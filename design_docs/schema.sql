-- ============================================================================
-- Lab Metadata System — schema DDL (PostgreSQL 14+)
-- ============================================================================
-- Canonical, runnable schema for the append-only event log, artifact index, and
-- provenance DAG. See design_docs/database-design.md for the ER diagram and the
-- table-by-table rationale. Apply against a fresh database, e.g.:
--
--     createdb lab && psql -d lab -f design_docs/schema.sql
--
-- This file installs the latest schema version (see lab.schema_version below).
-- To upgrade an existing database instead, apply the scripts in
-- design_docs/migrations/ in order; a fresh install from this file and an
-- upgraded database end up with identical schemas.
--
-- Requires privileges to create a schema. gen_random_uuid() is in core since
-- PG 13; the pgcrypto line is a fallback for older servers.
-- ============================================================================

-- CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- only needed on PG < 13
CREATE SCHEMA IF NOT EXISTS lab;

-- ---------------------------------------------------------------------------
-- Schema version
-- ---------------------------------------------------------------------------
-- One row per applied schema version; the current version is max(version).
-- This file installs the latest version directly; an existing database is
-- brought up to date by the scripts in design_docs/migrations/, each of which
-- inserts its own row. Clients (the CarasLabDB MATLAB class, the MCP server)
-- read max(version) at connect time and warn when it is not the version they
-- were written for -- a client with hard-coded column lists can otherwise
-- return wrong data against a changed schema rather than failing.
CREATE TABLE lab.schema_version (
    version     integer PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    description text NOT NULL
);

-- ---------------------------------------------------------------------------
-- Reference / lookup tables
-- ---------------------------------------------------------------------------
CREATE TABLE lab.person (
    person_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name   text NOT NULL CHECK (btrim(full_name) <> ''),
    email       text,
    role        text,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);
-- Email is the natural login key the client layer resolves "current person" by,
-- so uniqueness must be case-insensitive: 'Dan@umd.edu' and 'dan@umd.edu' are
-- one person, and a plain UNIQUE(email) would happily store both and then
-- resolve the wrong one (or none) at connection time.
CREATE UNIQUE INDEX uq_person_email_lower
    ON lab.person (lower(email)) WHERE email IS NOT NULL;

CREATE TABLE lab.storage_root (
    root_id     smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        text NOT NULL UNIQUE,          -- e.g. 'nas-main'
    description text
);

CREATE TABLE lab.species (
    code        text PRIMARY KEY,              -- e.g. 'meriones_unguiculatus'
    common_name text NOT NULL
);

CREATE TABLE lab.probe (
    probe_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    manufacturer text,
    model        text,
    n_channels   integer,
    geometry     jsonb,                         -- site coordinates / layout
    description  text
);

CREATE TABLE lab.pipeline (
    pipeline_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL UNIQUE,
    description text,
    repo_url    text
);

CREATE TABLE lab.event_type (
    code  text PRIMARY KEY,
    label text NOT NULL
);

CREATE TABLE lab.artifact_role (
    code  text PRIMARY KEY,
    label text NOT NULL
);

CREATE TABLE lab.acquisition_system (
    code  text PRIMARY KEY,
    label text NOT NULL
);

-- ---------------------------------------------------------------------------
-- Projects
-- ---------------------------------------------------------------------------
-- A project groups subjects and the people who work on them, and collects the
-- project-level documents (files on the NAS plus external references such as
-- Google Docs/Sheets). Unlike the event/artifact provenance tables, project
-- rows are mutable: people join/leave a project and reference docs get revised,
-- so these tables are deliberately left out of the append-only triggers below.
CREATE TABLE lab.project (
    project_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL UNIQUE,           -- unique project name
    description text,
    started_on  date,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid REFERENCES lab.person(person_id)
);

-- People associated with a project (many-to-many; a project has one or more).
CREATE TABLE lab.project_member (
    project_id uuid NOT NULL REFERENCES lab.project(project_id),
    person_id  uuid NOT NULL REFERENCES lab.person(person_id),
    role       text,                            -- 'PI','lead','member','analyst',...
    added_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, person_id)
);

-- Project-level artifacts: NAS files of any type plus external references
-- (Google Docs/Sheets, arbitrary URLs). These are attachments / reference
-- material, distinct from the provenance `artifact` table (which tracks
-- checksummed data files produced by events).
CREATE TABLE lab.project_artifact (
    project_artifact_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id          uuid NOT NULL REFERENCES lab.project(project_id),
    title               text NOT NULL,
    kind                text NOT NULL DEFAULT 'file'
                            CHECK (kind IN ('file','google_doc','google_sheet','url','other')),
    content_type        text,                    -- file type / MIME: 'pdf','xlsx','docx','csv',...
    -- External references (google_doc / google_sheet / url) are located by URI ...
    uri                 text,
    -- ... while NAS files are located under a storage root at a relative path.
    storage_root_id     smallint REFERENCES lab.storage_root(root_id),
    relative_path       text,
    description         text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid REFERENCES lab.person(person_id),
    -- A 'file' lives on the NAS; every other kind is located by URI.
    CONSTRAINT project_artifact_location_ck CHECK (
        (kind = 'file'
             AND storage_root_id IS NOT NULL AND relative_path IS NOT NULL
             AND uri IS NULL)
        OR (kind <> 'file'
             AND uri IS NOT NULL
             AND storage_root_id IS NULL AND relative_path IS NULL)
    ),
    -- See "Relative-path rules" above CREATE TABLE lab.session for the rationale.
    CONSTRAINT project_artifact_path_ck CHECK (
        relative_path IS NULL OR (
                relative_path <> ''
            AND relative_path = btrim(relative_path)
            AND relative_path !~ '^([/\\]|[A-Za-z]:)'
            AND relative_path !~ '\\'
            AND relative_path !~ '(^|/)\.\.(/|$)')
    )
);

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------
CREATE TABLE lab.subject (
    -- Lab ID (natural key). Constrained to non-blank, no surrounding whitespace:
    -- a stray trailing space produces a second, visually identical animal that
    -- silently splits that animal's event history in two.
    subject_id    text PRIMARY KEY CHECK (subject_id <> '' AND subject_id = btrim(subject_id)),
    project_id    uuid NOT NULL REFERENCES lab.project(project_id),
    species_code  text REFERENCES lab.species(code),
    sex           char(1) NOT NULL DEFAULT 'U' CHECK (sex IN ('M','F','U')),
    strain        text,
    genotype      text,
    source        text,                         -- 'bred_in_house', 'vendor:...'
    date_of_birth date,                         -- nullable: acquired animals
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid REFERENCES lab.person(person_id)
);

-- Relative-path rules (applied to lab.session, lab.artifact and
-- lab.project_artifact). Paths are stored *relative* to a storage root so they
-- resolve on every machine that mounts the NAS, which only works if the stored
-- text is genuinely relative and canonical:
--   * non-empty and not whitespace-padded;
--   * no leading '/' or '\' and no 'C:' drive letter — an absolute path baked
--     in from one workstation resolves nowhere else;
--   * forward slashes only — a Windows client writing 'GERB042\sess01' and a
--     Linux client writing 'GERB042/sess01' are the same folder, but the
--     UNIQUE constraints below would see two different rows, which defeats
--     both the session-to-folder mapping and artifact de-duplication.
--     Backslashes are rewritten to '/' on insert by trg_*_normalize_path, so
--     the CHECK's backslash clause is a post-normalization invariant rather
--     than something a caller normally trips over;
--   * no '..' segments, which would let a stored path escape its storage root.
-- The predicate is inlined rather than factored into a helper function so that
-- the constraints carry no dependency on restore order in a pg_dump/pg_restore.
CREATE TABLE lab.session (
    session_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_id      text NOT NULL REFERENCES lab.subject(subject_id) ON UPDATE CASCADE,
    label           text NOT NULL CHECK (label <> '' AND label = btrim(label)),
    storage_root_id smallint NOT NULL REFERENCES lab.storage_root(root_id),
    relative_path   text NOT NULL,              -- 'subject/session' under root
    started_at      timestamptz,
    ended_at        timestamptz,
    rig             text,
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid REFERENCES lab.person(person_id),
    UNIQUE (subject_id, label),
    UNIQUE (storage_root_id, relative_path),
    -- FK target for lab.event / lab.artifact, so a row cannot claim a session
    -- that belongs to a different subject (see event_session_subject_fk).
    UNIQUE (session_id, subject_id),
    CONSTRAINT session_interval_ck CHECK (ended_at IS NULL OR started_at IS NULL
                                          OR ended_at >= started_at),
    CONSTRAINT session_path_ck CHECK (
            relative_path <> ''
        AND relative_path = btrim(relative_path)
        AND relative_path !~ '^([/\\]|[A-Za-z]:)'
        AND relative_path !~ '\\'
        AND relative_path !~ '(^|/)\.\.(/|$)')
);

-- ---------------------------------------------------------------------------
-- Event base
-- ---------------------------------------------------------------------------
CREATE TABLE lab.event (
    event_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type  text NOT NULL REFERENCES lab.event_type(code),
    subject_id  text REFERENCES lab.subject(subject_id) ON UPDATE CASCADE,
    session_id  uuid REFERENCES lab.session(session_id),
    occurred_at timestamptz NOT NULL,           -- when it happened in the lab
    recorded_at timestamptz NOT NULL DEFAULT now(),  -- when the row was inserted
    recorded_by uuid REFERENCES lab.person(person_id),
    supersedes  uuid REFERENCES lab.event(event_id),
    notes       text,
    attributes  jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (supersedes <> event_id),
    -- attributes is an open extension point, but it must stay an *object*:
    -- a client that writes a bare array or scalar breaks every consumer that
    -- does attributes->>'key', and the GIN index below assumes object shape.
    CONSTRAINT event_attributes_object_ck CHECK (jsonb_typeof(attributes) = 'object'),
    -- Every event is about an animal except an analysis run, which may span
    -- several (a cross-animal analysis). A birth, surgery, recording, behavior,
    -- husbandry, endpoint or histology event with no subject is an entry
    -- error that every per-subject view would silently drop. A session-only
    -- insert still passes: trg_event_fill_subject runs BEFORE INSERT, ahead of
    -- this CHECK, and fills subject_id in from the session.
    CONSTRAINT event_subject_required_ck CHECK (
        subject_id IS NOT NULL OR event_type = 'analysis'),
    UNIQUE (event_id, event_type),              -- FK target for detail tables
    -- An event that names a session must name that session's subject. Without
    -- this an event could be filed under animal A while pointing at a session
    -- belonging to animal B — the row looks fine in isolation and silently
    -- corrupts every per-subject rollup. trg_event_fill_subject (below) fills
    -- subject_id in from the session when the caller omits it, so this is a
    -- consistency check rather than an extra field callers must remember.
    -- Deliberately NO ACTION, not ON UPDATE CASCADE. During a subject rename
    -- both lab.session.subject_id and lab.event.subject_id are already updated
    -- by their own cascades from lab.subject; adding a second cascade path
    -- into this same column would update the same event row twice within one
    -- command ("tuple to be updated was already modified..."). NO ACTION is
    -- checked at end of statement, by which point both sides are consistent.
    CONSTRAINT event_session_subject_fk FOREIGN KEY (session_id, subject_id)
        REFERENCES lab.session(session_id, subject_id)
);
-- Linear correction history: each row corrected by at most one successor.
CREATE UNIQUE INDEX uq_event_supersedes
    ON lab.event (supersedes) WHERE supersedes IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Event detail tables (class-table inheritance)
