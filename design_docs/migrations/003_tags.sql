-- ============================================================================
-- Migration 003: tags (schema version 2 -> 3)
-- ============================================================================
-- Brings a version-2 database to version 3, the version schema.sql now
-- installs. A fresh install does not need this file.
--
-- Apply as the schema owner, in one transaction, stopping on the first error:
--
--     psql -X -v ON_ERROR_STOP=1 -1 -d lab -f design_docs/migrations/003_tags.sql
--
-- Take a pg_dump first, and re-run design_docs/grants.sql afterwards (the new
-- lab.tag_namespace and lab.tag tables are editable by lab_rw). What it adds
-- (see design_docs/tagging.md and database-design.md §3.7):
--   * lab.tag_namespace, lab.tag: the tag vocabulary, with a per-namespace
--     policy (mutability, cardinality, open_vocabulary, applies_to). Mutable
--     reference tables, logged in lab.row_history; trg_tag_namespace_guard
--     freezes a namespace's policy once it is in use, trg_tag_guard keeps a
--     tag's identity fixed.
--   * lab.tag_assignment: the append-only log of 'add' / 'remove' operations
--     on events, artifacts, subjects, sessions and projects, policed by
--     trg_tag_assignment_policy and protected by fn_forbid_mutation like the
--     other logs.
--   * lab.tag_current, lab.entity_tags: the derived current state.
--   * lab.fn_canonical_tag, fn_tag_entity_id, fn_current_tags, fn_tag_match,
--     fn_find_by_tags (filters) and fn_register_tag, fn_tag (the write path).
--   * fn_check_integrity: new tag_not_carried_forward warning.
--   * Seed namespaces (tag, stage, qc, cohort, condition, topic) and the
--     stage / qc vocabularies.
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('lab.schema_version') IS NULL THEN
        RAISE EXCEPTION 'lab.schema_version not found: apply migration 002 first';
    END IF;
    IF (SELECT max(version) FROM lab.schema_version) <> 2 THEN
        RAISE EXCEPTION 'this database is at schema version %, migration 003 applies to version 2',
            (SELECT max(version) FROM lab.schema_version);
    END IF;
    IF to_regclass('lab.tag_namespace') IS NOT NULL THEN
        RAISE EXCEPTION 'lab.tag_namespace exists: migration 003 has already been applied';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Tags
-- ---------------------------------------------------------------------------
-- A hashtag-style labelling layer over events, artifacts, subjects, sessions
-- and projects. See design_docs/tagging.md for the user-facing rules; the
-- model is:
--
--   * A tag is `namespace:value`, lower-case, with a restricted character set
--     (tag_namespace / tag CHECKs below). Only case and surrounding whitespace
--     are normalized on the way in (lab.fn_canonical_tag); anything else that
--     is malformed is rejected, never rewritten. A tag written without a
--     namespace ('auditory_cortex') belongs to the reserved `tag` namespace
--     and is stored as 'tag:auditory_cortex'.
--   * Every namespace declares a policy: whether a value may change over time
--     (mutability), how many of its tags an entity may carry at once
--     (cardinality), whether new values may be created on the fly
--     (open_vocabulary) and which entity kinds it applies to. The policy is
--     frozen once the namespace is in use (trg_tag_namespace_guard), which is
--     what keeps it from drifting.
--   * tag_namespace and tag are mutable reference tables (edited in place,
--     logged in lab.row_history). tag_assignment is an APPEND-ONLY LOG of
--     'add' / 'remove' operations; the current tags of an entity are derived
--     from it by the lab.tag_current view. Nothing in the schema holds a
--     mutable "current tags" value.
--   * lab.fn_tag(kind, id, tag, op) is the one write path every client uses;
--     it applies the namespace policy in one call (replacing the current value
--     of a single-cardinality mutable namespace, auto-registering a value in
--     an open namespace). A direct INSERT into tag_assignment is still
--     policed by trg_tag_assignment_policy.
CREATE TABLE lab.tag_namespace (
    namespace       text PRIMARY KEY,
    description     text,
    -- 'immutable': once a tag of this namespace is on an entity it can never
    -- be removed or replaced there. 'mutable': it can (the log keeps history).
    mutability      text NOT NULL CHECK (mutability IN ('mutable','immutable')),
    -- 'single': at most one current tag of this namespace per entity
    -- ('stage:raw' or 'stage:analyzed', never both). 'multi': any number.
    cardinality     text NOT NULL CHECK (cardinality IN ('single','multi')),
    -- Whether lab.fn_tag may create a value that does not exist yet. A closed
    -- namespace still accepts a deliberate registration (lab.fn_register_tag
    -- or INSERT INTO lab.tag): the flag stops a typo from quietly becoming
    -- vocabulary, not a decision from being made.
    open_vocabulary boolean NOT NULL DEFAULT true,
    -- Entity kinds this namespace may be applied to.
    applies_to      text[] NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid REFERENCES lab.person(person_id),
    CONSTRAINT tag_namespace_format_ck CHECK (namespace ~ '^[a-z][a-z0-9_]{0,31}$'),
    CONSTRAINT tag_namespace_applies_to_ck CHECK (
        array_length(applies_to, 1) >= 1
        AND applies_to <@ ARRAY['event','artifact','subject','session','project']::text[])
);

