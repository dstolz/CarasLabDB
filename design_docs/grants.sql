-- ============================================================================
-- CarasLabDB privileges -- the single grant script every guide refers to
-- ============================================================================
-- Run as the schema owner after design_docs/schema.sql (or a migration), and
-- again after any schema change; it is idempotent:
--
--     psql -v ON_ERROR_STOP=1 -d lab -f design_docs/grants.sql
--
-- Two roles carry all privileges:
--
--   lab_rw  Read and write for researchers and their MATLAB client. Per-person
--           logins inherit it (CREATE ROLE jdoe LOGIN PASSWORD '...' IN ROLE
--           lab_rw), or, in a simpler setup, lab_rw is itself the login.
--   lab_ro  Read only, for the live dashboard server and the MCP server.
--
-- Each is created here as a group role (NOLOGIN) if it does not exist yet. A
-- guide that creates lab_rw or lab_ro itself with LOGIN keeps that; this
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
-- log, artifacts, provenance edges and audit logs are blocked by triggers
-- whatever is granted here.
GRANT INSERT ON ALL TABLES IN SCHEMA lab TO lab_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA lab TO lab_rw;

-- Except the logs only the database writes: maintenance_log (by
-- fn_rename_subject, run by the owner), row_history (by the SECURITY DEFINER
-- fn_log_row_change trigger) and schema_version (by migrations). A client
-- that could insert into them could forge history.
REVOKE INSERT ON lab.maintenance_log, lab.row_history, lab.schema_version FROM lab_rw;

-- Edit: the descriptive tables the schema leaves mutable, which the MATLAB
-- class (updateSubject, updateSession) and the GUI editors change in place.
-- Every UPDATE is recorded in lab.row_history with the login that made it.
-- The reference tables (species, probe, storage_root, vocabularies) stay
-- owner-only.
GRANT UPDATE ON lab.subject, lab.session, lab.project, lab.project_member,
                lab.project_artifact, lab.person TO lab_rw;

-- Tables and sequences the owner creates later get the same read/append
-- defaults. A new table that should be editable, or must not be written by
-- clients, still needs its own line above.
ALTER DEFAULT PRIVILEGES IN SCHEMA lab GRANT SELECT ON TABLES TO lab_rw, lab_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA lab GRANT INSERT ON TABLES TO lab_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA lab GRANT USAGE, SELECT ON SEQUENCES TO lab_rw;

-- lab.fn_rename_subject is REVOKEd from PUBLIC in schema.sql. Grant EXECUTE
-- on it only to the administrator who performs identity maintenance; it is
-- deliberately not granted here.