-- ---------------------------------------------------------------------------
CREATE TABLE lab.birth_event (
    event_id        uuid PRIMARY KEY,
    event_type      text NOT NULL DEFAULT 'birth' CHECK (event_type = 'birth'),
    dam_subject_id  text REFERENCES lab.subject(subject_id) ON UPDATE CASCADE,
    sire_subject_id text REFERENCES lab.subject(subject_id) ON UPDATE CASCADE,
    litter_id       text,
    birth_weight_g  numeric CHECK (birth_weight_g IS NULL OR birth_weight_g > 0),
    CONSTRAINT birth_parents_distinct_ck CHECK (dam_subject_id IS NULL
                                                OR sire_subject_id IS NULL
                                                OR dam_subject_id <> sire_subject_id),
    FOREIGN KEY (event_id, event_type)
        REFERENCES lab.event(event_id, event_type)
);

CREATE TABLE lab.surgery_event (
    event_id        uuid PRIMARY KEY,
    event_type      text NOT NULL DEFAULT 'surgery' CHECK (event_type = 'surgery'),
    procedure       text,
    surgeon_id      uuid REFERENCES lab.person(person_id),
    anesthesia      text,
    target_region   text,
    hemisphere      text CHECK (hemisphere IN ('L','R','bilateral')),
    stereotax_ap_mm numeric,
    stereotax_ml_mm numeric,
    stereotax_dv_mm numeric,
    probe_id        uuid REFERENCES lab.probe(probe_id),
    outcome         text,
    FOREIGN KEY (event_id, event_type)
        REFERENCES lab.event(event_id, event_type)
);

CREATE TABLE lab.recording_event (
    event_id                uuid PRIMARY KEY,
    event_type              text NOT NULL DEFAULT 'recording'
                                 CHECK (event_type = 'recording'),
    acquisition_system_code text REFERENCES lab.acquisition_system(code),
    probe_id                uuid REFERENCES lab.probe(probe_id),
    modality                text NOT NULL DEFAULT 'ephys'
                                 CHECK (modality IN ('ephys','video','behavior','multimodal')),
    sample_rate_hz          numeric CHECK (sample_rate_hz IS NULL OR sample_rate_hz > 0),
    n_channels              integer CHECK (n_channels IS NULL OR n_channels > 0),
    duration_s              numeric CHECK (duration_s IS NULL OR duration_s >= 0),
    stimulus_protocol       text,
    hardware_config         jsonb CHECK (hardware_config IS NULL
                                         OR jsonb_typeof(hardware_config) = 'object'),
    FOREIGN KEY (event_id, event_type)
        REFERENCES lab.event(event_id, event_type)
);

CREATE TABLE lab.behavior_event (
    event_id         uuid PRIMARY KEY,
    event_type       text NOT NULL DEFAULT 'behavior' CHECK (event_type = 'behavior'),
    task             text,
    paradigm         text,
    stage            text,
    trials_completed integer CHECK (trials_completed IS NULL OR trials_completed >= 0),
    -- Deliberately only bounded below: labs record performance as either a
    -- proportion (0-1) or a percentage (0-100), so an upper bound would reject
    -- one convention or the other. Pick one per task and keep it consistent.
    performance      numeric CHECK (performance IS NULL OR performance >= 0),
    reward           text,
    FOREIGN KEY (event_id, event_type)
        REFERENCES lab.event(event_id, event_type)
);

CREATE TABLE lab.husbandry_event (
    event_id      uuid PRIMARY KEY,
    event_type    text NOT NULL DEFAULT 'husbandry' CHECK (event_type = 'husbandry'),
    measure       text NOT NULL CHECK (btrim(measure) <> ''),
                                 -- 'weight','health_check','water_restriction',...
    weight_g      numeric CHECK (weight_g IS NULL OR weight_g > 0),
    water_ml      numeric CHECK (water_ml IS NULL OR water_ml >= 0),
    health_status text,
    FOREIGN KEY (event_id, event_type)
        REFERENCES lab.event(event_id, event_type)
);

CREATE TABLE lab.endpoint_event (
    event_id           uuid PRIMARY KEY,
    event_type         text NOT NULL DEFAULT 'endpoint' CHECK (event_type = 'endpoint'),
    method             text,             -- 'perfusion','overdose',...
    perfusion_fixative text,
    tissue_collected   boolean,
    disposition        text,
    FOREIGN KEY (event_id, event_type)
        REFERENCES lab.event(event_id, event_type)
);

CREATE TABLE lab.histology_event (
    event_id      uuid PRIMARY KEY,
    event_type    text NOT NULL DEFAULT 'histology' CHECK (event_type = 'histology'),
    technique     text,
    target_region text,
    stain         text,
    microscope    text,
    FOREIGN KEY (event_id, event_type)
        REFERENCES lab.event(event_id, event_type)
);

CREATE TABLE lab.analysis_event (
    event_id      uuid PRIMARY KEY,
    event_type    text NOT NULL DEFAULT 'analysis' CHECK (event_type = 'analysis'),
    pipeline_id   uuid REFERENCES lab.pipeline(pipeline_id),
    pipeline_name text,               -- denormalized snapshot of the name
    code_version  text,               -- git SHA / release tag (reproducibility)
    parameters    jsonb NOT NULL DEFAULT '{}'::jsonb
                      CHECK (jsonb_typeof(parameters) = 'object'),
    -- OS / package versions / container digest
    environment   jsonb CHECK (environment IS NULL
                               OR jsonb_typeof(environment) = 'object'),
    started_at    timestamptz,
    finished_at   timestamptz,
    status        text CHECK (status IN ('running','succeeded','failed')),
    CONSTRAINT analysis_interval_ck CHECK (finished_at IS NULL OR started_at IS NULL
                                           OR finished_at >= started_at),
    -- A run still in flight cannot already have a finish time. The converse
    -- (succeeded/failed implies finished_at IS NOT NULL) is deliberately NOT
    -- enforced: back-filled historical runs legitimately know their outcome
    -- but not their wall-clock finish.
    CONSTRAINT analysis_running_unfinished_ck CHECK (
        status IS DISTINCT FROM 'running' OR finished_at IS NULL),
    FOREIGN KEY (event_id, event_type)
        REFERENCES lab.event(event_id, event_type)
);

-- ---------------------------------------------------------------------------
-- Artifacts & provenance edges
-- ---------------------------------------------------------------------------
CREATE TABLE lab.artifact (
    artifact_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    produced_by_event_id uuid NOT NULL REFERENCES lab.event(event_id),
    storage_root_id      smallint NOT NULL REFERENCES lab.storage_root(root_id),
    relative_path        text NOT NULL,
    checksum             text NOT NULL,
    checksum_algo        text NOT NULL DEFAULT 'sha256'
                             CHECK (checksum_algo IN ('sha256','md5','blake3')),
    size_bytes           bigint CHECK (size_bytes IS NULL OR size_bytes >= 0),
    role                 text REFERENCES lab.artifact_role(code),
    format               text,                    -- 'rhd','dat','npy','mp4','png'
    subject_id           text REFERENCES lab.subject(subject_id) ON UPDATE CASCADE,
    session_id           uuid REFERENCES lab.session(session_id),
    supersedes           uuid REFERENCES lab.artifact(artifact_id),
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid REFERENCES lab.person(person_id),
    attributes           jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (supersedes <> artifact_id),
    CONSTRAINT artifact_attributes_object_ck CHECK (jsonb_typeof(attributes) = 'object'),
    -- File identity (storage_root_id, relative_path, checksum) is de-duplicated
    -- by uq_artifact_file_original and trg_artifact_unique_active below, not by
    -- a table-wide UNIQUE: a correction to an artifact's metadata, or to the
    -- event that produced it, is a new row describing the *same* file.
    -- Same subject/session agreement rule as lab.event; see the comment there.
    -- NO ACTION for the same reason as event_session_subject_fk above.
    CONSTRAINT artifact_session_subject_fk FOREIGN KEY (session_id, subject_id)
        REFERENCES lab.session(session_id, subject_id),
    -- This whole table exists to make file integrity checkable, so a checksum
    -- that cannot possibly be one is worse than useless: a nightly verifier
    -- would report 'mismatch' forever with no way to tell a corrupted file from
    -- a malformed registration. Require the exact hex width of the declared
    -- algorithm. trg_artifact_normalize lower-cases the value first, so mixed
    -- case is accepted on input but stored canonically -- without that, 'AB..'
    -- and 'ab..' are two different keys to uq_artifact_file_original (below)
    -- and the same bytes get registered twice.
    CONSTRAINT artifact_checksum_format_ck CHECK (
        checksum ~ '^[0-9a-f]+$'
        AND length(checksum) = CASE checksum_algo
                                   WHEN 'md5'    THEN 32
                                   WHEN 'sha256' THEN 64
                                   WHEN 'blake3' THEN 64
                                   -- No silent pass-through: an algorithm added
                                   -- to the checksum_algo CHECK but not here
                                   -- must fail loudly rather than quietly
                                   -- disabling width validation (a CASE with no
                                   -- ELSE yields NULL, and `length = NULL` is
                                   -- NULL, which a CHECK accepts).
                                   ELSE -1
                               END),
    -- See "Relative-path rules" above CREATE TABLE lab.session.
    CONSTRAINT artifact_path_ck CHECK (
            relative_path <> ''
        AND relative_path = btrim(relative_path)
        AND relative_path !~ '^([/\\]|[A-Za-z]:)'
        AND relative_path !~ '\\'
        AND relative_path !~ '(^|/)\.\.(/|$)')
);
CREATE UNIQUE INDEX uq_artifact_supersedes
    ON lab.artifact (supersedes) WHERE supersedes IS NOT NULL;
-- One original registration per file: the same bytes at the same path cannot
-- be registered twice. Corrections (supersedes IS NOT NULL) are exempt because
-- a correction that only changes role/format/session/attributes, or re-points
-- produced_by_event_id at a corrected event, necessarily describes the same
-- file as the row it replaces. trg_artifact_unique_active (below) closes the
-- remaining gap: no two *active* rows may describe the same file.
CREATE UNIQUE INDEX uq_artifact_file_original
    ON lab.artifact (storage_root_id, relative_path, checksum)
    WHERE supersedes IS NULL;

