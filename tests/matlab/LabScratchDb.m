classdef LabScratchDb < matlab.unittest.fixtures.Fixture
%LABSCRATCHDB Shared test fixture: a throwaway lab_mtest database.
%
%   Setup creates the database lab_mtest, applies design_docs/schema.sql and
%   design_docs/grants.sql, creates the login role lab_mtest_rw as a member
%   of lab_rw (not a superuser, so the tests exercise the grants) with a
%   person row of its own, and opens two CarasLabDB connections:
%       Db     as lab_mtest_rw -- what the tests use;
%       Admin  as the administrator login -- for what lab_rw may not do
%              (lab.fn_rename_subject) and for a second, independent session.
%   Teardown closes both and drops the database and lab_mtest_rw, plus
%   lab_rw / lab_ro if this fixture created them.
%
%   The database tests are opt-in, because this creates a database and a
%   role on the server. Set, before running the tests:
%       CARASLABDB_MTEST_ADMIN           a login with CREATEDB and CREATEROLE
%                                        (e.g. postgres)
%   and as needed
%       CARASLABDB_MTEST_ADMIN_PASSWORD  its password (default: trust / pgpass)
%       CARASLABDB_MTEST_HOST            default "localhost"
%       CARASLABDB_MTEST_PORT            default 5432
%       CARASLABDB_MTEST_PGBIN           folder holding psql (default: the PATH)
%   e.g.
%       setenv("CARASLABDB_MTEST_ADMIN", "postgres")
%       setenv("CARASLABDB_MTEST_PGBIN", "C:\Program Files\PostgreSQL\16\bin")
%       results = runtests("tests/matlab")
%
%   Without CARASLABDB_MTEST_ADMIN, or without the Database Toolbox, the
%   fixture is not Available and the database tests are skipped (reported
%   as Incomplete); the database-free tests still run.
%
%   Use a development server, never the lab's production one. Setup will not
%   touch an existing lab_mtest or lab_mtest_rw unless it carries this
%   fixture's marker comment (left by an interrupted earlier run).
%
%   See also TAGTESTS, TAGGUITESTS.

    properties (Constant)
        DbName      = "lab_mtest"
        RwRole      = "lab_mtest_rw"
        PersonEmail = "lab_mtest_rw@example.invalid"
        Marker      = "CarasLabDB MATLAB test scratch object; safe to drop"
    end

    properties (SetAccess = private)
        Available (1,1) logical = false
        Reason (1,1) string = ""
        Db                                  % CarasLabDB connected as RwRole
        Admin                               % CarasLabDB connected as the administrator
        PersonId (1,1) string = string(missing)
        RootId double = []                  % storage_root the tests' paths live under
        ConnectOutput (1,1) string = ""     % command-window text of constructing Db
        ConnectWarningId (1,1) string = ""  % lastwarn identifier after constructing Db
        RepoRoot (1,1) string = ""
        Host (1,1) string = "localhost"
        Port (1,1) double = 5432
        AdminUser (1,1) string = ""
    end

    properties (Access = private)
        AdminPassword (1,1) string = ""
        RwPassword (1,1) string = ""
        PgBin (1,1) string = ""
        CreatedDb (1,1) logical = false
        CreatedRwRole (1,1) logical = false
        CreatedGroupRoles string = strings(1, 0)
        SavedPath = ''
        Counter (1,1) double = 0
    end

    methods
        function setup(fx)
            fx.SetupDescription = "Create the scratch database " + fx.DbName;
            fx.TeardownDescription = "Drop the scratch database " + fx.DbName;
            fx.RepoRoot = string(fileparts(fileparts(fileparts(mfilename("fullpath")))));
            fx.SavedPath = path;
            addpath(fx.RepoRoot);

            fx.AdminUser = string(getenv("CARASLABDB_MTEST_ADMIN"));
            if strlength(fx.AdminUser) == 0
                fx.Reason = "Database tests skipped: set CARASLABDB_MTEST_ADMIN (see help LabScratchDb).";
                return
            end
            if exist("postgresql") == 0 %#ok<EXIST>
                fx.Reason = "Database tests skipped: the Database Toolbox (postgresql) is not installed.";
                return
            end
            fx.AdminPassword = string(getenv("CARASLABDB_MTEST_ADMIN_PASSWORD"));
            fx.PgBin = string(getenv("CARASLABDB_MTEST_PGBIN"));
            if strlength(getenv("CARASLABDB_MTEST_HOST")) > 0
                fx.Host = string(getenv("CARASLABDB_MTEST_HOST"));
            end
            if strlength(getenv("CARASLABDB_MTEST_PORT")) > 0
                fx.Port = str2double(getenv("CARASLABDB_MTEST_PORT"));
            end

            fx.createDatabase();
            fx.connect();
            fx.Available = true;
        end

        function teardown(fx)
            for c = {fx.Db, fx.Admin}
                try
                    if ~isempty(c{1}) && isvalid(c{1})
                        delete(c{1});
                    end
                catch
                end
            end
            try
                if fx.CreatedDb
                    fx.psql("postgres", "DROP DATABASE IF EXISTS " + fx.DbName + " WITH (FORCE);");
                end
                if fx.CreatedRwRole
                    fx.psql("postgres", "DROP ROLE IF EXISTS " + fx.RwRole + ";");
                end
                for r = fx.CreatedGroupRoles
                    fx.psql("postgres", "DROP ROLE IF EXISTS " + r + ";");
                end
            catch ME
                warning("LabScratchDb:teardownFailed", ...
                    "Could not drop the scratch objects; drop %s and %s by hand. (%s)", ...
                    fx.DbName, fx.RwRole, ME.message);
            end
            path(fx.SavedPath);
        end

        % ------------------------------------------------------------------
        % Helpers shared by the test classes
        % ------------------------------------------------------------------
        function n = next(fx)
            %NEXT A run-unique, deterministic sequence number for ids and paths.
            fx.Counter = fx.Counter + 1;
            n = fx.Counter;
        end

        function w = makeWorld(fx, prefix, nArtifacts)
            %MAKEWORLD A project, subject, session, recording event and its artifacts.
            arguments
                fx (1,1) LabScratchDb
                prefix (1,1) string
                nArtifacts (1,1) double = 1
            end
            db = fx.Db;
            n = fx.next();
            w.Key = prefix + "-" + n;
            w.ProjectId = db.addProject(Name="mt project " + w.Key);
            w.SubjectId = db.addSubject(SubjectId="MT-" + w.Key, ProjectId=w.ProjectId, ...
                SpeciesCode="meriones_unguiculatus");
            w.SessionId = db.addSession(SubjectId=w.SubjectId, Label="sess-" + w.Key, ...
                StorageRootId=fx.RootId, RelativePath="mt/" + w.Key);
            w.EventId = fx.addEvent(w);
            w.ArtifactIds = strings(1, 0);
            for k = 1:nArtifacts
                w.ArtifactIds(k) = fx.addArtifact(w, w.EventId);
            end
        end

        function eid = addEvent(fx, w)
            %ADDEVENT Another recording event in world W's session.
            n = fx.next();
            eid = fx.Db.addRecordingEvent(SubjectId=w.SubjectId, SessionId=w.SessionId, ...
                OccurredAt=datetime(2026, 10, 1, 9, 0, 0, "TimeZone", "UTC") + minutes(n), ...
                AcquisitionSystemCode="intan_rhx", NChannels=32);
        end

        function aid = addArtifact(fx, w, eventId)
            %ADDARTIFACT A new file produced by EVENTID, in world W.
            n = fx.next();
            aid = fx.Db.addArtifact(ProducedByEventId=eventId, StorageRootId=fx.RootId, ...
                RelativePath="mt/" + w.Key + "/f" + n + ".dat", Checksum=fx.checksum(n), ...
                Role="raw", Format="dat", SubjectId=w.SubjectId, SessionId=w.SessionId);
        end

        function ids = findByTagsSql(fx, kind, allOf, anyOf, noneOf, activeOnly)
            %FINDBYTAGSSQL lab.fn_find_by_tags, called with SQL written here (not by CarasLabDB).
            arguments
                fx (1,1) LabScratchDb
                kind (1,1) string
                allOf string = strings(1, 0)
                anyOf string = strings(1, 0)
                noneOf string = strings(1, 0)
                activeOnly (1,1) logical = true
            end
            sql = "SELECT entity_id FROM lab.fn_find_by_tags(" + LabScratchDb.quote(kind) + ", " + ...
                LabScratchDb.textArray(allOf) + ", " + LabScratchDb.textArray(anyOf) + ", " + ...
                LabScratchDb.textArray(noneOf) + ", " + string(activeOnly) + ")";
            ids = fx.column(fx.Db.runQuery(sql), "entity_id");
        end

        function v = scalar(fx, sql)
            %SCALAR First column of the first row of SQL (run as Db).
            T = fx.Db.runQuery(sql);
            v = T{1, 1};
        end

        function n = rowHistoryCount(fx, tableName, keyCol, keyVal)
            %ROWHISTORYCOUNT lab.row_history rows recorded for one row of TABLENAME.
            n = double(fx.scalar("SELECT count(*) AS n FROM lab.row_history WHERE table_name = " + ...
                LabScratchDb.quote(tableName) + " AND row_key ->> " + LabScratchDb.quote(keyCol) + ...
                " = " + LabScratchDb.quote(keyVal)));
        end

        function s = logSnapshot(fx, kind, ids)
            %LOGSNAPSHOT Every lab.tag_assignment row of these entities, as exact JSON text.
            col = kind + "_id";
            T = fx.Db.runQuery("SELECT to_jsonb(ta)::text AS row_json FROM lab.tag_assignment ta " + ...
                "WHERE ta.entity_kind = " + LabScratchDb.quote(kind) + " AND ta." + col + ...
                "::text = ANY (" + LabScratchDb.textArray(ids) + ") ORDER BY ta.assignment_id");
            s = fx.column(T, "row_json");
        end

        function c = counts(fx)
            %COUNTS Row counts of the tables a correction writes.
            T = fx.Db.runQuery("SELECT " + ...
                "(SELECT count(*) FROM lab.event) AS events, " + ...
                "(SELECT count(*) FROM lab.recording_event) AS recording_events, " + ...
                "(SELECT count(*) FROM lab.artifact) AS artifacts, " + ...
                "(SELECT count(*) FROM lab.event_input) AS event_inputs, " + ...
                "(SELECT count(*) FROM lab.tag_assignment) AS tag_assignments, " + ...
                "(SELECT count(*) FROM lab.tag) AS tags, " + ...
                "(SELECT coalesce(max(assignment_id), 0) FROM lab.tag_assignment) AS max_assignment_id");
            c = table2struct(T);
        end

        function T = integrity(fx, subjects, checks)
            %INTEGRITY lab.fn_check_integrity() rows about SUBJECTS, of the checks CHECKS.
            %   CHECKS defaults to the two a correction can leave behind;
            %   artifact_never_verified, which every new test file raises, is
            %   not one of them.
            arguments
                fx (1,1) LabScratchDb
                subjects string
                checks string = ["tag_not_carried_forward", "artifact_producer_superseded"]
            end
            T = fx.Db.runQuery("SELECT * FROM lab.fn_check_integrity() WHERE subject = ANY (" + ...
                LabScratchDb.textArray(subjects) + ") AND check_name = ANY (" + ...
                LabScratchDb.textArray(checks) + ") ORDER BY check_name, subject");
        end

        function s = connectionSettings(fx)
            %CONNECTIONSETTINGS CarasLabDB constructor values for the lab_rw login.
            s = struct("Username", fx.RwRole, "Password", fx.RwPassword, "Server", fx.Host, ...
                "Port", fx.Port, "DatabaseName", fx.DbName, "PersonEmail", fx.PersonEmail);
        end
    end

    methods (Static)
        function q = quote(s)
            %QUOTE A SQL string literal (quotes doubled), written independently of CarasLabDB.
            q = "'" + replace(string(s), "'", "''") + "'";
        end

        function a = textArray(tokens)
            %TEXTARRAY ARRAY['a', 'b']::text[], or NULL::text[] for no tokens.
            tokens = reshape(string(tokens), 1, []);
            if isempty(tokens)
                a = "NULL::text[]";
            else
                a = "ARRAY[" + strjoin(LabScratchDb.quote(tokens), ", ") + "]::text[]";
            end
        end

        function s = column(T, name)
            %COLUMN A fetched text column as a string column (0x1 when T is empty).
            if height(T) == 0
                s = strings(0, 1);
            else
                s = reshape(string(T.(char(name))), [], 1);
            end
        end

        function c = checksum(n)
            %CHECKSUM A unique, valid sha256-width hex checksum for sequence number N.
            c = lower(string(dec2hex(n, 64)));
        end
    end

    methods (Access = private)
        function createDatabase(fx)
            % Refuse to touch anything this fixture did not create.
            fx.dropLeftover("database", ...
                "SELECT coalesce(shobj_description(oid, 'pg_database'), '') FROM pg_database " + ...
                "WHERE datname = '" + fx.DbName + "'", ...
                "DROP DATABASE " + fx.DbName + " WITH (FORCE);");
            fx.dropLeftover("role", ...
                "SELECT coalesce(shobj_description(oid, 'pg_authid'), '') FROM pg_roles " + ...
                "WHERE rolname = '" + fx.RwRole + "'", ...
                "DROP ROLE " + fx.RwRole + ";");

            existing = splitlines(strtrim(string(fx.psql("postgres", ...
                "SELECT rolname FROM pg_roles WHERE rolname IN ('lab_rw', 'lab_ro');"))));
            fx.CreatedGroupRoles = setdiff(["lab_rw", "lab_ro"], existing);

            fx.psql("postgres", "CREATE DATABASE " + fx.DbName + ";");
            fx.CreatedDb = true;
            fx.psql("postgres", "COMMENT ON DATABASE " + fx.DbName + " IS " + ...
                LabScratchDb.quote(fx.Marker) + ";");
            fx.psqlFile(fx.DbName, fullfile(fx.RepoRoot, "design_docs", "schema.sql"));
            fx.psqlFile(fx.DbName, fullfile(fx.RepoRoot, "design_docs", "grants.sql"));

            fx.RwPassword = "mt_" + string(dec2hex(randi([0 15], 24, 1))');
            fx.psql("postgres", "CREATE ROLE " + fx.RwRole + " LOGIN PASSWORD " + ...
                LabScratchDb.quote(fx.RwPassword) + " IN ROLE lab_rw;" + newline + ...
                "COMMENT ON ROLE " + fx.RwRole + " IS " + LabScratchDb.quote(fx.Marker) + ";");
            fx.CreatedRwRole = true;
            out = fx.psql(fx.DbName, "INSERT INTO lab.person (full_name, email) VALUES " + ...
                "('MATLAB tag tests', " + LabScratchDb.quote(fx.PersonEmail) + ") RETURNING person_id;");
            fx.PersonId = strtrim(string(regexp(out, ...
                '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', 'match', 'once')));
        end

        function dropLeftover(fx, what, probe, dropSql)
            out = strtrim(string(fx.psql("postgres", probe)));
            if strlength(out) == 0
                return   % does not exist
            end
            if out ~= fx.Marker
                error("LabScratchDb:exists", ...
                    "A %s named %s already exists and was not made by this fixture; " + ...
                    "it is left alone. Drop or rename it first.", what, ...
                    extractBefore(extractAfter(probe, "= '"), "'"));
            end
            fx.psql("postgres", dropSql);
        end

        function connect(fx)
            % Used by name inside evalc, which captures the constructor's output.
            u = fx.RwRole; p = fx.RwPassword; h = fx.Host; pt = fx.Port; d = fx.DbName; %#ok<NASGU>
            e = fx.PersonEmail; %#ok<NASGU>
            lastwarn("");
            dbObj = [];
            fx.ConnectOutput = string(evalc( ...
                "dbObj = CarasLabDB(Username=u, Password=p, Server=h, Port=pt, " + ...
                "DatabaseName=d, PersonEmail=e);"));
            [~, fx.ConnectWarningId] = lastwarn();
            fx.Db = dbObj;
            fx.Admin = CarasLabDB(Username=fx.AdminUser, Password=fx.AdminPassword, ...
                Server=fx.Host, Port=fx.Port, DatabaseName=fx.DbName);
            fx.RootId = fx.Db.addStorageRoot(Name="mtest-root", Description="MATLAB tag tests");
        end

        function out = psqlFile(fx, db, file)
            out = fx.runPsql(db, file);
        end

        function out = psql(fx, db, sql)
            f = string(tempname) + ".sql";
            fid = fopen(f, "w", "n", "UTF-8");
            fprintf(fid, "%s\n", sql);
            fclose(fid);
            cleanup = onCleanup(@() delete(f));
            out = fx.runPsql(db, f);
        end

        function out = runPsql(fx, db, file)
            %RUNPSQL psql -f FILE against database DB as the administrator.
            % Connection settings go in through the environment (restored
            % afterwards), so the command line holds only the database name
            % and the file name.
            names = ["PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE", ...
                     "PGCONNECT_TIMEOUT", "PATH"];
            saved = strings(size(names));
            for i = 1:numel(names)
                saved(i) = string(getenv(names(i)));
            end
            restore = onCleanup(@() LabScratchDb.setEnv(names, saved));
            setenv("PGHOST", fx.Host);
            setenv("PGPORT", string(fx.Port));
            setenv("PGUSER", fx.AdminUser);
            setenv("PGPASSWORD", fx.AdminPassword);
            setenv("PGDATABASE", "");
            setenv("PGCONNECT_TIMEOUT", "10");
            if strlength(fx.PgBin) > 0
                setenv("PATH", fx.PgBin + pathsep + saved(end));
            end
            cmd = "psql -X -q -A -t -w -v ON_ERROR_STOP=1 -d " + db + " -f """ + file + """ 2>&1";
            [status, out] = system(cmd);
            if status ~= 0
                error("LabScratchDb:psqlFailed", "psql failed (exit %d) on %s:\n%s", ...
                    status, file, out);
            end
        end
    end

    methods (Static, Access = private)
        function setEnv(names, values)
            for i = 1:numel(names)
                setenv(names(i), values(i));
            end
        end
    end
end
