-- ============================================================================
-- Role and privilege assertions for design_docs/grants.sql
-- ============================================================================
-- Run as a superuser against a database that has had schema.sql and then
-- grants.sql applied and holds NO DATA (a scratch database, never the lab's:
-- the assertions count rows and would fail, harmlessly, on one that has any):
--
--     psql -X -v ON_ERROR_STOP=1 -d lab_test -f tests/roles_test.sql
--
-- tests/schema_test.sql runs as the owner and so cannot see what a member of
-- lab_rw or lab_ro may do; this file checks exactly that, by creating
-- throw-away logins that inherit the two group roles and acting as them
-- (SET SESSION AUTHORIZATION, which also sets session_user). Every check
-- raises on failure. The whole run, the logins included, is one transaction
-- that is rolled back at the end.
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

-- Run p_sql in a subtransaction and require that it fails with a message
-- matching p_pattern. It runs with the privileges of the current role.
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
-- Logins and fixtures
-- ---------------------------------------------------------------------------
-- rt_member   a lab member: inherits lab_rw, nothing else.
-- rt_reader   the dashboard / MCP login: inherits lab_ro.
-- rt_legacy   a member whose grants predate pre-launch schema version 4:
--             table-level UPDATE on lab.subject, key column included.
-- rt_renamer  a delegated administrator: may run lab.fn_rename_subject, but
--             is neither the owner nor a superuser.
-- rt_scanner  the login the scheduled search for new files runs as: a member
--             that may also append to the scan logs.
-- rt_lister   a member the owner lets manage the list of directories to
--             search.
CREATE ROLE rt_member  LOGIN IN ROLE lab_rw;
CREATE ROLE rt_reader  LOGIN IN ROLE lab_ro;
CREATE ROLE rt_legacy  LOGIN IN ROLE lab_rw;
CREATE ROLE rt_renamer LOGIN IN ROLE lab_rw;
CREATE ROLE rt_scanner LOGIN IN ROLE lab_rw;
CREATE ROLE rt_lister  LOGIN IN ROLE lab_rw;
GRANT INSERT ON lab.scan_run, lab.scan_run_result, lab.scan_file TO rt_scanner;
GRANT INSERT, UPDATE ON lab.scan_directory TO rt_lister;
GRANT UPDATE ON lab.subject TO rt_legacy, rt_renamer;
GRANT EXECUTE ON FUNCTION lab.fn_rename_subject(text, text) TO rt_renamer;
GRANT INSERT ON lab.maintenance_log TO rt_renamer;

INSERT INTO lab.person (person_id, full_name, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'Member One', 'one@example.edu'),
    ('00000000-0000-0000-0000-0000000000a2', 'Member Two', 'two@example.edu');
INSERT INTO lab.project (project_id, name)
VALUES ('00000000-0000-0000-0000-0000000000b1', 'roles-test-project');
INSERT INTO lab.storage_root (name) VALUES ('nas-roles-test');
INSERT INTO lab.subject (subject_id, project_id) VALUES
    ('R1', '00000000-0000-0000-0000-0000000000b1'),
    ('R2', '00000000-0000-0000-0000-0000000000b1'),
    ('R3', '00000000-0000-0000-0000-0000000000b1');
INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at) VALUES
    ('00000000-0000-0000-0000-0000000000e1', 'husbandry', 'R1', now()),
    ('00000000-0000-0000-0000-0000000000e2', 'husbandry', 'R2', now()),
    ('00000000-0000-0000-0000-0000000000e3', 'husbandry', 'R3', now());
INSERT INTO lab.husbandry_event (event_id, measure, weight_g) VALUES
    ('00000000-0000-0000-0000-0000000000e1', 'weight', 60),
    ('00000000-0000-0000-0000-0000000000e2', 'weight', 61),
    ('00000000-0000-0000-0000-0000000000e3', 'weight', 62);
-- The administrator maps the member's login to their person row.
UPDATE lab.person SET db_login = 'rt_member'
WHERE person_id = '00000000-0000-0000-0000-0000000000a1';
-- A template in use for R2, so that the rename cascade below also runs
-- through lab.subject_form and its guard trigger.
SELECT version_number FROM lab.fn_publish_form('roles fixture',
    '{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "roles fixture value"}]}]}');
SELECT lab.fn_add_subject_form('R2', 'roles fixture') AS rt_fixture_sf \gset

-- ---------------------------------------------------------------------------
-- A lab member (lab_rw)
-- ---------------------------------------------------------------------------
SET SESSION AUTHORIZATION rt_member;