CREATE TABLE lab.event_input (
    event_id    uuid NOT NULL REFERENCES lab.event(event_id),
    artifact_id uuid NOT NULL REFERENCES lab.artifact(artifact_id),
    role        text,
    PRIMARY KEY (event_id, artifact_id)
);

CREATE TABLE lab.artifact_verification (
    verification_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    artifact_id       uuid NOT NULL REFERENCES lab.artifact(artifact_id),
    verified_at       timestamptz NOT NULL DEFAULT now(),
    verified_by       uuid REFERENCES lab.person(person_id),
    status            text NOT NULL CHECK (status IN ('ok','missing','mismatch')),
    observed_checksum text,
    -- 'mismatch' is the one status that is actionable, and it is unactionable
    -- without the checksum that was actually observed.
    CONSTRAINT verification_mismatch_ck CHECK (
        status <> 'mismatch' OR observed_checksum IS NOT NULL),
    CONSTRAINT verification_checksum_format_ck CHECK (
        observed_checksum IS NULL OR observed_checksum ~ '^[0-9a-f]+$')
);

-- ---------------------------------------------------------------------------
-- Tags
-- ---------------------------------------------------------------------------
-- Hashtag-style labels on events, artifacts, subjects, sessions and projects,
-- for the ad-hoc categories (pipeline stage, cohort, QC outcome, topic) that
-- neither artifact.role nor free-text notes can be queried by. Every tag is
-- 'namespace:value', lower case, from a restricted character set. Only case
-- and surrounding whitespace are normalised on the way in (the same policy as
-- checksums and paths), plus one convenience: a tag written with no colon is
-- a *bare* tag and lands in the reserved 'tag' namespace, so 'auditory_cortex'
-- is stored as 'tag:auditory_cortex' (lab.fn_canonical_tag is the one place
-- that rule lives). Anything else malformed is rejected by the CHECKs below,
-- never rewritten.
--
-- The vocabulary (tag_namespace, tag) is mutable reference data, edited in
-- place and recorded in row_history. Putting a tag on a row is not: the
-- assignments are an append-only log, and an entity's current tags are
-- derived from it by the lab.tag_current view. Clients write through
-- lab.fn_tag.

-- One row per namespace, carrying the policy every tag in it obeys:
--   mutability       'immutable': once a tag of the namespace is on an entity
--                    it can never be removed or replaced (cohort, condition);
--                    'mutable': it can, and the log keeps the history.
--   cardinality      'single': at most one current tag of the namespace per
--                    entity (stage:raw XOR stage:analyzed); 'multi': any number.
--   open_vocabulary  whether lab.fn_tag / lab.fn_register_tag may create a new
--                    value on first use. A closed namespace still accepts a
--                    deliberate INSERT INTO lab.tag; what it stops is a typo
--                    (stage:currated) silently becoming vocabulary.
--   applies_to       the entity kinds its tags may be put on.
-- trg_tag_namespace_guard freezes mutability and cardinality, and lets
-- applies_to only grow, once any tag of the namespace has been assigned; the
-- reserved 'tag' namespace is frozen from the start.
CREATE TABLE lab.tag_namespace (
    namespace       text PRIMARY KEY,
    description     text,
    mutability      text NOT NULL,
    cardinality     text NOT NULL,
    open_vocabulary boolean NOT NULL DEFAULT true,
    applies_to      text[] NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid REFERENCES lab.person(person_id),
    CONSTRAINT tag_namespace_name_ck CHECK (namespace ~ '^[a-z][a-z0-9_]{0,31}$'),
    CONSTRAINT tag_namespace_mutability_ck CHECK (mutability IN ('mutable','immutable')),
    CONSTRAINT tag_namespace_cardinality_ck CHECK (cardinality IN ('single','multi')),
    CONSTRAINT tag_namespace_applies_to_ck CHECK (
        applies_to <@ ARRAY['event','artifact','subject','session','project']
        AND cardinality(applies_to) > 0)
);

