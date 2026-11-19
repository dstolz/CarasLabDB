-- ============================================================================
-- Schema assertions for design_docs/schema.sql
-- ============================================================================
-- Run against a database that has just had schema.sql applied and holds no
-- other data:
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
SELECT pg_temp.assert((SELECT max(version) FROM lab.schema_version) = 1,
                      'schema_version is 1');

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
-- One row in each scan log (a directory that is 'off', one run of it with its
-- result, one file in the scan memory).
INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                scan_interval_min, mode)
VALUES ((SELECT root_id FROM lab.storage_root WHERE name = 'nas-test'),
        'append-only-fixture', 'epsych', 'UTC', 60, 'off');
INSERT INTO lab.scan_run (scan_directory_id, command, mode)
SELECT scan_directory_id, 'run', 'report' FROM lab.scan_directory;
INSERT INTO lab.scan_run_result (scan_run_id, outcome) SELECT scan_run_id, 'ok' FROM lab.scan_run;
INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns, status)
SELECT r.scan_run_id, d.storage_root_id, 'append-only-fixture/a.mat', 1, 1, 'pending'
FROM lab.scan_run r JOIN lab.scan_directory d USING (scan_directory_id);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'event','recording_event','artifact','event_input',
        'artifact_verification','maintenance_log','row_history','schema_version',
        'tag_assignment','scan_run','scan_run_result','scan_file'
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
    PERFORM pg_temp.expect_error('UPDATE lab.scan_run SET host = ''x''', 'append-only log');
    PERFORM pg_temp.expect_error('UPDATE lab.scan_run_result SET outcome = ''failed''', 'append-only log');
    PERFORM pg_temp.expect_error('UPDATE lab.scan_file SET status = ''cleared''', 'append-only log');
    -- The list of directories is not a log, but emptying it would take the
    -- logs that refer to it along.
    PERFORM pg_temp.expect_error('TRUNCATE lab.scan_directory CASCADE', 'not allowed');
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

-- ===========================================================================
-- Pre-launch schema version 4
-- ===========================================================================
-- Fixture at this point: recording e1 is superseded by e7; its raw file f1 by
-- f7 and then by an active row with role 'derived'; analysis e2 consumed f1
-- and produced f2; f1 carries one 'mismatch' verification; subject G1 has
-- been renamed G1-renamed.

-- ---------------------------------------------------------------------------
-- Correction chains
-- ---------------------------------------------------------------------------
SELECT pg_temp.assert(
    lab.fn_event_current('00000000-0000-0000-0000-0000000000e1') = '00000000-0000-0000-0000-0000000000e7'
    AND lab.fn_event_current('00000000-0000-0000-0000-0000000000e7') = '00000000-0000-0000-0000-0000000000e7'
    AND lab.fn_event_current(NULL) IS NULL,
    'fn_event_current follows the chain to its end');
SELECT pg_temp.assert(
    (SELECT array_agg(v) FROM lab.fn_event_versions('00000000-0000-0000-0000-0000000000e1') v)
    = ARRAY['00000000-0000-0000-0000-0000000000e7', '00000000-0000-0000-0000-0000000000e1']::uuid[],
    'fn_event_versions lists the chain, current version first');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.fn_artifact_versions('00000000-0000-0000-0000-0000000000f7')) = 3
    AND lab.fn_artifact_current('00000000-0000-0000-0000-0000000000f1')
        = (SELECT artifact_id FROM lab.artifact_active WHERE relative_path = 'G1/s1/raw.dat'),
    'fn_artifact_versions / fn_artifact_current cover a three-row chain');
SELECT pg_temp.assert(
    (SELECT superseded_by::text || '|' || is_current FROM lab.event_version
      WHERE event_id = '00000000-0000-0000-0000-0000000000e1')
    = '00000000-0000-0000-0000-0000000000e7|false'
    AND (SELECT superseded_by IS NULL AND is_current FROM lab.event_version
          WHERE event_id = '00000000-0000-0000-0000-0000000000e7')
    AND (SELECT count(*) FROM lab.artifact_version WHERE NOT is_current) = 2,
    'event_version / artifact_version mark superseded rows and name the successor');

-- ---------------------------------------------------------------------------
-- Lineage follows corrections
-- ---------------------------------------------------------------------------
-- e2's edge still names f1, the superseded raw file. As recorded, nothing is
-- derived from the current raw row; following corrections, f2 is.
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.fn_artifact_lineage(
        (SELECT artifact_id FROM lab.artifact_active WHERE relative_path = 'G1/s1/raw.dat'),
        'down', false)) = 1,
    'as recorded, the current raw artifact has no descendants');
SELECT pg_temp.assert(
    (SELECT string_agg(depth || ':' || coalesce(event_id::text, '-') || ':' || artifact_id, ' '
                       ORDER BY depth)
     FROM lab.fn_artifact_lineage('00000000-0000-0000-0000-0000000000f7', 'down'))
    = '0:-:' || (SELECT artifact_id FROM lab.artifact_active WHERE relative_path = 'G1/s1/raw.dat')
      || ' 1:00000000-0000-0000-0000-0000000000e2:00000000-0000-0000-0000-0000000000f2',
    'following corrections, lineage down from any version reaches f2 and starts at the current row');
SELECT pg_temp.assert(
    (SELECT event_id FROM lab.fn_artifact_lineage('00000000-0000-0000-0000-0000000000f2', 'up', false)
      WHERE depth = 1) = '00000000-0000-0000-0000-0000000000e1',
    'as recorded, lineage up from f2 ends at superseded e1');
SELECT pg_temp.assert(
    (SELECT event_id::text || '|' || artifact_id FROM lab.fn_artifact_lineage(
        '00000000-0000-0000-0000-0000000000f2', 'up') WHERE depth = 1)
    = '00000000-0000-0000-0000-0000000000e7|'
      || (SELECT artifact_id FROM lab.artifact_active WHERE relative_path = 'G1/s1/raw.dat'),
    'following corrections, lineage up from f2 names current e7 and the current raw row');
-- A correction must not close a loop in the resolved graph: e7 (the current
-- version of the recording) cannot consume f2, which derives from it.
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.event_input (event_id, artifact_id)
       VALUES ('00000000-0000-0000-0000-0000000000e7', '00000000-0000-0000-0000-0000000000f2')$q$,
    'cyclic');

-- ---------------------------------------------------------------------------
-- Verification belongs to the file, not to the artifact row
-- ---------------------------------------------------------------------------
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.artifact_verification_latest
      WHERE status = 'mismatch'
        AND verified_artifact_id = '00000000-0000-0000-0000-0000000000f1') = 3,
    'all three rows describing the raw file share its latest verification');
SELECT pg_temp.assert(
    (SELECT subject FROM lab.fn_check_integrity() WHERE check_name = 'artifact_verification_failed')
    = (SELECT artifact_id::text FROM lab.artifact_active WHERE relative_path = 'G1/s1/raw.dat')
    AND NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity() i
                    JOIN lab.artifact_active a ON a.artifact_id::text = i.subject
                    WHERE i.check_name = 'artifact_never_verified'
                      AND a.relative_path = 'G1/s1/raw.dat'),
    'a failed check survives the correction: reported on the active row, not as never verified');
INSERT INTO lab.artifact_verification (artifact_id, status, verified_at)
VALUES ('00000000-0000-0000-0000-0000000000f7', 'ok', now() + interval '1 second');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity()
                WHERE check_name = 'artifact_verification_failed'),
    'a later ok check of the same file, on any of its rows, clears the failure');

-- ---------------------------------------------------------------------------
-- The login is stamped by the database
-- ---------------------------------------------------------------------------
INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at, recorded_login)
VALUES ('00000000-0000-0000-0000-0000000000d1', 'husbandry', 'G2', now(), 'someone_else');
INSERT INTO lab.husbandry_event (event_id, measure, weight_g)
VALUES ('00000000-0000-0000-0000-0000000000d1', 'weight', 61.5);
INSERT INTO lab.tag_assignment (entity_kind, subject_id, tag, op, applied_login)
VALUES ('subject', 'G2', 'tst_open:x', 'add', 'someone_else');
SELECT pg_temp.assert(
    (SELECT recorded_login FROM lab.event WHERE event_id = '00000000-0000-0000-0000-0000000000d1')
    = session_user
    AND NOT EXISTS (SELECT 1 FROM lab.event WHERE recorded_login IS DISTINCT FROM session_user)
    AND NOT EXISTS (SELECT 1 FROM lab.artifact WHERE created_login IS DISTINCT FROM session_user)
    AND NOT EXISTS (SELECT 1 FROM lab.artifact_verification
                    WHERE verified_login IS DISTINCT FROM session_user)
    AND NOT EXISTS (SELECT 1 FROM lab.tag_assignment
                    WHERE applied_login IS DISTINCT FROM session_user)
    AND (SELECT applied_login FROM lab.tag_current
          WHERE entity_kind = 'subject' AND entity_id = 'G2' AND tag = 'tst_open:x') = session_user,
    'the *_login columns hold session_user whatever the client sends');

-- ---------------------------------------------------------------------------
-- An artifact is filed with the event that produced it
-- ---------------------------------------------------------------------------
INSERT INTO lab.session (session_id, subject_id, label, storage_root_id, relative_path)
VALUES ('00000000-0000-0000-0000-0000000000c3', 'G1-renamed', 's2',
        (SELECT root_id FROM lab.storage_root WHERE name = 'nas-test'), 'G1/s2');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, relative_path, checksum, subject_id)
       VALUES ('00000000-0000-0000-0000-0000000000e7', 1, 'G2/stray.dat', repeat('1a', 32), 'G2')$q$,
    'is filed under subject G2');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, relative_path, checksum, session_id)
       VALUES ('00000000-0000-0000-0000-0000000000e7', 1, 'G1/s2/stray.dat', repeat('1b', 32),
               '00000000-0000-0000-0000-0000000000c3')$q$,
    'is filed under session 00000000-0000-0000-0000-0000000000c3');
-- An analysis with no subject may produce a per-animal file.
INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, relative_path, checksum, subject_id)
VALUES ('00000000-0000-0000-0000-0000000000e2',
        (SELECT root_id FROM lab.storage_root WHERE name = 'nas-test'),
        'G2/summary.csv', repeat('1c', 32), 'G2');
-- Rows that predate the trigger are reported.
ALTER TABLE lab.artifact DISABLE TRIGGER trg_artifact_matches_event;
INSERT INTO lab.artifact (artifact_id, produced_by_event_id, storage_root_id, relative_path,
                          checksum, subject_id)
VALUES ('00000000-0000-0000-0000-0000000000fa', '00000000-0000-0000-0000-0000000000e7',
        (SELECT root_id FROM lab.storage_root WHERE name = 'nas-test'),
        'G2/legacy.dat', repeat('1d', 32), 'G2');
ALTER TABLE lab.artifact ENABLE TRIGGER trg_artifact_matches_event;
SELECT pg_temp.assert(
    (SELECT subject FROM lab.fn_check_integrity() WHERE check_name = 'artifact_event_mismatch')
    = '00000000-0000-0000-0000-0000000000fa',
    'integrity check reports an artifact filed under another subject than its event');

-- ---------------------------------------------------------------------------
-- The rename hatch does not fill in a NULL subject
-- ---------------------------------------------------------------------------
SELECT pg_temp.expect_error(
    $q$SELECT set_config('lab.maintenance', 'subject_rename', true);
       SELECT set_config('lab.rename_from', 'no-such-animal', true);
       SELECT set_config('lab.rename_to', 'G2', true);
       UPDATE lab.event SET subject_id = 'G2'
       WHERE event_id = '00000000-0000-0000-0000-0000000000e2'$q$,
    'admits only the subject-id relabelling');

-- ---------------------------------------------------------------------------
-- Current tags follow insertion order, not applied_at
-- ---------------------------------------------------------------------------
INSERT INTO lab.tag (tag) VALUES ('tst_open:future');
INSERT INTO lab.tag_assignment (entity_kind, subject_id, tag, op, applied_at)
VALUES ('subject', 'G2', 'tst_open:future', 'add', '2099-01-01');
SELECT lab.fn_tag('subject', 'G2', 'tst_open:future', 'remove');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.tag_current
                WHERE entity_kind = 'subject' AND entity_id = 'G2' AND tag = 'tst_open:future'),
    'a remove takes effect even when the add carries a later applied_at');

-- A single-valued namespace holding two current tags is reported.
ALTER TABLE lab.tag_assignment DISABLE TRIGGER trg_tag_assignment_policy;
INSERT INTO lab.tag_assignment (entity_kind, subject_id, tag, op)
VALUES ('subject', 'G2', 'cohort:a', 'add');
INSERT INTO lab.tag (tag) VALUES ('cohort:b');
INSERT INTO lab.tag_assignment (entity_kind, subject_id, tag, op)
VALUES ('subject', 'G2', 'cohort:b', 'add');
ALTER TABLE lab.tag_assignment ENABLE TRIGGER trg_tag_assignment_policy;
SELECT pg_temp.assert(
    (SELECT severity || '|' || subject || '|' || detail FROM lab.fn_check_integrity()
      WHERE check_name = 'tag_cardinality_violation')
    = 'error|G2|subject has 2 current tags in single-valued namespace cohort: cohort:a, cohort:b',
    'integrity check reports two current tags in a single-valued namespace');

-- ---------------------------------------------------------------------------
-- Tag filters are checked against the vocabulary
-- ---------------------------------------------------------------------------
SELECT pg_temp.assert(
    (SELECT string_agg(token || ' => ' || problem, '; ' ORDER BY token)
     FROM lab.fn_tag_filter_problems('artifact',
            ARRAY['qc:fial', ' Stage:Raw ', 'nosuch:*', 'cohort:a', ' ', NULL,
                  'Auditory_Cortex', 'qc:*', 'topic:never_used']))
    = 'cohort:a => tags of namespace cohort apply to subject, session only, not to artifact; '
      'nosuch:* => tag namespace nosuch does not exist; '
      'qc:fial => tag qc:fial is not registered (values of qc: fail, maybe, pass, pending); '
      'topic:never_used => tag topic:never_used is not registered, so nothing can carry it',
    'fn_tag_filter_problems names unknown namespaces, inapplicable namespaces and unregistered tags');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_tag_filter_problems('artifact',
                    ARRAY['stage:raw', 'stage:*', 'auditory_cortex', '']))
    AND NOT EXISTS (SELECT 1 FROM lab.fn_tag_filter_problems('subject', NULL)),
    'a sound filter, or none, has no problems');

-- ---------------------------------------------------------------------------
-- A correction that drops every input is reported
-- ---------------------------------------------------------------------------
INSERT INTO lab.event (event_id, event_type, occurred_at, supersedes)
VALUES ('00000000-0000-0000-0000-0000000000e8', 'analysis', '2026-09-02 10:00-04',
        '00000000-0000-0000-0000-0000000000e2');
INSERT INTO lab.analysis_event (event_id, status) VALUES
    ('00000000-0000-0000-0000-0000000000e8', 'succeeded');
SELECT pg_temp.assert(
    (SELECT detail FROM lab.fn_check_integrity()
      WHERE check_name = 'input_not_carried_forward'
        AND subject = '00000000-0000-0000-0000-0000000000e8')
    = 'supersedes event 00000000-0000-0000-0000-0000000000e2, which consumed 1 artifact(s), '
      'but declares no inputs',
    'integrity check reports a correction that declares no inputs');
-- Until e8 declares its inputs, e2's outputs hang off a consumer that is no
-- longer current, so nothing is derived from the raw file.
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.fn_artifact_lineage('00000000-0000-0000-0000-0000000000f1', 'down')) = 1,
    'a correction with no inputs is authoritative: the old edge no longer counts');
INSERT INTO lab.event_input (event_id, artifact_id)
VALUES ('00000000-0000-0000-0000-0000000000e8', '00000000-0000-0000-0000-0000000000f1');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity()
                WHERE check_name = 'input_not_carried_forward')
    AND (SELECT string_agg(event_id::text, ',' ORDER BY artifact_id)
         FROM lab.fn_artifact_lineage('00000000-0000-0000-0000-0000000000f1', 'down')
         WHERE depth = 1)
        = '00000000-0000-0000-0000-0000000000e8,00000000-0000-0000-0000-0000000000e8',
    'once the inputs are re-declared, lineage reaches e2''s files through current event e8');

-- ===========================================================================
-- Pre-launch schema version 5: user-defined variables, retraction, logins
-- ===========================================================================
-- Fixture at this point: subjects G1-renamed and G2; sessions c1 and c3
-- (G1-renamed) and c2 (G2); recording e7 is current (e1 superseded); analysis
-- e8 is current (e2 superseded) and consumed raw file f1, whose current row
-- is the active artifact at G1/s1/raw.dat; f2 (spikes) is active.

-- ---------------------------------------------------------------------------
-- Variables: define on first use, update by setting again, read the latest
-- ---------------------------------------------------------------------------
SELECT pg_temp.assert(lab.fn_canonical_variable(E' Probe \t Depth\n') = 'probe depth',
                      'fn_canonical_variable folds case and whitespace');
SELECT lab.fn_set_variable('session', '00000000-0000-0000-0000-0000000000c1', ' Probe  Depth ', 1200,
                           p_units => 'um', p_label => 'Probe Depth',
                           p_description => 'Depth of the probe tip below the pia',
                           p_by => '00000000-0000-0000-0000-0000000000a1');
SELECT pg_temp.assert(
    (SELECT label || '|' || units || '|' || value_type || '|' || description || '|' || created_by
     FROM lab.variable WHERE name = 'probe depth')
    = 'Probe Depth|um|number|Depth of the probe tip below the pia|00000000-0000-0000-0000-0000000000a1',
    'a variable is defined on first use, with its label, units, type and description');
-- An update is a second row; the first stays in the log.
SELECT lab.fn_set_variable('session', '00000000-0000-0000-0000-0000000000c1', 'probe depth', 1350.50,
                           p_note => 'advanced 150 um');
