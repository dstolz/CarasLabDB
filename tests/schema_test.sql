-- ============================================================================
-- Schema assertions for design_docs/schema.sql
-- ============================================================================
-- Run against a database that has just had schema.sql (or the v1 schema plus
-- every script in design_docs/migrations/) applied and holds no other data:
--
--     psql -X -v ON_ERROR_STOP=1 -d lab_test -f tests/schema_test.sql
--
-- Every check raises on failure, so a non-zero exit status means a failed
-- assertion and the message names it. The whole run is one transaction that
-- is rolled back at the end, so the database is left as it was.
-- ============================================================================

\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
SET client_min_messages = warning;
BEGIN;

-- ---------------------------------------------------------------------------
-- Helpers (session-temporary)
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.assert(p_ok boolean, p_what text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok IS NOT TRUE THEN
        RAISE EXCEPTION 'ASSERTION FAILED: %', p_what;
    END IF;
END;
$$;

-- Run p_sql in a subtransaction and require that it fails with a message
-- matching p_pattern. The statement's effects are rolled back either way.
CREATE FUNCTION pg_temp.expect_error(p_sql text, p_pattern text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE failed boolean := false;
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        failed := true;
        IF SQLERRM !~ p_pattern THEN
            RAISE EXCEPTION 'ASSERTION FAILED: % raised "%", expected /%/',
                p_sql, SQLERRM, p_pattern;
        END IF;
    END;
    IF NOT failed THEN
        RAISE EXCEPTION 'ASSERTION FAILED: % succeeded, expected an error /%/',
            p_sql, p_pattern;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
INSERT INTO lab.person (person_id, full_name, email)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'Test Person', 'Test@Example.edu');
INSERT INTO lab.project (project_id, name)
VALUES ('00000000-0000-0000-0000-0000000000b1', 'test-project');
INSERT INTO lab.storage_root (name) VALUES ('nas-test');
INSERT INTO lab.subject (subject_id, project_id) VALUES
    ('G1', '00000000-0000-0000-0000-0000000000b1'),
    ('G2', '00000000-0000-0000-0000-0000000000b1');
INSERT INTO lab.session (session_id, subject_id, label, storage_root_id, relative_path) VALUES
    ('00000000-0000-0000-0000-0000000000c1', 'G1', 's1',
     (SELECT root_id FROM lab.storage_root WHERE name = 'nas-test'), 'G1\s1'),
    ('00000000-0000-0000-0000-0000000000c2', 'G2', 's1',
     (SELECT root_id FROM lab.storage_root WHERE name = 'nas-test'), 'G2/s1');

-- Recording e1 (session-only insert: subject_id is filled from the session).
INSERT INTO lab.event (event_id, event_type, session_id, occurred_at)
VALUES ('00000000-0000-0000-0000-0000000000e1', 'recording',
        '00000000-0000-0000-0000-0000000000c1', '2026-09-01 14:00-04');
INSERT INTO lab.recording_event (event_id, sample_rate_hz, n_channels)
VALUES ('00000000-0000-0000-0000-0000000000e1', 20000, 64);

-- Its raw file f1 (upper-case checksum, backslash path: both normalized).
INSERT INTO lab.artifact (artifact_id, produced_by_event_id, storage_root_id,
                          relative_path, checksum, role, session_id)
VALUES ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e1',
        (SELECT root_id FROM lab.storage_root WHERE name = 'nas-test'),
        'G1\s1\raw.dat', upper(repeat('ab', 32)), 'raw',
        '00000000-0000-0000-0000-0000000000c1');

-- ---------------------------------------------------------------------------
-- Version and baseline behaviour
-- ---------------------------------------------------------------------------
SELECT pg_temp.assert((SELECT max(version) FROM lab.schema_version) = 3,
                      'schema_version is 3');

SELECT pg_temp.assert(
    (SELECT subject_id FROM lab.event WHERE event_id = '00000000-0000-0000-0000-0000000000e1') = 'G1',
    'trg_event_fill_subject fills subject_id from the session');
SELECT pg_temp.assert(
    (SELECT relative_path FROM lab.session WHERE session_id = '00000000-0000-0000-0000-0000000000c1') = 'G1/s1',
    'session path backslashes are normalized');
