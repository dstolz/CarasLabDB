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
-- Tags: syntax, vocabulary policy, assignment log, filters
-- ---------------------------------------------------------------------------
-- Fixture namespaces beside the seeded ones: an open multi-valued one and a
-- closed single-valued one.
INSERT INTO lab.tag_namespace (namespace, mutability, cardinality, open_vocabulary, applies_to)
VALUES ('tst_open',   'mutable', 'multi',  true,  ARRAY['subject','event']),
       ('tst_closed', 'mutable', 'single', false, ARRAY['artifact']);

-- Canonical spelling: only case and surrounding whitespace change, and a bare
-- tag lands in the reserved 'tag' namespace.
SELECT pg_temp.assert(lab.fn_canonical_tag(' Stage:Raw ') = 'stage:raw',
                      'fn_canonical_tag lower-cases and trims');
SELECT pg_temp.assert(lab.fn_canonical_tag('Auditory_Cortex') = 'tag:auditory_cortex',
                      'fn_canonical_tag puts a bare tag in the tag namespace');
SELECT pg_temp.assert(lab.fn_canonical_tag('a b:c d') = 'a b:c d',
                      'fn_canonical_tag rewrites nothing else');
INSERT INTO lab.tag (tag) VALUES (' Tst_Closed:Alpha ');
INSERT INTO lab.tag (namespace, value) VALUES ('tst_closed', 'Beta');
SELECT pg_temp.assert(
    (SELECT string_agg(tag || '|' || namespace || '|' || value, ',' ORDER BY tag)
     FROM lab.tag WHERE namespace = 'tst_closed')
    = 'tst_closed:alpha|tst_closed|alpha,tst_closed:beta|tst_closed|beta',
    'lab.tag fills namespace/value from the tag, or the tag from them, canonically');
SELECT pg_temp.assert(
    lab.fn_register_tag('Auditory_Cortex') = 'tag:auditory_cortex'
    AND lab.fn_register_tag(' tag:auditory_cortex') = 'tag:auditory_cortex',
    'fn_register_tag returns the canonical tag for both spellings');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.tag WHERE value = 'auditory_cortex') = 1,
    'bare and prefixed spellings of a tag are one row');

-- Malformed tags are rejected, never rewritten.
SELECT pg_temp.expect_error($q$SELECT lab.fn_register_tag('topic:raw data')$q$, 'tag_value_ck');
SELECT pg_temp.expect_error($q$SELECT lab.fn_register_tag('topic:bad!')$q$, 'tag_value_ck');
SELECT pg_temp.expect_error($q$SELECT lab.fn_register_tag('topic:')$q$, 'tag_value_ck');
SELECT pg_temp.expect_error($q$SELECT lab.fn_register_tag('topic:a:b')$q$, 'tag_value_ck');
SELECT pg_temp.expect_error($q$SELECT lab.fn_register_tag('  ')$q$, 'tag_value_ck');
SELECT pg_temp.expect_error($q$INSERT INTO lab.tag (tag) VALUES ('topic:-x')$q$, 'tag_value_ck');
SELECT pg_temp.expect_error($q$SELECT lab.fn_register_tag('nosuch:x')$q$,
                            'namespace nosuch does not exist');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.tag_namespace (namespace, mutability, cardinality, applies_to)
       VALUES ('Bad Name', 'mutable', 'multi', ARRAY['event'])$q$,
    'tag_namespace_name_ck');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.tag_namespace (namespace, mutability, cardinality, applies_to)
       VALUES ('badkind', 'mutable', 'multi', ARRAY['event','animal'])$q$,
    'tag_namespace_applies_to_ck');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.tag_namespace (namespace, mutability, cardinality, applies_to)
       VALUES ('nokind', 'mutable', 'multi', '{}')$q$,
    'tag_namespace_applies_to_ck');

-- A closed namespace refuses to auto-register a value, but a deliberate
-- INSERT INTO lab.tag works.
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('event', '00000000-0000-0000-0000-0000000000e1', 'qc:maybe')$q$,
    'closed vocabulary \(its values: fail, pass, pending\)');
INSERT INTO lab.tag (tag, description) VALUES ('qc:maybe', 'Deliberately registered');
SELECT lab.fn_tag('event', '00000000-0000-0000-0000-0000000000e1', 'qc:maybe');