SELECT pg_temp.assert(
    (SELECT value || '|' || units || '|' || label || '|' || note FROM lab.variable_current
      WHERE entity_kind = 'session' AND variable = 'probe depth')
    = '1350.50|um|Probe Depth|advanced 150 um'
    AND (SELECT string_agg(value_num::text, ',' ORDER BY value_id) FROM lab.variable_value
          WHERE variable = 'probe depth') = '1200,1350.50'
    AND lab.fn_variable_number('session', '00000000-0000-0000-0000-0000000000C1', 'Probe Depth') = 1350.50,
    'setting a variable again updates it: the latest value is current, the history is kept, '
    'and the digits typed are the digits stored');
SELECT pg_temp.assert(
    (SELECT set_login = session_user AND set_at IS NOT NULL FROM lab.variable_current
      WHERE entity_kind = 'session' AND variable = 'probe depth'),
    'a value records when it was set and the login that set it');

-- A text variable, and all of an entity's variables as one object.
SELECT lab.fn_set_variable('subject', 'G2', 'housing', p_text => 'pair');
SELECT lab.fn_set_variable('subject', 'G2', 'baseline weight', 71.9, p_units => 'g');
SELECT pg_temp.assert(
    lab.fn_variable_text('subject', 'G2', 'housing') = 'pair'
    AND lab.fn_variable_number('subject', 'G2', 'housing') IS NULL
    AND lab.fn_variable_text('subject', 'G2', 'baseline weight') = '71.9'
    AND lab.fn_variable_number('subject', 'G2', 'no such variable') IS NULL
    AND (SELECT variables FROM lab.entity_variables
          WHERE entity_kind = 'subject' AND entity_id = 'G2')
        = '{"housing": "pair", "baseline weight": 71.9}'::jsonb,
    'text and number variables read back through the helper functions and entity_variables');

-- What is refused.
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('session', '00000000-0000-0000-0000-0000000000c1', 'probe depth', 1.35, p_units => 'mm')$q$,
    'is recorded in um, not in mm');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('session', '00000000-0000-0000-0000-0000000000c1', 'probe depth', p_text => 'deep')$q$,
    'holds a number');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('subject', 'G2', 'housing', 2)$q$, 'holds text');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('subject', 'G2', 'housing')$q$, 'exactly one value');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('subject', 'G2', 'housing', 1, 'pair')$q$, 'exactly one value');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('subject', 'G2', 'Bad!Name', 1)$q$, 'not a valid variable name');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('animal', 'G2', 'housing', p_text => 'x')$q$, 'entity kind must be');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('subject', 'G2', 'baseline weight', 'NaN'::numeric)$q$,
    'variable_value_number_ck');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('subject', 'G2', 'housing', p_text => '   ')$q$,
    'variable_value_text_ck');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.variable_value (entity_kind, subject_id, variable, value_num)
       VALUES ('subject', 'G2', 'never defined', 1)$q$, 'is not defined');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.variable_value (entity_kind, subject_id, variable, value_num, value_text)
       VALUES ('subject', 'G2', 'housing', 1, 'pair')$q$, 'variable_value_single_ck');
SELECT lab.fn_define_variable('litter size', 'number', NULL, 'Litter size', NULL, ARRAY['subject']);
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('session', '00000000-0000-0000-0000-0000000000c1', 'litter size', 5)$q$,
    'applies to subject only, not to session');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_define_variable('probe depth', 'number', 'mm')$q$, 'already defined as a number in um');
SELECT pg_temp.assert(lab.fn_define_variable(' PROBE depth ', 'number', 'um') = 'probe depth',
                      'defining an existing variable the same way is not an error');

-- Unset: the entity then has no current value; a second unset has nothing to do.
SELECT lab.fn_unset_variable('subject', 'G2', 'Housing', 'entered on the wrong animal');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.variable_current
                WHERE entity_kind = 'subject' AND entity_id = 'G2' AND variable = 'housing')
    AND (SELECT string_agg(op, ',' ORDER BY value_id) FROM lab.variable_value
          WHERE variable = 'housing') = 'set,unset',
    'an unset variable has no current value and its history is kept');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_unset_variable('subject', 'G2', 'housing')$q$, 'nothing to unset');

-- The definition: never renamed; units and type frozen once it has a value;
-- label and description editable and recorded.
SELECT pg_temp.expect_error(
    $q$UPDATE lab.variable SET name = 'depth' WHERE name = 'probe depth'$q$, 'cannot be renamed');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.variable SET units = 'mm' WHERE name = 'probe depth'$q$, 'units are frozen');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.variable SET value_type = 'text' WHERE name = 'probe depth'$q$, 'units are frozen');
UPDATE lab.variable SET units = 'pups' WHERE name = 'litter size';     -- no values yet: allowed
UPDATE lab.variable SET label = 'Probe depth (tip)' WHERE name = 'probe depth';
SELECT pg_temp.assert(
    (SELECT old_row ->> 'label' || '>' || (new_row ->> 'label') FROM lab.row_history
      WHERE table_name = 'variable' AND row_key ->> 'name' = 'probe depth')
    = 'Probe Depth>Probe depth (tip)'
    AND (SELECT label FROM lab.variable_current WHERE variable = 'probe depth') = 'Probe depth (tip)',
    'a definition edit is recorded in row_history and shows on the current value');
UPDATE lab.variable SET retired_at = now() WHERE name = 'litter size';
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('subject', 'G2', 'litter size', 5)$q$, 'was retired');

-- The value log is append-only.
SELECT pg_temp.expect_error($q$UPDATE lab.variable_value SET value_num = 1$q$, 'append-only log');
SELECT pg_temp.expect_error($q$DELETE FROM lab.variable_value$q$, 'not allowed');
SELECT pg_temp.expect_error($q$TRUNCATE lab.variable_value$q$, 'not allowed');

-- A correction starts with its predecessor's variables, each keeping the time
-- and person it was set by.
SELECT lab.fn_set_variable('event', '00000000-0000-0000-0000-0000000000e7', 'attenuation', 20,
                           p_units => 'dB', p_by => '00000000-0000-0000-0000-0000000000a1');
INSERT INTO lab.event (event_id, event_type, session_id, occurred_at, supersedes)
VALUES ('00000000-0000-0000-0000-0000000000e9', 'recording',
        '00000000-0000-0000-0000-0000000000c1', '2026-09-01 14:00-04',
        '00000000-0000-0000-0000-0000000000e7');
INSERT INTO lab.recording_event (event_id, sample_rate_hz, n_channels)
VALUES ('00000000-0000-0000-0000-0000000000e9', 30000, 32);
SELECT pg_temp.assert(
    (SELECT n.value || '|' || n.note || '|' || (n.set_at = o.set_at) || '|' || n.set_by
     FROM lab.variable_current n, lab.variable_current o
     WHERE n.entity_kind = 'event' AND n.entity_id = '00000000-0000-0000-0000-0000000000e9'
       AND o.entity_kind = 'event' AND o.entity_id = '00000000-0000-0000-0000-0000000000e7'
       AND n.variable = 'attenuation' AND o.variable = 'attenuation')
    = '20|carried forward from 00000000-0000-0000-0000-0000000000e7|true|'
      '00000000-0000-0000-0000-0000000000a1',
    'a superseding event carries its predecessor''s variables, with their set_at and set_by');

-- Variables follow a renamed subject (the cascade passes the rename hatch).
SELECT lab.fn_rename_subject('G2', 'G2-renamed');
SELECT pg_temp.assert(
    lab.fn_variable_number('subject', 'G2-renamed', 'baseline weight') = 71.9
    AND NOT EXISTS (SELECT 1 FROM lab.variable_value WHERE subject_id = 'G2'),
    'variables follow a renamed subject');

-- ---------------------------------------------------------------------------
-- Retraction
-- ---------------------------------------------------------------------------
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_retract('event', '00000000-0000-0000-0000-0000000000e7', 'entered twice')$q$,
    'has been superseded by 00000000-0000-0000-0000-0000000000e9');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_retract('event', '00000000-0000-0000-0000-0000000000e9', '  ')$q$,
    'retraction_reason_ck');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_retract('subject', '00000000-0000-0000-0000-0000000000e9', 'x')$q$,
    'only an event or an artifact');

-- Two more weights for one animal, dated after every other event in the
-- fixture; the later one is retracted.
INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at) VALUES
    ('00000000-0000-0000-0000-0000000000d2', 'husbandry', 'G2-renamed', '2098-01-01 09:00-04'),
    ('00000000-0000-0000-0000-0000000000d3', 'husbandry', 'G2-renamed', '2099-01-01 09:00-04');
INSERT INTO lab.husbandry_event (event_id, measure, weight_g) VALUES
    ('00000000-0000-0000-0000-0000000000d2', 'weight', 70.2),
    ('00000000-0000-0000-0000-0000000000d3', 'weight', 702);
SELECT pg_temp.assert(
    (SELECT latest_weight_g FROM lab.subject_current WHERE subject_id = 'G2-renamed') = 702,
    'before retraction the mistyped weight is the latest');
SELECT lab.fn_tag('event', '00000000-0000-0000-0000-0000000000d3', 'topic:retract_me');
SELECT lab.fn_retract('event', '00000000-0000-0000-0000-0000000000d3', 'weight mistyped: 702 for 70.2',
                      '00000000-0000-0000-0000-0000000000a1');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.event_active WHERE event_id = '00000000-0000-0000-0000-0000000000d3')
    AND EXISTS (SELECT 1 FROM lab.event WHERE event_id = '00000000-0000-0000-0000-0000000000d3')
    AND (SELECT is_retracted AND NOT is_current AND superseded_by IS NULL FROM lab.event_version
          WHERE event_id = '00000000-0000-0000-0000-0000000000d3')
    AND (SELECT latest_weight_g FROM lab.subject_current WHERE subject_id = 'G2-renamed') = 70.2
    AND NOT EXISTS (SELECT 1 FROM lab.fn_find_by_tags('event', ARRAY['topic:retract_me']))
    AND EXISTS (SELECT 1 FROM lab.fn_find_by_tags('event', ARRAY['topic:retract_me'], NULL, NULL, false)),
    'a retracted event stays in the log but is not active: views, subject_current and tag '
    'search leave it out');
SELECT pg_temp.assert(
    (SELECT reason || '|' || retracted_by || '|' || (retracted_login = session_user)
     FROM lab.retraction WHERE event_id = '00000000-0000-0000-0000-0000000000d3')
    = 'weight mistyped: 702 for 70.2|00000000-0000-0000-0000-0000000000a1|true',
    'a retraction records why, who and the login');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_retract('event', '00000000-0000-0000-0000-0000000000d3', 'again')$q$,
    'already retracted');
SELECT pg_temp.expect_error($q$DELETE FROM lab.retraction$q$, 'not allowed');
SELECT pg_temp.expect_error($q$UPDATE lab.retraction SET reason = 'x'$q$, 'append-only log');

-- Superseding a retracted row brings it back as an ordinary correction.
INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at, supersedes)
VALUES ('00000000-0000-0000-0000-0000000000d4', 'husbandry', 'G2-renamed', '2099-01-02 09:00-04',
        '00000000-0000-0000-0000-0000000000d3');
INSERT INTO lab.husbandry_event (event_id, measure, weight_g)
VALUES ('00000000-0000-0000-0000-0000000000d4', 'weight', 70.4);
SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.event_active WHERE event_id = '00000000-0000-0000-0000-0000000000d4')
    AND (SELECT latest_weight_g FROM lab.subject_current WHERE subject_id = 'G2-renamed') = 70.4,
    'superseding a retracted event restores it as a correction');

-- A retracted file: gone from the active view and from lineage, and the
-- event that consumed it is reported.
SELECT lab.fn_retract('artifact', '00000000-0000-0000-0000-0000000000f2', 'sorted from the wrong file');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.artifact_active WHERE artifact_id = '00000000-0000-0000-0000-0000000000f2')
    AND (SELECT is_retracted FROM lab.artifact_version
          WHERE artifact_id = '00000000-0000-0000-0000-0000000000f2')
    AND NOT EXISTS (SELECT 1 FROM lab.fn_artifact_lineage('00000000-0000-0000-0000-0000000000f1', 'down')
                    WHERE artifact_id = '00000000-0000-0000-0000-0000000000f2'),
    'a retracted artifact is not active and drops out of lineage that follows corrections');
SELECT lab.fn_retract('artifact',
                      (SELECT artifact_id FROM lab.artifact_active WHERE relative_path = 'G1/s1/raw.dat'),
                      'recorded from the wrong rig');
SELECT pg_temp.assert(
    (SELECT subject || '|' || (detail LIKE '%recorded from the wrong rig') FROM lab.fn_check_integrity()
      WHERE check_name = 'input_retracted') = '00000000-0000-0000-0000-0000000000e8|true',
    'integrity check reports the current analysis that consumed a retracted file');
SELECT lab.fn_retract('event', '00000000-0000-0000-0000-0000000000e8', 'analysis of a withdrawn file');
SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.fn_check_integrity()
            WHERE check_name = 'artifact_producer_retracted'
              AND detail LIKE 'produced by event 00000000-0000-0000-0000-0000000000e8, which was retracted:%')
    AND NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity() WHERE check_name = 'input_retracted'),
    'integrity check reports active files of a retracted event, resolved through its versions');

-- ---------------------------------------------------------------------------
-- People and logins
-- ---------------------------------------------------------------------------
SELECT pg_temp.assert(lab.fn_current_person() IS NULL, 'an unmapped login resolves to no person');
UPDATE lab.person SET db_login = session_user WHERE person_id = '00000000-0000-0000-0000-0000000000a1';
SELECT pg_temp.assert(lab.fn_current_person() = '00000000-0000-0000-0000-0000000000a1',
                      'fn_current_person resolves the connected login');
INSERT INTO lab.person (person_id, full_name) VALUES ('00000000-0000-0000-0000-0000000000a2', 'Other');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.person SET db_login = session_user
       WHERE person_id = '00000000-0000-0000-0000-0000000000a2'$q$, 'uq_person_db_login');
INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at) VALUES
    ('00000000-0000-0000-0000-0000000000d5', 'husbandry', 'G2-renamed', now());
INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at, recorded_by) VALUES
    ('00000000-0000-0000-0000-0000000000d6', 'husbandry', 'G2-renamed', now(),
     '00000000-0000-0000-0000-0000000000a2');
INSERT INTO lab.husbandry_event (event_id, measure) VALUES
    ('00000000-0000-0000-0000-0000000000d5', 'health_check'),
    ('00000000-0000-0000-0000-0000000000d6', 'health_check');
SELECT lab.fn_set_variable('subject', 'G2-renamed', 'baseline weight', 72.0);
SELECT pg_temp.assert(
    (SELECT recorded_by FROM lab.event WHERE event_id = '00000000-0000-0000-0000-0000000000d5')
        = '00000000-0000-0000-0000-0000000000a1'
    AND (SELECT recorded_by FROM lab.event WHERE event_id = '00000000-0000-0000-0000-0000000000d6')
        = '00000000-0000-0000-0000-0000000000a2'
    AND (SELECT set_by FROM lab.variable_current
          WHERE entity_kind = 'subject' AND variable = 'baseline weight')
        = '00000000-0000-0000-0000-0000000000a1',
    'a row that names no person is attributed to the login''s person; a named person is kept');

-- ===========================================================================
-- File disposition (lab.artifact_disposition, lab.artifact_present)
-- ===========================================================================
INSERT INTO lab.subject (subject_id, project_id) VALUES ('G3', '00000000-0000-0000-0000-0000000000b1');
INSERT INTO lab.session (session_id, subject_id, label, storage_root_id, relative_path) VALUES
    ('00000000-0000-0000-0000-0000000009c1', 'G3', 's1',
     (SELECT root_id FROM lab.storage_root WHERE name = 'nas-test'), 'G3/s1');
INSERT INTO lab.event (event_id, event_type, session_id, occurred_at)
VALUES ('00000000-0000-0000-0000-0000000009e1', 'recording',
        '00000000-0000-0000-0000-0000000009c1', '2026-10-01 09:00+00');
INSERT INTO lab.recording_event (event_id) VALUES ('00000000-0000-0000-0000-0000000009e1');
-- a1 raw file; a2 an output; a3 other bytes later written to a2's path;
-- a4 a1's bytes at another path; a5 other bytes at another path.
INSERT INTO lab.artifact (artifact_id, produced_by_event_id, storage_root_id, relative_path, checksum)
SELECT v.id::uuid, '00000000-0000-0000-0000-0000000009e1',
       (SELECT root_id FROM lab.storage_root WHERE name = 'nas-test'), v.path, repeat(v.hex, 32)
FROM (VALUES ('00000000-0000-0000-0000-0000000009a1', 'G3/s1/raw.dat',      '11'),
             ('00000000-0000-0000-0000-0000000009a2', 'G3/s1/out.mat',      '22'),
             ('00000000-0000-0000-0000-0000000009a3', 'G3/s1/out.mat',      '33'),
             ('00000000-0000-0000-0000-0000000009a4', 'G3/s1/copy/raw.dat', '11'),
             ('00000000-0000-0000-0000-0000000009a5', 'G3/s1/other.dat',    '55')) AS v(id, path, hex);

SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.artifact_present
      WHERE artifact_id::text LIKE '00000000-0000-0000-0000-0000000009a_') = 5,
    'every new file is present');
SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.fn_check_integrity()
            WHERE check_name = 'duplicate_active_path' AND subject LIKE '%:G3/s1/out.mat'),
    'two present rows at one path: the overwrite was not recorded');