-- May append, tag, and edit the descriptive columns of a subject.
INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at, recorded_by, recorded_login)
VALUES ('00000000-0000-0000-0000-0000000000e4', 'husbandry', 'R1', now(),
        '00000000-0000-0000-0000-0000000000a2', 'someone_else');
INSERT INTO lab.husbandry_event (event_id, measure, weight_g)
VALUES ('00000000-0000-0000-0000-0000000000e4', 'weight', 63);
INSERT INTO lab.artifact (artifact_id, produced_by_event_id, storage_root_id, relative_path, checksum)
VALUES ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e4',
        (SELECT root_id FROM lab.storage_root WHERE name = 'nas-roles-test'),
        'R1/weights.csv', repeat('ab', 32));
INSERT INTO lab.artifact_verification (artifact_id, status)
VALUES ('00000000-0000-0000-0000-0000000000f1', 'ok');
SELECT lab.fn_tag('subject', 'R1', 'topic:roles_test');
UPDATE lab.subject SET notes = 'edited by a member', sex = 'F' WHERE subject_id = 'R1';
SELECT pg_temp.assert(
    (SELECT recorded_login FROM lab.event WHERE event_id = '00000000-0000-0000-0000-0000000000e4')
        = 'rt_member'
    AND (SELECT created_login FROM lab.artifact) = 'rt_member'
    AND (SELECT verified_login FROM lab.artifact_verification) = 'rt_member'
    AND (SELECT applied_login FROM lab.tag_assignment) = 'rt_member',
    'rows a member writes carry the member''s login, whatever the member sends');
SELECT pg_temp.assert(
    (SELECT notes FROM lab.subject WHERE subject_id = 'R1') = 'edited by a member',
    'a member may edit a subject''s descriptive columns');

-- A row that names no person is attributed to the person mapped to the
-- login; a person the member does name (e4, above) is kept.
INSERT INTO lab.event (event_id, event_type, subject_id, occurred_at)
VALUES ('00000000-0000-0000-0000-0000000000e5', 'husbandry', 'R1', now());
INSERT INTO lab.husbandry_event (event_id, measure, weight_g)
VALUES ('00000000-0000-0000-0000-0000000000e5', 'weight', 630);
SELECT pg_temp.assert(
    lab.fn_current_person() = '00000000-0000-0000-0000-0000000000a1'
    AND (SELECT recorded_by FROM lab.event WHERE event_id = '00000000-0000-0000-0000-0000000000e5')
        = '00000000-0000-0000-0000-0000000000a1'
    AND (SELECT recorded_by FROM lab.event WHERE event_id = '00000000-0000-0000-0000-0000000000e4')
        = '00000000-0000-0000-0000-0000000000a2',
    'the login''s person is the default for recorded_by, and only the default');

-- May set, update and describe variables, and retract a row entered in error.
SELECT lab.fn_set_variable('subject', 'R1', 'Probe Depth', 1200, p_units => 'um');
SELECT lab.fn_set_variable('subject', 'R1', 'probe depth', 1300);
UPDATE lab.variable SET description = 'described by a member' WHERE name = 'probe depth';
SELECT lab.fn_retract('event', '00000000-0000-0000-0000-0000000000e5', 'weight mistyped');
SELECT pg_temp.assert(
    (SELECT value || '|' || set_login || '|' || set_by FROM lab.variable_current
      WHERE entity_kind = 'subject' AND entity_id = 'R1')
        = '1300|rt_member|00000000-0000-0000-0000-0000000000a1'
    AND (SELECT retracted_login || '|' || retracted_by FROM lab.retraction)
        = 'rt_member|00000000-0000-0000-0000-0000000000a1'
    AND NOT EXISTS (SELECT 1 FROM lab.event_active
                    WHERE event_id = '00000000-0000-0000-0000-0000000000e5'),
    'a member may set and update variables and retract an event; each records the login');
SELECT pg_temp.expect_error($q$UPDATE lab.variable_value SET value_num = 1$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.variable_value$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.retraction$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.variable$q$, 'permission denied');

-- May record what became of a file; the record is permanent and carries the
-- member's login and person, whatever the member sends.
INSERT INTO lab.artifact_disposition (artifact_id, disposition, occurred_at, recorded_login)
VALUES ('00000000-0000-0000-0000-0000000000f1', 'deleted', now(), 'someone_else');
SELECT pg_temp.assert(
    (SELECT recorded_login || '|' || recorded_by FROM lab.artifact_disposition)
        = 'rt_member|00000000-0000-0000-0000-0000000000a1'
    AND NOT EXISTS (SELECT 1 FROM lab.artifact_present
                    WHERE artifact_id = '00000000-0000-0000-0000-0000000000f1'),
    'a member may record a file''s disposition; it records the login and the person');
