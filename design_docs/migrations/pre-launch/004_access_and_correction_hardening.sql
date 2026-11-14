-- ============================================================================
-- Migration 004: access and correction hardening (schema version 3 -> 4)
-- ============================================================================
-- Brings a version-3 database (schema.sql as of migration 003) to version 4,
-- the version schema.sql now installs. A fresh install does not need this
-- file.
--
-- Apply as the schema owner, in one transaction, stopping on the first error:
--
--     psql -X -v ON_ERROR_STOP=1 -1 -d lab -f design_docs/migrations/004_access_and_correction_hardening.sql
--
-- Take a pg_dump first. What it changes:
--
-- Privilege boundary
--   * Every trigger function, and lab.fn_rename_subject, now pins its
--     search_path. A subject rename cascades into the append-only tables as
--     their owner, and an unpinned trigger function resolved type names with
--     the caller's search path, so a client that could start the cascade
--     could run its own code with the owner's privileges.
--   * trg_subject_id_guard: only a role that may execute
--     lab.fn_rename_subject may change a subject id. Until now any role with
--     UPDATE on lab.subject could set the lab.maintenance flags by hand and
--     rename an animal with a plain UPDATE, leaving no maintenance_log row.
--   * fn_forbid_mutation: under the rename flag a NULL subject id could be
--     filled in with the rename target; only old-id -> new-id now passes.
--   * New columns event.recorded_login, artifact.created_login,
--     artifact_verification.verified_login and tag_assignment.applied_login,
--     set to session_user by the trg_*_stamp_login triggers whatever the
--     client sends. Rows written before this migration keep NULL.
--
-- Corrections
--   * lab.fn_artifact_lineage gains p_follow_corrections (default true) and
--     then walks current rows, following supersede chains; before, a
--     correction disconnected everything derived from the corrected row.
--     Helpers: lab.fn_event_current / fn_artifact_current and
--     lab.fn_event_versions / fn_artifact_versions. The two-argument
--     signature is replaced, so existing calls get the new default.
--   * lab.artifact_verification_latest: the latest integrity check of the
--     file an artifact row describes, across every row describing that file.
--     fn_check_integrity uses it, so a correction no longer turns a failed
--     check into "never verified".
--   * trg_artifact_matches_event: an artifact cannot be filed under a
--     different subject or session than the event that produced it.
--   * lab.event_version / lab.artifact_version: every version of every row
--     with superseded_by and is_current.
--   * fn_check_integrity: new checks artifact_event_mismatch,
--     input_not_carried_forward and tag_cardinality_violation.
--
-- Concurrency
--   * trg_tag_assignment_policy, trg_artifact_unique_active and
--     trg_event_input_acyclic take a transaction-level advisory lock, so
--     their checks hold under concurrent writers.
--   * lab.tag_current takes the latest row by assignment_id, not applied_at:
--     an accepted 'remove' carrying an earlier applied_at left the tag
--     current.
--
-- Other
--   * lab.fn_tag_filter_problems: what is wrong with a tag filter (unknown
--     namespace or tag, namespace not applicable to the entity kind).
--   * event_subject_required_ck is validated if migration 002 had to leave it
--     NOT VALID and the offending rows have since been corrected.
--
-- Re-run design_docs/grants.sql afterwards. It now withholds UPDATE on
-- lab.subject.subject_id and on lab.person, and INSERT on lab.event_type,
-- from lab_rw; the new views need their SELECT grants.
--
-- After this migration an artifact whose subject or session differs from its
-- producing event's is reported by lab.fn_check_integrity() as
-- artifact_event_mismatch; correct each with a superseding artifact row.
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('lab.schema_version') IS NULL THEN
        RAISE EXCEPTION 'lab.schema_version not found: apply migrations 002 and 003 first';
    END IF;
    IF (SELECT max(version) FROM lab.schema_version) IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION 'this database is at schema version %, but migration 004 '
                        'applies to version 3 only',
                        (SELECT max(version) FROM lab.schema_version);
    END IF;
    IF to_regclass('lab.event_version') IS NOT NULL THEN
        RAISE EXCEPTION 'lab.event_version exists: migration 004 has already been applied';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Login columns
-- ---------------------------------------------------------------------------
-- Nullable with no default: existing rows were written before the login was
-- recorded, and stamping them with the login running this migration would be
-- a false statement about who wrote them. ADD COLUMN appends, and schema.sql
-- declares each of these as its table's last column, so both give one dump.
ALTER TABLE lab.event                 ADD COLUMN recorded_login text;
ALTER TABLE lab.artifact              ADD COLUMN created_login  text;
ALTER TABLE lab.artifact_verification ADD COLUMN verified_login text;
ALTER TABLE lab.tag_assignment        ADD COLUMN applied_login  text;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
-- event_active and artifact_active are SELECT *, which a view freezes when it
-- is created: re-create them so they expose the new column.
CREATE OR REPLACE VIEW lab.event_active AS
    SELECT e.* FROM lab.event e
    WHERE NOT EXISTS (
        SELECT 1 FROM lab.event s WHERE s.supersedes = e.event_id);