-- replaced: other bytes at the same path, and only while present.
INSERT INTO lab.artifact_disposition (artifact_id, disposition, successor_artifact_id, occurred_at)
VALUES ('00000000-0000-0000-0000-0000000009a2', 'replaced',
        '00000000-0000-0000-0000-0000000009a3', '2026-10-02 09:00+00');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.artifact_present
                WHERE artifact_id = '00000000-0000-0000-0000-0000000009a2')
    AND EXISTS (SELECT 1 FROM lab.artifact_present
                WHERE artifact_id = '00000000-0000-0000-0000-0000000009a3')
    AND EXISTS (SELECT 1 FROM lab.artifact_active
                WHERE artifact_id = '00000000-0000-0000-0000-0000000009a2'),
    'a replaced file leaves artifact_present, its row stays active, its successor is present');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity()
                WHERE check_name = 'duplicate_active_path' AND subject LIKE '%:G3/s1/out.mat'),
    'with the replacement recorded the path holds one present file');
SELECT pg_temp.assert(
    (SELECT recorded_login FROM lab.artifact_disposition
      WHERE artifact_id = '00000000-0000-0000-0000-0000000009a2') = session_user,
    'the disposition carries the login that recorded it');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.artifact_disposition (artifact_id, disposition, occurred_at)
    VALUES ('00000000-0000-0000-0000-0000000009a2', 'deleted', now())$q$,
    'already recorded as replaced');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.artifact_disposition (artifact_id, disposition, successor_artifact_id, occurred_at)
    VALUES ('00000000-0000-0000-0000-0000000009a3', 'replaced',
            '00000000-0000-0000-0000-0000000009a5', now())$q$,
    'a replacement');

-- A correction of a disposed row describes the same file: it is not present either.
INSERT INTO lab.artifact (artifact_id, produced_by_event_id, storage_root_id, relative_path,
                          checksum, role, supersedes)
SELECT '00000000-0000-0000-0000-0000000009b2', produced_by_event_id, storage_root_id,
       relative_path, checksum, 'derived', artifact_id
FROM lab.artifact WHERE artifact_id = '00000000-0000-0000-0000-0000000009a2';
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.artifact_present
                WHERE artifact_id = '00000000-0000-0000-0000-0000000009b2')
    AND (SELECT disposition FROM lab.artifact_disposition_latest
          WHERE artifact_id = '00000000-0000-0000-0000-0000000009b2') = 'replaced',
    'a disposition belongs to the file, so a correction of its row shares it');

-- moved: the same bytes at another path, the successor required.
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.artifact_disposition (artifact_id, disposition, occurred_at)
    VALUES ('00000000-0000-0000-0000-0000000009a1', 'moved', now())$q$,
    'disposition_successor_ck');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.artifact_disposition (artifact_id, disposition, successor_artifact_id, occurred_at)
    VALUES ('00000000-0000-0000-0000-0000000009a1', 'moved',
            '00000000-0000-0000-0000-0000000009a5', now())$q$,
    'a move keeps');
INSERT INTO lab.artifact_disposition (artifact_id, disposition, successor_artifact_id, occurred_at, note)
VALUES ('00000000-0000-0000-0000-0000000009a1', 'moved',
        '00000000-0000-0000-0000-0000000009a4', '2026-10-03 09:00+00', 'to the copy folder');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.artifact_present
                WHERE artifact_id = '00000000-0000-0000-0000-0000000009a1')
    AND EXISTS (SELECT 1 FROM lab.artifact_present
                WHERE artifact_id = '00000000-0000-0000-0000-0000000009a4'),
    'a moved file leaves artifact_present; the row at its new path is present');

-- A failed check of a file that is no longer there is not an integrity error;
-- an ok check after it was recorded gone is a contradiction worth a warning.
INSERT INTO lab.artifact_verification (artifact_id, status)
VALUES ('00000000-0000-0000-0000-0000000009a1', 'missing');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity()
                WHERE check_name IN ('artifact_verification_failed', 'artifact_never_verified')
                  AND subject = '00000000-0000-0000-0000-0000000009a1'),
    'the checks of files skip a file recorded as moved');
INSERT INTO lab.artifact_verification (artifact_id, status, observed_checksum)
VALUES ('00000000-0000-0000-0000-0000000009a1', 'ok', repeat('11', 32));
SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.fn_check_integrity()
            WHERE check_name = 'disposed_file_found'
              AND subject = '00000000-0000-0000-0000-0000000009a1'),
    'a file verified ok after it was recorded moved is reported');

-- deleted, then restored; restoring what is present is refused.
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.artifact_disposition (artifact_id, disposition, successor_artifact_id, occurred_at)
    VALUES ('00000000-0000-0000-0000-0000000009a5', 'deleted',
            '00000000-0000-0000-0000-0000000009a4', now())$q$,
    'disposition_successor_ck');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.artifact_disposition (artifact_id, disposition, occurred_at)
    VALUES ('00000000-0000-0000-0000-0000000009a5', 'restored', now())$q$,
    'nothing to restore');
INSERT INTO lab.artifact_disposition (artifact_id, disposition, occurred_at)
VALUES ('00000000-0000-0000-0000-0000000009a5', 'deleted', '2026-10-04 09:00+00');
INSERT INTO lab.artifact_disposition (artifact_id, disposition, occurred_at)
VALUES ('00000000-0000-0000-0000-0000000009a5', 'restored', '2026-10-05 09:00+00');
SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.artifact_present
            WHERE artifact_id = '00000000-0000-0000-0000-0000000009a5'),
    'a restored file is present again');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.artifact_disposition (artifact_id, disposition, occurred_at)
    VALUES ('00000000-0000-0000-0000-0000000009a5', 'restored', now())$q$,
    'nothing to restore');

-- The log is append-only.
SELECT pg_temp.expect_error('UPDATE lab.artifact_disposition SET note = ''x''', 'append-only log');
SELECT pg_temp.expect_error('DELETE FROM lab.artifact_disposition', 'append-only log');
SELECT pg_temp.expect_error('TRUNCATE lab.artifact_disposition CASCADE', 'not allowed');

SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.acquisition_system WHERE code = 'tdt_synapse'),
    'TDT Synapse is a seeded acquisition system');

-- ---------------------------------------------------------------------------
-- Forms: templates, subject forms, entries (observation events)
-- ---------------------------------------------------------------------------
INSERT INTO lab.project (project_id, name)
VALUES ('00000000-0000-0000-0000-0000000000b2', 'second-project');
INSERT INTO lab.subject (subject_id, project_id, sex) VALUES
    ('F1', '00000000-0000-0000-0000-0000000000b1', 'F');

SELECT pg_temp.assert(EXISTS (SELECT 1 FROM lab.event_type WHERE code = 'observation'),
                      'observation is a seeded event type');
SELECT pg_temp.assert(
    (SELECT value_type || '|' || array_to_string(applies_to, ',') FROM lab.variable
      WHERE name = 'entry note') = 'text|event',
    'entry note is a seeded text variable for events');

-- Number text is accepted only in the one form numeric gives back unchanged.
SELECT pg_temp.assert(
    lab.fn_form_number_ok('1.50') AND lab.fn_form_number_ok('-0.25') AND lab.fn_form_number_ok('0')
    AND lab.fn_form_number_ok('0.000100') AND lab.fn_form_number_ok('1234567890123456789012345')
    AND NOT lab.fn_form_number_ok('1e3') AND NOT lab.fn_form_number_ok('.5')
    AND NOT lab.fn_form_number_ok('+1') AND NOT lab.fn_form_number_ok('007')
    AND NOT lab.fn_form_number_ok('-0') AND NOT lab.fn_form_number_ok('1,5')
    AND NOT lab.fn_form_number_ok(' 1') AND NOT lab.fn_form_number_ok('1.')
    AND NOT lab.fn_form_number_ok('NaN') AND NOT lab.fn_form_number_ok('Infinity'),
    'fn_form_number_ok accepts plain decimals and nothing it would rewrite');
SELECT pg_temp.assert(
    lab.fn_form_integer_ok('12') AND lab.fn_form_integer_ok('-3')
    AND NOT lab.fn_form_integer_ok('1.0') AND NOT lab.fn_form_integer_ok('-0')
    AND NOT lab.fn_form_integer_ok('01'),
    'fn_form_integer_ok accepts whole numbers only');

-- Definition problems: each kind of fault is reported, with its place.
CREATE TEMP TABLE form_bad (def jsonb, pattern text);
INSERT INTO form_bad VALUES
    ('[]', 'must be a JSON object'),
    ('{"format": 2, "sections": [{"fields": [{"widget": "text", "variable": "a"}]}]}', 'must be 1'),
    ('{"format": 1, "sections": []}', 'at least one section'),
    ('{"format": 1, "sections": [{"fields": []}], "colour": "red"}', 'not a key of a form definition'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "heading", "text": "x"}]}]}', 'no field to fill in'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "slider", "variable": "a"}]}]}', 'widget must be one of'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text"}]}]}', 'needs a variable'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "Probe Depth"}]}]}', 'write the variable name as "probe depth"'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "entry note"}]}]}', 'reserved'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "a"}, {"widget": "longtext", "variable": "a"}]}]}', 'already a field'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "a", "units": "g"}]}]}', 'takes no units'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "number", "variable": "a", "min": 0}]}]}', 'min must be text'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "number", "variable": "a", "min": "1e3"}]}]}', 'not a plain decimal number'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "integer", "variable": "a", "max": "1.5"}]}]}', 'not a whole number'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "number", "variable": "a", "min": "5", "max": "1"}]}]}', 'min is greater than max'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "choice", "variable": "a"}]}]}', 'needs a list of options'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "choice", "variable": "a", "options": [{"value": "x"}, {"value": "x"}]}]}]}', 'listed twice'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "choice", "variable": "a", "options": [{"value": "=1"}]}]}]}', 'formula'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "yesno", "variable": "a", "options": [{"value": "x"}]}]}]}', 'takes no options'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "a", "required": "yes"}]}]}', 'true or false'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "instruction", "variable": "a", "text": "x"}]}]}', 'takes no variable'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "number", "variable": "session only"}]}]}', 'not defined for events'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "probe depth"}]}]}', 'holds numbers'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "number", "variable": "baseline weight", "units": "kg"}]}]}', 'recorded in g, not in kg'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "a"}]}], "header": [{"item": "weather"}]}', 'an info item is'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "a"}]}], "header": [{"variable": "nope", "source": "subject"}]}', 'variable nope is not defined'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "a"}]}], "header": [{"variable": "session only", "source": "subject"}]}', 'applies to session only'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "a"}]}], "header": [{"variable": "b", "source": "previous_entry"}]}', 'must be a field of this form'),
    ('{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "a"}]}], "header": [{"item": "sex"}, {"item": "sex"}]}', 'already in the header');
-- 'session only' is a number for sessions alone: strict mode wants it
-- defined for events, non-strict lets publish add that.
SELECT lab.fn_define_variable('session only', 'number', p_applies_to => ARRAY['session']);
SELECT pg_temp.assert(NOT EXISTS (
    SELECT 1 FROM form_bad b
    WHERE NOT EXISTS (SELECT 1 FROM lab.fn_form_definition_problems(b.def, true) p
                      WHERE p.problem ~ b.pattern)),
    'fn_form_definition_problems reports every kind of fault: ' ||
    coalesce((SELECT string_agg(b.pattern, '; ') FROM form_bad b
              WHERE NOT EXISTS (SELECT 1 FROM lab.fn_form_definition_problems(b.def, true) p
                                WHERE p.problem ~ b.pattern)), ''));
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM lab.fn_form_definition_problems(
    '{"format": 1, "sections": [{"fields": [{"widget": "number", "variable": "session only"}]}]}', false)),
    'without p_strict an existing variable not yet defined for events is no problem');

-- Publish: variables defined, versions numbered, an identical definition is
-- not a new version, applies_to grows.
CREATE TEMP TABLE form_def (v integer, def jsonb);
INSERT INTO form_def VALUES (1, $j${"format": 1,
  "header": [{"item": "species"}, {"item": "latest_weight"},
             {"variable": "baseline weight", "source": "subject", "label": "Baseline"},
             {"variable": "probe depth", "source": "previous_entry"}],
  "sections": [{"title": "Recording", "fields": [
      {"widget": "number", "variable": "probe depth", "units": "um", "required": true,
       "min": "0", "max": "6000", "show_previous": true},
      {"widget": "integer", "variable": "trial count"},
      {"widget": "choice", "variable": "hemisphere",
       "options": [{"value": "L", "label": "Left"}, {"value": "R", "label": "Right"}]},
      {"widget": "yesno", "variable": "implant ok", "required": true},
      {"widget": "instruction", "text": "Check the headcap before connecting."}]},
   {"title": "Times", "fields": [
      {"widget": "date", "variable": "surgery date"},
      {"widget": "time", "variable": "start time"},
      {"widget": "datetime", "variable": "fed at"},
      {"widget": "text", "variable": "booth"},
      {"widget": "longtext", "variable": "remarks"}]}]}$j$);
INSERT INTO form_def SELECT 2, jsonb_set(def, '{sections,1,fields}',
    (def #> '{sections,1,fields}') || '[{"widget": "number", "variable": "sound level"}]')
FROM form_def WHERE v = 1;

SELECT pg_temp.assert(
    (SELECT version_number || '|' || is_new FROM lab.fn_publish_form(
        ' Daily  Check ', (SELECT def FROM form_def WHERE v = 1), p_label => 'Daily check',
        p_note => 'first')) = '1|true',
    'the first publication is version 1');
SELECT pg_temp.assert(
    (SELECT label FROM lab.form WHERE name = 'daily check') = 'Daily check'
    AND (SELECT created_login = session_user AND note = 'first' FROM lab.form_version
          WHERE form_name = 'daily check' AND version = 1)
    AND (SELECT value_type || '|' || coalesce(units, '') || '|' || array_to_string(applies_to, ',')
           FROM lab.variable WHERE name = 'trial count') = 'number||event'
    AND (SELECT value_type FROM lab.variable WHERE name = 'hemisphere') = 'text'
    AND (SELECT 'event' = ANY (applies_to) AND 'session' = ANY (applies_to)
           FROM lab.variable WHERE name = 'probe depth'),
    'publishing defines the fields'' variables for events and grows an existing one''s applies_to');
SELECT pg_temp.assert(
    (SELECT version_number || '|' || is_new FROM lab.fn_publish_form(
        'daily check', (SELECT def FROM form_def WHERE v = 1))) = '1|false'
    AND (SELECT count(*) FROM lab.form_version WHERE form_name = 'daily check') = 1,
    'publishing an identical definition appends nothing');
SELECT pg_temp.assert(
    (SELECT version_number || '|' || is_new FROM lab.fn_publish_form(
        'daily check', (SELECT def FROM form_def WHERE v = 2), p_note => 'adds sound level')) = '2|true',
    'a changed definition is the next version');
SELECT pg_temp.expect_error($q$
    SELECT * FROM lab.fn_publish_form('daily check', '{"format": 1, "sections": []}')$q$,
    'definition is not valid');
SELECT pg_temp.expect_error($q$SELECT * FROM lab.fn_publish_form('2 bad', '{}')$q$,
    'not a valid form name');
-- The version policy holds for a raw INSERT too.
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.form_version (form_name, definition) VALUES ('daily check', '{"format": 1}')$q$,
    'definition is not valid');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.form_version (form_name, version, definition)
    SELECT 'daily check', 7, def FROM form_def WHERE v = 1$q$,
    'next version of form daily check is 3');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.form_version (form_name, definition) VALUES ('daily check',
      '{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "brand new"}]}]}')$q$,
    'variable brand new is not defined');
-- Versions are immutable, the template's name too; its label is not.
SELECT pg_temp.expect_error('UPDATE lab.form_version SET note = ''x''', 'never changed');
SELECT pg_temp.expect_error('DELETE FROM lab.form_version', 'never changed');
SELECT pg_temp.expect_error('TRUNCATE lab.form_version CASCADE', 'not allowed');
SELECT pg_temp.expect_error('UPDATE lab.form SET name = ''other''', 'cannot be renamed');
UPDATE lab.form SET description = 'Before each session' WHERE name = 'daily check';
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.row_history WHERE table_name = 'form' AND row_key = '{"name": "daily check"}') = 1,
    'edits to a template are recorded in row_history');

-- Subject forms: project and version default, one per (subject, project,
-- template), what they are never changes.
SELECT lab.fn_add_subject_form('F1', 'Daily Check', p_form_version => 1) AS sf1 \gset
SELECT lab.fn_add_subject_form('F1', 'daily check', '00000000-0000-0000-0000-0000000000b2') AS sf2 \gset
SELECT pg_temp.assert(
    (SELECT project_id || '|' || form_version FROM lab.subject_form WHERE subject_form_id = :'sf1')
        = '00000000-0000-0000-0000-0000000000b1|1'
    AND (SELECT project_id || '|' || form_version FROM lab.subject_form WHERE subject_form_id = :'sf2')
        = '00000000-0000-0000-0000-0000000000b2|2'
    AND lab.fn_add_subject_form('F1', 'daily check') = :'sf1',
    'a subject form defaults to the subject''s project and the latest version, and is not added twice');
SELECT pg_temp.expect_error($q$SELECT lab.fn_add_subject_form('nobody', 'daily check')$q$, 'does not exist');
SELECT pg_temp.expect_error($q$SELECT lab.fn_add_subject_form('F1', 'no such form')$q$, 'does not exist');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.subject_form (subject_id, form_name) VALUES ('F1', 'daily check')$q$,
    'duplicate key');
SELECT pg_temp.expect_error(format($q$
    UPDATE lab.subject_form SET project_id = '00000000-0000-0000-0000-0000000000b2'
    WHERE subject_form_id = %L$q$, :'sf1'), 'only form_version, notes and retired_at');
SELECT pg_temp.expect_error(format($q$
    UPDATE lab.subject_form SET subject_id = 'G1-renamed' WHERE subject_form_id = %L$q$, :'sf1'),
    'cannot be moved to another subject');
