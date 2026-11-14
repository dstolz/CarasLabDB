-- ============================================================================
-- Lab Metadata System — schema DDL (PostgreSQL 14+)
-- ============================================================================
-- Canonical, runnable schema for the append-only event log, artifact index, and
-- provenance DAG. See design_docs/database-design.md for the ER diagram and the
-- table-by-table rationale. Apply against a fresh database, e.g.:
--
--     createdb lab && psql -d lab -f design_docs/schema.sql
--
-- This file installs the current schema version (see lab.schema_version
-- below). The database has not been launched, so the current schema is
-- version 1 and changes are made here directly. From launch on, every change
-- also gets a numbered upgrade script in design_docs/migrations/, and a fresh
-- install from this file and an upgraded database must end up with identical
-- schemas.
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
-- This file installs the current version directly; after launch, an existing
-- database is brought up to date by the scripts in design_docs/migrations/,
-- each of which inserts its own row. Clients (the CarasLabDB MATLAB class, the MCP server)
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
    created_at  timestamptz NOT NULL DEFAULT now(),
    -- The database login this person connects with, if they have one. It ties
    -- the two notions of "who": the person named in recorded_by / created_by
    -- and the login the database stamps in the *_login columns.
    -- lab.fn_current_person() resolves the connected login to its person, so
    -- clients need not ask who is typing. Only the administrator sets it
    -- (design_docs/grants.sql withholds the column from lab_rw): a member who
    -- could map a login to a person could sign entries as someone else.
    db_login    text,
    CONSTRAINT person_db_login_ck CHECK (
        db_login IS NULL OR (db_login <> '' AND db_login = btrim(db_login)))
);
CREATE UNIQUE INDEX uq_person_db_login
    ON lab.person (db_login) WHERE db_login IS NOT NULL;
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
    -- The database login that inserted the row, set by trg_event_stamp_login
    -- whatever the client sends. recorded_by is the person the client says
    -- made the entry; this is who was actually connected. NULL only for rows
    -- that predate pre-launch schema version 4.
    recorded_login text,
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
    -- Login that inserted the row (trg_artifact_stamp_login); see lab.event.
    created_login        text,
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
    -- Login that inserted the row (trg_artifact_verification_stamp_login).
    verified_login    text,
    -- 'mismatch' is the one status that is actionable, and it is unactionable
    -- without the checksum that was actually observed.
    CONSTRAINT verification_mismatch_ck CHECK (
        status <> 'mismatch' OR observed_checksum IS NOT NULL),
    CONSTRAINT verification_checksum_format_ck CHECK (
        observed_checksum IS NULL OR observed_checksum ~ '^[0-9a-f]+$')
);

-- ---------------------------------------------------------------------------
-- Retractions
-- ---------------------------------------------------------------------------
-- A correction replaces a statement of fact with a better one; a retraction
-- withdraws a row that should never have been written at all -- an event
-- entered twice, a file registered by mistake. Before this table the only way
-- to hide such a row was to invent a successor of the same type. Like every
-- other change to the log it is appended, never applied in place: one row per
-- retracted event or artifact, with the reason, and the *_active views leave
-- retracted rows out. A retraction is permanent; to bring a retracted row
-- back, supersede it (the successor is an ordinary active row).
CREATE TABLE lab.retraction (
    retraction_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity_kind     text NOT NULL,
    event_id        uuid REFERENCES lab.event(event_id),
    artifact_id     uuid REFERENCES lab.artifact(artifact_id),
    reason          text NOT NULL,
    retracted_at    timestamptz NOT NULL DEFAULT now(),
    retracted_by    uuid REFERENCES lab.person(person_id),
    -- Login that inserted the row (trg_retraction_stamp_login).
    retracted_login text,
    CONSTRAINT retraction_kind_ck CHECK (entity_kind IN ('event','artifact')),
    CONSTRAINT retraction_entity_ck CHECK (
            (entity_kind = 'event')    = (event_id IS NOT NULL)
        AND (entity_kind = 'artifact') = (artifact_id IS NOT NULL)),
    -- A retraction with no stated reason is indistinguishable from data loss.
    CONSTRAINT retraction_reason_ck CHECK (btrim(reason) <> '')
);
-- A row is retracted at most once.
CREATE UNIQUE INDEX uq_retraction_event
    ON lab.retraction (event_id) WHERE event_id IS NOT NULL;
CREATE UNIQUE INDEX uq_retraction_artifact
    ON lab.retraction (artifact_id) WHERE artifact_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- File disposition: what became of a registered file
-- ---------------------------------------------------------------------------
-- An artifact row states that a file with these bytes was produced at this
-- path. When the file is later overwritten (a step run again), moved (copied
-- elsewhere and the original removed) or deleted (a clean-up), that statement
-- is still true, and the analyses that read the old bytes must go on pointing
-- at the row. So the row is neither superseded -- a correction, which lineage
-- follows to the successor (fn_artifact_lineage, follow_corrections) -- nor
-- retracted, which says it was entered in error. A disposition records what
-- happened to the file instead, and lab.artifact_present leaves the row out.
--
-- Like a verification (lab.artifact_verification_latest), a disposition
-- belongs to the *file* -- (storage root, relative path, checksum) -- not to
-- one row: a correction of the artifact row describes the same file and
-- shares its dispositions. The latest disposition of a file, in insertion
-- order (disposition_id), is its state:
--   replaced  other bytes are at the path now (successor: the row for them,
--             at the same path, if it is registered)
--   moved     the bytes are elsewhere now (successor: the row there, required,
--             with the same checksum at another path)
--   deleted   the file is gone
--   restored  the same bytes are back at the path (after any of the above)
-- trg_artifact_disposition_policy keeps the sequence meaningful: a file is
-- disposed of only while present, restored only while disposed of.
CREATE TABLE lab.artifact_disposition (
    disposition_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    artifact_id           uuid NOT NULL REFERENCES lab.artifact(artifact_id),
    disposition           text NOT NULL,
    successor_artifact_id uuid REFERENCES lab.artifact(artifact_id),
    occurred_at           timestamptz NOT NULL,      -- when it happened to the file
    recorded_at           timestamptz NOT NULL DEFAULT now(),
    recorded_by           uuid REFERENCES lab.person(person_id),
    note                  text,
    attributes            jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Login that inserted the row (trg_artifact_disposition_stamp_login).
    recorded_login        text,
    CONSTRAINT disposition_kind_ck CHECK (
        disposition IN ('replaced', 'moved', 'deleted', 'restored')),
    CONSTRAINT disposition_successor_ck CHECK (
        CASE disposition
            WHEN 'moved'    THEN successor_artifact_id IS NOT NULL
            WHEN 'deleted'  THEN successor_artifact_id IS NULL
            WHEN 'restored' THEN successor_artifact_id IS NULL
            ELSE true
        END),
    CONSTRAINT disposition_not_self_ck CHECK (successor_artifact_id <> artifact_id),
    CONSTRAINT disposition_attributes_object_ck CHECK (jsonb_typeof(attributes) = 'object')
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
    -- Login that inserted the row (trg_tag_assignment_stamp_login).
    applied_login text,
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
-- User-defined variables
-- ---------------------------------------------------------------------------
-- Named values that lab members attach to events, artifacts, subjects,
-- sessions and projects -- 'probe depth' = 1200 um on a recording session,
-- 'housing' = 'pair' on an animal -- for the measurements and settings no
-- fixed column anticipates. A "dataset" here is a session (the recording
-- folder) or an artifact (one file); both can carry variables.
--
-- Same shape as tags, for the same reasons. The definition (lab.variable) is
-- mutable reference data, edited in place and recorded in row_history. The
-- values are not: lab.variable_value is an append-only log, one row each time
-- a value is set or unset, and an entity's current values are derived from
-- it by lab.variable_current. A user "updates" a variable by setting it
-- again; every earlier value stays in the log with who set it and when.
-- Clients write through lab.fn_set_variable.

-- One row per variable. `name` is the key people query by ('probe depth'):
-- lower case, words of letters, digits, '_' or '-' separated by single
-- spaces. lab.fn_canonical_variable folds case and whitespace on the way in;
-- anything else malformed is rejected by the CHECK, never rewritten. `label`
-- is the common name shown to people ('Probe Depth').
--
-- value_type and units are part of what every stored value means, so
-- trg_variable_guard freezes them once the variable has a value: 1200
-- recorded as micrometres must not become 1200 millimetres because someone
-- edited the definition. For different units, define another variable.
CREATE TABLE lab.variable (
    name        text PRIMARY KEY,
    label       text NOT NULL,
    description text,
    units       text,                        -- 'um', 'g', 'dB SPL'; NULL = none
    value_type  text NOT NULL,               -- 'number' | 'text'
    applies_to  text[] NOT NULL
                    DEFAULT ARRAY['event','artifact','subject','session','project'],
    retired_at  timestamptz,                 -- lab.fn_set_variable refuses it once set
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid REFERENCES lab.person(person_id),
    CONSTRAINT variable_name_ck CHECK (
        name ~ '^[a-z][a-z0-9_-]*( [a-z0-9_-]+)*$' AND length(name) <= 63),
    CONSTRAINT variable_label_ck CHECK (btrim(label) <> ''),
    CONSTRAINT variable_units_ck CHECK (units IS NULL OR (units <> '' AND units = btrim(units))),
    CONSTRAINT variable_value_type_ck CHECK (value_type IN ('number','text')),
    CONSTRAINT variable_applies_to_ck CHECK (
        applies_to <@ ARRAY['event','artifact','subject','session','project']
        AND cardinality(applies_to) > 0)
);

-- The value log: one row per value set ('set') or cleared ('unset') on an
-- entity. Exactly the id column matching entity_kind is set, and a 'set' row
-- carries exactly one of value_num / value_text, whichever the variable's
-- value_type calls for (trg_variable_value_policy). Numbers are numeric, not
-- floating point: the digits a user typed are the digits stored. set_at is
-- when the value was set, the "last updated" time of a current value.
--
-- No stored entity_id column, for the reason given at lab.tag_assignment: a
-- subject rename cascades into subject_id here, and fn_forbid_mutation admits
-- that cascade only if every other column is unchanged.
CREATE TABLE lab.variable_value (
    value_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity_kind text NOT NULL,
    event_id    uuid REFERENCES lab.event(event_id),
    artifact_id uuid REFERENCES lab.artifact(artifact_id),
    subject_id  text REFERENCES lab.subject(subject_id) ON UPDATE CASCADE,
    session_id  uuid REFERENCES lab.session(session_id),
    project_id  uuid REFERENCES lab.project(project_id),
    variable    text NOT NULL REFERENCES lab.variable(name),
    op          text NOT NULL DEFAULT 'set',
    value_num   numeric,
    value_text  text,
    note        text,
    set_at      timestamptz NOT NULL DEFAULT now(),
    set_by      uuid REFERENCES lab.person(person_id),
    -- Login that inserted the row (trg_variable_value_stamp_login).
    set_login   text,
    CONSTRAINT variable_value_kind_ck CHECK (
        entity_kind IN ('event','artifact','subject','session','project')),
    CONSTRAINT variable_value_op_ck CHECK (op IN ('set','unset')),
    CONSTRAINT variable_value_entity_ck CHECK (
            (entity_kind = 'event')    = (event_id IS NOT NULL)
        AND (entity_kind = 'artifact') = (artifact_id IS NOT NULL)
        AND (entity_kind = 'subject')  = (subject_id IS NOT NULL)
        AND (entity_kind = 'session')  = (session_id IS NOT NULL)
        AND (entity_kind = 'project')  = (project_id IS NOT NULL)),
    -- A single value: one number or one string when set, neither when unset.
    CONSTRAINT variable_value_single_ck CHECK (
        num_nonnulls(value_num, value_text) = CASE op WHEN 'set' THEN 1 ELSE 0 END),
    -- NaN and the infinities are not measurements; a blank string is "unset".
    CONSTRAINT variable_value_number_ck CHECK (
        value_num IS NULL
        OR value_num NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
    CONSTRAINT variable_value_text_ck CHECK (value_text IS NULL OR btrim(value_text) <> '')
);

-- ---------------------------------------------------------------------------
-- Forms: templates, subject forms and the entries made on them
-- ---------------------------------------------------------------------------
-- A data-entry form for one session of one subject (web/forms/, see
-- design_docs/forms.md). Three layers, each in the shape the rest of the
-- schema already uses:
--
--   * A *template* (lab.form) is a named, reusable form. Its identity is
--     mutable reference data, like a variable definition; its content is a
--     series of immutable versions (lab.form_version). Publishing an edited
--     template appends a version, so an entry made on version 3 can always be
--     read with the fields version 3 had.
--   * A *subject form* (lab.subject_form) is a template put to use for one
--     subject in one project -- by default the subject's own project, but a
--     subject used in another project has its forms there too. It is pinned
--     to the template version new entries use.
--   * An *entry* is an event of type 'observation' (lab.observation_event):
--     what was observed in one session, at event.occurred_at, under a free
--     session label. Its field values are variables on the event, so they
--     are typed, unit-checked, append-only and login-stamped like every other
--     variable, a correction carries them forward, and lab.fn_retract
--     withdraws the entry. The entry's note is the reserved text variable
--     'entry note' on the same event, which can be changed later without a
--     correction.
--
-- Clients write through lab.fn_publish_form, lab.fn_add_subject_form,
-- lab.fn_record_observation and lab.fn_set_entry_note.

-- One row per template. `name` follows the variable-name rule (lower case,
-- words separated by single spaces) and never changes: the versions and the
-- subject forms refer to it.
CREATE TABLE lab.form (
    name        text PRIMARY KEY,
    label       text NOT NULL,
    description text,
    retired_at  timestamptz,                 -- hidden from the template picker once set
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid REFERENCES lab.person(person_id),
    CONSTRAINT form_name_ck CHECK (
        name ~ '^[a-z][a-z0-9_-]*( [a-z0-9_-]+)*$' AND length(name) <= 63),
    CONSTRAINT form_label_ck CHECK (btrim(label) <> '')
);

-- The template's content, one row per published version, append-only.
-- trg_form_version_policy numbers the versions 1, 2, 3 ... per template and
-- refuses a definition that lab.fn_form_definition_problems finds fault with,
-- however the row is written. created_login is stamped by
-- trg_form_version_stamp_login.
CREATE TABLE lab.form_version (
    form_name     text NOT NULL REFERENCES lab.form(name),
    version       integer NOT NULL CHECK (version > 0),
    definition    jsonb NOT NULL,
    note          text,                      -- what changed in this version
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid REFERENCES lab.person(person_id),
    created_login text,
    PRIMARY KEY (form_name, version),
    CONSTRAINT form_version_definition_ck CHECK (jsonb_typeof(definition) = 'object')
);

-- A template in use for one subject in one project. Mutable (form_version,
-- notes and retired_at are edited in place and recorded in row_history), but
-- what it *is* -- which subject, which project, which template -- never
-- changes (trg_subject_form_guard): the entries made on it refer to it. A
-- subject has a template at most once per project. form_version is the
-- version new entries use; moving it to a newer version is an explicit step.
CREATE TABLE lab.subject_form (
    subject_form_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_id      text NOT NULL REFERENCES lab.subject(subject_id) ON UPDATE CASCADE,
    project_id      uuid NOT NULL REFERENCES lab.project(project_id),
    form_name       text NOT NULL,
    form_version    integer NOT NULL,
    notes           text,
    retired_at      timestamptz,             -- no longer offered for new entries
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid REFERENCES lab.person(person_id),
    UNIQUE (subject_id, project_id, form_name),
    UNIQUE (subject_form_id, form_name),     -- FK target for lab.observation_event
    FOREIGN KEY (form_name, form_version) REFERENCES lab.form_version(form_name, version)
);

-- Detail row of an 'observation' event: one entry on a subject form. The
-- event row holds when (occurred_at), about whom (subject_id) and who
-- recorded it; this holds which form and version it was made on and the
-- session's label, which is free text (a session here need not be a
-- lab.session folder; event.session_id links one when there is one).
-- (subject_form_id, form_name) makes the entry's template the subject form's;
-- trg_observation_event_policy makes its subject the subject form's.
CREATE TABLE lab.observation_event (
    event_id        uuid PRIMARY KEY,
    event_type      text NOT NULL DEFAULT 'observation' CHECK (event_type = 'observation'),
    subject_form_id uuid NOT NULL,
    form_name       text NOT NULL,
    form_version    integer NOT NULL,
    session_label   text NOT NULL CHECK (session_label <> '' AND session_label = btrim(session_label)),
    FOREIGN KEY (event_id, event_type)
        REFERENCES lab.event(event_id, event_type),
    FOREIGN KEY (subject_form_id, form_name)
        REFERENCES lab.subject_form(subject_form_id, form_name),
    FOREIGN KEY (form_name, form_version)
        REFERENCES lab.form_version(form_name, version)
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
-- Read the same way as the verifications: latest disposition per file.
CREATE INDEX ix_artifact_disposition_artifact
    ON lab.artifact_disposition (artifact_id, disposition_id DESC);

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

-- Variable values are read the same two ways as tag assignments: per entity
-- ("this session's variables") and per variable ("every probe depth").
CREATE INDEX ix_variable_value_entity
    ON lab.variable_value (entity_kind, coalesce(event_id::text, artifact_id::text, subject_id,
                                                 session_id::text, project_id::text));
CREATE INDEX ix_variable_value_variable ON lab.variable_value (variable, entity_kind);
CREATE INDEX ix_variable_value_event    ON lab.variable_value (event_id);
CREATE INDEX ix_variable_value_artifact ON lab.variable_value (artifact_id);
CREATE INDEX ix_variable_value_subject  ON lab.variable_value (subject_id);
CREATE INDEX ix_variable_value_session  ON lab.variable_value (session_id);
CREATE INDEX ix_variable_value_project  ON lab.variable_value (project_id);

-- A subject's forms ("this animal's forms in this project") and a form's
-- entries ("every entry on this subject form").
CREATE INDEX ix_subject_form_project          ON lab.subject_form (project_id);
CREATE INDEX ix_subject_form_form             ON lab.subject_form (form_name, form_version);
CREATE INDEX ix_observation_event_subject_form ON lab.observation_event (subject_form_id);
CREATE INDEX ix_observation_event_form        ON lab.observation_event (form_name, form_version);

-- ---------------------------------------------------------------------------
-- Immutability + validation triggers
-- ---------------------------------------------------------------------------
-- Every trigger function pins its search_path (SET search_path = pg_catalog,
-- pg_temp). This is a security boundary, not tidiness: a subject rename
-- cascades through the ON UPDATE CASCADE foreign keys, and PostgreSQL runs a
-- cascaded UPDATE -- and so the triggers it fires -- as the *owner* of the
-- referencing table, while names inside an unpinned function are resolved
-- with the *caller's* search path. pg_temp is searched first for type names,
-- so a client that could start the cascade and had created a temporary type
-- called jsonb would have had its own code run with the owner's privileges.
-- With the path pinned, every unqualified name resolves in pg_catalog, and
-- every lab object is written schema-qualified.
CREATE OR REPLACE FUNCTION lab.fn_forbid_mutation() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
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
                -- IS DISTINCT FROM, not <>: a NULL old value (an analysis
                -- event with no subject, an unknown dam) must not slip
                -- through as "neither equal nor unequal" and be filled in.
                IF (v_old -> c) IS DISTINCT FROM (v_new -> c)
                   AND ((v_old ->> c) IS DISTINCT FROM v_from
                        OR (v_new ->> c) IS DISTINCT FROM v_to) THEN
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
                         'row_history', 'schema_version', 'tag_assignment',
                         'variable_value', 'retraction', 'artifact_disposition') THEN
        RAISE EXCEPTION
          '% on %.% is not allowed: this table is an append-only log.',
          TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
    END IF;

    IF TG_TABLE_NAME = 'form_version' THEN
        RAISE EXCEPTION USING
            MESSAGE = format('%s on lab.form_version is not allowed: a published form version '
                             'is never changed.', TG_OP),
            HINT    = 'Publish a new version instead (lab.fn_publish_form).';
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
        'observation_event',
        'artifact','event_input',
        'artifact_verification','maintenance_log','row_history','schema_version',
        'tag_assignment','variable_value','retraction','artifact_disposition',
        'form_version'
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
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
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
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
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
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
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
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
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
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
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
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE dup uuid;
BEGIN
    -- Serialise registrations of the same file: without the lock two
    -- concurrent transactions each see no duplicate and both commit. The lock
    -- is released at the end of the transaction; the check below then runs
    -- on a fresh snapshot and sees what the other transaction committed.
    PERFORM pg_advisory_xact_lock(hashtextextended(
        concat_ws(':', 'lab.artifact', NEW.storage_root_id, NEW.relative_path, NEW.checksum), 0));
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
-- artifact's ancestors (bounded by the same depth cap of 64) -- both in the
-- graph as recorded and in the graph with every node resolved to its current
-- version, which is the one lineage queries walk by default: a correction can
-- close a loop there that the recorded rows do not contain.
--
-- Edge inserts are serialised by an advisory lock held to the end of the
-- transaction, so two concurrent transactions cannot each add one half of a
-- loop. Edges are written in short transactions (one event and its inputs).
CREATE OR REPLACE FUNCTION lab.fn_forbid_provenance_cycle() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('lab.event_input', 0));
    IF EXISTS (SELECT 1 FROM lab.fn_artifact_lineage(NEW.artifact_id, 'up', false) l
               WHERE l.event_id = NEW.event_id)
       OR EXISTS (SELECT 1 FROM lab.fn_artifact_lineage(NEW.artifact_id, 'up', true) l
                  WHERE l.event_id = lab.fn_event_current(NEW.event_id)) THEN
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
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
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
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
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
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
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
-- Like trg_artifact_unique_active, this is a trigger, not a constraint, so the
-- checks are made race-free with an advisory lock on (entity, namespace) held
-- to the end of the transaction: without it two concurrent transactions each
-- pass the single-valued check and both commit, which in an immutable
-- namespace (two cohorts on one animal) can never be repaired.
-- lab.fn_check_integrity reports any such state as tag_cardinality_violation.
CREATE OR REPLACE FUNCTION lab.fn_tag_assignment_policy() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
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

    -- One writer at a time per (entity, namespace); every check below then
    -- runs on a snapshot that includes what the previous writer committed.
    PERFORM pg_advisory_xact_lock(hashtextextended(
        concat_ws(':', 'lab.tag', NEW.entity_kind, v_eid, split_part(NEW.tag, ':', 1)), 0));

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