CREATE TABLE lab.tag (
    tag         text PRIMARY KEY,                -- canonical 'namespace:value'
    namespace   text NOT NULL REFERENCES lab.tag_namespace(namespace),
    value       text NOT NULL,
    description text,
    -- Retired tags stay (the log references them) but cannot be added again.
    retired_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid REFERENCES lab.person(person_id),
    CONSTRAINT uq_tag_namespace_value UNIQUE (namespace, value),
    CONSTRAINT tag_value_format_ck CHECK (value ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'),
    CONSTRAINT tag_canonical_ck CHECK (tag = namespace || ':' || value)
);

-- The append-only log. Exactly one of the entity id columns is set, the one
-- named by entity_kind. There is deliberately no stored "entity_id" text
-- column derived from them: lab.fn_rename_subject cascades into subject_id
-- here, and the fn_forbid_mutation escape hatch admits that cascade only when
-- every other column is unchanged -- a derived copy of subject_id would not
-- be. lab.fn_tag_entity_id computes it where needed (views, index, triggers).
CREATE TABLE lab.tag_assignment (
    assignment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity_kind   text NOT NULL
                      CHECK (entity_kind IN ('event','artifact','subject','session','project')),
    event_id      uuid REFERENCES lab.event(event_id),
    artifact_id   uuid REFERENCES lab.artifact(artifact_id),
    subject_id    text REFERENCES lab.subject(subject_id) ON UPDATE CASCADE,
    session_id    uuid REFERENCES lab.session(session_id),
    project_id    uuid REFERENCES lab.project(project_id),
    tag           text NOT NULL REFERENCES lab.tag(tag),
    op            text NOT NULL CHECK (op IN ('add','remove')),
    note          text,
    applied_at    timestamptz NOT NULL DEFAULT now(),
    applied_by    uuid REFERENCES lab.person(person_id),
    CONSTRAINT tag_assignment_entity_ck CHECK (
        num_nonnulls(event_id, artifact_id, subject_id, session_id, project_id) = 1
        AND CASE entity_kind
                WHEN 'event'    THEN event_id    IS NOT NULL
                WHEN 'artifact' THEN artifact_id IS NOT NULL
                WHEN 'subject'  THEN subject_id  IS NOT NULL
                WHEN 'session'  THEN session_id  IS NOT NULL
                WHEN 'project'  THEN project_id  IS NOT NULL
            END)
);

-- Canonical spelling of a tag as typed by a person: lower-case, trimmed, and
-- prefixed with the reserved 'tag:' namespace when no namespace was given.
-- Everything else (illegal characters, an empty value, a second colon) is
-- left for the tag CHECKs to reject. Used by every write path and by the
-- filter functions, so 'Auditory_Cortex', ' auditory_cortex' and
-- 'tag:auditory_cortex' are one tag everywhere.
CREATE OR REPLACE FUNCTION lab.fn_canonical_tag(p_tag text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN t IS NULL THEN NULL
                WHEN position(':' IN t) = 0 THEN 'tag:' || t
                ELSE t END
    FROM (SELECT lower(btrim(p_tag)) AS t) s;
$$;

-- The entity a tag_assignment row is about, as text, whichever kind it is.
CREATE OR REPLACE FUNCTION lab.fn_tag_entity_id(
    p_event_id uuid, p_artifact_id uuid, p_subject_id text,
    p_session_id uuid, p_project_id uuid) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT coalesce(p_event_id::text, p_artifact_id::text, p_subject_id,
                    p_session_id::text, p_project_id::text);
$$;

-- "Current tags of this entity" is the one question every policy check and
-- every filter asks, so the index is shaped for it: the per-entity rows in
-- tag order, newest first within a tag.
CREATE INDEX ix_tag_assignment_entity ON lab.tag_assignment (
    entity_kind,
    lab.fn_tag_entity_id(event_id, artifact_id, subject_id, session_id, project_id),
    tag, assignment_id DESC);
CREATE INDEX ix_tag_assignment_tag      ON lab.tag_assignment (tag);
CREATE INDEX ix_tag_assignment_event    ON lab.tag_assignment (event_id);
CREATE INDEX ix_tag_assignment_artifact ON lab.tag_assignment (artifact_id);
CREATE INDEX ix_tag_assignment_subject  ON lab.tag_assignment (subject_id);
CREATE INDEX ix_tag_assignment_session  ON lab.tag_assignment (session_id);
CREATE INDEX ix_tag_assignment_project  ON lab.tag_assignment (project_id);

-- The current tags of one entity: for each tag, the newest log row decides.
-- (Newest by assignment_id, i.e. by log order; applied_at is caller-supplied.)
CREATE OR REPLACE FUNCTION lab.fn_current_tags(p_kind text, p_id text)
RETURNS TABLE (tag text, namespace text, value text, assignment_id bigint)
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT c.tag, t.namespace, t.value, c.assignment_id
    FROM (
        SELECT DISTINCT ON (a.tag) a.tag, a.op, a.assignment_id
        FROM lab.tag_assignment a
        WHERE a.entity_kind = p_kind
          AND lab.fn_tag_entity_id(a.event_id, a.artifact_id, a.subject_id,
                                   a.session_id, a.project_id) = p_id
        ORDER BY a.tag, a.assignment_id DESC
    ) c
    JOIN lab.tag t ON t.tag = c.tag
    WHERE c.op = 'add';
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
-- Tags: canonical form on the way in, and the namespace policy.
-- lab.tag: fill namespace/value from the canonical tag (a client may insert
-- just the tag string) and lower-case / trim. If the caller supplied
-- namespace or value as well, they must agree with the tag rather than be
-- silently overwritten.
CREATE OR REPLACE FUNCTION lab.fn_normalize_tag() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_ns  text;
    v_val text;
BEGIN
    IF NEW.tag IS NULL AND NEW.namespace IS NOT NULL AND NEW.value IS NOT NULL THEN
        NEW.tag := NEW.namespace || ':' || NEW.value;
    END IF;
    NEW.tag := lab.fn_canonical_tag(NEW.tag);
    IF NEW.tag IS NULL THEN
        RAISE EXCEPTION 'a tag needs a tag string or a namespace and a value';
    END IF;
    v_ns  := split_part(NEW.tag, ':', 1);
    v_val := substr(NEW.tag, length(v_ns) + 2);
    IF NEW.namespace IS NOT NULL AND lower(btrim(NEW.namespace)) <> v_ns THEN
        RAISE EXCEPTION 'tag % does not belong to namespace %', NEW.tag, NEW.namespace;
    END IF;
    IF NEW.value IS NOT NULL AND lower(btrim(NEW.value)) <> v_val THEN
        RAISE EXCEPTION 'tag % does not have value %', NEW.tag, NEW.value;
    END IF;
    NEW.namespace := v_ns;
    NEW.value     := v_val;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tag_normalize
    BEFORE INSERT ON lab.tag
    FOR EACH ROW EXECUTE FUNCTION lab.fn_normalize_tag();

-- lab.tag is editable (description, retired_at) but its identity is not: the
-- log references the tag string, so a renamed tag would rewrite history.
-- Retire it and register the right one instead.
CREATE OR REPLACE FUNCTION lab.fn_tag_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.tag <> OLD.tag OR NEW.namespace <> OLD.namespace OR NEW.value <> OLD.value THEN
        RAISE EXCEPTION
          'tag % cannot be renamed: retire it (retired_at) and register the '
          'correct tag instead', OLD.tag;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tag_guard
    BEFORE UPDATE ON lab.tag
    FOR EACH ROW EXECUTE FUNCTION lab.fn_tag_guard();

-- lab.tag_namespace: the name is canonicalized on insert like a tag; the
-- policy (mutability, cardinality, which kinds it applies to) is frozen once
-- any assignment exists in the namespace, except that applies_to may grow.
-- Without this, flipping a namespace from immutable to mutable after the
-- fact would silently void the guarantee every existing tag was given. The
-- reserved 'tag' namespace is frozen from the start: every bare tag lands in
-- it, so it must always be the permissive namespace it is seeded as.
CREATE OR REPLACE FUNCTION lab.fn_tag_namespace_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.namespace := lower(btrim(NEW.namespace));
        RETURN NEW;
    END IF;
    IF NEW.namespace <> OLD.namespace THEN
        RAISE EXCEPTION 'tag namespace % cannot be renamed', OLD.namespace;
    END IF;
    IF (NEW.mutability <> OLD.mutability OR NEW.cardinality <> OLD.cardinality
        OR NOT (OLD.applies_to <@ NEW.applies_to))
       AND (OLD.namespace = 'tag'
            OR EXISTS (SELECT 1 FROM lab.tag_assignment a JOIN lab.tag t ON t.tag = a.tag
                       WHERE t.namespace = OLD.namespace)) THEN
        RAISE EXCEPTION
          'the policy of tag namespace % (mutability, cardinality, applies_to) '
          'is frozen: it is in use', OLD.namespace;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tag_namespace_guard
    BEFORE INSERT OR UPDATE ON lab.tag_namespace
    FOR EACH ROW EXECUTE FUNCTION lab.fn_tag_namespace_guard();

-- lab.tag_assignment: canonicalize the tag, then apply the namespace policy
-- against the entity's current tags (lab.fn_current_tags). This is a trigger,
-- not a constraint, so like trg_artifact_unique_active it cannot see rows
-- another transaction is inserting concurrently; two sessions tagging the
-- same entity at the same instant can both pass a single-cardinality check.
CREATE OR REPLACE FUNCTION lab.fn_tag_assignment_policy() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_tag  lab.tag%ROWTYPE;
    v_ns   lab.tag_namespace%ROWTYPE;
    v_id   text;
    v_cur  record;
BEGIN
    NEW.tag := lab.fn_canonical_tag(NEW.tag);
    SELECT * INTO v_tag FROM lab.tag WHERE tag = NEW.tag;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = 'foreign_key_violation',
            MESSAGE = format('tag %s is not registered', NEW.tag),
            HINT    = 'lab.fn_tag registers it in an open namespace; '
                      'lab.fn_register_tag registers it deliberately.';
    END IF;
    SELECT * INTO v_ns FROM lab.tag_namespace WHERE namespace = v_tag.namespace;
    IF NOT (NEW.entity_kind = ANY (v_ns.applies_to)) THEN
        RAISE EXCEPTION 'tag namespace % does not apply to a % (applies_to: %)',
            v_ns.namespace, NEW.entity_kind, array_to_string(v_ns.applies_to, ', ');
    END IF;
    v_id := lab.fn_tag_entity_id(NEW.event_id, NEW.artifact_id, NEW.subject_id,
                                 NEW.session_id, NEW.project_id);

    IF NEW.op = 'add' THEN
        IF v_tag.retired_at IS NOT NULL THEN
            RAISE EXCEPTION 'tag % was retired on % and cannot be added',
                NEW.tag, v_tag.retired_at;
        END IF;
        IF EXISTS (SELECT 1 FROM lab.fn_current_tags(NEW.entity_kind, v_id) c
                   WHERE c.tag = NEW.tag) THEN
            RAISE EXCEPTION '% % already carries tag %', NEW.entity_kind, v_id, NEW.tag;
        END IF;
        IF v_ns.cardinality = 'single' THEN
            SELECT c.tag INTO v_cur
            FROM lab.fn_current_tags(NEW.entity_kind, v_id) c
            WHERE c.namespace = v_ns.namespace;
            IF FOUND THEN
                IF v_ns.mutability = 'immutable' THEN
                    RAISE EXCEPTION
                      '% % already carries % and namespace % is immutable and '
                      'single-valued: the tag cannot be replaced',
                      NEW.entity_kind, v_id, v_cur.tag, v_ns.namespace;
                END IF;
                RAISE EXCEPTION USING
                    MESSAGE = format('%s %s already carries %s; namespace %s is '
                                     'single-valued', NEW.entity_kind, v_id,
                                     v_cur.tag, v_ns.namespace),
                    HINT    = 'Use lab.fn_tag(kind, id, tag), which records the '
                              'removal of the current value and then the addition.';
            END IF;
        END IF;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM lab.fn_current_tags(NEW.entity_kind, v_id) c
                       WHERE c.tag = NEW.tag) THEN
            RAISE EXCEPTION '% % does not currently carry tag %',
                NEW.entity_kind, v_id, NEW.tag;
        END IF;
        IF v_ns.mutability = 'immutable' THEN
            RAISE EXCEPTION
              'tag % cannot be removed from % %: namespace % is immutable',
              NEW.tag, NEW.entity_kind, v_id, v_ns.namespace;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tag_assignment_policy
    BEFORE INSERT ON lab.tag_assignment
    FOR EACH ROW EXECUTE FUNCTION lab.fn_tag_assignment_policy();

-- fn_forbid_mutation: same body as schema.sql, now with the tag_assignment
-- message.
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

    IF TG_TABLE_NAME = 'tag_assignment' THEN
        -- The tag log has no supersedes column either: a tag is taken off an
        -- entity by appending a 'remove' row, which lab.fn_tag does.
        RAISE EXCEPTION
          '% on lab.tag_assignment is not allowed: tag assignments are an append-only log. '
          'Record a removal with lab.fn_tag(kind, id, tag, ''remove'') instead.',
          TG_OP;
    END IF;

    RAISE EXCEPTION
      '% on %.% is not allowed: this table is append-only. Insert a superseding row instead.',
      TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
END;
$$;

-- ---------------------------------------------------------------------------
-- Append-only protection for the tag log, and edit history for the vocabulary
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['tag_assignment'] LOOP
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

DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM (VALUES
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
-- Views
-- ---------------------------------------------------------------------------
-- Current tags of every tagged entity: per (entity, tag) the newest log row
-- decides, and only 'add' rows survive. entity_id is the entity's key as
-- text whichever kind it is; display_tag drops the reserved 'tag:' prefix
-- so a bare tag reads the way it was written.
CREATE VIEW lab.tag_current AS
    SELECT a.assignment_id, a.entity_kind,
           lab.fn_tag_entity_id(a.event_id, a.artifact_id, a.subject_id,
                                a.session_id, a.project_id) AS entity_id,
           a.event_id, a.artifact_id, a.subject_id, a.session_id, a.project_id,
           a.tag, t.namespace, t.value,
           CASE WHEN t.namespace = 'tag' THEN t.value ELSE a.tag END AS display_tag,
           a.note, a.applied_at, a.applied_by
    FROM (
        SELECT DISTINCT ON (entity_kind,
                            lab.fn_tag_entity_id(event_id, artifact_id, subject_id,
                                                 session_id, project_id),
                            tag) *
        FROM lab.tag_assignment
        ORDER BY entity_kind,
                 lab.fn_tag_entity_id(event_id, artifact_id, subject_id,
                                      session_id, project_id),
                 tag, assignment_id DESC
    ) a
    JOIN lab.tag t ON t.tag = a.tag
    WHERE a.op = 'add';

-- One row per tagged entity with its current tags as sorted arrays.
CREATE VIEW lab.entity_tags AS
    SELECT entity_kind, entity_id,
           array_agg(tag ORDER BY tag)         AS tags,
           array_agg(display_tag ORDER BY tag) AS display_tags
    FROM lab.tag_current
    GROUP BY entity_kind, entity_id;

-- ---------------------------------------------------------------------------
-- Tag filters and the tag write path
-- ---------------------------------------------------------------------------
-- Does the entity's current tag set satisfy a hashtag-style filter? Every
-- element is a tag pattern: a canonical tag ('stage:raw', or a bare
-- 'auditory_cortex' for the reserved namespace) matches that tag exactly;
-- 'namespace:*' matches any current tag of that namespace. p_all must all
-- match, at least one of p_any must match (when given), none of p_none may.
-- NULL or empty arrays impose nothing. This is the single definition of the
-- filter semantics the MATLAB class, the GUI and the MCP server expose.
CREATE OR REPLACE FUNCTION lab.fn_tag_match(
    p_kind text, p_id text, p_all text[], p_any text[] DEFAULT NULL, p_none text[] DEFAULT NULL
) RETURNS boolean
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    WITH cur AS (SELECT tag, namespace FROM lab.fn_current_tags(p_kind, p_id)),
    hit AS (
        SELECT p, EXISTS (SELECT 1 FROM cur
                          WHERE cur.tag = p OR p = cur.namespace || ':*') AS ok
        FROM unnest(coalesce(p_all, '{}') || coalesce(p_any, '{}') || coalesce(p_none, '{}')) AS u(raw)
        CROSS JOIN LATERAL (SELECT lab.fn_canonical_tag(u.raw) AS p) c
    )
    SELECT NOT EXISTS (SELECT 1 FROM unnest(coalesce(p_all, '{}')) x
                       JOIN hit ON hit.p = lab.fn_canonical_tag(x) WHERE NOT hit.ok)
       AND (coalesce(array_length(p_any, 1), 0) = 0
            OR EXISTS (SELECT 1 FROM unnest(p_any) x
                       JOIN hit ON hit.p = lab.fn_canonical_tag(x) WHERE hit.ok))
       AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p_none, '{}')) x
                       JOIN hit ON hit.p = lab.fn_canonical_tag(x) WHERE hit.ok);
