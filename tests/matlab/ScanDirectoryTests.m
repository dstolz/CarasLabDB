classdef (SharedTestFixtures = {LabScratchDb}) ScanDirectoryTests < matlab.unittest.TestCase
%SCANDIRECTORYTESTS Tests of the CarasLabDB methods for the directories searched for new files.
%
%   results = runtests("tests/matlab/ScanDirectoryTests.m")
%   results = runtests("tests/matlab", Tag="NoDatabase")  % no server needed
%
%   Covered: getScanLayouts, getScanDirectories, addScanDirectory,
%   updateScanDirectory (every field, Clear=, the mode), getScanRuns,
%   getScanFiles (LatestPerFile, Status, PathPrefix, ScanRunId) and
%   canEditScanDirectories; the database's refusals (an equal, nested or
%   case-variant directory, an unknown time zone, a bad window, a frozen
%   column, a member without the privilege) reaching the caller with the
%   database's message; and the checks made in MATLAB before any SQL is
%   sent.
%
%   Like VARIABLETESTS, the tests tagged "Database" run against the scratch
%   database of the shared fixture LABSCRATCHDB (opt-in; see "help
%   LabScratchDb") and are reported as Incomplete without it; the
%   "NoDatabase" ones check input validation and the SQL sent, against
%   RECORDINGCONNECTION. lab.scan_directory is the schema owner's, so the
%   database tests write it as Fx.Admin; every directory lies under a path
%   unique to the test ("scan/<key>/...") and is switched off afterwards (a
%   directory with runs cannot be deleted; one that is off takes part in no
%   overlap).
%
%   See also VARIABLETESTS, LABSCRATCHDB, RECORDINGCONNECTION.

    properties
        Fx      % the LabScratchDb shared fixture
    end

    properties (Constant)
        Me = "'00000000-0000-0000-0000-000000000001'"
    end

    methods (TestClassSetup)
        function getFixture(tc)
            tc.Fx = tc.getSharedTestFixtures("LabScratchDb");
        end
    end

    % =====================================================================
    % Without a database
    % =====================================================================
    methods (Test, TestTags = {'NoDatabase'})
        function invalidInputSendsNoSql(tc)
            % The window (HH:mm, both or neither, not empty), whole
            % positive minutes, the mode, Clear= and the status are checked
            % before any statement is sent.
            [db, conn] = ScanDirectoryTests.recordingDb();
            base = ScanDirectoryTests.requiredArgs();
            windows = {
                {"WindowStart", "1:00", "WindowEnd", "05:00"}
                {"WindowStart", "01:00"}
                {"WindowEnd", "05:00"}
                {"WindowStart", "24:00", "WindowEnd", "01:00"}
                {"WindowStart", "01:60", "WindowEnd", "02:00"}
                {"WindowStart", "01:00:00", "WindowEnd", "02:00"}
                {"WindowStart", "01:00", "WindowEnd", " 01:00 "}
                {"WindowStart", "", "WindowEnd", "02:00"}};
            for i = 1:numel(windows)
                w = windows{i};
                tc.verifyError(@() db.addScanDirectory(base{:}, w{:}), "CarasLabDB:invalidWindow", ...
                    "addScanDirectory, window " + i);
                tc.verifyError(@() db.updateScanDirectory(5, w{:}), "CarasLabDB:invalidWindow", ...
                    "updateScanDirectory, window " + i);
            end
            tc.verifyError(@() db.addScanDirectory(base{:}, "Mode", "sometimes"), "CarasLabDB:invalidValue");
            tc.verifyError(@() db.updateScanDirectory(5, Mode="sometimes"), "CarasLabDB:invalidValue");
            tc.verifyError(@() db.updateScanDirectory(5, Clear="layout"), "CarasLabDB:invalidValue");
            tc.verifyError(@() db.updateScanDirectory(5, Clear="window_start"), "CarasLabDB:invalidValue");
            tc.verifyError(@() db.updateScanDirectory(5, Clear="window", WindowStart="01:00", ...
                WindowEnd="02:00"), "CarasLabDB:clearAndSet");
            tc.verifyError(@() db.updateScanDirectory(5, Clear="rig", Rig="r"), "CarasLabDB:clearAndSet");
            tc.verifyError(@() db.getScanDirectories(Mode="sometimes"), "CarasLabDB:invalidValue");
            tc.verifyError(@() db.getScanFiles(Status="lost"), "CarasLabDB:invalidValue");
            calls = {
                @() db.addScanDirectory(StorageRootId=1, RelativePath="a/b", Layout="epsych", ...
                        TimeZone="UTC", ScanIntervalMin=1.5)
                @() db.addScanDirectory(StorageRootId=1, RelativePath="a/b", Layout="epsych", ...
                        TimeZone="UTC", ScanIntervalMin=0)
                @() db.addScanDirectory(base{:}, "MinAgeMin", -1)
                @() db.addScanDirectory(base{:}, "MinAgeMin", 2.5)
                @() db.addScanDirectory(base{:}, "PairWith", 1.5)
                @() db.updateScanDirectory(5, ScanIntervalMin=0.5)
                @() db.updateScanDirectory(1.5, Rig="r")
                @() db.getScanRuns(Limit=-1)
                @() db.getScanFiles(ScanRunId=2.5)};
            for i = 1:numel(calls)
                tc.verifyError(calls{i}, ?MException, func2str(calls{i}));
            end
            tc.verifyEmpty(conn.Log, "SQL was sent: " + strjoin(conn.Log, newline));
        end

        function statementsAreSentAsDocumented(tc)
            % The SQL of each method. The fake connection returns no rows,
            % so a write ends in an error after its statement was recorded.
            [db, conn] = ScanDirectoryTests.recordingDb();
            me = ScanDirectoryTests.Me;
            want = {
                @() db.addScanDirectory(StorageRootId=3, RelativePath="rig1/epsych", Layout="epsych", ...
                        TimeZone="America/New_York", ScanIntervalMin=60, WindowStart=" 01:00", ...
                        WindowEnd="05:00", MinAgeMin=720, Mode="register", Rig="rig 1", PairWith=7, ...
                        Notes="it's")
                "INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, " + ...
                    "scan_interval_min, window_start, window_end, min_age_min, mode, rig, pair_with, " + ...
                    "notes, created_by) VALUES (3, 'rig1/epsych', 'epsych', 'America/New_York', 60, " + ...
                    "'01:00', '05:00', 720, 'register', 'rig 1', 7, 'it''s', " + me + ") " + ...
                    "RETURNING scan_directory_id;"
                @() db.addScanDirectory(StorageRootId=3, RelativePath="rig1/intan", Layout="intan", ...
                        TimeZone="UTC", ScanIntervalMin=15)
                "INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, " + ...
                    "scan_interval_min, created_by) VALUES (3, 'rig1/intan', 'intan', 'UTC', 15, " + ...
                    me + ") RETURNING scan_directory_id;"
                @() db.updateScanDirectory(5, Mode="off", ScanIntervalMin=30, Clear=["window", "notes"])
                "UPDATE lab.scan_directory SET scan_interval_min = 30, mode = 'off', window_start = NULL, " + ...
                    "window_end = NULL, notes = NULL WHERE scan_directory_id = 5 RETURNING scan_directory_id;"
                @() db.updateScanDirectory(5, StorageRootId=2, RelativePath="x/y", Layout="intan", ...
                        TimeZone="Europe/Berlin", WindowStart="22:00", WindowEnd="02:00", MinAgeMin=0, ...
                        Rig="r", PairWith=6, Notes="n")
                "UPDATE lab.scan_directory SET storage_root_id = 2, relative_path = 'x/y', layout = 'intan', " + ...
                    "time_zone = 'Europe/Berlin', window_start = '22:00', window_end = '02:00', " + ...
                    "min_age_min = 0, rig = 'r', pair_with = 6, notes = 'n' WHERE scan_directory_id = 5 " + ...
                    "RETURNING scan_directory_id;"
                @() db.updateScanDirectory(5, Clear=["rig", "pair_with"])
                "UPDATE lab.scan_directory SET rig = NULL, pair_with = NULL WHERE scan_directory_id = 5 " + ...
                    "RETURNING scan_directory_id;"
                @() db.getScanDirectories(StorageRootId=2, Mode="register")
                "SELECT * FROM lab.scan_directory_status WHERE storage_root_id = 2 AND mode = 'register' " + ...
                    "ORDER BY storage_root, relative_path, scan_directory_id"
                @() db.getScanDirectories(ScanDirectoryId=4)
                "SELECT * FROM lab.scan_directory_status WHERE scan_directory_id = 4 ORDER BY"
                @() db.getScanLayouts()
                "SELECT * FROM lab.scan_layout ORDER BY code"
                @() db.getScanRuns(ScanDirectoryId=5, Limit=10)
                " FROM lab.scan_run r LEFT JOIN lab.scan_run_result x ON x.scan_run_id = r.scan_run_id " + ...
                    "WHERE r.scan_directory_id = 5 ORDER BY r.scan_run_id DESC LIMIT 10"
                @() db.getScanRuns()
                "ON x.scan_run_id = r.scan_run_id ORDER BY r.scan_run_id DESC LIMIT 100"
                @() db.getScanRuns(Limit=0)
                "ON x.scan_run_id = r.scan_run_id ORDER BY r.scan_run_id DESC"
                @() db.getScanFiles(StorageRootId=2, PathPrefix="rig1/x_y/", Status="held")
                " FROM lab.scan_file_latest f JOIN lab.scan_run r ON r.scan_run_id = f.scan_run_id " + ...
                    "WHERE f.storage_root_id = 2 AND starts_with(f.relative_path, 'rig1/x_y/') AND " + ...
                    "f.status = 'held' ORDER BY f.storage_root_id, f.relative_path, f.scan_file_id"
                @() db.getScanFiles(ScanRunId=9, LatestPerFile=false)
                " FROM lab.scan_file f JOIN lab.scan_run r ON r.scan_run_id = f.scan_run_id " + ...
                    "WHERE f.scan_run_id = 9 ORDER BY"
                @() db.getScanFiles()
                "f.mtime_ns::text AS mtime_ns"
                @() db.canEditScanDirectories()
                "SELECT has_table_privilege(current_user, 'lab.scan_directory', 'INSERT') AS can_insert, " + ...
                    "has_table_privilege(current_user, 'lab.scan_directory', 'UPDATE') AS can_update"};
            for i = 1:2:numel(want)
                conn.clearLog();
                try
                    want{i}();
                catch
                    % only the statement matters here
                end
                tc.assertNotEmpty(conn.Log, func2str(want{i}));
                tc.verifySubstring(conn.Log(1), want{i + 1}, func2str(want{i}));
            end
            % getScanRuns(Limit=0) has no LIMIT at all.
            conn.clearLog();
            try
                db.getScanRuns(Limit=0);
            catch
            end
            tc.verifyFalse(contains(conn.Log(1), "LIMIT"), "Limit=0 means no cap");
        end

        function fetchedWritesAreInTransactionsAndReadsAreBare(tc)
            % As VariableTests checks for the other methods: a fetched write
            % runs inside a transaction, and a read has no trailing semicolon.
            [db, conn] = ScanDirectoryTests.recordingDb();
            base = ScanDirectoryTests.requiredArgs();
            calls = {
                @() db.addScanDirectory(base{:})
                @() db.updateScanDirectory(5, Rig="r")
                @() db.getScanDirectories()
                @() db.getScanLayouts()
                @() db.getScanRuns(ScanDirectoryId=5)
                @() db.getScanFiles(Status="held")
                @() db.canEditScanDirectories()};
            for i = 1:numel(calls)
                conn.clearLog();
                try
                    calls{i}();
                catch
                    % only what was sent matters here
                end
                tc.assertNotEmpty(conn.Log, func2str(calls{i}));
                for k = find(conn.LogVia == "fetch")'
                    sql = conn.Log(k);
                    if contains(sql, ["INSERT ", "UPDATE "])
                        tc.verifyTrue(conn.LogInTransaction(k), ...
                            "a write fetched outside a transaction: " + sql);
                    else
                        tc.verifyFalse(endsWith(strtrim(sql), ";"), ...
                            "a read sent with a trailing semicolon: " + sql);
                    end
                end
            end
            tc.verifyEqual(string(conn.AutoCommit), "on");
        end

        function callerTextStaysInsideLiterals(tc)
            % No identifier is built from caller text.
            [db, conn] = ScanDirectoryTests.recordingDb();
            bad = "x'); DROP TABLE lab.scan_directory; --";
            calls = {
                @() db.addScanDirectory(StorageRootId=1, RelativePath=bad, Layout=bad, TimeZone=bad, ...
                        ScanIntervalMin=60, Rig=bad, Notes=bad)
                @() db.updateScanDirectory(5, RelativePath=bad, Layout=bad, TimeZone=bad, Rig=bad, Notes=bad)
                @() db.getScanFiles(PathPrefix=bad)};
            for i = 1:numel(calls)
                try
                    calls{i}();
                catch
                    % The fake connection returns empty results; only the SQL matters.
                end
            end
            tc.assertSize(conn.Log, [numel(calls) 1]);
            tc.verifyTrue(all(contains(conn.Log, "DROP TABLE lab.scan_directory")), "the hostile text was sent");
            for sql = conn.Log'
                outside = regexprep(sql, "E?'(?:[^']|'')*'", "''");
                tc.verifyFalse(contains(outside, "DROP", IgnoreCase=true), sql);
            end
        end

        function defaultsPassValidationOnEveryRelease(tc)
            % No default value fails argument validation (R2024b validates
            % defaults eagerly).
            [db, ~] = ScanDirectoryTests.recordingDb();
            base = ScanDirectoryTests.requiredArgs();
            calls = {
                @() db.getScanLayouts()
                @() db.getScanDirectories()
                @() db.addScanDirectory(base{:})
                @() db.updateScanDirectory(5, Notes="n")
                @() db.getScanRuns()
                @() db.getScanFiles()
                @() db.canEditScanDirectories()};
            for i = 1:numel(calls)
                try
                    calls{i}();
                catch ME
                    isValidation = startsWith(string(ME.identifier), ["MATLAB:validators:", "MATLAB:validation:"]) ...
                        || contains(ME.message, "default value");
                    tc.verifyFalse(isValidation, func2str(calls{i}) + ": " + ME.message);
                end
            end
        end
    end

    % =====================================================================
    % Against the scratch database
    % =====================================================================
    methods (Test, TestTags = {'Database'})
        function addReadUpdateClearAndHistory(tc)
            % As the owner: a directory is added, read back column by
            % column, every field is changed, the window and the optional
            % fields are cleared, the mode is switched; row_history holds
            % each edit.
            adm = tc.requireAdmin();
            fx = tc.Fx;
            base = tc.newBase();

            other = adm.addScanDirectory(StorageRootId=fx.RootId, RelativePath=base + "/intan", ...
                Layout="intan", TimeZone="America/New_York", ScanIntervalMin=1440);
            id = adm.addScanDirectory(StorageRootId=fx.RootId, RelativePath=base + "/epsych", ...
                Layout="epsych", TimeZone="America/New_York", ScanIntervalMin=60, ...
                WindowStart="01:00", WindowEnd="05:00", MinAgeMin=120, Rig="rig A", Notes="first");
            tc.verifyClass(id, "double");
            tc.verifyNotEqual(id, other);

            T = adm.getScanDirectories(ScanDirectoryId=id);
            tc.assertEqual(height(T), 1);
            tc.verifyEqual(ScanDirectoryTests.num(T, "scan_directory_id"), id);
            tc.verifyEqual(ScanDirectoryTests.num(T, "storage_root_id"), fx.RootId);
            tc.verifyEqual(ScanDirectoryTests.txt(T, "storage_root"), "mtest-root");
            tc.verifyEqual(ScanDirectoryTests.txt(T, "relative_path"), base + "/epsych");
            tc.verifyEqual(ScanDirectoryTests.txt(T, "layout"), "epsych");
            tc.verifyEqual(ScanDirectoryTests.txt(T, "time_zone"), "America/New_York");
            tc.verifyEqual(ScanDirectoryTests.num(T, "scan_interval_min"), 60);
            tc.verifyEqual(ScanDirectoryTests.txt(T, "window_start_text"), "01:00");
            tc.verifyEqual(ScanDirectoryTests.txt(T, "window_end_text"), "05:00");
            tc.verifyEqual(ScanDirectoryTests.num(T, "min_age_min"), 120);
            tc.verifyEqual(ScanDirectoryTests.txt(T, "mode"), "report", "the default mode");
            tc.verifyEqual(ScanDirectoryTests.txt(T, "rig"), "rig A");
            tc.verifyEqual(ScanDirectoryTests.txt(T, "notes"), "first");
            tc.verifyTrue(ScanDirectoryTests.isNull(T, "pair_with"));
            tc.verifyEqual(ScanDirectoryTests.txt(T, "created_login"), fx.AdminUser, "stamped by the database");
            tc.verifyTrue(ScanDirectoryTests.isNull(T, "last_run_id"), "never searched");
            tc.verifyFalse(logical(T.is_running(1)));
            tc.verifyFalse(logical(T.is_overdue(1)), "just added");
            tc.verifyEqual(ScanDirectoryTests.num(T, "n_pending"), 0);
            tc.verifyEqual(ScanDirectoryTests.num(T, "n_held"), 0);
            tc.verifyEqual(height(tc.Fx.Db.getScanDirectories(ScanDirectoryId=id)), 1, "a member reads the list");
            tc.verifyTrue(ismember(id, ScanDirectoryTests.nums(adm.getScanDirectories(StorageRootId=fx.RootId, ...
                Mode="report"), "scan_directory_id")));

            % Every field.
            adm.updateScanDirectory(id, RelativePath=base + "/epsych2", Layout="intan", ...
                TimeZone="Europe/Berlin", ScanIntervalMin=1440, WindowStart="22:00", WindowEnd="02:00", ...
                MinAgeMin=0, Mode="register", Rig="rig B", PairWith=other, Notes="second");
            T = adm.getScanDirectories(ScanDirectoryId=id);
            tc.verifyEqual(ScanDirectoryTests.txt(T, "relative_path"), base + "/epsych2");
            tc.verifyEqual(ScanDirectoryTests.txt(T, "layout"), "intan");
            tc.verifyEqual(ScanDirectoryTests.txt(T, "time_zone"), "Europe/Berlin");
            tc.verifyEqual(ScanDirectoryTests.num(T, "scan_interval_min"), 1440);
            tc.verifyEqual(ScanDirectoryTests.txt(T, "window_start_text"), "22:00", "a window may wrap midnight");
            tc.verifyEqual(ScanDirectoryTests.txt(T, "window_end_text"), "02:00");
            tc.verifyEqual(ScanDirectoryTests.num(T, "min_age_min"), 0);
            tc.verifyEqual(ScanDirectoryTests.txt(T, "mode"), "register");
            tc.verifyEqual(ScanDirectoryTests.txt(T, "rig"), "rig B");
            tc.verifyEqual(ScanDirectoryTests.num(T, "pair_with"), other);
            tc.verifyEqual(ScanDirectoryTests.txt(T, "notes"), "second");

            % Clear the window and the optional fields.
            adm.updateScanDirectory(id, Clear=["window", "rig", "pair_with", "notes"]);
            T = adm.getScanDirectories(ScanDirectoryId=id);
            for c = ["window_start_text", "window_end_text", "rig", "pair_with", "notes"]
                tc.verifyTrue(ScanDirectoryTests.isNull(T, c), c + " is cleared");
            end
            tc.verifyEqual(ScanDirectoryTests.num(T, "scan_interval_min"), 1440, "the rest is left alone");

            % Another storage root (before any run, the root may change).
            root2 = adm.addStorageRoot(Name="mtest-scan-" + extractAfter(base, "scan/"));
            adm.updateScanDirectory(id, StorageRootId=root2);
            T = adm.getScanDirectories(ScanDirectoryId=id);
            tc.verifyEqual(ScanDirectoryTests.num(T, "storage_root_id"), root2);

            adm.updateScanDirectory(id, Mode="off");
            T = adm.getScanDirectories(ScanDirectoryId=id);
            tc.verifyEqual(ScanDirectoryTests.txt(T, "mode"), "off");
            tc.verifyFalse(logical(T.is_due(1)), "a directory that is off is never due");

            tc.verifyEqual(fx.rowHistoryCount("scan_directory", "scan_directory_id", string(id)), 4, ...
                "one row_history row per edit");
            H = fx.Db.runQuery("SELECT new_row ->> 'mode' AS mode, changed_by FROM lab.row_history " + ...
                "WHERE table_name = 'scan_directory' AND row_key ->> 'scan_directory_id' = " + ...
                LabScratchDb.quote(string(id)) + " ORDER BY history_id DESC LIMIT 1");
            tc.verifyEqual(ScanDirectoryTests.txt(H, "mode"), "off");
            tc.verifyEqual(ScanDirectoryTests.txt(H, "changed_by"), fx.AdminUser);
            tc.verifyError(@() adm.updateScanDirectory(-5, Rig="x"), "CarasLabDB:scanDirectoryNotFound");
        end

        function overlapsTimeZonesAndWindowsAreRefused(tc)
            % The database's refusals reach the caller with its message: an
            % equal, nested or case-variant directory, an unknown time zone,
            % a window broken past MATLAB's check. A directory that is off
            % takes no part, which frees its path.
            adm = tc.requireAdmin();
            fx = tc.Fx;
            base = tc.newBase();
            add = @(rel) adm.addScanDirectory(StorageRootId=fx.RootId, RelativePath=rel, ...
                Layout="epsych", TimeZone="America/New_York", ScanIntervalMin=60);
            a = add(base + "/a");
            overlap = "is the same directory, contains it or lies inside it";
            for rel = [base + "/a", base + "/a/inner", base, base + "/A", upper(base) + "/a"]
                err = tc.errorOf(@() add(rel));
                tc.verifySubstring(string(err.message), overlap, rel);
            end
            err = tc.errorOf(@() adm.addScanDirectory(StorageRootId=fx.RootId, ...
                RelativePath=base + "/tz", Layout="epsych", TimeZone="Mars/Olympus_Mons", ...
                ScanIntervalMin=60));
            tc.verifySubstring(string(err.message), "is not a time zone name this server knows");
            err = tc.errorOf(@() adm.runCommand("INSERT INTO lab.scan_directory (storage_root_id, " + ...
                "relative_path, layout, time_zone, scan_interval_min, window_start) VALUES (" + ...
                string(fx.RootId) + ", " + LabScratchDb.quote(base + "/rawwin") + ", 'epsych', " + ...
                "'America/New_York', 60, '01:00')"));
            tc.verifySubstring(string(err.message), "scan_directory_window_ck", "one window time only");
            tc.verifyError(@() adm.addScanDirectory(StorageRootId=fx.RootId, RelativePath=base + "/w", ...
                Layout="epsych", TimeZone="UTC", ScanIntervalMin=60, WindowStart="1:00", ...
                WindowEnd="05:00"), ...
                "CarasLabDB:invalidWindow", "refused in MATLAB before it is sent");
            tc.verifyEqual(nnz(startsWith(ScanDirectoryTests.texts( ...
                adm.getScanDirectories(StorageRootId=fx.RootId), "relative_path"), base + "/")), 1, ...
                "nothing refused was written");

            % Off frees the path; the new row is the one compared then.
            adm.updateScanDirectory(a, Mode="off");
            b = add(base + "/a");
            tc.verifyNotEqual(b, a);
            err = tc.errorOf(@() adm.updateScanDirectory(a, Mode="report"));
            tc.verifySubstring(string(err.message), overlap, "turning the old one on again");

            % Once searched, root, path, layout and time zone are frozen.
            adm.runCommand("INSERT INTO lab.scan_run (scan_directory_id, command, mode) VALUES (" + ...
                string(b) + ", 'run', 'report')");
            for change = {{"RelativePath", base + "/b2"}, {"Layout", "intan"}, ...
                    {"TimeZone", "Europe/Berlin"}}
                c = change{1};
                err = tc.errorOf(@() adm.updateScanDirectory(b, c{:}));
                tc.verifySubstring(string(err.message), "has been searched", c{1});
            end
            adm.updateScanDirectory(b, Rig="still editable", ScanIntervalMin=30);
            T = adm.getScanDirectories(ScanDirectoryId=b);
            tc.verifyEqual(ScanDirectoryTests.txt(T, "rig"), "still editable");
            tc.verifyEqual(ScanDirectoryTests.num(T, "scan_interval_min"), 30);
            tc.verifyEqual(ScanDirectoryTests.txt(T, "relative_path"), base + "/a");
            tc.verifyEqual(string(adm.Connection.AutoCommit), "on");
        end

        function onlyTheOwnerMayEditTheList(tc)
            % A member reads the list but may not add or change a directory;
            % canEditScanDirectories says so, separately for each.
            adm = tc.requireAdmin();
            db = tc.Fx.Db;
            fx = tc.Fx;
            base = tc.newBase();

            c = db.canEditScanDirectories();
            tc.verifyEqual([c.Insert, c.Update], [false, false], "a member of lab_rw");
            tc.verifyEqual(c.Login, LabScratchDb.RwRole);
            c = adm.canEditScanDirectories();
            tc.verifyEqual([c.Insert, c.Update], [true, true], "the owner");
            tc.verifyEqual(c.Login, fx.AdminUser);

            id = adm.addScanDirectory(StorageRootId=fx.RootId, RelativePath=base + "/owner", ...
                Layout="epsych", TimeZone="UTC", ScanIntervalMin=60, Notes="owner's");
            err = tc.errorOf(@() db.addScanDirectory(StorageRootId=fx.RootId, ...
                RelativePath=base + "/member", Layout="epsych", TimeZone="UTC", ScanIntervalMin=60));
            tc.verifySubstring(string(err.message), "permission denied");
            err = tc.errorOf(@() db.updateScanDirectory(id, Notes="member's"));
            tc.verifySubstring(string(err.message), "permission denied");
            tc.verifyEqual(ScanDirectoryTests.txt(db.getScanDirectories(ScanDirectoryId=id), "notes"), ...
                "owner's", "nothing was changed");
            tc.verifyEqual(nnz(startsWith(ScanDirectoryTests.texts( ...
                db.getScanDirectories(StorageRootId=fx.RootId), "relative_path"), base + "/")), 1);
            tc.verifyEqual(string(db.Connection.AutoCommit), "on");
        end

        function runsAndTheScanMemoryAreRead(tc)
            % getScanRuns joins each run's result (none: running or
            % interrupted); getScanFiles reads the latest row per file or
            % the whole log; the status view counts held files.
            adm = tc.requireAdmin();
            fx = tc.Fx;
            base = tc.newBase();
            id = adm.addScanDirectory(StorageRootId=fx.RootId, RelativePath=base, Layout="epsych", ...
                TimeZone="UTC", ScanIntervalMin=60);
            sid = string(id);
            root = string(fx.RootId);
            runId = @() double(fx.scalar("SELECT max(scan_run_id) AS id FROM lab.scan_run " + ...
                "WHERE scan_directory_id = " + sid));
            q = @(s) LabScratchDb.quote(s);

            adm.runCommand("INSERT INTO lab.scan_run (scan_directory_id, command, mode, tool_version, " + ...
                "host) VALUES (" + sid + ", 'run', 'report', 'mt', 'mt-host')");
            r1 = runId();
            adm.runCommand("INSERT INTO lab.scan_run_result (scan_run_id, outcome, files_listed, " + ...
                "files_pending, files_held, message) VALUES (" + string(r1) + ", 'ok', 3, 1, 1, 'fine')");
            adm.runCommand("INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, " + ...
                "size_bytes, mtime_ns, group_key, status, reason_code, reason) VALUES " + ...
                "(" + string(r1) + ", " + root + ", " + q(base + "/x/f1.dat") + ", 10, " + ...
                "1700000000123456789, 'g1', 'pending', NULL, NULL), " + ...
                "(" + string(r1) + ", " + root + ", " + q(base + "/x/f2.dat") + ", 20, " + ...
                "1700000000987654321, 'g1', 'held', 'unknown_subject', 'no subject MT-none')");
            adm.runCommand("INSERT INTO lab.scan_run (scan_directory_id, command, mode) VALUES (" + ...
                sid + ", 'apply', 'register')");
            r2 = runId();
            adm.runCommand("INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, " + ...
                "group_key, status) VALUES (" + string(r2) + ", " + root + ", " + ...
                q(base + "/x/f1.dat") + ", 'g1', 'cleared')");

            R = adm.getScanRuns(ScanDirectoryId=id);
            tc.assertEqual(height(R), 2);
            tc.verifyEqual(ScanDirectoryTests.nums(R, "scan_run_id"), [r2; r1], "newest first");
            tc.verifyEqual(ScanDirectoryTests.texts(R, "command"), ["apply"; "run"]);
            tc.verifyEqual(reshape(logical(R.has_result), [], 1), [false; true]);
            tc.verifyEqual(reshape(logical(R.is_running), [], 1), [true; false], ...
                "no result, started just now: running");
            tc.verifyTrue(ScanDirectoryTests.isNull(R(1, :), "outcome"));
            tc.verifyEqual(ScanDirectoryTests.txt(R(2, :), "outcome"), "ok");
            tc.verifyEqual(ScanDirectoryTests.num(R(2, :), "files_listed"), 3);
            tc.verifyEqual(ScanDirectoryTests.txt(R(2, :), "message"), "fine");
            tc.verifyEqual(ScanDirectoryTests.txt(R(2, :), "host"), "mt-host");
            tc.verifyEqual(ScanDirectoryTests.txt(R(1, :), "run_login"), fx.AdminUser, "stamped");
            R = adm.getScanRuns(ScanDirectoryId=id, Limit=1);
            tc.verifyEqual(ScanDirectoryTests.nums(R, "scan_run_id"), r2);

            S = fx.Db.getScanDirectories(ScanDirectoryId=id);
            tc.verifyEqual(ScanDirectoryTests.num(S, "last_run_id"), r2);
            tc.verifyTrue(logical(S.is_running(1)));
            tc.verifyTrue(ScanDirectoryTests.isNull(S, "last_run_outcome"));
            tc.verifyEqual(ScanDirectoryTests.num(S, "n_pending"), 0, "f1's latest row is cleared");
            tc.verifyEqual(ScanDirectoryTests.num(S, "n_held"), 1);

            L = fx.Db.getScanFiles(StorageRootId=fx.RootId, PathPrefix=base + "/");
            tc.verifyEqual(ScanDirectoryTests.texts(L, "relative_path"), [base + "/x/f1.dat"; base + "/x/f2.dat"]);
            tc.verifyEqual(ScanDirectoryTests.texts(L, "status"), ["cleared"; "held"], "the latest row per file");
            tc.verifyEqual(ScanDirectoryTests.nums(L, "scan_directory_id"), [id; id]);
            Hd = fx.Db.getScanFiles(Status="held", StorageRootId=fx.RootId, PathPrefix=base + "/");
            tc.assertEqual(height(Hd), 1);
            tc.verifyEqual(ScanDirectoryTests.txt(Hd, "reason_code"), "unknown_subject");
            tc.verifyEqual(ScanDirectoryTests.txt(Hd, "reason"), "no subject MT-none");
            tc.verifyEqual(ScanDirectoryTests.txt(Hd, "mtime_ns"), "1700000000987654321", ...
                "mtime_ns exact, as text");
            tc.verifyEqual(ScanDirectoryTests.num(Hd, "size_bytes"), 20);
            tc.verifyEqual(height(fx.Db.getScanFiles(Status="pending", StorageRootId=fx.RootId, ...
                PathPrefix=base + "/")), 0, "f1 is no longer pending");
            tc.verifyEqual(height(fx.Db.getScanFiles(StorageRootId=fx.RootId, PathPrefix=base + "/", ...
                LatestPerFile=false)), 3, "the whole log");
            tc.verifyEqual(height(fx.Db.getScanFiles(ScanRunId=r1, LatestPerFile=false)), 2);
            tc.verifyEqual(height(fx.Db.getScanFiles(Status="pending", ScanRunId=r1, ...
                LatestPerFile=false)), 1);
            tc.verifyEqual(height(fx.Db.getScanFiles(StorageRootId=fx.RootId, ...
                PathPrefix=upper(base) + "/")), 0, "PathPrefix compares case");

            err = tc.errorOf(@() adm.updateScanDirectory(id, Layout="intan"));
            tc.verifySubstring(string(err.message), "has been searched");
        end
    end

    % =====================================================================
    % Helpers
    % =====================================================================
    methods (Access = private)
        function adm = requireAdmin(tc)
            tc.assumeTrue(tc.Fx.Available, tc.Fx.Reason);
            adm = tc.Fx.Admin;
        end

        function base = newBase(tc)
            %NEWBASE A path of this test's own ("scan/scan-<n>"), switched off afterwards.
            base = "scan/scan-" + tc.Fx.next();
            adm = tc.Fx.Admin;
            tc.addTeardown(@() ScanDirectoryTests.switchOff(adm, base));
        end

        function err = errorOf(tc, fn)
            %ERROROF The MException FN throws; a verification failure if none.
            err = [];
            try
                fn();
            catch err
            end
            if isempty(err)
                tc.verifyFail("expected an error from " + func2str(fn) + ", but it succeeded");
                err = MException("ScanDirectoryTests:noError", "(no error)");
            end
        end
    end

    methods (Static)
        function switchOff(adm, base)
            %SWITCHOFF Turn off every directory under BASE (one with runs cannot be deleted).
            try
                adm.runCommand("UPDATE lab.scan_directory SET mode = 'off' WHERE mode <> 'off' AND " + ...
                    "(relative_path = " + LabScratchDb.quote(base) + " OR starts_with(relative_path, " + ...
                    LabScratchDb.quote(base + "/") + "))");
            catch
            end
        end
    end

    methods (Static, Access = private)
        function [db, conn] = recordingDb()
            conn = RecordingConnection();
            db = CarasLabDB(Connection=conn, PersonId="00000000-0000-0000-0000-000000000001");
            conn.clearLog();
        end

        function args = requiredArgs()
            args = {"StorageRootId", 1, "RelativePath", "a/b", "Layout", "epsych", ...
                "TimeZone", "UTC", "ScanIntervalMin", 60};
        end

        function v = first(T, col)
            %FIRST The value in the first row of column COL (a cell unwrapped).
            v = T.(char(col));
            if iscell(v)
                v = v{1};
            elseif ~isempty(v)
                v = v(1);
            end
        end

        function s = txt(T, col)
            %TXT The first row's COL as a string (missing for NULL).
            v = ScanDirectoryTests.first(T, col);
            if isempty(v) || (isnumeric(v) && isnan(v))
                s = string(missing);
            else
                s = string(v);
            end
        end

        function x = num(T, col)
            %NUM The first row's COL as a double (NaN for NULL).
            v = ScanDirectoryTests.first(T, col);
            if isempty(v) || (isstring(v) && ismissing(v))
                x = NaN;
            else
                x = double(v);
            end
        end

        function tf = isNull(T, col)
            %ISNULL Whether the first row's COL is NULL, however the driver spells it.
            v = ScanDirectoryTests.first(T, col);
            if isempty(v)
                tf = true;
            elseif isstring(v)
                tf = ismissing(v) || strlength(v) == 0;
            elseif isnumeric(v)
                tf = isnan(double(v));
            elseif isdatetime(v)
                tf = isnat(v);
            else
                tf = false;
            end
        end

        function s = texts(T, col)
            %TEXTS Column COL as a string column (0x1 when T is empty).
            s = LabScratchDb.column(T, col);
        end

        function x = nums(T, col)
            %NUMS Column COL as a double column.
            if height(T) == 0
                x = zeros(0, 1);
            else
                x = double(reshape(T.(char(col)), [], 1));
            end
        end
    end
end