SELECT pg_temp.expect_error($q$UPDATE lab.artifact_disposition SET note = 'x'$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.artifact_disposition$q$, 'permission denied');

-- May add a person, but not map a login to one.
INSERT INTO lab.person (full_name, email) VALUES ('Added By Member', 'added@example.edu');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.person (full_name, db_login) VALUES ('Imposter', 'rt_reader')$q$,
    'permission denied');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.person SET db_login = 'rt_member'
       WHERE person_id = '00000000-0000-0000-0000-0000000000a2'$q$, 'permission denied');

-- May not touch the append-only log, the audit logs or the vocabulary of
-- event types, and may not edit people.
SELECT pg_temp.expect_error($q$UPDATE lab.event SET notes = 'tampered'$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.event$q$, 'permission denied');
SELECT pg_temp.expect_error($q$TRUNCATE lab.event CASCADE$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.subject WHERE subject_id = 'R3'$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.tag_assignment$q$, 'permission denied');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.row_history (table_name, operation, row_key, old_row, new_row)
       VALUES ('subject', 'UPDATE', '{}', '{}', '{}')$q$, 'permission denied');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.maintenance_log (operation) VALUES ('forged')$q$, 'permission denied');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.schema_version (version, description) VALUES (99, 'forged')$q$,
    'permission denied');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.event_type (code, label) VALUES ('bogus', 'Bogus')$q$, 'permission denied');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.person SET email = 'one@example.edu.invalid'
       WHERE person_id = '00000000-0000-0000-0000-0000000000a1'$q$, 'permission denied');
SELECT pg_temp.expect_error(
    $q$ALTER TABLE lab.event DISABLE TRIGGER trg_immutable_event$q$, 'must be owner');

-- May not rename a subject: not through the function, not with a plain
-- UPDATE, and not by setting the maintenance flags by hand.
SELECT pg_temp.expect_error($q$SELECT lab.fn_rename_subject('R1', 'R1x')$q$, 'permission denied');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.subject SET subject_id = 'R3x' WHERE subject_id = 'R3'$q$, 'permission denied');
SELECT pg_temp.expect_error(
    $q$SELECT set_config('lab.maintenance', 'subject_rename', true),
              set_config('lab.rename_from', 'R1', true),
              set_config('lab.rename_to', 'R1x', true);
       UPDATE lab.subject SET subject_id = 'R1x' WHERE subject_id = 'R1'$q$,
    'permission denied');

RESET SESSION AUTHORIZATION;

-- ---------------------------------------------------------------------------
-- A member whose grants predate pre-launch version 4: UPDATE on all of lab.subject
-- ---------------------------------------------------------------------------
-- The column-level grant is not the only barrier: trg_subject_id_guard
-- refuses the change for a role that may not run lab.fn_rename_subject.
SET SESSION AUTHORIZATION rt_legacy;
SELECT pg_temp.expect_error(
    $q$SELECT set_config('lab.maintenance', 'subject_rename', true),
              set_config('lab.rename_from', 'R1', true),
              set_config('lab.rename_to', 'R1x', true);
       UPDATE lab.subject SET subject_id = 'R1x' WHERE subject_id = 'R1'$q$,
    'subject id R1 cannot be changed by rt_legacy');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.event WHERE subject_id = 'R1') = 3
    AND NOT EXISTS (SELECT 1 FROM lab.subject WHERE subject_id = 'R1x'),
    'no member-initiated rename took effect');

-- ---------------------------------------------------------------------------
-- A delegated administrator cannot run code as the table owner
-- ---------------------------------------------------------------------------
-- A rename cascades into the append-only tables, and PostgreSQL runs that
-- cascade -- and the triggers it fires -- as the owner of those tables. A
-- trigger function that resolved names with the caller's search path would
-- pick up the caller's temporary type named jsonb, whose CHECK calls the
-- caller's function: code chosen by rt_renamer, run as the owner. The pinned
-- search_path on every trigger function is what stops it; the probe records
-- whether it ran. The cascade is started with a plain UPDATE under hand-set
-- flags, not through lab.fn_rename_subject, so that the only search_path in
-- force is the caller's own (the function pins its own, which the triggers
-- it fires would inherit).
SET SESSION AUTHORIZATION rt_renamer;
CREATE TEMP TABLE probe_log (ran_as text);
GRANT ALL ON probe_log TO PUBLIC;
CREATE FUNCTION pg_temp.probe() RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO probe_log VALUES (current_user);
    RETURN true;
END;
$$;
CREATE DOMAIN pg_temp.jsonb AS pg_catalog.jsonb CHECK (pg_temp.probe());
SELECT set_config('lab.maintenance', 'subject_rename', true),
       set_config('lab.rename_from', 'R2', true),
       set_config('lab.rename_to', 'R2-renamed', true);
