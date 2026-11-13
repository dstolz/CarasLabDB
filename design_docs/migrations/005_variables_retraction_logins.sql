-- ============================================================================
-- Migration 005: user-defined variables, retraction, login-to-person mapping
--                (schema version 4 -> 5)
-- ============================================================================
-- Brings a version-4 database (schema.sql as of migration 004) to version 5,
-- the version schema.sql now installs. A fresh install does not need this
-- file.
--
-- Apply as the schema owner, in one transaction, stopping on the first error:
--
--     psql -X -v ON_ERROR_STOP=1 -1 -d lab -f design_docs/migrations/005_variables_retraction_logins.sql
--
-- Take a backup first (tools/backup_lab.py). What it changes:
--
-- User-defined variables
--   * lab.variable: the definition of a named value -- name ('probe depth'),
--     label ('Probe Depth'), description, units, value type (number or text)
--     and the entity kinds it applies to. Mutable, recorded in row_history;
--     trg_variable_guard freezes the name always, and the value type and
--     units once the variable has a value.
--   * lab.variable_value: the append-only log of values set and unset on
--     events, artifacts, subjects, sessions and projects, policed by
--     trg_variable_value_policy and protected by fn_forbid_mutation.
--   * lab.variable_current (latest value per entity and variable) and
--     lab.entity_variables (all of an entity's current values as one JSON
--     object).
--   * lab.fn_set_variable (the write entry point; defines a variable on first
--     use), lab.fn_unset_variable, lab.fn_define_variable,
--     lab.fn_canonical_variable, and lab.fn_variable_number /
--     lab.fn_variable_text for use in ordinary queries.
--   * trg_event_carry_variables / trg_artifact_carry_variables: a correction
--     starts with its predecessor's current variables (lab.fn_carry_variables).
--
-- Retraction
--   * lab.retraction: an append-only record that an event or artifact was
--     withdrawn, with the reason. lab.event_active and lab.artifact_active
--     leave retracted rows out; lab.event_version and lab.artifact_version
--     gain is_retracted, and is_current is false for a retracted row.
--     lab.fn_retract is the write entry point.
--   * lab.subject_current and lab.fn_find_by_tags now take "active" from the
--     *_active views, so retracted events no longer count.
--   * fn_check_integrity: new checks artifact_producer_retracted and
--     input_retracted.
--
-- People and logins
--   * lab.person.db_login: the database login a person connects with.
--     lab.fn_current_person() resolves the connected login to that person,
--     and the trg_*_stamp_login triggers use it to fill recorded_by /
--     created_by / verified_by / applied_by / retracted_by when the client
--     names nobody. Existing rows are not touched.
--
-- Re-run design_docs/grants.sql afterwards: lab_rw needs UPDATE on
-- lab.variable, and may no longer set lab.person.db_login.
--
-- Afterwards, as the administrator, map each person to their login:
--
--     UPDATE lab.person SET db_login = 'jdoe' WHERE email = 'jdoe@example.edu';
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('lab.schema_version') IS NULL THEN
        RAISE EXCEPTION 'lab.schema_version not found: apply the earlier migrations first';
    END IF;
    IF (SELECT max(version) FROM lab.schema_version) IS DISTINCT FROM 4 THEN
        RAISE EXCEPTION 'this database is at schema version %, but migration 005 '
                        'applies to version 4 only',
                        (SELECT max(version) FROM lab.schema_version);
    END IF;
    IF to_regclass('lab.variable') IS NOT NULL THEN
        RAISE EXCEPTION 'lab.variable exists: migration 005 has already been applied';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- People and logins
-- ---------------------------------------------------------------------------
ALTER TABLE lab.person ADD COLUMN db_login text;
ALTER TABLE lab.person ADD CONSTRAINT person_db_login_ck CHECK (
        db_login IS NULL OR (db_login <> '' AND db_login = btrim(db_login)));
CREATE UNIQUE INDEX uq_person_db_login
    ON lab.person (db_login) WHERE db_login IS NOT NULL;

CREATE OR REPLACE FUNCTION lab.fn_current_person() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT p.person_id FROM lab.person p WHERE p.db_login = session_user::text;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
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
CREATE UNIQUE INDEX uq_retraction_event
    ON lab.retraction (event_id) WHERE event_id IS NOT NULL;
CREATE UNIQUE INDEX uq_retraction_artifact
    ON lab.retraction (artifact_id) WHERE artifact_id IS NOT NULL;

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

CREATE INDEX ix_variable_value_entity
    ON lab.variable_value (entity_kind, coalesce(event_id::text, artifact_id::text, subject_id,
                                                 session_id::text, project_id::text));
