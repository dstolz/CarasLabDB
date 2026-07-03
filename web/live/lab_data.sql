-- ============================================================================
-- lab_data.sql — export the whole lab schema as one JSON object for the
-- live dashboard (web/live/lab-dashboard-live.html).
-- ============================================================================
-- Emits a SINGLE row / SINGLE column of JSON whose shape matches the
-- `window.LAB_DATA` contract the dashboard's render code expects:
--
--   people, probes, pipelines, storageRoots, species, projects,
--   projectMembers, projectArtifacts, subjects, sessions, events,
--   artifacts, eventInputs, eventTypeMeta, roleMeta, NOW
--
-- Notes on the mapping:
--   * Full history is returned (superseded rows included). The dashboard
--     derives active/superseded client-side from the `supersedes` links,
--     exactly like the lab.event_active / lab.artifact_active views.
--   * Each event carries a `detail` object = its class-table-inheritance
--     row (birth_event, surgery_event, ...) minus the event_id/event_type
--     bookkeeping columns.
--   * Each artifact carries a `verification` object = its latest
--     lab.artifact_verification row, or {status:'unverified'} if none.
--   * timestamptz values are rendered as UTC ISO-8601 ("...Z") strings and
--     `NOW` as epoch milliseconds, matching what the front-end parses.
--
-- Run standalone to produce a static export:
--   psql -tAX -v ON_ERROR_STOP=1 -d lab -f web/live/lab_data.sql > lab-data.json
-- The bundled server (web/live/server.py) runs it per request instead.
-- ============================================================================

SET TIME ZONE 'UTC';

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
        'occurred_at', to_char(e.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'recorded_at', to_char(e.recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'recorded_by', e.recorded_by, 'supersedes', e.supersedes, 'notes', e.notes,
        'detail', CASE e.event_type
            WHEN 'birth'     THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.birth_event     x WHERE x.event_id = e.event_id)
            WHEN 'surgery'   THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.surgery_event   x WHERE x.event_id = e.event_id)
            WHEN 'recording' THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.recording_event x WHERE x.event_id = e.event_id)
            WHEN 'behavior'  THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.behavior_event  x WHERE x.event_id = e.event_id)
            WHEN 'husbandry' THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.husbandry_event x WHERE x.event_id = e.event_id)
            WHEN 'endpoint'  THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.endpoint_event  x WHERE x.event_id = e.event_id)
            WHEN 'histology' THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.histology_event x WHERE x.event_id = e.event_id)
            WHEN 'analysis'  THEN (SELECT to_jsonb(x) - 'event_id' - 'event_type' FROM lab.analysis_event  x WHERE x.event_id = e.event_id)
            ELSE '{}'::jsonb
        END
    ) ORDER BY e.occurred_at), '[]'::json) AS j
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
        'created_by', a.created_by,
        'verification', coalesce((
            SELECT json_build_object(
                'status', v.status,
                'verified_at', to_char(v.verified_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
            )
            FROM lab.artifact_verification v
            WHERE v.artifact_id = a.artifact_id
            ORDER BY v.verified_at DESC
            LIMIT 1
        ), json_build_object('status', 'unverified', 'verified_at', NULL))
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
    'roleMeta',         role_meta.j
) AS lab_data
FROM people, probes, pipelines, storage_roots, species, projects,
     project_members, project_artifacts, subjects, sessions, events,
     artifacts, event_inputs, event_type_meta, role_meta;