UPDATE lab.subject SET subject_id = 'R2-renamed' WHERE subject_id = 'R2';
SELECT set_config('lab.maintenance', '', true), set_config('lab.rename_from', '', true),
       set_config('lab.rename_to', '', true);
SELECT pg_temp.assert(
    (SELECT count(*) FROM probe_log) = 0,
    'trigger functions fired by the rename cascade did not run the caller''s code');
SELECT pg_temp.assert(
    (SELECT subject_id FROM lab.event WHERE event_id = '00000000-0000-0000-0000-0000000000e2')
        = 'R2-renamed'
    AND (SELECT subject_id FROM lab.subject_form WHERE subject_form_id = :'rt_fixture_sf')
        = 'R2-renamed',
    'the cascade itself ran, into the subject forms too');
-- The supported route, for a role that holds EXECUTE on the function.
SELECT lab.fn_rename_subject('R3', 'R3-renamed');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert(
    (SELECT subject_id FROM lab.event WHERE event_id = '00000000-0000-0000-0000-0000000000e3')
        = 'R3-renamed'
    AND (SELECT details ->> 'to' || '|' || performed_by FROM lab.maintenance_log
          WHERE operation = 'subject_rename') = 'R3-renamed|rt_renamer',
    'a delegated lab.fn_rename_subject works and is in maintenance_log');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'lab' AND p.prorettype = 'pg_catalog.trigger'::regtype
                  AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c
                                  WHERE c LIKE 'search_path=%')),
    'every trigger function in schema lab pins its search_path');

-- ---------------------------------------------------------------------------
-- The read-only login (lab_ro)
-- ---------------------------------------------------------------------------
SET SESSION AUTHORIZATION rt_reader;
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.event_active) = 4
    AND (SELECT count(*) FROM lab.event_version WHERE is_current) = 4
    AND (SELECT count(*) FROM lab.artifact_verification_latest) = 1
    AND (SELECT count(*) FROM lab.tag_current) = 1
    AND (SELECT count(*) FROM lab.variable_current) = 1
    AND (SELECT count(*) FROM lab.event_version WHERE is_retracted) = 1
    AND lab.fn_variable_number('subject', 'R1', 'probe depth') = 1300
    AND (SELECT count(*) FROM lab.fn_artifact_lineage('00000000-0000-0000-0000-0000000000f1', 'up')) = 1
    AND (SELECT count(*) FROM lab.fn_check_integrity()) >= 0
    AND (SELECT count(*) FROM lab.artifact_disposition_latest) = 1
    AND NOT EXISTS (SELECT 1 FROM lab.artifact_present)
    AND lab.fn_tag_match('subject', 'R1', ARRAY['topic:roles_test'])
    AND NOT EXISTS (SELECT 1 FROM lab.fn_tag_filter_problems('subject', ARRAY['topic:roles_test'])),
    'the read-only login reads tables, views and the read-only functions');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.event (event_type, subject_id, occurred_at) VALUES ('husbandry', 'R1', now())$q$,
    'permission denied');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_tag('subject', 'R1', 'topic:from_reader')$q$, 'permission denied');
SELECT pg_temp.expect_error(
    $q$UPDATE lab.subject SET notes = 'x' WHERE subject_id = 'R1'$q$, 'permission denied');
SELECT pg_temp.expect_error($q$SELECT lab.fn_rename_subject('R1', 'R1x')$q$, 'permission denied');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_variable('subject', 'R1', 'probe depth', 1)$q$, 'permission denied');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_retract('event', '00000000-0000-0000-0000-0000000000e1', 'x')$q$,
    'permission denied');
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.artifact_disposition (artifact_id, disposition, occurred_at)
       VALUES ('00000000-0000-0000-0000-0000000000f1', 'restored', now())$q$,
    'permission denied');
RESET SESSION AUTHORIZATION;

-- ---------------------------------------------------------------------------
-- Forms (design_docs/forms.md)
-- ---------------------------------------------------------------------------
-- A member publishes a template, puts it to use for a subject, records and
-- corrects entries and changes an entry's note; each row carries the
-- member's login. What a template or subject form is cannot be edited, and
-- versions and entries are append-only.
SET SESSION AUTHORIZATION rt_member;
SELECT pg_temp.assert(
    (SELECT version_number || '|' || is_new FROM lab.fn_publish_form('roles check',
        '{"format": 1, "header": [{"item": "sex"}],
          "sections": [{"fields": [{"widget": "number", "variable": "roles depth", "units": "um",
                                    "required": true},
                                   {"widget": "text", "variable": "roles side"}]}]}',
        p_label => 'Roles check')) = '1|true',
    'a member may publish a template');