CREATE INDEX ix_variable_value_variable ON lab.variable_value (variable, entity_kind);
CREATE INDEX ix_variable_value_event    ON lab.variable_value (event_id);
CREATE INDEX ix_variable_value_artifact ON lab.variable_value (artifact_id);
CREATE INDEX ix_variable_value_subject  ON lab.variable_value (subject_id);
CREATE INDEX ix_variable_value_session  ON lab.variable_value (session_id);
CREATE INDEX ix_variable_value_project  ON lab.variable_value (project_id);

-- ---------------------------------------------------------------------------
-- Immutability
-- ---------------------------------------------------------------------------
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
                         'variable_value', 'retraction') THEN
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
    FOREACH t IN ARRAY ARRAY['variable_value', 'retraction'] LOOP
        EXECUTE format(
          'CREATE TRIGGER trg_immutable_%1$s
             BEFORE UPDATE OR DELETE ON lab.%1$s
             FOR EACH ROW EXECUTE FUNCTION lab.fn_forbid_mutation();', t);
        EXECUTE format(
          'CREATE TRIGGER trg_immutable_truncate_%1$s
             BEFORE TRUNCATE ON lab.%1$s
             FOR EACH STATEMENT EXECUTE FUNCTION lab.fn_forbid_mutation();', t);
    END LOOP;
END;
$$;

CREATE TRIGGER trg_history_variable
    AFTER UPDATE OR DELETE ON lab.variable
    FOR EACH ROW EXECUTE FUNCTION lab.fn_log_row_change('name');

-- ---------------------------------------------------------------------------
-- Login stamp: two more tables, and the person mapped to the login
-- ---------------------------------------------------------------------------
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
    ELSIF TG_TABLE_NAME = 'variable_value' THEN
        NEW.set_login := session_user;
    ELSE
        RAISE EXCEPTION 'lab.fn_stamp_login is not defined for table %', TG_TABLE_NAME;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_retraction_stamp_login
    BEFORE INSERT ON lab.retraction
    FOR EACH ROW EXECUTE FUNCTION lab.fn_stamp_login();

CREATE TRIGGER trg_variable_value_stamp_login
    BEFORE INSERT ON lab.variable_value
    FOR EACH ROW EXECUTE FUNCTION lab.fn_stamp_login();

-- ---------------------------------------------------------------------------
-- Variable and retraction triggers
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW lab.event_active AS
    SELECT e.* FROM lab.event e
    WHERE NOT EXISTS (
        SELECT 1 FROM lab.event s WHERE s.supersedes = e.event_id)
      AND NOT EXISTS (
        SELECT 1 FROM lab.retraction r WHERE r.event_id = e.event_id);

CREATE OR REPLACE VIEW lab.artifact_active AS
    SELECT a.* FROM lab.artifact a
    WHERE NOT EXISTS (
        SELECT 1 FROM lab.artifact s WHERE s.supersedes = a.artifact_id)
      AND NOT EXISTS (
        SELECT 1 FROM lab.retraction r WHERE r.artifact_id = a.artifact_id);

CREATE OR REPLACE VIEW lab.event_version AS
    SELECT e.*, s.event_id AS superseded_by,
           (s.event_id IS NULL AND r.retraction_id IS NULL) AS is_current,
           (r.retraction_id IS NOT NULL) AS is_retracted
    FROM lab.event e
    LEFT JOIN lab.event s ON s.supersedes = e.event_id
    LEFT JOIN lab.retraction r ON r.event_id = e.event_id;

CREATE OR REPLACE VIEW lab.artifact_version AS
    SELECT a.*, s.artifact_id AS superseded_by,
           (s.artifact_id IS NULL AND r.retraction_id IS NULL) AS is_current,
           (r.retraction_id IS NOT NULL) AS is_retracted
    FROM lab.artifact a
    LEFT JOIN lab.artifact s ON s.supersedes = a.artifact_id
    LEFT JOIN lab.retraction r ON r.artifact_id = a.artifact_id;

CREATE OR REPLACE VIEW lab.subject_current AS
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

CREATE VIEW lab.entity_variables AS
    SELECT vc.entity_kind, vc.entity_id,
           jsonb_object_agg(vc.variable,
                            CASE WHEN vc.value_num IS NOT NULL THEN to_jsonb(vc.value_num)
                                 ELSE to_jsonb(vc.value_text) END) AS variables
    FROM lab.variable_current vc
    GROUP BY vc.entity_kind, vc.entity_id;

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------
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
    -- Two active artifacts at one path: the NAS file can only be one of them.
    SELECT 'warning', 'duplicate_active_path',
           a.storage_root_id || ':' || a.relative_path,
           format('%s active artifacts share this path', count(*))
    FROM lab.artifact_active a
    GROUP BY a.storage_root_id, a.relative_path
    HAVING count(*) > 1;
$$;

INSERT INTO lab.schema_version (version, description) VALUES
    (5, 'Migration 005: user-defined variables, retraction, login-to-person mapping');
