-- ============================================================================
-- Migration 002: integrity hardening (schema version 1 -> 2)
-- ============================================================================
-- Brings a database created from the version-1 schema.sql (the one with no
-- lab.schema_version table) to version 2, the version schema.sql now installs.
-- A fresh install does not need this file.
--
-- Apply as the schema owner, in one transaction, stopping on the first error:
--
--     psql -X -v ON_ERROR_STOP=1 -1 -d lab -f design_docs/migrations/002_integrity_hardening.sql
--
-- Take a pg_dump first. What it changes (numbers refer to the October 2026
-- code review):
--   * lab.schema_version: new; records this migration as version 2. (13)
--   * lab.artifact: the table-wide UNIQUE (storage_root_id, relative_path,
--     checksum) is replaced by uq_artifact_file_original (originals only) plus
--     trg_artifact_unique_active (no two active rows for one file), so an
--     artifact can be superseded to re-point it at a corrected event or to
--     correct its metadata. (2)
--   * fn_forbid_mutation: the subject_rename escape hatch admits only the
--     cascade of a real rename; fn_rename_subject sets the from/to pair it
--     checks. (5)
--   * artifact_verification, maintenance_log, row_history, schema_version are
--     append-only; trg_verification_normalize fires on INSERT only. (6)
--   * lab.row_history + fn_log_row_change triggers: prior values of every
--     edit to the mutable tables, with the login that made it. (8)
--   * lab.event: event_subject_required_ck (only an analysis may have no
--     subject). Added NOT VALID and then validated; if existing rows violate
--     it, the constraint still applies to new rows, and a NOTICE says how many
--     existing rows do not satisfy it. (11)
--   * event_input: trg_event_input_acyclic rejects an edge that would make the
--     provenance graph cyclic. (12)
--   * fn_check_integrity: new artifact_producer_superseded check (2) and
--     event_missing_subject check, which reports any pre-existing rows the
--     NOT VALID constraint above does not cover. (11)
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('lab.schema_version') IS NOT NULL THEN
        RAISE EXCEPTION 'lab.schema_version exists: this database is already at '
                        'version 2 or later, so migration 002 does not apply';
    END IF;
    IF to_regclass('lab.event') IS NULL THEN
        RAISE EXCEPTION 'lab.event not found: this is not a CarasLabDB database';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- (13) Schema version
-- ---------------------------------------------------------------------------
CREATE TABLE lab.schema_version (
    version     integer PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    description text NOT NULL
);

-- ---------------------------------------------------------------------------
-- (11) Every event but an analysis names a subject
-- ---------------------------------------------------------------------------
ALTER TABLE lab.event ADD
    CONSTRAINT event_subject_required_ck CHECK (
        subject_id IS NOT NULL OR event_type = 'analysis') NOT VALID;

DO $$
DECLARE n bigint;
BEGIN
    SELECT count(*) INTO n FROM lab.event
    WHERE subject_id IS NULL AND event_type <> 'analysis';
    IF n = 0 THEN
        ALTER TABLE lab.event VALIDATE CONSTRAINT event_subject_required_ck;
    ELSE
        RAISE NOTICE 'event_subject_required_ck left NOT VALID: % existing '
                     'non-analysis event(s) have no subject_id. It is enforced '
                     'for new rows.', n;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- (2) Artifact file identity: originals unique, corrections exempt
-- ---------------------------------------------------------------------------
ALTER TABLE lab.artifact
    DROP CONSTRAINT artifact_storage_root_id_relative_path_checksum_key;
CREATE UNIQUE INDEX uq_artifact_file_original
    ON lab.artifact (storage_root_id, relative_path, checksum)
    WHERE supersedes IS NULL;

-- ---------------------------------------------------------------------------
-- (8) Edit history table
-- ---------------------------------------------------------------------------
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
-- (5, 6) Append-only guard
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
                         'row_history', 'schema_version') THEN
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
        'artifact_verification','maintenance_log','row_history','schema_version'
    ] LOOP
        EXECUTE format(
          'DROP TRIGGER IF EXISTS trg_immutable_%1$s ON lab.%1$s;', t);
        EXECUTE format(
          'CREATE TRIGGER trg_immutable_%1$s
             BEFORE UPDATE OR DELETE ON lab.%1$s
             FOR EACH ROW EXECUTE FUNCTION lab.fn_forbid_mutation();', t);
        EXECUTE format(
          'DROP TRIGGER IF EXISTS trg_immutable_truncate_%1$s ON lab.%1$s;', t);
        EXECUTE format(
          'CREATE TRIGGER trg_immutable_truncate_%1$s
             BEFORE TRUNCATE ON lab.%1$s
             FOR EACH STATEMENT EXECUTE FUNCTION lab.fn_forbid_mutation();', t);
    END LOOP;
END;
$$;

-- UPDATE on artifact_verification is now blocked, so normalizing on UPDATE is dead.
DROP TRIGGER trg_verification_normalize ON lab.artifact_verification;
CREATE TRIGGER trg_verification_normalize
    BEFORE INSERT ON lab.artifact_verification
    FOR EACH ROW EXECUTE FUNCTION lab.fn_normalize_checksum();

-- ---------------------------------------------------------------------------
-- (2, 12, 8) Active-file uniqueness, acyclic provenance, edit history triggers
-- ---------------------------------------------------------------------------
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
        ('session',            '''session_id''')
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
-- (5) Subject rename sets the from/to pair fn_forbid_mutation checks
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- (2, 11) Integrity report: stranded artifacts, subject-less events
-- ---------------------------------------------------------------------------
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
    -- Two active artifacts at one path: the NAS file can only be one of them.
    SELECT 'warning', 'duplicate_active_path',
           a.storage_root_id || ':' || a.relative_path,
           format('%s active artifacts share this path', count(*))
    FROM lab.artifact_active a
    GROUP BY a.storage_root_id, a.relative_path
    HAVING count(*) > 1;
$$;

INSERT INTO lab.schema_version (version, description) VALUES
    (2, 'Migration 002: integrity hardening');