SELECT lab.fn_add_subject_form('R2-renamed', 'roles check') AS rt_sf \gset
SELECT pg_temp.assert(lab.fn_record_observation(
    '00000000-0000-0000-0000-0000000000d1', :'rt_sf', now(), 'day 1',
    '{"roles depth": "1350.50", "roles side": "left"}', 'first',
    p_attributes => '{"client": "roles_test"}') = 'inserted',
    'a member may record an entry');
SELECT pg_temp.assert(lab.fn_record_observation(
    '00000000-0000-0000-0000-0000000000d2', :'rt_sf', now(), 'day 1',
    '{"roles depth": "1400", "roles side": "left"}', 'first',
    p_supersedes => '00000000-0000-0000-0000-0000000000d1') = 'inserted'
    AND lab.fn_set_entry_note('00000000-0000-0000-0000-0000000000d2', 'second') = 'set',
    'a member may correct an entry and change its note');
UPDATE lab.form SET description = 'described by a member', retired_at = NULL WHERE name = 'roles check';
UPDATE lab.subject_form SET notes = 'a member''s note' WHERE subject_form_id = :'rt_sf';
SELECT pg_temp.assert(
    (SELECT created_login || '|' || created_by FROM lab.form_version WHERE form_name = 'roles check')
        = 'rt_member|00000000-0000-0000-0000-0000000000a1'
    AND (SELECT created_by FROM lab.form WHERE name = 'roles check') = '00000000-0000-0000-0000-0000000000a1'
    AND (SELECT created_by FROM lab.subject_form WHERE subject_form_id = :'rt_sf')
        = '00000000-0000-0000-0000-0000000000a1'
    AND (SELECT string_agg(DISTINCT e.recorded_login || '|' || e.recorded_by, ',')
           FROM lab.event e JOIN lab.observation_event o USING (event_id))
        = 'rt_member|00000000-0000-0000-0000-0000000000a1'
    AND (SELECT bool_and(set_login = 'rt_member') FROM lab.variable_value
          WHERE event_id IN ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2'))
    AND (SELECT changed_by FROM lab.row_history WHERE table_name = 'form') = 'rt_member'
    AND (SELECT changed_by FROM lab.row_history WHERE table_name = 'subject_form'
          AND row_key = jsonb_build_object('subject_form_id', :'rt_sf')) = 'rt_member',
    'templates, versions, subject forms, entries and their values carry the member''s login and person');
SELECT pg_temp.expect_error($q$UPDATE lab.form SET name = 'renamed' WHERE name = 'roles check'$q$,
    'permission denied');
SELECT pg_temp.expect_error(format($q$
    UPDATE lab.subject_form SET project_id = project_id WHERE subject_form_id = %L$q$, :'rt_sf'),
    'permission denied');
SELECT pg_temp.expect_error(format($q$
    UPDATE lab.subject_form SET subject_id = 'R3' WHERE subject_form_id = %L$q$, :'rt_sf'),
    'permission denied');
SELECT pg_temp.expect_error($q$UPDATE lab.form_version SET note = 'x'$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.form_version$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.form$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.subject_form$q$, 'permission denied');
SELECT pg_temp.expect_error($q$UPDATE lab.observation_event SET session_label = 'x'$q$,
    'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.observation_event$q$, 'permission denied');
-- A raw INSERT of a version goes through the same checks as fn_publish_form.
SELECT pg_temp.expect_error(
    $q$INSERT INTO lab.form_version (form_name, definition) VALUES ('roles check', '{"format": 1}')$q$,
    'definition is not valid');
RESET SESSION AUTHORIZATION;

-- The read-only login reads the forms and entries but writes none of them.
SET SESSION AUTHORIZATION rt_reader;
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.observation_active) = 1
    AND (SELECT field_values->>'roles depth' || '|' || note FROM lab.observation_active) = '1400|second'
    AND (SELECT count(*) FROM lab.fn_subject_project_columns('R2-renamed',
                                                             '00000000-0000-0000-0000-0000000000b1')) = 3
    AND NOT EXISTS (SELECT 1 FROM lab.fn_form_definition_problems(
        (SELECT definition FROM lab.form_version WHERE form_name = 'roles check'), true))
    AND NOT EXISTS (SELECT 1 FROM lab.fn_observation_problems('roles check', 1,
        '{"roles depth": "1"}')),
    'the read-only login reads entries and runs the read-only form functions');
SELECT pg_temp.expect_error($q$
    SELECT * FROM lab.fn_publish_form('reader form',
        '{"format": 1, "sections": [{"fields": [{"widget": "text", "variable": "roles side"}]}]}')$q$,
    'permission denied');
