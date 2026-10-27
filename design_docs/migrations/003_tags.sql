-- ============================================================================
-- Migration 003: tags (schema version 2 -> 3)
-- ============================================================================
-- Brings a version-2 database (schema.sql as of migration 002) to version 3,
-- the version schema.sql now installs. A fresh install does not need this
-- file.
--
-- Apply as the schema owner, in one transaction, stopping on the first error:
--
--     psql -X -v ON_ERROR_STOP=1 -1 -d lab -f design_docs/migrations/003_tags.sql
--
-- Take a pg_dump first. What it changes:
--   * lab.tag_namespace, lab.tag: the tag vocabulary -- namespaces with their
--     mutability / cardinality / open-vocabulary / applies_to policy, and the
--     registered 'namespace:value' tags. Mutable, recorded in row_history;
--     trg_tag_namespace_guard freezes a namespace's policy once it is in use
--     (the reserved 'tag' namespace from the start), trg_tag_guard stops a
--     tag being renamed.
--   * lab.tag_assignment: the append-only log of tags added to and removed
--     from events, artifacts, subjects, sessions and projects, policed by
--     trg_tag_assignment_policy. Added to the fn_forbid_mutation triggers.
--   * lab.fn_canonical_tag, lab.fn_register_tag, lab.fn_tag (the write entry
--     point), lab.fn_tag_match and lab.fn_find_by_tags (the filter semantics),
--     and the lab.tag_current / lab.entity_tags views.
--   * fn_forbid_mutation: tag_assignment reports as an append-only log.
--   * fn_check_integrity: new tag_not_carried_forward check.
--   * Seed namespaces tag, stage, qc, cohort, condition, topic and the stage
--     and qc values.
--
-- Re-run design_docs/grants.sql afterwards: lab_rw needs UPDATE on the two
-- vocabulary tables, and the new tables need their SELECT / INSERT grants.
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('lab.schema_version') IS NULL THEN
        RAISE EXCEPTION 'lab.schema_version not found: apply migration 002 first';
    END IF;
    IF (SELECT max(version) FROM lab.schema_version) IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'this database is at schema version %, but migration 003 '
                        'applies to version 2 only',
                        (SELECT max(version) FROM lab.schema_version);
    END IF;
    IF to_regclass('lab.tag_namespace') IS NOT NULL THEN
        RAISE EXCEPTION 'lab.tag_namespace exists: migration 003 has already been applied';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Tag tables
-- ---------------------------------------------------------------------------
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
-- Tag triggers: canonical spelling, vocabulary guards, assignment policy
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- tag_assignment is append-only
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
        'tag_assignment'
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

-- ---------------------------------------------------------------------------
-- Edit history for the tag vocabulary
-- ---------------------------------------------------------------------------
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
-- Current-tag views
-- ---------------------------------------------------------------------------
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
-- Integrity report: tag_not_carried_forward
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

INSERT INTO lab.schema_version (version, description) VALUES
    (3, 'Migration 003: tags');