-- An artifact must be filed under the same animal and session as the event
-- that produced it. Either side may leave subject or session unset (a
-- cross-animal analysis has no subject; a file may be registered without a
-- session), but where both name one they must agree -- otherwise the file is
-- listed under animal A while its recording is about animal B, the same
-- per-subject corruption event_session_subject_fk exists to prevent. It also
-- makes a correction that moves an event to another animal or session carry
-- its files along: re-pointing them unchanged is rejected here.
-- lab.fn_check_integrity reports existing rows as artifact_event_mismatch.
CREATE OR REPLACE FUNCTION lab.fn_artifact_matches_event() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_subject text;
    v_session uuid;
BEGIN
    SELECT e.subject_id, e.session_id INTO v_subject, v_session
    FROM lab.event e WHERE e.event_id = NEW.produced_by_event_id;
    IF NEW.subject_id IS NOT NULL AND v_subject IS NOT NULL
       AND NEW.subject_id <> v_subject THEN
        RAISE EXCEPTION USING
            MESSAGE = format('artifact is filed under subject %s, but the event that produced '
                             'it (%s) is about subject %s',
                             NEW.subject_id, NEW.produced_by_event_id, v_subject),
            HINT    = 'File the artifact under the producing event''s subject.';
    END IF;
    IF NEW.session_id IS NOT NULL AND v_session IS NOT NULL
       AND NEW.session_id <> v_session THEN
        RAISE EXCEPTION USING
            MESSAGE = format('artifact is filed under session %s, but the event that produced '
                             'it (%s) belongs to session %s',
                             NEW.session_id, NEW.produced_by_event_id, v_session),
            HINT    = 'File the artifact under the producing event''s session.';
    END IF;
    RETURN NEW;
END;
$$;

-- The name sorts after trg_artifact_fill_subject, so the comparison sees the
-- subject that trigger derives from the session.
CREATE TRIGGER trg_artifact_matches_event
    BEFORE INSERT ON lab.artifact
    FOR EACH ROW EXECUTE FUNCTION lab.fn_artifact_matches_event();

-- Record the database login on every row of the append-only logs, whatever
-- the client sends. recorded_by / created_by / verified_by / applied_by /
-- retracted_by name the *person* and are supplied by the client; the *_login
-- columns are the login that was actually connected, which with per-person
-- logins identifies the writer without client cooperation -- the same
-- guarantee row_history gives for the mutable tables. session_user, not
-- current_user: SET ROLE does not change it.
--
-- Where the client names no person, the person mapped to the login
-- (lab.person.db_login, see lab.fn_current_person) is filled in, so a script
-- or a psql session that sends nothing is still attributed. A person the
-- client does name is left alone: entering a record on someone's behalf is
-- legitimate, and the login column says who typed it. lab.variable_value is
-- stamped but not defaulted here -- lab.fn_set_variable does that -- because
-- a carried-forward value must keep the set_by it was carried with, NULL
-- included.
CREATE OR REPLACE FUNCTION lab.fn_stamp_login() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF TG_TABLE_NAME = 'event' THEN
        NEW.recorded_login := session_user;
        NEW.recorded_by := coalesce(NEW.recorded_by, lab.fn_current_person());
    ELSIF TG_TABLE_NAME = 'artifact' THEN
        NEW.created_login := session_user;
        NEW.created_by := coalesce(NEW.created_by, lab.fn_current_person());
    ELSIF TG_TABLE_NAME = 'artifact_verification' THEN
        NEW.verified_login := session_user;
        NEW.verified_by := coalesce(NEW.verified_by, lab.fn_current_person());
    ELSIF TG_TABLE_NAME = 'tag_assignment' THEN
        NEW.applied_login := session_user;
        NEW.applied_by := coalesce(NEW.applied_by, lab.fn_current_person());
    ELSIF TG_TABLE_NAME = 'retraction' THEN
        NEW.retracted_login := session_user;
        NEW.retracted_by := coalesce(NEW.retracted_by, lab.fn_current_person());
    ELSIF TG_TABLE_NAME = 'artifact_disposition' THEN
        NEW.recorded_login := session_user;
        NEW.recorded_by := coalesce(NEW.recorded_by, lab.fn_current_person());
    ELSIF TG_TABLE_NAME = 'variable_value' THEN
        NEW.set_login := session_user;
    ELSIF TG_TABLE_NAME = 'form_version' THEN
        NEW.created_login := session_user;
        NEW.created_by := coalesce(NEW.created_by, lab.fn_current_person());
    ELSE
        RAISE EXCEPTION 'lab.fn_stamp_login is not defined for table %', TG_TABLE_NAME;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_event_stamp_login
    BEFORE INSERT ON lab.event
    FOR EACH ROW EXECUTE FUNCTION lab.fn_stamp_login();

CREATE TRIGGER trg_artifact_stamp_login
    BEFORE INSERT ON lab.artifact
    FOR EACH ROW EXECUTE FUNCTION lab.fn_stamp_login();

CREATE TRIGGER trg_artifact_verification_stamp_login
    BEFORE INSERT ON lab.artifact_verification
    FOR EACH ROW EXECUTE FUNCTION lab.fn_stamp_login();

CREATE TRIGGER trg_tag_assignment_stamp_login
    BEFORE INSERT ON lab.tag_assignment
    FOR EACH ROW EXECUTE FUNCTION lab.fn_stamp_login();

CREATE TRIGGER trg_retraction_stamp_login
    BEFORE INSERT ON lab.retraction
    FOR EACH ROW EXECUTE FUNCTION lab.fn_stamp_login();

CREATE TRIGGER trg_artifact_disposition_stamp_login
    BEFORE INSERT ON lab.artifact_disposition
    FOR EACH ROW EXECUTE FUNCTION lab.fn_stamp_login();

CREATE TRIGGER trg_variable_value_stamp_login
    BEFORE INSERT ON lab.variable_value
    FOR EACH ROW EXECUTE FUNCTION lab.fn_stamp_login();

CREATE TRIGGER trg_form_version_stamp_login
    BEFORE INSERT ON lab.form_version
    FOR EACH ROW EXECUTE FUNCTION lab.fn_stamp_login();

-- subject_id is the natural key every append-only table refers to, so only a
-- role that may run lab.fn_rename_subject may change it. Without this, any
-- client holding UPDATE on lab.subject could set the lab.maintenance flags
-- by hand and rename an animal with a plain UPDATE -- no maintenance_log
-- entry, and the cascade running as the table owner. design_docs/grants.sql
-- also withholds UPDATE on the column from lab_rw; this holds even where the
-- grants were applied differently.
CREATE OR REPLACE FUNCTION lab.fn_subject_id_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NEW.subject_id IS DISTINCT FROM OLD.subject_id
       AND NOT has_function_privilege(current_user, 'lab.fn_rename_subject(text, text)',
                                      'EXECUTE') THEN
        RAISE EXCEPTION USING
            MESSAGE = format('subject id %s cannot be changed by %s', OLD.subject_id, current_user),
            HINT    = 'Renaming a subject is identity maintenance: ask the lab''s database '
                      'administrator to run lab.fn_rename_subject.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_subject_id_guard
    BEFORE UPDATE ON lab.subject
    FOR EACH ROW EXECUTE FUNCTION lab.fn_subject_id_guard();

-- The one canonical spelling of a variable name: lower case, with every run
-- of whitespace (leading, trailing, internal) reduced to nothing or to one
-- space. 'Probe  Depth ' and 'probe depth' are one variable everywhere.
-- Nothing else is rewritten; variable_name_ck rejects the rest.
CREATE OR REPLACE FUNCTION lab.fn_canonical_variable(p_name text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT btrim(regexp_replace(lower(p_name), '\s+', ' ', 'g'));
$$;

-- Canonicalise a variable definition on the way in: the name, a label that
-- defaults to the name, and blank units stored as NULL.
CREATE OR REPLACE FUNCTION lab.fn_normalize_variable() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    NEW.name  := lab.fn_canonical_variable(NEW.name);
    NEW.label := coalesce(nullif(btrim(NEW.label), ''), NEW.name);
    NEW.units := nullif(btrim(NEW.units), '');
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_variable_normalize
    BEFORE INSERT ON lab.variable
    FOR EACH ROW EXECUTE FUNCTION lab.fn_normalize_variable();

-- A variable's name is what the value log refers to, and its value type and
-- units are what every stored value means: the name never changes, and once
-- the variable has a value its type and units are frozen and applies_to may
-- only grow. Label, description and retired_at stay editable.
CREATE OR REPLACE FUNCTION lab.fn_variable_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NEW.name IS DISTINCT FROM OLD.name THEN
        RAISE EXCEPTION USING
            MESSAGE = format('variable %s cannot be renamed', OLD.name),
            HINT    = 'Retire it (set retired_at) and define the new variable instead.';
    END IF;
    NEW.units := nullif(btrim(NEW.units), '');
    IF (NEW.value_type IS DISTINCT FROM OLD.value_type
        OR NEW.units IS DISTINCT FROM OLD.units
        OR NOT (NEW.applies_to @> OLD.applies_to))
       AND EXISTS (SELECT 1 FROM lab.variable_value v WHERE v.variable = OLD.name) THEN
        RAISE EXCEPTION USING
            MESSAGE = format('variable %s has values, so its value type and units are frozen '
                             'and applies_to may only grow', OLD.name),
            HINT    = 'Define a new variable for different units and set the converted values.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_variable_guard
    BEFORE UPDATE ON lab.variable
    FOR EACH ROW EXECUTE FUNCTION lab.fn_variable_guard();

-- Enforce the definition on every value row, however it is written
-- (lab.fn_set_variable, a raw INSERT, MATLAB, the GUI). Rejected: a variable
-- that is not defined; an entity kind outside its applies_to; a number where
-- the variable holds text or the reverse; an 'unset' of a variable the
-- entity has no current value for. A row whose entity columns do not match
-- its entity_kind, or whose op is invalid, is passed through for the CHECKs
-- to reject. Whether a retired variable takes new values is decided by
-- lab.fn_set_variable, not here, so that a correction can still carry a
-- retired variable's value forward. Writers are serialised per (entity,
-- variable) by an advisory lock held to the end of the transaction.
CREATE OR REPLACE FUNCTION lab.fn_variable_value_policy() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_var lab.variable%ROWTYPE;
    v_eid text;
BEGIN
    NEW.variable := lab.fn_canonical_variable(NEW.variable);
    v_eid := CASE NEW.entity_kind
                 WHEN 'event'    THEN NEW.event_id::text
                 WHEN 'artifact' THEN NEW.artifact_id::text
                 WHEN 'subject'  THEN NEW.subject_id
                 WHEN 'session'  THEN NEW.session_id::text
                 WHEN 'project'  THEN NEW.project_id::text
             END;
    IF v_eid IS NULL OR NEW.op IS NULL OR NEW.op NOT IN ('set', 'unset') THEN
        RETURN NEW;
    END IF;

    SELECT v.* INTO v_var FROM lab.variable v WHERE v.name = NEW.variable;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            MESSAGE = format('variable %s is not defined', NEW.variable),
            HINT    = 'Use lab.fn_set_variable, which defines a variable on first use, '
                      'or lab.fn_define_variable.';
    END IF;
    IF NOT (NEW.entity_kind = ANY (v_var.applies_to)) THEN
        RAISE EXCEPTION 'variable % applies to % only, not to %',
            v_var.name, array_to_string(v_var.applies_to, ', '), NEW.entity_kind;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        concat_ws(':', 'lab.variable', NEW.entity_kind, v_eid, NEW.variable), 0));

    IF NEW.op = 'unset' THEN
        IF NOT EXISTS (SELECT 1 FROM lab.variable_current c
                       WHERE c.entity_kind = NEW.entity_kind
                         AND c.entity_id = v_eid AND c.variable = NEW.variable) THEN
            RAISE EXCEPTION '% % has no value for variable %, so there is nothing to unset',
                NEW.entity_kind, v_eid, NEW.variable;
        END IF;
        RETURN NEW;
    END IF;

    IF v_var.value_type = 'number' AND NEW.value_num IS NULL THEN
        RAISE EXCEPTION 'variable % holds a number, not text', v_var.name;
    END IF;
    IF v_var.value_type = 'text' AND NEW.value_text IS NULL THEN
        RAISE EXCEPTION 'variable % holds text, not a number', v_var.name;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_variable_value_policy
    BEFORE INSERT ON lab.variable_value
    FOR EACH ROW EXECUTE FUNCTION lab.fn_variable_value_policy();

