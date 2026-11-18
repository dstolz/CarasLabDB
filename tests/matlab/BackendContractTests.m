classdef (SharedTestFixtures = {LabScratchDb}) BackendContractTests < matlab.unittest.TestCase
    % BackendContractTests  One set of assertions, run against both backends of the shared client.
    %   labclient talks to the database only through labclient.Backend, which
    %   has two implementations: labclient.CarasBackend (the CarasLabDB class,
    %   a real PostgreSQL) and labclient.FakeBackend (in memory, what
    %   LabClientTests and every toolbox's own tests run against). The fake is
    %   only worth testing against while it answers as the database does, and
    %   nothing held the two to that. Every test here runs twice, Kind "fake"
    %   and Kind "real", with the same lines:
    %
    %     - records sent with labclient.Sync, as a toolbox's records are: an
    %       event of no dataset written once; a weighing; a file saved again
    %       and again naming its first version, in order and out of order; a
    %       copy of a file already there; a record held for a subject the
    %       database does not have; a dataset's recording, which makes its
    %       session;
    %     - what a backend refuses: a Detail field that is not a column, an
    %       id sent again with another digest, a disposition the policy does
    %       not allow;
    %     - what the reads give: the columns the client reads, converted the
    %       way the client converts them, and an empty answer that still has
    %       its columns.
    %
    %   Kind "real" is the first test of the send path against PostgreSQL. It
    %   needs the scratch database of LabScratchDb (CARASLABDB_MTEST_ADMIN and
    %   the Database Toolbox): without it those tests are filtered out, and
    %   the "fake" ones run all the same. The real ones connect as the client
    %   connects: labclient.Settings, the password from the vault
    %   (labclient.Secrets, its fake for tests), labclient.DB.connect(), with
    %   no backend put in by hand.
    %
    %   The scratch database is shared with the other test classes of a run,
    %   so every test keeps to itself: its own subject, its files under a
    %   folder of its own, and bytes no other test writes (a file with the
    %   bytes of another event's file is, rightly, a copy of it).
    %
    %   See also LABCLIENTTESTS, LABSCRATCHDB, CLIENTAPITESTS.

    properties (TestParameter)
        Kind = {'fake', 'real'}
    end

    properties
        Fx              % the LabScratchDb shared fixture
    end

    properties (Access = private)
        Restore = {}
        Top = ""        % the folder the storage root is mapped to on this computer
        Be              % the open backend under test, as labclient.DB.connect gives it
        Root = "mtest-root"   % the storage root's name (LabScratchDb's; the fake is given the same)
        RootId = NaN
        Subject = ""    % a subject the database has
        Key = ""        % this test's own: its folder below the root, and in the bytes of its files
    end

    methods (TestClassSetup)
        function getFixture(tc)
            tc.Fx = tc.getSharedTestFixtures("LabScratchDb");
        end
    end

    methods (Access = private)
        function start(tc, kind)
            %start  Settings, vault, outbox and an open backend of KIND, for one test.
            tc.Restore = {labclient.Prefs.useTemporary(), labclient.Secrets.useFake(), ...
                labclient.DB.useTemporary(), labclient.Sync.useManual()};
            tc.addTeardown(@() tc.cleanUp());
            tc.Key = "c" + extractBefore(strrep(labclient.Bundles.newId(), "-", ""), 13);
            tc.Top = string(tempname);
            mkdir(tc.Top);
            s = labclient.Settings.defaults();
            s.Enabled = true;
            s.Roots = struct("Name", tc.Root, "Path", tc.Top);
            if string(kind) == "fake"
                fake = labclient.FakeBackend();
                fake.Roots = table(1, tc.Root, "contract tests", 'VariableNames', {'root_id', 'name', 'description'});
                tc.Subject = "CT-" + tc.Key;
                fake.Subjects = table(tc.Subject, "P1", "mus_musculus", "F", ...
                    'VariableNames', {'subject_id', 'project_id', 'species_code', 'sex'});
                tc.Restore{end + 1} = labclient.DB.useBackend(@() fake);
                s.Server = "labdb.test";
                s.Username = "jdoe";
                labclient.Settings.save(s);
                labclient.Secrets.setFake(labclient.Settings.load(), fake.Password);
                tc.RootId = 1;
            else
                tc.assumeTrue(tc.Fx.Available, tc.Fx.Reason);
                c = tc.Fx.connectionSettings();
                w = tc.Fx.makeWorld("contract", 0);
                tc.Subject = string(w.SubjectId);
                s.Server = c.Server;
                s.Port = c.Port;
                s.DatabaseName = c.DatabaseName;
                s.Username = c.Username;
                s.PersonEmail = c.PersonEmail;
                labclient.Settings.save(s);
                labclient.Secrets.setFake(labclient.Settings.load(), c.Password);
                tc.RootId = double(tc.Fx.RootId);
            end
            tc.Be = labclient.DB.connect(Force=true);
            tc.assertNotEmpty(tc.Be, "connected as the client connects: " + labclient.DB.status().Message);
            tc.assertTrue(tc.Be.isOpen());
        end

        function cleanUp(tc)
            for tool = labclient.Sync.tools()
                labclient.Sync.unregisterTool(tool);
            end
            labclient.DB.disconnect();
            for k = numel(tc.Restore):-1:1
                tc.Restore{k} = [];
            end
            if strlength(tc.Top) > 0 && isfolder(tc.Top); rmdir(tc.Top, "s"); end
        end

        function r = rel(tc, name)
            %rel  Where NAME of this test is below the storage root.
            r = "contract/" + tc.Key + "/" + name;
        end

        function f = file(tc, name, k)
            %file  The file NAME of this test under the mapped root, with bytes of this test and number K.
            %   The same K gives the same bytes under another name (a copy);
            %   another K, or another test, gives other bytes.
            f = string(fullfile(tc.Top, "contract", tc.Key, name));
            if ~isfolder(fileparts(f)); mkdir(fileparts(f)); end
            fid = fopen(f, "w");
            fwrite(fid, uint8(char(tc.Key + "|" + k)), "uint8");
            fclose(fid);
        end

        function [b, artifactId, f] = behavior(tc, name, k, opts)
            %behavior  A sealed behavior record of no dataset, naming its subject, with the file NAME (bytes K) as its raw file.
            arguments
                tc
                name (1,1) string
                k (1,1) double
                opts.Subject (1,1) string = string(missing)
            end
            f = tc.file(name, k);
            artifactId = labclient.Bundles.newId();
            subject = opts.Subject;
            if ismissing(subject); subject = tc.Subject; end
            it = labclient.Bundles.item(f, Role="raw", Kind="session", ArtifactId=artifactId, ...
                Sha256=labclient.fileSha256(f), Root=tc.Root, Rel=tc.rel(name));
            b = labclient.Bundles.event(EventId=labclient.Bundles.newId(), EventType="behavior", ...
                OccurredAt=labclient.Bundles.now(), Detail=struct("task", "detect", "trials_completed", 12), ...
                Attributes=struct("made_by", "BackendContractTests"), Outputs=it, SubjectId=subject);
            b = labclient.Bundles.seal(b);
        end

        function [fb, id] = savedAgain(tc, ev, name, k, replaces, at)
            %savedAgain  A files record: new bytes (K) at NAME, a file of event record EV in place of REPLACES, captured at AT.
            f = tc.file(name, k);
            id = labclient.Bundles.newId();
            it = labclient.Bundles.item(f, Role="raw", Kind="session", ArtifactId=id, Root=tc.Root, Rel=tc.rel(name), ...
                Sha256=labclient.fileSha256(f), Replaces=replaces);
            fb = labclient.Bundles.files(EventId=ev.bundle_id, Outputs=it);
            fb.captured_at = labclient.Bundles.timeText(at);   % the order of the captures is the test's to set (not in the digest)
        end

        function send(tc, b) %#ok<INUSL>
            %send  Put record B in the outbox and send what waits.
            labclient.Outbox.put(b);
            labclient.Sync.flush(Budget=30);
        end

        function d = said(tc, id) %#ok<INUSL>
            %said  Where record ID is in the outbox and why, for a failed check's message.
            st = labclient.Outbox.stateOf(id);
            if st == ""
                d = "record " + id + " is not in the outbox";
            else
                d = "record " + id + " is " + st + ": " + labclient.Outbox.note(id, st).reason;
            end
        end

        function ids = presentAt(tc, name)
            %presentAt  The artifacts the backend has as present at NAME of this test, sorted.
            P = tc.Be.artifacts(struct("StorageRootId", tc.RootId, "RelativePath", tc.rel(name), "PresentOnly", true));
            ids = sort(reshape(string(P.artifact_id), 1, []));
        end

        function req = request(tc, type, detail)
            %request  What labclient.Sync hands a backend's recordEvent: an event of TYPE with DETAIL, no files.
            id = labclient.Bundles.newId();
            req = struct("EventType", type, "EventId", id, "Digest", labclient.fileSha256(id, Text=true), ...
                "OccurredAt", datetime(2026, 11, 18, 9, 0, 0, "TimeZone", "UTC"), "SubjectId", tc.Subject, ...
                "SessionId", "", "Notes", "", "AttributesJson", "{}", "RecordedBy", "", "Detail", detail, ...
                "Inputs", struct("artifact_id", {}, "role", {}), ...
                "Outputs", struct("artifact_id", {}, "storage_root_id", {}, "relative_path", {}, "checksum", {}, ...
                "size_bytes", {}, "role", {}, "format", {}, "attributes_json", {}, "replaces", {}));
        end
    end

    methods (Static, Access = private)
        function v = number(x)
            %number  One fetched number as a double, however the driver hands it over (the client reads them as tolerantly).
            if iscell(x); x = x{1}; end
            if isstring(x) || ischar(x)
                v = str2double(x);
            else
                v = double(x);
            end
        end
    end

    methods (Test)
        % ---- sending, as a toolbox's records are sent ------------------------------------------------

        function anEventOfNoDatasetIsRecordedOnce(tc, Kind)
            tc.start(Kind);
            [b, a, f] = tc.behavior("s1.mat", 1);
            tc.send(b);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "done", tc.said(b.bundle_id));
            E = tc.Be.eventRows(struct("EventId", b.bundle_id));
            tc.verifyEqual(height(E), 1, "the event");
            tc.verifyEqual(string(E.event_type(1)), "behavior");
            tc.verifyEqual(string(E.subject_id(1)), tc.Subject);
            A = tc.Be.artifacts(struct("ArtifactId", a));
            tc.verifyEqual(height(A), 1, "its file");
            tc.verifyEqual(string(A.produced_by_event_id(1)), string(b.bundle_id));
            tc.verifyEqual(double(A.storage_root_id(1)), tc.RootId);
            tc.verifyEqual(string(A.relative_path(1)), tc.rel("s1.mat"));
            tc.verifyEqual(string(A.checksum(1)), labclient.fileSha256(f));
            tc.verifyEqual(string(A.role(1)), "raw");
            tc.verifyEqual(tc.presentAt("s1.mat"), a);

            labclient.Outbox.move(b.bundle_id, "pending", Reason="sent again by the test");
            labclient.Sync.flush(Budget=30);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "done", tc.said(b.bundle_id));
            tc.verifySubstring(labclient.Outbox.note(b.bundle_id, "done").reason, "already in the database");
            tc.verifyEqual(height(tc.Be.eventRows(struct("EventId", b.bundle_id))), 1, "written once");
            tc.verifyEqual(height(tc.Be.artifacts(struct("StorageRootId", tc.RootId, "RelativePath", tc.rel("s1.mat")))), 1);
        end

        function aWeighingIsTheSubjectsLatestWeight(tc, Kind)
            tc.start(Kind);
            b = labclient.Bundles.seal(labclient.Bundles.event(EventId=labclient.Bundles.newId(), EventType="husbandry", ...
                OccurredAt=labclient.Bundles.now(), SubjectId=tc.Subject, ...
                Detail=struct("measure", "weight", "weight_g", 71.5, "water_ml", NaN, "health_status", "")));
            tc.send(b);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "done", tc.said(b.bundle_id));
            E = tc.Be.eventRows(struct("EventId", b.bundle_id));
            tc.verifyEqual(height(E), 1);
            tc.verifyEqual(string(E.event_type(1)), "husbandry");
            C = tc.Be.subjectCurrent(tc.Subject);
            tc.verifyEqual(height(C), 1);
            tc.verifyEqual(string(C.subject_id(1)), tc.Subject);
            tc.verifyEqual(BackendContractTests.number(C.latest_weight_g(1)), 71.5);
        end

        function aFileSavedAgainAndAgainNamingItsFirstVersion(tc, Kind)
            % what a toolbox does that reads the id of the file it replaces from the record it sent
            tc.start(Kind);
            [ev, a0] = tc.behavior("again.mat", 1);
            tc.send(ev);
            tc.assertEqual(labclient.Outbox.stateOf(ev.bundle_id), "done", tc.said(ev.bundle_id));
            t0 = datetime(2026, 11, 18, 9, 0, 0, "TimeZone", "America/New_York");

            [fb1, a1] = tc.savedAgain(ev, "again.mat", 2, a0, t0 + minutes(1));
            tc.send(fb1);
            tc.verifyEqual(labclient.Outbox.stateOf(fb1.bundle_id), "done", tc.said(fb1.bundle_id));
            [fb2, a2] = tc.savedAgain(ev, "again.mat", 3, a0, t0 + minutes(2));   % still names the first
            tc.send(fb2);
            tc.verifyEqual(labclient.Outbox.stateOf(fb2.bundle_id), "done", tc.said(fb2.bundle_id));

            D0 = tc.Be.dispositions(a0);
            tc.verifyEqual(height(D0), 1);
            tc.verifyEqual([string(D0.disposition(1)), string(D0.successor_artifact_id(1))], ["replaced", a1]);
            D1 = tc.Be.dispositions(a1);
            tc.verifyEqual(height(D1), 1, tc.said(fb2.bundle_id));
            tc.verifyEqual([string(D1.disposition(1)), string(D1.successor_artifact_id(1))], ["replaced", a2]);
            tc.verifyEqual(height(tc.Be.dispositions(a2)), 0);
            tc.verifyEqual(tc.presentAt("again.mat"), a2, "one present file at the path: the newest");
            tc.verifyEqual(height(tc.Be.artifacts(struct("StorageRootId", tc.RootId, "RelativePath", tc.rel("again.mat")))), 3, ...
                "every version is still a row");

            for id = [fb1.bundle_id, fb2.bundle_id]   % sent again, either one: nothing twice
                labclient.Outbox.move(id, "pending", Reason="sent again by the test");
                labclient.Sync.flush(Budget=30);
                tc.verifyEqual(labclient.Outbox.stateOf(id), "done", tc.said(id));
            end
            tc.verifyEqual(height(tc.Be.dispositions(a0)), 1);
            tc.verifyEqual(height(tc.Be.dispositions(a1)), 1);
            tc.verifyEqual(tc.presentAt("again.mat"), a2);
        end

        function aReplacementSentAfterANewerOneIsTheOneReplaced(tc, Kind)
            % the same, with the later save reaching the database first
            tc.start(Kind);
            [ev, a0] = tc.behavior("late.mat", 1);
            tc.send(ev);
            tc.assertEqual(labclient.Outbox.stateOf(ev.bundle_id), "done", tc.said(ev.bundle_id));
            t0 = datetime(2026, 11, 18, 9, 0, 0, "TimeZone", "America/New_York");
            [fb2, a1] = tc.savedAgain(ev, "late.mat", 2, a0, t0 + minutes(1));   % captured, and kept back
            [fb3, a2] = tc.savedAgain(ev, "late.mat", 3, a0, t0 + minutes(2));   % the bytes on disk now
            tc.send(fb3);
            tc.verifyEqual(labclient.Outbox.stateOf(fb3.bundle_id), "done", tc.said(fb3.bundle_id));
            tc.verifyEqual(tc.presentAt("late.mat"), a2);

            tc.send(fb2);   % the earlier save arrives late
            tc.verifyEqual(labclient.Outbox.stateOf(fb2.bundle_id), "done", tc.said(fb2.bundle_id));
            tc.verifySubstring(labclient.Outbox.note(fb2.bundle_id, "done").reason, "was sent first", ...
                "the backend says when a file was replaced, in a way the client reads");
            D0 = tc.Be.dispositions(a0);
            tc.verifyEqual([string(D0.disposition(1)), string(D0.successor_artifact_id(1))], ["replaced", a2]);
            D1 = tc.Be.dispositions(a1);
            tc.verifyEqual(height(D1), 1, "the late, earlier version is the one replaced");
            tc.verifyEqual([string(D1.disposition(1)), string(D1.successor_artifact_id(1))], ["replaced", a2]);
            tc.verifyEqual(height(tc.Be.dispositions(a2)), 0, "never the newer bytes by the older");
            tc.verifyEqual(tc.presentAt("late.mat"), a2, "the newest bytes stay the present file");
        end

        function aCopyOfAFileAlreadyThereIsAFileOfThatEvent(tc, Kind)
            % byte for byte the file of an event in the database, recorded again from another place
            tc.start(Kind);
            [ev, a0] = tc.behavior("rig/s.mat", 1);
            tc.send(ev);
            tc.assertEqual(labclient.Outbox.stateOf(ev.bundle_id), "done", tc.said(ev.bundle_id));
            [again, a1] = tc.behavior("server/s.mat", 1);   % the same bytes, another event id
            tc.send(again);
            tc.verifyEqual(labclient.Outbox.stateOf(again.bundle_id), "done", tc.said(again.bundle_id));
            tc.verifySubstring(labclient.Outbox.note(again.bundle_id, "done").reason, "a copy of the behavior");
            tc.verifyEqual(height(tc.Be.eventRows(struct("EventId", again.bundle_id))), 0, "not a second event");
            A = tc.Be.artifacts(struct("ArtifactId", a1));
            tc.verifyEqual(height(A), 1, "its file is registered");
            tc.verifyEqual(string(A.produced_by_event_id(1)), string(ev.bundle_id), "as a file of the first event");
            tc.verifyEqual(tc.presentAt("rig/s.mat"), a0);
        end

        function aRecordOfASubjectTheDatabaseDoesNotHaveIsHeld(tc, Kind)
            tc.start(Kind);
            b = tc.behavior("nobody.mat", 1, Subject="NO-SUCH-" + tc.Key);
            tc.send(b);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "held", tc.said(b.bundle_id));
            n = labclient.Outbox.note(b.bundle_id, "held");
            tc.verifyTrue(any(n.flags == labclient.Sync.NeedsSubject));
            tc.verifySubstring(n.reason, "NO-SUCH-" + tc.Key);
            tc.verifyEqual(height(tc.Be.eventRows(struct("EventId", b.bundle_id))), 0);
        end

        function aDatasetsRecordingMakesItsSession(tc, Kind)
            % a record about a dataset folder, through its tool's hooks: the session is made, the event is in it
            tc.start(Kind);
            labclient.Sync.registerTool("contract", struct( ...
                "readSession", @(folder, name) struct("session_id", "", "subject_id", "", "recording_event_id", ""), ...
                "copyOfSession", @(folder, name, sessionId, kind, eventId) [], ...
                "assignSubject", @(folder, name, subjectId) []));
            name = "ds-" + tc.Key;
            f = tc.file(name + "/raw.dat", 1);
            folder = string(fileparts(f));
            sid = labclient.Bundles.newId();
            ds = struct("name", name, "folder", folder, "session_id", sid, "subject_folder_id", tc.Subject, ...
                "recording_start", "", "tool", "contract");
            a = labclient.Bundles.newId();
            it = labclient.Bundles.item(f, Role="raw", Kind="raw", ArtifactId=a, Sha256=labclient.fileSha256(f), ...
                Root=tc.Root, Rel=tc.rel(name + "/raw.dat"));
            b = labclient.Bundles.seal(labclient.Bundles.event(EventId=labclient.Bundles.newId(), EventType="recording", ...
                OccurredAt=labclient.Bundles.now(), Detail=struct("acquisition_system_code", "intan_rhx", "duration_s", 12.5), ...
                Dataset=ds, Outputs=it));
            tc.send(b);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "done", tc.said(b.bundle_id));
            T = tc.Be.sessions(struct("SessionId", sid));
            tc.verifyEqual(height(T), 1, "the session the record names was made");
            tc.verifyEqual(string(T.subject_id(1)), tc.Subject);
            tc.verifyEqual(string(T.label(1)), name);
            tc.verifyEqual(double(T.storage_root_id(1)), tc.RootId);
            tc.verifyEqual(string(T.relative_path(1)), tc.rel(name));
            E = tc.Be.eventRows(struct("EventId", b.bundle_id));
            tc.verifyEqual(height(E), 1);
            tc.verifyEqual(string(E.session_id(1)), sid);
            tc.verifyEqual(string(E.subject_id(1)), tc.Subject);
            A = tc.Be.artifacts(struct("ArtifactId", a));
            tc.verifyEqual(string(A.session_id(1)), sid, "its file is the session's");
            S = tc.Be.sessions(struct("StorageRootId", tc.RootId, "RelativePath", tc.rel(name)));
            tc.verifyEqual(string(S.session_id), sid, "found by where its folder is, as the client looks for it");
        end

        % ---- what a backend refuses ---------------------------------------------------------------------

        function aDetailFieldThatIsNoColumnIsRefused(tc, Kind)
            tc.start(Kind);
            wrong = struct("analysis", struct("task", "t"), "recording", struct("trials_completed", 3), ...
                "behavior", struct("trials", 3), "husbandry", struct("measure", "weight", "grams", 20));
            for type = ["analysis" "recording" "behavior" "husbandry"]
                req = tc.request(type, wrong.(type));
                tc.verifyError(@() tc.Be.recordEvent(req), "CarasLabDB:invalidValue", type);
                tc.verifyEqual(height(tc.Be.eventRows(struct("EventId", req.EventId))), 0, "nothing written: " + type);
            end
            % every column there is, of the two types a rig records
            req = tc.request("behavior", struct("task", "detect", "paradigm", "go/no-go", "stage", "3", ...
                "trials_completed", 120, "performance", 0.75, "reward", "water"));
            out = tc.Be.recordEvent(req);
            tc.verifyNotEqual(string(out.Outcome), "existing");
            tc.verifyEqual(height(tc.Be.eventRows(struct("EventId", req.EventId))), 1);
            req2 = tc.request("husbandry", struct("measure", "weight", "weight_g", 70.5, "water_ml", 1.5, ...
                "health_status", "bright, alert"));
            tc.Be.recordEvent(req2);
            tc.verifyEqual(height(tc.Be.eventRows(struct("EventId", req2.EventId))), 1);

            % the same record again is the same record; the same id with another digest is a conflict
            out = tc.Be.recordEvent(req);
            tc.verifyEqual(string(out.Outcome), "existing");
            other = req;
            other.Digest = labclient.fileSha256(req.EventId + "/other", Text=true);
            tc.verifyError(@() tc.Be.recordEvent(other), "CarasLabDB:idConflict");
            tc.verifyEqual(height(tc.Be.eventRows(struct("EventId", req.EventId))), 1);
        end

        function aDispositionThePolicyDoesNotAllowIsRefused(tc, Kind)
            tc.start(Kind);
            [ev, a0] = tc.behavior("kept.mat", 1);
            tc.send(ev);
            tc.assertEqual(labclient.Outbox.stateOf(ev.bundle_id), "done", tc.said(ev.bundle_id));
            [ev2, other] = tc.behavior("elsewhere.mat", 2);   % other bytes at another path
            tc.send(ev2);
            tc.assertEqual(labclient.Outbox.stateOf(ev2.bundle_id), "done", tc.said(ev2.bundle_id));
            t = datetime(2026, 11, 18, 10, 0, 0, "TimeZone", "UTC");
            d = @(what, successor, at) struct("ArtifactId", a0, "Disposition", what, "SuccessorArtifactId", successor, ...
                "OccurredAt", at, "Note", "contract test", "AttributesJson", "{}");
            here = struct("ArtifactId", a0, "PresentOnly", true);

            % a file that is present cannot be restored; a replacement is other bytes at the SAME path; a move
            % keeps the bytes; a deleted file has no successor; every disposition says when
            tc.verifyError(@() tc.Be.addDisposition(d("restored", "", t)), ?MException, "restored while present");
            tc.verifyError(@() tc.Be.addDisposition(d("replaced", other, t)), ?MException, "replaced by a file elsewhere");
            tc.verifyError(@() tc.Be.addDisposition(d("moved", other, t)), ?MException, "moved to other bytes");
            tc.verifyError(@() tc.Be.addDisposition(d("deleted", other, t)), ?MException, "deleted, with a successor");
            tc.verifyError(@() tc.Be.addDisposition(d("deleted", "", NaT("TimeZone", "UTC"))), ?MException, "no time");
            tc.verifyEqual(height(tc.Be.dispositions(a0)), 0, "nothing was recorded by a refused disposition");
            tc.verifyEqual(height(tc.Be.artifacts(here)), 1);

            tc.Be.addDisposition(d("deleted", "", t));
            tc.verifyEqual(height(tc.Be.artifacts(here)), 0, "a deleted file is not present");
            tc.verifyEqual(height(tc.Be.artifacts(struct("ArtifactId", a0))), 1, "its row is still there");
            tc.verifyError(@() tc.Be.addDisposition(d("deleted", "", t + hours(1))), ?MException, "gone already");
            tc.Be.addDisposition(d("restored", "", t + hours(2)));
            tc.verifyEqual(height(tc.Be.artifacts(here)), 1, "restored: present again");
            D = tc.Be.dispositions(a0);
            tc.verifyEqual(reshape(string(D.disposition), 1, []), ["restored", "deleted"], "newest first");
        end

        % ---- what the reads give ---------------------------------------------------------------------------

        function theReadsGiveWhatTheClientReads(tc, Kind)
            % the columns labclient reads, converted the way it converts them; and an answer of no rows
            % that still has its columns (the client reads a column of an empty answer in several places)
            tc.start(Kind);
            [ev, a0] = tc.behavior("read.mat", 1);
            tc.send(ev);
            tc.assertEqual(labclient.Outbox.stateOf(ev.bundle_id), "done", tc.said(ev.bundle_id));
            has = @(T, names) all(ismember(names, string(T.Properties.VariableNames)));
            nobody = labclient.Bundles.newId();

            R = tc.Be.storageRoots();
            tc.verifyTrue(has(R, ["root_id" "name"]));
            tc.verifyEqual(double(R.root_id(string(R.name) == tc.Root)), tc.RootId);

            p = tc.Be.person();
            tc.verifyTrue(isfield(p, "PersonId") && isfield(p, "Login"));
            tc.verifyGreaterThan(strlength(string(p.Login)), 0);

            S = tc.Be.subjects(struct("SubjectId", tc.Subject));
            tc.verifyEqual(height(S), 1);
            tc.verifyTrue(has(S, ["subject_id" "project_id" "species_code" "sex"]));
            tc.verifyEqual(string(S.subject_id(1)), tc.Subject);
            none = tc.Be.subjects(struct("SubjectId", "NO-SUCH-" + tc.Key));
            tc.verifyEqual(height(none), 0);
            tc.verifyTrue(has(none, "subject_id"), "no rows, the columns all the same");

            P = tc.Be.projects();
            tc.verifyTrue(has(P, ["project_id" "name"]));
            tc.verifyTrue(any(string(P.project_id) == string(S.project_id(1))), "the subject's project is one of them");
            Sp = tc.Be.species();
            tc.verifyTrue(has(Sp, ["code" "common_name"]));
            tc.verifyTrue(any(string(Sp.code) == string(S.species_code(1))));
            tc.verifyTrue(has(tc.Be.persons(struct("Email", "nobody-" + tc.Key + "@example.invalid")), "person_id"));

            E = tc.Be.eventRows(struct("EventId", ev.bundle_id));
            tc.verifyTrue(has(E, ["event_id" "event_type" "subject_id" "session_id"]));
            tc.verifyEqual(string(E.event_id(1)), string(ev.bundle_id));
            none = tc.Be.eventRows(struct("EventId", nobody));
            tc.verifyEqual(height(none), 0);
            tc.verifyTrue(has(none, ["event_id" "subject_id"]));

            A = tc.Be.artifacts(struct("ArtifactId", a0));
            tc.verifyTrue(has(A, ["artifact_id" "produced_by_event_id" "storage_root_id" "relative_path" ...
                "checksum" "role" "session_id"]));
            tc.verifyEqual(strlength(string(A.checksum(1))), 64);
            byBytes = tc.Be.artifacts(struct("Checksum", string(A.checksum(1)), "Role", "raw"));
            tc.verifyEqual(string(byBytes.artifact_id), a0, "found by its bytes, as a copy is looked for");
            none = tc.Be.artifacts(struct("StorageRootId", tc.RootId, "RelativePath", tc.rel("no-such.mat")));
            tc.verifyEqual(height(none), 0);
            tc.verifyTrue(has(none, ["artifact_id" "checksum"]), "no rows, the columns all the same");
            tc.verifyEqual(numel(string(none.checksum)), 0);

            D = tc.Be.dispositions(a0);
            tc.verifyEqual(height(D), 0);
            T = tc.Be.sessions(struct("SessionId", nobody));
            tc.verifyEqual(height(T), 0);
            tc.verifyTrue(has(T, ["session_id" "subject_id" "label" "storage_root_id" "relative_path"]));

            % when a disposition happened, as the client reads it to order two versions
            t = datetime(2026, 11, 18, 10, 30, 0, "TimeZone", "America/New_York");
            tc.Be.addDisposition(struct("ArtifactId", a0, "Disposition", "deleted", "SuccessorArtifactId", "", ...
                "OccurredAt", t, "Note", "", "AttributesJson", "{}"));
            D = tc.Be.dispositions(a0);
            tc.verifyTrue(has(D, ["disposition" "successor_artifact_id" "occurred_at"]));
            tc.verifyEqual(string(D.disposition(1)), "deleted");
            at = D.occurred_at(1);
            tc.assertClass(at, "datetime");
            if isempty(at.TimeZone); at.TimeZone = "local"; end   % as labclient.Sync.whenOf reads it
            tc.verifyTrue(at == t, "the instant that was written: " + string(at));
            tc.verifyEqual(height(tc.Be.verifications(a0)), 0);
        end
    end
end