SELECT pg_temp.expect_error($q$SELECT lab.fn_add_subject_form('R1', 'roles check')$q$,
    'permission denied');
SELECT pg_temp.expect_error(format($q$
    SELECT lab.fn_record_observation(gen_random_uuid(), %L, now(), 'x', '{"roles depth": "1"}')$q$,
    :'rt_sf'), 'permission denied');
SELECT pg_temp.expect_error(
    $q$SELECT lab.fn_set_entry_note('00000000-0000-0000-0000-0000000000d2', 'reader')$q$,
    'permission denied');
SELECT pg_temp.expect_error($q$UPDATE lab.form SET description = 'x'$q$, 'permission denied');
SELECT pg_temp.expect_error($q$UPDATE lab.subject_form SET notes = 'x'$q$, 'permission denied');
RESET SESSION AUTHORIZATION;

-- ---------------------------------------------------------------------------
-- The search for new files (design_docs/nas-import.md)
-- ---------------------------------------------------------------------------
-- The owner lists a directory: R1 on the test root, where the member's file
-- R1/weights.csv was registered above.
INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                scan_interval_min, mode)
VALUES ((SELECT root_id FROM lab.storage_root WHERE name = 'nas-roles-test'),
        'R1', 'epsych', 'America/New_York', 1440, 'register');
INSERT INTO lab.scan_run (scan_directory_id, command, mode)
SELECT scan_directory_id, 'apply', 'register' FROM lab.scan_directory;
SELECT scan_directory_id AS rt_dir, storage_root_id AS rt_root FROM lab.scan_directory \gset
SELECT scan_run_id AS rt_owner_run FROM lab.scan_run \gset

-- A member reads the list, the logs and the schedule, and writes none of
-- them: whoever writes lab.scan_run can postpone a search, and whoever
-- writes lab.scan_file can make the search pass over a file.
SET SESSION AUTHORIZATION rt_member;
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.scan_directory) = 1
    AND (SELECT count(*) FROM lab.scan_layout) = 2
    AND (SELECT count(*) FROM lab.scan_run) = 1
    AND (SELECT is_due AND is_running AND created_login <> 'rt_member'
         FROM lab.scan_directory_status)
    AND (SELECT count(*) FROM lab.fn_scan_due()) = 1,
    'a member reads the list of directories, the runs and the schedule');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, scan_interval_min)
    VALUES (%s, 'R2', 'epsych', 'UTC', 60)$q$, :rt_root), 'permission denied for table scan_directory');
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_layout (code, label) VALUES ('bogus', 'Bogus')$q$,
    'permission denied for table scan_layout');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_run (scan_directory_id, command, mode, due_at) VALUES (%s, 'run', 'report', now())$q$,
    :rt_dir), 'permission denied for table scan_run');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_run_result (scan_run_id, outcome) VALUES (%s, 'ok')$q$, :rt_owner_run),
    'permission denied for table scan_run_result');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns,
                               status, artifact_id)
    VALUES (%s, %s, 'R1/weights.csv', 1, 1, 'known', '00000000-0000-0000-0000-0000000000f1')$q$,
    :rt_owner_run, :rt_root), 'permission denied for table scan_file');
-- Nor through the views over them: none can be written through, and the
-- privilege that would matter if one could is withheld as well.
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_file_latest (scan_run_id, storage_root_id, relative_path, size_bytes,
                                      mtime_ns, status)
    VALUES (%s, %s, 'R1/new.mat', 1, 1, 'pending')$q$, :rt_owner_run, :rt_root),
    'cannot insert into view "scan_file_latest"');
SELECT pg_temp.assert(
    NOT EXISTS (SELECT 1
                FROM unnest(ARRAY['scan_layout', 'scan_directory', 'scan_run', 'scan_run_result',
                                  'scan_file', 'scan_file_latest', 'scan_held',
                                  'scan_directory_status']) AS t(name)
                CROSS JOIN unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) AS p(privilege)
                WHERE has_table_privilege(current_user, 'lab.' || t.name, p.privilege))
    AND has_table_privilege(current_user, 'lab.scan_file', 'SELECT')
    AND has_table_privilege(current_user, 'lab.scan_held', 'SELECT'),
    'a member holds SELECT and nothing else on the scan tables and the views over them');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET mode = 'off'$q$, 'permission denied');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET scan_interval_min = 527040$q$,
    'permission denied');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_layout SET label = 'x'$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.scan_directory$q$, 'permission denied');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_run SET due_at = NULL$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.scan_file$q$, 'permission denied');
RESET SESSION AUTHORIZATION;

