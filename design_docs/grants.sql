-- ============================================================================
-- CarasLabDB privileges -- the single grant script every guide refers to
-- ============================================================================
-- Run as the schema owner after design_docs/schema.sql (or a migration), and
-- again after any schema change; it is idempotent:
--
--     psql -v ON_ERROR_STOP=1 -d lab -f design_docs/grants.sql
--
-- The schema owner should be a dedicated, non-superuser role (the lab's admin
-- login), not postgres: the owner can drop the immutability triggers, and a
-- cascaded update runs with the owner's privileges.
--
-- Two group roles carry all privileges. Neither is a login:
--
--   lab_rw  Read and write for researchers and their MATLAB client. Every lab
--           member has a login of their own that inherits it:
--               CREATE ROLE jdoe LOGIN PASSWORD '...' IN ROLE lab_rw;
--           so that row_history.changed_by and the *_login columns record who
--           wrote each row. Sharing one login defeats both.
--   lab_ro  Read only. The live dashboard server and the MCP server each get
--           a login that inherits it:
--               CREATE ROLE lab_dashboard LOGIN PASSWORD '...' IN ROLE lab_ro;
--
-- Each is created here as a group role (NOLOGIN) if it does not exist yet. A
-- deployment that already made lab_rw or lab_ro a login keeps that; this
-- script only sets privileges. Creating a missing role needs CREATEROLE.
-- ============================================================================

\set ON_ERROR_STOP 1

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lab_rw') THEN
        CREATE ROLE lab_rw NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lab_ro') THEN
        CREATE ROLE lab_ro NOLOGIN;
    END IF;
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO lab_rw, lab_ro', current_database());
END;
$$;

GRANT USAGE ON SCHEMA lab TO lab_rw, lab_ro;

-- Read: everything, both roles. Covers the views too.
GRANT SELECT ON ALL TABLES IN SCHEMA lab TO lab_rw, lab_ro;

-- Append: lab_rw inserts into every table. UPDATE and DELETE on the event
-- log, artifacts, provenance edges, tag assignments and audit logs are
-- blocked by triggers whatever is granted here.
GRANT INSERT ON ALL TABLES IN SCHEMA lab TO lab_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA lab TO lab_rw;

-- Except the logs only the database writes: maintenance_log (by
-- fn_rename_subject, run by the owner), row_history (by the SECURITY DEFINER
-- fn_log_row_change trigger) and schema_version (by migrations). A client
-- that could insert into them could forge history.
REVOKE INSERT ON lab.maintenance_log, lab.row_history, lab.schema_version FROM lab_rw;

-- lab.person is insertable, but not its db_login column: that column maps a
-- database login to a person (lab.fn_current_person), so whoever can set it
-- can sign entries as someone else. The administrator sets it when a member
-- is onboarded.
REVOKE INSERT ON lab.person FROM lab_rw;
GRANT INSERT (person_id, full_name, email, role, is_active, created_at)
    ON lab.person TO lab_rw;

-- And except lab.event_type: each event type is one of the schema's detail
-- tables, so a row added here names a type with no detail table, which every
-- event of that type then reports as event_missing_detail forever. New event
-- types arrive with a migration.
REVOKE INSERT ON lab.event_type FROM lab_rw;

-- Edit: the descriptive tables the schema leaves mutable, which the MATLAB
-- class (updateSubject, updateSession) and the GUI editors change in place,
-- the project tables, the tag vocabulary (tag_namespace, tag) and the
-- variable definitions (variable), which any member may extend, describe and
-- retire; trg_tag_namespace_guard, trg_tag_guard and trg_variable_guard stop
-- a namespace's policy drifting once it is in use, a tag or variable being
-- renamed, and a variable's units or type changing once it has values. Every UPDATE is recorded in lab.row_history with the
-- login that made it. The reference tables (person, species, probe,
-- storage_root, vocabularies) stay owner-only: lab.person in particular is
-- what recorded_by / created_by / applied_by point at, so a member who could
-- edit it could reassign other people's entries.
GRANT UPDATE ON lab.session, lab.project, lab.project_member,
                lab.project_artifact,
                lab.tag_namespace, lab.tag, lab.variable TO lab_rw;

-- lab.subject is editable column by column, and subject_id is not among the
-- columns: it is the natural key every append-only table refers to, and
-- changing it is the administrator's lab.fn_rename_subject (the cascade into
-- those tables runs with the owner's privileges, and each rename is recorded
-- in lab.maintenance_log). The two REVOKEs undo the table-level grants made
-- by earlier versions of this script.
REVOKE UPDATE ON lab.subject, lab.person FROM lab_rw;
GRANT UPDATE (project_id, species_code, sex, strain, genotype, source,
              date_of_birth, notes) ON lab.subject TO lab_rw;

-- Tables and sequences the owner creates later get the same read/append
-- defaults. A new table that should be editable, or must not be written by
-- clients, still needs its own line above.
ALTER DEFAULT PRIVILEGES IN SCHEMA lab GRANT SELECT ON TABLES TO lab_rw, lab_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA lab GRANT INSERT ON TABLES TO lab_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA lab GRANT USAGE, SELECT ON SEQUENCES TO lab_rw;

-- Every function except lab.fn_rename_subject keeps PostgreSQL's default
-- EXECUTE for PUBLIC. None is SECURITY DEFINER but the row_history trigger,
-- so lab.fn_tag, lab.fn_register_tag, lab.fn_set_variable, lab.fn_unset_variable
-- and lab.fn_retract write with the caller's privileges: lab_rw can use them,
-- and lab_ro calling them is refused at the INSERT.
--
-- lab.fn_rename_subject is REVOKEd from PUBLIC in schema.sql. Grant EXECUTE
-- on it only to the administrator who performs identity maintenance; it is
-- deliberately not granted here. trg_subject_id_guard lets only a role
-- holding that EXECUTE change a subject id, so the grant is the whole
-- permission.