SELECT pg_temp.expect_error(format($q$
    UPDATE lab.subject_form SET form_version = 9 WHERE subject_form_id = %L$q$, :'sf1'),
    'foreign key');

-- Entries: inserted, then the same entry again is 'existing' (also with the
-- time sent with another offset and blank values left out); another entry
-- under that id is refused.
CREATE TEMP TABLE obs_vals (k text, v jsonb);
INSERT INTO obs_vals VALUES
    ('first', '{"probe depth": "1350.50", "trial count": "12", "hemisphere": "L", "implant ok": "yes",
                "surgery date": "2026-08-30", "start time": "09:30", "fed at": "2026-11-13T18:00-05:00",
                "booth": "B2", "remarks": "Line one\nline two"}');
SELECT pg_temp.assert(lab.fn_record_observation(
    '00000000-0000-0000-0000-00000000f001', :'sf1', '2026-11-14 09:30-05', '2026-11-14 09:30',
    (SELECT v FROM obs_vals WHERE k = 'first'), 'Bright and alert.',
    p_attributes => '{"client": "schema_test"}') = 'inserted',
    'an entry is inserted');
SELECT pg_temp.assert(lab.fn_record_observation(
    '00000000-0000-0000-0000-00000000f001', :'sf1', '2026-11-14 14:30Z', '2026-11-14 09:30',
    (SELECT v || '{"sound level": "  "}' FROM obs_vals WHERE k = 'first'), 'Bright and alert.') = 'existing',
    'the same entry sent again is existing, and writes nothing');
SELECT pg_temp.expect_error(format($q$
    SELECT lab.fn_record_observation('00000000-0000-0000-0000-00000000f001', %L,
        '2026-11-14 09:30-05', '2026-11-14 09:30', '{"probe depth": "1351", "implant ok": "yes"}')$q$, :'sf1'),
    'already exists and is not this entry');
SELECT pg_temp.expect_error($q$
    SELECT lab.fn_record_observation('00000000-0000-0000-0000-0000000000e1',
        (SELECT subject_form_id FROM lab.subject_form LIMIT 1), now(), 'x', '{}')$q$,
    'already exists and is not this entry');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.event WHERE event_id = '00000000-0000-0000-0000-00000000f001') = 1
    AND (SELECT count(*) FROM lab.variable_value WHERE event_id = '00000000-0000-0000-0000-00000000f001') = 10,
    'the replay wrote nothing');
SELECT pg_temp.assert(
    (SELECT e.subject_id || '|' || o.form_name || '|' || o.form_version || '|' || o.session_label
            || '|' || e.recorded_login || '|' || (e.attributes->>'client')
            || '|' || length(e.attributes->>'client_digest')
       FROM lab.event e JOIN lab.observation_event o USING (event_id)
      WHERE e.event_id = '00000000-0000-0000-0000-00000000f001')
        = 'F1|daily check|1|2026-11-14 09:30|' || session_user || '|schema_test|64',
    'the entry''s event and detail row record its subject, form, version, label, login and digest');
-- Values are stored as the text typed: numbers exactly, text with its newline.
SELECT pg_temp.assert(
    (SELECT field_values::text || '|' || note FROM lab.observation_active
      WHERE event_id = '00000000-0000-0000-0000-00000000f001')
        = (SELECT v::text FROM obs_vals WHERE k = 'first') || '|Bright and alert.'
    AND (SELECT value_num::text FROM lab.variable_value
          WHERE event_id = '00000000-0000-0000-0000-00000000f001' AND variable = 'probe depth') = '1350.50'
    AND (SELECT entry_id = event_id FROM lab.observation_active
          WHERE event_id = '00000000-0000-0000-0000-00000000f001'),
    'observation_active returns every value as the text stored, and the note');
-- (A read in the statement that calls a write function does not see what the
-- function wrote: the statement's snapshot is older. Hence separate steps.)
SELECT pg_temp.assert(lab.fn_record_observation(
    '00000000-0000-0000-0000-00000000f002', :'sf1', '2026-11-15 09:30-05', '2026-11-15',
    '{"probe depth": "5999.000000000000000000000001", "implant ok": "no"}') = 'inserted',
    'a second entry is inserted');
SELECT pg_temp.assert(
    (SELECT field_values->>'probe depth' FROM lab.observation_active
          WHERE event_id = '00000000-0000-0000-0000-00000000f002') = '5999.000000000000000000000001',
    'a number with more digits than a double holds is stored exactly');

-- Every value rule refuses what it should, with SQLSTATE CLB02.
CREATE TEMP TABLE obs_bad (vals jsonb, note text, label text, pattern text);
INSERT INTO obs_bad VALUES
    ('{"implant ok": "yes"}', NULL, 'x', 'probe depth: is required'),
    ('{"probe depth": "1350", "implant ok": "  "}', NULL, 'x', 'implant ok: is required'),
    ('{"probe depth": 1350, "implant ok": "yes"}', NULL, 'x', 'must be sent as text'),
    ('{"probe depth": "1.35e3", "implant ok": "yes"}', NULL, 'x', 'not a plain decimal number'),
    ('{"probe depth": "-1", "implant ok": "yes"}', NULL, 'x', 'below the minimum, 0'),
    ('{"probe depth": "6000.5", "implant ok": "yes"}', NULL, 'x', 'above the maximum, 6000'),
    ('{"probe depth": "1", "trial count": "1.5", "implant ok": "yes"}', NULL, 'x', 'not a whole number'),
    ('{"probe depth": "1", "hemisphere": "left", "implant ok": "yes"}', NULL, 'x', 'not one of the choices \(L, R\)'),
    ('{"probe depth": "1", "implant ok": "true"}', NULL, 'x', 'not yes or no'),
    ('{"probe depth": "1", "implant ok": "yes", "surgery date": "2026-02-30"}', NULL, 'x', 'not a date'),
    ('{"probe depth": "1", "implant ok": "yes", "start time": "9:30"}', NULL, 'x', 'not a time'),
    ('{"probe depth": "1", "implant ok": "yes", "fed at": "2026-11-13T18:00"}', NULL, 'x', 'UTC offset'),
    ('{"probe depth": "1", "implant ok": "yes", "booth": "two\nlines"}', NULL, 'x', 'single line'),
    ('{"probe depth": "1", "implant ok": "yes", "booth": "=HYPERLINK(1)"}', NULL, 'x', 'formula'),
    ('{"probe depth": "1", "implant ok": "yes", "remarks": "@cmd"}', NULL, 'x', 'formula'),
    ('{"probe depth": "1", "implant ok": "yes", "sound level": "60"}', NULL, 'x', 'not a field of form daily check version 1'),
    ('{"probe depth": "1", "implant ok": "yes"}', '=1+1', 'x', 'entry note: starts with'),
    ('{"probe depth": "1", "implant ok": "yes"}', NULL, ' x', 'session label'),
    ('{"probe depth": "1", "implant ok": "yes"}', NULL, '', 'session label'),
    ('[1]', NULL, 'x', 'must be a JSON object');
CREATE FUNCTION pg_temp.obs_error(p_vals jsonb, p_note text, p_label text, p_sf uuid)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM lab.fn_record_observation(gen_random_uuid(), p_sf, now(), p_label, p_vals, p_note);
    RETURN 'no error';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
END;
$$;
SELECT pg_temp.assert(NOT EXISTS (
    SELECT 1 FROM obs_bad b
    WHERE pg_temp.obs_error(b.vals, b.note, b.label, :'sf1') !~ b.pattern),
    'every value rule refuses what it should: ' ||
    coalesce((SELECT string_agg(b.pattern || ' -> ' || pg_temp.obs_error(b.vals, b.note, b.label, :'sf1'), '; ')
              FROM obs_bad b
              WHERE pg_temp.obs_error(b.vals, b.note, b.label, :'sf1') !~ b.pattern), ''));
SELECT pg_temp.assert(
    pg_temp.obs_error('{"probe depth": "1.35e3", "implant ok": "yes"}', NULL, 'x', :'sf1') LIKE 'CLB02 %',
    'a value problem is SQLSTATE CLB02');
-- An entry on a subject form names that form's subject: a raw detail row
-- under another subject's event is refused.
INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at)
VALUES ('00000000-0000-0000-0000-00000000f0ff', 'observation', 'G1-renamed', now());
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.observation_event (event_id, subject_form_id, form_name, form_version, session_label)
    VALUES ('00000000-0000-0000-0000-00000000f0ff', %L, 'daily check', 1, 'x')$q$, :'sf1'),
    'belongs to subject F1');
INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at)
VALUES ('00000000-0000-0000-0000-00000000f0fe', 'observation', 'F1', now());
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.observation_event (event_id, subject_form_id, form_name, form_version, session_label)
    VALUES ('00000000-0000-0000-0000-00000000f0fe', %L, 'second form', 1, 'x')$q$, :'sf1'),
    'foreign key');

-- The note is changed without a correction; the history is kept.
SELECT pg_temp.assert(
    lab.fn_set_entry_note('00000000-0000-0000-0000-00000000f001', 'Bright; ate well.') = 'set'
    AND lab.fn_set_entry_note('00000000-0000-0000-0000-00000000f001', 'Bright; ate well.') = 'unchanged',
    'fn_set_entry_note sets a changed note and writes nothing for the same text');
SELECT pg_temp.assert(
    (SELECT note FROM lab.observation_active
          WHERE event_id = '00000000-0000-0000-0000-00000000f001') = 'Bright; ate well.'
    AND (SELECT string_agg(value_text, ' > ' ORDER BY value_id) FROM lab.variable_value
          WHERE event_id = '00000000-0000-0000-0000-00000000f001' AND variable = 'entry note')
        = 'Bright and alert. > Bright; ate well.'
    AND (SELECT bool_and(set_login = session_user) FROM lab.variable_value
          WHERE event_id = '00000000-0000-0000-0000-00000000f001' AND variable = 'entry note'),
    'fn_set_entry_note appends the new note and keeps the old one, under the login');
SELECT pg_temp.assert(
    lab.fn_set_entry_note('00000000-0000-0000-0000-00000000f002', '   ') = 'unchanged'
    AND lab.fn_set_entry_note('00000000-0000-0000-0000-00000000f002', 'tmp') = 'set'
    AND lab.fn_set_entry_note('00000000-0000-0000-0000-00000000f002', '') = 'unset',
    'a blank note clears a note, and is nothing to clear on an entry without one');
SELECT pg_temp.assert(
    (SELECT note IS NULL FROM lab.observation_active
      WHERE event_id = '00000000-0000-0000-0000-00000000f002'),
    'a cleared note is gone');
SELECT pg_temp.expect_error($q$SELECT lab.fn_set_entry_note('00000000-0000-0000-0000-00000000f001', '@x')$q$,
    'formula');
SELECT pg_temp.expect_error($q$SELECT lab.fn_set_entry_note('00000000-0000-0000-0000-0000000000e1', 'x')$q$,
    'not an entry on a form');

-- A correction: same subject form and version; changed values set, cleared
-- values unset, unchanged ones carried with their set_at; tags carried.
SELECT lab.fn_tag('event', '00000000-0000-0000-0000-00000000f001', 'qc:pass');
CREATE TEMP TABLE obs_before AS
SELECT set_at FROM lab.variable_value
WHERE event_id = '00000000-0000-0000-0000-00000000f001' AND variable = 'booth';
SELECT pg_temp.assert(lab.fn_record_observation(
    '00000000-0000-0000-0000-00000000f003', :'sf1', '2026-11-14 09:30-05', '2026-11-14 09:30',
    (SELECT (v - 'hemisphere') || '{"probe depth": "1400", "trial count": ""}' FROM obs_vals WHERE k = 'first'),
    'Bright; ate well.', p_supersedes => '00000000-0000-0000-0000-00000000f001') = 'inserted',
    'a correction is inserted');
SELECT pg_temp.assert(
    (SELECT field_values->>'probe depth' || '|' || coalesce(field_values->>'trial count', 'none')
            || '|' || coalesce(field_values->>'hemisphere', 'none') || '|' || (field_values->>'booth')
            || '|' || note || '|' || form_version || '|' || entry_id
       FROM lab.observation_active WHERE event_id = '00000000-0000-0000-0000-00000000f003')
        = '1400|none|none|B2|Bright; ate well.|1|00000000-0000-0000-0000-00000000f001'
    AND NOT EXISTS (SELECT 1 FROM lab.observation_active
                    WHERE event_id = '00000000-0000-0000-0000-00000000f001'),
    'the correction replaces the entry: changed, cleared and kept values, the note, the version, the entry id');
SELECT pg_temp.assert(
    (SELECT vv.set_at FROM lab.variable_value vv
      WHERE vv.event_id = '00000000-0000-0000-0000-00000000f003' AND vv.variable = 'booth')
        = (SELECT set_at FROM obs_before)
    AND (SELECT count(*) FROM lab.variable_value
          WHERE event_id = '00000000-0000-0000-0000-00000000f003' AND variable = 'booth') = 1
    AND (SELECT string_agg(op, ',' ORDER BY value_id) FROM lab.variable_value
          WHERE event_id = '00000000-0000-0000-0000-00000000f003' AND variable = 'hemisphere') = 'set,unset',
    'an unchanged value keeps its set_at and is not written again; a cleared one is unset');
SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.tag_current WHERE entity_kind = 'event'
            AND event_id = '00000000-0000-0000-0000-00000000f003' AND tag = 'qc:pass'),
    'the correction carries the entry''s tags');
SELECT pg_temp.expect_error(format($q$
    SELECT lab.fn_record_observation(gen_random_uuid(), %L, now(), 'x',
        '{"probe depth": "1", "implant ok": "yes"}',
        p_supersedes => '00000000-0000-0000-0000-00000000f001')$q$, :'sf1'),
    'already been corrected; its current version is 00000000-0000-0000-0000-00000000f003');
SELECT pg_temp.expect_error(format($q$
    SELECT lab.fn_record_observation(gen_random_uuid(), %L, now(), 'x',
        '{"probe depth": "1", "implant ok": "yes"}',
        p_supersedes => '00000000-0000-0000-0000-00000000f003')$q$, :'sf2'),
    'its correction must be too');
SELECT pg_temp.expect_error(format($q$
    SELECT lab.fn_record_observation(gen_random_uuid(), %L, now(), 'x', '{}',
        p_supersedes => '00000000-0000-0000-0000-0000000000e1')$q$, :'sf1'),
    'not an entry on a form');
SELECT pg_temp.expect_error($q$SELECT lab.fn_set_entry_note('00000000-0000-0000-0000-00000000f001', 'x')$q$,
    'has been corrected');
-- A correction under the subject form's newer version keeps the entry's own.
UPDATE lab.subject_form SET form_version = 2 WHERE subject_form_id = :'sf1';
SELECT pg_temp.assert(
    (SELECT string_agg(form_version::text, ',') FROM lab.observation_active
      WHERE subject_form_id = :'sf1') = '1,1'
    AND (SELECT count(*) FROM lab.row_history WHERE table_name = 'subject_form') = 1,
    'moving a subject form to a newer version changes no entry and is recorded in row_history');
SELECT pg_temp.assert(lab.fn_record_observation(
    '00000000-0000-0000-0000-00000000f004', :'sf1', '2026-11-16 09:30-05', '2026-11-16',
    '{"probe depth": "1500", "implant ok": "yes", "sound level": "65"}') = 'inserted',
    'an entry is inserted under the newer version');
SELECT pg_temp.assert(
    (SELECT form_version FROM lab.observation_active
          WHERE event_id = '00000000-0000-0000-0000-00000000f004') = 2,
    'a new entry uses the subject form''s version');

-- The CSV column order: by form, then by first appearance across versions.
SELECT version_number FROM lab.fn_publish_form('second form', $j${"format": 1, "sections": [{"fields": [
    {"widget": "text", "variable": "booth"}, {"widget": "number", "variable": "pellets"}]}]}$j$);
SELECT lab.fn_add_subject_form('F1', 'second form') AS sf3 \gset
SELECT pg_temp.assert(
    (SELECT string_agg(variable || coalesce('(' || units || ')', ''), ',' ORDER BY column_no)
       FROM lab.fn_subject_project_columns('F1', '00000000-0000-0000-0000-0000000000b1'))
        = 'probe depth(um),trial count,hemisphere,implant ok,surgery date,start time,fed at,booth,'
          'remarks,sound level,pellets',
    'fn_subject_project_columns lists each variable once, form by form, version by version');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.fn_subject_project_columns('F1', '00000000-0000-0000-0000-0000000000b2')) = 10
    AND NOT EXISTS (SELECT 1 FROM lab.fn_subject_project_columns('F1', '00000000-0000-0000-0000-0000000000b1') c
                    WHERE c.variable = 'entry note'),
    'the other project''s subject form, on version 2, has every field; the note is no column');

-- Integrity: a required value unset afterwards is reported; withdrawal hides
-- the entry; an observation event without its detail row is an error.
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity()
                                  WHERE check_name = 'observation_invalid'),
    'valid entries are not reported');
SELECT lab.fn_unset_variable('event', '00000000-0000-0000-0000-00000000f004', 'implant ok');
SELECT lab.fn_set_variable('event', '00000000-0000-0000-0000-00000000f004', 'housing', p_text => 'pair');
SELECT pg_temp.assert(
    (SELECT detail FROM lab.fn_check_integrity()
      WHERE check_name = 'observation_invalid' AND subject = '00000000-0000-0000-0000-00000000f004')
        = 'entry on form daily check version 2: implant ok: is required',
    'observation_invalid reports a required value unset since; other variables are not judged');
SELECT lab.fn_retract('event', '00000000-0000-0000-0000-00000000f004', 'test');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.observation_active WHERE event_id = '00000000-0000-0000-0000-00000000f004')
    AND NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity() WHERE check_name = 'observation_invalid'),
    'a withdrawn entry is not active and not judged');
SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.fn_check_integrity() WHERE check_name = 'event_missing_detail'
            AND subject = '00000000-0000-0000-0000-00000000f0ff'),
    'an observation event without its detail row is event_missing_detail');

-- Detail rows are append-only like every other.
SELECT pg_temp.expect_error('UPDATE lab.observation_event SET session_label = ''y''', 'append-only');
SELECT pg_temp.expect_error('DELETE FROM lab.observation_event', 'append-only');

-- A subject rename carries the subject forms and entries along.
SELECT lab.fn_rename_subject('F1', 'F1-renamed');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.subject_form WHERE subject_id = 'F1-renamed') = 3
    AND (SELECT count(*) FROM lab.observation_active WHERE subject_id = 'F1-renamed') = 2
    AND (SELECT count(*) FROM lab.fn_subject_project_columns('F1-renamed',
                                  '00000000-0000-0000-0000-0000000000b1')) = 11,
    'a subject rename relabels its subject forms and entries');
SELECT pg_temp.assert(lab.fn_record_observation(
    '00000000-0000-0000-0000-00000000f001', :'sf1', '2026-11-14 14:30Z', '2026-11-14 09:30',
    (SELECT v FROM obs_vals WHERE k = 'first'), 'Bright and alert.') = 'existing',
    'an entry stored before a rename is still recognised when it is sent again');

-- ===========================================================================
-- Searching listed directories (lab.scan_layout, scan_directory, scan_run,
-- scan_run_result, scan_file; lab.fn_scan_status)
-- ===========================================================================
-- Fixture at this point: one directory ('append-only-fixture' on nas-test,
-- 'off') with one run, its result and one file in the scan memory. Everything
-- below is on two storage roots of its own.
INSERT INTO lab.storage_root (name) VALUES ('nas-scan'), ('nas-scan-2');

CREATE FUNCTION pg_temp.scan_root(p_root text DEFAULT 'nas-scan') RETURNS smallint
LANGUAGE sql STABLE AS $$
    SELECT root_id FROM lab.storage_root WHERE name = p_root;
$$;
-- The id of a directory, by its path.
CREATE FUNCTION pg_temp.scan_dir(p_path text, p_root text DEFAULT 'nas-scan') RETURNS integer
LANGUAGE sql STABLE AS $$
    SELECT scan_directory_id FROM lab.scan_directory
    WHERE storage_root_id = pg_temp.scan_root(p_root) AND relative_path = p_path;
$$;
-- Add a directory with the settings the policy tests do not care about.
CREATE FUNCTION pg_temp.scan_add(p_path text, p_mode text DEFAULT 'register',
                                 p_root text DEFAULT 'nas-scan') RETURNS integer
LANGUAGE sql AS $$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                    scan_interval_min, mode)
    VALUES (pg_temp.scan_root(p_root), p_path, 'epsych', 'America/New_York', 1440, p_mode)
    RETURNING scan_directory_id;
$$;
-- Record a run of a directory, with its result when an outcome is given.
CREATE FUNCTION pg_temp.scan_ran(p_path text, p_due timestamptz, p_started timestamptz,
                                 p_outcome text DEFAULT NULL, p_finished timestamptz DEFAULT NULL,
                                 p_command text DEFAULT 'run') RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_run bigint;
BEGIN
    INSERT INTO lab.scan_run (scan_directory_id, command, mode, due_at, started_at)
    VALUES (pg_temp.scan_dir(p_path), p_command, 'register', p_due, p_started)
    RETURNING scan_run_id INTO v_run;
    IF p_outcome IS NOT NULL THEN
        INSERT INTO lab.scan_run_result (scan_run_id, outcome, finished_at)
        VALUES (v_run, p_outcome, p_finished);
    END IF;
    RETURN v_run;
END;
$$;
-- Put a directory's mode_changed_at at a fixed instant, as if its mode had
-- last changed then. Only the database sets that column, so this goes around
-- the trigger that keeps it, the way the rows of an earlier day would be
-- loaded.
CREATE FUNCTION pg_temp.scan_mode_changed(p_path text, p_at timestamptz) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    ALTER TABLE lab.scan_directory DISABLE TRIGGER trg_scan_directory_policy;
    UPDATE lab.scan_directory SET mode_changed_at = p_at
    WHERE scan_directory_id = pg_temp.scan_dir(p_path);
    ALTER TABLE lab.scan_directory ENABLE TRIGGER trg_scan_directory_policy;
END;
$$;
-- The schedule of one directory at a fixed instant.
CREATE FUNCTION pg_temp.sched(p_path text, p_now timestamptz) RETURNS lab.scan_directory_status
LANGUAGE sql STABLE AS $$
    SELECT s.* FROM lab.fn_scan_status(p_now) s
    WHERE s.scan_directory_id = pg_temp.scan_dir(p_path);
$$;
-- Minutes of [p_from, p_to) in which a directory's window is open.
CREATE FUNCTION pg_temp.open_minutes(p_path text, p_from timestamptz, p_to timestamptz)
RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT count(*) FROM generate_series(p_from, p_to - make_interval(mins => 1),
                                         make_interval(mins => 1)) g(t)
    WHERE lab.fn_scan_window_open(pg_temp.scan_dir(p_path), g.t);
$$;

SELECT pg_temp.assert(
    (SELECT string_agg(code, ',' ORDER BY code) FROM lab.scan_layout) = 'epsych,intan',
    'the two layouts of the tool are seeded');

-- ---------------------------------------------------------------------------
-- A directory: what its columns accept
-- ---------------------------------------------------------------------------
-- The path is normalised like a session's; the creator is stamped; the
-- defaults are a day's wait and 'report'.
INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                scan_interval_min, created_login)
VALUES (pg_temp.scan_root(), ' epsych_files\Data ', 'epsych', 'America/New_York', 1440, 'someone_else');
SELECT pg_temp.assert(
    (SELECT relative_path || '|' || mode || '|' || min_age_min || '|' || created_login || '|' || created_by
            || '|' || (window_start IS NULL AND window_end IS NULL AND pair_with IS NULL)
     FROM lab.scan_directory WHERE scan_directory_id = pg_temp.scan_dir('epsych_files/Data'))
    = 'epsych_files/Data|report|1440|' || session_user || '|00000000-0000-0000-0000-0000000000a1|true',
    'a directory: path normalised, defaults report / 1440, login stamped whatever is sent, '
    'person defaulted from the login');
INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                scan_interval_min, min_age_min, mode, created_by,
                                window_start, window_end, rig, notes)
VALUES (pg_temp.scan_root(), '.hidden/a..b/ok', 'intan', 'UTC', 527040, 0, 'off',
        '00000000-0000-0000-0000-0000000000a2', '23:59', '00:00', 'RIG3', 'limits'),
       (pg_temp.scan_root(), 'interval-one', 'intan', 'UTC', 1, 0, 'off', NULL, NULL, NULL, NULL, NULL);
SELECT pg_temp.assert(
    (SELECT created_by FROM lab.scan_directory
      WHERE scan_directory_id = pg_temp.scan_dir('.hidden/a..b/ok'))
    = '00000000-0000-0000-0000-0000000000a2',
    'the limits of interval and minimum age are accepted; a named creator is kept; '
    'a dot inside a name is not a dot segment');

SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, scan_interval_min)
    VALUES (pg_temp.scan_root(), %L, 'epsych', 'UTC', 60)$q$, v.path), 'scan_directory_path_ck')
FROM (VALUES (''), ('   '), ('/abs/Data'), ('\\nas\share'), ('C:/Data'), ('c:\Data'), ('a/../b'),
             ('../a'), ('a/..'), ('a/./b'), ('./a'), ('a/.'), ('.'), ('a//b'), ('a/'), ('a\')) AS v(path);
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.scan_directory (storage_root_id, layout, time_zone, scan_interval_min)
    VALUES (pg_temp.scan_root(), 'epsych', 'UTC', 60)$q$, 'null value in column "relative_path"');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, scan_interval_min)
    VALUES (pg_temp.scan_root(), 'limits/interval', 'epsych', 'UTC', %s)$q$, v.n), 'scan_directory_interval_ck')
FROM (VALUES (0), (-5), (527041)) AS v(n);
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, scan_interval_min, min_age_min)
    VALUES (pg_temp.scan_root(), 'limits/age', 'epsych', 'UTC', 60, -1)$q$, 'scan_directory_min_age_ck');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, scan_interval_min, mode)
    VALUES (pg_temp.scan_root(), 'limits/mode', 'epsych', 'UTC', 60, 'on')$q$, 'scan_directory_mode_ck');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, scan_interval_min)
    VALUES (pg_temp.scan_root(), 'limits/layout', 'openephys', 'UTC', 60)$q$, 'scan_directory_layout_fkey');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, scan_interval_min)
    VALUES (-1, 'limits/root', 'epsych', 'UTC', 60)$q$, 'scan_directory_storage_root_id_fkey');
-- The window: both or neither, unequal, whole minutes before 24:00.
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                    scan_interval_min, window_start, window_end)
    VALUES (pg_temp.scan_root(), 'limits/window', 'epsych', 'UTC', 60, %L, %L)$q$, v.s, v.e),
    'scan_directory_window_ck')
FROM (VALUES ('22:00', NULL), (NULL, '06:00'), ('22:00', '22:00'), ('24:00', '06:00'),
             ('22:00', '24:00'), ('22:00:30', '06:00'), ('22:00', '06:00:00.5')) AS v(s, e);
-- The time zone: a name the server knows, spelled as it is there.
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, scan_interval_min)
    VALUES (pg_temp.scan_root(), 'limits/zone', 'epsych', %L, 60)$q$, v.tz),
    'is not a time zone name this server knows')
FROM (VALUES ('EDT'), ('america/new_york'), ('-05'), ('America/New_York '), ('Mars/Olympus'), ('')) AS v(tz);
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, scan_interval_min)
    VALUES (pg_temp.scan_root(), 'limits/zone', 'epsych', 60)$q$, 'null value in column "time_zone"');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.scan_directory WHERE relative_path LIKE 'limits/%'),
    'no refused directory was stored');

-- ---------------------------------------------------------------------------
-- No two searched directories on one root are equal or nested
-- ---------------------------------------------------------------------------
-- epsych_files/Data is 'report'. Equal, inside and around it are refused, in
-- any case.
SELECT pg_temp.expect_error(format($q$SELECT pg_temp.scan_add(%L)$q$, v.path),
    'scan directory [0-9]+ \(epsych_files/Data\) is the same directory, contains it or lies inside it')
FROM (VALUES ('epsych_files/Data'), ('EPSYCH_FILES/DATA'), ('epsych_files/Data/SUBJ-ID-1'),
             ('Epsych_Files/data/subj/deeper'), ('epsych_files'), ('EPSYCH_files')) AS v(path);
SELECT pg_temp.expect_error($q$SELECT pg_temp.scan_add('epsych_files/data', 'report')$q$,
                            'cannot be searched: scan directory [0-9]+ \(epsych_files/Data\)');
DO $$
DECLARE v_state text; v_hint text;
BEGIN
    BEGIN
        PERFORM pg_temp.scan_add('epsych_files/Data/inner');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_hint = PG_EXCEPTION_HINT;
    END;
    PERFORM pg_temp.assert(v_state = '23P01' AND v_hint ~ 'Turn one of them off',
                           'an overlap is an exclusion_violation with a HINT');
END;
$$;
-- Not nested: siblings whose names only start the same, two paths that a
-- LIKE pattern would match because '_' is its wildcard (one that would lie
-- inside, one that would contain), and the same path on another root.
SELECT pg_temp.scan_add('epsych_files/Database');
SELECT pg_temp.scan_add('epsych_files/Dat');
SELECT pg_temp.scan_add('epsychXfiles/Data/SUBJ-ID-1');
SELECT pg_temp.scan_add('epsych_file_');
SELECT pg_temp.scan_add('epsych_files/Data/SUBJ-ID-1', 'register', 'nas-scan-2');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.scan_directory
      WHERE mode <> 'off' AND storage_root_id IN (pg_temp.scan_root(), pg_temp.scan_root('nas-scan-2'))) = 6,
    'siblings, paths that only a LIKE wildcard would match, and another root are not nested');
-- A directory that is 'off' takes no part, whichever of the two it is; it
-- cannot be turned on while the other is.
SELECT pg_temp.scan_add('epsych_files/Data/SUBJ-ID-2', 'off');
SELECT pg_temp.scan_add('EPSYCH_FILES/DATA', 'off');
SELECT pg_temp.scan_add('epsych_files', 'off');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET mode = 'report'
    WHERE scan_directory_id = pg_temp.scan_dir('epsych_files/Data/SUBJ-ID-2')$q$,
    '\(epsych_files/Data\) is the same directory, contains it or lies inside it');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET mode = 'register'
    WHERE scan_directory_id = pg_temp.scan_dir('EPSYCH_FILES/DATA')$q$, '\(epsych_files/Data\) is the same');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET mode = 'register'
    WHERE scan_directory_id = pg_temp.scan_dir('epsych_files')$q$, '\(epsych_files/Data\) is the same');
-- Moving a searched directory into another is refused like adding it there.
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET relative_path = 'epsych_files/Data/moved'
    WHERE scan_directory_id = pg_temp.scan_dir('epsych_files/Dat')$q$, '\(epsych_files/Data\) is the same');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET storage_root_id = pg_temp.scan_root()
    WHERE scan_directory_id = pg_temp.scan_dir('epsych_files/Data/SUBJ-ID-1', 'nas-scan-2')$q$,
    '\(epsych_files/Data\) is the same');
-- Replacing a directory: turn it off, and the inner one can be turned on.
UPDATE lab.scan_directory SET mode = 'off' WHERE scan_directory_id = pg_temp.scan_dir('epsych_files/Data');
UPDATE lab.scan_directory SET mode = 'report'
WHERE scan_directory_id = pg_temp.scan_dir('epsych_files/Data/SUBJ-ID-2');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET mode = 'report'
    WHERE scan_directory_id = pg_temp.scan_dir('epsych_files/Data')$q$,
    '\(epsych_files/Data/SUBJ-ID-2\) is the same');
UPDATE lab.scan_directory SET mode = 'off'
WHERE scan_directory_id = pg_temp.scan_dir('epsych_files/Data/SUBJ-ID-2');
UPDATE lab.scan_directory SET mode = 'report' WHERE scan_directory_id = pg_temp.scan_dir('epsych_files/Data');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity() WHERE check_name = 'scan_directory_overlap'),
    'the list the policy accepted has no overlap to report');

-- pair_with names another directory on the same storage root.
SELECT pg_temp.scan_add('intan_files/Data');
UPDATE lab.scan_directory SET pair_with = pg_temp.scan_dir('epsych_files/Data'), layout = 'intan'
WHERE scan_directory_id = pg_temp.scan_dir('intan_files/Data');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET pair_with = scan_directory_id
    WHERE scan_directory_id = pg_temp.scan_dir('intan_files/Data')$q$, 'scan_directory_pair_ck');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory
    SET pair_with = pg_temp.scan_dir('epsych_files/Data/SUBJ-ID-1', 'nas-scan-2')
    WHERE scan_directory_id = pg_temp.scan_dir('intan_files/Data')$q$, 'scan_directory_pair_fk');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET pair_with = -1
    WHERE scan_directory_id = pg_temp.scan_dir('intan_files/Data')$q$, 'scan_directory_pair_fk');
SELECT pg_temp.expect_error($q$DELETE FROM lab.scan_directory
    WHERE scan_directory_id = pg_temp.scan_dir('epsych_files/Data')$q$, 'scan_directory_pair_fk');

-- ---------------------------------------------------------------------------
-- Edits are recorded; what a run was made under is frozen by the run
-- ---------------------------------------------------------------------------
-- Before its first run every setting of a directory can change.
SELECT pg_temp.scan_add('before-run/a');
UPDATE lab.scan_directory
   SET relative_path = 'before-run\b', layout = 'intan', time_zone = 'UTC',
       storage_root_id = pg_temp.scan_root('nas-scan-2')
 WHERE scan_directory_id = pg_temp.scan_dir('before-run/a');
UPDATE lab.scan_directory SET notes = NULL                       -- no-op: not logged
 WHERE scan_directory_id = pg_temp.scan_dir('before-run/b', 'nas-scan-2');
SELECT pg_temp.assert(
    (SELECT count(*) || '|' || min(operation) || '|' || min(old_row ->> 'relative_path') || '>'
            || min(new_row ->> 'relative_path') || '|' || min(changed_by)
     FROM lab.row_history
     WHERE table_name = 'scan_directory'
       AND row_key = jsonb_build_object('scan_directory_id', pg_temp.scan_dir('before-run/b', 'nas-scan-2')))
    = '1|UPDATE|before-run/a>before-run/b|' || session_user,
    'before its first run a directory''s root, path, layout and zone can change; the edit '
    'is in row_history, a no-op is not');
-- The key and the creator never change, run or no run.
SELECT pg_temp.expect_error(format($q$UPDATE lab.scan_directory SET %s
    WHERE scan_directory_id = pg_temp.scan_dir('before-run/b', 'nas-scan-2')$q$, v.assignment),
    'never change')
FROM (VALUES ('created_at = now() + interval ''1 day'''), ('created_by = NULL'),
             ('created_login = ''someone_else'''), ('scan_directory_id = DEFAULT')) AS v(assignment);
-- A directory with no run can be deleted, and the deletion is recorded.
DELETE FROM lab.scan_directory WHERE scan_directory_id = pg_temp.scan_dir('before-run/b', 'nas-scan-2');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.row_history
      WHERE table_name = 'scan_directory' AND operation = 'DELETE'
        AND old_row ->> 'relative_path' = 'before-run/b') = 1,
    'deleting a directory that was never searched is recorded in row_history');
UPDATE lab.scan_layout SET label = 'Intan RHX (traditional format)' WHERE code = 'intan';
SELECT pg_temp.assert(
    (SELECT row_key ->> 'code' FROM lab.row_history WHERE table_name = 'scan_layout') = 'intan',
    'an edit of a layout is recorded in row_history');