-- Tags on e1, f1 and G1. fn_tag auto-registers open-namespace values.
SELECT lab.fn_tag('event', '00000000-0000-0000-0000-0000000000e1', 'Topic:Spikes',
                  p_by => '00000000-0000-0000-0000-0000000000a1');
SELECT lab.fn_tag('artifact', '00000000-0000-0000-0000-0000000000f1', ' Stage:Raw ');
SELECT lab.fn_tag('artifact', '00000000-0000-0000-0000-0000000000F1', 'auditory_cortex');
SELECT lab.fn_tag('subject', 'G1', 'cohort:a');
SELECT lab.fn_tag('subject', 'G1', 'tst_open:x');
SELECT pg_temp.assert(
    (SELECT created_by FROM lab.tag WHERE tag = 'topic:spikes') = '00000000-0000-0000-0000-0000000000a1'
    AND (SELECT applied_by FROM lab.tag_current WHERE tag = 'topic:spikes')
        = '00000000-0000-0000-0000-0000000000a1',
    'fn_tag records p_by on the new tag and on the assignment');

-- Policy violations, whether through fn_tag or a raw INSERT.
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('subject', 'G1', 'stage:raw')$q$,
    'tags of namespace stage apply to artifact only, not to subject');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('subject', 'G1', 'cohort:a', 'remove')$q$,
    'immutable: cohort:a cannot be removed');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('subject', 'G1', 'cohort:b')$q$,
    'already has cohort:a, and namespace cohort is immutable and single-valued');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('subject', 'G1', 'cohort:a')$q$,
    'already has tag cohort:a');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('subject', 'G2', 'tst_open:x', 'remove')$q$,
    'does not currently have tag tst_open:x');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.tag_assignment (entity_kind, subject_id, tag, op)
       VALUES ('subject', 'G2', 'tst_open:never', 'add')$q$,
    'tag tst_open:never is not registered');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.tag_assignment (entity_kind, event_id, tag, op)
       VALUES ('subject', '00000000-0000-0000-0000-0000000000e1', 'tst_open:x', 'add')$q$,
    'tag_assignment_entity_ck');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('animal', 'G1', 'topic:x')$q$, 'entity kind must be');
-- A second value in a single-valued namespace, inserted directly, is
-- rejected with a HINT pointing at fn_tag.
DO $$
DECLARE v_msg text; v_hint text;
BEGIN
    BEGIN
        INSERT INTO lab.tag_assignment (entity_kind, artifact_id, tag, op)
        VALUES ('artifact', '00000000-0000-0000-0000-0000000000f1', 'stage:sorted', 'add');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_hint = PG_EXCEPTION_HINT;
    END;
    PERFORM pg_temp.assert(v_msg ~ 'already has stage:raw, and namespace stage allows one current tag'
                           AND v_hint ~ 'lab\.fn_tag',
                           'single-valued direct insert rejected with a fn_tag HINT');
END;
$$;

-- fn_tag replaces the current value of a mutable single-valued namespace:
-- two log rows from one call, one current tag.
SELECT lab.fn_tag('artifact', '00000000-0000-0000-0000-0000000000f1', 'stage:preprocessed');
SELECT pg_temp.assert(
    (SELECT string_agg(tag || ' ' || op, ',' ORDER BY assignment_id) FROM lab.tag_assignment
      WHERE artifact_id = '00000000-0000-0000-0000-0000000000f1' AND tag LIKE 'stage:%')
    = 'stage:raw add,stage:raw remove,stage:preprocessed add'
    AND (SELECT note FROM lab.tag_assignment
          WHERE artifact_id = '00000000-0000-0000-0000-0000000000f1' AND op = 'remove')
        = 'replaced by stage:preprocessed'
    AND (SELECT string_agg(tag, ',') FROM lab.tag_current
          WHERE artifact_id = '00000000-0000-0000-0000-0000000000f1' AND namespace = 'stage')
        = 'stage:preprocessed',
    'fn_tag replace writes remove + add and leaves one current stage tag');
SELECT pg_temp.assert(
    (SELECT tags::text || ' ' || display_tags::text FROM lab.entity_tags
      WHERE entity_kind = 'artifact' AND entity_id = '00000000-0000-0000-0000-0000000000f1')
    = '{stage:preprocessed,tag:auditory_cortex} {stage:preprocessed,auditory_cortex}',
    'entity_tags lists sorted tags and their display forms (bare tags bare)');