SELECT pg_temp.assert(
    (SELECT relative_path || '|' || checksum FROM lab.artifact
      WHERE artifact_id = '00000000-0000-0000-0000-0000000000f1')
    = 'G1/s1/raw.dat|' || repeat('ab', 32),
    'artifact path and checksum are normalized');

SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.person (full_name, email) VALUES ('Dup', 'test@example.EDU')$q$,
    'uq_person_email_lower');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.event (event_type, subject_id, session_id, occurred_at)
       VALUES ('behavior', 'G2', '00000000-0000-0000-0000-0000000000c1', now())$q$,
    'event_session_subject_fk');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.event (event_type, subject_id, occurred_at) VALUES ('recording', 'G1', now());
       INSERT INTO lab.recording_event (event_id)
       SELECT event_id FROM lab.event WHERE session_id IS NULL AND event_type = 'recording'$q$,
    'must reference a session');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.event (event_type, subject_id, occurred_at, supersedes)
       VALUES ('birth', 'G1', now(), '00000000-0000-0000-0000-0000000000e1')$q$,
    'must preserve the event type');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at)
       VALUES ('00000000-0000-0000-0000-00000000aa01', 'analysis', 'G1', now());
       INSERT INTO lab.analysis_event (event_id, status, finished_at)
       VALUES ('00000000-0000-0000-0000-00000000aa01', 'running', now())$q$,
    'analysis_running_unfinished_ck');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, relative_path, checksum)
       VALUES ('00000000-0000-0000-0000-0000000000e1', 1, '/abs/path.dat', repeat('a', 64))$q$,
    'artifact_path_ck');

-- ---------------------------------------------------------------------------
-- The subject_rename escape hatch admits only a real rename (finding 5)
-- ---------------------------------------------------------------------------
SELECT pg_temp.expect_error(
    $q$SELECT set_config('lab.maintenance', 'subject_rename', true);
       UPDATE lab.event SET occurred_at = '1999-01-01', notes = 'tampered'
       WHERE event_id = '00000000-0000-0000-0000-0000000000e1'$q$,
    'admits only the subject-id relabelling');
-- Relabelling one event to another existing animal is not a rename.
SELECT pg_temp.expect_error(
    $q$SELECT set_config('lab.maintenance', 'subject_rename', true);
       SELECT set_config('lab.rename_from', 'G1', true);
       SELECT set_config('lab.rename_to', 'G2', true);
       UPDATE lab.artifact SET subject_id = 'G2'
       WHERE artifact_id = '00000000-0000-0000-0000-0000000000f1'$q$,
    'admits only the subject-id relabelling');

-- ---------------------------------------------------------------------------
-- Every event but an analysis names a subject (finding 11)
-- ---------------------------------------------------------------------------
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.event (event_type, occurred_at) VALUES ('histology', now())$q$,
    'event_subject_required_ck');
INSERT INTO lab.event (event_id, event_type, occurred_at)
VALUES ('00000000-0000-0000-0000-0000000000e2', 'analysis', '2026-09-02 10:00-04');
INSERT INTO lab.analysis_event (event_id, status) VALUES
    ('00000000-0000-0000-0000-0000000000e2', 'succeeded');

-- ---------------------------------------------------------------------------
-- Provenance stays acyclic (finding 12)
-- ---------------------------------------------------------------------------
-- e2 consumes f1 and produces f2: a legitimate edge.
INSERT INTO lab.event_input (event_id, artifact_id)
VALUES ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000f1');
INSERT INTO lab.artifact (artifact_id, produced_by_event_id, storage_root_id,
                          relative_path, checksum, role)
VALUES ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000e2',
        (SELECT root_id FROM lab.storage_root WHERE name = 'nas-test'),
        'G1/s1/spikes.npy', repeat('ef', 32), 'spikes');
-- Self-consumption and a two-step loop are both rejected.
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.event_input (event_id, artifact_id)
       VALUES ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000f2')$q$,
    'cyclic');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.event_input (event_id, artifact_id)
       VALUES ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000f2')$q$,
    'cyclic');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.fn_artifact_lineage('00000000-0000-0000-0000-0000000000f2', 'up')) = 2,
    'lineage up from f2 is f2 <- e2 <- f1 <- e1 (two rows)');