-- A run, even one with no result yet, freezes root, path, layout and zone.
SELECT pg_temp.scan_add('frozen/Data');
INSERT INTO lab.scan_run (scan_directory_id, command, mode, run_login, host, tool_version)
VALUES (pg_temp.scan_dir('frozen/Data'), 'apply', 'report', 'someone_else', 'rig3-pc', '1.0.0');
SELECT pg_temp.assert(
    (SELECT run_login || '|' || (due_at IS NULL) || '|' || (started_at >= now())
     FROM lab.scan_run WHERE scan_directory_id = pg_temp.scan_dir('frozen/Data'))
    = session_user || '|true|true'
    AND NOT EXISTS (SELECT 1 FROM lab.scan_run WHERE run_login IS DISTINCT FROM session_user)
    AND NOT EXISTS (SELECT 1 FROM lab.scan_directory WHERE created_login IS DISTINCT FROM session_user),
    'run_login and created_login hold session_user whatever the client sends; started_at is '
    'the database clock');
SELECT pg_temp.expect_error(format($q$UPDATE lab.scan_directory SET %s
    WHERE scan_directory_id = pg_temp.scan_dir('frozen/Data')$q$, v.assignment),
    'has been searched: its storage root, path, layout and time zone can no longer change')
FROM (VALUES ('relative_path = ''frozen/Elsewhere'''), ('relative_path = ''FROZEN/DATA'''),
             ('layout = ''intan'''), ('time_zone = ''UTC'''),
             ('storage_root_id = pg_temp.scan_root(''nas-scan-2'')')) AS v(assignment);
-- Everything else stays editable, and writing a frozen column unchanged (or
-- in a spelling the normalisation undoes) is no change.
UPDATE lab.scan_directory
   SET rig = 'RIG3', notes = 'edited after a run', scan_interval_min = 60, min_age_min = 30,
       window_start = '22:00', window_end = '06:00', mode = 'off', pair_with = NULL,
       relative_path = 'frozen\Data', layout = 'epsych', time_zone = 'America/New_York'
 WHERE scan_directory_id = pg_temp.scan_dir('frozen/Data');
SELECT pg_temp.assert(
    (SELECT rig || '|' || scan_interval_min || '|' || min_age_min || '|' || window_start || '|' || mode
     FROM lab.scan_directory WHERE scan_directory_id = pg_temp.scan_dir('frozen/Data'))
    = 'RIG3|60|30|22:00:00|off',
    'after a run the other settings of a directory can still be edited');
SELECT pg_temp.expect_error($q$DELETE FROM lab.scan_directory
    WHERE scan_directory_id = pg_temp.scan_dir('frozen/Data')$q$, 'scan_run_scan_directory_id_fkey');
-- Replaced, as the HINT says: turned off, and another added at the new path.
SELECT pg_temp.scan_add('frozen/Elsewhere');

-- mode_changed_at is the database's: the time the row was added, whatever
-- the client sends, and then the time of each change of mode.
INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                scan_interval_min, mode, mode_changed_at)
VALUES (pg_temp.scan_root(), 'mode/changes', 'epsych', 'UTC', 60, 'off', '2000-01-01 00:00Z');
SELECT pg_temp.assert(
    (SELECT mode_changed_at = now() AND created_at = now() FROM lab.scan_directory
      WHERE scan_directory_id = pg_temp.scan_dir('mode/changes'))
    AND NOT EXISTS (SELECT 1 FROM lab.scan_directory WHERE mode_changed_at <> now()),
    'mode_changed_at is the time the row was added, whatever the client sends');
-- As if the row had been added on 1 May 2026.
SELECT pg_temp.scan_mode_changed('mode/changes', '2026-05-01 00:00Z');
-- An edit that leaves mode alone leaves it, also when it writes mode again;
-- a client cannot set it.
UPDATE lab.scan_directory SET notes = 'edited', scan_interval_min = 30, mode = 'off'
WHERE scan_directory_id = pg_temp.scan_dir('mode/changes');
SELECT pg_temp.assert(
    (SELECT mode_changed_at = '2026-05-01 00:00Z' AND notes = 'edited' FROM lab.scan_directory
      WHERE scan_directory_id = pg_temp.scan_dir('mode/changes')),
    'an edit that does not change mode leaves mode_changed_at');
SELECT pg_temp.expect_error(format($q$UPDATE lab.scan_directory SET %s
    WHERE scan_directory_id = pg_temp.scan_dir('mode/changes')$q$, v.assignment),
    'mode_changed_at is kept by the database and cannot be set')
FROM (VALUES ('mode_changed_at = now()'), ('mode_changed_at = ''2000-01-01 00:00Z'', notes = ''x'''),
             ('mode_changed_at = DEFAULT')) AS v(assignment);
-- A change of mode sets it, again whatever the client sends, and the edit is
-- in row_history with both times.
UPDATE lab.scan_directory SET mode = 'report', mode_changed_at = '2000-01-01 00:00Z'
WHERE scan_directory_id = pg_temp.scan_dir('mode/changes');
SELECT pg_temp.assert(
    (SELECT mode_changed_at = now() AND mode = 'report' FROM lab.scan_directory
      WHERE scan_directory_id = pg_temp.scan_dir('mode/changes'))
    AND (SELECT (h.old_row ->> 'mode') || '>' || (h.new_row ->> 'mode') || '|'
                || ((h.old_row ->> 'mode_changed_at')::timestamptz = '2026-05-01 00:00Z') || '|'
                || ((h.new_row ->> 'mode_changed_at')::timestamptz = now())
         FROM lab.row_history h
         WHERE h.table_name = 'scan_directory'
           AND h.row_key = jsonb_build_object('scan_directory_id', pg_temp.scan_dir('mode/changes'))
         ORDER BY h.history_id DESC LIMIT 1) = 'off>report|true|true',
    'a change of mode sets mode_changed_at to now, whatever the client sends; the edit is '
    'in row_history');
SELECT pg_temp.scan_mode_changed('mode/changes', '2026-05-01 00:00Z');
UPDATE lab.scan_directory SET mode = 'register'
WHERE scan_directory_id = pg_temp.scan_dir('mode/changes');
UPDATE lab.scan_directory SET mode = 'off'
WHERE scan_directory_id = pg_temp.scan_dir('mode/changes');
SELECT pg_temp.assert(
    (SELECT mode_changed_at = now() FROM lab.scan_directory
      WHERE scan_directory_id = pg_temp.scan_dir('mode/changes')),
    'every change of mode sets mode_changed_at: report to register, and to off');

-- ---------------------------------------------------------------------------
-- Runs and results: what their columns accept
-- ---------------------------------------------------------------------------
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_run (scan_directory_id, command, mode)
    VALUES (pg_temp.scan_dir('frozen/Data'), 'scan', 'report')$q$, 'scan_run_command_ck');
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_run (scan_directory_id, command, mode)
    VALUES (pg_temp.scan_dir('frozen/Data'), 'run', 'off')$q$, 'scan_run_mode_ck');
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_run (scan_directory_id, command, mode)
    VALUES (-1, 'run', 'report')$q$, 'scan_run_scan_directory_id_fkey');
-- Only a 'run' answers a scheduled time, and never one that has not come.
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_run (scan_directory_id, command, mode, due_at)
    VALUES (pg_temp.scan_dir('frozen/Data'), 'apply', 'report', now())$q$, 'scan_run_due_ck');
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_run (scan_directory_id, command, mode, due_at)
    VALUES (pg_temp.scan_dir('frozen/Data'), 'run', 'report', now() + interval '1 hour')$q$,
    'scan_run_due_ck');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.scan_run (scan_directory_id, command, mode, due_at, started_at)
    VALUES (pg_temp.scan_dir('frozen/Data'), 'run', 'report', '2026-06-01 02:00:01Z', '2026-06-01 02:00Z')$q$,
    'scan_run_due_ck');
INSERT INTO lab.scan_run (scan_directory_id, command, mode, due_at)
VALUES (pg_temp.scan_dir('frozen/Data'), 'run', 'report', now());

SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_run_result (scan_run_id, outcome)
    SELECT max(scan_run_id), 'done' FROM lab.scan_run$q$, 'scan_run_result_outcome_ck');
SELECT pg_temp.expect_error(format($q$INSERT INTO lab.scan_run_result (scan_run_id, outcome, %I)
    SELECT max(scan_run_id), 'ok', -1 FROM lab.scan_run$q$, v.counter), 'scan_run_result_counts_ck')
FROM (VALUES ('files_listed'), ('files_unchanged'), ('files_pending'), ('files_registered'),
             ('files_known'), ('files_held'), ('files_ignored'), ('files_cleared'),
             ('groups_registered'), ('groups_waiting'), ('groups_held'), ('bytes_read')) AS v(counter);
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_run_result (scan_run_id, outcome, details)
    SELECT max(scan_run_id), 'ok', '[1, 2]' FROM lab.scan_run$q$, 'scan_run_result_details_object_ck');
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_run_result (scan_run_id, outcome)
    VALUES (-1, 'ok')$q$, 'scan_run_result_scan_run_id_fkey');
INSERT INTO lab.scan_run_result (scan_run_id, outcome, files_listed, bytes_read, message, details)
SELECT max(scan_run_id), 'unreachable', 0, 5000000000, 'the directory is empty', '{"skipped_roots": 0}'
FROM lab.scan_run;
SELECT pg_temp.assert(
    (SELECT x.finished_at >= r.started_at AND x.files_held = 0 AND x.bytes_read = 5000000000
     FROM lab.scan_run_result x JOIN lab.scan_run r USING (scan_run_id)
     WHERE x.outcome = 'unreachable'),
    'a result: counters default to 0, bytes_read is a bigint, finished_at is the database clock');
-- A run ends once.
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_run_result (scan_run_id, outcome)
    SELECT max(scan_run_id), 'ok' FROM lab.scan_run$q$, 'scan_run_result_pkey');

-- ---------------------------------------------------------------------------
-- The schedule, at fixed instants (lab.fn_scan_status)
-- ---------------------------------------------------------------------------
-- A daily search with no window, listed on 1 June 2026 at 02:00 UTC.
INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                scan_interval_min, mode, created_at)
VALUES (pg_temp.scan_root(), 'sched/daily', 'epsych', 'America/New_York', 1440, 'register',
        '2026-06-01 02:00Z');
SELECT pg_temp.scan_mode_changed('sched/daily', '2026-06-01 02:00Z');

-- Never searched: due from the moment it was listed; overdue one interval
-- and 26 hours after that, and not a second before.
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-06-01 02:00Z' AND NOT s.is_due AND NOT s.is_overdue AND NOT s.is_running
            AND s.window_open AND s.last_run_id IS NULL AND s.last_ok_run_id IS NULL
            AND s.window_start_text IS NULL AND s.window_end_text IS NULL
            AND s.storage_root = 'nas-scan' AND s.scan_interval_min = 1440
            AND s.mode = 'register' AND s.mode_changed_at = '2026-06-01 02:00Z'
            AND s.n_pending = 0 AND s.n_held = 0
     FROM pg_temp.sched('sched/daily', '2026-06-01 01:59:59Z') s),
    'never searched: due_at is created_at, and before it nothing is due');
SELECT pg_temp.assert(
    (SELECT s.is_due AND s.due_at = '2026-06-01 02:00Z'
     FROM pg_temp.sched('sched/daily', '2026-06-01 02:00Z') s)
    AND (SELECT s.is_due AND NOT s.is_overdue AND s.due_at = '2026-06-01 02:00Z'
         FROM pg_temp.sched('sched/daily', '2026-06-03 04:00Z') s)
    AND (SELECT s.is_due AND s.is_overdue AND s.due_at = '2026-06-01 02:00Z'
         FROM pg_temp.sched('sched/daily', '2026-06-03 04:00:01Z') s),
    'never searched: due at created_at, overdue after created_at + interval + 26 h');

-- After 'ok': the next is that run's due_at plus the interval, whenever the
-- run actually started and ended. Two daily runs, each started late, keep
-- the time of day.
SELECT pg_temp.scan_ran('sched/daily', '2026-06-01 02:00Z', '2026-06-01 02:07Z', 'ok', '2026-06-01 02:31Z')
       AS sched_run1 \gset
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-06-02 02:00Z' AND NOT s.is_due AND NOT s.is_overdue
            AND s.last_run_id = :sched_run1 AND s.last_run_command = 'run'
            AND s.last_run_mode = 'register' AND s.last_run_outcome = 'ok'
            AND s.last_run_started_at = '2026-06-01 02:07Z'
            AND s.last_run_finished_at = '2026-06-01 02:31Z'
            AND s.last_ok_run_id = :sched_run1 AND s.last_ok_due_at = '2026-06-01 02:00Z'
            AND s.last_ok_finished_at = '2026-06-01 02:31Z'
     FROM pg_temp.sched('sched/daily', '2026-06-02 01:59:59Z') s)
    AND (SELECT s.is_due AND s.due_at = '2026-06-02 02:00Z'
         FROM pg_temp.sched('sched/daily', '2026-06-02 02:14Z') s),
    'after ok: due one interval after the run''s due_at, not after its start or end');
SELECT pg_temp.scan_ran('sched/daily', '2026-06-02 02:00Z', '2026-06-02 02:14Z', 'ok', '2026-06-02 02:40Z')
       AS sched_run2 \gset
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-06-03 02:00Z' AND NOT s.is_due AND s.last_ok_run_id = :sched_run2
     FROM pg_temp.sched('sched/daily', '2026-06-02 12:00Z') s),
    'anchored: two daily runs that each started late are due at the same time of day');

-- A run made by hand (no due_at) is the latest run but never moves the
-- schedule, whatever its outcome.
SELECT pg_temp.scan_ran('sched/daily', NULL, '2026-06-02 10:00Z', 'ok', '2026-06-02 10:20Z', 'apply')
       AS sched_hand1 \gset
SELECT pg_temp.scan_ran('sched/daily', NULL, '2026-06-02 11:00Z', 'failed', '2026-06-02 11:01Z')
       AS sched_hand2 \gset
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-06-03 02:00Z' AND NOT s.is_due
            AND s.last_run_id = :sched_hand2 AND s.last_run_outcome = 'failed'
            AND s.last_ok_run_id = :sched_run2 AND s.last_ok_due_at = '2026-06-02 02:00Z'
     FROM pg_temp.sched('sched/daily', '2026-06-02 12:00Z') s),
    'a run with no due_at does not move the schedule and is not the last ok scheduled run');

-- Far behind: when the next due time is more than one interval before now,
-- one search is owed, now. The overdue flag keeps counting from the last ok
-- search: it is raised although due_at has moved up to now.
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-06-03 02:00Z' AND s.is_due AND NOT s.is_overdue
     FROM pg_temp.sched('sched/daily', '2026-06-04 02:00Z') s)
    AND (SELECT s.due_at = '2026-06-04 02:00:01Z' AND s.is_due AND NOT s.is_overdue
         FROM pg_temp.sched('sched/daily', '2026-06-04 02:00:01Z') s)
    AND (SELECT s.due_at = '2026-06-05 04:00Z' AND s.is_due AND NOT s.is_overdue
         FROM pg_temp.sched('sched/daily', '2026-06-05 04:00Z') s)
    AND (SELECT s.due_at = '2026-06-05 04:00:01Z' AND s.is_due AND s.is_overdue
         FROM pg_temp.sched('sched/daily', '2026-06-05 04:00:01Z') s)
    AND (SELECT s.due_at = '2026-07-01 00:00Z' AND s.is_due AND s.is_overdue
         FROM pg_temp.sched('sched/daily', '2026-07-01 00:00Z') s),
    'far behind: due_at moves up to now once it is more than one interval back; overdue '
    'is counted from the last ok search, interval + 26 h after one was due');

-- After 'partial': the rest is due at once. The last ok search stays the one
-- before.
SELECT pg_temp.scan_ran('sched/daily', '2026-06-03 02:00Z', '2026-06-03 02:05Z', 'partial', '2026-06-03 03:00Z')
       AS sched_run3 \gset
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-06-03 03:00:30Z' AND s.is_due AND NOT s.is_overdue
            AND s.last_run_outcome = 'partial' AND s.last_ok_run_id = :sched_run2
     FROM pg_temp.sched('sched/daily', '2026-06-03 03:00:30Z') s)
    AND (SELECT s.due_at = '2026-06-04 12:00Z' AND s.is_due
         FROM pg_temp.sched('sched/daily', '2026-06-04 12:00Z') s),
    'after partial: due at once, at whatever instant it is asked');

-- After 'failed' or 'unreachable': again after the interval or 60 minutes,
-- whichever is shorter, counted from the end of the failed run.
SELECT pg_temp.scan_ran('sched/daily', '2026-06-03 03:00:30Z', '2026-06-03 03:00:40Z', 'failed',
                        '2026-06-03 03:10Z') AS sched_run4 \gset
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-06-03 04:10Z' AND NOT s.is_due AND s.last_run_outcome = 'failed'
            AND s.last_ok_run_id = :sched_run2
     FROM pg_temp.sched('sched/daily', '2026-06-03 04:09:59Z') s)
    AND (SELECT s.due_at = '2026-06-03 04:10Z' AND s.is_due
         FROM pg_temp.sched('sched/daily', '2026-06-03 04:10Z') s),
    'after failed: due 60 minutes after the run ended when the interval is longer');
SELECT pg_temp.scan_ran('sched/daily', '2026-06-03 04:10Z', '2026-06-03 04:15Z', 'unreachable',
                        '2026-06-03 04:15:20Z') AS sched_run5 \gset
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-06-03 05:15:20Z' AND NOT s.is_due
     FROM pg_temp.sched('sched/daily', '2026-06-03 05:00Z') s),
    'after unreachable: the same wait as after failed');
