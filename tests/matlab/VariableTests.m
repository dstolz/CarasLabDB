classdef (SharedTestFixtures = {LabScratchDb}) VariableTests < matlab.unittest.TestCase
%VARIABLETESTS Tests of the schema version 5 features of the CarasLabDB class.
%
%   results = runtests("tests/matlab/VariableTests.m")
%   results = runtests("tests/matlab", Tag="NoDatabase")  % no server needed
%
%   Covered: user-defined variables (set, update, unset, history, units and
%   type mismatches, definitions), retraction, the current person taken from
%   the database login, ActiveOnly=false reading the *_version views,
%   checkIntegrity, addHusbandryBatch, and addArtifactFromFile /
%   fileChecksum against known hashes.
%
%   Like TAGTESTS, the tests tagged "Database" run against the scratch
%   database of the shared fixture LABSCRATCHDB (opt-in; see "help
%   LabScratchDb") and are reported as Incomplete without it; the
%   "NoDatabase" ones check input validation and the SQL sent, against
%   RECORDINGCONNECTION. Variable names are made unique with the fixture's
%   counter, so the tests do not depend on each other's definitions.
%
%   See also TAGTESTS, LABSCRATCHDB, RECORDINGCONNECTION.

    properties
        Fx      % the LabScratchDb shared fixture
    end

    properties (Constant)
        FakeId = "00000000-0000-0000-0000-000000000002"
        % SHA-256 / MD5 of the three bytes 'abc', and of no bytes at all.
        AbcSha256   = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        AbcMd5      = "900150983cd24fb0d6963f7d28e17f72"
        EmptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        % SHA-256 of the 8*2^20 + 5 bytes mod(0:n-1, 251): longer than one
        % chunk of fileChecksum, and holding every byte value above 127.
        BigSha256   = "75934ec6907d95413c119970cc9a88dccecccd86bdfbcee656af4e3c520e5a89"
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
        function variableNamesAreCanonicalised(tc)
            % Lower case, runs of whitespace to one space, ends trimmed;
            % anything else malformed is refused, never rewritten.
            tc.verifyEqual(CarasLabDB.normalizeVariableName(" Probe   Depth "), "probe depth");
            tc.verifyEqual(CarasLabDB.normalizeVariableName(sprintf("Probe\tDepth\n")), "probe depth");
            tc.verifyEqual(CarasLabDB.normalizeVariableName(["Housing", "ISI_ms", "probe-depth 2"]), ...
                ["housing", "isi_ms", "probe-depth 2"]);
            longest = string(repmat('a', 1, 63));
            tc.verifyEqual(CarasLabDB.normalizeVariableName(longest), longest);
            for x = ["", "   ", "1depth", "_depth", "depth (um)", "probe.depth", "o'brien", ...
                     longest + "a"]
                tc.verifyError(@() CarasLabDB.normalizeVariableName(x), ...
                    "CarasLabDB:invalidVariableName", "input '" + x + "'");
            end
            tc.verifyError(@() CarasLabDB.normalizeVariableName(string(missing)), ...
                "CarasLabDB:invalidVariableName");
            tc.verifyError(@() CarasLabDB.normalizeVariableName(["depth", "probe.depth"]), ...
                "CarasLabDB:invalidVariableName", "one bad element fails the whole array");
        end

        function invalidInputSendsNoSql(tc)
            % A value that is not one finite number or one non-blank string,
            % a malformed name, an unknown kind and a blank retraction
            % reason all fail before any statement is sent.
            [db, conn] = VariableTests.recordingDb();
            id = VariableTests.FakeId;
            for v = {NaN, Inf, [1 2], "", "   ", string(missing), ["a", "b"], true, {}, missing}
                tc.verifyError(@() db.setVariable("session", id, "depth", v{1}), ...
                    "CarasLabDB:invalidVariableValue", class(v{1}));
            end
            calls = {
                @() db.setVariable("session", id, "depth (um)", 1)
                @() db.unsetVariable("session", id, "1depth")
                @() db.getVariableValues("probe.depth")
                @() db.defineVariable("")
                @() db.setVariable("foo", id, "depth", 1)
                @() db.getVariables("foo", id)
                @() db.getVariableValues("depth", Kind="foo")
                @() db.defineVariable("depth", AppliesTo=["session", "foo"])
                @() db.defineVariable("depth", ValueType="integer")
                @() db.getRetractions(Kind="subject")
                @() db.retractEvent(id, "   ")
                @() db.retractArtifact(id, string(missing))};
            for i = 1:numel(calls)
                tc.verifyError(calls{i}, ?MException, func2str(calls{i}));
            end
            tc.verifyError(@() db.retractEvent(id, ""), "CarasLabDB:reasonRequired");
            tc.verifyEmpty(conn.Log, "SQL was sent: " + strjoin(conn.Log, newline));
        end

        function statementsAreSentAsDocumented(tc)
            % The SQL of the write entry points, and which relation the
            % readers use. The fake connection returns no rows, so each call
            % ends in an error after its statement was recorded.
            [db, conn] = VariableTests.recordingDb();
            id = VariableTests.FakeId;
            me = "'00000000-0000-0000-0000-000000000001'::uuid";
            want = {
                @() db.setVariable("session", id, " Probe  Depth ", 71.9, Units="um", Note="it's deep")
                "lab.fn_set_variable('session', '" + id + "', 'probe depth', p_number => 71.9, " + ...
                    "p_units => 'um', p_label => NULL, p_description => NULL, " + ...
                    "p_note => 'it''s deep', p_by => " + me + ")"
                @() db.setVariable("subject", "S-1", "Housing", 'pair')
                "lab.fn_set_variable('subject', 'S-1', 'housing', p_text => 'pair', p_units => NULL"
                @() db.setVariable("event", id, "count", int32(-3))
                "p_number => -3, "
                @() db.unsetVariable("session", id, "Probe Depth", Note="wrong probe")
                "lab.fn_unset_variable('session', '" + id + "', 'probe depth', 'wrong probe', " + me + ")"
                @() db.defineVariable("Weight at Surgery", Units="g", AppliesTo=["subject", "event"])
                "lab.fn_define_variable('weight at surgery', 'number', p_units => 'g', " + ...
                    "p_label => NULL, p_description => NULL, p_applies_to => '{event,subject}'::text[], " + ...
                    "p_by => " + me + ")"
                @() db.defineVariable("housing", ValueType="text")
                "lab.fn_define_variable('housing', 'text', p_units => NULL, p_label => NULL, " + ...
                    "p_description => NULL, p_applies_to => NULL::text[]"
                @() db.retractEvent(id, "entered twice")
                "lab.fn_retract('event', '" + id + "'::uuid, 'entered twice', " + me + ")"
                @() db.retractArtifact(id, "wrong path")
                "lab.fn_retract('artifact', '" + id + "'::uuid, 'wrong path', " + me + ")"
                @() db.getVariables("session", id)
                "FROM lab.variable_current x WHERE x.entity_kind = 'session' AND x.session_id = '" + id + "'"
                @() db.getVariables("subject", "S-1", History=true)
                "FROM lab.variable_value x WHERE x.entity_kind = 'subject' AND x.subject_id = 'S-1' ORDER BY x.value_id"
                @() db.getVariableValues("Probe Depth", Kind="event", ActiveOnly=false)
                "c WHERE c.variable = 'probe depth' AND c.entity_kind = 'event' ORDER BY"
                @() db.getVariableDefinitions()
                "FROM lab.variable WHERE retired_at IS NULL ORDER BY name"
                @() db.getEvents()
                "FROM lab.event_active ORDER BY"
                @() db.getEvents(ActiveOnly=false)
                "FROM lab.event_version ORDER BY"
                @() db.getArtifacts(ActiveOnly=false, SubjectId="S-1")
                "FROM lab.artifact_version WHERE subject_id = 'S-1'"
                @() db.getRetractions(Kind="event")
                "FROM lab.retraction WHERE entity_kind = 'event' ORDER BY retraction_id"
                @() db.checkIntegrity()
                "FROM lab.fn_check_integrity() ORDER BY (severity = 'error') DESC"};
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
        end

        function fetchedWritesAreInTransactionsAndReadsAreBare(tc)
            % What the Database Toolbox does with a fetch decides how each
            % statement must be sent (see CarasLabDB.pSelect / pWrite): a
            % statement that writes and returns rows goes inside a
            % transaction, and any other fetch has no trailing semicolon.
            [db, conn] = VariableTests.recordingDb();
            id = VariableTests.FakeId;
            calls = {
                @() db.addPerson(FullName="P")
                @() db.addProject(Name="p")
                @() db.addStorageRoot(Name="r")
                @() db.addSession(SubjectId="S-1", Label="l", StorageRootId=1, RelativePath="a/b")
                @() db.updateSubject("S-1", Strain="x")
                @() db.updateSession(id, Rig="r")
                @() db.addTag("artifact", id, "topic:x")
                @() db.removeTag("artifact", id, ["topic:x", "topic:y"])
                @() db.retireTag("topic:x")
                @() db.setVariable("session", id, "depth", 1)
                @() db.unsetVariable("session", id, "depth")
                @() db.defineVariable("depth")
                @() db.retractEvent(id, "entered twice")
                @() db.getEvents()
                @() db.getArtifacts(SubjectId="S-1")
                @() db.getVariables("session", id)
                @() db.getEntityTags("artifact", id)
                @() db.checkIntegrity()
                @() db.artifactLineage(id)
                @() db.runQuery("SELECT 1 AS one;")};
            writes = ["INSERT ", "UPDATE ", "DELETE ", "fn_tag(", "fn_set_variable(", ...
                "fn_unset_variable(", "fn_define_variable(", "fn_retract(", "fn_rename_subject("];
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
                    if contains(sql, writes)
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
            % No identifier is built from caller text: hostile ids, values,
            % notes and reasons reach the SQL only inside quoted literals.
            [db, conn] = VariableTests.recordingDb();
            bad = "x'); DROP TABLE lab.variable; --";
            calls = {
                @() db.setVariable("subject", bad, "depth", bad, Units=bad, Label=bad, ...
                        Description=bad, Note=bad, SetBy=bad)
                @() db.unsetVariable("subject", bad, "depth", Note=bad)
                @() db.getVariables("subject", bad)
                @() db.getVariables("event", bad, History=true)
                @() db.defineVariable("depth", Units=bad, Label=bad, Description=bad)
                @() db.updateVariableDefinition("depth", Label=bad, Description=bad)
                @() db.retractEvent(bad, bad)
                @() db.retractArtifact(bad, bad, RetractedBy=bad)
                @() db.getRetractions(EventId=bad, ArtifactId=bad)};
            for i = 1:numel(calls)
                try
                    calls{i}();
                catch
                    % The fake connection returns empty results; only the SQL matters.
                end
            end
            tc.assertSize(conn.Log, [numel(calls) 1]);
            tc.verifyTrue(all(contains(conn.Log, "DROP TABLE lab.variable")), "the hostile text was sent");
            for sql = conn.Log'
                outside = regexprep(sql, "E?'(?:[^']|'')*'", "''");
                tc.verifyFalse(contains(outside, "DROP", IgnoreCase=true), sql);
            end
        end

        function personComesFromTheLogin(tc)
            % With no PersonId / PersonEmail / PersonName the current person
            % is the one lab.fn_current_person() returns; only when that is
            % NULL too does construction warn.
            pid = "00000000-0000-0000-0000-00000000abcd";
            conn = RecordingConnection();
            conn.LoginPersonId = pid;
            db = tc.verifyWarningFree(@() CarasLabDB(Connection=conn));
            tc.verifyEqual(db.CurrentPersonId, pid);
            tc.verifyTrue(any(contains(conn.Log, "lab.fn_current_person()")));

            % A named person wins, and the login is then not asked.
            conn.clearLog();
            db.setPerson(PersonId="00000000-0000-0000-0000-000000000001");
            tc.verifyEqual(db.CurrentPersonId, "00000000-0000-0000-0000-000000000001");
            tc.verifyFalse(any(contains(conn.Log, "fn_current_person")));
            db.setPerson();     % back to the login's person
            tc.verifyEqual(db.CurrentPersonId, pid);

            unmapped = RecordingConnection();
            db2 = tc.verifyWarning(@() CarasLabDB(Connection=unmapped), "CarasLabDB:noCurrentPerson");
            tc.verifyTrue(ismissing(db2.CurrentPersonId));

            % An older schema has no lab.fn_current_person: it is not called.
            old = RecordingConnection();
            old.SchemaVersion = 4;
            old.LoginPersonId = pid;
            db3 = tc.verifyWarning(@() CarasLabDB(Connection=old, AllowSchemaMismatch=true), ...
                "CarasLabDB:noCurrentPerson");
            tc.verifyTrue(ismissing(db3.CurrentPersonId));
            tc.verifyFalse(any(contains(old.Log, "fn_current_person")));
        end

        function husbandryBatchValidatesBeforeWriting(tc)
            % A sheet with a bad row writes nothing at all; a row with no
            % value is skipped; the first statement of a good sheet is the
            % first row's event.
            [db, conn] = VariableTests.recordingDb();
            t = datetime(2026, 11, 2, 9, 30, 0, "TimeZone", "UTC");
            sheet = @(w) table(["S-1"; "S-2"; "S-3"], w(:), 'VariableNames', {'subject_id', 'weight_g'});
            bad = {
                table([70; 71], 'VariableNames', {'weight_g'})                       % no subject_id
                table(["S-1"; "S-2"], 'VariableNames', {'subject_id'})               % no value variable
                sheet([70 -1 NaN])                                                   % negative weight
                sheet([70 0 NaN])                                                    % zero weight
                sheet([70 Inf NaN])
                table(["S-1"; ""], [70; 71], 'VariableNames', {'subject_id', 'weight_g'})
                table(["S-1"; "S-2"], [1; -0.5], 'VariableNames', {'subject_id', 'water_ml'})
                table(["S-1"; "S-2"], ["70"; "71"], 'VariableNames', {'subject_id', 'weight_g'})};
            for i = 1:numel(bad)
                tc.verifyError(@() db.addHusbandryBatch(bad{i}, OccurredAt=t), ...
                    "CarasLabDB:invalidValue", "sheet " + i);
            end
            tc.verifyError(@() db.addHusbandryBatch(sheet([70 71 72]), OccurredAt=t, Measure=" "), ...
                "CarasLabDB:invalidValue");
            tc.verifyEmpty(conn.Log, "a refused sheet sent SQL");

            ids = db.addHusbandryBatch(sheet([NaN NaN NaN]), OccurredAt=t);
            tc.verifySize(ids, [3 1]);
            tc.verifyTrue(all(ismissing(ids)), "no row has a value");
            ids = db.addHusbandryBatch(sheet([NaN NaN NaN]));       % OccurredAt defaults to now
            tc.verifyTrue(all(ismissing(ids)));
            tc.verifyEmpty(conn.Log, "a sheet with no value sent SQL");

            % The fake connection returns no event_id, so the first insert
            % raises -- after which AutoCommit must be back on.
            tc.verifyError(@() db.addHusbandryBatch(sheet([NaN 71.9 68]), OccurredAt=t, Notes="weekly"), ...
                "CarasLabDB:insertFailed");
            tc.assertSize(conn.Log, [1 1]);
            tc.verifySubstring(conn.Log(1), "INSERT INTO lab.event (event_type, occurred_at, subject_id, " + ...
                "notes, recorded_by) VALUES ('husbandry', TIMESTAMPTZ '2026-11-02 09:30:00.000000+00:00', " + ...
                "'S-2', 'weekly', '00000000-0000-0000-0000-000000000001') RETURNING event_id;");
            tc.verifyEqual(string(conn.AutoCommit), "on");
        end

        function fileChecksumMatchesKnownHashes(tc)
            % fileChecksum against published test vectors and a file longer
            % than one read chunk. This is the check its help text asks for.
            tc.assumeTrue(usejava('jvm'), "fileChecksum needs the JVM");
            folder = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            abc = VariableTests.writeBytes(fullfile(folder, "abc.txt"), uint8('abc'));
            none = VariableTests.writeBytes(fullfile(folder, "empty.bin"), uint8([]));
            n = 8 * 2^20 + 5;
            big = VariableTests.writeBytes(fullfile(folder, "big.bin"), uint8(mod(0:n-1, 251)));

            tc.verifyEqual(CarasLabDB.fileChecksum(abc), VariableTests.AbcSha256);
            tc.verifyEqual(CarasLabDB.fileChecksum(abc, Algo="sha256"), VariableTests.AbcSha256);
            tc.verifyEqual(CarasLabDB.fileChecksum(abc, Algo="md5"), VariableTests.AbcMd5);
            tc.verifyEqual(CarasLabDB.fileChecksum(none), VariableTests.EmptySha256);
            tc.verifyEqual(CarasLabDB.fileChecksum(big), VariableTests.BigSha256);
            tc.verifyError(@() CarasLabDB.fileChecksum(fullfile(folder, "no_such_file")), ...
                "CarasLabDB:fileNotFound");
            tc.verifyError(@() CarasLabDB.fileChecksum(abc, Algo="sha1"), "MATLAB:validators:mustBeMember");
        end

        function artifactFromFileWorksOutPathSizeAndChecksum(tc)
            % The path relative to RootPath (forward slashes), the size and
            % the SHA-256 reach the INSERT; a file outside RootPath is
            % refused before anything is sent.
            tc.assumeTrue(usejava('jvm'), "fileChecksum needs the JVM");
            [db, conn] = VariableTests.recordingDb();
            id = VariableTests.FakeId;
            root = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            other = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            mkdir(fullfile(root, "G-1", "sess 1"));
            file = VariableTests.writeBytes(fullfile(root, "G-1", "sess 1", "Raw.DAT"), uint8('abc'));
            outside = VariableTests.writeBytes(fullfile(other, "raw.dat"), uint8('abc'));

            tc.verifyError(@() db.addArtifactFromFile(outside, ProducedByEventId=id, ...
                StorageRootId=1, RootPath=root), "CarasLabDB:fileNotUnderRoot");
            tc.verifyError(@() db.addArtifactFromFile(fullfile(root, "nope.dat"), ProducedByEventId=id, ...
                StorageRootId=1, RootPath=root), "CarasLabDB:fileNotFound");
            tc.verifyError(@() db.addArtifactFromFile(fullfile(root, "G-1"), ProducedByEventId=id, ...
                StorageRootId=1, RootPath=root), "CarasLabDB:fileNotFound");
            tc.verifyError(@() db.addArtifactFromFile(file, ProducedByEventId=id, ...
                StorageRootId=1, RootPath=fullfile(root, "no_such_folder")), "CarasLabDB:rootNotFound");
            tc.verifyEmpty(conn.Log, "a refused file sent SQL");

            % The fake connection returns no artifact_id: only the INSERT matters.
            tc.verifyError(@() db.addArtifactFromFile(file, ProducedByEventId=id, ...
                StorageRootId=1, RootPath=string(root) + filesep, Role="raw"), "CarasLabDB:insertFailed");
            tc.assertSize(conn.Log, [1 1]);
            for piece = ["relative_path", "'G-1/sess 1/Raw.DAT'", "'" + VariableTests.AbcSha256 + "'", ...
                         "'sha256', 3, 'raw', 'dat'"]
                tc.verifySubstring(conn.Log(1), piece);
            end
        end

        function defaultsPassValidationOnEveryRelease(tc)
            % No new method's default values fail argument validation
            % (R2024b validates defaults eagerly).
            [db, ~] = VariableTests.recordingDb();
            id = VariableTests.FakeId;
            T = table("S-1", 70, 'VariableNames', {'subject_id', 'weight_g'});
            calls = {
                @() db.setVariable("session", id, "depth", 1)
                @() db.unsetVariable("session", id, "depth")
                @() db.getVariables("session", id)
                @() db.getVariableValues("depth")
                @() db.defineVariable("depth")
                @() db.getVariableDefinitions()
                @() db.getVariableDefinitions(Name="depth", IncludeRetired=true)
                @() db.updateVariableDefinition("depth", Label="Depth")
                @() db.retireVariable("depth")
                @() db.retireVariable("depth", Retired=false)
                @() db.retractEvent(id, "why")
                @() db.retractArtifact(id, "why")
                @() db.getRetractions()
                @() db.getRetractions(EventId=id)
                @() db.checkIntegrity()
                @() db.addHusbandryBatch(T)
                @() db.addHusbandryBatch(T, Measure="health_check", Notes="n", RecordedBy=id)
                @() db.addArtifactFromFile("no_such_file.dat", ProducedByEventId=id, ...
                        StorageRootId=1, RootPath="no_such_folder")
                @() CarasLabDB.fileChecksum("no_such_file.dat")};
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
        function setUpdateUnsetAndHistory(tc)
            % A variable is defined on first use, updated by setting it
            % again, cleared by unsetVariable; the log keeps every step.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("var", 0);
            name = "mt depth " + tc.Fx.next();
            sid = w.SessionId;

            id1 = db.setVariable("session", sid, name, 1200, Units="um", Label="MT Depth", Note="first");
            T = db.getVariables("session", sid);
            tc.assertEqual(height(T), 1);
            tc.verifyEqual([string(T.variable), string(T.label), string(T.value), string(T.units), ...
                string(T.value_type), string(T.note)], [name, "MT Depth", "1200", "um", "number", "first"]);
            tc.verifyEqual(double(T.value_num), 1200);
            tc.verifyEqual(string(T.set_by), db.CurrentPersonId);
            tc.verifyEqual(string(T.set_login), LabScratchDb.RwRole);

            % Same variable in another spelling: an update, stored exactly.
            id2 = db.setVariable("session", upper(sid), "  " + upper(name) + " ", 71.9);
            T = db.getVariables("session", sid);
            tc.assertEqual(height(T), 1, "an update, not a second variable");
            tc.verifyEqual(string(T.value), "71.9", "the digits typed are the digits stored");
            tc.verifyEqual(double(T.value_num), 71.9);
            V = db.getVariableValues(name, Kind="session");
            tc.verifyEqual([string(V.entity_kind), string(V.entity_id), string(V.value)], ...
                ["session", sid, "71.9"]);
            tc.verifyEqual(height(db.getVariableValues(name, Kind="event")), 0);

            id3 = db.unsetVariable("session", sid, name, Note="wrong probe");
            tc.verifyEqual(height(db.getVariables("session", sid)), 0);
            tc.verifyEqual(height(db.getVariableValues(name)), 0);
            H = db.getVariables("session", sid, History=true);
            tc.verifyEqual(string(H.op)', ["set", "set", "unset"]);
            tc.verifyEqual(double(H.value_id)', [id1, id2, id3]);
            tc.verifyEqual(double(H.value_num(1:2))', [1200, 71.9]);
            tc.verifyTrue(isnan(double(H.value_num(3))));
            err = tc.errorOf(@() db.unsetVariable("session", sid, name));
            tc.verifySubstring(string(err.message), "nothing to unset");

            % A text variable, on a subject (whose id is not a uuid).
            textName = "mt housing " + tc.Fx.next();
            db.setVariable("subject", w.SubjectId, textName, "pair");
            S = db.getVariables("subject", w.SubjectId);
            tc.verifyEqual([string(S.variable), string(S.value), string(S.value_text), ...
                string(S.value_type)], [textName, "pair", "pair", "text"]);
            tc.verifyTrue(isnan(double(S.value_num)));
            err = tc.errorOf(@() db.setVariable("subject", w.SubjectId, textName, 2));
            tc.verifySubstring(string(err.message), "holds text");
            err = tc.errorOf(@() db.setVariable("session", sid, name, "deep"));
            tc.verifySubstring(string(err.message), "holds a number");
        end

        function unitsMismatchAndDefinitions(tc)
            % A definition fixes units and applies_to; a value in other
            % units or on another kind is refused; label and retirement are
            % editable.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("vdef", 0);
            name = "mt weight " + tc.Fx.next();
            tc.verifyEqual(db.defineVariable(" " + upper(name), Units="g", ...
                AppliesTo=["subject", "event"], Description="at surgery"), name);
            D = db.getVariableDefinitions(Name=name);
            tc.assertEqual(height(D), 1);
            tc.verifyClass(D.applies_to, "string", "applies_to is text, not an array object");
            tc.verifyEqual([string(D.label), string(D.units), string(D.value_type), D.applies_to, ...
                string(D.description)], [name, "g", "number", "event,subject", "at surgery"]);
            tc.verifyEqual(string(D.created_by), db.CurrentPersonId);
            tc.verifyEqual(db.defineVariable(name, Units="g"), name, "defining it again changes nothing");
            err = tc.errorOf(@() db.defineVariable(name, Units="kg"));
            tc.verifySubstring(string(err.message), "already defined");

            err = tc.errorOf(@() db.setVariable("subject", w.SubjectId, name, 0.0719, Units="kg"));
            tc.verifySubstring(string(err.message), "is recorded in g, not in kg");
            err = tc.errorOf(@() db.setVariable("session", w.SessionId, name, 71.9));
            tc.verifySubstring(string(err.message), "applies to");
            tc.verifyEqual(height(db.getVariables("subject", w.SubjectId)), 0, "nothing was written");
            db.setVariable("subject", w.SubjectId, name, 71.9);            % units omitted: its own
            db.setVariable("subject", w.SubjectId, name, 72.4, Units="g");

            db.updateVariableDefinition(name, Label="MT Weight");
            tc.verifyEqual(string(db.getVariableDefinitions(Name=name).label), "MT Weight");
            tc.verifyEqual(string(db.getVariables("subject", w.SubjectId).label), "MT Weight");
            tc.verifyError(@() db.updateVariableDefinition("mt no such variable", Label="x"), ...
                "CarasLabDB:variableNotFound");
            tc.verifyError(@() db.retireVariable("mt no such variable"), "CarasLabDB:variableNotFound");

            db.retireVariable(name);
            db.retireVariable(name);                                       % already retired: no-op
            tc.verifyEqual(height(db.getVariableDefinitions(Name=name)), 0);
            R = db.getVariableDefinitions(Name=name, IncludeRetired=true);
            tc.verifyFalse(isnat(R.retired_at));
            tc.verifyFalse(ismember(name, string(db.getVariableDefinitions().name)));
            err = tc.errorOf(@() db.setVariable("subject", w.SubjectId, name, 73));
            tc.verifySubstring(string(err.message), "was retired");
            tc.verifyEqual(double(db.getVariables("subject", w.SubjectId).value_num), 72.4, ...
                "the row keeps the value it has");
            db.retireVariable(name, Retired=false);
            db.setVariable("subject", w.SubjectId, name, 73);
            tc.verifyEqual(double(db.getVariables("subject", w.SubjectId).value_num), 73);
        end

        function correctionCarriesVariablesOnce(tc)
            % The database copies a superseded event's and artifact's
            % variables to the successor; the class must not copy them again.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("vcarry", 1);
            name = "mt carried " + tc.Fx.next();
            db.setVariable("event", w.EventId, name, 5, Units="mm");
            db.setVariable("artifact", w.ArtifactIds(1), name, 7);

            newE = db.supersedeEvent(w.EventId, Notes="corrected");
            H = db.getVariables("event", newE, History=true);
            tc.assertEqual(height(H), 1, "one carried row, not two");
            tc.verifyEqual([string(H.op), string(H.note)], ["set", "carried forward from " + w.EventId]);
            tc.verifyEqual(double(H.value_num), 5);
            A = db.getArtifacts(ProducedByEventId=newE);
            tc.assertEqual(height(A), 1);
            newA = string(A.artifact_id);
            HA = db.getVariables("artifact", newA, History=true);
            tc.verifyEqual(height(HA), 1);
            tc.verifyEqual(double(db.getVariables("artifact", newA).value_num), 7);

            V = db.getVariableValues(name);
            tc.verifyEqual(sort(string(V.entity_id)), sort([newE; newA]), "current rows only");
            V = db.getVariableValues(name, ActiveOnly=false);
            tc.verifyEqual(sort(string(V.entity_id)), ...
                sort([w.EventId; newE; w.ArtifactIds(1); newA]), "every version");
        end

        function retractionHidesRowsAndVersionViewsExplain(tc)
            % A retracted row leaves the active readers; ActiveOnly=false
            % shows what became of every version.
            db = tc.requireDb();
            w = tc.Fx.makeWorld("retract", 1);
            dup = tc.Fx.addEvent(w);
            aid = w.ArtifactIds(1);

            tc.verifyError(@() db.retractEvent(dup, "  "), "CarasLabDB:reasonRequired");
            rid = db.retractEvent(dup, "entered twice");
            tc.verifyTrue(isfinite(rid));
            tc.verifyEqual(height(db.getEvents(EventId=dup)), 0);
            tc.verifyError(@() db.getEventDetail(EventId=dup), "CarasLabDB:eventNotFound");
            E = db.getEvents(EventId=dup, ActiveOnly=false);
            tc.assertEqual(height(E), 1);
            tc.verifyTrue(logical(E.is_retracted));
            tc.verifyFalse(logical(E.is_current));
            R = db.getRetractions(EventId=dup);
            tc.verifyEqual([string(R.entity_kind), string(R.reason), string(R.retracted_by), ...
                string(R.retracted_login)], ["event", "entered twice", db.CurrentPersonId, LabScratchDb.RwRole]);
            tc.verifyEqual(double(R.retraction_id), rid);
            tc.verifyTrue(ismember(rid, double(db.getRetractions(Kind="event").retraction_id)));
            err = tc.errorOf(@() db.retractEvent(dup, "again"));
            tc.verifySubstring(string(err.message), "already retracted");

            % Retracting an event does not retract its file: integrity says so.
            db.retractEvent(w.EventId, "wrong animal");
            I = db.checkIntegrity();
            tc.verifyEqual(string(I.Properties.VariableNames), ["severity", "check_name", "subject", "detail"]);
            tc.verifyTrue(issorted(string(I.severity) ~= "error"), "errors come first");
            hit = string(I.subject) == aid & string(I.check_name) == "artifact_producer_retracted";
            tc.verifyEqual(nnz(hit), 1);
            db.retractArtifact(aid, "its recording was withdrawn");
            tc.verifyEqual(height(db.getArtifacts(ArtifactId=aid)), 0);
            A = db.getArtifacts(ArtifactId=aid, ActiveOnly=false);
            tc.verifyTrue(logical(A.is_retracted) && ~logical(A.is_current));
            I = db.checkIntegrity();
            tc.verifyFalse(any(string(I.subject) == aid & string(I.check_name) == "artifact_producer_retracted"));

            % A superseded row names its correction.
            w2 = tc.Fx.makeWorld("versions", 0);
            newE = db.supersedeEvent(w2.EventId);
            V = db.getEvents(SubjectId=w2.SubjectId, ActiveOnly=false);
            old = string(V.event_id) == w2.EventId;
            tc.verifyEqual(string(V.superseded_by(old)), newE);
            tc.verifyEqual(logical(V.is_current)', ~old');
            tc.verifyFalse(any(logical(V.is_retracted)));
            err = tc.errorOf(@() db.retractEvent(w2.EventId, "old version"));
            tc.verifySubstring(string(err.message), "has been superseded");
        end

        function personComesFromTheLoginOnTheServer(tc)
            % A login mapped to a person (lab.person.db_login) needs to name
            % nobody: the class resolves the person, and so does the database
            % for a row whose client sends none.
            tc.requireDb();
            fx = tc.Fx;
            s = rmfield(fx.connectionSettings(), "PersonEmail");
            args = namedargs2cell(s);
            tc.verifyWarning(@() CarasLabDB(args{:}), "CarasLabDB:noCurrentPerson", ...
                "an unmapped login with no person named");

            map = "UPDATE lab.person SET db_login = %s WHERE person_id = " + LabScratchDb.quote(fx.PersonId);
            fx.Admin.runCommand(sprintf(map, LabScratchDb.quote(LabScratchDb.RwRole)));
            tc.addTeardown(@() fx.Admin.runCommand(sprintf(map, "NULL")));

            db2 = tc.verifyWarningFree(@() CarasLabDB(args{:}));
            tc.addTeardown(@() delete(db2));
            tc.verifyEqual(db2.CurrentPersonId, fx.PersonId);
            w = fx.makeWorld("login", 0);
            eid = db2.addHusbandryEvent(SubjectId=w.SubjectId, Measure="weight", WeightG=70, ...
                OccurredAt=datetime(2026, 11, 3, 9, 0, 0, "TimeZone", "UTC"));
            tc.verifyEqual(string(db2.getEvents(EventId=eid).recorded_by), fx.PersonId);
            % Even a raw INSERT that names no person is attributed.
            db2.runCommand("INSERT INTO lab.tag_assignment (entity_kind, event_id, tag, op) VALUES " + ...
                "('event', " + LabScratchDb.quote(eid) + ", 'qc:pass', 'add')");
            T = db2.getEntityTags("event", eid);
            tc.verifyEqual(string(T.applied_by), fx.PersonId);
        end

        function husbandryBatchIsAllOrNone(tc)
            % One event per row with a value, in one transaction.
            db = tc.requireDb();
            a = tc.Fx.makeWorld("batch", 0);
            b = tc.Fx.makeWorld("batch", 0);
            c = tc.Fx.makeWorld("batch", 0);
            t = datetime(2026, 11, 4, 9, 0, 0, "TimeZone", "UTC");
            sheet = table([a.SubjectId; b.SubjectId; c.SubjectId], [71.9; NaN; 68], ...
                ["bright"; ""; ""], 'VariableNames', {'subject_id', 'weight_g', 'health_status'});

            ids = db.addHusbandryBatch(sheet, OccurredAt=t, Notes="weekly weigh-in");
            tc.verifySize(ids, [3 1]);
            tc.verifyEqual(ismissing(ids)', [false true false], "the row with no value is skipped");
            D = db.getEventDetail(EventId=ids(1));
            tc.verifyEqual([string(D.subject_id), string(D.measure), string(D.health_status), ...
                string(D.notes), string(D.recorded_by)], ...
                [a.SubjectId, "weight", "bright", "weekly weigh-in", db.CurrentPersonId]);
            tc.verifyEqual(double(D.weight_g), 71.9);
            tc.verifyEqual(double(db.getSubjectCurrent(SubjectId=c.SubjectId).latest_weight_g), 68);
            tc.verifyEqual(height(db.getEvents(SubjectId=b.SubjectId, EventType="husbandry")), 0);

            % The second row names an animal that does not exist: the first
            % row's event must not survive.
            n0 = tc.Fx.counts();
            bad = table([a.SubjectId; "MT-no-such-animal"], [72; 70], ...
                'VariableNames', {'subject_id', 'weight_g'});
            tc.errorOf(@() db.addHusbandryBatch(bad, OccurredAt=t));
            tc.verifyEqual(tc.Fx.counts(), n0, "a failed sheet left rows behind");
            tc.verifyEqual(string(db.Connection.AutoCommit), "on");
        end

        function artifactFromFileIsRegistered(tc)
            % addArtifactFromFile against the database: the row stored is
            % the one INFO describes.
            tc.assumeTrue(usejava('jvm'), "fileChecksum needs the JVM");
            db = tc.requireDb();
            w = tc.Fx.makeWorld("fromfile", 0);
            root = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            rel = "mt/" + w.Key + "/from file.dat";
            mkdir(fullfile(root, "mt", w.Key));
            file = VariableTests.writeBytes(fullfile(root, "mt", w.Key, "from file.dat"), uint8('abc'));

            [aid, info] = db.addArtifactFromFile(file, ProducedByEventId=w.EventId, ...
                StorageRootId=tc.Fx.RootId, RootPath=root, Role="raw", ...
                SubjectId=w.SubjectId, SessionId=w.SessionId, Attributes=struct("origin", "test"));
            tc.verifyEqual(info.relative_path, rel);
            tc.verifyEqual(info.checksum, VariableTests.AbcSha256);
            tc.verifyEqual(info.size_bytes, 3);
            A = db.getArtifacts(ArtifactId=aid);
            tc.assertEqual(height(A), 1);
            tc.verifyEqual([string(A.relative_path), string(A.checksum), string(A.checksum_algo), ...
                string(A.role), string(A.format), string(A.session_id)], ...
                [rel, VariableTests.AbcSha256, "sha256", "raw", "dat", w.SessionId]);
            tc.verifyEqual(double(A.size_bytes), 3);
            tc.verifyEqual(height(db.getArtifacts(Checksum=upper(VariableTests.AbcSha256), ...
                SessionId=w.SessionId)), 1);
        end
    end

    % =====================================================================
    % Helpers
    % =====================================================================
    methods (Access = private)
        function db = requireDb(tc)
            tc.assumeTrue(tc.Fx.Available, tc.Fx.Reason);
            db = tc.Fx.Db;
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
                err = MException("VariableTests:noError", "(no error)");
            end
        end
    end

    methods (Static, Access = private)
        function [db, conn] = recordingDb()
            conn = RecordingConnection();
            db = CarasLabDB(Connection=conn, PersonId="00000000-0000-0000-0000-000000000001");
            conn.clearLog();
        end

        function file = writeBytes(file, bytes)
            %WRITEBYTES Write BYTES (uint8) to FILE exactly; returns FILE as a string.
            file = string(file);
            fid = fopen(file, "w");
            assert(fid > 0, "could not create %s", file);
            closeFile = onCleanup(@() fclose(fid)); %#ok<NASGU>
            fwrite(fid, bytes, "uint8");
        end
    end
end