-- ---------------------------------------------------------------------------
-- Correcting an event re-points its artifacts (finding 2)
-- ---------------------------------------------------------------------------
-- Supersede recording e1 with e7 (sample rate corrected).
INSERT INTO lab.event (event_id, event_type, session_id, occurred_at, supersedes)
VALUES ('00000000-0000-0000-0000-0000000000e7', 'recording',
        '00000000-0000-0000-0000-0000000000c1', '2026-09-01 14:00-04',
        '00000000-0000-0000-0000-0000000000e1');
INSERT INTO lab.recording_event (event_id, sample_rate_hz, n_channels)
VALUES ('00000000-0000-0000-0000-0000000000e7', 30000, 64);

SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.fn_check_integrity()
            WHERE check_name = 'artifact_producer_superseded'
              AND subject = '00000000-0000-0000-0000-0000000000f1'),
    'integrity check reports f1 stranded on superseded e1');

-- Re-point f1 at e7, keeping the same file: allowed.
INSERT INTO lab.artifact (artifact_id, produced_by_event_id, storage_root_id,
                          relative_path, checksum, role, session_id, subject_id, supersedes)
SELECT '00000000-0000-0000-0000-0000000000f7', '00000000-0000-0000-0000-0000000000e7',
       storage_root_id, relative_path, checksum, role, session_id, subject_id, artifact_id
FROM lab.artifact WHERE artifact_id = '00000000-0000-0000-0000-0000000000f1';

SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity()
                WHERE check_name = 'artifact_producer_superseded'),
    'no stranded artifacts after re-pointing');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.artifact_active
      WHERE produced_by_event_id = '00000000-0000-0000-0000-0000000000e7') = 1,
    'the corrected recording lists its file');

-- A fresh registration of the same file is still rejected, whether the
-- existing row is the original or the active correction.
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, relative_path, checksum)
       SELECT '00000000-0000-0000-0000-0000000000e7', storage_root_id, relative_path, checksum
       FROM lab.artifact WHERE artifact_id = '00000000-0000-0000-0000-0000000000f7'$q$,
    'already registers this file|uq_artifact_file_original');
-- A second correction of an already-corrected row forks the chain: rejected.
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, relative_path,
                                 checksum, supersedes)
       SELECT produced_by_event_id, storage_root_id, relative_path, checksum, artifact_id
       FROM lab.artifact WHERE artifact_id = '00000000-0000-0000-0000-0000000000f1'$q$,
    'already registers this file|uq_artifact_supersedes');
-- A metadata-only correction of the active row (role) is allowed.
INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, relative_path,
                          checksum, role, session_id, subject_id, supersedes)
SELECT produced_by_event_id, storage_root_id, relative_path, checksum, 'derived',
       session_id, subject_id, artifact_id
FROM lab.artifact WHERE artifact_id = '00000000-0000-0000-0000-0000000000f7';
SELECT pg_temp.assert(
    (SELECT role FROM lab.artifact_active
      WHERE relative_path = 'G1/s1/raw.dat') = 'derived',
    'metadata-only artifact correction is active');

-- ---------------------------------------------------------------------------
-- Edits to mutable tables are recorded (finding 8)
-- ---------------------------------------------------------------------------
UPDATE lab.subject SET sex = 'F', notes = 'sexed at weaning' WHERE subject_id = 'G1';
UPDATE lab.subject SET sex = 'F' WHERE subject_id = 'G1';      -- no-op: not logged
INSERT INTO lab.project_member (project_id, person_id)
VALUES ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1');
DELETE FROM lab.project_member;

SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.row_history WHERE table_name = 'subject') = 1,
    'one subject history row (no-op update not logged)');
SELECT pg_temp.assert(
    (SELECT old_row ->> 'sex' || '>' || (new_row ->> 'sex') || '|' || (row_key ->> 'subject_id')
       || '|' || changed_by
     FROM lab.row_history WHERE table_name = 'subject') = 'U>F|G1|' || session_user,
    'subject history row holds old and new values, key and login');
SELECT pg_temp.assert(
    (SELECT row_key FROM lab.row_history WHERE table_name = 'project_member' AND operation = 'DELETE')
    = jsonb_build_object('project_id', '00000000-0000-0000-0000-0000000000b1',
                         'person_id',  '00000000-0000-0000-0000-0000000000a1'),
    'project_member delete recorded with its composite key');