-- A correction is a new row, so without this it would start with none of its
-- predecessor's variables. Copy them when the superseding event or artifact
-- is inserted, in the database, so that every client -- and a correction
-- typed into psql -- behaves the same.
CREATE OR REPLACE FUNCTION lab.fn_carry_variables_on_supersede() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NEW.supersedes IS NULL THEN
        RETURN NULL;
    END IF;
    IF TG_TABLE_NAME = 'event' THEN
        PERFORM lab.fn_carry_variables('event', NEW.supersedes, NEW.event_id);
    ELSIF TG_TABLE_NAME = 'artifact' THEN
        PERFORM lab.fn_carry_variables('artifact', NEW.supersedes, NEW.artifact_id);
    ELSE
        RAISE EXCEPTION 'lab.fn_carry_variables_on_supersede is not defined for table %',
            TG_TABLE_NAME;
    END IF;
    RETURN NULL;        -- AFTER trigger: the return value is ignored
END;
$$;

CREATE TRIGGER trg_event_carry_variables
    AFTER INSERT ON lab.event
    FOR EACH ROW EXECUTE FUNCTION lab.fn_carry_variables_on_supersede();

CREATE TRIGGER trg_artifact_carry_variables
    AFTER INSERT ON lab.artifact
    FOR EACH ROW EXECUTE FUNCTION lab.fn_carry_variables_on_supersede();

-- Canonicalise a template on the way in: its name the way a variable name is
-- (lab.fn_canonical_variable), and a label that defaults to the name.
CREATE OR REPLACE FUNCTION lab.fn_normalize_form() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    NEW.name  := lab.fn_canonical_variable(NEW.name);
    NEW.label := coalesce(nullif(btrim(NEW.label), ''), NEW.name);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_normalize
    BEFORE INSERT ON lab.form
    FOR EACH ROW EXECUTE FUNCTION lab.fn_normalize_form();

-- A template's name is what its versions, subject forms and entries refer
-- to: it never changes. Label, description and retired_at stay editable.
CREATE OR REPLACE FUNCTION lab.fn_form_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NEW.name IS DISTINCT FROM OLD.name THEN
        RAISE EXCEPTION USING
            MESSAGE = format('form %s cannot be renamed', OLD.name),
            HINT    = 'Change its label, or retire it and publish a template under the new name.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_guard
    BEFORE UPDATE ON lab.form
    FOR EACH ROW EXECUTE FUNCTION lab.fn_form_guard();

-- Every version row, however it is written (lab.fn_publish_form or a raw
-- INSERT): numbered max + 1 per template, under a per-template lock so two
-- publishers cannot both take the same number; refused for a retired
-- template; and refused when lab.fn_form_definition_problems reports
-- anything about the definition, with every bound variable already defined
-- for events (lab.fn_publish_form defines them first).
CREATE OR REPLACE FUNCTION lab.fn_form_version_policy() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_next     integer;
    v_problems text;
    v_detail   text;
BEGIN
    NEW.form_name := lab.fn_canonical_variable(NEW.form_name);
    PERFORM pg_advisory_xact_lock(hashtextextended(
        concat_ws(':', 'lab.form_version', NEW.form_name), 0));
    IF EXISTS (SELECT 1 FROM lab.form f
               WHERE f.name = NEW.form_name AND f.retired_at IS NOT NULL) THEN
        RAISE EXCEPTION USING
            MESSAGE = format('form %s is retired and takes no new versions', NEW.form_name),
            HINT    = 'Clear its retired_at first.';
    END IF;
    SELECT coalesce(max(fv.version), 0) + 1 INTO v_next
    FROM lab.form_version fv WHERE fv.form_name = NEW.form_name;
    IF NEW.version IS NULL THEN
        NEW.version := v_next;
    ELSIF NEW.version <> v_next THEN
        RAISE EXCEPTION USING
            MESSAGE = format('the next version of form %s is %s, not %s',
                             NEW.form_name, v_next, NEW.version),
            HINT    = 'Leave version out: the database numbers the versions.';
    END IF;

    SELECT string_agg(p.path || ': ' || p.problem, '; ' ORDER BY p.ord),
           jsonb_agg(jsonb_build_object('path', p.path, 'problem', p.problem) ORDER BY p.ord)::text
      INTO v_problems, v_detail
    FROM lab.fn_form_definition_problems(NEW.definition, true) p;
    IF v_problems IS NOT NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'CLB02',
            MESSAGE = format('form %s: the definition is not valid: %s', NEW.form_name, v_problems),
            DETAIL  = v_detail;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_version_policy
    BEFORE INSERT ON lab.form_version
    FOR EACH ROW EXECUTE FUNCTION lab.fn_form_version_policy();

-- Fill in a new subject form: the template name canonicalised, the project
-- defaulting to the subject's own, and the version to the template's latest.
CREATE OR REPLACE FUNCTION lab.fn_subject_form_defaults() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    NEW.form_name := lab.fn_canonical_variable(NEW.form_name);
    IF NEW.project_id IS NULL THEN
        SELECT s.project_id INTO NEW.project_id
        FROM lab.subject s WHERE s.subject_id = NEW.subject_id;
    END IF;
    IF NEW.form_version IS NULL THEN
        SELECT max(fv.version) INTO NEW.form_version
        FROM lab.form_version fv WHERE fv.form_name = NEW.form_name;
        IF NEW.form_version IS NULL THEN
            RAISE EXCEPTION USING
                MESSAGE = format('form %s has no published version', NEW.form_name),
                HINT    = 'Publish it first (lab.fn_publish_form).';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_subject_form_defaults
    BEFORE INSERT ON lab.subject_form
    FOR EACH ROW EXECUTE FUNCTION lab.fn_subject_form_defaults();

-- A subject form's entries refer to it, so what it is never changes: only
-- form_version (the version new entries use), notes and retired_at may be
-- edited. The one exception is the relabelling a subject rename cascades
-- into subject_id, admitted on the same terms as in lab.fn_forbid_mutation.
CREATE OR REPLACE FUNCTION lab.fn_subject_form_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_from text := coalesce(current_setting('lab.rename_from', true), '');
    v_to   text := coalesce(current_setting('lab.rename_to', true), '');
BEGIN
    IF NEW.subject_form_id IS DISTINCT FROM OLD.subject_form_id
       OR NEW.project_id IS DISTINCT FROM OLD.project_id
       OR NEW.form_name IS DISTINCT FROM OLD.form_name
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION USING
            MESSAGE = format('subject form %s: only form_version, notes and retired_at can change',
                             OLD.subject_form_id),
            HINT    = 'For another project or template, add a subject form for it '
                      '(lab.fn_add_subject_form).';
    END IF;
    IF NEW.subject_id IS DISTINCT FROM OLD.subject_id
       AND NOT (coalesce(current_setting('lab.maintenance', true), '') = 'subject_rename'
                AND v_from <> '' AND v_to <> ''
                AND OLD.subject_id = v_from AND NEW.subject_id = v_to
                AND NOT EXISTS (SELECT 1 FROM lab.subject WHERE subject_id = v_from)
                AND EXISTS (SELECT 1 FROM lab.subject WHERE subject_id = v_to)) THEN
        RAISE EXCEPTION USING
            MESSAGE = format('subject form %s cannot be moved to another subject',
                             OLD.subject_form_id),
            HINT    = 'Add the template to the other subject instead.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_subject_form_guard
    BEFORE UPDATE ON lab.subject_form
    FOR EACH ROW EXECUTE FUNCTION lab.fn_subject_form_guard();

-- An entry is about the subject its subject form belongs to. The event row
-- carries the subject, the detail row the subject form, so this cannot be a
-- foreign key; the composite FK on (subject_form_id, form_name) already ties
-- the entry's template to the subject form's.
CREATE OR REPLACE FUNCTION lab.fn_observation_event_policy() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_event_subject text;
    v_form_subject  text;
BEGIN
    SELECT e.subject_id INTO v_event_subject FROM lab.event e WHERE e.event_id = NEW.event_id;
    SELECT sf.subject_id INTO v_form_subject
    FROM lab.subject_form sf WHERE sf.subject_form_id = NEW.subject_form_id;
    IF v_form_subject IS NOT NULL AND v_event_subject IS DISTINCT FROM v_form_subject THEN
        RAISE EXCEPTION USING
            MESSAGE = format('observation event %s is about subject %s, but subject form %s '
                             'belongs to subject %s', NEW.event_id,
                             coalesce(v_event_subject, 'none'), NEW.subject_form_id, v_form_subject);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_observation_event_policy
    BEFORE INSERT ON lab.observation_event
    FOR EACH ROW EXECUTE FUNCTION lab.fn_observation_event_policy();

-- Only the current version of a row can be retracted, and only once: a
-- superseded row is already inactive, and retracting it would say nothing
-- about the correction that replaced it.
CREATE OR REPLACE FUNCTION lab.fn_retraction_policy() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_next uuid;
BEGIN
    IF NEW.entity_kind = 'event' AND NEW.event_id IS NOT NULL THEN
        SELECT s.event_id INTO v_next FROM lab.event s WHERE s.supersedes = NEW.event_id;
        IF v_next IS NOT NULL THEN
            RAISE EXCEPTION USING
                MESSAGE = format('event %s has been superseded by %s', NEW.event_id, v_next),
                HINT    = 'Retract the current version instead.';
        END IF;
        IF EXISTS (SELECT 1 FROM lab.retraction r WHERE r.event_id = NEW.event_id) THEN
            RAISE EXCEPTION 'event % is already retracted', NEW.event_id;
        END IF;
    ELSIF NEW.entity_kind = 'artifact' AND NEW.artifact_id IS NOT NULL THEN
        SELECT s.artifact_id INTO v_next FROM lab.artifact s WHERE s.supersedes = NEW.artifact_id;
        IF v_next IS NOT NULL THEN
            RAISE EXCEPTION USING
                MESSAGE = format('artifact %s has been superseded by %s', NEW.artifact_id, v_next),
                HINT    = 'Retract the current version instead.';
        END IF;
        IF EXISTS (SELECT 1 FROM lab.retraction r WHERE r.artifact_id = NEW.artifact_id) THEN
            RAISE EXCEPTION 'artifact % is already retracted', NEW.artifact_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_retraction_policy
    BEFORE INSERT ON lab.retraction
    FOR EACH ROW EXECUTE FUNCTION lab.fn_retraction_policy();

-- What may be recorded about a file (see lab.artifact_disposition): it is
-- replaced, moved or deleted only while present, and restored only while it
-- is not. A move names the row for the same bytes at another path; a
-- replacement, when it names one, the row for other bytes at the same path.
-- One writer at a time per file, so two clients cannot both dispose of it.
CREATE OR REPLACE FUNCTION lab.fn_artifact_disposition_policy() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_file   lab.artifact%ROWTYPE;
    v_next   lab.artifact%ROWTYPE;
    v_latest text;
BEGIN
    SELECT * INTO v_file FROM lab.artifact a WHERE a.artifact_id = NEW.artifact_id;
    IF NOT FOUND THEN
        RETURN NEW;     -- the foreign key reports it
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        concat_ws(':', 'lab.artifact_disposition', v_file.storage_root_id,
                  v_file.relative_path, v_file.checksum), 0));

    SELECT d.disposition INTO v_latest
    FROM lab.artifact f
    JOIN lab.artifact_disposition d ON d.artifact_id = f.artifact_id
    WHERE f.storage_root_id = v_file.storage_root_id
      AND f.relative_path   = v_file.relative_path
      AND f.checksum        = v_file.checksum
    ORDER BY d.disposition_id DESC
    LIMIT 1;

    IF NEW.disposition = 'restored' THEN
        IF v_latest IS NULL OR v_latest = 'restored' THEN
            RAISE EXCEPTION USING
                MESSAGE = format('the file of artifact %s is present: there is nothing to restore',
                                 NEW.artifact_id);
        END IF;
    ELSIF v_latest IS NOT NULL AND v_latest <> 'restored' THEN
        RAISE EXCEPTION USING
            MESSAGE = format('the file of artifact %s is already recorded as %s',
                             NEW.artifact_id, v_latest),
            HINT    = 'Record ''restored'' first if the same bytes came back.';
    END IF;

    IF NEW.successor_artifact_id IS NOT NULL THEN
        SELECT * INTO v_next FROM lab.artifact a WHERE a.artifact_id = NEW.successor_artifact_id;
        IF FOUND AND NEW.disposition = 'moved'
           AND (v_next.checksum <> v_file.checksum
                OR (v_next.storage_root_id = v_file.storage_root_id
                    AND v_next.relative_path = v_file.relative_path)) THEN
            RAISE EXCEPTION USING
                MESSAGE = format('artifact %s cannot be where artifact %s moved: a move keeps '
                                 'the bytes (the same checksum) at another path',
                                 NEW.successor_artifact_id, NEW.artifact_id);
        END IF;
        IF FOUND AND NEW.disposition = 'replaced'
           AND (v_next.storage_root_id <> v_file.storage_root_id
                OR v_next.relative_path <> v_file.relative_path
                OR v_next.checksum = v_file.checksum) THEN
            RAISE EXCEPTION USING
                MESSAGE = format('artifact %s cannot have replaced artifact %s: a replacement '
                                 'is other bytes (another checksum) at the same path',
                                 NEW.successor_artifact_id, NEW.artifact_id);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_artifact_disposition_policy
    BEFORE INSERT ON lab.artifact_disposition
    FOR EACH ROW EXECUTE FUNCTION lab.fn_artifact_disposition_policy();

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
        ('tag',                '''tag'''),
        ('variable',           '''name'''),
        ('form',               '''name'''),
        ('subject_form',       '''subject_form_id''')
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
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
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
-- A row is active when nothing supersedes it and it has not been retracted.
CREATE VIEW lab.event_active AS
    SELECT e.* FROM lab.event e
    WHERE NOT EXISTS (
        SELECT 1 FROM lab.event s WHERE s.supersedes = e.event_id)
      AND NOT EXISTS (
        SELECT 1 FROM lab.retraction r WHERE r.event_id = e.event_id);

CREATE VIEW lab.artifact_active AS
    SELECT a.* FROM lab.artifact a
    WHERE NOT EXISTS (
        SELECT 1 FROM lab.artifact s WHERE s.supersedes = a.artifact_id)
      AND NOT EXISTS (
        SELECT 1 FROM lab.retraction r WHERE r.artifact_id = a.artifact_id);

-- Every version of every event / artifact, superseded, retracted or neither,
-- with the row that replaced it. Readers of full history use these instead of
-- the base tables so that a row that is no longer in force cannot be mistaken
-- for a current one: is_current is false, and superseded_by names its
-- correction or is_retracted says it was withdrawn.
CREATE VIEW lab.event_version AS
    SELECT e.*, s.event_id AS superseded_by,
           (s.event_id IS NULL AND r.retraction_id IS NULL) AS is_current,
           (r.retraction_id IS NOT NULL) AS is_retracted
    FROM lab.event e
    LEFT JOIN lab.event s ON s.supersedes = e.event_id
    LEFT JOIN lab.retraction r ON r.event_id = e.event_id;

CREATE VIEW lab.artifact_version AS
    SELECT a.*, s.artifact_id AS superseded_by,
           (s.artifact_id IS NULL AND r.retraction_id IS NULL) AS is_current,
           (r.retraction_id IS NOT NULL) AS is_retracted
    FROM lab.artifact a
    LEFT JOIN lab.artifact s ON s.supersedes = a.artifact_id
    LEFT JOIN lab.retraction r ON r.artifact_id = a.artifact_id;

-- The latest integrity check of the *file* each artifact row describes.
-- Verification belongs to the file, not to the row: a correction to an
-- artifact's metadata, or to the event that produced it, inserts a new row
-- for the same (storage_root_id, relative_path, checksum), and that row must
-- not start with a clean slate -- a known 'mismatch' would silently become
-- "never verified". So the latest check is taken over every artifact row
-- that describes the same file; verified_artifact_id is the row the check
-- was recorded against. One row per artifact whose file has ever been
-- checked. A correction that changes the path or the checksum describes a
-- different file and correctly starts unverified.
CREATE VIEW lab.artifact_verification_latest AS
    SELECT a.artifact_id, v.verification_id, v.verified_artifact_id,
           v.verified_at, v.verified_by, v.status, v.observed_checksum
    FROM lab.artifact a
    JOIN LATERAL (
        SELECT av.verification_id, av.artifact_id AS verified_artifact_id,
               av.verified_at, av.verified_by, av.status, av.observed_checksum
        FROM lab.artifact f
        JOIN lab.artifact_verification av ON av.artifact_id = f.artifact_id
        WHERE f.storage_root_id = a.storage_root_id
          AND f.relative_path   = a.relative_path
          AND f.checksum        = a.checksum
        ORDER BY av.verified_at DESC, av.verification_id DESC
        LIMIT 1
    ) v ON true;