CREATE OR REPLACE VIEW lab.artifact_active AS
    SELECT a.* FROM lab.artifact a
    WHERE NOT EXISTS (
        SELECT 1 FROM lab.artifact s WHERE s.supersedes = a.artifact_id);

CREATE VIEW lab.event_version AS
    SELECT e.*, s.event_id AS superseded_by, (s.event_id IS NULL) AS is_current
    FROM lab.event e
    LEFT JOIN lab.event s ON s.supersedes = e.event_id;

CREATE VIEW lab.artifact_version AS
    SELECT a.*, s.artifact_id AS superseded_by, (s.artifact_id IS NULL) AS is_current
    FROM lab.artifact a
    LEFT JOIN lab.artifact s ON s.supersedes = a.artifact_id;

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

CREATE OR REPLACE VIEW lab.tag_current AS
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

-- ---------------------------------------------------------------------------
-- Trigger functions: pinned search_path
-- ---------------------------------------------------------------------------
-- Bodies unchanged; only the setting is added.
ALTER FUNCTION lab.fn_require_session_for_recording() SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION lab.fn_fill_subject_from_session() SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION lab.fn_supersede_same_type() SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION lab.fn_normalize_checksum() SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION lab.fn_normalize_path() SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION lab.fn_normalize_tag() SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION lab.fn_tag_guard() SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION lab.fn_tag_namespace_guard() SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION lab.fn_rename_subject(text, text) SET search_path = pg_catalog, pg_temp;

-- Bodies changed as well (see the header).
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

-- ---------------------------------------------------------------------------
-- New trigger functions and their triggers
-- ---------------------------------------------------------------------------
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

CREATE TRIGGER trg_artifact_matches_event
    BEFORE INSERT ON lab.artifact
    FOR EACH ROW EXECUTE FUNCTION lab.fn_artifact_matches_event();

CREATE OR REPLACE FUNCTION lab.fn_stamp_login() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF TG_TABLE_NAME = 'event' THEN
        NEW.recorded_login := session_user;
    ELSIF TG_TABLE_NAME = 'artifact' THEN
        NEW.created_login := session_user;
    ELSIF TG_TABLE_NAME = 'artifact_verification' THEN
        NEW.verified_login := session_user;
    ELSIF TG_TABLE_NAME = 'tag_assignment' THEN
        NEW.applied_login := session_user;
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

-- ---------------------------------------------------------------------------
-- Correction chains and lineage
-- ---------------------------------------------------------------------------
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

-- The signature gains a parameter, which CREATE OR REPLACE would add as a
-- second function next to the old one; drop the old one first.
DROP FUNCTION lab.fn_artifact_lineage(uuid, text);

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
-- Tag filter check and integrity report
-- ---------------------------------------------------------------------------
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
    -- Artifacts whose file failed its most recent integrity check. By file,
    -- not by row (lab.artifact_verification_latest): a correction inserts a
    -- new artifact row for the same file, and the failure must follow it.
    SELECT 'error', 'artifact_verification_failed', a.artifact_id::text,
           format('latest verification is %s (%s)', v.status, v.verified_at)
    FROM lab.artifact_active a
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
    FROM lab.artifact_active a
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
    -- insert; this reports rows that predate it (schema version 4).
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
    -- raced before schema version 4 made the check race-free.
    SELECT 'error', 'tag_cardinality_violation', c.entity_id,
           format('%s has %s current tags in single-valued namespace %s: %s',
                  c.entity_kind, count(*), c.namespace, string_agg(c.tag, ', ' ORDER BY c.tag))
    FROM lab.tag_current c
    JOIN lab.tag_namespace n ON n.namespace = c.namespace
    WHERE n.cardinality = 'single'
    GROUP BY c.entity_kind, c.entity_id, c.namespace
    HAVING count(*) > 1

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
-- event_subject_required_ck
-- ---------------------------------------------------------------------------
-- Migration 002 adds this constraint NOT VALID when a version-1 database holds
-- non-analysis events with no subject. Once those rows are corrected (each is
-- superseded by an event that names its subject) the rows still exist, so the
-- constraint can only be validated when there are none at all.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint
               WHERE conname = 'event_subject_required_ck'
                 AND conrelid = 'lab.event'::regclass AND NOT convalidated) THEN
        IF EXISTS (SELECT 1 FROM lab.event
                   WHERE subject_id IS NULL AND event_type <> 'analysis') THEN
            RAISE NOTICE 'event_subject_required_ck stays NOT VALID: % event(s) have no subject '
                         '(see lab.fn_check_integrity(), event_missing_subject)',
                (SELECT count(*) FROM lab.event
                 WHERE subject_id IS NULL AND event_type <> 'analysis');
        ELSE
            ALTER TABLE lab.event VALIDATE CONSTRAINT event_subject_required_ck;
        END IF;
    END IF;
END;
$$;

INSERT INTO lab.schema_version (version, description) VALUES
    (4, 'Migration 004: access and correction hardening');