-- The scanner appends to the three logs; each run carries its login,
-- whatever it sends. It registers files as any member does. It cannot change
-- the list it works from, nor a row it has written.
SET SESSION AUTHORIZATION rt_scanner;
INSERT INTO lab.scan_run (scan_directory_id, command, mode, due_at, run_login, host, tool_version)
SELECT d.scan_directory_id, 'run', 'register', d.due_at, 'someone_else', 'lab-server', '1.0.0'
FROM lab.fn_scan_due() d;
SELECT max(scan_run_id) AS rt_scan_run FROM lab.scan_run \gset
INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns,
                           group_key, status, reason_code, artifact_id)
VALUES (:rt_scan_run, :rt_root, 'R1/weights.csv', 120, 1780000000000000000, 'R1', 'known', NULL,
        '00000000-0000-0000-0000-0000000000f1'),
       (:rt_scan_run, :rt_root, 'R1/new.mat', 400, 1780000000000000001, 'R1', 'pending', NULL, NULL),
       (:rt_scan_run, :rt_root, 'R1/stray.txt', 3, 1780000000000000002, NULL, 'held',
        'unrecognised_file', NULL);
INSERT INTO lab.scan_run_result (scan_run_id, outcome, files_listed, files_known, files_pending, files_held)
VALUES (:rt_scan_run, 'ok', 3, 1, 1, 1);
SELECT pg_temp.assert(
    (SELECT run_login FROM lab.scan_run WHERE scan_run_id = :rt_scan_run) = 'rt_scanner'
    AND (SELECT run_login FROM lab.scan_run WHERE scan_run_id = :rt_owner_run) <> 'rt_scanner'
    AND (SELECT last_ok_run_id = :rt_scan_run AND last_run_outcome = 'ok' AND NOT is_due
                AND NOT is_running AND n_pending = 1 AND n_held = 1
         FROM lab.scan_directory_status),
    'the scanner appends runs, results and memory rows; run_login is its login, whatever '
    'it sends; the schedule follows');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_run SET due_at = NULL$q$, 'permission denied');
SELECT pg_temp.expect_error($q$DELETE FROM lab.scan_run_result$q$, 'permission denied');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_file SET status = 'cleared'$q$, 'permission denied');
SELECT pg_temp.expect_error($q$TRUNCATE lab.scan_file$q$, 'permission denied');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET mode = 'off'$q$, 'permission denied');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, scan_interval_min)
    VALUES (%s, 'R2', 'epsych', 'UTC', 60)$q$, :rt_root), 'permission denied for table scan_directory');
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_layout (code, label) VALUES ('bogus', 'Bogus')$q$,
    'permission denied for table scan_layout');
RESET SESSION AUTHORIZATION;

-- A member the owner grants INSERT and UPDATE on the list adds and edits
-- directories. The row carries the login, the edit is in row_history under
-- it, and the rules of the list hold for it as for the owner. The grant is
-- the list and nothing more.
SET SESSION AUTHORIZATION rt_lister;
INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone,
                                scan_interval_min, created_login)
VALUES (:rt_root, 'R2', 'intan', 'America/New_York', 60, 'someone_else');
SELECT scan_directory_id AS rt_dir2 FROM lab.scan_directory WHERE relative_path = 'R2' \gset
UPDATE lab.scan_directory
   SET scan_interval_min = 30, window_start = '22:00', window_end = '06:00', pair_with = :rt_dir
 WHERE scan_directory_id = :rt_dir2;
UPDATE lab.scan_directory SET notes = 'searched nightly' WHERE scan_directory_id = :rt_dir;
SELECT pg_temp.assert(
    (SELECT created_login || '|' || mode || '|' || scan_interval_min || '|' || pair_with
     FROM lab.scan_directory WHERE scan_directory_id = :rt_dir2) = 'rt_lister|report|30|' || :rt_dir
    AND (SELECT count(*) || '|' || min(changed_by) || '|' || min(operation) FROM lab.row_history
          WHERE table_name = 'scan_directory') = '2|rt_lister|UPDATE'
    AND (SELECT old_row ->> 'scan_interval_min' || '>' || (new_row ->> 'scan_interval_min')
         FROM lab.row_history
         WHERE table_name = 'scan_directory'
           AND row_key = jsonb_build_object('scan_directory_id', :rt_dir2)) = '60>30',
    'a delegated login adds and edits directories; the row carries its login and the edit '
    'is in row_history under it');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, scan_interval_min)
    VALUES (%s, 'r1/Sub', 'epsych', 'UTC', 60)$q$, :rt_root), 'lies inside it');