-- The latest disposition of each artifact row's file, by file like the
-- verifications above: every row describing (root, path, checksum) shares it.
-- disposed_artifact_id is the row the disposition was recorded against.
CREATE VIEW lab.artifact_disposition_latest AS
    SELECT a.artifact_id, d.disposition_id, d.disposed_artifact_id, d.disposition,
           d.successor_artifact_id, d.occurred_at, d.recorded_at, d.recorded_by
    FROM lab.artifact a
    JOIN LATERAL (
        SELECT ad.disposition_id, ad.artifact_id AS disposed_artifact_id,
               ad.disposition, ad.successor_artifact_id, ad.occurred_at,
               ad.recorded_at, ad.recorded_by
        FROM lab.artifact f
        JOIN lab.artifact_disposition ad ON ad.artifact_id = f.artifact_id
        WHERE f.storage_root_id = a.storage_root_id
          AND f.relative_path   = a.relative_path
          AND f.checksum        = a.checksum
        ORDER BY ad.disposition_id DESC
        LIMIT 1
    ) d ON true;

-- Active artifacts whose file is where the row says it is: not replaced,
-- moved or deleted since (or restored since). Where to find a file; the
-- integrity checks of files read this, not artifact_active.
CREATE VIEW lab.artifact_present AS
    SELECT a.* FROM lab.artifact_active a
    WHERE NOT EXISTS (
        SELECT 1 FROM lab.artifact_disposition_latest d
        WHERE d.artifact_id = a.artifact_id AND d.disposition <> 'restored');

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
        JOIN lab.event_active e ON e.event_id = h.event_id
        WHERE e.subject_id = s.subject_id AND h.weight_g IS NOT NULL
        -- event_id breaks ties: two weights recorded at the same instant would
        -- otherwise make this view return a different number run to run.
        ORDER BY e.occurred_at DESC, e.event_id DESC LIMIT 1
    ) w ON true
    LEFT JOIN LATERAL (
        SELECT e.event_id, e.occurred_at
        FROM lab.endpoint_event ee
        JOIN lab.event_active e ON e.event_id = ee.event_id
        WHERE e.subject_id = s.subject_id
        ORDER BY e.occurred_at DESC, e.event_id DESC LIMIT 1
    ) ep ON true;

-- Current tags: the latest assignment row per (entity, tag), kept when it is
-- an 'add'. entity_id is the entity's id as text, whatever its kind (computed
-- here, not stored; see lab.tag_assignment). display_tag is the tag as people
-- write it: a bare tag shows without its 'tag:' prefix, so every client
-- renders 'auditory_cortex' the same way without re-implementing the rule.
-- "Latest" is insertion order (assignment_id), never applied_at: applied_at
-- is the start time of the writing transaction and can be supplied by the
-- client, so a 'remove' accepted by trg_tag_assignment_policy could carry an
-- earlier applied_at than the 'add' it removes and would then do nothing.
-- trg_tag_assignment_policy serialises writers per (entity, namespace), so
-- insertion order is the order in which the policy accepted the rows.
CREATE VIEW lab.tag_current AS
    SELECT c.assignment_id, c.entity_kind, c.entity_id,
           c.event_id, c.artifact_id, c.subject_id, c.session_id, c.project_id,
           c.tag, t.namespace, t.value,
           CASE WHEN t.namespace = 'tag' THEN t.value ELSE t.tag END AS display_tag,
           c.note, c.applied_at, c.applied_by, c.applied_login
    FROM (
        SELECT DISTINCT ON (x.entity_kind, x.entity_id, x.tag) x.*
        FROM (
            SELECT ta.*,
                   coalesce(ta.event_id::text, ta.artifact_id::text, ta.subject_id,
                            ta.session_id::text, ta.project_id::text) AS entity_id
            FROM lab.tag_assignment ta
        ) x
        ORDER BY x.entity_kind, x.entity_id, x.tag, x.assignment_id DESC
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

-- Current variables: the latest value row per (entity, variable), kept when
-- it is a 'set'. "Latest" is insertion order (value_id), as for tags. value
-- is the value as text whichever kind it is, units and label come from the
-- definition, and set_at is when this value was set -- the variable's "last
-- updated" time. The full history is lab.variable_value.
CREATE VIEW lab.variable_current AS
    SELECT c.value_id, c.entity_kind, c.entity_id,
           c.event_id, c.artifact_id, c.subject_id, c.session_id, c.project_id,
           c.variable, v.label, v.units, v.value_type,
           c.value_num, c.value_text,
           coalesce(c.value_text, c.value_num::text) AS value,
           c.note, c.set_at, c.set_by, c.set_login
    FROM (
        SELECT DISTINCT ON (x.entity_kind, x.entity_id, x.variable) x.*
        FROM (
            SELECT vv.*,
                   coalesce(vv.event_id::text, vv.artifact_id::text, vv.subject_id,
                            vv.session_id::text, vv.project_id::text) AS entity_id
            FROM lab.variable_value vv
        ) x
        ORDER BY x.entity_kind, x.entity_id, x.variable, x.value_id DESC
    ) c
    JOIN lab.variable v ON v.name = c.variable
    WHERE c.op = 'set';

-- One row per entity that has at least one current variable, with all of them
-- as one JSON object {name: value} -- numbers as JSON numbers, text as
-- strings -- for joining onto a list of subjects, sessions or files.
CREATE VIEW lab.entity_variables AS
    SELECT vc.entity_kind, vc.entity_id,
           jsonb_object_agg(vc.variable,
                            CASE WHEN vc.value_num IS NOT NULL THEN to_jsonb(vc.value_num)
                                 ELSE to_jsonb(vc.value_text) END) AS variables
    FROM lab.variable_current vc
    GROUP BY vc.entity_kind, vc.entity_id;

-- ---------------------------------------------------------------------------
-- Correction chains and the recursive lineage function
-- ---------------------------------------------------------------------------
-- A correction is a new row whose supersedes column names the row it replaces,
-- and uq_event_supersedes / uq_artifact_supersedes keep each chain linear, so
-- every row has exactly one current version: the end of its chain. These
-- return it (the id itself when the row has not been corrected) ...
CREATE OR REPLACE FUNCTION lab.fn_event_current(p_event_id uuid) RETURNS uuid
LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
DECLARE
    v_id   uuid := p_event_id;
    v_next uuid;
BEGIN
    LOOP
        SELECT e.event_id INTO v_next FROM lab.event e WHERE e.supersedes = v_id;
        EXIT WHEN v_next IS NULL;
        v_id := v_next;
    END LOOP;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION lab.fn_artifact_current(p_artifact_id uuid) RETURNS uuid
LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
DECLARE
    v_id   uuid := p_artifact_id;
    v_next uuid;
BEGIN
    LOOP
        SELECT a.artifact_id INTO v_next FROM lab.artifact a WHERE a.supersedes = v_id;
        EXIT WHEN v_next IS NULL;
        v_id := v_next;
    END LOOP;
    RETURN v_id;
END;
$$;

-- ... and these return every version in the chain an id belongs to, the
-- current one first.
CREATE OR REPLACE FUNCTION lab.fn_event_versions(p_event_id uuid) RETURNS SETOF uuid
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    WITH RECURSIVE v AS (
        SELECT e.event_id, e.supersedes FROM lab.event e
        WHERE e.event_id = lab.fn_event_current(p_event_id)
      UNION ALL
        SELECT e.event_id, e.supersedes FROM v JOIN lab.event e ON e.event_id = v.supersedes
    )
    SELECT v.event_id FROM v;
$$;

CREATE OR REPLACE FUNCTION lab.fn_artifact_versions(p_artifact_id uuid) RETURNS SETOF uuid
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    WITH RECURSIVE v AS (
        SELECT a.artifact_id, a.supersedes FROM lab.artifact a
        WHERE a.artifact_id = lab.fn_artifact_current(p_artifact_id)
      UNION ALL
        SELECT a.artifact_id, a.supersedes FROM v JOIN lab.artifact a ON a.artifact_id = v.supersedes
    )
    SELECT v.artifact_id FROM v;
$$;

-- Ancestors ('up') or descendants ('down') of an artifact in the provenance
-- graph, as (depth, event_id, artifact_id) rows.
--
-- With p_follow_corrections (the default) the walk is over *current* rows,
-- whichever version p_artifact_id names, and every id returned is a current
-- one. Provenance edges are immutable, so after a correction they still name
-- the superseded rows: an analysis that consumed raw file a1 keeps its edge
-- to a1 when a1 is corrected to a2. Walking the rows as recorded then says
-- nothing was derived from a2, and the ancestry of the analysis output ends
-- at a row artifact_active hides. So each node stands for its whole chain:
--   * an artifact is produced by the current version of its producing event;
--   * an event's inputs are the inputs its current version declares (a
--     correction re-declares them, so it is authoritative), each resolved to
--     its current artifact;
--   * an artifact's consumers are the current events with an edge to any of
--     its versions, and their outputs the active artifacts produced by any
--     version of the event.
--
-- With p_follow_corrections false the walk is over the rows exactly as
-- recorded, superseded ones included -- the audit view of what was written.
CREATE OR REPLACE FUNCTION lab.fn_artifact_lineage(
    p_artifact_id        uuid,
    p_direction          text DEFAULT 'up',   -- 'up' = ancestors, 'down' = descendants
    p_follow_corrections boolean DEFAULT true
) RETURNS TABLE (depth integer, event_id uuid, artifact_id uuid)
-- STABLE PARALLEL SAFE: read-only, so the planner may cache and parallelize it.
-- Without this it is treated as VOLATILE (the default) and re-executed per row
-- whenever it appears in a join.
LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
BEGIN
    IF p_direction NOT IN ('up','down') THEN
        RAISE EXCEPTION 'direction must be ''up'' or ''down'', got %', p_direction;
    END IF;

    IF p_direction = 'up' AND p_follow_corrections THEN
        RETURN QUERY
        WITH RECURSIVE lin AS (
            SELECT 0 AS depth, lab.fn_event_current(a.produced_by_event_id) AS event_id,
                   a.artifact_id
            FROM lab.artifact a
            WHERE a.artifact_id = lab.fn_artifact_current(p_artifact_id)
          UNION
            SELECT l.depth + 1, lab.fn_event_current(ain.produced_by_event_id), ain.artifact_id
            FROM lin l
            JOIN lab.event_input ei  ON ei.event_id = l.event_id
            JOIN lab.artifact    ain ON ain.artifact_id = lab.fn_artifact_current(ei.artifact_id)
            WHERE l.depth < 64
        )
        SELECT lin.depth, lin.event_id, lin.artifact_id FROM lin ORDER BY lin.depth;
    ELSIF p_direction = 'up' THEN
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
    ELSIF p_follow_corrections THEN
        RETURN QUERY
        WITH RECURSIVE lin AS (
            SELECT 0 AS depth, NULL::uuid AS event_id, a.artifact_id
            FROM lab.artifact a
            WHERE a.artifact_id = lab.fn_artifact_current(p_artifact_id)
          UNION
            SELECT l.depth + 1, c.event_id, prod.artifact_id
            FROM lin l
            CROSS JOIN LATERAL lab.fn_artifact_versions(l.artifact_id) av(artifact_id)
            JOIN lab.event_input     ei   ON ei.artifact_id = av.artifact_id
            JOIN lab.event_active    c    ON c.event_id = ei.event_id
            CROSS JOIN LATERAL lab.fn_event_versions(c.event_id) cv(event_id)
            JOIN lab.artifact_active prod ON prod.produced_by_event_id = cv.event_id
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
--                            ARRAY['stage:raw', 'topic:tonotopy'], NULL, ARRAY['qc:fail'])
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
-- skips superseded and retracted rows, like the *_active views; it has no
-- effect on the other kinds.
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
               OR EXISTS (SELECT 1 FROM lab.event_active x WHERE x.event_id = e.event_id))
          AND lab.fn_tag_match('event', e.event_id::text, p_all, p_any, p_none)
        ORDER BY 1;
    ELSIF p_kind = 'artifact' THEN
        RETURN QUERY
        SELECT a.artifact_id::text FROM lab.artifact a
        WHERE (NOT p_active_only
               OR EXISTS (SELECT 1 FROM lab.artifact_active x WHERE x.artifact_id = a.artifact_id))
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
-- People and logins
-- ---------------------------------------------------------------------------
-- The person whose lab.person.db_login is the login now connected, or NULL
-- when the login is mapped to nobody (a shared or service login). Clients
-- use it to resolve "current person" without asking, and trg_*_stamp_login
-- uses it to attribute a row whose client named no person.
CREATE OR REPLACE FUNCTION lab.fn_current_person() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT p.person_id FROM lab.person p WHERE p.db_login = session_user::text;
$$;