-- A directory searched every 15 minutes waits 15, not 60.
INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                scan_interval_min, mode, created_at)
VALUES (pg_temp.scan_root(), 'sched/often', 'epsych', 'UTC', 15, 'report', '2026-06-01 00:00Z');
SELECT pg_temp.scan_ran('sched/often', '2026-06-01 00:00Z', '2026-06-01 00:01Z', 'failed', '2026-06-01 00:02Z');
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-06-01 00:17Z' AND NOT s.is_due
     FROM pg_temp.sched('sched/often', '2026-06-01 00:16:59Z') s)
    AND (SELECT s.is_due FROM pg_temp.sched('sched/often', '2026-06-01 00:17Z') s),
    'after failed: due one interval after the run ended when the interval is under 60 minutes');
-- Searches that fail do not keep the directory from being overdue: that is
-- counted from the last ok search (run 2, due 2 June 02:00, so the next was
-- due on the 3rd at 02:00), not from due_at, which every failure moves.
SELECT pg_temp.assert(
    (SELECT NOT s.is_overdue FROM pg_temp.sched('sched/daily', '2026-06-05 04:00Z') s)
    AND (SELECT s.is_overdue AND s.is_due AND s.due_at = '2026-06-03 05:15:20Z'
         FROM pg_temp.sched('sched/daily', '2026-06-05 04:00:01Z') s),
    'overdue is counted from the last ok search, so failing searches do not hide it');

-- A run with no result is running, for 24 hours; it does not count for the
-- schedule, so the directory stays as due as it was.
SELECT pg_temp.scan_ran('sched/daily', '2026-06-03 05:15:20Z', '2026-06-03 05:20Z') AS sched_run6 \gset
SELECT pg_temp.assert(
    (SELECT s.is_running AND s.is_due AND s.due_at = '2026-06-03 05:15:20Z'
            AND s.last_run_id = :sched_run6 AND s.last_run_started_at = '2026-06-03 05:20Z'
            AND s.last_run_outcome IS NULL AND s.last_run_finished_at IS NULL
     FROM pg_temp.sched('sched/daily', '2026-06-03 06:00Z') s)
    AND (SELECT s.is_running FROM pg_temp.sched('sched/daily', '2026-06-04 05:19:59Z') s)
    AND (SELECT NOT s.is_running AND s.is_due FROM pg_temp.sched('sched/daily', '2026-06-04 05:20Z') s),
    'a run with no result is running for 24 hours and leaves the directory due');
-- Its result, when it comes, counts: the schedule is anchored again.
INSERT INTO lab.scan_run_result (scan_run_id, outcome, finished_at)
VALUES (:sched_run6, 'ok', '2026-06-03 05:45Z');
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-06-04 05:15:20Z' AND NOT s.is_due AND NOT s.is_running
            AND NOT s.is_overdue AND s.last_ok_run_id = :sched_run6
     FROM pg_temp.sched('sched/daily', '2026-06-03 06:00Z') s),
    'the result of a run moves the schedule when it is written');

-- 'off': never due and never overdue, however long ago. Back on, a search is
-- owed at once, but the directory is not overdue for the time it was off:
-- that is counted again from the change of mode (here as if made on
-- 1 September), one interval and 26 hours.
UPDATE lab.scan_directory SET mode = 'off' WHERE scan_directory_id = pg_temp.scan_dir('sched/daily');
SELECT pg_temp.assert(
    (SELECT NOT s.is_due AND NOT s.is_overdue AND s.mode = 'off' AND s.due_at = '2026-09-01 00:00Z'
            AND s.mode_changed_at = now()
     FROM pg_temp.sched('sched/daily', '2026-09-01 00:00Z') s),
    'a directory that is off is neither due nor overdue');
UPDATE lab.scan_directory SET mode = 'report' WHERE scan_directory_id = pg_temp.scan_dir('sched/daily');
SELECT pg_temp.scan_mode_changed('sched/daily', '2026-09-01 00:00Z');
SELECT pg_temp.assert(
    (SELECT s.is_due AND NOT s.is_overdue AND s.due_at = '2026-09-01 00:00Z'
            AND s.mode_changed_at = '2026-09-01 00:00Z' AND s.last_ok_due_at = '2026-06-03 05:15:20Z'
     FROM pg_temp.sched('sched/daily', '2026-09-01 00:00Z') s)
    AND (SELECT s.is_due AND NOT s.is_overdue
         FROM pg_temp.sched('sched/daily', '2026-09-03 02:00Z') s)
    AND (SELECT s.is_due AND s.is_overdue
         FROM pg_temp.sched('sched/daily', '2026-09-03 02:00:01Z') s),
    'turned on again after a long time: due at once, and overdue only one interval and '
    '26 h after it was turned on');
-- The same for a directory that was listed 'off' and never searched: its
-- due_at is still created_at.
INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                scan_interval_min, mode, created_at)
VALUES (pg_temp.scan_root(), 'sched/late', 'epsych', 'UTC', 1440, 'off', '2026-01-01 00:00Z');
SELECT pg_temp.scan_mode_changed('sched/late', '2026-01-01 00:00Z');
SELECT pg_temp.assert(
    (SELECT NOT s.is_due AND NOT s.is_overdue AND s.due_at = '2026-01-01 00:00Z'
     FROM pg_temp.sched('sched/late', '2026-08-31 00:00Z') s),
    'listed off: neither due nor overdue, however long');
UPDATE lab.scan_directory SET mode = 'register' WHERE scan_directory_id = pg_temp.scan_dir('sched/late');
SELECT pg_temp.assert(
    (SELECT mode_changed_at = now() FROM lab.scan_directory
      WHERE scan_directory_id = pg_temp.scan_dir('sched/late')),
    'turning a directory on sets mode_changed_at');
SELECT pg_temp.scan_mode_changed('sched/late', '2026-09-01 00:00Z');
SELECT pg_temp.assert(
    (SELECT s.is_due AND NOT s.is_overdue AND s.due_at = '2026-01-01 00:00Z'
            AND s.mode_changed_at = '2026-09-01 00:00Z'
     FROM pg_temp.sched('sched/late', '2026-09-01 00:00Z') s)
    AND (SELECT s.is_due AND NOT s.is_overdue FROM pg_temp.sched('sched/late', '2026-09-03 02:00Z') s)
    AND (SELECT s.is_due AND s.is_overdue FROM pg_temp.sched('sched/late', '2026-09-03 02:00:01Z') s),
    'listed off and turned on long after: due at once, not overdue until one interval and '
    '26 h after it was turned on');
-- A shorter interval takes effect from the last scheduled run.
UPDATE lab.scan_directory SET scan_interval_min = 120
WHERE scan_directory_id = pg_temp.scan_dir('sched/daily');
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-06-03 07:15:20Z' AND NOT s.is_due AND s.scan_interval_min = 120
     FROM pg_temp.sched('sched/daily', '2026-06-03 07:00Z') s),
    'a changed interval is counted from the last scheduled run''s due_at');
UPDATE lab.scan_directory SET scan_interval_min = 1440
WHERE scan_directory_id = pg_temp.scan_dir('sched/daily');

-- ---------------------------------------------------------------------------
-- The window, in the directory's time zone
-- ---------------------------------------------------------------------------
-- 22:00 to 06:00 New York time: wraps midnight. In January New York is UTC-5.
INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                scan_interval_min, mode, created_at, window_start, window_end)
VALUES (pg_temp.scan_root(), 'sched/night', 'epsych', 'America/New_York', 1440, 'register',
        '2026-01-01 00:00Z', '22:00', '06:00');
SELECT pg_temp.assert(
    (SELECT NOT s.window_open AND NOT s.is_due AND s.due_at = '2026-01-01 00:00Z'
            AND s.window_start_text = '22:00' AND s.window_end_text = '06:00'
     FROM pg_temp.sched('sched/night', '2026-01-10 02:59:59Z') s)
    AND (SELECT s.window_open AND s.is_due FROM pg_temp.sched('sched/night', '2026-01-10 03:00Z') s)
    AND (SELECT s.window_open AND s.is_due FROM pg_temp.sched('sched/night', '2026-01-10 05:00Z') s)
    AND (SELECT s.window_open AND s.is_due FROM pg_temp.sched('sched/night', '2026-01-10 10:59:59Z') s)
    AND (SELECT NOT s.window_open AND NOT s.is_due FROM pg_temp.sched('sched/night', '2026-01-10 11:00Z') s)
    AND (SELECT NOT s.window_open AND NOT s.is_due FROM pg_temp.sched('sched/night', '2026-01-10 17:00Z') s),
    'a window that wraps midnight is open from its start to its end, [start, end), and a '
    'directory whose due time has passed waits for it');
SELECT pg_temp.assert(
    lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 03:00Z')
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 11:00Z')
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/daily'), '2026-01-10 11:00Z')
    AND lab.fn_scan_window_open(-1, '2026-01-10 11:00Z') IS NULL
    AND pg_temp.open_minutes('sched/night', '2026-01-10 00:00Z', '2026-01-11 00:00Z') = 480,
    'fn_scan_window_open: the window test alone; no window is always open; no directory, NULL');
-- In July New York is UTC-4: the same window, an hour earlier in UTC.
SELECT pg_temp.assert(
    NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-07-10 01:59:59Z')
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-07-10 02:00Z')
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-07-10 09:59:59Z')
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-07-10 10:00Z'),
    'the window follows the directory''s time zone through daylight saving');
-- 09:00 to 17:00: does not wrap. An end at 00:00 means "until midnight".
UPDATE lab.scan_directory SET window_start = '09:00', window_end = '17:00'
WHERE scan_directory_id = pg_temp.scan_dir('sched/night');
SELECT pg_temp.assert(
    NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 13:59:59Z')
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 14:00Z')
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 21:59:59Z')
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 22:00Z')
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 05:00Z'),
    'a window that does not wrap is open from its start to its end only');
UPDATE lab.scan_directory SET window_start = '22:30', window_end = '00:00'
WHERE scan_directory_id = pg_temp.scan_dir('sched/night');
SELECT pg_temp.assert(
    (SELECT s.window_start_text = '22:30' AND s.window_end_text = '00:00'
     FROM pg_temp.sched('sched/night', '2026-01-10 12:00Z') s)
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 03:29:59Z')
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 03:30Z')
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 04:59:59Z')
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 05:00Z')
    AND pg_temp.open_minutes('sched/night', '2026-01-10 00:00Z', '2026-01-11 00:00Z') = 90,
    'a window that ends at 00:00 is open until midnight');

-- Daylight saving in America/New_York, 2026. On 8 March the clocks go from
-- 02:00 to 03:00: a window inside the skipped hour does not open that day
-- (it does the day before), and one across it is open for the hours that
-- exist. The local day of 8 March is 23 hours long.
UPDATE lab.scan_directory SET window_start = '02:15', window_end = '02:45'
WHERE scan_directory_id = pg_temp.scan_dir('sched/night');
SELECT pg_temp.assert(
    pg_temp.open_minutes('sched/night', '2026-03-07 05:00Z', '2026-03-08 05:00Z') = 30
    AND pg_temp.open_minutes('sched/night', '2026-03-08 05:00Z', '2026-03-09 04:00Z') = 0
    AND pg_temp.open_minutes('sched/night', '2026-03-09 04:00Z', '2026-03-10 04:00Z') = 30
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-03-07 07:20Z')
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-03-08 07:20Z')
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-03-08 06:20Z')
    AND (SELECT NOT s.is_due AND NOT s.window_open
         FROM pg_temp.sched('sched/night', '2026-03-08 07:20Z') s),
    'spring forward: a window inside the skipped hour does not open that day');
UPDATE lab.scan_directory SET window_start = '01:30', window_end = '03:30'
WHERE scan_directory_id = pg_temp.scan_dir('sched/night');
SELECT pg_temp.assert(
    pg_temp.open_minutes('sched/night', '2026-03-07 05:00Z', '2026-03-08 05:00Z') = 120
    AND pg_temp.open_minutes('sched/night', '2026-03-08 05:00Z', '2026-03-09 04:00Z') = 60
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-03-08 06:29:59Z')
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-03-08 06:30Z')
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-03-08 07:29:59Z')
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-03-08 07:30Z'),
    'spring forward: a window across the skipped hour is open for the hours that exist');
-- On 1 November the clocks go from 02:00 back to 01:00: the hour from 01:00
-- comes twice, and a window inside it is open twice. The local day is 25
-- hours long.
UPDATE lab.scan_directory SET window_start = '01:15', window_end = '01:45'
WHERE scan_directory_id = pg_temp.scan_dir('sched/night');
SELECT pg_temp.assert(
    pg_temp.open_minutes('sched/night', '2026-10-31 04:00Z', '2026-11-01 04:00Z') = 30
    AND pg_temp.open_minutes('sched/night', '2026-11-01 04:00Z', '2026-11-02 05:00Z') = 60
    AND pg_temp.open_minutes('sched/night', '2026-11-02 05:00Z', '2026-11-03 05:00Z') = 30
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-11-01 05:30Z')
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-11-01 05:50Z')
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-11-01 06:10Z')
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-11-01 06:30Z')
    AND (SELECT s.is_due AND s.window_open FROM pg_temp.sched('sched/night', '2026-11-01 06:30Z') s),
    'fall back: a window inside the repeated hour is open twice that day');
UPDATE lab.scan_directory SET window_start = '22:00', window_end = '06:00'
WHERE scan_directory_id = pg_temp.scan_dir('sched/night');

-- The session's time zone changes nothing. A daily search whose last ok run
-- was due on 7 March at 03:30 New York time (08:30 UTC) is due 1440 minutes
-- later -- 08:30 UTC on the 8th, which is 04:30 on the wall clock there --
-- whatever zone the session is in; "one day later" in a session set to New
-- York would be 03:30 there, 07:30 UTC.
SELECT pg_temp.scan_ran('sched/night', '2026-03-07 08:30Z', '2026-03-07 08:31Z', 'ok', '2026-03-07 08:50Z');
SELECT current_setting('TimeZone') AS scan_tz_before \gset
SET LOCAL TimeZone = 'UTC';
CREATE TEMP TABLE scan_sched_utc AS
SELECT v.t AS asked_at, s.*
FROM (VALUES ('2026-01-10 02:59:59Z'::timestamptz), ('2026-01-10 03:00Z'), ('2026-03-08 06:59Z'),
             ('2026-03-08 07:30Z'), ('2026-03-08 08:29:59Z'), ('2026-03-08 08:30Z'),
             ('2026-06-03 04:10Z'),
             ('2026-06-05 04:00:01Z'), ('2026-11-01 05:30Z'), ('2026-11-01 06:30Z'),
             ('2026-11-02 12:00Z')) AS v(t)
CROSS JOIN LATERAL lab.fn_scan_status(v.t) s;
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-03-08 08:30Z' AND NOT s.is_due AND s.window_open
     FROM pg_temp.sched('sched/night', '2026-03-08 08:29:59Z') s)
    AND (SELECT s.is_due AND s.window_open FROM pg_temp.sched('sched/night', '2026-03-08 08:30Z') s),
    'a daily interval is 1440 minutes: across the spring change the next search is due at '
    'the same UTC time');
SET LOCAL TimeZone = 'America/New_York';
SELECT pg_temp.assert(
    (SELECT s.due_at = '2026-03-08 08:30Z' AND NOT s.is_due
     FROM pg_temp.sched('sched/night', '2026-03-08 08:29:59Z') s)
    AND (SELECT s.is_due FROM pg_temp.sched('sched/night', '2026-03-08 08:30Z') s)
    AND (SELECT count(*) FROM scan_sched_utc) >= 100
    AND NOT EXISTS (
        (SELECT * FROM scan_sched_utc
         EXCEPT
         SELECT v.asked_at, s.* FROM (SELECT DISTINCT asked_at FROM scan_sched_utc) v
         CROSS JOIN LATERAL lab.fn_scan_status(v.asked_at) s)
        UNION ALL
        (SELECT v.asked_at, s.* FROM (SELECT DISTINCT asked_at FROM scan_sched_utc) v
         CROSS JOIN LATERAL lab.fn_scan_status(v.asked_at) s
         EXCEPT
         SELECT * FROM scan_sched_utc)),
    'the schedule is the same with the session in America/New_York as in UTC');
SET LOCAL TimeZone = 'Pacific/Kiritimati';
SELECT pg_temp.assert(
    NOT EXISTS (
        (SELECT * FROM scan_sched_utc
         EXCEPT
         SELECT v.asked_at, s.* FROM (SELECT DISTINCT asked_at FROM scan_sched_utc) v
         CROSS JOIN LATERAL lab.fn_scan_status(v.asked_at) s)
        UNION ALL
        (SELECT v.asked_at, s.* FROM (SELECT DISTINCT asked_at FROM scan_sched_utc) v
         CROSS JOIN LATERAL lab.fn_scan_status(v.asked_at) s
         EXCEPT
         SELECT * FROM scan_sched_utc))
    AND NOT lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 02:59:59Z')
    AND lab.fn_scan_window_open(pg_temp.scan_dir('sched/night'), '2026-01-10 03:00Z'),
    'the schedule and the window are the same with the session 14 hours ahead of UTC');
SET LOCAL TimeZone = :'scan_tz_before';