-- ---------------------------------------------------------------------------
-- Tags: syntax, namespace policy, the log and the derived current state
-- ---------------------------------------------------------------------------
-- Canonical form: lower-case, trimmed, bare tags land in the 'tag' namespace.
SELECT pg_temp.assert(
    lab.fn_register_tag(' Auditory_Cortex ') = 'tag:auditory_cortex'
    AND lab.fn_register_tag('Topic:Gerbil') = 'topic:gerbil'
    AND lab.fn_register_tag('tag:auditory_cortex') = 'tag:auditory_cortex',
    'fn_register_tag canonicalizes and is idempotent');
SELECT pg_temp.assert(
    (SELECT namespace || '|' || value FROM lab.tag WHERE tag = 'tag:auditory_cortex')
    = 'tag|auditory_cortex',
    'trg_tag_normalize splits the canonical tag into namespace and value');
INSERT INTO lab.tag (namespace, value) VALUES ('topic', 'Hearing');
SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.tag WHERE tag = 'topic:hearing'),
    'a tag inserted as namespace + value gets its canonical tag string');
-- Malformed tags are rejected, not rewritten.
SELECT pg_temp.expect_error($q$INSERT INTO lab.tag (tag) VALUES ('bad tag')$q$,
                            'tag_value_format_ck');
SELECT pg_temp.expect_error($q$INSERT INTO lab.tag (tag) VALUES ('stage:raw/1')$q$,
                            'tag_value_format_ck');
SELECT pg_temp.expect_error($q$INSERT INTO lab.tag (tag) VALUES ('a:b:c')$q$,
                            'tag_value_format_ck');
SELECT pg_temp.expect_error($q$INSERT INTO lab.tag (tag) VALUES ('stage:')$q$,
                            'tag_value_format_ck');
SELECT pg_temp.expect_error($q$INSERT INTO lab.tag (tag, namespace) VALUES ('qc:pass', 'stage')$q$,
                            'does not belong to namespace');
SELECT pg_temp.expect_error($q$INSERT INTO lab.tag (tag) VALUES ('nonexistent:x')$q$,
                            'tag_namespace_fkey');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.tag_namespace (namespace, mutability, cardinality, applies_to)
       VALUES ('Bad Name', 'mutable', 'multi', ARRAY['event'])$q$,
    'tag_namespace_format_ck');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.tag_namespace (namespace, mutability, cardinality, applies_to)
       VALUES ('region', 'mutable', 'multi', ARRAY['file'])$q$,
    'tag_namespace_applies_to_ck');
INSERT INTO lab.tag_namespace (namespace, mutability, cardinality, applies_to)
VALUES (' Region ', 'immutable', 'multi', ARRAY['event', 'artifact']);
SELECT pg_temp.assert(EXISTS (SELECT 1 FROM lab.tag_namespace WHERE namespace = 'region'),
                      'namespace names are canonicalized on insert');

-- fn_tag: the write path. Replacing the value of a single-valued mutable
-- namespace is one call and two log rows; adding a current tag writes nothing.
SELECT pg_temp.assert(lab.fn_tag('artifact', '00000000-0000-0000-0000-0000000000f1', 'Stage:Raw') IS NOT NULL,
                      'write: lab.fn_tag(''artifact'', ''00000000-0000-0000-0000-000000000');
SELECT pg_temp.assert(
    lab.fn_tag('artifact', '00000000-0000-0000-0000-0000000000f1', 'stage:raw')
    = (SELECT assignment_id FROM lab.tag_assignment WHERE tag = 'stage:raw' AND op = 'add'),
    'adding a tag the entity already carries writes nothing');
SELECT pg_temp.assert(lab.fn_tag('artifact', '00000000-0000-0000-0000-0000000000f1', 'stage:preprocessed') IS NOT NULL,
                      'write: lab.fn_tag(''artifact'', ''00000000-0000-0000-0000-000000000');
SELECT pg_temp.assert(
    (SELECT string_agg(tag || ':' || op, ',' ORDER BY assignment_id)
     FROM lab.tag_assignment WHERE artifact_id = '00000000-0000-0000-0000-0000000000f1')
    = 'stage:raw:add,stage:raw:remove,stage:preprocessed:add',
    'fn_tag records the removal of the current value, then the addition');
