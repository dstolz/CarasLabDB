classdef LabClientTests < matlab.unittest.TestCase
%LABCLIENTTESTS Tests of the shared lab database client, the +labclient package.
%
%   results = runtests("tests/matlab/LabClientTests.m")
%
%   Everything runs against labclient.FakeBackend, in a temporary preference
%   store (labclient.Prefs), a fake password vault, a temporary client folder
%   and no sending timer: no server, no Database Toolbox, nothing of the
%   user's touched.
%
%   Covered: the preference store; labclient.Settings, Secrets, Roots and DB
%   (state, the growing pause while offline, Force); the Database window and
%   the lamp; the SHA-256 vectors; labclient.Bundles (zoned times, ids, the
%   golden bundle testdata/bundle_event_v1.json, optional members left out
%   while empty); labclient.Outbox (put and its replacement of a record not
%   sent yet, claims only one process can win, a claim taken back and the old
%   owner left without a claim, stale claims); labclient.Hasher; sending
%   (labclient.Sync): an event of no dataset naming its subject, held for a
%   subject the database does not have and re-targeted to another, husbandry
%   events, a replacement file registered beside the one it replaces (also
%   when it names a version replaced before, and when a later save was sent
%   first), a record
%   recorded as a copy of a file already in the database whichever of two
%   toolboxes sent it first, a record whose tool is not running here never
%   claimed, a dataset record that names no tool sent only through the tool
%   registered to take such records; a record the database would refuse
%   (labclient.Bundles.problems) kept held with its reason, and the fake
%   refusing what the database refuses; the interface's version
%   (labclient.Api); labclient.SubjectCache.
%
%   See also LABSCRATCHDB, CLIENTAPITESTS.

    properties (Access = private)
        Fake
        Restore = {}
        Top = ""
        Calls                      % containers.Map: what the fake tool's hooks were asked
        Sessions                   % containers.Map: the fake tool's session files
    end

    methods (TestMethodSetup)
        function isolate(tc)
            tc.Restore = {labclient.Prefs.useTemporary(), labclient.Secrets.useFake(), ...
                labclient.DB.useTemporary(), labclient.Sync.useManual()};
            tc.Fake = labclient.FakeBackend();
            tc.Fake.Roots = table(1, "nas", "the lab's NAS", 'VariableNames', {'root_id', 'name', 'description'});
            tc.Fake.Subjects = table(["SUBJ-1"; "SUBJ-2"], ["P1"; "P1"], ["mus_musculus"; "mus_musculus"], ["F"; "M"], ...
                'VariableNames', {'subject_id', 'project_id', 'species_code', 'sex'});
            fake = tc.Fake;
            tc.Restore{end + 1} = labclient.DB.useBackend(@() fake);
            tc.Top = string(tempname);
            mkdir(tc.Top);
            s = labclient.Settings.defaults();
            s.Enabled = true;
            s.Server = "labdb.test";
            s.Username = "jdoe";
            s.Roots = struct("Name", "nas", "Path", tc.Top);
            labclient.Settings.save(s);
            labclient.Secrets.setFake(labclient.Settings.load(), fake.Password);
            tc.Calls = containers.Map('KeyType', 'char', 'ValueType', 'any');
            tc.Sessions = containers.Map('KeyType', 'char', 'ValueType', 'any');
            tc.addTeardown(@() tc.cleanUp());
        end
    end

    methods (Access = private)
        function cleanUp(tc)
            for tool = labclient.Sync.tools()
                labclient.Sync.unregisterTool(tool);
            end
            for k = numel(tc.Restore):-1:1
                tc.Restore{k} = [];
            end
            if isfolder(tc.Top); rmdir(tc.Top, "s"); end
        end

        function f = file(tc, rel, bytes)
            %file  A file under the mapped root with these bytes; its full path.
            f = string(fullfile(tc.Top, rel));
            if ~isfolder(fileparts(f)); mkdir(fileparts(f)); end
            fid = fopen(f, "w");
            fwrite(fid, bytes, "uint8");
            fclose(fid);
        end

        function registerTool(tc, name, opts)
            %registerTool  A fake toolbox: its session files are entries of a map, every hook call counted.
            arguments
                tc
                name (1,1) string
                opts.TakesUntagged (1,1) logical = false
            end
            S = tc.Sessions; C = tc.Calls;
            labclient.Sync.registerTool(name, struct( ...
                "readSession", @(folder, nm) LabClientTests.readFake(S, C, folder, nm), ...
                "copyOfSession", @(folder, nm, sid, kind, ev) LabClientTests.copyFake(S, C, folder, nm, sid, kind, ev), ...
                "assignSubject", @(folder, nm, subj) LabClientTests.assignFake(S, C, folder, nm, subj)), ...
                TakesUntagged=opts.TakesUntagged);
        end

        function n = called(tc, hook)
            n = 0;
            if isKey(tc.Calls, char(hook)); n = tc.Calls(char(hook)); end
        end

        function ds = datasetBlock(tc, name, subject, tool)
            folder = string(fullfile(tc.Top, subject, name));
            if ~isfolder(folder); mkdir(folder); end
            ds = struct("name", name, "folder", folder, "session_id", "", "subject_folder_id", subject, ...
                "recording_start", "", "tool", tool);
        end

        function b = record(tc, f, opts)
            %record  A sealed behavior record of file F (raw): of no dataset naming a subject, or of a dataset.
            arguments
                tc
                f (1,1) string
                opts.Subject (1,1) string = ""
                opts.Dataset (1,1) struct = labclient.Bundles.noDataset()
                opts.Type (1,1) string = "behavior"
                opts.Id (1,1) string = ""
                opts.Notes (1,1) string = ""
            end %#ok<INUSL>
            id = opts.Id;
            if id == ""; id = labclient.Bundles.newId(); end
            it = labclient.Bundles.item(f, Role="raw", Kind="session", ArtifactId=labclient.Bundles.newId(), ...
                Sha256=labclient.fileSha256(f), Root="nas", Rel=string(strrep(extractAfter(f, strlength(tc.Top) + 1), "\", "/")));
            b = labclient.Bundles.event(EventId=id, EventType=opts.Type, OccurredAt=labclient.Bundles.now(), ...
                Detail=struct("task", "detect", "trials_completed", 12), Attributes=struct("rig", "r1"), ...
                Outputs=it, SubjectId=opts.Subject, Dataset=opts.Dataset, Notes=opts.Notes);
            b = labclient.Bundles.seal(b);
        end

        function [fb, id] = savedAgain(tc, ev, rel, bytes, replaces, at)
            %savedAgain  A sealed files record: new BYTES at REL, a file of event record EV in place of REPLACES, captured at AT.
            f = tc.file(rel, bytes);
            id = labclient.Bundles.newId();
            it = labclient.Bundles.item(f, Role="raw", Kind="session", ArtifactId=id, Root="nas", Rel=rel, ...
                Sha256=labclient.fileSha256(f), Replaces=replaces);
            fb = labclient.Bundles.files(EventId=ev.bundle_id, Outputs=it);
            fb.captured_at = labclient.Bundles.timeText(at);   % the order of the captures is the test's to set (not in the digest)
        end

        function b = golden(~)
            out = labclient.Bundles.item("/data/nas/G-1/s1/s1_spikes.mat", Role="spikes", Kind="threshold_spikes", ...
                ArtifactId="11111111-1111-4111-8111-111111111111", Root="nas", Rel="G-1/s1/s1_spikes.mat", ...
                Sha256=string(repmat('a', 1, 64)), ...
                Snapshot=struct("bytes", 1234, "mtime", "2026-07-02T14:30:00.000-04:00"));
            in = labclient.Bundles.item("/data/nas/G-1/s1/amplifier.dat", Role="raw", Kind="raw", ...
                Root="nas", Rel="G-1/s1/amplifier.dat", ...
                Snapshot=struct("bytes", 5000000000, "mtime", "2026-07-02T14:12:10.000-04:00"));
            detail = struct("pipeline_name", "ephys_analysis/spikes", "code_version", "abc1234", ...
                "parameters_json", '{"file":"s1_spikes.mat"}', "environment_json", "{}", ...
                "started_at", "2026-07-02T14:29:00.000000-04:00", ...
                "finished_at", "2026-07-02T14:30:00.000000-04:00", "status", "succeeded");
            ds = struct("name", "s1", "folder", "/data/nas/G-1/s1", ...
                "session_id", "33333333-3333-4333-8333-333333333333", "subject_folder_id", "G-1", ...
                "recording_start", "2026-07-02T14:12:10.000000-04:00");
            by = struct("host", "RIG2", "os_user", "jdoe", "db_username", "jdoe", "person_id", "", ...
                "person_email", "");
            b = labclient.Bundles.event(EventId="22222222-2222-4222-8222-222222222222", EventType="analysis", ...
                OccurredAt="2026-07-02T14:29:00.000000-04:00", Detail=detail, ...
                Attributes=struct("step", "spikes"), Dataset=ds, Inputs=in, Outputs=out, ...
                CapturedAt="2026-07-02T14:30:01.000000-04:00", CapturedBy=by);
        end
    end

    methods (Static, Access = private)
        function ses = readFake(S, C, folder, nm)
            LabClientTests.count(C, "readSession");
            key = char(string(folder) + "|" + string(nm));
            if isKey(S, key)
                ses = S(key);
            else
                ses = struct("session_id", "", "subject_id", "", "recording_event_id", "");
            end
        end

        function copyFake(S, C, folder, nm, sid, kind, ev) %#ok<INUSD>
            LabClientTests.count(C, "copyOfSession");
            key = char(string(folder) + "|" + string(nm));
            ses = struct("session_id", string(sid), "subject_id", "", "recording_event_id", "");
            S(key) = ses;
        end

        function assignFake(S, C, folder, nm, subj)
            LabClientTests.count(C, "assignSubject");
            key = char(string(folder) + "|" + string(nm));
            ses = struct("session_id", "", "subject_id", string(subj), "recording_event_id", "");
            if isKey(S, key); ses = S(key); ses.subject_id = string(subj); end
            S(key) = ses;
        end

        function count(C, name)
            n = 0;
            if isKey(C, char(name)); n = C(char(name)); end
            C(char(name)) = n + 1;
        end
    end

    methods (Test)
        % ---- preferences, settings, vault, roots, connection ----------------------------------------

        function prefsStoreAndNeverCreates(tc)
            tc.verifyFalse(labclient.Prefs.ispref("X"));
            tc.verifyError(@() labclient.Prefs.getpref("X"), "labclient:Prefs:NoPreference");
            labclient.Prefs.setpref("X", struct("a", 1));
            tc.verifyTrue(labclient.Prefs.ispref("X"));
            tc.verifyEqual(labclient.Prefs.getpref("X").a, 1);
            labclient.Prefs.rmpref("X");
            tc.verifyFalse(labclient.Prefs.ispref("X"));
            labclient.Prefs.rmpref("X");   % not there: nothing happens
            tc.verifyNotEqual(labclient.Prefs.storeFile(), "", "tests keep it in a file");
            tc.verifyFalse(ispref(char(labclient.Prefs.Group), 'X'), "MATLAB's own preferences untouched");
        end

        function settingsRoundTrip(tc)
            labclient.Prefs.rmpref(labclient.Settings.Name);
            s = labclient.Settings.load();
            tc.verifyEqual(s, labclient.Settings.defaults(), "nothing saved: the defaults");
            tc.verifyFalse(labclient.Settings.isConfigured(s));
            s.Enabled = true;
            s.Server = "  labdb.example.edu ";
            s.Username = "jdoe";
            s.Roots = struct("Name", "nas-main", "Path", tempdir);
            s.ConnectTimeout = 0.5;
            labclient.Settings.save(s);
            t = labclient.Settings.load();
            tc.verifyEqual(t.Server, "labdb.example.edu", "trimmed");
            tc.verifyEqual(t.ConnectTimeout, 2, "libpq's smallest connect timeout");
            tc.verifyEqual(t.Roots.Name, "nas-main");
            tc.verifyTrue(labclient.Settings.isConfigured(t));

            bad = t; bad.Port = 70000;
            tc.verifyError(@() labclient.Settings.save(bad), "labclient:Settings:Invalid");
            bad = t; bad.LabTimeZone = "Mars/Olympus";
            tc.verifyError(@() labclient.Settings.save(bad), "labclient:Settings:Invalid");
            bad = t; bad.Roots = struct("Name", {"a", "a"}, "Path", {tempdir, tempdir});
            tc.verifyError(@() labclient.Settings.save(bad), "labclient:Settings:Invalid", "a root listed twice");
            bad = t; bad.PersonId = "not-a-uuid";
            tc.verifyError(@() labclient.Settings.save(bad), "labclient:Settings:Invalid");

            stored = labclient.Prefs.getpref(labclient.Settings.Name);
            stored.Port = "five";       % written by something else
            labclient.Prefs.setpref(labclient.Settings.Name, stored);
            tc.verifyEqual(labclient.Settings.load().Port, 5432, "a stored value of the wrong kind: the default");
            tc.verifyEqual(labclient.Settings.load().Server, "labdb.example.edu", "the other fields kept");
        end

        function fakeVault(tc)
            s = labclient.Settings.load();
            labclient.Secrets.remove(s);
            tc.verifyFalse(labclient.Secrets.has(s));
            tc.verifyError(@() labclient.Secrets.get(s), "labclient:Secrets:None");
            labclient.Secrets.setFake(s, "secret");
            tc.verifyTrue(labclient.Secrets.has(s));
            tc.verifyEqual(labclient.Secrets.get(s), "secret");
            tc.verifyEqual(labclient.Secrets.secretName(s), "CarasLabDB:jdoe@labdb.test:5432/lab");
            labclient.Secrets.remove(s);
            tc.verifyFalse(labclient.Secrets.has(s));
        end

        function rootsLocateAndResolve(tc)
            top = string(tempname);
            mkdir(fullfile(top, "nas", "G-1", "s1"));
            mkdir(fullfile(top, "nas", "inner"));
            tc.addTeardown(@() rmdir(top, "s"));
            s = labclient.Settings.defaults();
            s.Roots = struct("Name", {"nas", "inner"}, ...
                "Path", {fullfile(top, "nas"), fullfile(top, "nas", "inner")});
            file = string(fullfile(top, "nas", "G-1", "s1", "a.mat"));
            [root, rel, why] = labclient.Roots.locate(file, s);
            tc.verifyEqual([root, rel, why], ["nas", "G-1/s1/a.mat", ""]);
            [root, rel] = labclient.Roots.locate(string(fullfile(top, "nas", "inner", "b.mat")), s);
            tc.verifyEqual([root, rel], ["inner", "b.mat"], "the longest root wins");
            [root, ~, why] = labclient.Roots.locate(string(fullfile(tempdir, "elsewhere.mat")), s);
            tc.verifyEqual(root, "");
            tc.verifySubstring(why, "none of the mapped");
            [root, ~, why] = labclient.Roots.locate(string(fullfile(top, "nas")), s);
            tc.verifyEqual(root, "");
            tc.verifySubstring(why, "root folder itself");
            tc.verifyEqual(labclient.Roots.resolve("nas", "G-1/s1/a.mat", s), file);
            tc.verifyEqual(labclient.Roots.resolve("other", "a.mat", s), "");

            labclient.Roots.writeMarker(fullfile(top, "nas"), "nas-old", 7);   % a marker naming another root: refused
            [root, ~, why] = labclient.Roots.locate(file, s);
            tc.verifyEqual(root, "");
            tc.verifySubstring(why, "nas-old");
            labclient.Roots.writeMarker(fullfile(top, "nas"), "nas", 7);
            tc.verifyEqual(labclient.Roots.locate(file, s), "nas", "its own marker: accepted");
        end

        function offUntilSetUp(tc)
            s = labclient.Settings.load();
            s.Enabled = false;
            labclient.Settings.save(s);
            labclient.DB.disconnect();
            tc.verifyEmpty(labclient.DB.connect());
            tc.verifyEqual(labclient.DB.status().State, "off");
            tc.verifySubstring(labclient.DB.status().Message, "turned off");
            tc.verifyEmpty(tc.Fake.Calls, "nothing is tried while the database is off");
            tc.verifyFalse(labclient.Sync.enabled());
            tc.verifyEqual(labclient.Sync.flush().message, "The lab database is turned off on this computer.");
        end

        function connectsAndReportsState(tc)
            b = labclient.DB.connect();
            tc.verifyNotEmpty(b);
            tc.verifyEqual(labclient.DB.status().State, "connected");
            tc.verifyFalse(isnat(labclient.DB.status().Since));
            tc.verifyEqual(tc.Fake.Calls(1:2), ["probe"; "open"], "probed before opening");
            tc.verifyEqual(b.person().PersonId, tc.Fake.PersonId);
            n = tc.Fake.Opens;
            labclient.DB.connect();
            tc.verifyEqual(tc.Fake.Opens, n, "an open connection is reused");
            labclient.DB.disconnect();
            tc.verifyNotEqual(labclient.DB.status().State, "connected");
        end

        function offlineWaitsBeforeTryingAgain(tc)
            tc.Fake.Reachable = false;
            t0 = tic;
            tc.verifyEmpty(labclient.DB.connect());
            tc.verifyLessThan(toc(t0), 2, "an unreachable server costs no wait here");
            st = labclient.DB.status();
            tc.verifyEqual(st.State, "offline");
            tc.verifySubstring(st.Message, "keep working");
            tc.verifyGreaterThan(st.NextTry, datetime("now", "TimeZone", "local"));
            probes = nnz(tc.Fake.Calls == "probe");
            tc.verifyEmpty(labclient.DB.connect());
            tc.verifyEqual(nnz(tc.Fake.Calls == "probe"), probes, "no new try before NextTry");
            tc.Fake.Reachable = true;
            tc.verifyNotEmpty(labclient.DB.connect(Force=true), "Force tries at once");
            tc.verifyEqual(labclient.DB.status().State, "connected");
        end

        function attentionWhenSomethingHereIsWrong(tc)
            s = labclient.Settings.load();
            labclient.Secrets.remove(s);
            tc.verifyEmpty(labclient.DB.connect(Force=true));
            tc.verifyEqual(labclient.DB.status().State, "attention");
            tc.verifySubstring(labclient.DB.status().Message, "No password");
            labclient.Secrets.setFake(s, "wrong");
            tc.verifyEmpty(labclient.DB.connect(Force=true));
            tc.verifyEqual(labclient.DB.status().State, "attention");
            tc.verifySubstring(labclient.DB.status().Message, "refused");
        end

        function folderIsTemporary(tc)
            d = labclient.DB.folder();
            tc.verifyTrue(isfolder(d));
            tc.verifyEqual(d, string(getenv(labclient.DB.EnvVar)), "useTemporary's folder");
        end

        function panelSavesTestsAndMapsRoots(tc)
            s = labclient.Settings.load();
            p = labclient.Panel.open(Visible=false);
            tc.addTeardown(@() p.close());
            p.Ctl.Server.Value = 'labdb.other';
            tc.verifyTrue(p.save());
            tc.verifyEqual(labclient.Settings.load().Server, "labdb.other");
            p.Ctl.Server.Value = char(s.Server);
            p.testConnection();
            tc.verifyEqual(labclient.DB.status().State, "connected");
            tc.verifyEqual(labclient.Settings.load().PersonId, tc.Fake.PersonId, "the person id is kept");

            folder = string(tempname);
            mkdir(folder);
            tc.addTeardown(@() rmdir(folder, "s"));
            labclient.Roots.writeMarker(folder, "someone-else", 3);
            p.addRoot("ws-test-d", folder);
            tc.verifyFalse(any(string({p.Roots.Name}) == "ws-test-d"), "a folder marked as another root is refused");
            delete(fullfile(folder, labclient.Roots.MarkerFile));
            p.addRoot("ws-test-d", folder);
            tc.verifyTrue(any(string({p.Roots.Name}) == "ws-test-d"));
            p.registerRoot("ws-test-d");
            tc.verifyTrue(any(tc.Fake.Roots.name == "ws-test-d"), "registered in the database");
            tc.verifyTrue(isfile(fullfile(folder, labclient.Roots.MarkerFile)), "and its folder marked");
            tc.verifyTrue(p.save());
            tc.verifyTrue(any(string({labclient.Settings.load().Roots.Name}) == "ws-test-d"));
        end

        function lampFollowsTheState(tc)
            f = uifigure("Visible", "off");
            tc.addTeardown(@() delete(f));
            g = uigridlayout(f, [1 2]);
            labclient.DB.disconnect();
            lamp = labclient.Lamp(g, Row=1, Column=2, Parent=f);
            tc.verifySubstring(string(lamp.Button.Text), "Database: offline");
            labclient.DB.connect(Force=true);
            tc.verifySubstring(string(lamp.Button.Text), "Database: connected");
            tc.Fake.Reachable = false;
            labclient.DB.disconnect();
            labclient.DB.connect(Force=true);
            tc.verifySubstring(string(lamp.Button.Text), "Database: offline");
            tc.verifySubstring(string(lamp.Button.Tooltip), "out of reach");
            labclient.Outbox.put(tc.record(tc.file("l.mat", 1:9), Subject="SUBJ-1"));
            lamp.refresh();
            tc.verifySubstring(string(lamp.Button.Text), "1 to send");
        end

        function theInterfaceHasAVersion(tc)
            % what a toolbox asks before it uses the package (labclient.Api)
            tc.verifyEqual(exist("labclient.Api", "class"), 8);
            v = labclient.Api.Version;
            tc.verifyTrue(isnumeric(v) && isscalar(v) && v == fix(v) && v >= 3, "a whole number, 3 or later");
            [ok, why] = labclient.Api.atLeast(v);
            tc.verifyTrue(ok);
            tc.verifyEqual(why, "");
            tc.verifyTrue(labclient.Api.atLeast(1));
            [ok, why] = labclient.Api.atLeast(v + 1);
            tc.verifyFalse(ok, "a toolbox that needs a later version is told so");
            tc.verifySubstring(why, "version " + (v + 1));
            tc.verifySubstring(why, "Update the CarasLabDB checkout");
        end

        % ---- SHA-256, bundles ---------------------------------------------------------------------

        function sha256KnownVectors(tc)
            tc.verifyEqual(labclient.fileSha256("", Text=true), ...
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
            tc.verifyEqual(labclient.fileSha256("abc", Text=true), ...
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
            f = tc.file("abc.txt", uint8('abc'));
            tc.verifyEqual(labclient.fileSha256(f), labclient.fileSha256("abc", Text=true), "a file and its bytes as text");
            tc.verifyError(@() labclient.fileSha256(fullfile(tc.Top, "none.bin")), "labclient:fileSha256:CannotRead");
        end

        function timesAndIds(tc)
            t = labclient.Bundles.timeText(datetime(2026, 7, 2, 14, 30, 0.5, "TimeZone", "America/New_York"));
            tc.verifyEqual(t, "2026-07-02T14:30:00.500000-04:00");
            tc.verifyEqual(labclient.Bundles.timeText(NaT("TimeZone", "UTC")), "");
            tc.verifyError(@() labclient.Bundles.timeText(datetime(2026, 7, 2)), "labclient:Bundles:Unzoned");
        end

        function idsAreV4AndLeaveTheGlobalStreamAlone(tc)
            state = rng;
            ids = strings(1, 200);
            for k = 1:200; ids(k) = labclient.Bundles.newId(); end
            tc.verifyEqual(rng, state, "MATLAB's global random stream is not touched");
            tc.verifyEqual(numel(unique(ids)), 200);
            tc.verifyTrue(all(~cellfun(@isempty, regexp(ids, ...
                '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', 'once'))));
        end

        function goldenBundleIsTheFormat(tc)
            golden = strtrim(string(fileread(fullfile(fileparts(mfilename("fullpath")), ...
                "testdata", "bundle_event_v1.json"))));
            b = labclient.Bundles.seal(tc.golden());
            txt = labclient.Bundles.encode(b);
            tc.verifyEqual(txt, golden, "labclient.Bundles.encode is the documented format, byte for byte. Got: " + txt);
            tc.verifyEqual(b.digest, labclient.fileSha256(labclient.Bundles.encodeRecord(b.record), Text=true));
            d = labclient.Bundles.decode(golden);
            tc.verifyEqual(labclient.Bundles.encode(d), golden, "decoded and encoded again: the same text");
            tc.verifyEqual(labclient.Bundles.seal(d).digest, b.digest, "the same digest from the file");
            tc.verifyEqual(d.record.outputs(1).bytes, 1234);
            tc.verifyEqual(d.record.inputs(1).bytes, 5000000000);
            tc.verifyEqual(d.record.subject_id, "", "a record from before records named their subject");
            tc.verifyEqual(labclient.Bundles.toolOf(d), labclient.Bundles.Untagged, ...
                "a folder and no tool: no toolbox is assumed for it");
            tc.verifySubstring(txt, '"outputs":[{', "a list of one is still a list");
            u = tc.golden();
            u.record.outputs(1).sha256 = "";
            tc.verifyFalse(labclient.Bundles.isSealed(labclient.Bundles.seal(u)), "an output without its hash: not sealed");
        end

        function optionalMembersOnlyWhenGiven(tc)
            f = tc.file("o.mat", 1:5);
            b = tc.record(f, Subject="SUBJ-1");
            txt = labclient.Bundles.encode(b);
            tc.verifySubstring(txt, '"subject_id":"SUBJ-1"');
            tc.verifyEqual(labclient.Bundles.toolOf(b), "", "no dataset folder: needs no tool");
            ds = tc.datasetBlock("n1", "SUBJ-1", "tool-x");
            b2 = tc.record(f, Dataset=ds);
            txt2 = labclient.Bundles.encode(b2);
            tc.verifySubstring(txt2, '"tool":"tool-x"');
            tc.verifyFalse(contains(txt2, '"subject_id"'), "empty: left out");
            tc.verifyEqual(labclient.Bundles.toolOf(labclient.Bundles.decode(txt2)), "tool-x");
            tc.verifyError(@() labclient.Bundles.event(EventId=labclient.Bundles.newId(), EventType="behavior", ...
                OccurredAt=labclient.Bundles.now(), Dataset=ds, SubjectId="SUBJ-2"), "labclient:Bundles:SubjectAndDataset");
        end

        % ---- the outbox ---------------------------------------------------------------------------

        function outboxStatesAndClaims(tc)
            b = labclient.Bundles.seal(tc.golden());
            tc.verifyEqual(labclient.Outbox.put(b), "added");
            tc.verifyEqual(labclient.Outbox.put(b), "unchanged");
            c = labclient.Outbox.counts();
            tc.verifyEqual(c.pending, 1);
            [r, st] = labclient.Outbox.read(b.bundle_id);
            tc.verifyEqual(st, "pending");
            tc.verifyEqual(labclient.Bundles.encode(r), labclient.Bundles.encode(b));
            T = labclient.Outbox.list();
            tc.verifyEqual(T.id, b.bundle_id);
            tc.verifyTrue(T.sealed);

            claim = labclient.Outbox.claim(b.bundle_id);
            tc.verifyNotEmpty(claim);
            tc.verifyEmpty(labclient.Outbox.claim(b.bundle_id), "only one can win a claim");
            labclient.Outbox.finish(claim, "held", Reason="a subject to assign");
            T = labclient.Outbox.list(State="held");
            tc.verifyEqual(T.note, "a subject to assign");
            labclient.Outbox.move(b.bundle_id, "pending");
            claim = labclient.Outbox.claim(b.bundle_id);
            tc.verifyEqual(labclient.Outbox.recoverStale(MaxAge=60), 0, "a live claim is kept");
            pause(1.2);
            tc.verifyEqual(labclient.Outbox.recoverStale(MaxAge=1), 1, "a claim whose MATLAB stopped is given back");
            [~, st] = labclient.Outbox.read(b.bundle_id);
            tc.verifyEqual(st, "pending");
            claim = labclient.Outbox.claim(b.bundle_id);
            labclient.Outbox.finish(claim, "done");
            c = labclient.Outbox.counts();
            tc.verifyEqual([c.pending c.claimed c.held c.failed c.done], [0 0 0 0 1]);
        end

        function aClaimGivenBackIsNotTheOldOwnersAnymore(tc)
            % two processes over one outbox: the first stalls, the second takes its claim back and claims
            b = tc.record(tc.file("c.mat", 1:9), Subject="SUBJ-1");
            labclient.Outbox.put(b);
            id = b.bundle_id;
            c1 = labclient.Outbox.claim(id);
            pause(1.2);
            tc.verifyEqual(labclient.Outbox.recoverStale(MaxAge=1), 1);
            c2 = labclient.Outbox.claim(id);
            tc.verifyNotEmpty(c2);
            tc.verifyNotEqual(c1.claimed_at, c2.claimed_at);
            tc.verifyFalse(labclient.Outbox.finish(c1, "done"), "the old owner no longer holds it");
            tc.verifyEqual(labclient.Outbox.stateOf(id), "claimed", "and changed nothing");
            labclient.Outbox.heartbeat(c1);   % writes nothing either
            hb = jsondecode(fileread(fullfile(labclient.Outbox.root(), "claimed", id + ".claim.json")));
            tc.verifyEqual(string(hb.claimed_at), c2.claimed_at, "the claim file is still the new owner's");
            tc.verifyTrue(labclient.Outbox.finish(c2, "done"));
            tc.verifyEqual(labclient.Outbox.stateOf(id), "done");
        end

        function putReplacesARecordThatWasNotSentYet(tc)
            f = tc.file("p.mat", 1:9);
            b1 = tc.record(f, Subject="SUBJ-1", Notes="version 1");
            id = b1.bundle_id;
            tc.verifyEqual(labclient.Outbox.put(b1), "added");
            tc.verifyEqual(labclient.Outbox.put(b1), "unchanged");

            b2 = b1; b2.record.event.notes = "version 2"; b2.captured_at = labclient.Bundles.now();
            b2 = labclient.Bundles.seal(b2);
            tc.verifyEqual(labclient.Outbox.put(b2), "replaced");
            [r, st] = labclient.Outbox.read(id);
            tc.verifyEqual([st, r.record.event.notes], ["pending", "version 2"]);
            tc.verifySubstring(labclient.Outbox.note(id, "pending").reason, "replaced");
            tc.verifyEqual(labclient.Outbox.counts().pending, 1, "one record, not two");

            % held (with a flag) and failed ones are replaced too, back to pending with no flags
            labclient.Outbox.move(id, "held", Reason="a subject", Flags=labclient.Sync.NeedsSubject);
            b3 = b2; b3.record.event.notes = "version 3"; b3.captured_at = labclient.Bundles.now();
            b3 = labclient.Bundles.seal(b3);
            tc.verifyEqual(labclient.Outbox.put(b3), "replaced");
            tc.verifyEqual(labclient.Outbox.stateOf(id), "pending");
            tc.verifyEmpty(labclient.Outbox.note(id, "pending").flags);
            labclient.Outbox.move(id, "failed", Reason="refused");
            b4 = b3; b4.record.event.notes = "version 4"; b4.captured_at = labclient.Bundles.now();
            b4 = labclient.Bundles.seal(b4);
            tc.verifyEqual(labclient.Outbox.put(b4), "replaced");
            tc.verifyEqual(labclient.Outbox.read(id).record.event.notes, "version 4");

            % the hashes a replaced record had started do not stay
            d = fullfile(labclient.DB.folder(), "hashing");
            mkdir(d);
            writelines("x", fullfile(d, id + "_1.job.json"));
            b5 = b4; b5.record.event.notes = "version 5"; b5.captured_at = labclient.Bundles.now();
            b5 = labclient.Bundles.seal(b5);
            labclient.Outbox.put(b5);
            tc.verifyFalse(isfile(fullfile(d, id + "_1.job.json")));

            % a hash taken of the old capture does not overwrite the new one
            tc.verifyFalse(labclient.Outbox.update(b4), "its capture was replaced");
            tc.verifyEqual(labclient.Outbox.read(id).record.event.notes, "version 5");

            % being sent now, sent, discarded: not replaced, and the caller is told
            claim = labclient.Outbox.claim(id);
            b6 = b5; b6.record.event.notes = "version 6"; b6.captured_at = labclient.Bundles.now();
            b6 = labclient.Bundles.seal(b6);
            tc.verifyError(@() labclient.Outbox.put(b6), "labclient:Outbox:Claimed");
            labclient.Outbox.finish(claim, "done");
            tc.verifyError(@() labclient.Outbox.put(b6), "labclient:Outbox:Sent");
            tc.verifyEqual(labclient.Outbox.put(b5), "unchanged", "the very record that was sent is no error");
            other = tc.record(tc.file("p2.mat", 1:3), Subject="SUBJ-1");
            labclient.Outbox.put(other);
            labclient.Outbox.move(other.bundle_id, "discarded", Reason="no");
            other.record.event.notes = "again";
            tc.verifyError(@() labclient.Outbox.put(other), "labclient:Outbox:Discarded");
        end

        function hasherInMatlabAndChangedFiles(tc)
            f = tc.file("small.bin", uint8(1:200));
            it = labclient.Bundles.item(f, ArtifactId=labclient.Bundles.newId());
            [h, why] = labclient.Hasher.hashNow(it);
            tc.verifyEqual([h, why], [labclient.fileSha256(f), ""]);

            b = tc.golden();
            b.bundle_id = labclient.Bundles.newId();
            b.record.event.event_id = b.bundle_id;
            b.record.outputs = it;
            labclient.Outbox.put(b);
            tc.verifyEqual(labclient.Hasher.work(), 1, "hashed and sealed");
            r = labclient.Outbox.read(b.bundle_id);
            tc.verifyTrue(labclient.Bundles.isSealed(r));
            tc.verifyEqual(r.record.outputs.sha256, labclient.fileSha256(f));

            g = tc.file("changes.bin", uint8(1:100));
            it2 = labclient.Bundles.item(g, ArtifactId=labclient.Bundles.newId());
            pause(1.1);
            tc.file("changes.bin", uint8(1:150));   % rewritten after it was captured
            tc.verifySubstring(labclient.Hasher.changed(it2), "changed after it was captured");
            b2 = b;
            b2.bundle_id = labclient.Bundles.newId();
            b2.record.event.event_id = b2.bundle_id;
            b2.record.outputs = it2;
            labclient.Outbox.put(b2);
            labclient.Hasher.work();
            [~, st] = labclient.Outbox.read(b2.bundle_id);
            tc.verifyEqual(st, "held", "no hash of bytes that were not captured");
            T = labclient.Outbox.list(State="held");
            tc.verifySubstring(T.note, "changed after it was captured");
        end

        function hasherOutOfProcess(tc)
            s = labclient.Settings.load();
            s.HashInProcessMB = 1e-4;   % about 100 bytes: everything bigger goes out of process
            labclient.Settings.save(s);
            f = tc.file("large.bin", uint8(mod(0:99999, 256)));
            b = tc.golden();
            b.record.outputs = labclient.Bundles.item(f, ArtifactId=labclient.Bundles.newId());
            labclient.Outbox.put(b);
            labclient.Hasher.work();   % starts the job
            t0 = tic;
            while toc(t0) < 90 && ~labclient.Bundles.isSealed(labclient.Outbox.read(b.bundle_id))
                pause(0.5);
                labclient.Hasher.work();
            end
            r = labclient.Outbox.read(b.bundle_id);
            tc.verifyTrue(labclient.Bundles.isSealed(r), "the separate process hashed it");
            tc.verifyEqual(r.record.outputs.sha256, labclient.fileSha256(f));
        end

        % ---- a record the database would refuse: said where it is made, kept, held ---------------------

        function problemsSaysWhatTheDatabaseWouldRefuse(tc)
            ok = tc.record(tc.file("rig/p0.mat", 1:10), Subject="SUBJ-1");
            tc.verifyEmpty(labclient.Bundles.problems(ok));
            tc.verifyEmpty(labclient.Bundles.problems(tc.golden()), "the golden record");
            at = labclient.Bundles.now();
            said = @(type, detail, when) strjoin(labclient.Bundles.problems(labclient.Bundles.event( ...
                EventId=labclient.Bundles.newId(), EventType=type, OccurredAt=when, Detail=detail, ...
                SubjectId="SUBJ-1")), "; ");
            % no time, and a time that is not written as timeText writes one
            tc.verifySubstring(said("behavior", struct("task", "t"), ""), "when it happened");
            tc.verifySubstring(said("behavior", struct("task", "t"), "2026-11-18 09:00"), "timeText");
            % a field that is not a column of that type of event
            p = labclient.Bundles.problems(labclient.Bundles.event(EventId=labclient.Bundles.newId(), ...
                EventType="behavior", OccurredAt=at, Detail=struct("task", "t", "trials", 12), SubjectId="SUBJ-1"));
            tc.verifyNumElements(p, 1);
            tc.verifySubstring(p, "Detail field trials ");
            tc.verifySubstring(p, "trials_completed", "it names the columns there are");
            tc.verifySubstring(said("recording", struct("task", "t"), at), "Detail field task", "a behavior column on a recording");
            % a JSON column goes under <name>_json: parameters and environment, and no other
            tc.verifyEmpty(labclient.Bundles.problems(labclient.Bundles.event(EventId=labclient.Bundles.newId(), ...
                EventType="analysis", OccurredAt=at, Detail=struct("pipeline_name", "p", "parameters_json", "{}", ...
                "environment_json", "{}", "started_at", "", "finished_at", at, "status", "succeeded"))));
            tc.verifySubstring(said("recording", struct("hardware_config_json", "{}"), at), "hardware_config_json");
            % an analysis event's times and status
            tc.verifySubstring(said("analysis", struct("finished_at", "yesterday"), at), "finished_at");
            tc.verifySubstring(said("analysis", struct("status", "done"), at), "status");
            % husbandry: what was not measured is not sent, so its name is not judged; the measure is needed
            tc.verifyEmpty(labclient.Bundles.problems(labclient.Bundles.event(EventId=labclient.Bundles.newId(), ...
                EventType="husbandry", OccurredAt=at, SubjectId="SUBJ-1", Detail=struct("measure", "weight", ...
                "weight_g", 20, "water_ml", NaN, "health_status", "", "not_a_column", []))));
            tc.verifySubstring(said("husbandry", struct("measure", "weight", "grams", 20), at), "Detail field grams");
            tc.verifySubstring(said("husbandry", struct("weight_g", 20), at), "what was measured");
            % nothing to say about a files record, and nothing in the record is changed by asking
            tc.verifyEmpty(labclient.Bundles.problems(labclient.Bundles.files(EventId=ok.bundle_id)));
            before = labclient.Bundles.encode(ok);
            labclient.Bundles.problems(ok);
            tc.verifyEqual(labclient.Bundles.encode(ok), before);
        end

        function theDetailColumnsAreTheOnesRecordEventTakes(tc)
            % labclient keeps a copy of the list (a record is made with no database at hand):
            % it must be CarasLabDB's own, name for name
            for type = ["analysis" "recording" "behavior" "husbandry"]
                tc.verifyEqual(sort(labclient.Bundles.detailColumns(type)), sort(CarasLabDB.recordEventColumns(type)), type);
            end
            tc.verifyTrue(all(ismember(labclient.Bundles.JsonDetail, CarasLabDB.recordEventColumns("analysis"))));
            tc.verifyError(@() labclient.Bundles.detailColumns("surgery"), "labclient:Bundles:EventType");
        end

        function aRecordTheDatabaseWouldRefuseIsKeptHeld(tc)
            id = labclient.Bundles.newId();
            bad = labclient.Bundles.event(EventId=id, EventType="behavior", OccurredAt=labclient.Bundles.now(), ...
                Detail=struct("task", "detect", "trials", 12), SubjectId="SUBJ-1");   % trials: not a column
            bad = labclient.Bundles.seal(bad);
            [status, why] = labclient.Outbox.put(bad);
            tc.verifyEqual(status, "added", "it is kept: nothing a toolbox recorded is dropped");
            tc.verifySubstring(strjoin(why, "; "), "Detail field trials ");
            tc.verifyEqual(labclient.Outbox.stateOf(id), "held", "and held, where it is seen at once");
            n = labclient.Outbox.note(id, "held");
            tc.verifySubstring(n.reason, "Detail field trials ");
            tc.verifyTrue(any(n.flags == labclient.Outbox.NotSendable));
            tc.verifyEqual(labclient.Outbox.read(id).record.event.detail.trials, 12, "as it was recorded");
            r = labclient.Sync.flush(Budget=10);
            tc.verifyEqual(r.sent, 0, "not sent");
            tc.verifyEmpty(tc.Fake.Events);
            tc.verifyEqual(labclient.Outbox.counts().held, 1);

            % the same record again changes nothing; a corrected one under the same id replaces it and is sent
            tc.verifyEqual(labclient.Outbox.put(bad), "unchanged");
            good = labclient.Bundles.event(EventId=id, EventType="behavior", OccurredAt=bad.record.event.occurred_at, ...
                Detail=struct("task", "detect", "trials_completed", 12), SubjectId="SUBJ-1");
            [status, why] = labclient.Outbox.put(labclient.Bundles.seal(good));
            tc.verifyEqual(status, "replaced");
            tc.verifyEmpty(why);
            tc.verifyEqual(labclient.Outbox.stateOf(id), "pending");
            tc.verifyEmpty(labclient.Outbox.note(id, "pending").flags, "no flag left on it");
            r = labclient.Sync.flush(Budget=10);
            tc.verifyEqual(r.sent, 1, r.message);
            tc.verifyEqual(tc.Fake.Events(1).detail.trials_completed, 12);

            % a waiting record replaced by one the database would refuse is held too
            id2 = labclient.Bundles.newId();
            fine = labclient.Bundles.seal(labclient.Bundles.event(EventId=id2, EventType="husbandry", ...
                OccurredAt=labclient.Bundles.now(), SubjectId="SUBJ-1", Detail=struct("measure", "weight", "weight_g", 21)));
            tc.verifyEqual(labclient.Outbox.put(fine), "added");
            tc.verifyEqual(labclient.Outbox.stateOf(id2), "pending");
            worse = labclient.Bundles.seal(labclient.Bundles.event(EventId=id2, EventType="husbandry", ...
                OccurredAt="", SubjectId="SUBJ-1", Detail=struct("measure", "weight", "weight_g", 22)));
            [status, why] = labclient.Outbox.put(worse);
            tc.verifyEqual(status, "replaced");
            tc.verifySubstring(strjoin(why, "; "), "when it happened");
            tc.verifyEqual(labclient.Outbox.stateOf(id2), "held");
            tc.verifyTrue(any(labclient.Outbox.note(id2, "held").flags == labclient.Outbox.NotSendable));
        end

        function aHeldRecordReleasedByAPersonFailsAsTheDatabaseSays(tc)
            % the fake refuses what the database refuses, so a toolbox's tests see it too
            id = labclient.Bundles.newId();
            bad = labclient.Bundles.seal(labclient.Bundles.event(EventId=id, EventType="behavior", ...
                OccurredAt=labclient.Bundles.now(), Detail=struct("trials", 12), SubjectId="SUBJ-1"));
            labclient.Outbox.put(bad);
            labclient.Outbox.move(id, "pending", Reason="released by a person");   % flags kept, as the window does
            r = labclient.Sync.flush(Budget=10);
            tc.verifyEqual(r.sent, 0);
            tc.verifyEqual(labclient.Outbox.stateOf(id), "failed");
            n = labclient.Outbox.note(id, "failed");
            tc.verifySubstring(n.reason, "Detail cannot set trials");
            tc.verifyFalse(any(n.flags == labclient.Outbox.NotSendable), "the flag was the hold's, not the record's");
            tc.verifyEmpty(tc.Fake.Events);
            % directly, for each type the fake used not to look at
            be = labclient.DB.connect();
            req = struct("EventType", "recording", "EventId", labclient.Bundles.newId(), "Digest", repmat('a', 1, 64), ...
                "OccurredAt", datetime("now", "TimeZone", "UTC"), "SubjectId", "SUBJ-1", "SessionId", "", "Notes", "", ...
                "AttributesJson", "{}", "RecordedBy", "", "Detail", struct("task", "t"), ...
                "Inputs", struct("artifact_id", {}, "role", {}), "Outputs", struct("artifact_id", {}));
            tc.verifyError(@() be.recordEvent(req), "CarasLabDB:invalidValue");
            req.EventType = "analysis";
            req.Detail = struct("status", "done");
            tc.verifyError(@() be.recordEvent(req), "CarasLabDB:invalidValue");
            req.Detail = struct("status", "succeeded");
            req.OccurredAt = NaT("TimeZone", "UTC");
            tc.verifyError(@() be.recordEvent(req), "labclient:Refused");
        end

        % ---- sending: records of no dataset ---------------------------------------------------------

        function aRecordOfNoDatasetIsSentForItsSubject(tc)
            f = tc.file("rig/s1.mat", 1:64);
            b = tc.record(f, Subject="SUBJ-1");
            labclient.Outbox.put(b);
            r = labclient.Sync.flush(Budget=10);
            tc.verifyEqual(r.sent, 1, r.message);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "done");
            e = tc.Fake.Events(1);
            tc.verifyEqual([e.event_type, e.subject_id, e.session_id], ["behavior", "SUBJ-1", ""], "a subject, no session");
            tc.verifyEmpty(tc.Fake.Sessions, "a behavior record needs no lab.session");
            A = tc.Fake.Artifacts;
            tc.verifyEqual([A.produced_by_event_id, A.relative_path, A.checksum], ...
                [b.bundle_id, "rig/s1.mat", labclient.fileSha256(f)]);
            tc.verifyEqual(e.recorded_by, tc.Fake.PersonId);
        end

        function aSubjectTheDatabaseDoesNotHaveHoldsTheRecord(tc)
            f = tc.file("rig/s9.mat", 1:64);
            b = tc.record(f, Subject="SUBJ-9");
            labclient.Outbox.put(b);
            labclient.Sync.flush(Budget=10);
            id = b.bundle_id;
            tc.verifyEqual(labclient.Outbox.stateOf(id), "held");
            tc.verifySubstring(labclient.Outbox.note(id, "held").reason, "SUBJ-9 is not in the database");
            tc.verifyTrue(any(labclient.Outbox.note(id, "held").flags == labclient.Sync.NeedsSubject));
            tc.verifyEmpty(tc.Fake.Events);
            T = labclient.Sync.subjectHolds();
            tc.verifyEqual([T.folder_id, T.folder, T.tool, T.bundle_id], ["SUBJ-9", "", "", id]);
            tc.verifySubstring(T.name, "behavior");

            % assign it to another subject: the record is re-targeted, sealed again, sent
            labclient.Sync.release("SUBJ-9", "SUBJ-2", T);
            [r, st] = labclient.Outbox.read(id);
            tc.verifyEqual(st, "pending");
            tc.verifyEqual(r.record.subject_id, "SUBJ-2");
            tc.verifyTrue(labclient.Bundles.isSealed(r));
            tc.verifyNotEqual(r.digest, b.digest, "another record: another digest");
            tc.verifySubstring(r.record.event.attributes_json, "subject_assigned_from");
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(tc.Fake.Events(1).subject_id, "SUBJ-2");
            tc.verifyEqual(labclient.Outbox.stateOf(id), "done");
        end

        function theDialogAssignsARecordOfNoDataset(tc)
            f = tc.file("rig/s7.mat", 1:64);
            b = tc.record(f, Subject="SUBJ-10");   % a typo for SUBJ-1
            labclient.Outbox.put(b);
            labclient.Sync.flush(Budget=10);
            dlg = labclient.SubjectAssignDialog.open(FolderId="SUBJ-10", Visible=false);
            tc.addTeardown(@() dlg.cancel());
            items = string(dlg.Ctl.List.Items);
            tc.verifyEqual(items(1), "SUBJ-1", "the nearest subject first");
            dlg.pick("SUBJ-1");
            dlg.ok();
            tc.verifyEqual(dlg.Result, "SUBJ-1");
            tc.verifyEqual(labclient.Outbox.read(b.bundle_id).record.subject_id, "SUBJ-1");
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(tc.Fake.Events(1).subject_id, "SUBJ-1");
            tc.verifyEqual(tc.called("assignSubject"), 0, "no dataset: no session file to note it in");
        end

        function aNonAnalysisRecordWithNoSubjectIsHeld(tc)
            b = labclient.Bundles.event(EventId=labclient.Bundles.newId(), EventType="husbandry", ...
                OccurredAt=labclient.Bundles.now(), Detail=struct("measure", "weight", "weight_g", 20));
            labclient.Outbox.put(labclient.Bundles.seal(b));
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "held");
            tc.verifySubstring(labclient.Outbox.note(b.bundle_id, "held").reason, "names no subject");
        end

        function husbandryEventsAreSent(tc)
            id = labclient.Bundles.newId();
            at = labclient.Bundles.timeText(datetime(2026, 11, 17, 9, 0, 0, "TimeZone", "America/New_York"));
            b = labclient.Bundles.event(EventId=id, EventType="husbandry", OccurredAt=at, SubjectId="SUBJ-1", ...
                Detail=struct("measure", "weight", "weight_g", 24.5, "water_ml", NaN, "health_status", ""), ...
                Notes="after the session");
            labclient.Outbox.put(labclient.Bundles.seal(b));
            r = labclient.Sync.flush(Budget=10);
            tc.verifyEqual(r.sent, 1, r.message);
            e = tc.Fake.Events(1);
            tc.verifyEqual([e.event_type, e.subject_id], ["husbandry", "SUBJ-1"]);
            tc.verifyEqual(sort(string(fieldnames(e.detail))).', sort(["measure"; "weight_g"]).', ...
                "a column not measured is not sent");
            tc.verifyEqual(e.detail.weight_g, 24.5);
            tc.verifyEqual(e.notes, "after the session");
            % the fake refuses what the database would
            req = struct("EventType", "husbandry", "EventId", labclient.Bundles.newId(), "Digest", repmat('a', 1, 64), ...
                "OccurredAt", datetime(2026, 1, 1, "TimeZone", "UTC"), "SubjectId", "SUBJ-1", "SessionId", "", ...
                "Notes", "", "AttributesJson", "{}", "RecordedBy", tc.Fake.PersonId, ...
                "Detail", struct("weight_g", 20), "Inputs", struct("artifact_id", {}, "role", {}), ...
                "Outputs", struct("artifact_id", {}, "storage_root_id", {}, "relative_path", {}, "checksum", {}, ...
                "size_bytes", {}, "role", {}, "format", {}, "attributes_json", {}, "replaces", {}));
            be = labclient.DB.connect();
            tc.verifyError(@() be.recordEvent(req), "labclient:Refused", "a measure is needed");
            req.Detail = struct("measure", "weight", "bogus", 1);
            tc.verifyError(@() be.recordEvent(req), "CarasLabDB:invalidValue");
        end

        % ---- sending: a file replaced by new bytes at the same path -----------------------------------

        function aReplacementFileOfAnEventAlreadySent(tc)
            f = tc.file("rig/session.mat", 1:50);
            ev = tc.record(f, Subject="SUBJ-1");
            labclient.Outbox.put(ev);
            labclient.Sync.flush(Budget=10);
            old = tc.Fake.Artifacts(1, :);
            tc.verifyEqual(labclient.Outbox.stateOf(ev.bundle_id), "done");

            pause(1.1);
            tc.file("rig/session.mat", 1:80);   % the same path, new bytes
            it = labclient.Bundles.item(f, Role="raw", Kind="session", ArtifactId=labclient.Bundles.newId(), ...
                Root="nas", Rel="rig/session.mat", Replaces=old.artifact_id);
            fb = labclient.Bundles.files(EventId=ev.bundle_id, Outputs=it, After=strings(1, 0));
            tc.verifyFalse(labclient.Bundles.isSealed(fb), "the hash is not known yet");
            labclient.Outbox.put(fb);
            tc.verifyEqual(labclient.Hasher.work(), 1);
            r = labclient.Sync.flush(Budget=10);
            tc.verifyEqual(r.sent, 1, r.message);
            A = tc.Fake.Artifacts;
            tc.verifyEqual(height(A), 2);
            tc.verifyEqual(numel(unique(A.relative_path)), 1, "one path");
            tc.verifyNotEqual(A.checksum(1), A.checksum(2));
            tc.verifyEqual(A.produced_by_event_id(2), ev.bundle_id, "a file of the same event");
            D = tc.Fake.Dispositions;
            tc.verifyEqual([D.artifact_id, D.disposition, D.successor_artifact_id], ...
                [old.artifact_id, "replaced", A.artifact_id(2)]);
            be = labclient.DB.connect();
            P = be.artifacts(struct("PresentOnly", true));
            tc.verifyEqual(P.artifact_id, A.artifact_id(2), "only the new bytes are present");

            labclient.Outbox.move(fb.bundle_id, "pending");   % sent again: nothing twice
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(height(tc.Fake.Artifacts), 2);
            tc.verifyEqual(height(tc.Fake.Dispositions), 1);

            % an earlier file the database does not have: noted, not an error
            it2 = labclient.Bundles.item(f, Role="raw", Kind="session", ArtifactId=labclient.Bundles.newId(), ...
                Root="nas", Rel="rig/other.mat", Replaces=labclient.Bundles.newId(), Sha256=repmat('b', 1, 64));
            fb2 = labclient.Bundles.files(EventId=ev.bundle_id, Outputs=it2);
            labclient.Outbox.put(fb2);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(fb2.bundle_id), "done");
            tc.verifySubstring(labclient.Outbox.note(fb2.bundle_id, "done").reason, "not marked replaced");
        end

        function aFileSavedAgainAndAgainNamingItsFirstVersion(tc)
            % a toolbox that names the FIRST version as the one replaced, every time it saves
            rel = "rig/again.mat";
            ev = tc.record(tc.file(rel, 1:50), Subject="SUBJ-1");
            labclient.Outbox.put(ev);
            labclient.Sync.flush(Budget=10);
            a0 = tc.Fake.Artifacts.artifact_id(1);
            t0 = datetime(2026, 11, 18, 9, 0, 0, "TimeZone", "America/New_York");
            be = labclient.DB.connect();
            here = struct("StorageRootId", 1, "RelativePath", rel, "PresentOnly", true);

            [fb1, a1] = tc.savedAgain(ev, rel, 1:60, a0, t0 + minutes(1));
            labclient.Outbox.put(fb1);
            labclient.Sync.flush(Budget=10);
            [fb2, a2] = tc.savedAgain(ev, rel, 1:70, a0, t0 + minutes(2));   % still names the first
            labclient.Outbox.put(fb2);
            r = labclient.Sync.flush(Budget=10);
            tc.verifyEqual(r.sent, 1, r.message);
            tc.verifyEqual(labclient.Outbox.stateOf(fb2.bundle_id), "done");
            D = tc.Fake.Dispositions;
            tc.verifyEqual([D.artifact_id, D.disposition, D.successor_artifact_id], ...
                [a0, "replaced", a1; a1, "replaced", a2], "each version replaced by the next, and nothing else");
            tc.verifyEqual(be.artifacts(here).artifact_id, a2, "one present file at the path: the newest");
            tc.verifySubstring(labclient.Outbox.note(fb2.bundle_id, "done").reason, "its present version " + a1);

            for id = [fb1.bundle_id, fb2.bundle_id]   % sent again, either one: nothing twice
                labclient.Outbox.move(id, "pending");
                labclient.Sync.flush(Budget=10);
            end
            tc.verifyEqual(height(tc.Fake.Artifacts), 3);
            tc.verifyEqual(height(tc.Fake.Dispositions), 2);

            [fb3, a3] = tc.savedAgain(ev, rel, 1:80, a0, t0 + minutes(3));   % followed over two replacements
            labclient.Outbox.put(fb3);
            labclient.Sync.flush(Budget=10);
            D = tc.Fake.Dispositions;
            tc.verifyEqual(height(D), 3);
            tc.verifyEqual([D.artifact_id(3), D.disposition(3), D.successor_artifact_id(3)], [a2, "replaced", a3]);
            tc.verifyEqual(be.artifacts(here).artifact_id, a3);

            % the version at the path was deleted since: nothing of the chain is there to replace
            be.addDisposition(struct("ArtifactId", a3, "Disposition", "deleted", "SuccessorArtifactId", "", ...
                "OccurredAt", t0 + minutes(4), "Note", "cleaned up", "AttributesJson", "{}"));
            [fb4, a4] = tc.savedAgain(ev, rel, 1:90, a0, t0 + minutes(5));
            labclient.Outbox.put(fb4);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(fb4.bundle_id), "done", "left alone, not an error");
            tc.verifyEqual(height(tc.Fake.Dispositions), 4, "nothing recorded for a chain that ends in a deleted file");
            tc.verifyEqual(be.artifacts(here).artifact_id, a4, "the deleted file is not present; the new one is");
        end

        function aReplacementSentAfterANewerOneIsTheOneReplaced(tc)
            % three saves of one path, each naming the first version; the third is sent before the second
            rel = "rig/late.mat";
            ev = tc.record(tc.file(rel, 1:50), Subject="SUBJ-1");
            labclient.Outbox.put(ev);
            labclient.Sync.flush(Budget=10);
            a0 = tc.Fake.Artifacts.artifact_id(1);
            t0 = datetime(2026, 11, 18, 9, 0, 0, "TimeZone", "America/New_York");
            be = labclient.DB.connect();
            here = struct("StorageRootId", 1, "RelativePath", rel, "PresentOnly", true);
            [fb2, a1] = tc.savedAgain(ev, rel, 1:60, a0, t0 + minutes(1));   % captured, and kept back
            [fb3, a2] = tc.savedAgain(ev, rel, 1:70, a0, t0 + minutes(2));   % the bytes on disk now
            labclient.Outbox.put(fb3);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(be.artifacts(here).artifact_id, a2);

            labclient.Outbox.put(fb2);   % the earlier save arrives late
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(fb2.bundle_id), "done");
            D = tc.Fake.Dispositions;
            tc.verifyEqual([D.artifact_id, D.disposition, D.successor_artifact_id], ...
                [a0, "replaced", a2; a1, "replaced", a2], "the late, earlier version is the one replaced");
            tc.verifyTrue(D.occurred_at(2) == t0 + minutes(2), "when the newer version took the place");
            tc.verifyEqual(be.artifacts(here).artifact_id, a2, "the newest bytes stay the present file");
            tc.verifySubstring(labclient.Outbox.note(fb2.bundle_id, "done").reason, "was sent first");

            for id = [fb2.bundle_id, fb3.bundle_id]   % sent again, either one: nothing twice
                labclient.Outbox.move(id, "pending");
                labclient.Sync.flush(Budget=10);
            end
            tc.verifyEqual(height(tc.Fake.Artifacts), 3);
            tc.verifyEqual(height(tc.Fake.Dispositions), 2);

            [fb4, a3] = tc.savedAgain(ev, rel, 1:80, a0, t0 + minutes(3));   % in order again: replaces the newest
            labclient.Outbox.put(fb4);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(be.artifacts(here).artifact_id, a3);
            tc.verifyEqual(height(tc.Fake.Dispositions), 3);
        end

        function aReplacementWhoseTimeCannotBeReadIsLeft(tc)
            % the order of two versions is told by when each took the place; from a backend
            % that does not say when, neither is touched
            rel = "rig/untimed.mat";
            ev = tc.record(tc.file(rel, 1:50), Subject="SUBJ-1");
            labclient.Outbox.put(ev);
            labclient.Sync.flush(Budget=10);
            a0 = tc.Fake.Artifacts.artifact_id(1);
            t0 = datetime(2026, 11, 18, 9, 0, 0, "TimeZone", "America/New_York");
            [fb1, a1] = tc.savedAgain(ev, rel, 1:60, a0, t0 + minutes(1));
            labclient.Outbox.put(fb1);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(height(tc.Fake.Dispositions), 1, "the first replaced by the second, as ever");
            tc.Fake.DispositionTimes = false;
            [fb2, a2] = tc.savedAgain(ev, rel, 1:70, a0, t0 + minutes(2));
            labclient.Outbox.put(fb2);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(fb2.bundle_id), "done", "left, not an error");
            tc.verifyEqual(height(tc.Fake.Dispositions), 1, "nothing recorded when the order cannot be told");
            tc.verifySubstring(labclient.Outbox.note(fb2.bundle_id, "done").reason, "could not be read");
            be = labclient.DB.connect();
            P = be.artifacts(struct("StorageRootId", 1, "RelativePath", rel, "PresentOnly", true));
            tc.verifyEqual(sort(P.artifact_id), sort([a1; a2]), "both stay present, as before this rule: reported, not guessed");
        end

        function aFilesRecordWaitsForItsEventAndHoldsAWrongCopy(tc)
            f = tc.file("rig/w.mat", 1:50);
            ev = tc.record(tc.file("rig/w0.mat", 1:20), Subject="SUBJ-1");
            it = labclient.Bundles.item(f, Role="derived", Kind="x", ArtifactId=labclient.Bundles.newId(), ...
                Root="nas", Rel="rig/w.mat", Sha256=labclient.fileSha256(f), ...
                Attributes=struct("copied_from_sha256", repmat('c', 1, 64)));
            fb = labclient.Bundles.files(EventId=ev.bundle_id, Artifacts=it);
            labclient.Outbox.put(fb);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(fb.bundle_id), "pending", "its event is not in the database yet");
            tc.verifySubstring(labclient.Outbox.note(fb.bundle_id, "pending").reason, "waiting");
            labclient.Outbox.put(ev);
            labclient.Sync.flush(Budget=10);   % the event goes, then the files record is looked at again
            labclient.Outbox.move(fb.bundle_id, "pending");
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(fb.bundle_id), "held", "a copy that is not its source's bytes");
            tc.verifySubstring(labclient.Outbox.note(fb.bundle_id, "held").reason, "not the bytes of the file it copies");
        end

        % ---- sending: copies of a file already in the database, from either toolbox --------------------

        function aNoDatasetRecordOfAFileAlreadyThereIsACopyOfItsEvent(tc)
            % a dataset record of one toolbox first, then another toolbox's record of no dataset, of the same bytes
            tc.registerTool("tool-x");
            f1 = tc.file("sessions/a/beh.mat", 1:90);
            ds = tc.datasetBlock("a", "SUBJ-1", "tool-x");
            b1 = tc.record(f1, Dataset=ds);
            labclient.Outbox.put(b1);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(b1.bundle_id), "done");
            S = tc.Fake.Sessions.session_id;
            tc.verifyEqual(height(tc.Fake.Sessions), 1, "the dataset record made its session");

            f2 = tc.file("rig/beh_copy.mat", 1:90);   % byte for byte the same file
            b2 = tc.record(f2, Subject="SUBJ-1");
            labclient.Outbox.put(b2);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(b2.bundle_id), "done");
            tc.verifySubstring(labclient.Outbox.note(b2.bundle_id, "done").reason, "a copy of the behavior");
            tc.verifyEqual(sum(string({tc.Fake.Events.event_type}) == "behavior"), 1, "no second behavior event");
            A = tc.Fake.Artifacts;
            tc.verifyEqual(height(A), 2);
            tc.verifyTrue(all(A.produced_by_event_id == b1.bundle_id), "both are files of the first event");
            tc.verifyTrue(all(A.session_id == S));
            a = jsondecode(char(A.attributes(2)));
            tc.verifyEqual(string(a.copied_from), A.artifact_id(1));
            tc.verifyEqual(string(a.copy_recorded_as), b2.bundle_id);

            % a record of the same bytes naming another subject is not filed under this one's event
            f3 = tc.file("rig/beh_copy2.mat", 1:90);
            b3 = tc.record(f3, Subject="SUBJ-2");
            labclient.Outbox.put(b3);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(b3.bundle_id), "held");
            tc.verifySubstring(labclient.Outbox.note(b3.bundle_id, "held").reason, "subject SUBJ-1");
        end

        function aDatasetRecordOfAFileAlreadyThereIsACopyOfAnEventWithNoSession(tc)
            % a record of no dataset first, then another toolbox's dataset record of the same bytes
            tc.registerTool("tool-x");
            f1 = tc.file("rig/e1.mat", 1:90);
            b1 = tc.record(f1, Subject="SUBJ-1");
            labclient.Outbox.put(b1);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(b1.bundle_id), "done");
            tc.verifyEmpty(tc.Fake.Sessions);

            f2 = tc.file("sessions/b/beh.mat", 1:90);
            ds = tc.datasetBlock("b", "SUBJ-1", "tool-x");
            b2 = tc.record(f2, Dataset=ds);
            labclient.Outbox.put(b2);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(b2.bundle_id), "done");
            tc.verifySubstring(labclient.Outbox.note(b2.bundle_id, "done").reason, "a copy of the behavior");
            tc.verifyEqual(sum(string({tc.Fake.Events.event_type}) == "behavior"), 1, "no second behavior event");
            A = tc.Fake.Artifacts;
            tc.verifyTrue(all(A.produced_by_event_id == b1.bundle_id));
            tc.verifyEqual(tc.called("copyOfSession"), 0, "an event with no session gives the folder none");
        end

        % ---- sending: a record needs its tool ------------------------------------------------------------

        function aRecordOfAToolNotRunningHereIsNeverClaimed(tc)
            f = tc.file("sessions/c/beh.mat", 1:40);
            ds = tc.datasetBlock("c", "SUBJ-1", "ghost-tool");
            bd = tc.record(f, Dataset=ds);
            bn = tc.record(tc.file("rig/n.mat", 1:41), Subject="SUBJ-2");
            labclient.Outbox.put(bd);
            labclient.Outbox.put(bn);
            tc.verifyFalse(labclient.Sync.hasTool("ghost-tool"));
            r = labclient.Sync.flush(Budget=10);
            tc.verifyEqual(r.sent, 1, "the record of no dataset needs no tool: sent");
            tc.verifyEqual(labclient.Outbox.stateOf(bn.bundle_id), "done");
            tc.verifyEqual(labclient.Outbox.stateOf(bd.bundle_id), "pending", "untouched: not claimed, not failed");
            tc.verifyEqual(labclient.Outbox.note(bd.bundle_id, "pending").reason, "", "not even a note");
            be = labclient.DB.connect();
            tc.verifyEqual(labclient.Sync.sendNext(be).outcome, "none");
            tc.verifyEqual(labclient.Outbox.counts().claimed, 0);

            tc.registerTool("ghost-tool");             % a MATLAB that has it
            r = labclient.Sync.flush(Budget=10);
            tc.verifyEqual(r.sent, 1);
            tc.verifyEqual(labclient.Outbox.stateOf(bd.bundle_id), "done");
            tc.verifyEqual(tc.Fake.Sessions.subject_id, "SUBJ-1");
        end

        function aDatasetRecordForAnUnknownSubjectIsAssignedThroughItsToolsHook(tc)
            tc.registerTool("tool-x");
            f = tc.file("sessions/d/beh.mat", 1:33);
            ds = tc.datasetBlock("d", "SUBJ-7", "tool-x");
            b = tc.record(f, Dataset=ds);
            labclient.Outbox.put(b);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "held");
            T = labclient.Sync.subjectHolds();
            tc.verifyEqual([T.folder_id, T.name, T.tool], ["SUBJ-7", "d", "tool-x"]);
            labclient.Sync.release("SUBJ-7", "SUBJ-1", T);
            tc.verifyEqual(tc.called("assignSubject"), 1);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "pending");
            labclient.Sync.unregisterTool("tool-x");
            T2 = T;
            tc.verifyError(@() labclient.Sync.release("SUBJ-7", "SUBJ-1", T2), "labclient:Sync:NoTool");
        end

        function anUntaggedDatasetRecordWaitsForTheToolThatTakesThem(tc)
            % a dataset record that names no tool (written before records named their tool)
            f = tc.file("sessions/u/beh.mat", 1:44);
            ds = tc.datasetBlock("u", "SUBJ-1", "");
            b = tc.record(f, Dataset=ds);
            tc.verifyEqual(labclient.Bundles.toolOf(b), labclient.Bundles.Untagged);
            tc.verifyFalse(contains(labclient.Bundles.encode(b), '"tool"'), "no tool: the member is left out");
            labclient.Outbox.put(b);
            tc.registerTool("tool-x");                 % a tool runs here, but not one that takes them
            tc.verifyFalse(labclient.Sync.hasTool(labclient.Bundles.Untagged));
            tc.verifyEqual(labclient.Sync.untaggedTool(), "");
            r = labclient.Sync.flush(Budget=10);
            tc.verifyEqual(r.sent, 0);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "pending", "untouched: not claimed, not failed");
            tc.verifyEqual(labclient.Outbox.note(b.bundle_id, "pending").reason, "", "not even a note");
            tc.verifyEqual(tc.called("readSession"), 0, "no tool's hooks were tried on it");
            tc.verifyError(@() labclient.Sync.hooks(labclient.Bundles.Untagged), "labclient:Sync:NoTool");

            labclient.Sync.unregisterTool("tool-x");
            tc.registerTool("tool-old", TakesUntagged=true);   % the toolbox that wrote such records
            tc.verifyEqual(labclient.Sync.untaggedTool(), "tool-old");
            tc.verifyTrue(labclient.Sync.hasTool(labclient.Bundles.Untagged));
            r = labclient.Sync.flush(Budget=10);
            tc.verifyEqual(r.sent, 1);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "done");
            tc.verifyGreaterThan(tc.called("readSession"), 0, "sent through that tool's hooks");
            tc.verifyEqual(tc.Fake.Sessions.subject_id, "SUBJ-1");
        end

        function anUntaggedDatasetRecordIsAssignedThroughTheToolThatTakesThem(tc)
            tc.registerTool("tool-old", TakesUntagged=true);
            f = tc.file("sessions/v/beh.mat", 1:35);
            ds = tc.datasetBlock("v", "SUBJ-7", "");
            b = tc.record(f, Dataset=ds);
            labclient.Outbox.put(b);
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "held");
            T = labclient.Sync.subjectHolds();
            tc.verifyEqual([T.folder_id, T.name, T.tool], ["SUBJ-7", "v", labclient.Bundles.Untagged]);
            labclient.Sync.release("SUBJ-7", "SUBJ-1", T(:, ["name" "folder"]));   % no tool column: names no tool either
            tc.verifyEqual(tc.called("assignSubject"), 1);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "pending");
            labclient.Sync.unregisterTool("tool-old");
            tc.verifyError(@() labclient.Sync.release("SUBJ-7", "SUBJ-1", T), "labclient:Sync:NoTool");
        end

        function onlyOneToolTakesTheUntaggedRecords(tc)
            tc.registerTool("tool-old", TakesUntagged=true);
            tc.verifyError(@() tc.registerTool("tool-new", TakesUntagged=true), "labclient:Sync:UntaggedTaken");
            tc.verifyFalse(labclient.Sync.hasTool("tool-new"), "refused: not registered at all");
            tc.registerTool("tool-new");               % without them it may run beside the other
            tc.verifyEqual(labclient.Sync.untaggedTool(), "tool-old");
            tc.registerTool("tool-old", TakesUntagged=true);   % the same tool again: its registration replaced
            tc.verifyEqual(labclient.Sync.untaggedTool(), "tool-old");
            tc.registerTool("tool-old");               % registered again without it: it takes them no more
            tc.verifyEqual(labclient.Sync.untaggedTool(), "");
            tc.verifyFalse(labclient.Sync.hasTool(labclient.Bundles.Untagged));
            hooks = labclient.Sync.hooks("tool-old");
            tc.verifyError(@() labclient.Sync.registerTool(labclient.Bundles.Untagged, hooks), "labclient:Sync:BadName");
        end

        function toolHooksAreChecked(tc)
            tc.verifyError(@() labclient.Sync.registerTool("t", struct("readSession", 1)), "labclient:Sync:BadHooks");
            tc.verifyEqual(labclient.Sync.tools(), strings(1, 0));
            tc.registerTool("t");
            tc.verifyEqual(labclient.Sync.tools(), "t");
            tc.verifyTrue(labclient.Sync.hasTool("t"));
            tc.verifyTrue(labclient.Sync.hasTool(""), "no tool needed: always");
            labclient.Sync.unregisterTool("t");
            tc.verifyFalse(labclient.Sync.hasTool("t"));
            tc.verifyError(@() labclient.Sync.hooks("t"), "labclient:Sync:NoTool");
        end

        function sendingTwiceWritesOnce(tc)
            b = tc.record(tc.file("rig/t.mat", 1:12), Subject="SUBJ-1");
            labclient.Outbox.put(b);
            labclient.Sync.flush(Budget=10);
            labclient.Outbox.move(b.bundle_id, "pending");
            labclient.Sync.flush(Budget=10);
            tc.verifyEqual(numel(tc.Fake.Events), 1);
            tc.verifySubstring(labclient.Outbox.note(b.bundle_id, "done").reason, "already in the database");
        end

        function anUnreachableServerLeavesTheOutboxAsItWas(tc)
            b = tc.record(tc.file("rig/u.mat", 1:12), Subject="SUBJ-1");
            labclient.Outbox.put(b);
            tc.Fake.Reachable = false;
            t0 = tic;
            r = labclient.Sync.flush(Budget=10);
            tc.verifyLessThan(toc(t0), 5);
            tc.verifyEqual(r.sent, 0);
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "pending");
        end

        function noSendingWhileSuspended(tc)
            b = tc.record(tc.file("rig/s.mat", 1:12), Subject="SUBJ-1");
            labclient.Outbox.put(b);
            quiet = labclient.Sync.suspend();
            labclient.Sync.tick();
            tc.verifyEqual(labclient.Outbox.stateOf(b.bundle_id), "pending");
            clear quiet
            tc.verifyFalse(labclient.Sync.suspended());
        end

        % ---- the subject cache --------------------------------------------------------------------------

        function theSubjectCacheIsReadFromTheFileOnly(tc)
            % a weight and an endpoint in the database, a baseline weight variable
            tc.Fake.Subjects = [tc.Fake.Subjects; table("SUBJ-3", "P1", "mus_musculus", "M", ...
                'VariableNames', tc.Fake.Subjects.Properties.VariableNames)];
            tc.Fake.SubjectInfo = table(["SUBJ-1"; "SUBJ-3"], [datetime(2026, 5, 1); NaT], ...
                [NaT("TimeZone", "UTC"); datetime(2026, 11, 1, "TimeZone", "UTC")], ...
                'VariableNames', {'subject_id', 'date_of_birth', 'endpoint_at'});
            for w = [24.5 25.5]
                at = labclient.Bundles.timeText(datetime(2026, 11, 10, 9, 0, 0, "TimeZone", "UTC") + days(double(w > 25)));
                b = labclient.Bundles.event(EventId=labclient.Bundles.newId(), EventType="husbandry", ...
                    OccurredAt=at, SubjectId="SUBJ-1", Detail=struct("measure", "weight", "weight_g", w));
                labclient.Outbox.put(labclient.Bundles.seal(b));
            end
            labclient.Sync.flush(Budget=10);
            tc.Fake.Variables = table("subject", "SUBJ-1", "baseline weight", "26", 26, "", "g", ...
                datetime(2026, 11, 2, "TimeZone", "UTC"), 'VariableNames', tc.Fake.Variables.Properties.VariableNames);

            T0 = labclient.SubjectCache.status(["SUBJ-1"; "SUBJ-3"; "NOPE"]);
            tc.verifyEqual(T0.known, [false; false; false], "nothing asked yet");
            tc.verifyTrue(all(isnat(T0.as_of)));

            r = labclient.SubjectCache.refresh(["SUBJ-1"; "SUBJ-3"; "NOPE"]);
            tc.verifyTrue(r.Connected, r.Message);
            tc.verifyEqual(r.Refreshed, 3);
            tc.verifyEqual(r.NotFound, "NOPE");
            tc.verifyTrue(isfile(labclient.SubjectCache.file()));

            % the file only: the database may be off, gone, or refuse
            tc.Fake.Reachable = false;
            s = labclient.Settings.load(); s.Enabled = false; labclient.Settings.save(s);
            labclient.DB.disconnect();
            T = labclient.SubjectCache.status(["SUBJ-3"; "SUBJ-1"; "NOPE"; "NEVER"]);
            tc.verifyEqual(T.subject_id, ["SUBJ-3"; "SUBJ-1"; "NOPE"; "NEVER"]);
            tc.verifyEqual(T.known, [true; true; false; false]);
            tc.verifyEqual(T.is_endpointed(1:2), [true; false]);
            tc.verifyEqual(T.latest_weight_g(2), 25.5, "the newest weight");
            tc.verifyEqual(T.baseline_weight_g(2), 26);
            tc.verifyTrue(isnan(T.baseline_weight_g(1)));
            tc.verifyEqual(T.project(2), "P1");
            tc.verifyEqual(T.sex(1:2), ["M"; "F"]);
            tc.verifyEqual(T.species(2), "mus_musculus");
            tc.verifyEqual(T.date_of_birth(2), datetime(2026, 5, 1));
            tc.verifyTrue(isnat(T.date_of_birth(1)));
            tc.verifyEqual(posixtime(T.endpoint_at(1)), posixtime(datetime(2026, 11, 1, "TimeZone", "UTC")));
            tc.verifyFalse(isnat(T.as_of(3)), "asked and absent is not never asked");
            tc.verifyTrue(isnat(T.as_of(4)));
            tc.verifyTrue(ismissing(T.project(3)) && isnan(T.latest_weight_g(3)));

            % refresh with nothing reachable: never throws, changes nothing
            r2 = labclient.SubjectCache.refresh("SUBJ-1");
            tc.verifyFalse(r2.Connected);
            tc.verifyNotEmpty(r2.Message);
            tc.verifyEqual(labclient.SubjectCache.status("SUBJ-1").latest_weight_g, 25.5);
        end

        function aRefreshKeepsTheOtherSubjectsAndFollowsChanges(tc)
            labclient.SubjectCache.refresh("SUBJ-1");
            b = labclient.Bundles.event(EventId=labclient.Bundles.newId(), EventType="husbandry", ...
                OccurredAt=labclient.Bundles.now(), SubjectId="SUBJ-2", Detail=struct("measure", "weight", "weight_g", 30));
            labclient.Outbox.put(labclient.Bundles.seal(b));
            labclient.Sync.flush(Budget=10);
            r = labclient.SubjectCache.refresh("SUBJ-2");
            tc.verifyEqual(r.Refreshed, 1);
            T = labclient.SubjectCache.status(["SUBJ-1"; "SUBJ-2"]);
            tc.verifyEqual(T.known, [true; true], "the first subject's entry is still there");
            tc.verifyTrue(isnan(T.latest_weight_g(1)));
            tc.verifyEqual(T.latest_weight_g(2), 30);
        end
    end
end
