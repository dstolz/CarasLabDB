-- ============================================================================
-- Lab Metadata System — schema DDL (PostgreSQL 14+)
-- ============================================================================
-- Canonical, runnable schema for the append-only event log, artifact index, and
-- provenance DAG. See design_docs/database-design.md for the ER diagram and the
-- table-by-table rationale. Apply against a fresh database, e.g.:
--
--     createdb lab && psql -d lab -f design_docs/schema.sql
--
-- Requires privileges to create a schema. gen_random_uuid() is in core since
-- PG 13; the pgcrypto line is a fallback for older servers.
-- ============================================================================

-- CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- only needed on PG < 13
CREATE SCHEMA IF NOT EXISTS lab;

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
    UNIQUE (storage_root_id, relative_path, checksum),
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
    -- and 'ab..' are two different rows under the UNIQUE above and the same
    -- bytes get registered twice.
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

-- ---------------------------------------------------------------------------
-- Immutability + validation triggers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lab.fn_forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- Narrow, audited escape hatch for identity maintenance only. Renaming a
    -- subject cascades an UPDATE into these append-only tables (see
    -- lab.fn_rename_subject), which is a relabelling of *who* a row is about,
    -- not a change to *what happened*. DELETE and TRUNCATE are never allowed,
    -- and the flag is transaction-local (set_config(..., is_local => true)).
    IF TG_OP = 'UPDATE'
       AND coalesce(current_setting('lab.maintenance', true), '') = 'subject_rename'
    THEN
        RETURN NEW;
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
        'artifact','event_input'
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
-- UNIQUE(storage_root_id, relative_path, checksum) instead of creating a
-- second artifact row for the identical file.
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
    BEFORE INSERT OR UPDATE ON lab.artifact_verification
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
-- lab.fn_rename_subject performs the rename behind a transaction-local flag
-- that fn_forbid_mutation honours for UPDATE only. Every rename is recorded.
CREATE TABLE lab.maintenance_log (
    maintenance_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    performed_at   timestamptz NOT NULL DEFAULT now(),
    performed_by   text NOT NULL DEFAULT current_user,
    operation      text NOT NULL,
    details        jsonb NOT NULL DEFAULT '{}'::jsonb
);

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
    PERFORM set_config('lab.maintenance', 'subject_rename', true);
    UPDATE lab.subject SET subject_id = p_new WHERE subject_id = p_old;
    PERFORM set_config('lab.maintenance', '', true);

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

-- ---------------------------------------------------------------------------
-- Roles (deployment-specific -- intentionally not created here)
-- ---------------------------------------------------------------------------
-- This file creates no roles: role names, passwords and cluster membership are
-- per-deployment, and roles are cluster-wide rather than database-scoped.
--
-- Do create a read-only role for the consumers that only ever read -- the web
-- dashboard's server and the MCP server. The triggers above stop UPDATE and
-- DELETE, but nothing in SQL stops an INSERT of a bogus event, and a client
-- that cannot write is a stronger guarantee than one that merely does not:
--
--     CREATE ROLE lab_ro LOGIN PASSWORD '...';
--     GRANT CONNECT ON DATABASE lab TO lab_ro;
--     GRANT USAGE ON SCHEMA lab TO lab_ro;
--     GRANT SELECT ON ALL TABLES IN SCHEMA lab TO lab_ro;
--     ALTER DEFAULT PRIVILEGES IN SCHEMA lab GRANT SELECT ON TABLES TO lab_ro;
--
-- lab.fn_rename_subject is REVOKEd from PUBLIC above; grant EXECUTE on it only
-- to the administrator role that is expected to run identity maintenance.
-- See design_docs/mcp-server.md and the deployment guides for the full setup.