SELECT pg_temp.assert(
    (SELECT string_agg(tag, ',') FROM lab.tag_current
      WHERE entity_kind = 'artifact' AND entity_id = '00000000-0000-0000-0000-0000000000f1')
    = 'stage:preprocessed',
    'tag_current shows one stage tag after the replacement');
-- Closed vocabulary: fn_tag will not invent a value; a deliberate registration works.
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('artifact', '00000000-0000-0000-0000-0000000000f1', 'stage:currated')$q$,
    'closed vocabulary');
SELECT pg_temp.assert(lab.fn_register_tag('stage:archived', 'Moved to cold storage') IS NOT NULL,
                      'write: lab.fn_register_tag(''stage:archived'', ''Moved to cold stor');
SELECT pg_temp.assert(EXISTS (SELECT 1 FROM lab.tag WHERE tag = 'stage:archived'),
                      'fn_register_tag registers a value in a closed namespace');
-- Open vocabulary: a new value is registered on first use.
SELECT pg_temp.assert(lab.fn_tag('artifact', '00000000-0000-0000-0000-0000000000f1', 'visual_cortex') IS NOT NULL,
                      'write: lab.fn_tag(''artifact'', ''00000000-0000-0000-0000-000000000');
SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.tag WHERE tag = 'tag:visual_cortex')
    AND (SELECT display_tag FROM lab.tag_current WHERE tag = 'tag:visual_cortex') = 'visual_cortex',
    'a bare tag is auto-registered in the tag namespace and displayed bare');
-- applies_to
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('subject', 'G1', 'stage:raw')$q$,
    'does not apply to a subject');
-- Immutable, single-valued: set once, never replaced or removed.
SELECT pg_temp.assert(lab.fn_tag('subject', 'G1', 'cohort:a') IS NOT NULL,
                      'write: lab.fn_tag(''subject'', ''G1'', ''cohort:a'')');
SELECT pg_temp.expect_error($q$SELECT lab.fn_tag('subject', 'G1', 'cohort:b')$q$,
                            'immutable and single-valued');
SELECT pg_temp.expect_error($q$SELECT lab.fn_tag('subject', 'G1', 'cohort:a', 'remove')$q$,
                            'is immutable');
-- Mutable, multi-valued: add and remove freely; removing twice is an error.
SELECT pg_temp.assert(lab.fn_tag('subject', 'G1', 'topic:gerbil') IS NOT NULL,
                      'write: lab.fn_tag(''subject'', ''G1'', ''topic:gerbil'')');
SELECT pg_temp.assert(lab.fn_tag('subject', 'G1', 'topic:hearing') IS NOT NULL,
                      'write: lab.fn_tag(''subject'', ''G1'', ''topic:hearing'')');
SELECT pg_temp.assert(lab.fn_tag('subject', 'G1', 'topic:gerbil', 'remove') IS NOT NULL,
                      'write: lab.fn_tag(''subject'', ''G1'', ''topic:gerbil'', ''remove''');
SELECT pg_temp.expect_error($q$SELECT lab.fn_tag('subject', 'G1', 'topic:gerbil', 'remove')$q$,
                            'does not currently carry');
-- A direct INSERT is policed too: a second single-valued tag is refused.
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.tag_assignment (entity_kind, artifact_id, tag, op)
       VALUES ('artifact', '00000000-0000-0000-0000-0000000000f1', 'stage:sorted', 'add')$q$,
    'single-valued');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.tag_assignment (entity_kind, artifact_id, subject_id, tag, op)
       VALUES ('artifact', '00000000-0000-0000-0000-0000000000f1', 'G1', 'topic:gerbil', 'add')$q$,
    'tag_assignment_entity_ck');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.tag_assignment (entity_kind, artifact_id, tag, op)
       VALUES ('artifact', '00000000-0000-0000-0000-0000000000f1', 'topic:nope', 'add')$q$,
    'not registered');
-- Every kind can be tagged.
SELECT pg_temp.assert(lab.fn_tag('event',   '00000000-0000-0000-0000-0000000000e1', 'qc:pass') IS NOT NULL,
                      'write: lab.fn_tag(''event'',   ''00000000-0000-0000-0000-0000000000');
SELECT pg_temp.assert(lab.fn_tag('session', '00000000-0000-0000-0000-0000000000c1', 'Condition:Noise') IS NOT NULL,
                      'write: lab.fn_tag(''session'', ''00000000-0000-0000-0000-0000000000');
