-- ============================================================================
-- Ephys Metadata System — schema DDL (PostgreSQL 14+)
-- ============================================================================
-- Canonical, runnable schema for the append-only event log, artifact index, and
-- provenance DAG. See design_docs/database-design.md for the ER diagram and the
-- table-by-table rationale. Apply against a fresh database, e.g.:
--
--     createdb ephys && psql -d ephys -f design_docs/schema.sql
--
-- Requires privileges to create a schema. gen_random_uuid() is in core since
-- PG 13; the pgcrypto line is a fallback for older servers.
-- ============================================================================

-- CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- only needed on PG < 13
CREATE SCHEMA IF NOT EXISTS ephys;

-- ---------------------------------------------------------------------------
-- Reference / lookup tables
-- ---------------------------------------------------------------------------
CREATE TABLE ephys.person (
    person_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name   text NOT NULL,
    email       text UNIQUE,
    role        text,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ephys.storage_root (
    root_id     smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        text NOT NULL UNIQUE,          -- e.g. 'nas-main'
    description text
);

CREATE TABLE ephys.species (
    code        text PRIMARY KEY,              -- e.g. 'meriones_unguiculatus'
    common_name text NOT NULL
);

CREATE TABLE ephys.probe (
    probe_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    manufacturer text,
    model        text,
    n_channels   integer,
    geometry     jsonb,                         -- site coordinates / layout
    description  text
);

CREATE TABLE ephys.pipeline (
    pipeline_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL UNIQUE,
    description text,
    repo_url    text
);

CREATE TABLE ephys.event_type (
    code  text PRIMARY KEY,
    label text NOT NULL
);

CREATE TABLE ephys.artifact_role (
    code  text PRIMARY KEY,
    label text NOT NULL
);

CREATE TABLE ephys.acquisition_system (
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
CREATE TABLE ephys.project (
    project_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL UNIQUE,           -- unique project name
    description text,
    started_on  date,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid REFERENCES ephys.person(person_id)
);

-- People associated with a project (many-to-many; a project has one or more).
CREATE TABLE ephys.project_member (
    project_id uuid NOT NULL REFERENCES ephys.project(project_id),
    person_id  uuid NOT NULL REFERENCES ephys.person(person_id),
    role       text,                            -- 'PI','lead','member','analyst',...
    added_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, person_id)
);

-- Project-level artifacts: NAS files of any type plus external references
-- (Google Docs/Sheets, arbitrary URLs). These are attachments / reference
-- material, distinct from the provenance `artifact` table (which tracks
-- checksummed data files produced by events).
CREATE TABLE ephys.project_artifact (
    project_artifact_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id          uuid NOT NULL REFERENCES ephys.project(project_id),
    title               text NOT NULL,
    kind                text NOT NULL DEFAULT 'file'
                            CHECK (kind IN ('file','google_doc','google_sheet','url','other')),
    content_type        text,                    -- file type / MIME: 'pdf','xlsx','docx','csv',...
    -- External references (google_doc / google_sheet / url) are located by URI ...
    uri                 text,
    -- ... while NAS files are located under a storage root at a relative path.
    storage_root_id     smallint REFERENCES ephys.storage_root(root_id),
    relative_path       text,
    description         text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid REFERENCES ephys.person(person_id),
    -- A 'file' lives on the NAS; every other kind is located by URI.
    CONSTRAINT project_artifact_location_ck CHECK (
        (kind = 'file'
             AND storage_root_id IS NOT NULL AND relative_path IS NOT NULL
             AND uri IS NULL)
        OR (kind <> 'file'
             AND uri IS NOT NULL
             AND storage_root_id IS NULL AND relative_path IS NULL)
    )
);

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------
CREATE TABLE ephys.subject (
    subject_id    text PRIMARY KEY,             -- lab ID (natural key)
    project_id    uuid NOT NULL REFERENCES ephys.project(project_id),
    species_code  text REFERENCES ephys.species(code),
    sex           char(1) NOT NULL DEFAULT 'U' CHECK (sex IN ('M','F','U')),
    strain        text,
    genotype      text,
    source        text,                         -- 'bred_in_house', 'vendor:...'
    date_of_birth date,                         -- nullable: acquired animals
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid REFERENCES ephys.person(person_id)
);

CREATE TABLE ephys.session (
    session_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_id      text NOT NULL REFERENCES ephys.subject(subject_id),
    label           text NOT NULL,              -- NAS folder name under subject
    storage_root_id smallint NOT NULL REFERENCES ephys.storage_root(root_id),
    relative_path   text NOT NULL,              -- 'subject/session' under root
    started_at      timestamptz,
    ended_at        timestamptz,
    rig             text,
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid REFERENCES ephys.person(person_id),
    UNIQUE (subject_id, label),
    UNIQUE (storage_root_id, relative_path)
);

-- ---------------------------------------------------------------------------
-- Event base
-- ---------------------------------------------------------------------------
CREATE TABLE ephys.event (
    event_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type  text NOT NULL REFERENCES ephys.event_type(code),
    subject_id  text REFERENCES ephys.subject(subject_id),
    session_id  uuid REFERENCES ephys.session(session_id),
    occurred_at timestamptz NOT NULL,           -- when it happened in the lab
    recorded_at timestamptz NOT NULL DEFAULT now(),  -- when the row was inserted
    recorded_by uuid REFERENCES ephys.person(person_id),
    supersedes  uuid REFERENCES ephys.event(event_id),
    notes       text,
    attributes  jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (supersedes <> event_id),
    UNIQUE (event_id, event_type)               -- FK target for detail tables
);
-- Linear correction history: each row corrected by at most one successor.
CREATE UNIQUE INDEX uq_event_supersedes
    ON ephys.event (supersedes) WHERE supersedes IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Event detail tables (class-table inheritance)
-- ---------------------------------------------------------------------------
CREATE TABLE ephys.birth_event (
    event_id        uuid PRIMARY KEY,
    event_type      text NOT NULL DEFAULT 'birth' CHECK (event_type = 'birth'),
    dam_subject_id  text REFERENCES ephys.subject(subject_id),
    sire_subject_id text REFERENCES ephys.subject(subject_id),
    litter_id       text,
    birth_weight_g  numeric,
    FOREIGN KEY (event_id, event_type)
        REFERENCES ephys.event(event_id, event_type)
);

CREATE TABLE ephys.surgery_event (
    event_id        uuid PRIMARY KEY,
    event_type      text NOT NULL DEFAULT 'surgery' CHECK (event_type = 'surgery'),
    procedure       text,
    surgeon_id      uuid REFERENCES ephys.person(person_id),
    anesthesia      text,
    target_region   text,
    hemisphere      text CHECK (hemisphere IN ('L','R','bilateral')),
    stereotax_ap_mm numeric,
    stereotax_ml_mm numeric,
    stereotax_dv_mm numeric,
    probe_id        uuid REFERENCES ephys.probe(probe_id),
    outcome         text,
    FOREIGN KEY (event_id, event_type)
        REFERENCES ephys.event(event_id, event_type)
);

CREATE TABLE ephys.recording_event (
    event_id                uuid PRIMARY KEY,
    event_type              text NOT NULL DEFAULT 'recording'
                                 CHECK (event_type = 'recording'),
    acquisition_system_code text REFERENCES ephys.acquisition_system(code),
    probe_id                uuid REFERENCES ephys.probe(probe_id),
    modality                text NOT NULL DEFAULT 'ephys'
                                 CHECK (modality IN ('ephys','video','behavior','multimodal')),
    sample_rate_hz          numeric,
    n_channels              integer,
    duration_s              numeric,
    stimulus_protocol       text,
    hardware_config         jsonb,
    FOREIGN KEY (event_id, event_type)
        REFERENCES ephys.event(event_id, event_type)
);

CREATE TABLE ephys.behavior_event (
    event_id         uuid PRIMARY KEY,
    event_type       text NOT NULL DEFAULT 'behavior' CHECK (event_type = 'behavior'),
    task             text,
    paradigm         text,
    stage            text,
    trials_completed integer,
    performance      numeric,
    reward           text,
    FOREIGN KEY (event_id, event_type)
        REFERENCES ephys.event(event_id, event_type)
);

CREATE TABLE ephys.husbandry_event (
    event_id      uuid PRIMARY KEY,
    event_type    text NOT NULL DEFAULT 'husbandry' CHECK (event_type = 'husbandry'),
    measure       text NOT NULL,   -- 'weight','health_check','water_restriction',...
    weight_g      numeric,
    water_ml      numeric,
    health_status text,
    FOREIGN KEY (event_id, event_type)
        REFERENCES ephys.event(event_id, event_type)
);

CREATE TABLE ephys.endpoint_event (
    event_id           uuid PRIMARY KEY,
    event_type         text NOT NULL DEFAULT 'endpoint' CHECK (event_type = 'endpoint'),
    method             text,             -- 'perfusion','overdose',...
    perfusion_fixative text,
    tissue_collected   boolean,
    disposition        text,
    FOREIGN KEY (event_id, event_type)
        REFERENCES ephys.event(event_id, event_type)
);

CREATE TABLE ephys.histology_event (
    event_id      uuid PRIMARY KEY,
    event_type    text NOT NULL DEFAULT 'histology' CHECK (event_type = 'histology'),
    technique     text,
    target_region text,
    stain         text,
    microscope    text,
    FOREIGN KEY (event_id, event_type)
        REFERENCES ephys.event(event_id, event_type)
);

CREATE TABLE ephys.analysis_event (
    event_id      uuid PRIMARY KEY,
    event_type    text NOT NULL DEFAULT 'analysis' CHECK (event_type = 'analysis'),
    pipeline_id   uuid REFERENCES ephys.pipeline(pipeline_id),
    pipeline_name text,               -- denormalized snapshot of the name
    code_version  text,               -- git SHA / release tag (reproducibility)
    parameters    jsonb NOT NULL DEFAULT '{}'::jsonb,
    environment   jsonb,              -- OS / package versions / container digest
    started_at    timestamptz,
    finished_at   timestamptz,
    status        text CHECK (status IN ('running','succeeded','failed')),
    FOREIGN KEY (event_id, event_type)
        REFERENCES ephys.event(event_id, event_type)
);

-- ---------------------------------------------------------------------------
-- Artifacts & provenance edges
-- ---------------------------------------------------------------------------
CREATE TABLE ephys.artifact (
    artifact_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    produced_by_event_id uuid NOT NULL REFERENCES ephys.event(event_id),
    storage_root_id      smallint NOT NULL REFERENCES ephys.storage_root(root_id),
    relative_path        text NOT NULL,
    checksum             text NOT NULL,
    checksum_algo        text NOT NULL DEFAULT 'sha256'
                             CHECK (checksum_algo IN ('sha256','md5','blake3')),
    size_bytes           bigint,
    role                 text REFERENCES ephys.artifact_role(code),
    format               text,                    -- 'rhd','dat','npy','mp4','png'
    subject_id           text REFERENCES ephys.subject(subject_id),
    session_id           uuid REFERENCES ephys.session(session_id),
    supersedes           uuid REFERENCES ephys.artifact(artifact_id),
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid REFERENCES ephys.person(person_id),
    attributes           jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (supersedes <> artifact_id),
    UNIQUE (storage_root_id, relative_path, checksum)
);
CREATE UNIQUE INDEX uq_artifact_supersedes
    ON ephys.artifact (supersedes) WHERE supersedes IS NOT NULL;

CREATE TABLE ephys.event_input (
    event_id    uuid NOT NULL REFERENCES ephys.event(event_id),
    artifact_id uuid NOT NULL REFERENCES ephys.artifact(artifact_id),
    role        text,
    PRIMARY KEY (event_id, artifact_id)
);

CREATE TABLE ephys.artifact_verification (
    verification_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    artifact_id       uuid NOT NULL REFERENCES ephys.artifact(artifact_id),
    verified_at       timestamptz NOT NULL DEFAULT now(),
    verified_by       uuid REFERENCES ephys.person(person_id),
    status            text NOT NULL CHECK (status IN ('ok','missing','mismatch')),
    observed_checksum text
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX ix_event_subject   ON ephys.event (subject_id);
CREATE INDEX ix_event_session   ON ephys.event (session_id);
CREATE INDEX ix_event_type      ON ephys.event (event_type);
CREATE INDEX ix_event_occurred  ON ephys.event (occurred_at);
CREATE INDEX ix_event_attrs_gin ON ephys.event USING gin (attributes);

CREATE INDEX ix_artifact_event    ON ephys.artifact (produced_by_event_id);
CREATE INDEX ix_artifact_subject  ON ephys.artifact (subject_id);
CREATE INDEX ix_artifact_session  ON ephys.artifact (session_id);
CREATE INDEX ix_artifact_role     ON ephys.artifact (role);
CREATE INDEX ix_artifact_checksum ON ephys.artifact (checksum);

CREATE INDEX ix_event_input_artifact ON ephys.event_input (artifact_id);
CREATE INDEX ix_analysis_params_gin  ON ephys.analysis_event USING gin (parameters);

CREATE INDEX ix_subject_project          ON ephys.subject (project_id);
CREATE INDEX ix_project_member_person    ON ephys.project_member (person_id);
CREATE INDEX ix_project_artifact_project ON ephys.project_artifact (project_id);

-- ---------------------------------------------------------------------------
-- Immutability + validation triggers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ephys.fn_forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
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
          'CREATE TRIGGER trg_immutable_%1$s
             BEFORE UPDATE OR DELETE ON ephys.%1$s
             FOR EACH ROW EXECUTE FUNCTION ephys.fn_forbid_mutation();', t);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION ephys.fn_require_session_for_recording() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT session_id FROM ephys.event WHERE event_id = NEW.event_id) IS NULL THEN
        RAISE EXCEPTION
          'recording event % must reference a session (event.session_id is null)',
          NEW.event_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_require_session_for_recording
    BEFORE INSERT ON ephys.recording_event
    FOR EACH ROW EXECUTE FUNCTION ephys.fn_require_session_for_recording();

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
CREATE VIEW ephys.event_active AS
    SELECT e.* FROM ephys.event e
    WHERE NOT EXISTS (
        SELECT 1 FROM ephys.event s WHERE s.supersedes = e.event_id);

CREATE VIEW ephys.artifact_active AS
    SELECT a.* FROM ephys.artifact a
    WHERE NOT EXISTS (
        SELECT 1 FROM ephys.artifact s WHERE s.supersedes = a.artifact_id);

-- Uniform edge list for graph tooling.
CREATE VIEW ephys.provenance_edge AS
    SELECT 'produces'::text AS edge_type,
           'event'::text    AS from_kind, produced_by_event_id AS from_id,
           'artifact'::text AS to_kind,   artifact_id          AS to_id
    FROM ephys.artifact
    UNION ALL
    SELECT 'consumes'::text,
           'artifact', artifact_id,
           'event',    event_id
    FROM ephys.event_input;

-- Subject dimension enriched with latest active weight + endpoint status.
CREATE VIEW ephys.subject_current AS
    SELECT s.*,
           w.weight_g    AS latest_weight_g,
           w.occurred_at AS latest_weight_at,
           (ep.event_id IS NOT NULL) AS is_endpointed,
           ep.occurred_at            AS endpoint_at
    FROM ephys.subject s
    LEFT JOIN LATERAL (
        SELECT h.weight_g, e.occurred_at
        FROM ephys.husbandry_event h
        JOIN ephys.event e ON e.event_id = h.event_id
        WHERE e.subject_id = s.subject_id AND h.weight_g IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM ephys.event x WHERE x.supersedes = e.event_id)
        ORDER BY e.occurred_at DESC LIMIT 1
    ) w ON true
    LEFT JOIN LATERAL (
        SELECT e.event_id, e.occurred_at
        FROM ephys.endpoint_event ee
        JOIN ephys.event e ON e.event_id = ee.event_id
        WHERE e.subject_id = s.subject_id
          AND NOT EXISTS (SELECT 1 FROM ephys.event x WHERE x.supersedes = e.event_id)
        ORDER BY e.occurred_at DESC LIMIT 1
    ) ep ON true;

-- ---------------------------------------------------------------------------
-- Recursive lineage function
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ephys.fn_artifact_lineage(
    p_artifact_id uuid,
    p_direction   text DEFAULT 'up'   -- 'up' = ancestors, 'down' = descendants
) RETURNS TABLE (depth integer, event_id uuid, artifact_id uuid)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_direction NOT IN ('up','down') THEN
        RAISE EXCEPTION 'direction must be ''up'' or ''down'', got %', p_direction;
    END IF;

    IF p_direction = 'up' THEN
        RETURN QUERY
        WITH RECURSIVE lin AS (
            SELECT 0 AS depth, a.produced_by_event_id AS event_id, a.artifact_id
            FROM ephys.artifact a
            WHERE a.artifact_id = p_artifact_id
          UNION
            SELECT l.depth + 1, ain.produced_by_event_id, ain.artifact_id
            FROM lin l
            JOIN ephys.event_input ei  ON ei.event_id = l.event_id
            JOIN ephys.artifact    ain ON ain.artifact_id = ei.artifact_id
            WHERE l.depth < 64
        )
        SELECT lin.depth, lin.event_id, lin.artifact_id FROM lin ORDER BY lin.depth;
    ELSE
        RETURN QUERY
        WITH RECURSIVE lin AS (
            SELECT 0 AS depth, NULL::uuid AS event_id, a.artifact_id
            FROM ephys.artifact a
            WHERE a.artifact_id = p_artifact_id
          UNION
            SELECT l.depth + 1, ei.event_id, prod.artifact_id
            FROM lin l
            JOIN ephys.event_input ei   ON ei.artifact_id = l.artifact_id
            JOIN ephys.artifact    prod ON prod.produced_by_event_id = ei.event_id
            WHERE l.depth < 64
        )
        SELECT lin.depth, lin.event_id, lin.artifact_id FROM lin ORDER BY lin.depth;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Seed vocabulary
-- ---------------------------------------------------------------------------
INSERT INTO ephys.event_type (code, label) VALUES
    ('birth','Birth'), ('surgery','Surgery'), ('recording','Recording'),
    ('behavior','Behavior / training'), ('husbandry','Husbandry / health'),
    ('endpoint','Endpoint / euthanasia'), ('histology','Histology'),
    ('analysis','Analysis run');

INSERT INTO ephys.artifact_role (code, label) VALUES
    ('raw','Raw acquisition'), ('spikes','Spike times'), ('lfp','LFP'),
    ('waveforms','Spike waveforms'), ('video','Behavioral video'),
    ('figure','Figure'), ('report','Report'), ('derived','Derived data'),
    ('other','Other');

INSERT INTO ephys.acquisition_system (code, label) VALUES
    ('intan_rhx','Intan RHX'), ('open_ephys','Open Ephys');

INSERT INTO ephys.species (code, common_name) VALUES
    ('meriones_unguiculatus','Mongolian gerbil'),
    ('mus_musculus','House mouse'),
    ('rattus_norvegicus','Norway rat');
