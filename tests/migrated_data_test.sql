-- ============================================================================
-- Assertions on a version-1 database with data, after every migration
-- ============================================================================
-- Run against a database built from the version-1 schema.sql, loaded with
-- tests/seed_v1.sql and then upgraded with every script in
-- design_docs/migrations/:
--
--     psql -X -v ON_ERROR_STOP=1 -d lab_migrated_data -f tests/migrated_data_test.sql
--
-- The fresh-install comparison in CI upgrades an EMPTY version-1 database; a
-- migration that is correct on empty tables can still fail, or quietly
-- rewrite history, on a database that holds rows. Every check raises on
-- failure; the run is one transaction, rolled back at the end.
-- ============================================================================

\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
SET client_min_messages = warning;
BEGIN;

CREATE FUNCTION pg_temp.assert(p_ok boolean, p_what text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok IS NOT TRUE THEN
        RAISE EXCEPTION 'ASSERTION FAILED: %', p_what;
    END IF;
END;
$$;

SELECT pg_temp.assert((SELECT max(version) FROM lab.schema_version) = 4,
                      'the migrated database is at schema version 4');

-- Nothing was lost.
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.event) = 4
    AND (SELECT count(*) FROM lab.recording_event) = 2
    AND (SELECT count(*) FROM lab.artifact) = 2
    AND (SELECT count(*) FROM lab.event_input) = 1
    AND (SELECT count(*) FROM lab.artifact_verification) = 1
    AND (SELECT count(*) FROM lab.subject) = 1
    AND (SELECT count(*) FROM lab.session) = 1,
    'every seeded row survived the migrations');

-- Values the later versions canonicalise were canonicalised, not dropped.
SELECT pg_temp.assert(
    (SELECT checksum FROM lab.artifact WHERE artifact_id = 'dddddddd-0000-0000-0000-000000000001')
        = repeat('ab', 32)
    AND (SELECT relative_path FROM lab.session) = 'L-0001/s1',
    'legacy checksum and path were normalised by migration 002');

-- Rows written before version 4 have no login, and are not given one.
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM lab.event WHERE recorded_login IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM lab.artifact WHERE created_login IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM lab.artifact_verification WHERE verified_login IS NOT NULL),
    'legacy rows keep a NULL login: the migration does not claim to know who wrote them');
SELECT pg_temp.assert(
    (SELECT occurred_at FROM lab.event WHERE event_id = '11111111-0000-0000-0000-000000000001')
        = '2026-03-01 14:00+00'
    AND (SELECT recorded_by FROM lab.event WHERE event_id = '11111111-0000-0000-0000-000000000001')
        = 'aaaaaaaa-0000-0000-0000-000000000001',
    'legacy event values are unchanged');

-- The legacy event with no subject keeps its constraint NOT VALID and is
-- reported, rather than blocking the upgrade.
SELECT pg_temp.assert(
    (SELECT NOT convalidated FROM pg_constraint
      WHERE conname = 'event_subject_required_ck' AND conrelid = 'lab.event'::regclass)
    AND EXISTS (SELECT 1 FROM lab.fn_check_integrity()
                WHERE check_name = 'event_missing_subject'
                  AND subject = '11111111-0000-0000-0000-000000000004'),
    'the subject-less legacy event is reported and its constraint left NOT VALID');

-- The version-1 correction left the raw file on the superseded recording.
-- That is still reported, and lineage now follows the correction anyway.
SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM lab.fn_check_integrity()
            WHERE check_name = 'artifact_producer_superseded'
              AND subject = 'dddddddd-0000-0000-0000-000000000001'),
    'the stranded legacy artifact is reported');
SELECT pg_temp.assert(
    (SELECT event_id FROM lab.fn_artifact_lineage('dddddddd-0000-0000-0000-000000000002', 'up')
      WHERE depth = 1) = '11111111-0000-0000-0000-000000000003'
    AND (SELECT event_id FROM lab.fn_artifact_lineage('dddddddd-0000-0000-0000-000000000002',
                                                      'up', false)
          WHERE depth = 1) = '11111111-0000-0000-0000-000000000001',
    'lineage resolves the legacy correction; the recorded rows are still reachable');
SELECT pg_temp.assert(
    (SELECT status FROM lab.artifact_verification_latest
      WHERE artifact_id = 'dddddddd-0000-0000-0000-000000000001') = 'ok',
    'the legacy verification is the file''s latest check');

-- New rows are written under the version-4 rules.
INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at)
VALUES ('11111111-0000-0000-0000-000000000005', 'husbandry', 'L-0001', now());
INSERT INTO lab.husbandry_event (event_id, measure, weight_g)
VALUES ('11111111-0000-0000-0000-000000000005', 'weight', 60.5);
SELECT pg_temp.assert(
    (SELECT recorded_login FROM lab.event WHERE event_id = '11111111-0000-0000-0000-000000000005')
        = session_user,
    'a row written after the migration carries the login');

ROLLBACK;
\echo 'migrated_data_test.sql: all assertions passed'