$$;

-- The tagged entities of one kind that satisfy a filter. An entity with no
-- tags at all is never returned (even by a filter that is only p_none); the
-- per-table getters in the clients apply fn_tag_match to the base table
-- when untagged rows should be included.
CREATE OR REPLACE FUNCTION lab.fn_find_by_tags(
    p_kind text, p_all text[], p_any text[] DEFAULT NULL, p_none text[] DEFAULT NULL
) RETURNS TABLE (entity_id text)
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT e.entity_id
    FROM (SELECT DISTINCT
              lab.fn_tag_entity_id(a.event_id, a.artifact_id, a.subject_id,
                                   a.session_id, a.project_id) AS entity_id
          FROM lab.tag_assignment a
          WHERE a.entity_kind = p_kind) e
    WHERE lab.fn_tag_match(p_kind, e.entity_id, p_all, p_any, p_none)
    ORDER BY e.entity_id;
$$;

-- Register a tag without applying it. Deliberate registration: it works in a
-- closed namespace too (that flag only governs lab.fn_tag's auto-creation).
-- Returns the canonical tag; registering an existing tag is a no-op.
CREATE OR REPLACE FUNCTION lab.fn_register_tag(
    p_tag text, p_description text DEFAULT NULL, p_by uuid DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_tag text := lab.fn_canonical_tag(p_tag);
BEGIN
    IF v_tag IS NULL THEN
        RAISE EXCEPTION 'a tag is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM lab.tag_namespace
                   WHERE namespace = split_part(v_tag, ':', 1)) THEN
        RAISE EXCEPTION 'tag namespace % does not exist; create it first '
                        '(INSERT INTO lab.tag_namespace / CarasLabDB.addTagNamespace)',
            split_part(v_tag, ':', 1);
    END IF;
    INSERT INTO lab.tag (tag, description, created_by)
    VALUES (v_tag, p_description, p_by)
    ON CONFLICT (tag) DO NOTHING;
    RETURN v_tag;
END;
$$;

-- The write path for tags. p_kind names the entity table, p_id its key as
-- text, p_op is 'add' (default) or 'remove'. In one call it:
--   * canonicalizes the tag and, for 'add', registers an unknown value when
--     the namespace is open (a closed namespace raises);
--   * for 'add' in a single-valued, mutable namespace, first records the
--     removal of the value the entity currently carries, so 'stage:raw' ->
--     'stage:preprocessed' is one call and two log rows;
--   * inserts the assignment, which trg_tag_assignment_policy checks.
-- Adding a tag the entity already carries writes nothing and returns the
-- assignment that made it current. Returns the new assignment_id otherwise.
CREATE OR REPLACE FUNCTION lab.fn_tag(
    p_kind text, p_id text, p_tag text, p_op text DEFAULT 'add',
    p_note text DEFAULT NULL, p_by uuid DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_tag  text := lab.fn_canonical_tag(p_tag);
    v_ns   lab.tag_namespace%ROWTYPE;
    v_cur  record;
    v_id   bigint;
BEGIN
    IF p_kind IS NULL OR p_kind NOT IN ('event','artifact','subject','session','project') THEN
        RAISE EXCEPTION 'entity kind must be event, artifact, subject, session or project, got %', p_kind;
    END IF;
    IF p_id IS NULL OR btrim(p_id) = '' THEN
        RAISE EXCEPTION 'an entity id is required';
    END IF;
    IF p_op NOT IN ('add','remove') THEN
        RAISE EXCEPTION 'op must be ''add'' or ''remove'', got %', p_op;
    END IF;
    IF v_tag IS NULL THEN
        RAISE EXCEPTION 'a tag is required';
    END IF;
    SELECT * INTO v_ns FROM lab.tag_namespace WHERE namespace = split_part(v_tag, ':', 1);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'tag namespace % does not exist; create it first '
                        '(INSERT INTO lab.tag_namespace / CarasLabDB.addTagNamespace)',
            split_part(v_tag, ':', 1);
    END IF;

    IF p_op = 'add' THEN
        IF NOT EXISTS (SELECT 1 FROM lab.tag WHERE tag = v_tag) THEN
            IF NOT v_ns.open_vocabulary THEN
                RAISE EXCEPTION USING
                    MESSAGE = format('tag %s is not registered and namespace %s has a '
                                     'closed vocabulary', v_tag, v_ns.namespace),
                    HINT    = 'Pick a registered value (SELECT tag FROM lab.tag WHERE '
                              'namespace = ...) or register it deliberately with '
                              'lab.fn_register_tag.';
            END IF;
            INSERT INTO lab.tag (tag, created_by) VALUES (v_tag, p_by);
        END IF;
        SELECT c.tag, c.assignment_id INTO v_cur
        FROM lab.fn_current_tags(p_kind, p_id) c WHERE c.tag = v_tag;
        IF FOUND THEN
            RETURN v_cur.assignment_id;      -- already current: nothing to record
        END IF;
        IF v_ns.cardinality = 'single' AND v_ns.mutability = 'mutable' THEN
            FOR v_cur IN SELECT c.tag FROM lab.fn_current_tags(p_kind, p_id) c
                         WHERE c.namespace = v_ns.namespace LOOP
                INSERT INTO lab.tag_assignment
                    (entity_kind, event_id, artifact_id, subject_id, session_id, project_id,
                     tag, op, note, applied_by)
                VALUES
                    (p_kind,
                     CASE WHEN p_kind = 'event'    THEN p_id::uuid END,
                     CASE WHEN p_kind = 'artifact' THEN p_id::uuid END,
                     CASE WHEN p_kind = 'subject'  THEN p_id END,
                     CASE WHEN p_kind = 'session'  THEN p_id::uuid END,
                     CASE WHEN p_kind = 'project'  THEN p_id::uuid END,
                     v_cur.tag, 'remove', 'replaced by ' || v_tag, p_by);
            END LOOP;
        END IF;
    END IF;

    INSERT INTO lab.tag_assignment
        (entity_kind, event_id, artifact_id, subject_id, session_id, project_id,
         tag, op, note, applied_by)
    VALUES
        (p_kind,
         CASE WHEN p_kind = 'event'    THEN p_id::uuid END,
         CASE WHEN p_kind = 'artifact' THEN p_id::uuid END,
         CASE WHEN p_kind = 'subject'  THEN p_id END,
         CASE WHEN p_kind = 'session'  THEN p_id::uuid END,
         CASE WHEN p_kind = 'project'  THEN p_id::uuid END,
         v_tag, p_op, p_note, p_by)
    RETURNING assignment_id INTO v_id;
    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Integrity report: same body as schema.sql, with tag_not_carried_forward
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
    -- A correction that lost tags: the superseded event or artifact currently
    -- carries a tag its successor does not. CarasLabDB carries tags forward
    -- when it supersedes a row; a correction made by hand may not have.
    SELECT 'warning', 'tag_not_carried_forward', s.event_id::text,
           format('supersedes event %s, which carries tag %s', c.entity_id, c.tag)
    FROM lab.tag_current c
    JOIN lab.event s ON s.supersedes = c.event_id
    WHERE c.entity_kind = 'event'
      AND NOT EXISTS (SELECT 1 FROM lab.fn_current_tags('event', s.event_id::text) x
                      WHERE x.tag = c.tag)

    UNION ALL
    SELECT 'warning', 'tag_not_carried_forward', s.artifact_id::text,
           format('supersedes artifact %s, which carries tag %s', c.entity_id, c.tag)
    FROM lab.tag_current c
    JOIN lab.artifact s ON s.supersedes = c.artifact_id
    WHERE c.entity_kind = 'artifact'
      AND NOT EXISTS (SELECT 1 FROM lab.fn_current_tags('artifact', s.artifact_id::text) x
                      WHERE x.tag = c.tag)
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
-- Tag namespaces. 'tag' is reserved: every tag written without a namespace
-- lands in it, so it is the permissive one and its policy is frozen
-- (trg_tag_namespace_guard). The others are a starting vocabulary any member
-- may extend. Note the difference between artifact.role and stage: role says
-- what a file *is* (fixed at registration), stage says where it is in the
-- pipeline, which changes.
INSERT INTO lab.tag_namespace (namespace, description, mutability, cardinality,
                               open_vocabulary, applies_to) VALUES
    ('tag',       'Free-form tags written without a namespace (''auditory_cortex'')',
                  'mutable', 'multi', true,
                  ARRAY['event','artifact','subject','session','project']),
    ('stage',     'Processing stage of a file: where it is in the pipeline. '
                  'Changes over time (artifact.role says what the file is).',
                  'mutable', 'single', false, ARRAY['artifact']),
    ('qc',        'Quality-control verdict', 'mutable', 'single', false,
                  ARRAY['artifact','event','session']),
    ('cohort',    'Experimental cohort an animal was assigned to; permanent',
                  'immutable', 'single', true, ARRAY['subject','session']),
    ('condition', 'Experimental condition; permanent once assigned',
                  'immutable', 'single', true, ARRAY['subject','session','event']),
    ('topic',     'Topic or theme, any number per entity', 'mutable', 'multi', true,
                  ARRAY['event','artifact','subject','session','project'])
ON CONFLICT (namespace) DO NOTHING;

INSERT INTO lab.tag (tag, description) VALUES
    ('stage:raw',          'As acquired'),
    ('stage:preprocessed', 'Filtered / re-referenced / converted'),
    ('stage:sorted',       'Spike-sorted'),
    ('stage:curated',      'Sorting manually curated'),
    ('stage:analyzed',     'Analysis outputs derived from it'),
    ('qc:pending',         'Not yet checked'),
    ('qc:pass',            'Checked, acceptable'),
    ('qc:fail',            'Checked, rejected')
ON CONFLICT (tag) DO NOTHING;

INSERT INTO lab.schema_version (version, description) VALUES
    (3, 'Migration 003: tags');