-- ---------------------------------------------------------------------------
-- Retraction
-- ---------------------------------------------------------------------------
-- Withdraw an event or artifact that should never have been recorded:
--
--     SELECT lab.fn_retract('event', '<event_id>', 'entered twice');
--
-- The row and everything that refers to it stay in the database; the
-- *_active views stop returning it. Retracting an event does not retract the
-- files it produced -- lab.fn_check_integrity reports them as
-- artifact_producer_retracted until each is retracted or re-pointed at the
-- right event. Returns the retraction_id.
CREATE OR REPLACE FUNCTION lab.fn_retract(
    p_kind   text,
    p_id     uuid,
    p_reason text,
    p_by     uuid DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_out bigint;
BEGIN
    IF p_kind IS NULL OR p_kind NOT IN ('event', 'artifact') THEN
        RAISE EXCEPTION 'only an event or an artifact can be retracted, got %', p_kind;
    END IF;
    IF p_id IS NULL THEN
        RAISE EXCEPTION 'an id is required';
    END IF;
    INSERT INTO lab.retraction (entity_kind, event_id, artifact_id, reason, retracted_by)
    VALUES (p_kind,
            CASE WHEN p_kind = 'event'    THEN p_id END,
            CASE WHEN p_kind = 'artifact' THEN p_id END,
            p_reason, p_by)
    RETURNING retraction_id INTO v_out;
    RETURN v_out;
END;
$$;

-- ---------------------------------------------------------------------------
-- User-defined variables: writes and simple reads
-- ---------------------------------------------------------------------------
-- Define a variable without setting it, and return its canonical name. A
-- variable that already exists is returned as is, provided the value type
-- and units asked for are the ones it has; otherwise this raises rather than
-- letting two meanings share a name.
CREATE OR REPLACE FUNCTION lab.fn_define_variable(
    p_name        text,
    p_value_type  text DEFAULT 'number',
    p_units       text DEFAULT NULL,
    p_label       text DEFAULT NULL,
    p_description text DEFAULT NULL,
    p_applies_to  text[] DEFAULT NULL,
    p_by          uuid DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_name  text := lab.fn_canonical_variable(p_name);
    v_units text := nullif(btrim(p_units), '');
    v_var   lab.variable%ROWTYPE;
BEGIN
    IF v_name IS NULL OR v_name = '' THEN
        RAISE EXCEPTION 'a variable name is required';
    END IF;
    IF v_name !~ '^[a-z][a-z0-9_-]*( [a-z0-9_-]+)*$' OR length(v_name) > 63 THEN
        RAISE EXCEPTION USING
            MESSAGE = format('"%s" is not a valid variable name', v_name),
            HINT    = 'Use words of letters, digits, _ or -, separated by single spaces and '
                      'starting with a letter, at most 63 characters: probe depth';
    END IF;
    SELECT v.* INTO v_var FROM lab.variable v WHERE v.name = v_name;
    IF FOUND THEN
        IF v_var.value_type IS DISTINCT FROM p_value_type
           OR v_var.units IS DISTINCT FROM v_units THEN
            RAISE EXCEPTION USING
                MESSAGE = format('variable %s is already defined as a %s in %s; asked for a %s in %s',
                                 v_name, v_var.value_type, coalesce(v_var.units, 'no units'),
                                 coalesce(p_value_type, 'NULL'), coalesce(v_units, 'no units')),
                HINT    = 'Use the existing definition, or define a variable with another name.';
        END IF;
        RETURN v_name;
    END IF;
    INSERT INTO lab.variable (name, label, description, units, value_type, applies_to, created_by)
    VALUES (v_name, p_label, p_description, v_units, p_value_type,
            coalesce(p_applies_to, ARRAY['event','artifact','subject','session','project']),
            coalesce(p_by, lab.fn_current_person()))
    ON CONFLICT (name) DO NOTHING;
    RETURN v_name;
END;
$$;

-- The one write entry point for variables, used by every client. Exactly one
-- of p_number / p_text is given:
--
--     SELECT lab.fn_set_variable('session', '<session_id>', 'Probe Depth', 1200,
--                                p_units => 'um', p_label => 'Probe Depth',
--                                p_description => 'Depth of the probe tip below the pia');
--     SELECT lab.fn_set_variable('subject', 'G-0421', 'housing', p_text => 'pair');
--     SELECT lab.fn_set_variable('session', '<session_id>', 'probe depth', 1350);  -- an update
--
-- p_kind is event, artifact, subject, session or project and p_id that
-- entity's id as text. The name is canonicalised (lab.fn_canonical_variable).
-- A variable used for the first time is defined on the spot, as a number or
-- as text according to which value was given, with the units, label and
-- description supplied; for a variable that already exists those three are
-- not changed by this call (edit lab.variable), and units that differ from
-- the definition are an error, so a value in millimetres cannot be filed
-- under a variable recorded in micrometres. Setting a variable again appends
-- a row -- that is an update -- and lab.variable_current shows the latest.
-- Returns the value_id of the row written.
CREATE OR REPLACE FUNCTION lab.fn_set_variable(
    p_kind        text,
    p_id          text,
    p_name        text,
    p_number      numeric DEFAULT NULL,
    p_text        text DEFAULT NULL,
    p_units       text DEFAULT NULL,
    p_label       text DEFAULT NULL,
    p_description text DEFAULT NULL,
    p_note        text DEFAULT NULL,
    p_by          uuid DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_name  text := lab.fn_canonical_variable(p_name);
    v_units text := nullif(btrim(p_units), '');
    v_var   lab.variable%ROWTYPE;
    v_uuid  uuid;
    v_out   bigint;
BEGIN
    IF p_kind IS NULL OR p_kind NOT IN ('event', 'artifact', 'subject', 'session', 'project') THEN
        RAISE EXCEPTION 'entity kind must be event, artifact, subject, session or project, got %',
            p_kind;
    END IF;
    IF p_id IS NULL THEN
        RAISE EXCEPTION 'an entity id is required';
    END IF;
    IF v_name IS NULL OR v_name = '' THEN
        RAISE EXCEPTION 'a variable name is required';
    END IF;
    IF num_nonnulls(p_number, p_text) <> 1 THEN
        RAISE EXCEPTION USING
            MESSAGE = format('variable %s needs exactly one value: a number or a string', v_name),
            HINT    = 'To clear a variable use lab.fn_unset_variable.';
    END IF;
    IF p_kind <> 'subject' THEN
        v_uuid := p_id::uuid;
    END IF;

    SELECT v.* INTO v_var FROM lab.variable v WHERE v.name = v_name;
    IF NOT FOUND THEN
        PERFORM lab.fn_define_variable(
            v_name, CASE WHEN p_number IS NOT NULL THEN 'number' ELSE 'text' END,
            v_units, p_label, p_description, NULL, p_by);
        SELECT v.* INTO v_var FROM lab.variable v WHERE v.name = v_name;
    ELSE
        IF v_var.retired_at IS NOT NULL THEN
            RAISE EXCEPTION 'variable % was retired at % and takes no new values',
                v_name, v_var.retired_at;
        END IF;
        IF v_units IS NOT NULL AND v_units IS DISTINCT FROM v_var.units THEN
            RAISE EXCEPTION USING
                MESSAGE = format('variable %s is recorded in %s, not in %s',
                                 v_name, coalesce(v_var.units, 'no units'), v_units),
                HINT    = 'Convert the value, or define a separate variable for the other units.';
        END IF;
    END IF;
    IF v_var.value_type = 'number' AND p_number IS NULL THEN
        RAISE EXCEPTION 'variable % holds a number; pass p_number', v_name;
    END IF;
    IF v_var.value_type = 'text' AND p_text IS NULL THEN
        RAISE EXCEPTION 'variable % holds text; pass p_text', v_name;
    END IF;

    INSERT INTO lab.variable_value (entity_kind, event_id, artifact_id, subject_id, session_id,
                                    project_id, variable, op, value_num, value_text, note, set_by)
    VALUES (p_kind,
            CASE WHEN p_kind = 'event'    THEN v_uuid END,
            CASE WHEN p_kind = 'artifact' THEN v_uuid END,
            CASE WHEN p_kind = 'subject'  THEN p_id END,
            CASE WHEN p_kind = 'session'  THEN v_uuid END,
            CASE WHEN p_kind = 'project'  THEN v_uuid END,
            v_name, 'set', p_number, p_text, p_note, coalesce(p_by, lab.fn_current_person()))
    RETURNING value_id INTO v_out;
    RETURN v_out;
END;
$$;

-- Clear a variable on an entity: appends an 'unset' row, after which the
-- entity has no current value for it. The earlier values stay in the log.
CREATE OR REPLACE FUNCTION lab.fn_unset_variable(
    p_kind text,
    p_id   text,
    p_name text,
    p_note text DEFAULT NULL,
    p_by   uuid DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_uuid uuid;
    v_out  bigint;
BEGIN
    IF p_kind IS NULL OR p_kind NOT IN ('event', 'artifact', 'subject', 'session', 'project') THEN
        RAISE EXCEPTION 'entity kind must be event, artifact, subject, session or project, got %',
            p_kind;
    END IF;
    IF p_id IS NULL THEN
        RAISE EXCEPTION 'an entity id is required';
    END IF;
    IF p_kind <> 'subject' THEN
        v_uuid := p_id::uuid;
    END IF;
    INSERT INTO lab.variable_value (entity_kind, event_id, artifact_id, subject_id, session_id,
                                    project_id, variable, op, note, set_by)
    VALUES (p_kind,
            CASE WHEN p_kind = 'event'    THEN v_uuid END,
            CASE WHEN p_kind = 'artifact' THEN v_uuid END,
            CASE WHEN p_kind = 'subject'  THEN p_id END,
            CASE WHEN p_kind = 'session'  THEN v_uuid END,
            CASE WHEN p_kind = 'project'  THEN v_uuid END,
            p_name, 'unset', p_note, coalesce(p_by, lab.fn_current_person()))
    RETURNING value_id INTO v_out;
    RETURN v_out;
END;
$$;

-- The current value of one variable on one entity, for use in an ordinary
-- query -- NULL when the entity has no current value for it:
--
--     SELECT s.session_id, s.label,
--            lab.fn_variable_number('session', s.session_id::text, 'probe depth') AS probe_depth_um
--     FROM lab.session s;
--
-- fn_variable_number is the number (NULL for a text variable);
-- fn_variable_text is the value as text, whichever kind it is.
CREATE OR REPLACE FUNCTION lab.fn_variable_number(p_kind text, p_id text, p_name text)
RETURNS numeric
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT c.value_num FROM lab.variable_current c
    WHERE c.entity_kind = p_kind
      AND c.entity_id = CASE WHEN p_kind IN ('event', 'artifact', 'session', 'project')
                             THEN p_id::uuid::text ELSE p_id END
      AND c.variable = lab.fn_canonical_variable(p_name);
$$;

CREATE OR REPLACE FUNCTION lab.fn_variable_text(p_kind text, p_id text, p_name text)
RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT c.value FROM lab.variable_current c
    WHERE c.entity_kind = p_kind
      AND c.entity_id = CASE WHEN p_kind IN ('event', 'artifact', 'session', 'project')
                             THEN p_id::uuid::text ELSE p_id END
      AND c.variable = lab.fn_canonical_variable(p_name);
$$;

-- Copy the current variables of a superseded event or artifact onto its
-- successor, keeping each value's set_at and set_by: the value was not
-- changed by the correction, so its "last updated" must not move. Called by
-- trg_*_carry_variables; returns the number of values copied.
CREATE OR REPLACE FUNCTION lab.fn_carry_variables(p_kind text, p_old_id uuid, p_new_id uuid)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_n integer;
BEGIN
    IF p_kind IS NULL OR p_kind NOT IN ('event', 'artifact') THEN
        RAISE EXCEPTION 'variables are carried forward for events and artifacts only, got %', p_kind;
    END IF;
    INSERT INTO lab.variable_value (entity_kind, event_id, artifact_id, variable, op,
                                    value_num, value_text, note, set_at, set_by)
    SELECT p_kind,
           CASE WHEN p_kind = 'event'    THEN p_new_id END,
           CASE WHEN p_kind = 'artifact' THEN p_new_id END,
           c.variable, 'set', c.value_num, c.value_text,
           format('carried forward from %s', p_old_id), c.set_at, c.set_by
    FROM lab.variable_current c
    WHERE c.entity_kind = p_kind AND c.entity_id = p_old_id::text
    ORDER BY c.value_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;

-- ---------------------------------------------------------------------------
-- Forms: value rules, definitions, writes and reads
-- ---------------------------------------------------------------------------
-- Values reach these functions as the text the user typed and are stored as
-- that text: a number is accepted only when it is already in the one form
-- PostgreSQL's numeric gives back unchanged, so '1.50' is stored and shown as
-- 1.50, and '1e3', '.5', '+1', '007' or '1,5' are refused with the reason
-- rather than rewritten into something the user did not type.

-- A plain decimal number, written the way numeric::text writes it.
CREATE OR REPLACE FUNCTION lab.fn_form_number_ok(p_value text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$
    SELECT CASE WHEN p_value ~ '^-?(0|[1-9][0-9]*)(\.[0-9]+)?$'
                THEN p_value::numeric::text = p_value
                ELSE false END;
$$;

-- A whole number, written the same way.
CREATE OR REPLACE FUNCTION lab.fn_form_integer_ok(p_value text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$
    SELECT p_value ~ '^-?(0|[1-9][0-9]*)$' AND p_value <> '-0';
$$;

-- What is wrong with one non-blank value of one form field, or NULL when it
-- is acceptable. p_field is the field's object in the form definition.
CREATE OR REPLACE FUNCTION lab.fn_form_value_problem(p_field jsonb, p_value text)
RETURNS text
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_widget text := p_field->>'widget';
    v_ok     boolean;
BEGIN
    IF v_widget IN ('number', 'integer') THEN
        IF v_widget = 'number' AND NOT lab.fn_form_number_ok(p_value) THEN
            RETURN format('"%s" is not a plain decimal number: write it like 12, -3 or 0.25 '
                          '(no exponent, leading zeros, "+", spaces or thousands separators)',
                          p_value);
        END IF;
        IF v_widget = 'integer' AND NOT lab.fn_form_integer_ok(p_value) THEN
            RETURN format('"%s" is not a whole number: write it like 12 or -3', p_value);
        END IF;
        IF p_field ? 'min' AND p_value::numeric < (p_field->>'min')::numeric THEN
            RETURN format('%s is below the minimum, %s', p_value, p_field->>'min');
        END IF;
        IF p_field ? 'max' AND p_value::numeric > (p_field->>'max')::numeric THEN
            RETURN format('%s is above the maximum, %s', p_value, p_field->>'max');
        END IF;
        RETURN NULL;
    ELSIF v_widget IN ('text', 'longtext') THEN
        IF v_widget = 'text' AND p_value ~ '[\r\n]' THEN
            RETURN 'must be a single line';
        END IF;
        IF p_value ~ '^[=@]' THEN
            RETURN 'starts with "=" or "@", which a spreadsheet opening the CSV would run '
                   'as a formula: start it with another character';
        END IF;
        RETURN NULL;
    ELSIF v_widget = 'choice' THEN
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_field->'options') o
                       WHERE o.value->>'value' = p_value) THEN
            RETURN format('"%s" is not one of the choices (%s)', p_value,
                          (SELECT string_agg(o.value->>'value', ', ' ORDER BY o.n)
                           FROM jsonb_array_elements(p_field->'options') WITH ORDINALITY o(value, n)));
        END IF;
        RETURN NULL;
    ELSIF v_widget = 'yesno' THEN
        IF p_value NOT IN ('yes', 'no') THEN
            RETURN format('"%s" is not yes or no', p_value);
        END IF;
        RETURN NULL;
    ELSIF v_widget = 'date' THEN
        v_ok := p_value ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$';
        IF v_ok THEN
            BEGIN
                v_ok := to_char(p_value::date, 'YYYY-MM-DD') = p_value;
            EXCEPTION WHEN OTHERS THEN
                v_ok := false;
            END;
        END IF;
        IF NOT v_ok THEN
            RETURN format('"%s" is not a date written YYYY-MM-DD', p_value);
        END IF;
        RETURN NULL;
    ELSIF v_widget = 'time' THEN
        IF p_value !~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$' THEN
            RETURN format('"%s" is not a time written HH:MM or HH:MM:SS (24-hour)', p_value);
        END IF;
        RETURN NULL;
    ELSIF v_widget = 'datetime' THEN
        v_ok := p_value ~ ('^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]'
                           '(:[0-5][0-9](\.[0-9]{1,6})?)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$');
        IF v_ok THEN
            BEGIN
                v_ok := to_char(left(p_value, 10)::date, 'YYYY-MM-DD') = left(p_value, 10)
                        AND p_value::timestamptz IS NOT NULL;
            EXCEPTION WHEN OTHERS THEN
                v_ok := false;
            END;
        END IF;
        IF NOT v_ok THEN
            RETURN format('"%s" is not a date and time with its UTC offset, written like '
                          '2026-11-14T09:30-05:00', p_value);
        END IF;
        RETURN NULL;
    END IF;
    RETURN format('fields of widget %s take no value', coalesce(v_widget, 'NULL'));
END;
$$;

-- What is wrong with a form definition, one row per problem in the order
-- found; no rows means it can be published. The definition (format 1):
--
--   {"format": 1,
--    "header":   [{"item": "species"}, {"item": "latest_weight"},
--                 {"variable": "baseline weight", "source": "subject"}, ...],
--    "sections": [{"title": "Recording",
--                  "fields": [{"widget": "number", "variable": "probe depth",
--                              "label": "Probe depth", "units": "um",
--                              "required": true, "min": "0", "max": "6000",
--                              "help": "...", "show_previous": true},
--                             {"widget": "choice", "variable": "hemisphere",
--                              "options": [{"value": "L"}, {"value": "R", "label": "Right"}]},
--                             {"widget": "instruction", "text": "..."}]}]}
--
-- design_docs/forms.md describes every key. Each field that takes a value is
-- bound to a variable (lab.variable), which holds a number for the number and
-- integer widgets and text for the others. With p_strict every bound
-- variable must already be defined for events, as it is once
-- lab.fn_publish_form has run; without, a variable that does not exist yet is
-- fine (lab.fn_publish_form defines it), which is how a client checks a draft.
CREATE OR REPLACE FUNCTION lab.fn_form_definition_problems(p_def jsonb, p_strict boolean DEFAULT false)
RETURNS TABLE (ord integer, path text, problem text)
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    c_widgets    constant text[] := ARRAY['number','integer','text','longtext','choice','yesno',
                                          'date','time','datetime','heading','instruction'];
    c_items      constant text[] := ARRAY['project','members','species','sex','strain','genotype',
                                          'date_of_birth','age','source','subject_notes','tags',
                                          'latest_weight','endpoint','last_surgery','last_entry'];
    c_field_keys constant text[] := ARRAY['widget','variable','label','units','required','min',
                                          'max','options','help','show_previous','text'];
    v_n      integer := 0;
    v_sec    jsonb;
    v_si     bigint;
    v_fld    jsonb;
    v_fi     bigint;
    v_p      text;
    v_widget text;
    v_var    text;
    v_type   text;
    v_row    lab.variable%ROWTYPE;
    v_fields text[] := '{}';
    v_data   integer := 0;
    v_key    text;
    v_opt    jsonb;
    v_vals   text[];
    v_item   jsonb;
    v_hi     bigint;
    v_hseen  text[] := '{}';
    v_hkey   text;
    v_src    text;
BEGIN
    IF p_def IS NULL OR jsonb_typeof(p_def) <> 'object' THEN
        v_n := v_n + 1; ord := v_n; path := 'definition';
        problem := 'must be a JSON object'; RETURN NEXT;
        RETURN;
    END IF;
    FOR v_key IN SELECT k FROM jsonb_object_keys(p_def) k ORDER BY k LOOP
        IF v_key NOT IN ('format', 'header', 'sections') THEN
            v_n := v_n + 1; ord := v_n; path := v_key;
            problem := 'is not a key of a form definition'; RETURN NEXT;
        END IF;
    END LOOP;
    IF p_def->'format' IS DISTINCT FROM '1'::jsonb THEN
        v_n := v_n + 1; ord := v_n; path := 'format';
        problem := 'must be 1'; RETURN NEXT;
    END IF;
    IF (CASE WHEN jsonb_typeof(p_def->'sections') = 'array'
             THEN jsonb_array_length(p_def->'sections') = 0 ELSE true END) THEN
        v_n := v_n + 1; ord := v_n; path := 'sections';
        problem := 'must be a list of at least one section'; RETURN NEXT;
        RETURN;
    END IF;

    FOR v_sec, v_si IN SELECT s.value, s.n
                       FROM jsonb_array_elements(p_def->'sections') WITH ORDINALITY s(value, n) LOOP
        v_p := format('section %s', v_si);
        IF jsonb_typeof(v_sec) <> 'object' THEN
            v_n := v_n + 1; ord := v_n; path := v_p;
            problem := 'must be an object with a title and fields'; RETURN NEXT;
            CONTINUE;
        END IF;
        FOR v_key IN SELECT k FROM jsonb_object_keys(v_sec) k ORDER BY k LOOP
            IF v_key NOT IN ('title', 'fields') THEN
                v_n := v_n + 1; ord := v_n; path := v_p;
                problem := format('%s is not a key of a section', v_key); RETURN NEXT;
            END IF;
        END LOOP;
        IF v_sec ? 'title' AND jsonb_typeof(v_sec->'title') <> 'string' THEN
            v_n := v_n + 1; ord := v_n; path := v_p;
            problem := 'title must be text'; RETURN NEXT;
        END IF;
        IF jsonb_typeof(v_sec->'fields') IS DISTINCT FROM 'array' THEN
            v_n := v_n + 1; ord := v_n; path := v_p;
            problem := 'fields must be a list'; RETURN NEXT;
            CONTINUE;
        END IF;

        FOR v_fld, v_fi IN SELECT f.value, f.n
                           FROM jsonb_array_elements(v_sec->'fields') WITH ORDINALITY f(value, n) LOOP
            v_p := format('section %s field %s', v_si, v_fi);
            IF jsonb_typeof(v_fld) <> 'object' THEN
                v_n := v_n + 1; ord := v_n; path := v_p;
                problem := 'must be an object'; RETURN NEXT;
                CONTINUE;
            END IF;
            FOR v_key IN SELECT k FROM jsonb_object_keys(v_fld) k ORDER BY k LOOP
                IF NOT (v_key = ANY (c_field_keys)) THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := format('%s is not a key of a field', v_key); RETURN NEXT;
                END IF;
            END LOOP;
            v_widget := CASE WHEN jsonb_typeof(v_fld->'widget') = 'string' THEN v_fld->>'widget' END;
            IF v_widget IS NULL OR NOT (v_widget = ANY (c_widgets)) THEN
                v_n := v_n + 1; ord := v_n; path := v_p;
                problem := format('widget must be one of %s', array_to_string(c_widgets, ', '));
                RETURN NEXT;
                CONTINUE;
            END IF;
            FOREACH v_key IN ARRAY ARRAY['label', 'units', 'help', 'text', 'min', 'max'] LOOP
                IF v_fld ? v_key AND jsonb_typeof(v_fld->v_key) <> 'string' THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := format('%s must be text (a JSON string)', v_key); RETURN NEXT;
                END IF;
            END LOOP;
            FOREACH v_key IN ARRAY ARRAY['required', 'show_previous'] LOOP
                IF v_fld ? v_key AND jsonb_typeof(v_fld->v_key) <> 'boolean' THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := format('%s must be true or false', v_key); RETURN NEXT;
                END IF;
            END LOOP;

            IF v_widget IN ('heading', 'instruction') THEN
                IF jsonb_typeof(v_fld->'text') IS DISTINCT FROM 'string'
                   OR btrim(v_fld->>'text') = '' THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := format('a %s needs its text', v_widget); RETURN NEXT;
                END IF;
                FOREACH v_key IN ARRAY ARRAY['variable', 'units', 'required', 'min', 'max',
                                             'options', 'show_previous'] LOOP
                    IF v_fld ? v_key THEN
                        v_n := v_n + 1; ord := v_n; path := v_p;
                        problem := format('a %s takes no %s', v_widget, v_key); RETURN NEXT;
                    END IF;
                END LOOP;
                CONTINUE;
            END IF;

            -- A field that takes a value.
            v_data := v_data + 1;
            IF v_fld ? 'text' THEN
                v_n := v_n + 1; ord := v_n; path := v_p;
                problem := 'text is for headings and instructions; use label or help'; RETURN NEXT;
            END IF;
            v_var := CASE WHEN jsonb_typeof(v_fld->'variable') = 'string' THEN v_fld->>'variable' END;
            IF v_var IS NULL THEN
                v_n := v_n + 1; ord := v_n; path := v_p;
                problem := 'needs a variable, the name its values are stored under'; RETURN NEXT;
            ELSE
                v_p := format('section %s field %s (%s)', v_si, v_fi, v_var);
                IF v_var <> lab.fn_canonical_variable(v_var) THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := format('write the variable name as "%s"',
                                      lab.fn_canonical_variable(v_var));
                    RETURN NEXT;
                ELSIF v_var !~ '^[a-z][a-z0-9_-]*( [a-z0-9_-]+)*$' OR length(v_var) > 63 THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := 'a variable name is words of letters, digits, _ or -, separated '
                               'by single spaces and starting with a letter, at most 63 characters';
                    RETURN NEXT;
                ELSIF v_var = 'entry note' THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := 'entry note is reserved for the note every entry has'; RETURN NEXT;
                ELSIF v_var = ANY (v_fields) THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := 'the variable is already a field of this form'; RETURN NEXT;
                END IF;
                v_fields := v_fields || v_var;
            END IF;
            IF v_fld ? 'label' AND btrim(v_fld->>'label') = '' THEN
                v_n := v_n + 1; ord := v_n; path := v_p;
                problem := 'label must not be blank (leave it out to use the variable''s label)';
                RETURN NEXT;
            END IF;
            v_type := CASE WHEN v_widget IN ('number', 'integer') THEN 'number' ELSE 'text' END;

            IF v_fld ? 'units' THEN
                IF v_type <> 'number' THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := format('a %s field takes no units', v_widget); RETURN NEXT;
                ELSIF jsonb_typeof(v_fld->'units') = 'string'
                      AND (v_fld->>'units' = '' OR v_fld->>'units' <> btrim(v_fld->>'units')) THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := 'units must not be blank or have surrounding spaces'; RETURN NEXT;
                END IF;
            END IF;
            FOREACH v_key IN ARRAY ARRAY['min', 'max'] LOOP
                IF v_fld ? v_key AND jsonb_typeof(v_fld->v_key) = 'string' THEN
                    IF v_type <> 'number' THEN
                        v_n := v_n + 1; ord := v_n; path := v_p;
                        problem := format('a %s field takes no %s', v_widget, v_key); RETURN NEXT;
                    ELSIF (v_widget = 'number' AND NOT lab.fn_form_number_ok(v_fld->>v_key))
                          OR (v_widget = 'integer' AND NOT lab.fn_form_integer_ok(v_fld->>v_key)) THEN
                        v_n := v_n + 1; ord := v_n; path := v_p;
                        problem := format('%s "%s" is not a %s', v_key, v_fld->>v_key,
                                          CASE v_widget WHEN 'integer' THEN 'whole number'
                                                        ELSE 'plain decimal number' END);
                        RETURN NEXT;
                    END IF;
                END IF;
            END LOOP;
            IF v_type = 'number' AND jsonb_typeof(v_fld->'min') = 'string'
               AND jsonb_typeof(v_fld->'max') = 'string'
               AND lab.fn_form_number_ok(v_fld->>'min') AND lab.fn_form_number_ok(v_fld->>'max')
               AND (v_fld->>'min')::numeric > (v_fld->>'max')::numeric THEN
                v_n := v_n + 1; ord := v_n; path := v_p;
                problem := 'min is greater than max'; RETURN NEXT;
            END IF;

            IF v_widget = 'choice' THEN
                IF (CASE WHEN jsonb_typeof(v_fld->'options') = 'array'
                         THEN jsonb_array_length(v_fld->'options') = 0 ELSE true END) THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := 'a choice needs a list of options'; RETURN NEXT;
                ELSE
                    v_vals := '{}';
                    FOR v_opt IN SELECT o.value FROM jsonb_array_elements(v_fld->'options') o LOOP
                        IF jsonb_typeof(v_opt) <> 'object'
                           OR jsonb_typeof(v_opt->'value') IS DISTINCT FROM 'string'
                           OR (v_opt ? 'label' AND jsonb_typeof(v_opt->'label') <> 'string')
                           OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_opt) k
                                      WHERE k NOT IN ('value', 'label')) THEN
                            v_n := v_n + 1; ord := v_n; path := v_p;
                            problem := 'each option is {"value": text, "label": text (optional)}';
                            RETURN NEXT;
                        ELSIF v_opt->>'value' = '' OR v_opt->>'value' <> btrim(v_opt->>'value')
                              OR v_opt->>'value' ~ '[\r\n]' THEN
                            v_n := v_n + 1; ord := v_n; path := v_p;
                            problem := format('option "%s" must be one line, not blank and without '
                                              'surrounding spaces', v_opt->>'value');
                            RETURN NEXT;
                        ELSIF v_opt->>'value' ~ '^[=@]' THEN
                            v_n := v_n + 1; ord := v_n; path := v_p;
                            problem := format('option "%s" starts with "=" or "@", which a '
                                              'spreadsheet would run as a formula', v_opt->>'value');
                            RETURN NEXT;
                        ELSIF v_opt->>'value' = ANY (v_vals) THEN
                            v_n := v_n + 1; ord := v_n; path := v_p;
                            problem := format('option "%s" is listed twice', v_opt->>'value');
                            RETURN NEXT;
                        ELSE
                            v_vals := v_vals || (v_opt->>'value');
                        END IF;
                    END LOOP;
                END IF;
            ELSIF v_fld ? 'options' THEN
                v_n := v_n + 1; ord := v_n; path := v_p;
                problem := format('a %s field takes no options', v_widget); RETURN NEXT;
            END IF;

            IF v_var IS NOT NULL AND v_var = lab.fn_canonical_variable(v_var) THEN
                SELECT v.* INTO v_row FROM lab.variable v WHERE v.name = v_var;
                IF FOUND THEN
                    IF v_row.value_type <> v_type THEN
                        v_n := v_n + 1; ord := v_n; path := v_p;
                        problem := format('variable %s holds %s, so it cannot be a %s field',
                                          v_var, CASE v_row.value_type WHEN 'number' THEN 'numbers'
                                                      ELSE 'text' END, v_widget);
                        RETURN NEXT;
                    END IF;
                    IF v_fld ? 'units' AND (v_fld->>'units') IS DISTINCT FROM v_row.units THEN
                        v_n := v_n + 1; ord := v_n; path := v_p;
                        problem := format('variable %s is recorded in %s, not in %s', v_var,
                                          coalesce(v_row.units, 'no units'), v_fld->>'units');
                        RETURN NEXT;
                    END IF;
                    IF v_row.retired_at IS NOT NULL THEN
                        v_n := v_n + 1; ord := v_n; path := v_p;
                        problem := format('variable %s is retired', v_var); RETURN NEXT;
                    END IF;
                    IF p_strict AND NOT ('event' = ANY (v_row.applies_to)) THEN
                        v_n := v_n + 1; ord := v_n; path := v_p;
                        problem := format('variable %s is not defined for events', v_var);
                        RETURN NEXT;
                    END IF;
                ELSIF p_strict THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := format('variable %s is not defined', v_var); RETURN NEXT;
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    IF v_data = 0 THEN
        v_n := v_n + 1; ord := v_n; path := 'sections';
        problem := 'the form has no field to fill in'; RETURN NEXT;
    END IF;

    -- What the designer puts at the top of the form.
    IF p_def ? 'header' THEN
        IF jsonb_typeof(p_def->'header') <> 'array' THEN
            v_n := v_n + 1; ord := v_n; path := 'header';
            problem := 'must be a list'; RETURN NEXT;
            RETURN;
        END IF;
        FOR v_item, v_hi IN SELECT h.value, h.n
                            FROM jsonb_array_elements(p_def->'header') WITH ORDINALITY h(value, n) LOOP
            v_p := format('header %s', v_hi);
            IF jsonb_typeof(v_item) <> 'object' THEN
                v_n := v_n + 1; ord := v_n; path := v_p;
                problem := 'must be an object'; RETURN NEXT;
                CONTINUE;
            END IF;
            IF v_item ? 'item' THEN
                IF EXISTS (SELECT 1 FROM jsonb_object_keys(v_item) k WHERE k <> 'item')
                   OR jsonb_typeof(v_item->'item') <> 'string'
                   OR NOT ((v_item->>'item') = ANY (c_items)) THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := format('an info item is {"item": one of %s}',
                                      array_to_string(c_items, ', '));
                    RETURN NEXT;
                    CONTINUE;
                END IF;
                v_hkey := 'item:' || (v_item->>'item');
            ELSE
                IF EXISTS (SELECT 1 FROM jsonb_object_keys(v_item) k
                           WHERE k NOT IN ('variable', 'source', 'label'))
                   OR jsonb_typeof(v_item->'variable') IS DISTINCT FROM 'string'
                   OR jsonb_typeof(v_item->'source') IS DISTINCT FROM 'string'
                   OR (v_item ? 'label' AND (jsonb_typeof(v_item->'label') <> 'string'
                                             OR btrim(v_item->>'label') = '')) THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := 'a variable item is {"variable": name, "source": subject, project '
                               'or previous_entry, "label": text (optional)}';
                    RETURN NEXT;
                    CONTINUE;
                END IF;
                v_var := v_item->>'variable';
                v_src := v_item->>'source';
                v_p := format('header %s (%s)', v_hi, v_var);
                v_hkey := 'variable:' || v_src || ':' || v_var;
                IF v_src NOT IN ('subject', 'project', 'previous_entry') THEN
                    v_n := v_n + 1; ord := v_n; path := v_p;
                    problem := 'source must be subject, project or previous_entry'; RETURN NEXT;
                ELSIF v_src = 'previous_entry' THEN
                    IF NOT (v_var = ANY (v_fields)) AND v_var <> 'entry note' THEN
                        v_n := v_n + 1; ord := v_n; path := v_p;
                        problem := 'a value from the previous entry must be a field of this form '
                                   '(or entry note)';
                        RETURN NEXT;
                    END IF;
                ELSE
                    SELECT v.* INTO v_row FROM lab.variable v WHERE v.name = v_var;
                    IF NOT FOUND THEN
                        v_n := v_n + 1; ord := v_n; path := v_p;
                        problem := format('variable %s is not defined', v_var); RETURN NEXT;
                    ELSIF NOT (v_src = ANY (v_row.applies_to)) THEN
                        v_n := v_n + 1; ord := v_n; path := v_p;
                        problem := format('variable %s applies to %s only, not to a %s', v_var,
                                          array_to_string(v_row.applies_to, ', '), v_src);
                        RETURN NEXT;
                    END IF;
                END IF;
            END IF;
            IF v_hkey = ANY (v_hseen) THEN
                v_n := v_n + 1; ord := v_n; path := v_p;
                problem := 'is already in the header'; RETURN NEXT;
            END IF;
            v_hseen := v_hseen || v_hkey;
        END LOOP;
    END IF;
END;
$$;

-- What is wrong with the values of one entry on version p_form_version of
-- form p_form_name, one row per problem; no rows means they can be stored.
-- p_values is {variable: value}, each value the text as typed (a JSON
-- string); a blank or missing value is no value. Every key must be a field
-- of that version. With p_stored the values are ones already in the
-- database (lab.fn_check_integrity): keys that are not fields, which another
-- client may have set on the event, are ignored, and so is a variable
-- retired since.
CREATE OR REPLACE FUNCTION lab.fn_observation_problems(
    p_form_name    text,
    p_form_version integer,
    p_values       jsonb,
    p_stored       boolean DEFAULT false
) RETURNS TABLE (field text, problem text)
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_def    jsonb;
    v_fld    jsonb;
    v_fields text[];
    v_key    text;
    v_val    jsonb;
    v_txt    text;
    v_msg    text;
BEGIN
    SELECT fv.definition INTO v_def FROM lab.form_version fv
    WHERE fv.form_name = p_form_name AND fv.version = p_form_version;
    IF NOT FOUND THEN
        field := ''; problem := format('form %s has no version %s', p_form_name, p_form_version);
        RETURN NEXT;
        RETURN;
    END IF;
    p_values := coalesce(p_values, '{}'::jsonb);
    IF jsonb_typeof(p_values) <> 'object' THEN
        field := ''; problem := 'the values must be a JSON object {variable: value}';
        RETURN NEXT;
        RETURN;
    END IF;
    SELECT coalesce(array_agg(f.value->>'variable'), '{}') INTO v_fields
    FROM jsonb_array_elements(v_def->'sections') s,
         jsonb_array_elements(s.value->'fields') f
    WHERE f.value->>'widget' NOT IN ('heading', 'instruction');

    FOR v_key, v_val IN SELECT e.key, e.value FROM jsonb_each(p_values) e ORDER BY e.key LOOP
        IF NOT (v_key = ANY (v_fields)) THEN
            IF NOT p_stored THEN
                field := v_key;
                problem := format('is not a field of form %s version %s', p_form_name, p_form_version);
                RETURN NEXT;
            END IF;
        ELSIF jsonb_typeof(v_val) NOT IN ('string', 'null') THEN
            field := v_key;
            problem := format('must be sent as text (a JSON string), not as a JSON %s, so that '
                              'it is stored exactly as typed', jsonb_typeof(v_val));
            RETURN NEXT;
        END IF;
    END LOOP;

    FOR v_fld IN SELECT f.value
                 FROM jsonb_array_elements(v_def->'sections') WITH ORDINALITY s(value, sn),
                      jsonb_array_elements(s.value->'fields') WITH ORDINALITY f(value, fn)
                 WHERE f.value->>'widget' NOT IN ('heading', 'instruction')
                 ORDER BY s.sn, f.fn LOOP
        v_key := v_fld->>'variable';
        v_txt := CASE WHEN jsonb_typeof(p_values->v_key) = 'string' THEN p_values->>v_key END;
        IF v_txt IS NULL OR btrim(v_txt) = '' THEN
            IF coalesce((v_fld->>'required')::boolean, false) THEN
                field := v_key; problem := 'is required'; RETURN NEXT;
            END IF;
            CONTINUE;
        END IF;
        v_msg := lab.fn_form_value_problem(v_fld, v_txt);
        IF v_msg IS NOT NULL THEN
            field := v_key; problem := v_msg; RETURN NEXT;
        ELSIF NOT p_stored
              AND EXISTS (SELECT 1 FROM lab.variable v
                          WHERE v.name = v_key AND v.retired_at IS NOT NULL) THEN
            field := v_key; problem := 'its variable has been retired and takes no new values';
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

-- Publish a template: define the variables its fields are bound to (a new
-- variable holds numbers for the number and integer widgets and text for the
-- others, in the field's units, and applies to events; an existing one has
-- 'event' added to its applies_to if it lacks it), create the lab.form row on
-- first publication, and append the definition as the next version.
-- Publishing a definition identical to the latest version appends nothing
-- and returns that version with is_new false. p_label and p_description, when
-- given, also update the template's label and description.
--
--     SELECT * FROM lab.fn_publish_form('daily check', '{"format": 1, "sections": [...]}',
--                                       p_label => 'Daily check');
CREATE OR REPLACE FUNCTION lab.fn_publish_form(
    p_name        text,
    p_definition  jsonb,
    p_label       text DEFAULT NULL,
    p_description text DEFAULT NULL,
    p_note        text DEFAULT NULL,
    p_by          uuid DEFAULT NULL
) RETURNS TABLE (version_number integer, is_new boolean)
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_name     text := lab.fn_canonical_variable(p_name);
    v_form     lab.form%ROWTYPE;
    v_problems text;
    v_detail   text;
    v_fld      jsonb;
    v_var      text;
    v_row      lab.variable%ROWTYPE;
    v_latest   lab.form_version%ROWTYPE;
BEGIN
    IF v_name IS NULL OR v_name !~ '^[a-z][a-z0-9_-]*( [a-z0-9_-]+)*$' OR length(v_name) > 63 THEN
        RAISE EXCEPTION USING
            MESSAGE = format('"%s" is not a valid form name', coalesce(v_name, '')),
            HINT    = 'Use words of letters, digits, _ or -, separated by single spaces and '
                      'starting with a letter, at most 63 characters: daily check';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        concat_ws(':', 'lab.form_version', v_name), 0));

    SELECT string_agg(p.path || ': ' || p.problem, '; ' ORDER BY p.ord),
           jsonb_agg(jsonb_build_object('path', p.path, 'problem', p.problem) ORDER BY p.ord)::text
      INTO v_problems, v_detail
    FROM lab.fn_form_definition_problems(p_definition, false) p;
    IF v_problems IS NOT NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'CLB02',
            MESSAGE = format('form %s: the definition is not valid: %s', v_name, v_problems),
            DETAIL  = v_detail;
    END IF;

    SELECT f.* INTO v_form FROM lab.form f WHERE f.name = v_name;
    IF NOT FOUND THEN
        INSERT INTO lab.form (name, label, description, created_by)
        VALUES (v_name, p_label, p_description, coalesce(p_by, lab.fn_current_person()));
    ELSE
        IF v_form.retired_at IS NOT NULL THEN
            RAISE EXCEPTION USING
                MESSAGE = format('form %s is retired and takes no new versions', v_name),
                HINT    = 'Clear its retired_at first.';
        END IF;
        IF nullif(btrim(p_label), '') IS NOT NULL AND p_label IS DISTINCT FROM v_form.label THEN
            UPDATE lab.form SET label = p_label WHERE name = v_name;
        END IF;
        IF p_description IS NOT NULL AND p_description IS DISTINCT FROM v_form.description THEN
            UPDATE lab.form SET description = nullif(p_description, '') WHERE name = v_name;
        END IF;
    END IF;

    FOR v_fld IN SELECT f.value
                 FROM jsonb_array_elements(p_definition->'sections') s,
                      jsonb_array_elements(s.value->'fields') f
                 WHERE f.value->>'widget' NOT IN ('heading', 'instruction') LOOP
        v_var := v_fld->>'variable';
        SELECT v.* INTO v_row FROM lab.variable v WHERE v.name = v_var;
        IF NOT FOUND THEN
            PERFORM lab.fn_define_variable(
                v_var,
                CASE WHEN v_fld->>'widget' IN ('number', 'integer') THEN 'number' ELSE 'text' END,
                v_fld->>'units', coalesce(v_fld->>'label', v_var), NULL, ARRAY['event'], p_by);
        ELSIF NOT ('event' = ANY (v_row.applies_to)) THEN
            UPDATE lab.variable SET applies_to = applies_to || 'event'::text WHERE name = v_var;
        END IF;
    END LOOP;

    SELECT fv.* INTO v_latest FROM lab.form_version fv
    WHERE fv.form_name = v_name ORDER BY fv.version DESC LIMIT 1;
    IF FOUND AND v_latest.definition = p_definition THEN
        version_number := v_latest.version;
        is_new := false;
        RETURN NEXT;
        RETURN;
    END IF;
    INSERT INTO lab.form_version (form_name, definition, note, created_by)
    VALUES (v_name, p_definition, nullif(btrim(p_note), ''), p_by)
    RETURNING version INTO version_number;
    is_new := true;
    RETURN NEXT;