-- What is due, the one longest due first; the view is the schedule now.
SELECT pg_temp.assert(
    (SELECT string_agg(f.relative_path, ',' ORDER BY f.ordinality)
     FROM lab.fn_scan_due('2026-06-03 06:30Z') WITH ORDINALITY AS f
     WHERE f.relative_path LIKE 'sched/%')
    = 'sched/late,sched/often,sched/night'
    AND NOT EXISTS (SELECT 1 FROM lab.fn_scan_due('2026-06-03 06:30Z') f WHERE NOT f.is_due)
    AND NOT EXISTS (SELECT 1 FROM lab.fn_scan_due('2026-06-03 06:30Z') f WHERE f.mode = 'off'),
    'fn_scan_due lists what is due at that instant, earliest due_at first: not what is '
    'off, not yet due, or outside its window');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.scan_directory_status) = (SELECT count(*) FROM lab.scan_directory)
    AND NOT EXISTS (SELECT * FROM lab.scan_directory_status
                    EXCEPT SELECT * FROM lab.fn_scan_status(now()))
    AND NOT EXISTS (SELECT * FROM lab.fn_scan_status(NULL)
                    EXCEPT SELECT * FROM lab.fn_scan_status())
    AND NOT EXISTS (SELECT * FROM lab.fn_scan_due()
                    EXCEPT SELECT * FROM lab.scan_directory_status WHERE is_due),
    'scan_directory_status is fn_scan_status at now(), one row per directory; no instant '
    'means now; fn_scan_due is its due rows');

-- ---------------------------------------------------------------------------
-- The scan memory (lab.scan_file, scan_file_latest, scan_held)
-- ---------------------------------------------------------------------------
-- A registered recording under intan_files/Data, to be named by the memory.
INSERT INTO lab.subject (subject_id, project_id) VALUES ('SC1', '00000000-0000-0000-0000-0000000000b1');
INSERT INTO lab.session (session_id, subject_id, label, storage_root_id, relative_path)
VALUES ('00000000-0000-0000-0000-00000005c001', 'SC1', 'SC1_260601_101500', pg_temp.scan_root(),
        'intan_files/Data/SC1/SC1_260601_101500');
INSERT INTO lab.event (event_id, event_type, session_id, occurred_at)
VALUES ('00000000-0000-0000-0000-00000005e001', 'recording',
        '00000000-0000-0000-0000-00000005c001', '2026-06-01 14:15Z');
INSERT INTO lab.recording_event (event_id) VALUES ('00000000-0000-0000-0000-00000005e001');
INSERT INTO lab.artifact (artifact_id, produced_by_event_id, storage_root_id, relative_path,
                          checksum, session_id)
VALUES ('00000000-0000-0000-0000-00000005a001', '00000000-0000-0000-0000-00000005e001',
        pg_temp.scan_root(), 'intan_files/Data/SC1/SC1_260601_101500/a.rhd', repeat('5a', 32),
        '00000000-0000-0000-0000-00000005c001'),
       ('00000000-0000-0000-0000-00000005a002', '00000000-0000-0000-0000-00000005e001',
        pg_temp.scan_root('nas-scan-2'), 'intan_files/Data/SC1/SC1_260601_101500/a.rhd', repeat('5b', 32),
        '00000000-0000-0000-0000-00000005c001');

-- First run: everything it sees is new. One file is held; one lies beside
-- the directory, at a path a LIKE wildcard would put inside it.
SELECT pg_temp.scan_ran('intan_files/Data', NULL, '2026-06-10 03:00Z', 'ok', '2026-06-10 03:05Z')
       AS mem_run1 \gset
INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns,
                           group_key, status, reason_code, reason)
VALUES (:mem_run1, pg_temp.scan_root(), ' intan_files\Data\SC1\SC1_260601_101500\a.rhd ', 1000,
        1780000000123456789, 'SC1_260601_101500', 'pending', NULL, NULL),
       (:mem_run1, pg_temp.scan_root(), 'intan_files/Data/SC1/SC1_260601_101500/b.rhd', 2000,
        1780000060123456789, 'SC1_260601_101500', 'pending', NULL, NULL),
       (:mem_run1, pg_temp.scan_root(), 'intan_files/Data/XX9/XX9_260601_120000/a.rhd', 0,
        1780000000000000001, 'XX9_260601_120000', 'held', 'unknown_subject', 'XX9 is not a subject'),
       (:mem_run1, pg_temp.scan_root(), 'INTAN_FILES/data/SC1/notes.txt', 12,
        1780000000000000002, NULL, 'held', 'unrecognised_file', NULL),
       (:mem_run1, pg_temp.scan_root(), 'intanXfiles/Data/SC1/c.rhd', 5, 5, NULL, 'pending', NULL, NULL),
       (:mem_run1, pg_temp.scan_root(), 'intan_files/Database/d.rhd', 6, 6, NULL, 'held', 'x', NULL),
       (:mem_run1, pg_temp.scan_root('nas-scan-2'), 'intan_files/Data/SC1/e.rhd', 7, 7, NULL,
        'pending', NULL, NULL);
SELECT pg_temp.assert(
    (SELECT relative_path || '|' || mtime_ns FROM lab.scan_file
      WHERE scan_run_id = :mem_run1 AND size_bytes = 1000)
    = 'intan_files/Data/SC1/SC1_260601_101500/a.rhd|1780000000123456789',
    'a memory row: path normalised like an artifact''s, mtime_ns kept to the nanosecond');
SELECT pg_temp.assert(
    (SELECT s.n_pending = 2 AND s.n_held = 2 FROM pg_temp.sched('intan_files/Data', now()) s)
    AND (SELECT s.n_pending = 0 AND s.n_held = 0 FROM pg_temp.sched('epsych_files/Data', now()) s),
    'n_pending and n_held count the latest rows under the directory on its root, without '
    'regard to case, and not a sibling path or one only a LIKE wildcard would match');

-- What a memory row may say.
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns,
                               status, reason_code, artifact_id)
    VALUES (%s, pg_temp.scan_root(), 'intan_files/Data/SC1/SC1_260601_101500/a.rhd', %s)$q$,
    :mem_run1, v.rest), v.pattern)
FROM (VALUES
    ('1, 1, ''seen'', NULL, NULL',                                             'scan_file_status_ck'),
    ('-1, 1, ''pending'', NULL, NULL',                                         'scan_file_size_ck'),
    ('NULL, 1, ''pending'', NULL, NULL',                                       'scan_file_listing_ck'),
    ('1, NULL, ''held'', ''x'', NULL',                                         'scan_file_listing_ck'),
    ('1, 1, ''held'', NULL, NULL',                                             'scan_file_held_ck'),
    ('1, 1, ''held'', ''  '', NULL',                                           'scan_file_held_ck'),
    ('1, 1, ''registered'', NULL, NULL',                                       'scan_file_artifact_ck'),
    ('1, 1, ''known'', NULL, NULL',                                            'scan_file_artifact_ck'),
    ('1, 1, ''pending'', NULL, ''00000000-0000-0000-0000-00000005a001''',      'scan_file_artifact_ck'),
    ('1, 1, ''held'', ''x'', ''00000000-0000-0000-0000-00000005a001''',        'scan_file_artifact_ck'),
    ('NULL, NULL, ''cleared'', NULL, ''00000000-0000-0000-0000-00000005a001''', 'scan_file_artifact_ck'),
    ('1, 1, ''registered'', NULL, ''00000000-0000-0000-0000-0000000000ff''',   'scan_file_artifact_fk')
    ) AS v(rest, pattern);
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns, status)
    VALUES (%s, pg_temp.scan_root(), %L, 1, 1, 'pending')$q$, :mem_run1, v.path), 'scan_file_path_ck')
FROM (VALUES (''), ('/abs/a.rhd'), ('S:/Data/a.rhd'), ('a/../b.rhd')) AS v(path);
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns, status)
    VALUES (-1, pg_temp.scan_root(), 'a.rhd', 1, 1, 'pending')$q$, 'scan_file_scan_run_id_fkey');
-- A 'registered' or 'known' row names an artifact at its own root and path:
-- not the artifact of another path, of the same path in another case, or of
-- the same path on another root.
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns,
                               status, artifact_id)
    VALUES (%s, pg_temp.scan_root(%L), %L, 1000, 1, %L, %L)$q$,
    :mem_run1, v.root, v.path, v.status, v.artifact), 'scan_file_artifact_fk')
FROM (VALUES
    ('nas-scan', 'intan_files/Data/SC1/SC1_260601_101500/b.rhd', 'registered',
     '00000000-0000-0000-0000-00000005a001'),
    ('nas-scan', 'intan_files/Data/SC1/SC1_260601_101500/A.rhd', 'known',
     '00000000-0000-0000-0000-00000005a001'),
    ('nas-scan-2', 'intan_files/Data/SC1/SC1_260601_101500/a.rhd', 'registered',
     '00000000-0000-0000-0000-00000005a001'),
    ('nas-scan', 'intan_files/Data/SC1/SC1_260601_101500/a.rhd', 'known',
     '00000000-0000-0000-0000-00000005a002')) AS v(root, path, status, artifact);

-- Second run, a day later: a.rhd is registered; b.rhd has grown and waits
-- again; the unknown subject's file changed and is still held for the same
-- reason; the text file is gone.
SELECT pg_temp.scan_ran('intan_files/Data', NULL, '2026-06-11 03:00Z', 'ok', '2026-06-11 03:05Z')
       AS mem_run2 \gset
INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns,
                           group_key, status, reason_code, reason, artifact_id)
VALUES (:mem_run2, pg_temp.scan_root(), 'intan_files/Data/SC1/SC1_260601_101500/a.rhd', 1000,
        1780000000123456789, 'SC1_260601_101500', 'registered', NULL, NULL,
        '00000000-0000-0000-0000-00000005a001'),
       (:mem_run2, pg_temp.scan_root(), 'intan_files/Data/SC1/SC1_260601_101500/b.rhd', 2500,
        1780090000123456789, 'SC1_260601_101500', 'pending', NULL, NULL, NULL),
       (:mem_run2, pg_temp.scan_root(), 'intan_files/Data/XX9/XX9_260601_120000/a.rhd', 64,
        1780090000000000001, 'XX9_260601_120000', 'held', 'unknown_subject', 'XX9 is not a subject', NULL),
       (:mem_run2, pg_temp.scan_root(), 'INTAN_FILES/data/SC1/notes.txt', NULL, NULL, NULL,
        'cleared', NULL, NULL, NULL);
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.scan_file_latest WHERE scan_run_id IN (:mem_run1, :mem_run2)) = 7
    AND (SELECT string_agg(status || ' ' || coalesce(size_bytes::text, '-'), ','
                           ORDER BY relative_path COLLATE "C")
         FROM lab.scan_file_latest
         WHERE storage_root_id = pg_temp.scan_root() AND lower(relative_path) LIKE 'intan\_files/data/%')
        = 'cleared -,registered 1000,pending 2500,held 64'
    AND (SELECT artifact_id FROM lab.scan_file_latest WHERE status = 'registered')
        = '00000000-0000-0000-0000-00000005a001',
    'scan_file_latest is the latest row per storage root and path, by insertion order');
SELECT pg_temp.assert(
    (SELECT s.n_pending = 1 AND s.n_held = 1 FROM pg_temp.sched('intan_files/Data', now()) s),
    'the counts follow the latest rows: a registered and a cleared file are counted no more');
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.scan_held WHERE storage_root = 'nas-scan') = 2
    AND (SELECT h.scan_directory_id = pg_temp.scan_dir('intan_files/Data')
                AND h.scan_run_id = :mem_run2 AND h.storage_root_id = pg_temp.scan_root()
                AND h.size_bytes = 64 AND h.mtime_ns = 1780090000000000001
                AND h.group_key = 'XX9_260601_120000' AND h.reason = 'XX9 is not a subject'
                AND h.held_at = '2026-06-11 03:00Z' AND h.first_held_at = '2026-06-10 03:00Z'
         FROM lab.scan_held h WHERE h.reason_code = 'unknown_subject')
    AND (SELECT h.first_held_at = '2026-06-10 03:00Z' AND h.held_at = '2026-06-10 03:00Z'
         FROM lab.scan_held h WHERE h.relative_path = 'intan_files/Database/d.rhd'),
    'scan_held: the latest rows that are held, with the directory of the run, the root''s '
    'name and when the file was first held for that reason');
-- A hold for another reason, or one that was lifted in between, starts again.
SELECT pg_temp.scan_ran('intan_files/Data', NULL, '2026-06-12 03:00Z', 'ok', '2026-06-12 03:05Z')
       AS mem_run3 \gset
INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns,
                           status, reason_code)
VALUES (:mem_run3, pg_temp.scan_root(), 'intan_files/Data/XX9/XX9_260601_120000/a.rhd', 64,
        1780090000000000001, 'held', 'mislabelled_folder'),
       (:mem_run3, pg_temp.scan_root(), 'intan_files/Database/d.rhd', 6, 6, 'pending', NULL);
SELECT pg_temp.scan_ran('intan_files/Data', NULL, '2026-06-13 03:00Z', 'ok', '2026-06-13 03:05Z')
       AS mem_run4 \gset
INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns,
                           status, reason_code)
VALUES (:mem_run4, pg_temp.scan_root(), 'intan_files/Database/d.rhd', 6, 6, 'held', 'x');
SELECT pg_temp.assert(
    (SELECT h.first_held_at = '2026-06-12 03:00Z' FROM lab.scan_held h
      WHERE h.reason_code = 'mislabelled_folder')
    AND (SELECT h.first_held_at = '2026-06-13 03:00Z' AND h.scan_run_id = :mem_run4
         FROM lab.scan_held h WHERE h.relative_path = 'intan_files/Database/d.rhd')
    AND NOT EXISTS (SELECT 1 FROM lab.scan_held h WHERE h.reason_code = 'unknown_subject'),
    'first_held_at starts again when the reason changes or the hold was lifted in between');

-- The memory is append-only, and so are the runs and their results.
SELECT pg_temp.expect_error('UPDATE lab.scan_file SET status = ''registered''', 'append-only log');
SELECT pg_temp.expect_error('DELETE FROM lab.scan_file', 'append-only log');
SELECT pg_temp.expect_error('TRUNCATE lab.scan_file', 'not allowed');
SELECT pg_temp.expect_error('UPDATE lab.scan_run SET due_at = NULL', 'append-only log');
SELECT pg_temp.expect_error('DELETE FROM lab.scan_run_result', 'append-only log');

-- Renaming the subject of a registered file leaves the memory as it is: it
-- holds no subject, and the key it refers to is not the subject's.
CREATE TEMP TABLE scan_file_before AS SELECT * FROM lab.scan_file;
SELECT lab.fn_rename_subject('SC1', 'SC1-renamed');
SELECT pg_temp.assert(
    (SELECT a.subject_id FROM lab.scan_file_latest l JOIN lab.artifact a USING (artifact_id)
      WHERE l.status = 'registered') = 'SC1-renamed'
    AND NOT EXISTS (SELECT * FROM scan_file_before EXCEPT SELECT * FROM lab.scan_file)
    AND NOT EXISTS (SELECT * FROM lab.scan_file EXCEPT SELECT * FROM scan_file_before),
    'a subject rename passes through the artifact a memory row names and changes no memory row');

-- ---------------------------------------------------------------------------
-- Integrity: an overlap that got past the trigger is reported
-- ---------------------------------------------------------------------------
ALTER TABLE lab.scan_directory DISABLE TRIGGER trg_scan_directory_policy;
SELECT pg_temp.scan_add('INTAN_FILES/data/SC1');
SELECT pg_temp.scan_add('intanXfiles/Data');
-- Equal paths are refused by the unique index, with or without the trigger.
SELECT pg_temp.expect_error($q$SELECT pg_temp.scan_add('Intan_Files/DATA')$q$, 'uq_scan_directory_path');
ALTER TABLE lab.scan_directory ENABLE TRIGGER trg_scan_directory_policy;
SELECT pg_temp.assert(
    (SELECT string_agg(severity || '|' || subject || '|' || detail, ';')
     FROM lab.fn_check_integrity() WHERE check_name = 'scan_directory_overlap')
    = format('warning|%s|directory intan_files/Data on storage root %s and scan directory %s '
             '(INTAN_FILES/data/SC1) are equal or nested',
             pg_temp.scan_dir('intan_files/Data'), pg_temp.scan_root(),
             pg_temp.scan_dir('INTAN_FILES/data/SC1')),
    'scan_directory_overlap reports a nested pair once, under the lower id, and nothing else');
-- The rows can still be edited apart: turning one off needs no check.
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET notes = 'x'
    WHERE scan_directory_id = pg_temp.scan_dir('INTAN_FILES/data/SC1')$q$, '\(intan_files/Data\) is the same');
UPDATE lab.scan_directory SET mode = 'off', notes = 'overlapped intan_files/Data'
WHERE scan_directory_id = pg_temp.scan_dir('INTAN_FILES/data/SC1');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity() WHERE check_name = 'scan_directory_overlap'),
    'with one of the two off the overlap is gone');

-- ---------------------------------------------------------------------------
-- Client metadata probes
-- ---------------------------------------------------------------------------
-- MATLAB's Database Toolbox learns a result's column types by first sending a
-- statement as "SELECT * FROM (<statement>) as temp LIMIT 0". Such a probe
-- around a call of a write function must write nothing.
CREATE TEMP TABLE probe_before AS
SELECT (SELECT count(*) FROM lab.variable_value) AS n_values,
       (SELECT count(*) FROM lab.variable)       AS n_variables,
       (SELECT count(*) FROM lab.tag_assignment) AS n_tags;
SELECT * FROM (SELECT lab.fn_set_variable('subject', 'G2-renamed', 'probe test', 1.0) AS value_id) as temp LIMIT 0;
SELECT * FROM (SELECT 1 AS ok FROM lab.fn_set_variable('subject', 'G2-renamed', 'probe test', 2.0)) as temp LIMIT 0;
SELECT * FROM (SELECT lab.fn_tag('subject', 'G2-renamed', 'topic:probe_test', 'add') AS assignment_id) as temp LIMIT 0;
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.variable_value) = (SELECT n_values FROM probe_before)
    AND (SELECT count(*) FROM lab.variable) = (SELECT n_variables FROM probe_before)
    AND (SELECT count(*) FROM lab.tag_assignment) = (SELECT n_tags FROM probe_before),
    'a LIMIT 0 probe around a write function writes nothing');

ROLLBACK;
\echo 'schema_test.sql: all assertions passed'