SELECT pg_temp.assert(lab.fn_tag('project', '00000000-0000-0000-0000-0000000000b1', 'topic:gerbil') IS NOT NULL,
                      'write: lab.fn_tag(''project'', ''00000000-0000-0000-0000-0000000000');
SELECT pg_temp.assert(
    (SELECT string_agg(entity_kind, ',' ORDER BY entity_kind) FROM lab.entity_tags)
    = 'artifact,event,project,session,subject',
    'entity_tags lists every tagged kind');
SELECT pg_temp.assert(
    (SELECT tags FROM lab.entity_tags WHERE entity_kind = 'subject' AND entity_id = 'G1')
    = ARRAY['cohort:a', 'topic:hearing'],
    'entity_tags aggregates the current tags in order');

-- Filters: all / any / none, wildcards, bare tags, case-insensitive input.
SELECT pg_temp.assert(
    lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1',
                     ARRAY['stage:preprocessed', 'Visual_Cortex'])
    AND lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1', ARRAY['stage:*'])
    AND NOT lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1', ARRAY['stage:raw'])
    AND lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1',
                         NULL, ARRAY['qc:fail', 'stage:preprocessed'])
    AND NOT lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1',
                             NULL, ARRAY['qc:fail', 'stage:raw'])
    AND NOT lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1',
                             NULL, NULL, ARRAY['tag:*'])
    AND lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1', '{}', '{}', '{}')
    AND lab.fn_tag_match('subject', 'G2', NULL, NULL, ARRAY['cohort:*']),
    'fn_tag_match semantics');
SELECT pg_temp.assert(
    (SELECT string_agg(entity_id, ',') FROM lab.fn_find_by_tags('subject', ARRAY['cohort:*'])) = 'G1'
    AND NOT EXISTS (SELECT 1 FROM lab.fn_find_by_tags('subject', ARRAY['cohort:*'], NULL, ARRAY['topic:hearing'])),
    'fn_find_by_tags');

-- Namespace policy is frozen once in use; applies_to may only grow.
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag_namespace SET mutability = 'mutable' WHERE namespace = 'cohort'$q$,
    'is frozen');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag_namespace SET applies_to = ARRAY['subject'] WHERE namespace = 'cohort'$q$,
    'is frozen');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag_namespace SET cardinality = 'single' WHERE namespace = 'tag'$q$,
    'is frozen');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag_namespace SET namespace = 'cohorts' WHERE namespace = 'cohort'$q$,
    'cannot be renamed');
UPDATE lab.tag_namespace
SET description = 'edited', applies_to = applies_to || ARRAY['event']
WHERE namespace = 'cohort';
UPDATE lab.tag_namespace SET mutability = 'mutable' WHERE namespace = 'region';   -- unused: allowed
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag SET value = 'gerbils' WHERE tag = 'topic:gerbil'$q$,
    'cannot be renamed');
UPDATE lab.tag SET retired_at = now() WHERE tag = 'topic:gerbil';
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('event', '00000000-0000-0000-0000-0000000000e1', 'topic:gerbil')$q$,
    'was retired');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.row_history WHERE table_name = 'tag_namespace') = 2
    AND (SELECT count(*) FROM lab.row_history WHERE table_name = 'tag') = 1,
    'edits to the tag vocabulary are recorded in row_history');

-- ---------------------------------------------------------------------------
-- fn_rename_subject still works end to end, and is recorded
-- ---------------------------------------------------------------------------
SELECT lab.fn_rename_subject('G1', 'G1-renamed');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.event WHERE subject_id = 'G1')
    AND NOT EXISTS (SELECT 1 FROM lab.artifact WHERE subject_id = 'G1')
    AND NOT EXISTS (SELECT 1 FROM lab.session WHERE subject_id = 'G1')
    AND (SELECT count(*) FROM lab.event WHERE subject_id = 'G1-renamed') = 2
    AND (SELECT count(*) FROM lab.artifact WHERE subject_id = 'G1-renamed') = 3
    AND NOT EXISTS (SELECT 1 FROM lab.tag_assignment WHERE subject_id = 'G1')
    AND (SELECT count(*) FROM lab.tag_assignment WHERE subject_id = 'G1-renamed') = 4
    AND (SELECT tags FROM lab.entity_tags WHERE entity_kind = 'subject' AND entity_id = 'G1-renamed')
        = ARRAY['cohort:a', 'topic:hearing'],
    'rename cascades to session, event, artifact and tag_assignment');
