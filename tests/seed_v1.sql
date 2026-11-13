-- ============================================================================
-- A small version-1 dataset, for testing the migrations on a database that
-- already holds rows
-- ============================================================================
-- Apply to a database built from the version-1 schema.sql (the commit named
-- by SCHEMA_V1_COMMIT in .github/workflows/tests.yml), BEFORE the scripts in
-- design_docs/migrations/. tests/migrated_data_test.sql then checks what the
-- migrations made of it. It deliberately contains what version 1 allowed and
-- later versions tightened: an upper-case checksum, a backslash path, and a
-- histology event with no subject.
-- ============================================================================
\set ON_ERROR_STOP 1
BEGIN;
INSERT INTO lab.person (person_id, full_name, email)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'Legacy Person', 'legacy@example.edu');
INSERT INTO lab.storage_root (name) VALUES ('nas-legacy');
INSERT INTO lab.project (project_id, name)
VALUES ('bbbbbbbb-0000-0000-0000-000000000001', 'legacy-project');
INSERT INTO lab.subject (subject_id, project_id, species_code, sex)
VALUES ('L-0001', 'bbbbbbbb-0000-0000-0000-000000000001', 'meriones_unguiculatus', 'M');
INSERT INTO lab.session (session_id, subject_id, label, storage_root_id, relative_path)
VALUES ('cccccccc-0000-0000-0000-000000000001', 'L-0001', 's1',
        (SELECT root_id FROM lab.storage_root WHERE name = 'nas-legacy'), 'L-0001\s1');

-- A recording, its raw file, and one verification of it.
INSERT INTO lab.event (event_id, event_type, subject_id, session_id, occurred_at, recorded_by)
VALUES ('11111111-0000-0000-0000-000000000001', 'recording', 'L-0001',
        'cccccccc-0000-0000-0000-000000000001', '2026-03-01 14:00+00',
        'aaaaaaaa-0000-0000-0000-000000000001');
INSERT INTO lab.recording_event (event_id, acquisition_system_code, sample_rate_hz, n_channels)
VALUES ('11111111-0000-0000-0000-000000000001', 'intan_rhx', 20000, 64);
INSERT INTO lab.artifact (artifact_id, produced_by_event_id, storage_root_id, relative_path,
                          checksum, role, session_id)
VALUES ('dddddddd-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
        (SELECT root_id FROM lab.storage_root WHERE name = 'nas-legacy'),
        'L-0001/s1/raw.dat', upper(repeat('ab', 32)), 'raw',
        'cccccccc-0000-0000-0000-000000000001');
INSERT INTO lab.artifact_verification (artifact_id, status)
VALUES ('dddddddd-0000-0000-0000-000000000001', 'ok');

-- An analysis that consumed it.
INSERT INTO lab.event (event_id, event_type, occurred_at)
VALUES ('11111111-0000-0000-0000-000000000002', 'analysis', '2026-03-02 09:00+00');
INSERT INTO lab.analysis_event (event_id, pipeline_name, status)
VALUES ('11111111-0000-0000-0000-000000000002', 'kilosort', 'succeeded');
INSERT INTO lab.event_input (event_id, artifact_id)
VALUES ('11111111-0000-0000-0000-000000000002', 'dddddddd-0000-0000-0000-000000000001');
INSERT INTO lab.artifact (artifact_id, produced_by_event_id, storage_root_id, relative_path,
                          checksum, role)
VALUES ('dddddddd-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000002',
        (SELECT root_id FROM lab.storage_root WHERE name = 'nas-legacy'),
        'L-0001/s1/spikes.npy', repeat('cd', 32), 'spikes');

-- A correction of the recording, made the version-1 way: the event only.
INSERT INTO lab.event (event_id, event_type, subject_id, session_id, occurred_at, supersedes)
VALUES ('11111111-0000-0000-0000-000000000003', 'recording', 'L-0001',
        'cccccccc-0000-0000-0000-000000000001', '2026-03-01 14:00+00',
        '11111111-0000-0000-0000-000000000001');
INSERT INTO lab.recording_event (event_id, acquisition_system_code, sample_rate_hz, n_channels)
VALUES ('11111111-0000-0000-0000-000000000003', 'intan_rhx', 30000, 64);

-- What version 1 allowed and version 2 forbids: an animal event with no animal.
INSERT INTO lab.event (event_id, event_type, occurred_at)
VALUES ('11111111-0000-0000-0000-000000000004', 'histology', '2026-03-03 11:00+00');
INSERT INTO lab.histology_event (event_id, technique)
VALUES ('11111111-0000-0000-0000-000000000004', 'nissl');
COMMIT;