-- Retired tags cannot be assigned; tags and namespaces are never renamed.
UPDATE lab.tag SET retired_at = now(), description = 'old' WHERE tag = 'tst_closed:beta';
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('artifact', '00000000-0000-0000-0000-0000000000f2', 'tst_closed:beta')$q$,
    'tst_closed:beta was retired');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag SET value = 'gamma', tag = 'tst_closed:gamma' WHERE tag = 'tst_closed:alpha'$q$,
    'cannot be renamed');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag_namespace SET namespace = 'tst_renamed' WHERE namespace = 'tst_closed'$q$,
    'cannot be renamed');

-- Policy is editable while a namespace is unused and frozen once it is used;
-- the reserved 'tag' namespace is frozen from the start.
UPDATE lab.tag_namespace SET cardinality = 'multi', applies_to = ARRAY['artifact','event']
WHERE namespace = 'tst_closed';
UPDATE lab.tag_namespace SET cardinality = 'single', applies_to = ARRAY['artifact']
WHERE namespace = 'tst_closed';
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag_namespace SET mutability = 'immutable' WHERE namespace = 'tst_open'$q$,
    'tst_open is in use, so its policy is frozen');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag_namespace SET cardinality = 'single' WHERE namespace = 'tst_open'$q$,
    'policy is frozen');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag_namespace SET applies_to = ARRAY['subject'] WHERE namespace = 'tst_open'$q$,
    'policy is frozen');
UPDATE lab.tag_namespace
SET applies_to = ARRAY['subject','event','session'], open_vocabulary = false, description = 'edited'
WHERE namespace = 'tst_open';
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag_namespace SET open_vocabulary = false WHERE namespace = 'tag'$q$,
    'reserved for bare tags');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.tag_namespace SET cardinality = 'single' WHERE namespace = 'tag'$q$,
    'reserved for bare tags');
UPDATE lab.tag_namespace SET description = 'Bare tags (edited)' WHERE namespace = 'tag';
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.row_history WHERE table_name = 'tag_namespace') = 4
    AND (SELECT count(*) FROM lab.row_history WHERE table_name = 'tag') = 1
    AND (SELECT row_key FROM lab.row_history WHERE table_name = 'tag')
        = '{"tag": "tst_closed:beta"}'::jsonb,
    'vocabulary edits are recorded in row_history');

-- Filters: all / any / none, wildcards, bare tokens, NULL and empty lists.
SELECT lab.fn_tag('event', '00000000-0000-0000-0000-0000000000e2', 'topic:spikes');
SELECT pg_temp.assert(
        lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1',
                         ARRAY['stage:preprocessed', ' Auditory_Cortex'], NULL, NULL)
    AND lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000F1',
                         ARRAY['tag:auditory_cortex'], NULL, NULL)
    AND NOT lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1',
                             ARRAY['stage:preprocessed', 'stage:raw'], NULL, NULL)
    AND lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1',
                         NULL, ARRAY['stage:raw', 'auditory_cortex'], NULL)
    AND NOT lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1',
                             NULL, ARRAY['stage:raw', 'qc:*'], NULL)
    AND NOT lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1',
                             NULL, NULL, ARRAY['stage:*'])
    AND lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1',
                         ARRAY['stage:*', '*'], NULL, ARRAY['qc:*'])
    AND lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1', NULL, NULL, NULL)
    AND lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1', '{}', '{}', '{}')
    AND lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f1',
                         ARRAY['', NULL], ARRAY[' '], NULL)
    AND lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f2')
    AND NOT lab.fn_tag_match('artifact', '00000000-0000-0000-0000-0000000000f2',
                             ARRAY['stage:*'], NULL, NULL),
    'fn_tag_match all/any/none semantics');
SELECT pg_temp.assert(
    (SELECT array_agg(entity_id) FROM lab.fn_find_by_tags('event', ARRAY['qc:*']))
        = ARRAY['00000000-0000-0000-0000-0000000000e1']
    AND (SELECT array_agg(entity_id)
         FROM lab.fn_find_by_tags('event', ARRAY['topic:spikes'], NULL, ARRAY['qc:maybe']))
        = ARRAY['00000000-0000-0000-0000-0000000000e2']
    AND (SELECT array_agg(entity_id) FROM lab.fn_find_by_tags('event', NULL, NULL, ARRAY['qc:*']))
        = ARRAY['00000000-0000-0000-0000-0000000000e2']
    AND (SELECT array_agg(entity_id) FROM lab.fn_find_by_tags('subject', NULL, ARRAY['cohort:a']))
        = ARRAY['G1']
    AND (SELECT count(*) FROM lab.fn_find_by_tags('subject')) = 2,
    'fn_find_by_tags returns the matching entities, untagged ones included');