END;
$$;

-- Put a template to use for a subject: returns the subject form for
-- (subject, project, template), creating it if there is none. The project
-- defaults to the subject's own and the version to the template's latest.
-- An existing subject form is returned as it is (whatever p_form_version
-- says), and brought back into use if it had been retired.
CREATE OR REPLACE FUNCTION lab.fn_add_subject_form(
    p_subject_id   text,
    p_form_name    text,
    p_project_id   uuid DEFAULT NULL,
    p_form_version integer DEFAULT NULL,
    p_notes        text DEFAULT NULL,
    p_by           uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_name    text := lab.fn_canonical_variable(p_form_name);
    v_project uuid := p_project_id;
    v_form    lab.form%ROWTYPE;
    v_id      uuid;
    v_retired timestamptz;
BEGIN
    IF v_project IS NULL THEN
        SELECT s.project_id INTO v_project FROM lab.subject s WHERE s.subject_id = p_subject_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM lab.subject s WHERE s.subject_id = p_subject_id) THEN
        RAISE EXCEPTION 'subject % does not exist', coalesce(p_subject_id, 'NULL');
    END IF;
    SELECT f.* INTO v_form FROM lab.form f WHERE f.name = v_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'form % does not exist', coalesce(v_name, 'NULL');
    END IF;
    IF v_form.retired_at IS NOT NULL THEN
        RAISE EXCEPTION USING
            MESSAGE = format('form %s is retired', v_name),
            HINT    = 'Clear its retired_at to use it again.';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        concat_ws(':', 'lab.subject_form', p_subject_id, v_project, v_name), 0));
    SELECT sf.subject_form_id, sf.retired_at INTO v_id, v_retired
    FROM lab.subject_form sf
    WHERE sf.subject_id = p_subject_id AND sf.project_id = v_project AND sf.form_name = v_name;
    IF FOUND THEN
        IF v_retired IS NOT NULL THEN
            UPDATE lab.subject_form SET retired_at = NULL WHERE subject_form_id = v_id;
        END IF;
        RETURN v_id;
    END IF;
    INSERT INTO lab.subject_form (subject_id, project_id, form_name, form_version, notes, created_by)
    VALUES (p_subject_id, v_project, v_name, p_form_version, nullif(btrim(p_notes), ''),
            coalesce(p_by, lab.fn_current_person()))
    RETURNING subject_form_id INTO v_id;
    RETURN v_id;
