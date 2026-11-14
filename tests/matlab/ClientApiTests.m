classdef (SharedTestFixtures = {LabScratchDb}) ClientApiTests < matlab.unittest.TestCase
%CLIENTAPITESTS Tests of what a client that may work offline needs from CarasLabDB.
%
%   results = runtests("tests/matlab/ClientApiTests.m")
%   results = runtests("tests/matlab", Tag="NoDatabase")  % no server needed
%
%   Covered: ids minted by the caller (EventId=, ArtifactId=, SessionId=),
%   recordEvent (one transaction, safe to send again, an id reused for
%   another record refused, a file already registered not registered twice,
%   inputs the database does not have yet skipped and added later with
%   addEventInput(IfExists="skip")), JSON text sent as written
%   (CarasLabDB.jsonText, CarasLabDBJson.withMember), the file-location
%   filters of getArtifacts / getSessions, and the time limits
%   (ConnectTimeout=, StatementTimeout=, LockTimeout=).
%
%   Like TAGTESTS, the tests tagged "Database" run against the scratch
%   database of the shared fixture LABSCRATCHDB (opt-in; see "help
%   LabScratchDb") and are reported as Incomplete without it; the
%   "NoDatabase" ones check input validation and the SQL sent, against
%   RECORDINGCONNECTION.
%
%   See also TAGTESTS, VARIABLETESTS, LABSCRATCHDB, RECORDINGCONNECTION.

    properties
        Fx      % the LabScratchDb shared fixture
    end

    properties (Constant)
        PersonId = "00000000-0000-0000-0000-000000000001"
        EventId  = "0f8a2a5e-6c1b-4c1e-9d0e-3a1b2c3d4e01"
        InputId  = "0f8a2a5e-6c1b-4c1e-9d0e-3a1b2c3d4e02"
        OutputId = "0f8a2a5e-6c1b-4c1e-9d0e-3a1b2c3d4e03"
        Digest   = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        Hash     = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
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
        function jsonTextIsSentAsWritten(tc)
            % The text reaches the SQL unchanged; a struct goes through
            % jsonencode, which would lose the trailing zero and the digits.
            text = '{"fs": 30000.0, "big": 12345678901234567890, "s": "it''s"}';
            tc.verifyEqual(CarasLabDB.sqlLiteral(CarasLabDB.jsonText(text)), ...
                "'" + replace(string(text), "'", "''") + "'::jsonb");
            tc.verifyError(@() CarasLabDB.jsonText('{"a": '), "CarasLabDB:invalidJson");
            tc.verifyError(@() CarasLabDB.jsonText("  "), "CarasLabDB:invalidJson");
            tc.verifyTrue(CarasLabDB.jsonText('{"a": 1}').isObject());
            tc.verifyFalse(CarasLabDB.jsonText('[1, 2]').isObject());
        end

        function withMemberEditsOnlyTheText(tc)
            j = CarasLabDB.jsonText('{"fs": 30000.0}');
            tc.verifyEqual(j.withMember("client_digest", "ab").Text, ...
                "{""client_digest"":""ab"",""fs"": 30000.0}");
            tc.verifyEqual(CarasLabDB.jsonText('{}').withMember("k", "v").Text, ...
                "{""k"":""v""}");
            tc.verifyEqual(CarasLabDB.jsonText(' { } ').withMember("k", "v").Text, ...
                "{""k"":""v"" }");
            tc.verifyEqual(j.withMember("ids", "x", Array=true).Text, ...
                "{""ids"":[""x""],""fs"": 30000.0}");
            tc.verifyEqual(j.withMember("ids", ["x", "y"], Array=true).Text, ...
                "{""ids"":[""x"",""y""],""fs"": 30000.0}");
            tc.verifyError(@() j.withMember("fs", "1"), "CarasLabDB:invalidJson");
            tc.verifyError(@() CarasLabDB.jsonText('[1]').withMember("k", "v"), ...
                "CarasLabDB:invalidJson");
            tc.verifyError(@() j.withMember("Bad Name", "v"), "CarasLabDB:invalidValue");
            tc.verifyError(@() j.withMember("ids", ["x", "y"]), "CarasLabDB:invalidValue");
        end

        function clientIdsReachTheInsert(tc)
            % A minted id is checked, lower-cased and inserted as the key;
            % a malformed one is refused before any SQL is sent.
            [db, conn] = ClientApiTests.recordingDb();
            conn.Results("RETURNING session_id") = table("1", 'VariableNames', {'session_id'});
            conn.Results("RETURNING event_id") = table("2", 'VariableNames', {'event_id'});
            conn.Results("RETURNING artifact_id") = table("3", 'VariableNames', {'artifact_id'});
            up = upper(ClientApiTests.EventId);
            t = datetime(2026, 11, 14, 9, 0, 0, "TimeZone", "UTC");

            db.addSession(SessionId=up, SubjectId="S-1", Label="s", StorageRootId=1, ...
                RelativePath="S-1/s");
            db.addAnalysisEvent(EventId=up, OccurredAt=t, PipelineName="p");
            db.addArtifact(ArtifactId=up, ProducedByEventId=ClientApiTests.EventId, ...
                StorageRootId=1, RelativePath="S-1/s/f.mat", Checksum=ClientApiTests.Hash);
            tc.assertSize(conn.Log, [4 1]);   % session, event, analysis_event, artifact
            for i = [1 2 4]
                tc.verifySubstring(conn.Log(i), "'" + ClientApiTests.EventId + "'");
            end
            tc.verifySubstring(conn.Log(1), "session_id");
            tc.verifySubstring(conn.Log(2), "event_id");
            tc.verifySubstring(conn.Log(4), "artifact_id");

            conn.clearLog();
            calls = {
                @() db.addSession(SessionId="not-a-uuid", SubjectId="S-1", Label="s", ...
                    StorageRootId=1, RelativePath="S-1/s")
                @() db.addRecordingEvent(EventId="1234", OccurredAt=t, SessionId=ClientApiTests.EventId)
                @() db.addArtifact(ArtifactId="x", ProducedByEventId=ClientApiTests.EventId, ...
                    StorageRootId=1, RelativePath="a", Checksum=ClientApiTests.Hash)};
            for i = 1:numel(calls)
                tc.verifyError(calls{i}, "CarasLabDB:invalidValue", "call " + i);
            end
            tc.verifyEmpty(conn.Log, "nothing was sent for a malformed id");
        end

        function locationFiltersReachTheSql(tc)
            [db, conn] = ClientApiTests.recordingDb();
            db.getArtifacts(StorageRootId=2, RelativePath="S-1/s/f.mat");
            db.getArtifacts(PathPrefix="S-1/it's/");
            db.getSessions(StorageRootId=2, RelativePath="S-1/s");
            tc.assertSize(conn.Log, [3 1]);
            tc.verifySubstring(conn.Log(1), "storage_root_id = 2");
            tc.verifySubstring(conn.Log(1), "relative_path = 'S-1/s/f.mat'");
            tc.verifySubstring(conn.Log(2), "starts_with(relative_path, 'S-1/it''s/')");
            tc.verifySubstring(conn.Log(3), "relative_path = 'S-1/s'");
            tc.verifySubstring(conn.Log(3), "storage_root_id = 2");
        end

        function eventInputCanSkipAnExistingEdge(tc)
            [db, conn] = ClientApiTests.recordingDb();
            inserted = db.addEventInput(EventId=ClientApiTests.EventId, ...
                ArtifactId=ClientApiTests.InputId, IfExists="skip");
            tc.verifyFalse(inserted, "the fake returns no row: nothing was inserted");
            tc.assertSize(conn.Log, [1 1]);
            tc.verifySubstring(conn.Log(1), "ON CONFLICT (event_id, artifact_id) DO NOTHING");
            tc.verifyTrue(conn.LogInTransaction(1));
        end

        function timeoutsAreSetForTheSession(tc)
            conn = RecordingConnection();
            CarasLabDB(Connection=conn, PersonId=ClientApiTests.PersonId, ...
                StatementTimeout=5, LockTimeout=2.5);
            tc.verifyTrue(any(conn.Log == "SET statement_timeout = 5000;"));
            tc.verifyTrue(any(conn.Log == "SET lock_timeout = 2500;"));
            conn2 = RecordingConnection();
            CarasLabDB(Connection=conn2, PersonId=ClientApiTests.PersonId);
            tc.verifyFalse(any(contains(conn2.Log, "_timeout")), "no limit unless asked for");
            tc.verifyError(@() CarasLabDB(Connection=RecordingConnection(), ...
                PersonId=ClientApiTests.PersonId, StatementTimeout=-1), ?MException);
        end

        function recordEventChecksBeforeSending(tc)
            [db, conn] = ClientApiTests.recordingDb();
            t = datetime(2026, 11, 14, 9, 0, 0, "TimeZone", "UTC");
            ok = ClientApiTests.goodArgs(t);
            cases = {
                "CarasLabDB:invalidValue", setfield(ok, "EventId", "nope")
                "CarasLabDB:invalidValue", setfield(ok, "Digest", "xyz")
                "CarasLabDB:unzonedTime",  setfield(ok, "OccurredAt", datetime(2026, 11, 14))
                "CarasLabDB:invalidValue", setfield(ok, "Detail", struct("event_type", "x"))
                "CarasLabDB:unzonedTime",  setfield(ok, "Detail", struct("started_at", datetime(2026, 1, 1)))
                "CarasLabDB:invalidValue", setfield(ok, "Detail", struct("status", "done"))
                "CarasLabDB:invalidValue", setfield(ok, "Outputs", struct("storage_root_id", 1, "relative_path", "a"))
                "CarasLabDB:invalidValue", setfield(ok, "Outputs", struct("storage_root_id", {1, 1}, ...
                    "relative_path", {"a", "a"}, "checksum", {ClientApiTests.Hash, ClientApiTests.Hash}))
                "CarasLabDB:invalidValue", setfield(ok, "Outputs", struct("storage_root_id", 1, ...
                    "relative_path", "a", "checksum", ClientApiTests.Hash, "produced_by_event_id", "x"))
                "CarasLabDB:invalidValue", setfield(ok, "Inputs", struct("artifact_id", ...
                    {ClientApiTests.InputId, ClientApiTests.InputId}))
                "CarasLabDB:invalidValue", setfield(ok, "Attributes", struct("client_digest", "x"))
                "CarasLabDB:invalidJson",  setfield(ok, "Attributes", CarasLabDB.jsonText('{"client_digest": 1}'))
                };
            for i = 1:size(cases, 1)
                args = namedargs2cell(cases{i, 2});
                tc.verifyError(@() db.recordEvent("analysis", args{:}), cases{i, 1}, "case " + i);
            end
            tc.verifyError(@() db.recordEvent("surgery", ...
                EventId=ClientApiTests.EventId, Digest=ClientApiTests.Digest, OccurredAt=t), ?MException);
            tc.verifyEmpty(conn.Log, "nothing is sent for a record that fails its checks");
        end

        function recordEventWritesInOneTransaction(tc)
            [db, conn] = ClientApiTests.recordingDb();
            conn.Results("RETURNING event_id") = table(ClientApiTests.EventId, 'VariableNames', {'event_id'});
            conn.Results("RETURNING artifact_id") = table(ClientApiTests.OutputId, 'VariableNames', {'artifact_id'});
            t = datetime(2026, 11, 14, 9, 0, 0, "TimeZone", "UTC");
            args = namedargs2cell(ClientApiTests.goodArgs(t));
            out = db.recordEvent("analysis", args{:});

            tc.verifyEqual(out.Outcome, "inserted");
            tc.verifyEqual(out.EventId, ClientApiTests.EventId);
            tc.verifyEqual(out.OutputIds, ClientApiTests.OutputId);
            tc.verifyEqual(out.Unchanged, false);
            tc.verifyTrue(all(conn.LogInTransaction), "every statement inside the transaction");
            tc.verifyEqual(conn.Commits, 1);
            tc.verifyEqual(conn.Rollbacks, 0);
            first = @(pattern) find(contains(conn.Log, pattern), 1);
            order = [first("AS client_digest"), first("AS current_id"), ...
                     first("INSERT INTO lab.event "), first("INSERT INTO lab.analysis_event"), ...
                     first("INSERT INTO lab.event_input"), first("INSERT INTO lab.artifact ")];
            tc.assertNumElements(order, 6, "every step was sent");
            tc.verifyTrue(issorted(order), "replay check, file lookup, event, detail, input, output");
            ev = conn.Log(first("INSERT INTO lab.event "));
            tc.verifySubstring(ev, """client_digest"":""" + ClientApiTests.Digest + """");
            tc.verifySubstring(ev, "'" + ClientApiTests.EventId + "'");
            tc.verifyFalse(contains(ev, "unchanged_outputs"));
            par = conn.Log(first("INSERT INTO lab.analysis_event"));
            tc.verifySubstring(par, "'{""fs"": 30000.0}'::jsonb", "parameters sent as written");
            art = conn.Log(first("INSERT INTO lab.artifact "));
            tc.verifySubstring(art, "'" + ClientApiTests.OutputId + "'");
            tc.verifySubstring(art, "'" + ClientApiTests.Hash + "'");
        end

        function recordEventSentAgainWritesNothing(tc)
            [db, conn] = ClientApiTests.recordingDb();
            conn.Results("AS client_digest") = table(ClientApiTests.Digest, "[]", ...
                'VariableNames', {'client_digest', 'unchanged_outputs'});
            conn.Results("AS current_id") = table(ClientApiTests.OutputId, 'VariableNames', {'current_id'});
            t = datetime(2026, 11, 14, 9, 0, 0, "TimeZone", "UTC");
            args = namedargs2cell(ClientApiTests.goodArgs(t));
            out = db.recordEvent("analysis", args{:});
            tc.verifyEqual(out.Outcome, "existing");
            tc.verifyEqual(out.OutputIds, ClientApiTests.OutputId);
            tc.verifyEqual(out.Unchanged, false);
            tc.verifyFalse(any(contains(conn.Log, "INSERT")), "nothing is written again");
        end

        function recordEventRefusesAnotherRecordUnderTheSameId(tc)
            [db, conn] = ClientApiTests.recordingDb();
            conn.Results("AS client_digest") = table(string(repmat('0', 1, 64)), "[]", ...
                'VariableNames', {'client_digest', 'unchanged_outputs'});
            t = datetime(2026, 11, 14, 9, 0, 0, "TimeZone", "UTC");
            args = namedargs2cell(ClientApiTests.goodArgs(t));
            tc.verifyError(@() db.recordEvent("analysis", args{:}), "CarasLabDB:idConflict");
            tc.verifyFalse(any(contains(conn.Log, "INSERT")));
            tc.verifyEqual(conn.Commits, 0);
            tc.verifyEqual(conn.Rollbacks, 1);
        end

        function recordEventKeepsAFileRegisteredAlready(tc)
            % The same bytes at the same path: no second row; the event
            % lists the existing one.
            [db, conn] = ClientApiTests.recordingDb();
            existing = "0f8a2a5e-6c1b-4c1e-9d0e-3a1b2c3d4eff";
            conn.Results("AS current_id") = table(existing, 'VariableNames', {'current_id'});
            conn.Results("RETURNING event_id") = table(ClientApiTests.EventId, 'VariableNames', {'event_id'});
            t = datetime(2026, 11, 14, 9, 0, 0, "TimeZone", "UTC");
            args = namedargs2cell(ClientApiTests.goodArgs(t));
            out = db.recordEvent("analysis", args{:});
            tc.verifyEqual(out.OutputIds, existing);
            tc.verifyEqual(out.Unchanged, true);
            tc.verifyFalse(any(contains(conn.Log, "INSERT INTO lab.artifact ")));
            ev = conn.Log(find(contains(conn.Log, "INSERT INTO lab.event "), 1));
            tc.verifySubstring(ev, """unchanged_outputs"":[""" + existing + """]");
        end

        function recordEventCanSkipMissingInputs(tc)
            [db, conn] = ClientApiTests.recordingDb();
            conn.Results("RETURNING event_id") = table(ClientApiTests.EventId, 'VariableNames', {'event_id'});
            conn.Results("RETURNING artifact_id") = table(ClientApiTests.OutputId, 'VariableNames', {'artifact_id'});
            t = datetime(2026, 11, 14, 9, 0, 0, "TimeZone", "UTC");
            args = namedargs2cell(ClientApiTests.goodArgs(t));
            out = db.recordEvent("analysis", args{:}, MissingInputs="skip");
            tc.verifyEqual(out.SkippedInputs, ClientApiTests.InputId);
            tc.verifyFalse(any(contains(conn.Log, "INSERT INTO lab.event_input")));
            tc.verifyTrue(any(contains(conn.Log, "INSERT INTO lab.artifact ")));
        end

        function recordEventRecordsTheFileItReplaced(tc)
            [db, conn] = ClientApiTests.recordingDb();
            conn.Results("RETURNING event_id") = table(ClientApiTests.EventId, 'VariableNames', {'event_id'});
            conn.Results("RETURNING artifact_id") = table(ClientApiTests.OutputId, 'VariableNames', {'artifact_id'});
            t = datetime(2026, 11, 14, 9, 0, 0, "TimeZone", "UTC");
            a = ClientApiTests.goodArgs(t);
            old = "0f8a2a5e-6c1b-4c1e-9d0e-3a1b2c3d4e10";
            a.Outputs.replaces = old;
            args = namedargs2cell(a);
            db.recordEvent("analysis", args{:});
            at = find(contains(conn.Log, "INSERT INTO lab.artifact_disposition"));
            tc.assertNumElements(at, 1);
            tc.verifyGreaterThan(at, find(contains(conn.Log, "INSERT INTO lab.artifact "), 1));
            d = conn.Log(at);
            tc.verifySubstring(d, "'replaced'");
            tc.verifySubstring(d, "'" + old + "'");
            tc.verifySubstring(d, "'" + ClientApiTests.OutputId + "'");
            tc.verifySubstring(d, "2026-11-14 09:01:00", "when the run finished");
            tc.verifyFalse(contains(conn.Log(find(contains(conn.Log, "INSERT INTO lab.artifact "), 1)), ...
                "replaces"), "replaces is not an artifact column");

            % A replaced row the database does not have: skipped with MissingInputs="skip".
            conn.clearLog();
            out = db.recordEvent("analysis", args{:}, MissingInputs="skip");
            tc.verifyEqual(out.SkippedReplaces, old);
            tc.verifyFalse(any(contains(conn.Log, "INSERT INTO lab.artifact_disposition")));
        end

        function presentOnlyReadsArtifactPresent(tc)
            [db, conn] = ClientApiTests.recordingDb();
            db.getArtifacts(PresentOnly=true);
            tc.verifySubstring(conn.Log(1), "FROM lab.artifact_present");
            tc.verifyError(@() db.getArtifacts(PresentOnly=true, ActiveOnly=false), ...
                "CarasLabDB:invalidValue");
            conn.clearLog();
            db.getArtifactDispositions(ArtifactId=ClientApiTests.OutputId, LatestPerFile=true);
            db.getArtifactDispositions(Disposition="moved");
            tc.verifySubstring(conn.Log(1), "FROM lab.artifact_disposition_latest");
            tc.verifySubstring(conn.Log(2), "disposition = 'moved'");
            tc.verifyError(@() db.getArtifactDispositions(Disposition="lost"), "CarasLabDB:invalidValue");
            tc.verifyError(@() db.addArtifactDisposition(ArtifactId="x", Disposition="deleted", ...
                OccurredAt=datetime("now", "TimeZone", "UTC")), "CarasLabDB:invalidValue");
        end
    end

    % =====================================================================
    % Against the scratch database
    % =====================================================================
    methods (Test, TestTags = {'Database'})
        function clientIdsAreTheRowIds(tc)
            db = tc.requireDb();
            fx = tc.Fx;
            w = fx.makeWorld("ids", 0);
            sid = ClientApiTests.newId(fx);
            got = db.addSession(SessionId=sid, SubjectId=w.SubjectId, Label="ids-" + sid, ...
                StorageRootId=fx.RootId, RelativePath="mt/ids/" + sid);
            tc.verifyEqual(got, sid);
            eid = ClientApiTests.newId(fx);
            got = db.addRecordingEvent(EventId=eid, SubjectId=w.SubjectId, SessionId=sid, ...
                OccurredAt=datetime(2026, 11, 1, 9, 0, 0, "TimeZone", "UTC"));
            tc.verifyEqual(got, eid);
            aid = ClientApiTests.newId(fx);
            got = db.addArtifact(ArtifactId=aid, ProducedByEventId=eid, StorageRootId=fx.RootId, ...
                RelativePath="mt/ids/" + sid + "/raw.dat", Checksum=fx.checksum(fx.next()));
            tc.verifyEqual(got, aid);
            T = db.getArtifacts(StorageRootId=fx.RootId, RelativePath="mt/ids/" + sid + "/raw.dat");
            tc.verifyEqual(LabScratchDb.column(T, "artifact_id"), aid);
            T = db.getArtifacts(PathPrefix="mt/ids/" + sid + "/");
            tc.verifyEqual(LabScratchDb.column(T, "artifact_id"), aid);
            T = db.getSessions(StorageRootId=fx.RootId, RelativePath="mt/ids/" + sid);
            tc.verifyEqual(LabScratchDb.column(T, "session_id"), sid);
        end

        function recordEventWritesOnceAndCanBeSentAgain(tc)
            db = tc.requireDb();
            fx = tc.Fx;
            w = fx.makeWorld("rec", 1);
            [args, ids] = ClientApiTests.analysisRecord(fx, w);
            before = fx.counts();
            out = db.recordEvent("analysis", args{:});
            tc.verifyEqual(out.Outcome, "inserted");
            tc.verifyEqual(out.EventId, ids.EventId);
            tc.verifyEqual(out.OutputIds, ids.OutputId);
            after = fx.counts();
            tc.verifyEqual(after.events - before.events, 1);
            tc.verifyEqual(after.artifacts - before.artifacts, 1);
            tc.verifyEqual(after.event_inputs - before.event_inputs, 1);

            % The stored row: digest, parameters as written, the file filed
            % under the event's session, the input edge.
            tc.verifyEqual(string(fx.scalar("SELECT attributes->>'client_digest' FROM lab.event " + ...
                "WHERE event_id = " + LabScratchDb.quote(ids.EventId))), ids.Digest);
            par = string(fx.scalar("SELECT parameters::text FROM lab.analysis_event " + ...
                "WHERE event_id = " + LabScratchDb.quote(ids.EventId)));
            tc.verifySubstring(par, "12345678901234567890", "digits a double would lose");
            tc.verifySubstring(par, "30000.0", "the trailing zero numeric keeps");
            A = db.getArtifacts(ArtifactId=ids.OutputId);
            tc.verifyEqual(LabScratchDb.column(A, "session_id"), w.SessionId);
            tc.verifyEqual(LabScratchDb.column(A, "produced_by_event_id"), ids.EventId);
            I = db.getEventInputs(EventId=ids.EventId);
            tc.verifyEqual(LabScratchDb.column(I, "artifact_id"), w.ArtifactIds(1));

            % Sent again: nothing new.
            again = db.recordEvent("analysis", args{:});
            tc.verifyEqual(again.Outcome, "existing");
            tc.verifyEqual(again.OutputIds, ids.OutputId);
            tc.verifyEqual(fx.counts(), after);

            % The same id for another record: refused, nothing written.
            other = args;
            at = find(cellfun(@(x) isequal(string(x), "Digest"), other(1:2:end)));
            other{2 * at} = string(repmat('1', 1, 64));
            tc.verifyError(@() db.recordEvent("analysis", other{:}), "CarasLabDB:idConflict");
            tc.verifyEqual(fx.counts(), after);
        end

        function recordEventReusesARegisteredFile(tc)
            db = tc.requireDb();
            fx = tc.Fx;
            w = fx.makeWorld("same", 1);
            [args, ids] = ClientApiTests.analysisRecord(fx, w);
            db.recordEvent("analysis", args{:});
            % A second run that wrote the same bytes to the same path.
            [args2, ids2] = ClientApiTests.analysisRecord(fx, w, Path=ids.Path, Checksum=ids.Checksum);
            before = fx.counts();
            out = db.recordEvent("analysis", args2{:});
            tc.verifyEqual(out.Unchanged, true);
            tc.verifyEqual(out.OutputIds, ids.OutputId, "the existing row describes the file");
            after = fx.counts();
            tc.verifyEqual(after.events - before.events, 1);
            tc.verifyEqual(after.artifacts, before.artifacts, "no second row for the same file");
            listed = string(fx.scalar("SELECT attributes->'unchanged_outputs'->>0 FROM lab.event " + ...
                "WHERE event_id = " + LabScratchDb.quote(ids2.EventId)));
            tc.verifyEqual(listed, ids.OutputId);
        end

        function missingInputsCanBeAddedLater(tc)
            db = tc.requireDb();
            fx = tc.Fx;
            w = fx.makeWorld("late", 0);
            later = ClientApiTests.newId(fx);
            [args, ids] = ClientApiTests.analysisRecord(fx, w, InputId=later);
            tc.verifyError(@() db.recordEvent("analysis", args{:}), ?MException, ...
                "an input the database does not have is an error by default");
            tc.verifyEmpty(db.getEvents(EventId=ids.EventId), "and nothing was written");
            out = db.recordEvent("analysis", args{:}, MissingInputs="skip");
            tc.verifyEqual(out.SkippedInputs, later);
            tc.verifyEmpty(db.getEventInputs(EventId=ids.EventId));

            eid = fx.addEvent(w);
            db.addArtifact(ArtifactId=later, ProducedByEventId=eid, StorageRootId=fx.RootId, ...
                RelativePath="mt/" + w.Key + "/late.dat", Checksum=fx.checksum(fx.next()));
            tc.verifyTrue(db.addEventInput(EventId=ids.EventId, ArtifactId=later, IfExists="skip"));
            tc.verifyFalse(db.addEventInput(EventId=ids.EventId, ArtifactId=later, IfExists="skip"));
            tc.verifyEqual(LabScratchDb.column(db.getEventInputs(EventId=ids.EventId), "artifact_id"), later);
        end

        function recordEventIsAllOrNothing(tc)
            % An output under a storage root that does not exist fails the
            % foreign key after the event was inserted: nothing remains.
            db = tc.requireDb();
            fx = tc.Fx;
            w = fx.makeWorld("atomic", 1);
            [args, ids] = ClientApiTests.analysisRecord(fx, w, RootId=32000);
            before = fx.counts();
            tc.verifyError(@() db.recordEvent("analysis", args{:}), ?MException);
            tc.verifyEqual(fx.counts(), before);
            tc.verifyEmpty(db.getEvents(EventId=ids.EventId, ActiveOnly=false));
        end

        function dispositionsSayWhereAFileIs(tc)
            db = tc.requireDb();
            fx = tc.Fx;
            w = fx.makeWorld("disp", 1);
            aid = w.ArtifactIds(1);
            t = datetime(2026, 11, 2, 9, 0, 0, "TimeZone", "UTC");
            tc.verifyNumElements(LabScratchDb.column(db.getArtifacts(ArtifactId=aid, PresentOnly=true), ...
                "artifact_id"), 1);
            id = db.addArtifactDisposition(ArtifactId=aid, Disposition="deleted", OccurredAt=t, ...
                Note="cleaned up");
            tc.verifyGreaterThan(id, 0);
            tc.verifyEmpty(db.getArtifacts(ArtifactId=aid, PresentOnly=true), "a deleted file is not present");
            tc.verifyNumElements(LabScratchDb.column(db.getArtifacts(ArtifactId=aid), "artifact_id"), 1, ...
                "its row is still active");
            L = db.getArtifactDispositions(ArtifactId=aid, LatestPerFile=true);
            tc.verifyEqual(LabScratchDb.column(L, "disposition"), "deleted");
            tc.verifyError(@() db.addArtifactDisposition(ArtifactId=aid, Disposition="deleted", ...
                OccurredAt=t), ?MException, "a file already gone cannot be deleted again");
            db.addArtifactDisposition(ArtifactId=aid, Disposition="restored", OccurredAt=t + days(1));
            tc.verifyNumElements(LabScratchDb.column(db.getArtifacts(ArtifactId=aid, PresentOnly=true), ...
                "artifact_id"), 1, "restored: present again");
            T = db.getArtifactDispositions(ArtifactId=aid);
            tc.verifyEqual(LabScratchDb.column(T, "disposition"), ["restored"; "deleted"], "newest first");
        end

        function recordEventRecordsReplacedAndRestoredFiles(tc)
            % v1 at a path; v2 overwrites it (replaces v1); v3 writes v1's
            % bytes again (replaces v2): v1's row is reused and restored.
            db = tc.requireDb();
            fx = tc.Fx;
            w = fx.makeWorld("rr", 1);
            [a1, v1] = ClientApiTests.analysisRecord(fx, w);
            db.recordEvent("analysis", a1{:});
            [a2, v2] = ClientApiTests.analysisRecord(fx, w, Path=v1.Path, Replaces=v1.OutputId);
            db.recordEvent("analysis", a2{:});
            present = @() LabScratchDb.column(db.getArtifacts(RelativePath=v1.Path, ...
                StorageRootId=fx.RootId, PresentOnly=true), "artifact_id");
            tc.verifyEqual(present(), v2.OutputId, "v2 is at the path; v1 was replaced");
            tc.verifyEqual(LabScratchDb.column(db.getArtifactDispositions(ArtifactId=v1.OutputId), ...
                "successor_artifact_id"), v2.OutputId);
            [a3, ~] = ClientApiTests.analysisRecord(fx, w, Path=v1.Path, Checksum=v1.Checksum, ...
                Replaces=v2.OutputId);
            out = db.recordEvent("analysis", a3{:});
            tc.verifyEqual(out.OutputIds, v1.OutputId, "the same bytes: v1's row");
            tc.verifyTrue(out.Unchanged);
            tc.verifyEqual(present(), v1.OutputId, "v1 restored, v2 replaced");
            tc.verifyEqual(LabScratchDb.column(db.getArtifactDispositions(ArtifactId=v1.OutputId), ...
                "disposition"), ["restored"; "replaced"]);
            dup = fx.Db.runQuery("SELECT * FROM lab.fn_check_integrity() WHERE check_name = " + ...
                "'duplicate_active_path' AND subject = " + ...
                LabScratchDb.quote(string(fx.RootId) + ":" + v1.Path));
            tc.verifyEqual(height(dup), 0, "one present file at the path");
        end

        function statementTimeoutStopsALongStatement(tc)
            tc.requireDb();
            s = tc.Fx.connectionSettings();
            args = namedargs2cell(s);
            db2 = CarasLabDB(args{:}, StatementTimeout=1, LockTimeout=2);
            tc.addTeardown(@() delete(db2));
            tc.verifyEqual(string(db2.runQuery( ...
                "SELECT current_setting('statement_timeout') AS v").v), "1s");
            tc.verifyEqual(string(db2.runQuery( ...
                "SELECT current_setting('lock_timeout') AS v").v), "2s");
            t0 = tic;
            tc.verifyError(@() db2.runQuery("SELECT pg_sleep(5)"), ?MException);
            tc.verifyLessThan(toc(t0), 4.5, "stopped by the limit, not by the sleep ending");
        end

        function connectTimeoutBoundsAnUnansweredConnection(tc)
            % A server that accepts the TCP connection and never answers:
            % without a limit libpq waits for minutes.
            tc.requireDb();
            tc.assumeTrue(exist("tcpserver", "file") > 0 || exist("tcpserver", "class") > 0, ...
                "tcpserver is not available");
            server = [];
            for port = 55432:55532
                try
                    server = tcpserver("127.0.0.1", port);
                    break
                catch
                end
            end
            tc.assumeNotEmpty(server, "no free local port for the silent server");
            tc.addTeardown(@() delete(server));
            had = isenv("PGCONNECT_TIMEOUT");
            old = string(getenv("PGCONNECT_TIMEOUT"));
            t0 = tic;
            failed = false;
            try
                CarasLabDB(Username="nobody", Password="x", Server="127.0.0.1", ...
                    Port=server.ServerPort, DatabaseName="lab", ConnectTimeout=2);
            catch
                failed = true;
            end
            elapsed = toc(t0);
            tc.verifyTrue(failed, "a server that never answers is not a connection");
            tc.verifyLessThan(elapsed, 20, "ConnectTimeout=2 bounds the wait");
            tc.verifyEqual(isenv("PGCONNECT_TIMEOUT"), had, "PGCONNECT_TIMEOUT put back");
            tc.verifyEqual(string(getenv("PGCONNECT_TIMEOUT")), old);
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
    end

    methods (Static, Access = private)
        function [db, conn] = recordingDb()
            conn = RecordingConnection();
            db = CarasLabDB(Connection=conn, PersonId=ClientApiTests.PersonId);
            conn.clearLog();
        end

        function s = goodArgs(t)
            %GOODARGS recordEvent's Name=Value arguments for one analysis run, as a struct.
            s = struct("EventId", ClientApiTests.EventId, "Digest", ClientApiTests.Digest, ...
                "OccurredAt", t, ...
                "Detail", struct("pipeline_name", "test/run", ...
                    "parameters", CarasLabDB.jsonText('{"fs": 30000.0}'), ...
                    "started_at", t, "finished_at", t + minutes(1), "status", "succeeded"), ...
                "Inputs", struct("artifact_id", ClientApiTests.InputId, "role", "raw"), ...
                "Outputs", struct("artifact_id", ClientApiTests.OutputId, "storage_root_id", 1, ...
                    "relative_path", "S-1/s/f.mat", "checksum", ClientApiTests.Hash, ...
                    "size_bytes", 3, "role", "derived", "format", "mat"));
        end

        function id = newId(fx)
            %NEWID A uuid unique within this run of the fixture.
            id = string(sprintf("0f8a2a5e-6c1b-4c1e-9d0e-%012x", fx.next()));
        end

        function [args, ids] = analysisRecord(fx, w, opts)
            %ANALYSISRECORD recordEvent arguments for an analysis of world W's first file.
            arguments
                fx
                w
                opts.Path (1,1) string = string(missing)
                opts.Checksum (1,1) string = string(missing)
                opts.InputId (1,1) string = string(missing)
                opts.RootId double = []
                opts.Replaces (1,1) string = string(missing)
            end
            ids.EventId = ClientApiTests.newId(fx);
            ids.OutputId = ClientApiTests.newId(fx);
            ids.Digest = string(fx.checksum(fx.next()));
            ids.Path = opts.Path;
            if ismissing(ids.Path)
                ids.Path = "mt/" + w.Key + "/out-" + fx.next() + ".mat";
            end
            ids.Checksum = opts.Checksum;
            if ismissing(ids.Checksum)
                ids.Checksum = string(fx.checksum(fx.next()));
            end
            input = opts.InputId;
            if ismissing(input)
                input = w.ArtifactIds(1);
            end
            root = opts.RootId;
            if isempty(root)
                root = fx.RootId;
            end
            t = datetime(2026, 11, 14, 9, 0, 0, "TimeZone", "UTC");
            output = struct("artifact_id", ids.OutputId, "storage_root_id", root, ...
                "relative_path", ids.Path, "checksum", ids.Checksum, ...
                "size_bytes", 10, "role", "derived", "format", "mat");
            if ~ismissing(opts.Replaces)
                output.replaces = opts.Replaces;
            end
            args = {"EventId", ids.EventId, "Digest", ids.Digest, "OccurredAt", t, ...
                "SessionId", w.SessionId, ...
                "Detail", struct("pipeline_name", "mtest/run", "code_version", "abc", ...
                    "parameters", CarasLabDB.jsonText( ...
                        '{"fs": 30000.0, "big": 12345678901234567890}'), ...
                    "started_at", t, "finished_at", t + minutes(2), "status", "succeeded"), ...
                "Inputs", struct("artifact_id", input, "role", "raw"), ...
                "Outputs", output};
        end
    end
end