SELECT pg_temp.expect_error($q$SELECT * FROM lab.fn_find_by_tags('animal')$q$,
                            'entity kind must be');

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

-- e1's current tags were not copied onto e7.
SELECT pg_temp.assert(
    (SELECT detail FROM lab.fn_check_integrity()
      WHERE check_name = 'tag_not_carried_forward'
        AND subject = '00000000-0000-0000-0000-0000000000e7')
    = 'supersedes event 00000000-0000-0000-0000-0000000000e1, whose current tags were '
      'not carried forward: qc:maybe, topic:spikes',
    'integrity check reports tags not carried forward to e7');
-- Carry them forward the way a client does, then change them on purpose: a
-- tag later removed, or a single-valued namespace given another value, still
-- counts as carried.
INSERT INTO lab.tag_assignment (entity_kind, event_id, tag, op, note)
SELECT 'event', '00000000-0000-0000-0000-0000000000e7', tag, 'add',
       'carried forward from 00000000-0000-0000-0000-0000000000e1'
FROM lab.tag_current
WHERE entity_kind = 'event' AND entity_id = '00000000-0000-0000-0000-0000000000e1';
SELECT lab.fn_tag('event', '00000000-0000-0000-0000-0000000000e7', 'qc:pass');
SELECT lab.fn_tag('event', '00000000-0000-0000-0000-0000000000e7', 'topic:spikes', 'remove');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity()
                WHERE check_name = 'tag_not_carried_forward'
                  AND subject = '00000000-0000-0000-0000-0000000000e7')
    AND (SELECT tags FROM lab.entity_tags
          WHERE entity_kind = 'event' AND entity_id = '00000000-0000-0000-0000-0000000000e7')
        = ARRAY['qc:pass'],
    'carried-forward tags clear the check, and later changes do not re-raise it');

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
    EXISTS (SELECT 1 FROM lab.fn_check_integrity()
            WHERE check_name = 'tag_not_carried_forward'
              AND subject = '00000000-0000-0000-0000-0000000000f7'),
    'integrity check reports f1''s tags missing from f7');
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
-- fn_rename_subject still works end to end, and is recorded
-- ---------------------------------------------------------------------------
SELECT lab.fn_rename_subject('G1', 'G1-renamed');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.event WHERE subject_id = 'G1')
    AND NOT EXISTS (SELECT 1 FROM lab.artifact WHERE subject_id = 'G1')
    AND NOT EXISTS (SELECT 1 FROM lab.session WHERE subject_id = 'G1')
    AND (SELECT count(*) FROM lab.event WHERE subject_id = 'G1-renamed') = 2
    AND (SELECT count(*) FROM lab.artifact WHERE subject_id = 'G1-renamed') = 3,
    'rename cascades to session, event and artifact');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.tag_assignment WHERE subject_id = 'G1')
    AND (SELECT count(*) FROM lab.tag_assignment WHERE subject_id = 'G1-renamed') = 2
    AND (SELECT tags FROM lab.entity_tags
          WHERE entity_kind = 'subject' AND entity_id = 'G1-renamed')
        = ARRAY['cohort:a', 'tst_open:x'],
    'rename cascades into tag_assignment, and the tags follow the subject');
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
        'event','recording_event','artifact','event_input',
        'artifact_verification','maintenance_log','row_history','schema_version',
        'tag_assignment'
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
    PERFORM pg_temp.expect_error('UPDATE lab.tag_assignment SET op = ''remove''', 'append-only log');
END;
$$;

-- ---------------------------------------------------------------------------
-- Integrity report on the fixture data
-- ---------------------------------------------------------------------------
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity()
                WHERE check_name IN ('event_missing_detail', 'event_missing_subject',
                                     'artifact_producer_superseded', 'duplicate_active_path',
                                     'tag_not_carried_forward')),
    'no structural integrity errors in the fixture');

ROLLBACK;
\echo 'schema_test.sql: all assertions passed'