SELECT pg_temp.expect_error(format($q$
    UPDATE lab.scan_directory SET relative_path = 'R1-moved' WHERE scan_directory_id = %s$q$, :rt_dir),
    'has been searched');
SELECT pg_temp.expect_error(format($q$
    UPDATE lab.scan_directory SET created_login = 'rt_member' WHERE scan_directory_id = %s$q$, :rt_dir2),
    'never change');
SELECT pg_temp.expect_error(format($q$
    UPDATE lab.scan_directory SET mode_changed_at = now() - interval '1 year'
    WHERE scan_directory_id = %s$q$, :rt_dir2), 'mode_changed_at is kept by the database');
UPDATE lab.scan_directory SET mode = 'register', mode_changed_at = '2000-01-01 00:00Z'
WHERE scan_directory_id = :rt_dir2;
SELECT pg_temp.assert(
    (SELECT mode || '|' || (mode_changed_at = now()) FROM lab.scan_directory
      WHERE scan_directory_id = :rt_dir2) = 'register|true',
    'a delegated login changes a directory''s mode; when it changed is the database''s to say');
SELECT pg_temp.expect_error($q$DELETE FROM lab.scan_directory$q$, 'permission denied');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_run (scan_directory_id, command, mode) VALUES (%s, 'run', 'report')$q$, :rt_dir2),
    'permission denied for table scan_run');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns, status)
    VALUES (%s, %s, 'R2/a.rhd', 1, 1, 'pending')$q$, :rt_scan_run, :rt_root),
    'permission denied for table scan_file');
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_layout (code, label) VALUES ('bogus', 'Bogus')$q$,
    'permission denied for table scan_layout');
SELECT pg_temp.expect_error($q$
    INSERT INTO lab.row_history (table_name, operation, row_key, old_row, new_row)
    VALUES ('scan_directory', 'UPDATE', '{}', '{}', '{}')$q$, 'permission denied');
RESET SESSION AUTHORIZATION;

-- The read-only login reads the list, the memory and the schedule through
-- the views and functions, and writes nothing.
SET SESSION AUTHORIZATION rt_reader;
SELECT pg_temp.assert(
    (SELECT count(*) FROM lab.scan_directory_status) = 2
    AND (SELECT count(*) FROM lab.fn_scan_status()) = 2
    AND (SELECT string_agg(relative_path || ' ' || window_start_text || '-' || window_end_text, ',')
         FROM lab.fn_scan_status() WHERE window_start_text IS NOT NULL) = 'R2 22:00-06:00'
    AND (SELECT count(*) FROM lab.fn_scan_due('2036-01-10 03:00Z')) = 2
    AND (SELECT string_agg(relative_path, ',') FROM lab.fn_scan_due('2036-01-10 12:00Z')) = 'R1'
    AND lab.fn_scan_window_open(:rt_dir)
    AND lab.fn_scan_window_open(:rt_dir2, '2026-01-10 03:00Z')
    AND NOT lab.fn_scan_window_open(:rt_dir2, '2026-01-10 12:00Z')
    AND (SELECT count(*) FROM lab.scan_file_latest) = 3
    AND (SELECT relative_path || '|' || reason_code || '|' || storage_root || '|' || scan_directory_id
         FROM lab.scan_held) = 'R1/stray.txt|unrecognised_file|nas-roles-test|' || :rt_dir
    AND (SELECT count(*) FROM lab.scan_run) = 2
    AND (SELECT count(*) FROM lab.scan_run_result) = 1
    AND NOT EXISTS (SELECT 1 FROM lab.fn_check_integrity() WHERE check_name = 'scan_directory_overlap'),
    'the read-only login reads the scan tables, views and the schedule functions');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, scan_interval_min)
    VALUES (%s, 'R3', 'epsych', 'UTC', 60)$q$, :rt_root), 'permission denied');
SELECT pg_temp.expect_error($q$INSERT INTO lab.scan_layout (code, label) VALUES ('bogus', 'Bogus')$q$,
    'permission denied');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_run (scan_directory_id, command, mode) VALUES (%s, 'run', 'report')$q$, :rt_dir),
    'permission denied');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_run_result (scan_run_id, outcome) VALUES (%s, 'ok')$q$, :rt_owner_run),
    'permission denied');
SELECT pg_temp.expect_error(format($q$
    INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, mtime_ns, status)
    VALUES (%s, %s, 'R1/x.mat', 1, 1, 'pending')$q$, :rt_scan_run, :rt_root), 'permission denied');
SELECT pg_temp.expect_error($q$UPDATE lab.scan_directory SET mode = 'off'$q$, 'permission denied');
RESET SESSION AUTHORIZATION;

ROLLBACK;
\echo 'roles_test.sql: all assertions passed'