SELECT pg_temp.assert(
    current_setting('lab.maintenance', true) = ''
    AND current_setting('lab.rename_from', true) = ''
    AND current_setting('lab.rename_to', true) = '',
    'rename flags are cleared afterwards');
SELECT pg_temp.assert(
    (SELECT details FROM lab.maintenance_log WHERE operation = 'subject_rename')
    = '{"from": "G1", "to": "G1-renamed"}'::jsonb,
    'rename recorded in maintenance_log');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.row_history
      WHERE table_name IN ('subject', 'session')
        AND new_row ->> 'subject_id' = 'G1-renamed') = 2,
    'rename recorded in row_history for subject and session');

-- ---------------------------------------------------------------------------
-- Append-only tables reject UPDATE, DELETE and TRUNCATE (findings 5, 6)
-- ---------------------------------------------------------------------------
-- Placed after the fixtures above so every table listed holds rows: a
-- row-level trigger cannot fire on an empty table.
INSERT INTO lab.artifact_verification (artifact_id, status, observed_checksum)
VALUES ('00000000-0000-0000-0000-0000000000f1', 'mismatch', repeat('cd', 32));
INSERT INTO lab.maintenance_log (operation) VALUES ('test');

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'event','recording_event','artifact','event_input','tag_assignment',
        'artifact_verification','maintenance_log','row_history','schema_version'
    ] LOOP
        PERFORM pg_temp.expect_error(format('DELETE FROM lab.%I', t), 'not allowed');
        PERFORM pg_temp.expect_error(format('TRUNCATE lab.%I CASCADE', t), 'not allowed');
    END LOOP;
    -- UPDATE needs a column that exists; any row-touching UPDATE will do.
    PERFORM pg_temp.expect_error('UPDATE lab.event SET notes = ''x''', 'not allowed');
    PERFORM pg_temp.expect_error('UPDATE lab.recording_event SET n_channels = 1', 'not allowed');
    PERFORM pg_temp.expect_error('UPDATE lab.artifact SET format = ''x''', 'not allowed');
    PERFORM pg_temp.expect_error('UPDATE lab.artifact_verification SET status = ''ok''', 'append-only log');
    PERFORM pg_temp.expect_error('UPDATE lab.maintenance_log SET operation = ''x''', 'append-only log');
    PERFORM pg_temp.expect_error('UPDATE lab.schema_version SET description = ''x''', 'append-only log');
    PERFORM pg_temp.expect_error('UPDATE lab.tag_assignment SET note = ''x''', 'append-only log');
END;
$$;

-- ---------------------------------------------------------------------------
-- Integrity report on the fixture data
-- ---------------------------------------------------------------------------
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity()
                WHERE check_name IN ('event_missing_detail', 'event_missing_subject',
                                     'artifact_producer_superseded', 'duplicate_active_path')),
    'no structural integrity errors in the fixture');

-- e1 carries qc:pass and is superseded by e7, which does not: reported until
-- the tag is carried forward (CarasLabDB.supersedeEvent does this itself).
-- Likewise f1 (two tags) is superseded by f7, which has none.
SELECT pg_temp.assert(
    (SELECT string_agg(subject, ',' ORDER BY subject)
     FROM lab.fn_check_integrity() WHERE check_name = 'tag_not_carried_forward')
    = '00000000-0000-0000-0000-0000000000e7,'
      '00000000-0000-0000-0000-0000000000f7,00000000-0000-0000-0000-0000000000f7',
    'integrity check reports the tags e7 and f7 did not inherit');
SELECT pg_temp.assert(lab.fn_tag('event', '00000000-0000-0000-0000-0000000000e7', 'qc:pass', 'add',
                  'carried forward from 00000000-0000-0000-0000-0000000000e1') IS NOT NULL,
                      'write: lab.fn_tag(''event'', ''00000000-0000-0000-0000-0000000000e7');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity()
                WHERE check_name = 'tag_not_carried_forward'
                  AND subject = '00000000-0000-0000-0000-0000000000e7'),
    'no lost event tags after carrying forward');

ROLLBACK;
\echo 'schema_test.sql: all assertions passed'
