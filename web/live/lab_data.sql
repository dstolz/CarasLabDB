-- ============================================================================
-- lab_data.sql — export the whole lab schema as one JSON object for the
-- live dashboard (web/live/lab-dashboard-live.html).
-- ============================================================================
-- Emits a SINGLE row / SINGLE column of JSON whose shape matches the
-- `window.LAB_DATA` contract the dashboard's render code expects:
--
--   people, probes, pipelines, storageRoots, species, projects,
--   projectMembers, projectArtifacts, subjects, sessions, events,
--   artifacts, eventInputs, eventTypeMeta, roleMeta, tagNamespaces, tags,
--   tagAssignments, variables, variableValues, retractions, dispositions, NOW
--
-- The integrity summary (`integrity`) is NOT computed here: it is
-- lab_integrity.sql, which server.py runs on its own, longer-lived cache
-- (lab.fn_check_integrity() costs about as much as this whole export) and
-- splices into the payload. `python web/live/server.py --dump` writes the
-- combined payload to stdout.
--
-- Notes on the mapping:
--   * Full history is returned (superseded rows included). The dashboard
--     derives active/superseded client-side from the `supersedes` links,
--     exactly like the lab.event_active / lab.artifact_active views.
--   * Each event carries a `detail` object = its class-table-inheritance
--     row (birth_event, surgery_event, ...) minus the event_id/event_type
--     bookkeeping columns.
--   * Each artifact carries a `verification` object = the latest check of
--     the FILE it describes, from lab.artifact_verification_latest (a
--     corrected artifact row keeps its file's verification state), or
--     {status:'unverified'} if the file was never checked.
--   * Tags: `tagNamespaces` and `tags` are the vocabulary (applies_to as a
--     JSON array); `tagAssignments` is the whole append-only log in
--     assignment_id order, each row naming its entity as (entity_kind,
--     entity_id) -- entity_id computed exactly as lab.tag_current does. The
--     dashboard derives current tags from the log like lab.tag_current: the
--     latest row per entity and tag by assignment_id, kept if it is an 'add'.
--   * timestamptz values are rendered as UTC ISO-8601 ("...Z") strings and
--     `NOW` as epoch milliseconds, matching what the front-end parses.
--     event.occurred_at and tag_assignment.applied_at keep their microseconds:
--     the dashboard orders events by occurred_at (latest weight per subject,
--     like lab.subject_current), and two events in one second must not tie
--     there when they do not tie in the database. The other timestamps are
--     whole seconds. The timestamps inside `detail` objects carry the
--     session zone's offset; server.py pins that zone to UTC, and PGTZ=UTC
--     does the same for psql.
--   * recorded_login / created_login are the database logins that inserted
--     the row (NULL only on rows older than pre-launch schema version 4).
--   * Variables: `variables` are the definitions (lab.variable, applies_to as
--     a JSON array); `variableValues` is the whole append-only log
--     (lab.variable_value) in value_id order, each row naming its entity as
--     (entity_kind, entity_id) like the tag log. `value` is the value as TEXT
--     exactly as stored -- coalesce(value_text, value_num::text), the same
--     expression as lab.variable_current.value -- never a JSON number, so
--     1350.50 stays 1350.50 and a 20-digit number keeps every digit;
--     value_type says how to read it. The dashboard derives current values
--     like lab.variable_current: the latest row per entity and variable by
--     value_id, kept if it is a 'set'.
--   * Retractions: `retractions` is lab.retraction. A retracted event or
--     artifact is not active, exactly as in lab.event_active /
--     lab.artifact_active; the dashboard applies that client-side.
--   * Dispositions: `dispositions` is lab.artifact_disposition, the log of
--     what became of files (replaced, moved, deleted, restored). It belongs
--     to the file (storage root, path, checksum); the dashboard takes each
--     file's latest row by disposition_id, as lab.artifact_disposition_latest,
--     and a row is present (lab.artifact_present) when it is active and its
--     file was not replaced, moved or deleted since.
--
-- This file is a single statement. Run it standalone to produce a static
-- export (without the integrity summary):
--   PGTZ=UTC psql -tAXq -v ON_ERROR_STOP=1 -d lab -f web/live/lab_data.sql > lab-data.json
-- The bundled server (web/live/server.py) runs it on demand instead.
-- ============================================================================

WITH
people AS (
    SELECT coalesce(json_agg(json_build_object(
        'person_id', person_id, 'full_name', full_name, 'email', email,
        'role', role, 'is_active', is_active
    ) ORDER BY full_name), '[]'::json) AS j
    FROM lab.person
),
probes AS (
    SELECT coalesce(json_agg(json_build_object(
        'probe_id', probe_id, 'manufacturer', manufacturer, 'model', model,
        'n_channels', n_channels, 'description', description
    )), '[]'::json) AS j
    FROM lab.probe
),
pipelines AS (
    SELECT coalesce(json_agg(json_build_object(
        'pipeline_id', pipeline_id, 'name', name,
        'description', description, 'repo_url', repo_url
    )), '[]'::json) AS j
    FROM lab.pipeline
),
storage_roots AS (
    SELECT coalesce(json_agg(json_build_object(
        'root_id', root_id, 'name', name, 'description', description
    ) ORDER BY root_id), '[]'::json) AS j
    FROM lab.storage_root
),
species AS (
    SELECT coalesce(json_agg(json_build_object(
        'code', code, 'common_name', common_name
    ) ORDER BY common_name), '[]'::json) AS j
    FROM lab.species
),
projects AS (
    SELECT coalesce(json_agg(json_build_object(
        'project_id', project_id, 'name', name, 'description', description,
        'started_on', started_on, 'is_active', is_active, 'created_by', created_by
    ) ORDER BY name), '[]'::json) AS j
    FROM lab.project
),
project_members AS (
    SELECT coalesce(json_agg(json_build_object(
        'project_id', project_id, 'person_id', person_id, 'role', role
    )), '[]'::json) AS j
    FROM lab.project_member
),
project_artifacts AS (
    SELECT coalesce(json_agg(json_build_object(
        'project_artifact_id', project_artifact_id, 'project_id', project_id,
        'title', title, 'kind', kind, 'content_type', content_type,
        'uri', uri, 'storage_root_id', storage_root_id,
        'relative_path', relative_path, 'description', description,
        'created_at', to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'created_by', created_by
    )), '[]'::json) AS j
    FROM lab.project_artifact
),
subjects AS (
    SELECT coalesce(json_agg(json_build_object(
        'subject_id', subject_id, 'project_id', project_id,
        'species_code', species_code, 'sex', sex, 'strain', strain,
        'genotype', genotype, 'source', source, 'date_of_birth', date_of_birth,
        'notes', notes,
        'created_at', to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'created_by', created_by
    ) ORDER BY subject_id), '[]'::json) AS j
    FROM lab.subject
),
sessions AS (
    SELECT coalesce(json_agg(json_build_object(
        'session_id', session_id, 'subject_id', subject_id, 'label', label,
        'storage_root_id', storage_root_id, 'relative_path', relative_path,
        'started_at', to_char(started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'ended_at',   to_char(ended_at   AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'rig', rig, 'notes', notes, 'created_by', created_by
    )), '[]'::json) AS j
    FROM lab.session
),
events AS (
    SELECT coalesce(json_agg(json_build_object(
        'event_id', e.event_id, 'event_type', e.event_type,
        'subject_id', e.subject_id, 'session_id', e.session_id,
        'occurred_at', to_char(e.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'recorded_at', to_char(e.recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'recorded_by', e.recorded_by, 'recorded_login', e.recorded_login,
        'supersedes', e.supersedes, 'notes', e.notes,
        -- coalesce: a partially-written event (base row inserted, detail row
        -- not) would otherwise yield JSON null and make the dashboard's
        -- ev.detail.<field> lookups throw.
        'detail', coalesce(CASE e.event_type
            WHEN 'birth'     THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.birth_event     x WHERE x.event_id = e.event_id)
            WHEN 'surgery'   THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.surgery_event   x WHERE x.event_id = e.event_id)
            WHEN 'recording' THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.recording_event x WHERE x.event_id = e.event_id)
            WHEN 'behavior'  THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.behavior_event  x WHERE x.event_id = e.event_id)
            WHEN 'husbandry' THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.husbandry_event x WHERE x.event_id = e.event_id)
            WHEN 'endpoint'  THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.endpoint_event  x WHERE x.event_id = e.event_id)
            WHEN 'histology' THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.histology_event x WHERE x.event_id = e.event_id)
            WHEN 'analysis'  THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.analysis_event  x WHERE x.event_id = e.event_id)
            WHEN 'observation' THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.observation_event x WHERE x.event_id = e.event_id)
            ELSE '{}'::jsonb
        END, '{}'::jsonb)
    ) ORDER BY e.occurred_at, e.event_id), '[]'::json) AS j
    FROM lab.event e
),
artifacts AS (
    SELECT coalesce(json_agg(json_build_object(
        'artifact_id', a.artifact_id, 'produced_by_event_id', a.produced_by_event_id,
        'storage_root_id', a.storage_root_id, 'relative_path', a.relative_path,
        'checksum', a.checksum, 'checksum_algo', a.checksum_algo,
        'size_bytes', a.size_bytes, 'role', a.role, 'format', a.format,
        'subject_id', a.subject_id, 'session_id', a.session_id,
        'supersedes', a.supersedes,
        'created_at', to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'created_by', a.created_by, 'created_login', a.created_login,
        -- The view holds one row per artifact whose FILE (storage root, path,
        -- checksum) has ever been checked, whichever row of the correction
        -- chain the check was recorded against, latest check first by
        -- (verified_at, verification_id). verified_artifact_id tells the
        -- dashboard when that was another row than this one.
        'verification', coalesce((
            SELECT json_build_object(
                'status', v.status,
                'verified_at', to_char(v.verified_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                'verified_artifact_id', v.verified_artifact_id
            )
            FROM lab.artifact_verification_latest v
            WHERE v.artifact_id = a.artifact_id
        ), json_build_object('status', 'unverified', 'verified_at', NULL,
                             'verified_artifact_id', NULL))
    )), '[]'::json) AS j
    FROM lab.artifact a
),
event_inputs AS (
    SELECT coalesce(json_agg(json_build_object(
        'event_id', event_id, 'artifact_id', artifact_id, 'role', role
    )), '[]'::json) AS j
    FROM lab.event_input
),
event_type_meta AS (
    SELECT coalesce(json_agg(json_build_object(
        'code', code, 'label', label
    )), '[]'::json) AS j
    FROM lab.event_type
),
role_meta AS (
    SELECT coalesce(json_agg(code ORDER BY code), '[]'::json) AS j
    FROM lab.artifact_role
),
tag_namespaces AS (
    SELECT coalesce(json_agg(json_build_object(
        'namespace', namespace, 'description', description,
        'mutability', mutability, 'cardinality', cardinality,
        'open_vocabulary', open_vocabulary, 'applies_to', applies_to,
        'created_at', to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'created_by', created_by
    ) ORDER BY namespace), '[]'::json) AS j
    FROM lab.tag_namespace
),
tags AS (
    SELECT coalesce(json_agg(json_build_object(
        'tag', tag, 'namespace', namespace, 'value', value,
        'description', description,
        'retired_at', to_char(retired_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'created_at', to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'created_by', created_by
    ) ORDER BY tag), '[]'::json) AS j
    FROM lab.tag
),
tag_assignments AS (
    SELECT coalesce(json_agg(json_build_object(
        'assignment_id', assignment_id, 'entity_kind', entity_kind,
        'entity_id', coalesce(event_id::text, artifact_id::text, subject_id,
                              session_id::text, project_id::text),
        'tag', tag, 'op', op, 'note', note,
        'applied_at', to_char(applied_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'applied_by', applied_by
    ) ORDER BY assignment_id), '[]'::json) AS j
    FROM lab.tag_assignment
),
variables AS (
    SELECT coalesce(json_agg(json_build_object(
        'name', name, 'label', label, 'description', description,
        'units', units, 'value_type', value_type, 'applies_to', applies_to,
        'retired_at', to_char(retired_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'created_at', to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'created_by', created_by
    ) ORDER BY name), '[]'::json) AS j
    FROM lab.variable
),
variable_values AS (
    SELECT coalesce(json_agg(json_build_object(
        'value_id', vv.value_id, 'entity_kind', vv.entity_kind,
        'entity_id', coalesce(vv.event_id::text, vv.artifact_id::text, vv.subject_id,
                              vv.session_id::text, vv.project_id::text),
        'variable', vv.variable, 'op', vv.op,
        'value', coalesce(vv.value_text, vv.value_num::text),
        'value_type', v.value_type, 'note', vv.note,
        'set_at', to_char(vv.set_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'set_by', vv.set_by, 'set_login', vv.set_login
    ) ORDER BY vv.value_id), '[]'::json) AS j
    FROM lab.variable_value vv
    JOIN lab.variable v ON v.name = vv.variable
),
retractions AS (
    SELECT coalesce(json_agg(json_build_object(
        'retraction_id', retraction_id, 'entity_kind', entity_kind,
        'entity_id', coalesce(event_id::text, artifact_id::text),
        'reason', reason,
        'retracted_at', to_char(retracted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'retracted_by', retracted_by, 'retracted_login', retracted_login
    ) ORDER BY retraction_id), '[]'::json) AS j
    FROM lab.retraction
),
dispositions AS (
    SELECT coalesce(json_agg(json_build_object(
        'disposition_id', disposition_id, 'artifact_id', artifact_id,
        'disposition', disposition, 'successor_artifact_id', successor_artifact_id,
        'occurred_at', to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'recorded_at', to_char(recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'recorded_by', recorded_by, 'recorded_login', recorded_login, 'note', note
    ) ORDER BY disposition_id), '[]'::json) AS j
    FROM lab.artifact_disposition
)
SELECT json_build_object(
    'NOW',              (extract(epoch FROM now()) * 1000)::bigint,
    'people',           people.j,
    'probes',           probes.j,
    'pipelines',        pipelines.j,
    'storageRoots',     storage_roots.j,
    'species',          species.j,
    'projects',         projects.j,
    'projectMembers',   project_members.j,
    'projectArtifacts', project_artifacts.j,
    'subjects',         subjects.j,
    'sessions',         sessions.j,
    'events',           events.j,
    'artifacts',        artifacts.j,
    'eventInputs',      event_inputs.j,
    'eventTypeMeta',    event_type_meta.j,
    'roleMeta',         role_meta.j,
    'tagNamespaces',    tag_namespaces.j,
    'tags',             tags.j,
    'tagAssignments',   tag_assignments.j,
    'variables',        variables.j,
    'variableValues',   variable_values.j,
    'retractions',      retractions.j,
    'dispositions',     dispositions.j
) AS lab_data
FROM people, probes, pipelines, storage_roots, species, projects,
     project_members, project_artifacts, subjects, sessions, events,
     artifacts, event_inputs, event_type_meta, role_meta, tag_namespaces,
     tags, tag_assignments, variables, variable_values, retractions, dispositions;