END;
$$;

-- Record one entry on a subject form, or a correction of one, in one
-- transaction. Made for a client that may send the same entry more than once
-- (the browser keeps an entry until the server confirms it, and sends it
-- again after a dropped connection): the client mints p_event_id, and the
-- database stores a digest of the entry in event.attributes.client_digest.
--   * An event p_event_id that is this same entry (same digest) is
--     'existing' and nothing is written. That is decided before anything is
--     checked, so an entry already stored is never refused on replay.
--   * An event p_event_id that is anything else raises SQLSTATE CLB01.
--   * Values that break the rules of the form version (lab.fn_observation_problems),
--     or a blank session label, raise SQLSTATE CLB02 with the problems as a
--     JSON list [{field, problem}] in DETAIL.
--   * Otherwise the event, its detail row and its values are written and the
--     result is 'inserted'.
-- p_values is {variable: text as typed}; p_note is the entry's note, stored
-- in the 'entry note' variable. occurred_at is when the session happened.
--
-- A correction (p_supersedes) stays on the same subject form and keeps the
-- form version of the entry it corrects. trg_event_carry_variables copies the
-- predecessor's values onto it; then values that changed are set, values
-- that were cleared are unset, and unchanged values keep their history. The
-- predecessor's current tags are carried forward (retired tags are not: a
-- retired tag cannot be assigned, and lab.fn_check_integrity reports it).
-- Correcting an entry that has already been corrected raises SQLSTATE CLB03
-- naming the current version.
CREATE OR REPLACE FUNCTION lab.fn_record_observation(
    p_event_id        uuid,
    p_subject_form_id uuid,
    p_occurred_at     timestamptz,
    p_session_label   text,
    p_values          jsonb,
    p_note            text DEFAULT NULL,
    p_supersedes      uuid DEFAULT NULL,
    p_session_id      uuid DEFAULT NULL,
    p_attributes      jsonb DEFAULT NULL,
    p_recorded_by     uuid DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_values   jsonb := coalesce(p_values, '{}'::jsonb);
    v_note     text := CASE WHEN btrim(coalesce(p_note, '')) = '' THEN NULL ELSE p_note END;
    v_digest   text;
    v_type     text;
    v_stored   text;
    v_sf       lab.subject_form%ROWTYPE;
    v_version  integer;
    v_old_sf   uuid;
    v_next     uuid;
    v_problems text;
    v_detail   text;
    v_fld      jsonb;
    v_var      text;
    v_new      text;
    v_cur      text;
BEGIN
    IF p_event_id IS NULL OR p_subject_form_id IS NULL OR p_occurred_at IS NULL THEN
        RAISE EXCEPTION 'an entry needs its event id, its subject form and when it occurred';
    END IF;
    IF jsonb_typeof(v_values) <> 'object' THEN
        RAISE EXCEPTION 'the values must be a JSON object {variable: value}';
    END IF;
    IF p_attributes IS NOT NULL AND jsonb_typeof(p_attributes) <> 'object' THEN
        RAISE EXCEPTION 'the attributes must be a JSON object';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        concat_ws(':', 'lab.observation', p_event_id), 0));

    -- The digest covers what the entry says, not how it was sent: blank
    -- values are left out (blank is no value), and the time is written in
    -- UTC so that the same instant sent with another offset is the same entry.
    v_digest := encode(sha256(convert_to(jsonb_build_object(
        'subject_form_id', p_subject_form_id,
        'occurred_at', to_char(p_occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'session_label', p_session_label,
        'session_id', p_session_id,
        'supersedes', p_supersedes,
        'note', v_note,
        'values', (SELECT coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
                   FROM jsonb_each(v_values) e
                   WHERE NOT (jsonb_typeof(e.value) = 'null'
                              OR (jsonb_typeof(e.value) = 'string'
                                  AND btrim(e.value #>> '{}') = ''))))::text, 'UTF8')), 'hex');

    SELECT e.event_type, e.attributes->>'client_digest' INTO v_type, v_stored
    FROM lab.event e WHERE e.event_id = p_event_id;
    IF FOUND THEN
        IF v_type = 'observation' AND v_stored = v_digest THEN
            RETURN 'existing';
        END IF;
        RAISE EXCEPTION USING
            ERRCODE = 'CLB01',
            MESSAGE = format('event %s already exists and is not this entry', p_event_id),
            HINT    = 'An entry that was changed after it was saved is a correction: '
                      'send it with a new event id and p_supersedes.';
    END IF;

    SELECT sf.* INTO v_sf FROM lab.subject_form sf WHERE sf.subject_form_id = p_subject_form_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'subject form % does not exist', p_subject_form_id;
    END IF;

    IF p_supersedes IS NULL THEN
        v_version := v_sf.form_version;
    ELSE
        SELECT o.subject_form_id, o.form_version INTO v_old_sf, v_version
        FROM lab.observation_event o WHERE o.event_id = p_supersedes;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'event % is not an entry on a form, so this cannot correct it',
                p_supersedes;
        END IF;
        IF v_old_sf <> p_subject_form_id THEN
            RAISE EXCEPTION USING
                MESSAGE = format('entry %s was made on subject form %s; its correction must be too',
                                 p_supersedes, v_old_sf);
        END IF;
        SELECT e.event_id INTO v_next FROM lab.event e WHERE e.supersedes = p_supersedes;
        IF v_next IS NOT NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = 'CLB03',
                MESSAGE = format('entry %s has already been corrected; its current version is %s',
                                 p_supersedes, lab.fn_event_current(p_supersedes)),
                HINT    = 'Correct the current version instead.';
        END IF;
    END IF;

    SELECT string_agg(x.field || ': ' || x.problem, '; '),
           jsonb_agg(jsonb_build_object('field', x.field, 'problem', x.problem))::text
      INTO v_problems, v_detail
    FROM (SELECT p.field, p.problem
          FROM lab.fn_observation_problems(v_sf.form_name, v_version, v_values) p
          UNION ALL
          SELECT 'session label', 'must not be blank or have surrounding spaces'
          WHERE p_session_label IS NULL OR p_session_label = ''
             OR p_session_label <> btrim(p_session_label)
          UNION ALL
          SELECT 'entry note', 'starts with "=" or "@", which a spreadsheet opening the CSV '
                               'would run as a formula: start it with another character'
          WHERE v_note ~ '^[=@]') x;
    IF v_problems IS NOT NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'CLB02',
            MESSAGE = format('the entry cannot be stored: %s', v_problems),
            DETAIL  = v_detail;
    END IF;

    INSERT INTO lab.event (event_id, event_type, subject_id, session_id, occurred_at,
                           recorded_by, supersedes, attributes)
    VALUES (p_event_id, 'observation', v_sf.subject_id, p_session_id, p_occurred_at,
            p_recorded_by, p_supersedes,
            coalesce(p_attributes, '{}'::jsonb) || jsonb_build_object('client_digest', v_digest));
    INSERT INTO lab.observation_event (event_id, subject_form_id, form_name, form_version,
                                       session_label)
    VALUES (p_event_id, p_subject_form_id, v_sf.form_name, v_version, p_session_label);

    -- Values: compared as text with what the event already holds (nothing for
    -- a new entry, the carried values for a correction).
    FOR v_fld IN
        SELECT f.value
        FROM lab.form_version fv,
             jsonb_array_elements(fv.definition->'sections') s,
             jsonb_array_elements(s.value->'fields') f
        WHERE fv.form_name = v_sf.form_name AND fv.version = v_version
          AND f.value->>'widget' NOT IN ('heading', 'instruction')
        UNION ALL
        SELECT jsonb_build_object('variable', 'entry note', 'widget', 'longtext')
    LOOP
        v_var := v_fld->>'variable';
        IF v_var = 'entry note' THEN
            v_new := v_note;
        ELSE
            v_new := CASE WHEN jsonb_typeof(v_values->v_var) = 'string'
                               AND btrim(v_values->>v_var) <> ''
                          THEN v_values->>v_var END;
        END IF;
        SELECT CASE WHEN vv.op = 'set' THEN coalesce(vv.value_text, vv.value_num::text) END
          INTO v_cur
        FROM lab.variable_value vv
        WHERE vv.event_id = p_event_id AND vv.variable = v_var
        ORDER BY vv.value_id DESC LIMIT 1;
        IF NOT FOUND THEN
            v_cur := NULL;
        END IF;
        IF v_new IS NULL THEN
            IF v_cur IS NOT NULL THEN
                PERFORM lab.fn_unset_variable('event', p_event_id::text, v_var,
                                              'cleared in the correction', p_recorded_by);
            END IF;
        ELSIF v_new IS DISTINCT FROM v_cur THEN
            IF v_fld->>'widget' IN ('number', 'integer') THEN
                PERFORM lab.fn_set_variable('event', p_event_id::text, v_var,
                                            p_number => v_new::numeric, p_by => p_recorded_by);
            ELSE
                PERFORM lab.fn_set_variable('event', p_event_id::text, v_var,
                                            p_text => v_new, p_by => p_recorded_by);
            END IF;
        END IF;
    END LOOP;

    IF p_supersedes IS NOT NULL THEN
        INSERT INTO lab.tag_assignment (entity_kind, event_id, tag, op, note, applied_by)
        SELECT 'event', p_event_id, c.tag, 'add',
               format('carried forward from %s', p_supersedes), p_recorded_by
        FROM lab.tag_current c
        JOIN lab.tag t ON t.tag = c.tag
        WHERE c.entity_kind = 'event' AND c.event_id = p_supersedes AND t.retired_at IS NULL
        ORDER BY c.tag;
    END IF;
    RETURN 'inserted';
END;
$$;

-- Change the note of an entry without correcting it: the note is the entry's
-- 'entry note' variable, so this appends a value row (the earlier text stays
-- in the log with who wrote it). A blank note clears it. Text equal to the
-- current note writes nothing, so sending the same change twice is harmless.
-- Only the current version of an entry takes a new note. Returns 'set',
-- 'unset' or 'unchanged'.
CREATE OR REPLACE FUNCTION lab.fn_set_entry_note(
    p_event_id uuid,
    p_note     text,
    p_by       uuid DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_new text := CASE WHEN btrim(coalesce(p_note, '')) = '' THEN NULL ELSE p_note END;
    v_cur text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM lab.observation_event o WHERE o.event_id = p_event_id) THEN
        RAISE EXCEPTION 'event % is not an entry on a form', coalesce(p_event_id::text, 'NULL');
    END IF;
    IF EXISTS (SELECT 1 FROM lab.event e WHERE e.supersedes = p_event_id) THEN
        RAISE EXCEPTION USING
            MESSAGE = format('entry %s has been corrected; its current version is %s',
                             p_event_id, lab.fn_event_current(p_event_id)),
            HINT    = 'Change the note of the current version.';
    END IF;
    IF EXISTS (SELECT 1 FROM lab.retraction r WHERE r.event_id = p_event_id) THEN
        RAISE EXCEPTION 'entry % has been withdrawn', p_event_id;
    END IF;
    IF v_new ~ '^[=@]' THEN
        RAISE EXCEPTION USING
            ERRCODE = 'CLB02',
            MESSAGE = 'the note starts with "=" or "@", which a spreadsheet opening the CSV '
                      'would run as a formula: start it with another character',
            DETAIL  = jsonb_build_array(jsonb_build_object(
                          'field', 'entry note',
                          'problem', 'starts with "=" or "@"'))::text;
    END IF;
    -- The same lock trg_variable_value_policy takes, so that the comparison
    -- and the write are one step.
    PERFORM pg_advisory_xact_lock(hashtextextended(
        concat_ws(':', 'lab.variable', 'event', p_event_id::text, 'entry note'), 0));
    SELECT CASE WHEN vv.op = 'set' THEN vv.value_text END INTO v_cur
    FROM lab.variable_value vv
    WHERE vv.event_id = p_event_id AND vv.variable = 'entry note'
    ORDER BY vv.value_id DESC LIMIT 1;
    IF v_new IS NULL THEN
        IF v_cur IS NULL THEN
            RETURN 'unchanged';
        END IF;
        PERFORM lab.fn_unset_variable('event', p_event_id::text, 'entry note', NULL, p_by);
        RETURN 'unset';
    END IF;
    IF v_new = v_cur THEN
        RETURN 'unchanged';
    END IF;
    PERFORM lab.fn_set_variable('event', p_event_id::text, 'entry note', p_text => v_new,
                                p_by => p_by);
    RETURN 'set';
END;
$$;

-- The first version of the correction chain an event belongs to: the id an
-- entry keeps through its corrections.
CREATE OR REPLACE FUNCTION lab.fn_event_original(p_event_id uuid) RETURNS uuid
LANGUAGE plpgsql STABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_id   uuid := p_event_id;
    v_prev uuid;
BEGIN
    LOOP
        SELECT e.supersedes INTO v_prev FROM lab.event e WHERE e.event_id = v_id;
        EXIT WHEN v_prev IS NULL;
        v_id := v_prev;
    END LOOP;
    RETURN v_id;
END;
$$;

-- Every active entry on a form (neither corrected nor withdrawn), with its
-- values. field_values is {variable: value} over the entry's current values,
-- each as the text the database stored (a JSON string, never a JSON number:
-- 1.50 stays 1.50), the note left out; note is the entry's note. entry_id is
-- the id of the entry's first version, which its corrections keep. Read per
-- event through ix_variable_value_event, not through lab.variable_current.
CREATE VIEW lab.observation_active AS
    SELECT e.event_id,
           lab.fn_event_original(e.event_id) AS entry_id,
           e.supersedes,
           o.subject_form_id, e.subject_id, sf.project_id,
           o.form_name, o.form_version, o.session_label,
           e.occurred_at, e.recorded_at, e.recorded_by, e.recorded_login, e.session_id,
           e.attributes,
           coalesce(v.field_values, '{}'::jsonb) AS field_values,
           v.note
    FROM lab.event_active e
    JOIN lab.observation_event o ON o.event_id = e.event_id
    JOIN lab.subject_form sf ON sf.subject_form_id = o.subject_form_id
    LEFT JOIN LATERAL (
        SELECT jsonb_object_agg(c.variable, c.value)
                   FILTER (WHERE c.variable <> 'entry note') AS field_values,
               max(c.value) FILTER (WHERE c.variable = 'entry note') AS note
        FROM (SELECT DISTINCT ON (vv.variable) vv.variable, vv.op,
                     coalesce(vv.value_text, vv.value_num::text) AS value
              FROM lab.variable_value vv
              WHERE vv.event_id = e.event_id
              ORDER BY vv.variable, vv.value_id DESC) c
        WHERE c.op = 'set'
    ) v ON true;

-- The fields of all of a subject's forms in one project, in the order the
-- per-subject, per-project CSV (web/forms/) lists them: form by form in the
-- order the forms were added to the subject (by name when two were added in
-- one transaction, which gives them the same created_at), and within a form in the order
-- the fields first appear across its versions (a field added in version 2
-- comes after version 1's). A variable on two forms is one column, listed
-- where it first appears. The versions counted are those up to the one each
-- subject form uses, and any its entries were made on.
CREATE OR REPLACE FUNCTION lab.fn_subject_project_columns(p_subject_id text, p_project_id uuid)
RETURNS TABLE (column_no integer, variable text, label text, units text, value_type text,
               widget text, form_name text)
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
    WITH sf AS (
        SELECT s.subject_form_id, s.form_name, s.form_version,
               row_number() OVER (ORDER BY s.created_at, s.form_name) AS form_no
        FROM lab.subject_form s
        WHERE s.subject_id = p_subject_id AND s.project_id = p_project_id
    ), f AS (
        SELECT sf.form_no, sf.form_name, fv.version, sec.n AS section_no, fld.n AS field_no,
               fld.value AS field
        FROM sf
        JOIN lab.form_version fv
          ON fv.form_name = sf.form_name
         AND (fv.version <= sf.form_version
              OR EXISTS (SELECT 1 FROM lab.observation_event o
                         WHERE o.subject_form_id = sf.subject_form_id
                           AND o.form_version = fv.version))
        CROSS JOIN LATERAL jsonb_array_elements(fv.definition->'sections')
                               WITH ORDINALITY AS sec(value, n)
        CROSS JOIN LATERAL jsonb_array_elements(sec.value->'fields')
                               WITH ORDINALITY AS fld(value, n)
        WHERE fld.value->>'widget' NOT IN ('heading', 'instruction')
    ), firsts AS (
        SELECT DISTINCT ON (f.field->>'variable')
               f.field->>'variable' AS variable, f.form_no, f.version, f.section_no,
               f.field_no, f.form_name, f.field
        FROM f
        ORDER BY f.field->>'variable', f.form_no, f.version, f.section_no, f.field_no
    )
    SELECT (row_number() OVER (ORDER BY x.form_no, x.version, x.section_no, x.field_no))::integer,
           x.variable, coalesce(x.field->>'label', v.label), v.units, v.value_type,
           x.field->>'widget', x.form_name
    FROM firsts x
    JOIN lab.variable v ON v.name = x.variable
    ORDER BY 1;
$$;

-- What is wrong with a tag filter, one row per faulty token; no rows means the
-- filter is sound. lab.fn_tag_match deliberately treats an unknown token as
-- "no entity has it", which is right for matching but makes a typo silent:
-- NotTags = 'qc:fial' excludes nothing and returns the failed recordings.
-- The vocabulary catches typos on write; clients call this once per query to
-- catch them on read. p_tokens is every token of the filter, whichever list
-- it came from. Reported: a namespace that does not exist, a namespace whose
-- tags cannot be put on p_kind, and (unless the token is 'ns:*') a tag that
-- is not registered. Blank tokens are ignored, as in lab.fn_tag_match.
CREATE OR REPLACE FUNCTION lab.fn_tag_filter_problems(
    p_kind   text,
    p_tokens text[]
) RETURNS TABLE (token text, problem text)
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT k.raw,
           CASE
               WHEN n.namespace IS NULL THEN
                   format('tag namespace %s does not exist', k.ns)
               WHEN NOT (p_kind = ANY (n.applies_to)) THEN
                   format('tags of namespace %s apply to %s only, not to %s',
                          k.ns, array_to_string(n.applies_to, ', '), p_kind)
               WHEN n.open_vocabulary THEN
                   format('tag %s is not registered, so nothing can carry it', k.t)
               ELSE
                   format('tag %s is not registered (values of %s: %s)', k.t, k.ns,
                          (SELECT coalesce(string_agg(v.value, ', ' ORDER BY v.value), 'none')
                           FROM lab.tag v WHERE v.namespace = k.ns))
           END
    FROM (SELECT u.raw, c.t, split_part(c.t, ':', 1) AS ns, c.t LIKE '%:*' AS wild
          FROM unnest(p_tokens) u(raw)
          CROSS JOIN LATERAL (SELECT lab.fn_canonical_tag(u.raw) AS t) c
          WHERE btrim(u.raw) <> '') k
    LEFT JOIN lab.tag_namespace n ON n.namespace = k.ns
    LEFT JOIN lab.tag t ON t.tag = k.t
    WHERE n.namespace IS NULL
       OR NOT (p_kind = ANY (n.applies_to))
       OR (NOT k.wild AND t.tag IS NULL);
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
        UNION ALL SELECT event_id FROM lab.analysis_event
        UNION ALL SELECT event_id FROM lab.observation_event)

    UNION ALL
    -- Non-analysis events with no subject. event_subject_required_ck rejects
    -- these on insert; this reports rows that predate the constraint in a
    -- database migrated from the first pre-launch schema (where it may be
    -- NOT VALID).
    SELECT 'warning', 'event_missing_subject', e.event_id::text,
           format('%s event has no subject_id', e.event_type)
    FROM lab.event e
    WHERE e.subject_id IS NULL AND e.event_type <> 'analysis'

    UNION ALL
    -- Artifacts whose file failed its most recent integrity check. By file,
    -- not by row (lab.artifact_verification_latest): a correction inserts a
    -- new artifact row for the same file, and the failure must follow it.
    SELECT 'error', 'artifact_verification_failed', a.artifact_id::text,
           format('latest verification is %s (%s)', v.status, v.verified_at)
    FROM lab.artifact_present a
    JOIN lab.artifact_verification_latest v ON v.artifact_id = a.artifact_id
    WHERE v.status <> 'ok'

    UNION ALL
    -- Recorded before it happened: usually a timezone bug in a client.
    SELECT 'warning', 'event_recorded_before_occurred', e.event_id::text,
           format('occurred_at %s is after recorded_at %s', e.occurred_at, e.recorded_at)
    FROM lab.event e
    WHERE e.occurred_at > e.recorded_at + interval '1 day'

    UNION ALL
    -- Active artifacts whose file has never been checked at all (again by
    -- file, so a correction does not make a verified file look unchecked).
    SELECT 'warning', 'artifact_never_verified', a.artifact_id::text,
           format('registered %s, no verification recorded', a.created_at)
    FROM lab.artifact_present a
    WHERE NOT EXISTS (SELECT 1 FROM lab.artifact_verification_latest v
                      WHERE v.artifact_id = a.artifact_id)

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
    -- Active artifacts filed under a different animal or session than the
    -- event that produced them. trg_artifact_matches_event rejects these on
    -- insert; this reports rows that predate it (pre-launch schema version 4).
    SELECT 'warning', 'artifact_event_mismatch', a.artifact_id::text,
           format('filed under subject %s / session %s, but producing event %s is about '
                  'subject %s / session %s',
                  coalesce(a.subject_id, 'none'), coalesce(a.session_id::text, 'none'),
                  e.event_id, coalesce(e.subject_id, 'none'), coalesce(e.session_id::text, 'none'))
    FROM lab.artifact_active a
    JOIN lab.event e ON e.event_id = a.produced_by_event_id
    WHERE (a.subject_id IS NOT NULL AND e.subject_id IS NOT NULL AND a.subject_id <> e.subject_id)
       OR (a.session_id IS NOT NULL AND e.session_id IS NOT NULL AND a.session_id <> e.session_id)

    UNION ALL
    -- Active corrections that dropped every input: an active event whose
    -- superseded predecessor consumed artifacts while it declares none, so
    -- lineage through it stops. CarasLabDB copies the edges forward; this
    -- catches corrections made some other way. A correction that re-declares
    -- a different, non-empty set of inputs is deliberate and not reported.
    SELECT 'warning', 'input_not_carried_forward', e.event_id::text,
           format('supersedes event %s, which consumed %s artifact(s), but declares no inputs',
                  e.supersedes,
                  (SELECT count(*) FROM lab.event_input o WHERE o.event_id = e.supersedes))
    FROM lab.event_active e
    WHERE e.supersedes IS NOT NULL
      AND EXISTS (SELECT 1 FROM lab.event_input o WHERE o.event_id = e.supersedes)
      AND NOT EXISTS (SELECT 1 FROM lab.event_input n WHERE n.event_id = e.event_id)

    UNION ALL
    -- More than one current tag in a single-valued namespace on one entity.
    -- trg_tag_assignment_policy prevents it; this reports assignments that
    -- raced before pre-launch schema version 4 made the check race-free.
    SELECT 'error', 'tag_cardinality_violation', c.entity_id,
           format('%s has %s current tags in single-valued namespace %s: %s',
                  c.entity_kind, count(*), c.namespace, string_agg(c.tag, ', ' ORDER BY c.tag))
    FROM lab.tag_current c
    JOIN lab.tag_namespace n ON n.namespace = c.namespace
    WHERE n.cardinality = 'single'
    GROUP BY c.entity_kind, c.entity_id, c.namespace
    HAVING count(*) > 1

    UNION ALL
    -- Active artifacts whose producing event has been retracted (in its
    -- current version): the event was withdrawn but its files are still
    -- listed. Retract each file too, or supersede it with
    -- produced_by_event_id set to the event it belongs to.
    SELECT 'warning', 'artifact_producer_retracted', a.artifact_id::text,
           format('produced by event %s, which was retracted: %s', r.event_id, r.reason)
    FROM lab.artifact_active a
    JOIN lab.retraction r ON r.event_id = lab.fn_event_current(a.produced_by_event_id)

    UNION ALL
    -- Active events that consumed an artifact since retracted: the analysis
    -- rests on a file the lab has withdrawn.
    SELECT 'warning', 'input_retracted', e.event_id::text,
           format('consumed artifact %s, which was retracted: %s', ei.artifact_id, r.reason)
    FROM lab.event_active e
    JOIN lab.event_input ei ON ei.event_id = e.event_id
    JOIN lab.retraction r ON r.artifact_id = lab.fn_artifact_current(ei.artifact_id)

    UNION ALL
    -- Two present artifacts at one path: the file can only be one of them. A
    -- file overwritten without a 'replaced' disposition shows up here.
    SELECT 'warning', 'duplicate_active_path',
           a.storage_root_id || ':' || a.relative_path,
           format('%s present artifacts share this path', count(*))
    FROM lab.artifact_present a
    GROUP BY a.storage_root_id, a.relative_path
    HAVING count(*) > 1

    UNION ALL
    -- A file recorded as replaced, moved or deleted that a later check found
    -- at its path with its bytes: one of the two records is wrong.
    SELECT 'warning', 'disposed_file_found', a.artifact_id::text,
           format('recorded as %s at %s, but verified ok at %s', d.disposition,
                  d.occurred_at, v.verified_at)
    FROM lab.artifact_active a
    JOIN lab.artifact_disposition_latest d
      ON d.artifact_id = a.artifact_id AND d.disposition <> 'restored'
    JOIN lab.artifact_verification_latest v
      ON v.artifact_id = a.artifact_id AND v.status = 'ok' AND v.verified_at > d.occurred_at

    UNION ALL
    -- Active form entries whose current values break the rules of the form
    -- version they were made on: a required value unset, a number outside its
    -- range, a choice that is not an option. lab.fn_record_observation refuses
    -- such entries; this catches values changed afterwards by another client
    -- (lab.fn_set_variable / fn_unset_variable on the event). Variables on the
    -- event that are not fields of its form are not judged.
    SELECT 'warning', 'observation_invalid', oa.event_id::text,
           format('entry on form %s version %s: %s', oa.form_name, oa.form_version,
                  string_agg(p.field || ': ' || p.problem, '; ' ORDER BY p.field))
    FROM lab.observation_active oa
    CROSS JOIN LATERAL lab.fn_observation_problems(oa.form_name, oa.form_version,
                                                   oa.field_values, true) p
    GROUP BY oa.event_id, oa.form_name, oa.form_version;
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
    ('analysis','Analysis run'), ('observation','Observation (form entry)')
ON CONFLICT (code) DO NOTHING;

-- The note every form entry has (lab.fn_record_observation,
-- lab.fn_set_entry_note). Reserved: lab.fn_form_definition_problems refuses a
-- form field bound to it.
INSERT INTO lab.variable (name, label, description, value_type, applies_to) VALUES
    ('entry note', 'Note',
     'The note on a form entry (an observation event). It can be changed after the entry is '
     'made, with lab.fn_set_entry_note; every earlier text stays in the value log.',
     'text', ARRAY['event'])
ON CONFLICT (name) DO NOTHING;

INSERT INTO lab.artifact_role (code, label) VALUES
    ('raw','Raw acquisition'), ('spikes','Spike times'), ('lfp','LFP'),
    ('waveforms','Spike waveforms'), ('video','Behavioral video'),
    ('figure','Figure'), ('report','Report'), ('derived','Derived data'),
    ('other','Other')
ON CONFLICT (code) DO NOTHING;

INSERT INTO lab.acquisition_system (code, label) VALUES
    ('intan_rhx','Intan RHX'), ('open_ephys','Open Ephys'), ('tdt_synapse','TDT Synapse')
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
-- design_docs/migrations/ (none before launch) and with the client constants
-- that check it (CarasLabDB.SchemaVersionExpected,
-- caraslabdb_mcp.db.SCHEMA_VERSION).
INSERT INTO lab.schema_version (version, description) VALUES
    (1, 'Fresh install from schema.sql')
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
-- trg_subject_id_guard uses that same privilege to decide who may change a
-- subject id at all.
--
-- Apply this file as a dedicated, non-superuser owner role rather than as the
-- postgres superuser: the owner can drop the immutability triggers, and
-- cascaded updates run with the owner's privileges.