-- One row per known tag. trg_tag_normalize canonicalises `tag` and fills
-- namespace/value from it, so a client may insert just the tag string. A tag
-- is never renamed (trg_tag_guard): retire it (retired_at) and register the
-- replacement, so the log keeps meaning what it meant.
CREATE TABLE lab.tag (
    tag         text PRIMARY KEY,
    namespace   text NOT NULL REFERENCES lab.tag_namespace(namespace),
    value       text NOT NULL,
    description text,
    retired_at  timestamptz,                 -- no new assignments once set
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid REFERENCES lab.person(person_id),
    CONSTRAINT tag_value_ck CHECK (value ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'),
    CONSTRAINT tag_parts_ck CHECK (tag = namespace || ':' || value),
    CONSTRAINT uq_tag_namespace_value UNIQUE (namespace, value)
);

-- The assignment log: one row per tag put on ('add') or taken off ('remove')
-- an entity. Exactly the id column matching entity_kind is set. The current
-- state is the latest row per (entity, tag) -- see lab.tag_current -- and
-- trg_tag_assignment_policy rejects a row the namespace's policy forbids.
--
-- Deliberately no stored or generated entity_id column: renaming a subject
-- cascades into subject_id here, and fn_forbid_mutation admits that cascade
-- only if every other column is unchanged, so a derived copy of the id would
-- make lab.fn_rename_subject fail for every tagged subject. The views and
-- functions compute entity_id instead (ix_tag_assignment_entity indexes it).
CREATE TABLE lab.tag_assignment (
    assignment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity_kind   text NOT NULL,
    event_id      uuid REFERENCES lab.event(event_id),
    artifact_id   uuid REFERENCES lab.artifact(artifact_id),
    subject_id    text REFERENCES lab.subject(subject_id) ON UPDATE CASCADE,
    session_id    uuid REFERENCES lab.session(session_id),
    project_id    uuid REFERENCES lab.project(project_id),
    tag           text NOT NULL REFERENCES lab.tag(tag),
    op            text NOT NULL,
    note          text,
    applied_at    timestamptz NOT NULL DEFAULT now(),
    applied_by    uuid REFERENCES lab.person(person_id),
    CONSTRAINT tag_assignment_kind_ck CHECK (
        entity_kind IN ('event','artifact','subject','session','project')),
    CONSTRAINT tag_assignment_op_ck CHECK (op IN ('add','remove')),
    CONSTRAINT tag_assignment_entity_ck CHECK (
            (entity_kind = 'event')    = (event_id IS NOT NULL)
        AND (entity_kind = 'artifact') = (artifact_id IS NOT NULL)
        AND (entity_kind = 'subject')  = (subject_id IS NOT NULL)
        AND (entity_kind = 'session')  = (session_id IS NOT NULL)
        AND (entity_kind = 'project')  = (project_id IS NOT NULL))
);

-- ---------------------------------------------------------------------------
-- Audit logs
-- ---------------------------------------------------------------------------
-- Both are append-only (see the trigger loop below). Clients never write to
-- them directly: maintenance_log is written by lab.fn_rename_subject, and
-- row_history by the lab.fn_log_row_change triggers.

-- Identity-maintenance operations (subject renames); see lab.fn_rename_subject.
CREATE TABLE lab.maintenance_log (
    maintenance_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    performed_at   timestamptz NOT NULL DEFAULT now(),
    performed_by   text NOT NULL DEFAULT current_user,
    operation      text NOT NULL,
    details        jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- Prior versions of rows in the *mutable* tables (the reference tables,
-- project tables, subject, session and the tag vocabulary). Those tables are
-- deliberately editable in place, but an in-place edit with no record of the
-- previous value or of who made it is the same provenance gap the event log
-- exists to close. One row per UPDATE that changed something, or per DELETE.
--
-- changed_by is session_user -- the login that connected -- rather than
-- current_user, which SET ROLE can change and which is the function owner
-- inside the SECURITY DEFINER trigger that writes this table. With per-person
-- logins it identifies the editor without client cooperation.
CREATE TABLE lab.row_history (
    history_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    changed_at timestamptz NOT NULL DEFAULT now(),
    changed_by text NOT NULL DEFAULT session_user,
    table_name text NOT NULL,
    operation  text NOT NULL CHECK (operation IN ('UPDATE','DELETE')),
    row_key    jsonb NOT NULL,           -- primary key of the row, before the change
    old_row    jsonb NOT NULL,
    new_row    jsonb,                    -- NULL for a DELETE
    CONSTRAINT row_history_new_row_ck CHECK ((operation = 'UPDATE') = (new_row IS NOT NULL))
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
-- The dominant read pattern is "this animal's / this session's history in time
-- order", so these lead with the filter column and carry occurred_at, letting
-- the planner satisfy filter+sort from one index instead of sorting the whole
-- per-subject set. They also serve plain subject_id / session_id lookups as a
-- leading-column prefix, so no separate single-column index is needed.
CREATE INDEX ix_event_subject   ON lab.event (subject_id, occurred_at DESC);
CREATE INDEX ix_event_session   ON lab.event (session_id, occurred_at DESC);
CREATE INDEX ix_event_type      ON lab.event (event_type);
CREATE INDEX ix_event_occurred  ON lab.event (occurred_at);
CREATE INDEX ix_event_attrs_gin ON lab.event USING gin (attributes);

CREATE INDEX ix_artifact_event    ON lab.artifact (produced_by_event_id);
CREATE INDEX ix_artifact_subject  ON lab.artifact (subject_id);
CREATE INDEX ix_artifact_session  ON lab.artifact (session_id);
CREATE INDEX ix_artifact_role     ON lab.artifact (role);
CREATE INDEX ix_artifact_checksum ON lab.artifact (checksum);

CREATE INDEX ix_event_input_artifact ON lab.event_input (artifact_id);
CREATE INDEX ix_analysis_params_gin  ON lab.analysis_event USING gin (parameters);

-- artifact_verification is the fastest-growing table in the schema (one row per
-- artifact per integrity sweep) and is almost always read as "latest check for
-- this artifact" -- which is exactly what the dashboard's per-artifact lateral
-- in web/live/lab_data.sql does. Without this it is a sequential scan of the
-- whole verification log per artifact, i.e. quadratic in database size.
CREATE INDEX ix_artifact_verification_artifact
    ON lab.artifact_verification (artifact_id, verified_at DESC);

CREATE INDEX ix_subject_project          ON lab.subject (project_id);
CREATE INDEX ix_project_member_person    ON lab.project_member (person_id);
CREATE INDEX ix_project_artifact_project ON lab.project_artifact (project_id);

-- Tag assignments are read per entity ("this artifact's tags", which every
-- tag filter asks once per candidate row) and per tag ("everything tagged
-- qc:fail"). The entity index is on the same expression lab.tag_current
-- computes entity_id from, so the planner can use it through the view. The
-- per-column indexes serve the foreign keys (a subject rename cascades here).
CREATE INDEX ix_tag_assignment_entity
    ON lab.tag_assignment (entity_kind, coalesce(event_id::text, artifact_id::text, subject_id,
                                                 session_id::text, project_id::text));
CREATE INDEX ix_tag_assignment_tag      ON lab.tag_assignment (tag, entity_kind);
CREATE INDEX ix_tag_assignment_event    ON lab.tag_assignment (event_id);
CREATE INDEX ix_tag_assignment_artifact ON lab.tag_assignment (artifact_id);
CREATE INDEX ix_tag_assignment_subject  ON lab.tag_assignment (subject_id);
CREATE INDEX ix_tag_assignment_session  ON lab.tag_assignment (session_id);
CREATE INDEX ix_tag_assignment_project  ON lab.tag_assignment (project_id);

-- ---------------------------------------------------------------------------
-- Immutability + validation triggers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lab.fn_forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_from text;
    v_to   text;
    v_old  jsonb;
    v_new  jsonb;
    v_ok   boolean;
    c      text;
BEGIN
    -- Narrow, audited escape hatch for identity maintenance only. Renaming a
    -- subject cascades an UPDATE into these append-only tables (see
    -- lab.fn_rename_subject), which is a relabelling of *who* a row is about,
    -- not a change to *what happened*. DELETE and TRUNCATE are never allowed,
    -- and the flags are transaction-local (set_config(..., is_local => true)).
    --
    -- The flag alone is not trusted -- any session can set a custom setting --
    -- so under it only an UPDATE that is exactly the cascade of a completed
    -- rename passes: every column other than the subject-id columns is
    -- unchanged, every subject-id column that changed went from
    -- lab.rename_from to lab.rename_to, the old subject id no longer exists
    -- and the new one does.
    IF TG_OP = 'UPDATE'
       AND coalesce(current_setting('lab.maintenance', true), '') = 'subject_rename'
    THEN
        v_from := coalesce(current_setting('lab.rename_from', true), '');
        v_to   := coalesce(current_setting('lab.rename_to', true), '');
        v_old  := to_jsonb(OLD);
        v_new  := to_jsonb(NEW);
        v_ok   := v_from <> '' AND v_to <> ''
              AND NOT EXISTS (SELECT 1 FROM lab.subject WHERE subject_id = v_from)
              AND EXISTS (SELECT 1 FROM lab.subject WHERE subject_id = v_to)
              AND (v_old - 'subject_id' - 'dam_subject_id' - 'sire_subject_id')
                = (v_new - 'subject_id' - 'dam_subject_id' - 'sire_subject_id');
        IF v_ok THEN
            FOREACH c IN ARRAY ARRAY['subject_id', 'dam_subject_id', 'sire_subject_id'] LOOP
                IF (v_old -> c) IS DISTINCT FROM (v_new -> c)
                   AND NOT ((v_old ->> c) = v_from AND (v_new ->> c) = v_to) THEN
                    v_ok := false;
                END IF;
            END LOOP;
        END IF;
        IF v_ok THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION
          'lab.maintenance = subject_rename admits only the subject-id relabelling '
          'performed by lab.fn_rename_subject; this UPDATE on %.% is not one',
          TG_TABLE_SCHEMA, TG_TABLE_NAME;
    END IF;

    IF TG_TABLE_NAME IN ('artifact_verification', 'maintenance_log',
                         'row_history', 'schema_version', 'tag_assignment') THEN
        RAISE EXCEPTION
          '% on %.% is not allowed: this table is an append-only log.',
          TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
    END IF;

    IF TG_TABLE_NAME = 'event_input' THEN
        -- event_input has no supersedes column, so the generic advice below
        -- would be impossible to follow. Correct a mis-recorded input by
        -- superseding the consuming *event* and re-declaring its inputs.
        RAISE EXCEPTION
          '% on lab.event_input is not allowed: provenance edges are append-only. '
          'Supersede the consuming event and re-declare its inputs instead.',
          TG_OP;
    END IF;

    RAISE EXCEPTION
      '% on %.% is not allowed: this table is append-only. Insert a superseding row instead.',
      TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
END;
$$;

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'event','birth_event','surgery_event','recording_event','behavior_event',
        'husbandry_event','endpoint_event','histology_event','analysis_event',
        'artifact','event_input',
        'artifact_verification','maintenance_log','row_history','schema_version',
        'tag_assignment'
    ] LOOP
        EXECUTE format(
          'DROP TRIGGER IF EXISTS trg_immutable_%1$s ON lab.%1$s;', t);
        EXECUTE format(
          'CREATE TRIGGER trg_immutable_%1$s
             BEFORE UPDATE OR DELETE ON lab.%1$s
             FOR EACH ROW EXECUTE FUNCTION lab.fn_forbid_mutation();', t);
        -- TRUNCATE bypasses row-level triggers entirely, so the row-level
        -- trigger above does NOT protect against it: a single
        -- `TRUNCATE lab.event CASCADE` would silently erase the whole
        -- append-only log and every artifact and provenance edge hanging off
        -- it. TRUNCATE only fires statement-level triggers, hence this second
        -- one. (FOR EACH ROW is not permitted for a TRUNCATE trigger, which is
        -- why it cannot simply be folded into the trigger above.)
        EXECUTE format(
          'DROP TRIGGER IF EXISTS trg_immutable_truncate_%1$s ON lab.%1$s;', t);
        EXECUTE format(
          'CREATE TRIGGER trg_immutable_truncate_%1$s
             BEFORE TRUNCATE ON lab.%1$s
             FOR EACH STATEMENT EXECUTE FUNCTION lab.fn_forbid_mutation();', t);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION lab.fn_require_session_for_recording() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT session_id FROM lab.event WHERE event_id = NEW.event_id) IS NULL THEN
        RAISE EXCEPTION
          'recording event % must reference a session (event.session_id is null)',
          NEW.event_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_require_session_for_recording
    BEFORE INSERT ON lab.recording_event
    FOR EACH ROW EXECUTE FUNCTION lab.fn_require_session_for_recording();

-- Fill subject_id in from the session when the caller supplies only session_id.
-- The session already determines the subject, so making callers repeat it is a
-- chance to get it wrong; deriving it here means the composite FK
-- (session_id, subject_id) is always exercised rather than being skipped as
-- MATCH SIMPLE does whenever one of its columns is NULL.
CREATE OR REPLACE FUNCTION lab.fn_fill_subject_from_session() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.session_id IS NOT NULL AND NEW.subject_id IS NULL THEN
        SELECT s.subject_id INTO NEW.subject_id
        FROM lab.session s WHERE s.session_id = NEW.session_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_event_fill_subject
    BEFORE INSERT ON lab.event
    FOR EACH ROW EXECUTE FUNCTION lab.fn_fill_subject_from_session();

CREATE TRIGGER trg_artifact_fill_subject
    BEFORE INSERT ON lab.artifact
    FOR EACH ROW EXECUTE FUNCTION lab.fn_fill_subject_from_session();

-- A correction replaces one statement of fact with a better one about the SAME
-- fact. Letting a 'recording' be superseded by a 'birth' would silently retype
-- history: event_active would show the birth, the recording detail row would
-- still exist but be unreachable, and per-type counts would not add up. The
-- partial unique index on supersedes keeps chains linear; this keeps them
-- type-stable.
CREATE OR REPLACE FUNCTION lab.fn_supersede_same_type() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE old_type text;
BEGIN
    IF NEW.supersedes IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT event_type INTO old_type FROM lab.event WHERE event_id = NEW.supersedes;
    IF old_type IS DISTINCT FROM NEW.event_type THEN
        RAISE EXCEPTION
          'event % of type % cannot supersede event % of type %: a correction '
          'must preserve the event type',
          NEW.event_id, NEW.event_type, NEW.supersedes, old_type;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_event_supersede_same_type
    BEFORE INSERT ON lab.event
    FOR EACH ROW EXECUTE FUNCTION lab.fn_supersede_same_type();

-- Canonicalize checksums to lower-case hex on the way in, so that the same
-- bytes registered by a client that emits upper-case hex de-duplicate against
-- uq_artifact_file_original / trg_artifact_unique_active instead of creating
-- a second artifact row for the identical file.
CREATE OR REPLACE FUNCTION lab.fn_normalize_checksum() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'artifact' THEN
        NEW.checksum := lower(btrim(NEW.checksum));
    ELSE
        NEW.observed_checksum := lower(btrim(NEW.observed_checksum));
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_artifact_normalize
    BEFORE INSERT ON lab.artifact
    FOR EACH ROW EXECUTE FUNCTION lab.fn_normalize_checksum();

CREATE TRIGGER trg_verification_normalize
    BEFORE INSERT ON lab.artifact_verification
    FOR EACH ROW EXECUTE FUNCTION lab.fn_normalize_checksum();

-- Canonicalize path separators on the way in, for the same reason checksums
-- are lower-cased: this lab runs on Windows, where MATLAB's fullfile() and
-- every native tool produce 'G-0421\sess01'. Rejecting that outright would be
-- defensible but hostile, and worse, a client that worked around it by storing
-- the backslash form somewhere else would silently create a second row for a
-- folder that already has one. Normalizing means one folder is one row no
-- matter which OS registered it. The path CHECKs still reject the things that
-- cannot be repaired by rewriting -- absolute paths, drive letters, and '..'
-- escapes -- and their backslash clause remains as a post-normalization
-- invariant.
CREATE OR REPLACE FUNCTION lab.fn_normalize_path() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.relative_path IS NOT NULL THEN
        NEW.relative_path := btrim(replace(NEW.relative_path, '\', '/'));
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_session_normalize_path
    BEFORE INSERT OR UPDATE ON lab.session
    FOR EACH ROW EXECUTE FUNCTION lab.fn_normalize_path();

CREATE TRIGGER trg_artifact_normalize_path
    BEFORE INSERT ON lab.artifact
    FOR EACH ROW EXECUTE FUNCTION lab.fn_normalize_path();

CREATE TRIGGER trg_project_artifact_normalize_path
    BEFORE INSERT OR UPDATE ON lab.project_artifact
    FOR EACH ROW EXECUTE FUNCTION lab.fn_normalize_path();

-- No two *active* artifacts may describe the same file. uq_artifact_file_original
-- covers original registrations only, because a correction necessarily repeats
-- the file identity of the row it supersedes; this covers the rest: a new row
-- is rejected when an active artifact other than the one it supersedes already
-- has the same (storage_root_id, relative_path, checksum). The trigger name
-- sorts after trg_artifact_normalize and trg_artifact_normalize_path, and
-- BEFORE triggers fire in name order, so the comparison sees the normalized
-- checksum and path.
CREATE OR REPLACE FUNCTION lab.fn_artifact_unique_active() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE dup uuid;
BEGIN
    SELECT a.artifact_id INTO dup
    FROM lab.artifact_active a
    WHERE a.storage_root_id = NEW.storage_root_id
      AND a.relative_path   = NEW.relative_path
      AND a.checksum        = NEW.checksum
      AND a.artifact_id IS DISTINCT FROM NEW.supersedes
    LIMIT 1;
    IF dup IS NOT NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'unique_violation',
            MESSAGE = format('active artifact %s already registers this file '
                             '(storage_root_id %s, relative_path %s, checksum %s)',
                             dup, NEW.storage_root_id, NEW.relative_path, NEW.checksum),
            HINT    = 'Supersede that artifact instead of registering the file again.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_artifact_unique_active
    BEFORE INSERT ON lab.artifact
    FOR EACH ROW EXECUTE FUNCTION lab.fn_artifact_unique_active();

-- The provenance graph must stay acyclic. An event that consumes an artifact
-- derived from its own output (most simply, the artifact it produced) makes
-- fn_artifact_lineage walk the loop to its depth cap and report a long,
-- wrong ancestry. Reject the edge if the event already appears among the
-- artifact's ancestors (bounded by the same depth cap of 64).
CREATE OR REPLACE FUNCTION lab.fn_forbid_provenance_cycle() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM lab.fn_artifact_lineage(NEW.artifact_id, 'up') l
               WHERE l.event_id = NEW.event_id) THEN
        RAISE EXCEPTION
          'event % cannot consume artifact %: the artifact derives from that '
          'event, so the edge would make the provenance graph cyclic',
          NEW.event_id, NEW.artifact_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_event_input_acyclic
    BEFORE INSERT ON lab.event_input
    FOR EACH ROW EXECUTE FUNCTION lab.fn_forbid_provenance_cycle();

-- The one canonical spelling of a tag: lower case, no surrounding whitespace,
-- and a bare tag (no colon) placed in the reserved 'tag' namespace. Nothing
-- else is rewritten -- a space, a second colon or an illegal character is
-- left for the CHECKs on lab.tag to reject. Every trigger and function that
-- takes a tag from a caller goes through this, so 'Auditory_Cortex',
-- 'auditory_cortex' and 'tag:auditory_cortex' are one tag everywhere.
CREATE OR REPLACE FUNCTION lab.fn_canonical_tag(p_tag text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN position(':' IN t) > 0 THEN t ELSE 'tag:' || t END
    FROM (SELECT lower(btrim(p_tag)) AS t) s;
$$;

-- Canonicalise tags on the way in. On lab.tag the namespace and value columns
-- are filled from the tag when the caller leaves them out (BEFORE triggers run
-- ahead of the NOT NULL checks, as for trg_event_fill_subject), or the tag
-- from them; tag_parts_ck then holds the three together.
CREATE OR REPLACE FUNCTION lab.fn_normalize_tag() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'tag' THEN
        NEW.namespace := lower(btrim(NEW.namespace));
        NEW.value     := lower(btrim(NEW.value));
        IF NEW.tag IS NULL AND NEW.namespace IS NOT NULL AND NEW.value IS NOT NULL THEN
            NEW.tag := NEW.namespace || ':' || NEW.value;
        END IF;
        NEW.tag       := lab.fn_canonical_tag(NEW.tag);
        NEW.namespace := coalesce(NEW.namespace, split_part(NEW.tag, ':', 1));
        NEW.value     := coalesce(NEW.value, substr(NEW.tag, position(':' IN NEW.tag) + 1));
    ELSE
        NEW.tag := lab.fn_canonical_tag(NEW.tag);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tag_normalize
    BEFORE INSERT ON lab.tag
    FOR EACH ROW EXECUTE FUNCTION lab.fn_normalize_tag();

CREATE TRIGGER trg_tag_assignment_normalize
    BEFORE INSERT ON lab.tag_assignment
    FOR EACH ROW EXECUTE FUNCTION lab.fn_normalize_tag();

-- A tag's identity never changes: the assignment log refers to it by name, so
-- renaming one would silently relabel every entity that carries it. Retire
-- it and register the replacement instead. Description and retired_at stay
-- editable.
CREATE OR REPLACE FUNCTION lab.fn_tag_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.tag IS DISTINCT FROM OLD.tag
       OR NEW.namespace IS DISTINCT FROM OLD.namespace
       OR NEW.value IS DISTINCT FROM OLD.value THEN
        RAISE EXCEPTION USING
            MESSAGE = format('tag %s cannot be renamed', OLD.tag),
            HINT    = 'Retire it (set retired_at) and register the new tag instead.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tag_guard
    BEFORE UPDATE ON lab.tag
    FOR EACH ROW EXECUTE FUNCTION lab.fn_tag_guard();

-- Anti-drift: a namespace's policy is what gives its existing assignments
-- their meaning, so once any tag of the namespace has been assigned,
-- mutability and cardinality are frozen and applies_to may only grow
-- (turning cohort mutable, or stage multi-valued, would retroactively change
-- what the log says). The reserved 'tag' namespace, where every bare tag
-- lands, is frozen from the start, open_vocabulary included. A namespace is
-- never renamed; description and (outside 'tag') open_vocabulary stay
-- editable.
CREATE OR REPLACE FUNCTION lab.fn_tag_namespace_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.namespace IS DISTINCT FROM OLD.namespace THEN
        RAISE EXCEPTION USING
            MESSAGE = format('tag namespace %s cannot be renamed', OLD.namespace),
            HINT    = 'Create a new namespace instead.';
    END IF;
    IF OLD.namespace = 'tag'
       AND (NEW.mutability IS DISTINCT FROM OLD.mutability
            OR NEW.cardinality IS DISTINCT FROM OLD.cardinality
            OR NEW.open_vocabulary IS DISTINCT FROM OLD.open_vocabulary
            OR NEW.applies_to IS DISTINCT FROM OLD.applies_to) THEN
        RAISE EXCEPTION USING
            MESSAGE = 'tag namespace tag is reserved for bare tags: its policy '
                      '(mutability, cardinality, open_vocabulary, applies_to) cannot change',
            HINT    = 'Only its description may be edited.';
    END IF;
    IF (NEW.mutability IS DISTINCT FROM OLD.mutability
        OR NEW.cardinality IS DISTINCT FROM OLD.cardinality
        OR NOT (NEW.applies_to @> OLD.applies_to))
       AND EXISTS (SELECT 1 FROM lab.tag_assignment ta
                   JOIN lab.tag t ON t.tag = ta.tag
                   WHERE t.namespace = OLD.namespace) THEN
        RAISE EXCEPTION USING
            MESSAGE = format('tag namespace %s is in use, so its policy is frozen: '
                             'mutability and cardinality cannot change and applies_to '
                             'may only grow', OLD.namespace),
            HINT    = 'Create a new namespace for a different policy.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tag_namespace_guard
    BEFORE UPDATE ON lab.tag_namespace
    FOR EACH ROW EXECUTE FUNCTION lab.fn_tag_namespace_guard();

-- Enforce the namespace policy on every assignment, however it is written
-- (lab.fn_tag, a raw INSERT from psql, MATLAB, the GUI), so all clients share
-- one semantics. Rejected:
--   * a tag that is not registered, or (for 'add') is retired;
--   * an entity kind outside the namespace's applies_to;
--   * 'add' of a tag already current on the entity, 'remove' of one that is
--     not, and any 'remove' in an immutable namespace;
--   * 'add' in a single-valued namespace while another of its tags is current.
-- The trigger name sorts after trg_tag_assignment_normalize, so it sees the
-- canonical tag. A row whose entity columns do not match its entity_kind, or
-- whose op is invalid, is passed through for the CHECKs to reject.
--
-- Like trg_artifact_unique_active, this is a trigger, not a constraint: two
-- concurrent transactions can each pass the single-valued check for the same
-- entity and both commit. Clients tag interactively, one entity at a time, so
-- this is a documented limitation rather than something worth a lock.
CREATE OR REPLACE FUNCTION lab.fn_tag_assignment_policy() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_ns      lab.tag_namespace%ROWTYPE;
    v_retired timestamptz;
    v_eid     text;
    v_current boolean;
    v_other   text;
BEGIN
    v_eid := CASE NEW.entity_kind
                 WHEN 'event'    THEN NEW.event_id::text
                 WHEN 'artifact' THEN NEW.artifact_id::text
                 WHEN 'subject'  THEN NEW.subject_id
                 WHEN 'session'  THEN NEW.session_id::text
                 WHEN 'project'  THEN NEW.project_id::text
             END;
    IF v_eid IS NULL OR NEW.op IS NULL OR NEW.op NOT IN ('add', 'remove') THEN
        RETURN NEW;
    END IF;

    SELECT t.retired_at INTO v_retired FROM lab.tag t WHERE t.tag = NEW.tag;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            MESSAGE = format('tag %s is not registered', NEW.tag),
            HINT    = 'Register it in lab.tag first, or use lab.fn_tag, which registers '
                      'new values of an open namespace.';
    END IF;
    SELECT n.* INTO v_ns FROM lab.tag_namespace n
    WHERE n.namespace = split_part(NEW.tag, ':', 1);
    IF NEW.op = 'add' AND v_retired IS NOT NULL THEN
        RAISE EXCEPTION 'tag % was retired at % and cannot be assigned', NEW.tag, v_retired;
    END IF;
    IF NOT (NEW.entity_kind = ANY (v_ns.applies_to)) THEN
        RAISE EXCEPTION 'tags of namespace % apply to % only, not to %',
            v_ns.namespace, array_to_string(v_ns.applies_to, ', '), NEW.entity_kind;
    END IF;

    v_current := EXISTS (SELECT 1 FROM lab.tag_current c
                         WHERE c.entity_kind = NEW.entity_kind
                           AND c.entity_id = v_eid AND c.tag = NEW.tag);

    IF NEW.op = 'remove' THEN
        IF v_ns.mutability = 'immutable' THEN
            RAISE EXCEPTION USING
                MESSAGE = format('tag namespace %s is immutable: %s cannot be removed '
                                 'from %s %s', v_ns.namespace, NEW.tag, NEW.entity_kind, v_eid),
                HINT    = 'An immutable tag is permanent once set.';
        END IF;
        IF NOT v_current THEN
            RAISE EXCEPTION '% % does not currently have tag %, so it cannot be removed',
                NEW.entity_kind, v_eid, NEW.tag;
        END IF;
        RETURN NEW;
    END IF;

    IF v_current THEN
        RAISE EXCEPTION '% % already has tag %', NEW.entity_kind, v_eid, NEW.tag;
    END IF;
    IF v_ns.cardinality = 'single' THEN
        SELECT c.tag INTO v_other FROM lab.tag_current c
        WHERE c.entity_kind = NEW.entity_kind AND c.entity_id = v_eid
          AND c.namespace = v_ns.namespace
        LIMIT 1;
        IF v_other IS NOT NULL THEN
            IF v_ns.mutability = 'immutable' THEN
                RAISE EXCEPTION USING
                    MESSAGE = format('%s %s already has %s, and namespace %s is immutable '
                                     'and single-valued', NEW.entity_kind, v_eid, v_other,
                                     v_ns.namespace),
                    HINT    = 'An immutable tag is permanent once set and cannot be replaced.';
            END IF;
            RAISE EXCEPTION USING
                MESSAGE = format('%s %s already has %s, and namespace %s allows one '
                                 'current tag', NEW.entity_kind, v_eid, v_other, v_ns.namespace),
                HINT    = 'Use lab.fn_tag, which replaces the current value in a mutable '
                          'namespace.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tag_assignment_policy
    BEFORE INSERT ON lab.tag_assignment
    FOR EACH ROW EXECUTE FUNCTION lab.fn_tag_assignment_policy();

-- Edit history for the mutable tables (see lab.row_history). SECURITY DEFINER
-- so that clients need no INSERT privilege on row_history and cannot write
-- forged history rows; the trigger arguments name the table's primary-key
-- columns.
CREATE OR REPLACE FUNCTION lab.fn_log_row_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_key jsonb := '{}'::jsonb;
    i     integer;
BEGIN
    IF TG_OP = 'UPDATE' AND to_jsonb(OLD) = to_jsonb(NEW) THEN
        RETURN NULL;    -- nothing changed, nothing to record
    END IF;
    FOR i IN 0 .. TG_NARGS - 1 LOOP
        v_key := v_key || jsonb_build_object(TG_ARGV[i], to_jsonb(OLD) -> TG_ARGV[i]);
    END LOOP;
    INSERT INTO lab.row_history (table_name, operation, row_key, old_row, new_row)
    VALUES (TG_TABLE_NAME, TG_OP, v_key, to_jsonb(OLD),
            CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(NEW) END);
    RETURN NULL;        -- AFTER trigger: the return value is ignored
END;
$$;

DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('person',             '''person_id'''),
        ('storage_root',       '''root_id'''),
        ('species',            '''code'''),
        ('probe',              '''probe_id'''),
        ('pipeline',           '''pipeline_id'''),
        ('event_type',         '''code'''),
        ('artifact_role',      '''code'''),
        ('acquisition_system', '''code'''),
        ('project',            '''project_id'''),
        ('project_member',     '''project_id'', ''person_id'''),
        ('project_artifact',   '''project_artifact_id'''),
        ('subject',            '''subject_id'''),
        ('session',            '''session_id'''),
        ('tag_namespace',      '''namespace'''),
        ('tag',                '''tag''')
    ) AS v(tbl, pk_args) LOOP
        EXECUTE format(
          'DROP TRIGGER IF EXISTS trg_history_%1$s ON lab.%1$s;', r.tbl);
        EXECUTE format(
          'CREATE TRIGGER trg_history_%1$s
             AFTER UPDATE OR DELETE ON lab.%1$s
             FOR EACH ROW EXECUTE FUNCTION lab.fn_log_row_change(%2$s);',
          r.tbl, r.pk_args);
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Identity maintenance
-- ---------------------------------------------------------------------------
-- `subject_id` is a human-typed natural key, and humans mistype it. Because it
-- is the natural key, correcting a typo means updating every FK that points at
-- it -- but those FKs land in append-only tables, so without an explicit path
-- a single mistyped animal ID is *permanently uncorrectable*: you can neither
-- update the referencing rows nor delete them, and creating the correctly-named
-- subject strands that animal's history under the wrong ID forever.
--
-- The FKs to lab.subject(subject_id) therefore declare ON UPDATE CASCADE, and
-- lab.fn_rename_subject performs the rename behind transaction-local flags
-- that fn_forbid_mutation honours for exactly this relabelling and nothing
-- else. Every rename is recorded in lab.maintenance_log.
CREATE OR REPLACE FUNCTION lab.fn_rename_subject(p_old text, p_new text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_old IS NULL OR p_new IS NULL OR btrim(p_new) = '' THEN
        RAISE EXCEPTION 'both the old and the new subject id are required';
    END IF;
    IF p_new <> btrim(p_new) THEN
        RAISE EXCEPTION 'new subject id % has leading/trailing whitespace', p_new;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM lab.subject WHERE subject_id = p_old) THEN
        RAISE EXCEPTION 'subject % does not exist', p_old;
    END IF;
    IF EXISTS (SELECT 1 FROM lab.subject WHERE subject_id = p_new) THEN
        RAISE EXCEPTION
          'subject % already exists; merging two subjects is not a rename', p_new;
    END IF;

    -- is_local => true: scoped to this transaction, reset automatically.
    -- fn_forbid_mutation checks every cascaded row change against the
    -- from/to pair, so the flag cannot be used to change anything else.
    PERFORM set_config('lab.maintenance', 'subject_rename', true);
    PERFORM set_config('lab.rename_from', p_old, true);
    PERFORM set_config('lab.rename_to', p_new, true);
    UPDATE lab.subject SET subject_id = p_new WHERE subject_id = p_old;
    PERFORM set_config('lab.maintenance', '', true);
    PERFORM set_config('lab.rename_from', '', true);
    PERFORM set_config('lab.rename_to', '', true);

    INSERT INTO lab.maintenance_log (operation, details)
    VALUES ('subject_rename',
            jsonb_build_object('from', p_old, 'to', p_new));
END;
$$;

-- Admin-only: this is the one function that can write to an append-only table.
REVOKE ALL ON FUNCTION lab.fn_rename_subject(text, text) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
CREATE VIEW lab.event_active AS
    SELECT e.* FROM lab.event e
    WHERE NOT EXISTS (
        SELECT 1 FROM lab.event s WHERE s.supersedes = e.event_id);

CREATE VIEW lab.artifact_active AS
    SELECT a.* FROM lab.artifact a
    WHERE NOT EXISTS (
        SELECT 1 FROM lab.artifact s WHERE s.supersedes = a.artifact_id);

-- Uniform edge list for graph tooling.
CREATE VIEW lab.provenance_edge AS
    SELECT 'produces'::text AS edge_type,
           'event'::text    AS from_kind, produced_by_event_id AS from_id,
           'artifact'::text AS to_kind,   artifact_id          AS to_id
    FROM lab.artifact
    UNION ALL
    SELECT 'consumes'::text,
           'artifact', artifact_id,
           'event',    event_id
    FROM lab.event_input;

-- Subject dimension enriched with latest active weight + endpoint status.
CREATE VIEW lab.subject_current AS
    SELECT s.*,
           w.weight_g    AS latest_weight_g,
           w.occurred_at AS latest_weight_at,
           (ep.event_id IS NOT NULL) AS is_endpointed,
           ep.occurred_at            AS endpoint_at
    FROM lab.subject s
    LEFT JOIN LATERAL (
        SELECT h.weight_g, e.occurred_at
        FROM lab.husbandry_event h
        JOIN lab.event e ON e.event_id = h.event_id
        WHERE e.subject_id = s.subject_id AND h.weight_g IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM lab.event x WHERE x.supersedes = e.event_id)
        -- event_id breaks ties: two weights recorded at the same instant would
        -- otherwise make this view return a different number run to run.
        ORDER BY e.occurred_at DESC, e.event_id DESC LIMIT 1
    ) w ON true
    LEFT JOIN LATERAL (
        SELECT e.event_id, e.occurred_at
        FROM lab.endpoint_event ee
        JOIN lab.event e ON e.event_id = ee.event_id
        WHERE e.subject_id = s.subject_id
          AND NOT EXISTS (SELECT 1 FROM lab.event x WHERE x.supersedes = e.event_id)
        ORDER BY e.occurred_at DESC LIMIT 1
    ) ep ON true;

-- Current tags: the latest assignment row per (entity, tag), kept when it is
-- an 'add'. entity_id is the entity's id as text, whatever its kind (computed
-- here, not stored; see lab.tag_assignment). display_tag is the tag as people
-- write it: a bare tag shows without its 'tag:' prefix, so every client
-- renders 'auditory_cortex' the same way without re-implementing the rule.
-- Ties on applied_at (lab.fn_tag writes a replacement's 'remove' and 'add' in
-- one transaction) are broken by assignment_id, i.e. insertion order.
CREATE VIEW lab.tag_current AS
    SELECT c.assignment_id, c.entity_kind, c.entity_id,
           c.event_id, c.artifact_id, c.subject_id, c.session_id, c.project_id,
           c.tag, t.namespace, t.value,
           CASE WHEN t.namespace = 'tag' THEN t.value ELSE t.tag END AS display_tag,
           c.note, c.applied_at, c.applied_by
    FROM (
        SELECT DISTINCT ON (x.entity_kind, x.entity_id, x.tag) x.*
        FROM (
            SELECT ta.*,
                   coalesce(ta.event_id::text, ta.artifact_id::text, ta.subject_id,
                            ta.session_id::text, ta.project_id::text) AS entity_id
            FROM lab.tag_assignment ta
        ) x
        ORDER BY x.entity_kind, x.entity_id, x.tag, x.applied_at DESC, x.assignment_id DESC
    ) c
    JOIN lab.tag t ON t.tag = c.tag
    WHERE c.op = 'add';

-- One row per entity that has at least one current tag. tags and display_tags
-- are sorted by tag and parallel: element i of one is element i of the other.
CREATE VIEW lab.entity_tags AS
    SELECT tc.entity_kind, tc.entity_id,
           array_agg(tc.tag ORDER BY tc.tag)         AS tags,
           array_agg(tc.display_tag ORDER BY tc.tag) AS display_tags
    FROM lab.tag_current tc
    GROUP BY tc.entity_kind, tc.entity_id;

-- ---------------------------------------------------------------------------
-- Recursive lineage function
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lab.fn_artifact_lineage(
    p_artifact_id uuid,
    p_direction   text DEFAULT 'up'   -- 'up' = ancestors, 'down' = descendants
) RETURNS TABLE (depth integer, event_id uuid, artifact_id uuid)
-- STABLE PARALLEL SAFE: read-only, so the planner may cache and parallelize it.
-- Without this it is treated as VOLATILE (the default) and re-executed per row
-- whenever it appears in a join.
LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
BEGIN
    IF p_direction NOT IN ('up','down') THEN
        RAISE EXCEPTION 'direction must be ''up'' or ''down'', got %', p_direction;
    END IF;

    IF p_direction = 'up' THEN
        RETURN QUERY
        WITH RECURSIVE lin AS (
            SELECT 0 AS depth, a.produced_by_event_id AS event_id, a.artifact_id
            FROM lab.artifact a
            WHERE a.artifact_id = p_artifact_id
          UNION
            SELECT l.depth + 1, ain.produced_by_event_id, ain.artifact_id
            FROM lin l
            JOIN lab.event_input ei  ON ei.event_id = l.event_id
            JOIN lab.artifact    ain ON ain.artifact_id = ei.artifact_id
            WHERE l.depth < 64
        )
        SELECT lin.depth, lin.event_id, lin.artifact_id FROM lin ORDER BY lin.depth;
    ELSE
        RETURN QUERY
        WITH RECURSIVE lin AS (
            SELECT 0 AS depth, NULL::uuid AS event_id, a.artifact_id
            FROM lab.artifact a
            WHERE a.artifact_id = p_artifact_id
          UNION
            SELECT l.depth + 1, ei.event_id, prod.artifact_id
            FROM lin l
            JOIN lab.event_input ei   ON ei.artifact_id = l.artifact_id
            JOIN lab.artifact    prod ON prod.produced_by_event_id = ei.event_id
            WHERE l.depth < 64
        )
        SELECT lin.depth, lin.event_id, lin.artifact_id FROM lin ORDER BY lin.depth;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Tag writes and filters
-- ---------------------------------------------------------------------------
-- Register a tag without applying it, and return its canonical spelling. A
-- tag that already exists is returned as is (retired or not). A new value is
-- created only in an open namespace; a closed one raises, listing the values
-- it has, so that a typo is caught instead of becoming vocabulary. Values of a
-- closed namespace are added deliberately with INSERT INTO lab.tag.
CREATE OR REPLACE FUNCTION lab.fn_register_tag(
    p_tag         text,
    p_description text DEFAULT NULL,
    p_by          uuid DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_tag  text := lab.fn_canonical_tag(p_tag);
    v_ns   text;
    v_open boolean;
BEGIN
    IF v_tag IS NULL THEN
        RAISE EXCEPTION 'a tag is required';
    END IF;
    IF EXISTS (SELECT 1 FROM lab.tag t WHERE t.tag = v_tag) THEN
        RETURN v_tag;
    END IF;
    v_ns := split_part(v_tag, ':', 1);
    SELECT n.open_vocabulary INTO v_open FROM lab.tag_namespace n WHERE n.namespace = v_ns;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            MESSAGE = format('tag namespace %s does not exist (tag %s)', v_ns, v_tag),
            HINT    = 'Create it in lab.tag_namespace first, or write the tag without a '
                      'colon to use the default tag namespace.';
    END IF;
    IF NOT v_open THEN
        RAISE EXCEPTION USING
            MESSAGE = format('tag %s is not registered, and namespace %s has a closed '
                             'vocabulary (its values: %s)', v_tag, v_ns,
                             (SELECT coalesce(string_agg(t.value, ', ' ORDER BY t.value), 'none')
                              FROM lab.tag t
                              WHERE t.namespace = v_ns AND t.retired_at IS NULL)),
            HINT    = 'Check the spelling. A genuinely new value is registered '
                      'deliberately with INSERT INTO lab.tag (tag) VALUES (...).';
    END IF;
    INSERT INTO lab.tag (tag, description, created_by)
    VALUES (v_tag, p_description, p_by)
    ON CONFLICT (tag) DO NOTHING;
    RETURN v_tag;
END;
$$;

-- The one write entry point for tagging, used by every client:
--
--     SELECT lab.fn_tag('artifact', '<artifact_id>', 'stage:sorted');
--     SELECT lab.fn_tag('subject', 'G-0421', 'cohort:a');
--     SELECT lab.fn_tag('event', '<event_id>', 'qc:fail', 'remove');
--
-- p_kind is event, artifact, subject, session or project and p_id that
-- entity's id as text. The tag is canonicalised (lab.fn_canonical_tag), and
-- for 'add' registered first if it is new to an open namespace. An 'add' in a
-- mutable single-valued namespace replaces the current value: the 'remove' of
-- the old tag and the 'add' of the new one are two log rows written by this
-- one call. Everything else -- duplicates, immutable namespaces, applies_to --
-- is left to trg_tag_assignment_policy, so a raw INSERT behaves the same.
-- Returns the assignment_id of the row for p_tag.
CREATE OR REPLACE FUNCTION lab.fn_tag(
    p_kind text,
    p_id   text,
    p_tag  text,
    p_op   text DEFAULT 'add',
    p_note text DEFAULT NULL,
    p_by   uuid DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_tag  text := lab.fn_canonical_tag(p_tag);
    v_uuid uuid;
    v_id   text;
    v_ns   lab.tag_namespace%ROWTYPE;
    v_old  text;
    v_out  bigint;
BEGIN
    IF p_kind IS NULL OR p_kind NOT IN ('event', 'artifact', 'subject', 'session', 'project') THEN
        RAISE EXCEPTION 'entity kind must be event, artifact, subject, session or project, got %',
            p_kind;
    END IF;
    IF p_op IS NULL OR p_op NOT IN ('add', 'remove') THEN
        RAISE EXCEPTION 'op must be ''add'' or ''remove'', got %', p_op;
    END IF;
    IF p_id IS NULL THEN
        RAISE EXCEPTION 'an entity id is required';
    END IF;
    IF p_kind <> 'subject' THEN
        v_uuid := p_id::uuid;
    END IF;
    v_id := coalesce(v_uuid::text, p_id);

    IF p_op = 'add' THEN
        v_tag := lab.fn_register_tag(v_tag, NULL, p_by);
        SELECT n.* INTO v_ns FROM lab.tag_namespace n
        WHERE n.namespace = split_part(v_tag, ':', 1);
        IF v_ns.cardinality = 'single' AND v_ns.mutability = 'mutable' THEN
            FOR v_old IN
                SELECT c.tag FROM lab.tag_current c
                WHERE c.entity_kind = p_kind AND c.entity_id = v_id
                  AND c.namespace = v_ns.namespace AND c.tag <> v_tag
            LOOP
                INSERT INTO lab.tag_assignment (entity_kind, event_id, artifact_id, subject_id,
                                                session_id, project_id, tag, op, note, applied_by)
                VALUES (p_kind,
                        CASE WHEN p_kind = 'event'    THEN v_uuid END,
                        CASE WHEN p_kind = 'artifact' THEN v_uuid END,
                        CASE WHEN p_kind = 'subject'  THEN v_id END,
                        CASE WHEN p_kind = 'session'  THEN v_uuid END,
                        CASE WHEN p_kind = 'project'  THEN v_uuid END,
                        v_old, 'remove', coalesce(p_note, format('replaced by %s', v_tag)), p_by);
            END LOOP;
        END IF;
    END IF;

    INSERT INTO lab.tag_assignment (entity_kind, event_id, artifact_id, subject_id,
                                    session_id, project_id, tag, op, note, applied_by)
    VALUES (p_kind,
            CASE WHEN p_kind = 'event'    THEN v_uuid END,
            CASE WHEN p_kind = 'artifact' THEN v_uuid END,
            CASE WHEN p_kind = 'subject'  THEN v_id END,
            CASE WHEN p_kind = 'session'  THEN v_uuid END,
            CASE WHEN p_kind = 'project'  THEN v_uuid END,
            v_tag, p_op, p_note, p_by)
    RETURNING assignment_id INTO v_out;
    RETURN v_out;
END;
$$;

-- The single definition of tag-filter semantics, used by the MATLAB getters,
-- the GUI and the MCP server: does entity (p_kind, p_id) carry
--   every tag in p_all, at least one tag in p_any, and no tag in p_none?
-- Each token is canonicalised like a stored tag (so a bare token means
-- 'tag:<token>'), and 'ns:*' matches any current tag in namespace ns. A NULL
-- or empty array is no constraint -- in particular an empty p_any does NOT
-- mean "matches nothing" -- and NULL or blank elements are ignored, so a
-- filter with no tokens at all matches every entity. An unknown p_kind has no
-- tags. Only current tags count (lab.tag_current).
--
--     WHERE lab.fn_tag_match('artifact', a.artifact_id::text,
--                            ARRAY['stage:raw', 'cohort:a'], NULL, ARRAY['qc:fail'])
CREATE OR REPLACE FUNCTION lab.fn_tag_match(
    p_kind text,
    p_id   text,
    p_all  text[] DEFAULT NULL,
    p_any  text[] DEFAULT NULL,
    p_none text[] DEFAULT NULL
) RETURNS boolean
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    WITH cur AS (
        SELECT c.tag, c.namespace
        FROM lab.tag_current c
        WHERE c.entity_kind = p_kind
          AND c.entity_id = CASE WHEN p_kind IN ('event', 'artifact', 'session', 'project')
                                 THEN p_id::uuid::text ELSE p_id END
    ), tok AS (
        SELECT l.list,
               EXISTS (SELECT 1 FROM cur
                       WHERE CASE WHEN l.t LIKE '%:*' THEN cur.namespace = left(l.t, -2)
                                  ELSE cur.tag = l.t END) AS hit
        FROM (SELECT v.list, lab.fn_canonical_tag(u.t) AS t
              FROM (VALUES ('all', p_all), ('any', p_any), ('none', p_none)) v(list, arr)
              CROSS JOIN LATERAL unnest(v.arr) u(t)
              WHERE btrim(u.t) <> '') l
    )
    SELECT NOT EXISTS (SELECT 1 FROM tok WHERE tok.list = 'all' AND NOT tok.hit)
       AND (NOT EXISTS (SELECT 1 FROM tok WHERE tok.list = 'any')
            OR EXISTS (SELECT 1 FROM tok WHERE tok.list = 'any' AND tok.hit))
       AND NOT EXISTS (SELECT 1 FROM tok WHERE tok.list = 'none' AND tok.hit);
$$;

-- Every entity of kind p_kind that lab.fn_tag_match accepts, as entity_id
-- text in id order. Untagged entities are candidates too, so a p_none-only
-- query finds them. For events and artifacts p_active_only (the default)
-- skips superseded rows, like the *_active views; it has no effect on the
-- other kinds.
CREATE OR REPLACE FUNCTION lab.fn_find_by_tags(
    p_kind        text,
    p_all         text[] DEFAULT NULL,
    p_any         text[] DEFAULT NULL,
    p_none        text[] DEFAULT NULL,
    p_active_only boolean DEFAULT true
) RETURNS TABLE (entity_id text)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_kind = 'event' THEN
        RETURN QUERY
        SELECT e.event_id::text FROM lab.event e
        WHERE (NOT p_active_only
               OR NOT EXISTS (SELECT 1 FROM lab.event s WHERE s.supersedes = e.event_id))
          AND lab.fn_tag_match('event', e.event_id::text, p_all, p_any, p_none)
        ORDER BY 1;
    ELSIF p_kind = 'artifact' THEN
        RETURN QUERY
        SELECT a.artifact_id::text FROM lab.artifact a
        WHERE (NOT p_active_only
               OR NOT EXISTS (SELECT 1 FROM lab.artifact s WHERE s.supersedes = a.artifact_id))
          AND lab.fn_tag_match('artifact', a.artifact_id::text, p_all, p_any, p_none)
        ORDER BY 1;
    ELSIF p_kind = 'subject' THEN
        RETURN QUERY
        SELECT s.subject_id FROM lab.subject s
        WHERE lab.fn_tag_match('subject', s.subject_id, p_all, p_any, p_none)
        ORDER BY 1;
    ELSIF p_kind = 'session' THEN
        RETURN QUERY
        SELECT s.session_id::text FROM lab.session s
        WHERE lab.fn_tag_match('session', s.session_id::text, p_all, p_any, p_none)
        ORDER BY 1;
    ELSIF p_kind = 'project' THEN
        RETURN QUERY
        SELECT p.project_id::text FROM lab.project p
        WHERE lab.fn_tag_match('project', p.project_id::text, p_all, p_any, p_none)
        ORDER BY 1;
    ELSE
        RAISE EXCEPTION 'entity kind must be event, artifact, subject, session or project, got %',
            p_kind;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Integrity report
-- ---------------------------------------------------------------------------
-- Class-table inheritance has one hole no declarative constraint can close:
-- the composite FK guarantees a detail row cannot attach to an event of the
-- wrong type, but nothing forces a detail row to exist at all. A client that
-- inserts the base event and then dies before the detail insert (or any writer
-- that skips the paired-insert transaction) leaves a typed event with no
-- payload, which reads as a real event everywhere and renders as a blank row.
--
-- PostgreSQL cannot express "every event has a detail row" as a constraint --
-- it would need to be deferred across two tables -- so it is a scheduled check
-- instead. Run it from cron / a monitoring job; an empty result means healthy.
--
--     SELECT * FROM lab.fn_check_integrity();
CREATE OR REPLACE FUNCTION lab.fn_check_integrity()
RETURNS TABLE (severity text, check_name text, subject text, detail text)
LANGUAGE sql STABLE AS $$
    -- Typed events whose detail row was never written.
    SELECT 'error', 'event_missing_detail', e.event_id::text,
           format('%s event has no row in lab.%s_event', e.event_type, e.event_type)
    FROM lab.event e
    WHERE e.event_id NOT IN (
        SELECT event_id FROM lab.birth_event
        UNION ALL SELECT event_id FROM lab.surgery_event
        UNION ALL SELECT event_id FROM lab.recording_event
        UNION ALL SELECT event_id FROM lab.behavior_event
        UNION ALL SELECT event_id FROM lab.husbandry_event
        UNION ALL SELECT event_id FROM lab.endpoint_event
        UNION ALL SELECT event_id FROM lab.histology_event
        UNION ALL SELECT event_id FROM lab.analysis_event)

    UNION ALL
    -- Non-analysis events with no subject. event_subject_required_ck rejects
    -- these on insert; this reports rows that predate the constraint in a
    -- database migrated from schema version 1 (where it may be NOT VALID).
    SELECT 'warning', 'event_missing_subject', e.event_id::text,
           format('%s event has no subject_id', e.event_type)
    FROM lab.event e
    WHERE e.subject_id IS NULL AND e.event_type <> 'analysis'

    UNION ALL
    -- Artifacts whose most recent integrity check failed.
    SELECT 'error', 'artifact_verification_failed', a.artifact_id::text,
           format('latest verification is %s (%s)', v.status, v.verified_at)
    FROM lab.artifact_active a
    JOIN LATERAL (
        SELECT status, verified_at FROM lab.artifact_verification av
        WHERE av.artifact_id = a.artifact_id
        ORDER BY av.verified_at DESC, av.verification_id DESC LIMIT 1
    ) v ON true
    WHERE v.status <> 'ok'

    UNION ALL
    -- Recorded before it happened: usually a timezone bug in a client.
    SELECT 'warning', 'event_recorded_before_occurred', e.event_id::text,
           format('occurred_at %s is after recorded_at %s', e.occurred_at, e.recorded_at)
    FROM lab.event e
    WHERE e.occurred_at > e.recorded_at + interval '1 day'

    UNION ALL
    -- Active artifacts that have never been checked at all.
    SELECT 'warning', 'artifact_never_verified', a.artifact_id::text,
           format('registered %s, no verification recorded', a.created_at)
    FROM lab.artifact_active a
    WHERE NOT EXISTS (SELECT 1 FROM lab.artifact_verification av
                      WHERE av.artifact_id = a.artifact_id)

    UNION ALL
    -- Active artifacts whose producing event has been corrected: the current
    -- version of the event lists no files while these stay attached to a row
    -- event_active hides. Supersede each such artifact with
    -- produced_by_event_id set to the current event (CarasLabDB.supersedeEvent
    -- does this as part of the correction).
    SELECT 'warning', 'artifact_producer_superseded', a.artifact_id::text,
           format('produced by event %s, which is superseded by event %s',
                  a.produced_by_event_id, s.event_id)
    FROM lab.artifact_active a
    JOIN lab.event s ON s.supersedes = a.produced_by_event_id

    UNION ALL
    -- Active corrections that dropped tags: an active event or artifact whose
    -- superseded predecessor has current tags that were never carried onto
    -- it. The MATLAB class copies the current tags forward when it inserts a
    -- correction; this catches corrections made some other way. A tag counts
    -- as carried when the successor has any assignment row for it (it may
    -- since have been removed on purpose) or, in a single-valued namespace,
    -- any row in that namespace (it has since been given another value). One
    -- row per successor, listing the missing tags.
    SELECT 'warning', 'tag_not_carried_forward', s.entity_id,
           format('supersedes %s %s, whose current tags were not carried forward: %s',
                  s.entity_kind, s.old_id, string_agg(o.tag, ', ' ORDER BY o.tag))
    FROM (SELECT 'event'::text AS entity_kind, e.event_id::text AS entity_id,
                 e.supersedes::text AS old_id
          FROM lab.event_active e WHERE e.supersedes IS NOT NULL
          UNION ALL
          SELECT 'artifact', a.artifact_id::text, a.supersedes::text
          FROM lab.artifact_active a WHERE a.supersedes IS NOT NULL) s
    JOIN lab.tag_current o ON o.entity_kind = s.entity_kind AND o.entity_id = s.old_id
    JOIN lab.tag_namespace n ON n.namespace = o.namespace
    WHERE NOT EXISTS (
        SELECT 1 FROM lab.tag_assignment x
        JOIN lab.tag xt ON xt.tag = x.tag
        WHERE x.entity_kind = s.entity_kind
          AND coalesce(x.event_id::text, x.artifact_id::text, x.subject_id,
                       x.session_id::text, x.project_id::text) = s.entity_id
          AND (x.tag = o.tag OR (n.cardinality = 'single' AND xt.namespace = o.namespace)))
    GROUP BY s.entity_kind, s.entity_id, s.old_id

    UNION ALL
    -- Two active artifacts at one path: the NAS file can only be one of them.
    SELECT 'warning', 'duplicate_active_path',
           a.storage_root_id || ':' || a.relative_path,
           format('%s active artifacts share this path', count(*))
    FROM lab.artifact_active a
    GROUP BY a.storage_root_id, a.relative_path
    HAVING count(*) > 1;
$$;

-- ---------------------------------------------------------------------------
-- Seed vocabulary
-- ---------------------------------------------------------------------------
-- ON CONFLICT DO NOTHING so that re-applying schema.sql to a database that
-- already has the vocabulary is not a hard failure on duplicate keys.
INSERT INTO lab.event_type (code, label) VALUES
    ('birth','Birth'), ('surgery','Surgery'), ('recording','Recording'),
    ('behavior','Behavior / training'), ('husbandry','Husbandry / health'),
    ('endpoint','Endpoint / euthanasia'), ('histology','Histology'),
    ('analysis','Analysis run')
ON CONFLICT (code) DO NOTHING;

INSERT INTO lab.artifact_role (code, label) VALUES
    ('raw','Raw acquisition'), ('spikes','Spike times'), ('lfp','LFP'),
    ('waveforms','Spike waveforms'), ('video','Behavioral video'),
    ('figure','Figure'), ('report','Report'), ('derived','Derived data'),
    ('other','Other')
ON CONFLICT (code) DO NOTHING;

INSERT INTO lab.acquisition_system (code, label) VALUES
    ('intan_rhx','Intan RHX'), ('open_ephys','Open Ephys')
ON CONFLICT (code) DO NOTHING;

INSERT INTO lab.species (code, common_name) VALUES
    ('meriones_unguiculatus','Mongolian gerbil'),
    ('mus_musculus','House mouse'),
    ('rattus_norvegicus','Norway rat')
ON CONFLICT (code) DO NOTHING;

-- Starting tag vocabulary; every row is editable by lab members, within the
-- limits of trg_tag_namespace_guard. 'tag' is the reserved home of bare tags
-- and its policy cannot change.
INSERT INTO lab.tag_namespace (namespace, description, mutability, cardinality,
                               open_vocabulary, applies_to) VALUES
    ('tag', 'Bare tags, written without a namespace (auditory_cortex is tag:auditory_cortex). '
            'Reserved: its policy cannot change.',
     'mutable', 'multi', true, ARRAY['event','artifact','subject','session','project']),
    ('stage', 'Where an artifact is in the processing pipeline; changes as it moves on. '
              'Distinct from artifact.role, which is what the file is and is fixed at '
              'registration.',
     'mutable', 'single', false, ARRAY['artifact']),
    ('qc', 'Quality-control outcome.',
     'mutable', 'single', false, ARRAY['artifact','event','session']),
    ('cohort', 'Experimental cohort; permanent once assigned.',
     'immutable', 'single', true, ARRAY['subject','session']),
    ('condition', 'Experimental condition or group; permanent once assigned.',
     'immutable', 'single', true, ARRAY['subject','session','event']),
    ('topic', 'Free-form subject matter.',
     'mutable', 'multi', true, ARRAY['event','artifact','subject','session','project'])
ON CONFLICT (namespace) DO NOTHING;

INSERT INTO lab.tag (tag, description) VALUES
    ('stage:raw',          'As acquired'),
    ('stage:preprocessed', 'Filtered / re-referenced / converted'),
    ('stage:sorted',       'Spike-sorted'),
    ('stage:curated',      'Sorting curated by hand'),
    ('stage:analyzed',     'Used in a finished analysis'),
    ('qc:pending',         'Not yet reviewed'),
    ('qc:pass',            'Passed review'),
    ('qc:fail',            'Failed review')
ON CONFLICT (tag) DO NOTHING;

-- The version this file installs. Keep in step with the newest script in
-- design_docs/migrations/ and with the client constants that check it
-- (CarasLabDB.SchemaVersionExpected, caraslabdb_mcp.db.SCHEMA_VERSION).
INSERT INTO lab.schema_version (version, description) VALUES
    (3, 'Fresh install from schema.sql')
ON CONFLICT (version) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Roles (deployment-specific -- intentionally not created here)
-- ---------------------------------------------------------------------------
-- This file creates no roles: role names, passwords and cluster membership are
-- per-deployment, and roles are cluster-wide rather than database-scoped.
-- design_docs/grants.sql sets up the two roles every deployment uses -- lab_rw
-- (read, insert, and update of the mutable descriptive tables) and lab_ro
-- (read only, for the dashboard server and the MCP server) -- and is applied
-- after this file:
--
--     psql -v ON_ERROR_STOP=1 -d lab -f design_docs/grants.sql
--
-- lab.fn_rename_subject is REVOKEd from PUBLIC above; grant EXECUTE on it only
-- to the administrator role that is expected to run identity maintenance.
