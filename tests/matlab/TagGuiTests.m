classdef (SharedTestFixtures = {LabScratchDb}) TagGuiTests < matlab.uitest.TestCase
%TAGGUITESTS Tests of the Tags filter and the tag editor of CarasLabDBApp.
%
%   results = runtests("tests/matlab/TagGuiTests.m")
%
%   Needs the scratch database of LABSCRATCHDB (see its help) and a display:
%   the app's windows open on screen while the tests drive them with
%   matlab.uitest gestures (type, press, choose).
%
%   How the modal tag editor is driven: it blocks in uiwait, so each test
%   opens it from the test (Ctrl+T, the toolbar button, or showTagEditor)
%   while a timer finds the window, runs the test's steps against it and
%   closes it; what the steps observe is checked once the editor returns.
%
%   Keyboard shortcuts: matlab.uitest has no key-press gesture, so a
%   shortcut is tested by calling the window's KeyPressFcn with the event
%   a uifigure would deliver (Key, Modifier, Character). That tests the
%   dispatch; whether the real window delivers the key -- for example while
%   a text box has focus -- is a check for a person at the keyboard.
%
%   Alerts: the folder alertSpy is put on the path, where its uialert
%   records each alert's text and then shows the real alert, which the tests
%   dismiss with dismissAlertDialog (proving that it appeared).
%
%   The user's own CarasLabDBApp preferences are saved before the tests and
%   restored afterwards; the tests start from the defaults.
%
%   See also LABSCRATCHDB, TAGTESTS, CARASLABDBAPP.

    properties
        Fx      % the LabScratchDb shared fixture
        App     % the CarasLabDBApp under test
    end

    methods (TestClassSetup)
        function setupClass(tc)
            import matlab.unittest.fixtures.PathFixture
            import matlab.unittest.fixtures.SuppressedWarningsFixture
            tc.Fx = tc.getSharedTestFixtures("LabScratchDb");

            had = ispref("CarasLabDBApp", "Prefs");
            saved = [];
            if had
                saved = getpref("CarasLabDBApp", "Prefs");
                rmpref("CarasLabDBApp", "Prefs");
            end
            tc.addTeardown(@() TagGuiTests.restorePrefs(had, saved));

            setappdata(groot, "TagGuiTests_realUialert", @uialert);
            tc.applyFixture(PathFixture(fullfile(fileparts(mfilename("fullpath")), "alertSpy")));
            tc.addTeardown(@() rmappdata(groot, "TagGuiTests_realUialert"));
            tc.applyFixture(SuppressedWarningsFixture("MATLAB:uiautomation:Driver:WarnInHGCallbacks"));
        end
    end

    methods (TestMethodSetup)
        function openApp(tc)
            tc.assumeTrue(tc.Fx.Available, tc.Fx.Reason);
            % Closing the previous test's app saved its filter and tab; start
            % every test from the defaults instead.
            if ispref("CarasLabDBApp", "Prefs")
                rmpref("CarasLabDBApp", "Prefs");
            end
            setappdata(groot, "TagGuiTests_alerts", []);
            tc.App = CarasLabDBApp(tc.Fx.Db);
            tc.addTeardown(@() tc.closeAll());
        end
    end

    % =====================================================================
    % Tags filter field
    % =====================================================================
    methods (Test)
        function tagFilterMatchesDatabase(tc)
            % Section 9: the Tags field on each browse tab gives the rows
            % lab.fn_find_by_tags gives (as in section 4).
            w = tc.guiWorld();
            m = tc.mainParts();
            tc.chooseTab("artifacts");
            cases = {
                "stage:raw",            "stage:raw", "", ""
                "stage:raw -qc:fail",   "stage:raw", "", "qc:fail"
                "qc:*",                 "qc:*",      "", ""
                "-qc:*",                strings(1, 0), "", "qc:*"
                "gui_bare",             "gui_bare",  "", ""
                "  Stage:RAW   Topic:Gui ", ["stage:raw", "topic:gui"], "", ""};
            for i = 1:size(cases, 1)
                tc.type(m.TagField, cases{i, 1});
                tc.verifyEmpty(TagGuiTests.alerts(), "no alert for '" + cases{i, 1} + "'");
                got = LabScratchDb.column(m.Tables.artifacts.Data, "artifact_id");
                want = tc.Fx.findByTagsSql("artifact", cases{i, 2}, [], ...
                    TagGuiTests.nonEmpty(cases{i, 4}), true);
                tc.verifyEqual(sort(got), sort(want), "artifacts: '" + cases{i, 1} + "'");
                tc.verifySubstring(string(m.Status.Text), "tags: " + strtrim(cases{i, 1}));
            end
            tc.verifyTrue(ismember(w.A(1), LabScratchDb.column(m.Tables.artifacts.Data, "artifact_id")), ...
                "the last case (stage:raw topic:gui) includes this test's first artifact");

            tc.type(m.TagField, "cohort:a");
            tc.chooseTab("subjects");
            tc.verifyEqual(sort(LabScratchDb.column(m.Tables.subjects.Data, "subject_id")), ...
                sort(tc.Fx.findByTagsSql("subject", "cohort:a")));
            tc.type(m.TagField, "qc:pass");
            tc.chooseTab("events");
            tc.verifyEqual(sort(LabScratchDb.column(m.Tables.events.Data, "event_id")), ...
                sort(tc.Fx.findByTagsSql("event", "qc:pass")));
            tc.chooseTab("sessions");
            tc.type(m.TagField, "-qc:*");
            tc.verifyEqual(sort(LabScratchDb.column(m.Tables.sessions.Data, "session_id")), ...
                sort(tc.Fx.findByTagsSql("session", [], [], "qc:*")));
        end

        function malformedTokenShowsAMessage(tc)
            % Section 9: a malformed token gives an alert and a status line,
            % not a stack trace, and the app stays usable.
            m = tc.mainParts();
            tc.chooseTab("artifacts");
            tc.type(m.TagField, "stage:raw!");
            a = TagGuiTests.alerts();
            tc.assertNumElements(a, 1);
            tc.verifyEqual(a.Title, "Invalid filter");
            tc.verifySubstring(a.Message, "Invalid tag 'stage:raw!'");
            tc.verifySubstring(string(m.Status.Text), "Filter error: Invalid tag 'stage:raw!'");
            tc.dismissAlertDialog(m.Fig);
            tc.type(m.TagField, "-");
            tc.type(m.TagField, "stage:raw");
            tc.verifyNumElements(TagGuiTests.alerts(), 1, "no further alerts");
            tc.verifyEqual(sort(LabScratchDb.column(m.Tables.artifacts.Data, "artifact_id")), ...
                sort(tc.Fx.findByTagsSql("artifact", "stage:raw")));
        end

        function clearEmptiesTheTagsField(tc)
            % Section 9: Clear (and Esc) empty the Tags field and unfilter.
            m = tc.mainParts();
            tc.chooseTab("artifacts");
            allIds = sort(LabScratchDb.column(m.Tables.artifacts.Data, "artifact_id"));
            tc.type(m.TagField, "qc:*");
            tc.press(m.Clear);
            tc.verifyEqual(string(m.TagField.Value), "");
            tc.verifyEqual(sort(LabScratchDb.column(m.Tables.artifacts.Data, "artifact_id")), allIds);
            tc.type(m.TagField, "qc:*");
            TagGuiTests.key(m.Fig, "escape", {});
            tc.verifyEqual(string(m.TagField.Value), "", "Esc clears too");
        end

        function tagFilterIsRememberedOnReopen(tc)
            % Section 9: the LastTagFilter pref is restored after close and reopen.
            m = tc.mainParts();
            tc.chooseTab("artifacts");
            tc.type(m.TagField, "stage:raw -qc:fail");
            close(m.Fig);                       % CloseRequestFcn -> delete -> savePrefs
            tc.verifyFalse(isvalid(tc.App));
            p = getpref("CarasLabDBApp", "Prefs");
            tc.verifyEqual(p.LastTagFilter, "stage:raw -qc:fail");

            tc.App = CarasLabDBApp(tc.Fx.Db);
            m = tc.mainParts();
            tc.verifyEqual(string(m.TagField.Value), "stage:raw -qc:fail");
            tc.verifyEqual(string(findall(tc.App.Fig, "Type", "uitabgroup").SelectedTab.Tag), ...
                "artifacts", "the last tab is restored too");
            tc.verifyEqual(sort(LabScratchDb.column(m.Tables.artifacts.Data, "artifact_id")), ...
                sort(tc.Fx.findByTagsSql("artifact", "stage:raw", [], "qc:fail")), ...
                "the remembered filter is applied on opening");
        end
    end

    % =====================================================================
    % Tag editor
    % =====================================================================
    methods (Test)
        function ctrlTOpensEditorForSelectedRow(tc)
            % Section 9: Ctrl+T on a selected row; the editor's lists.
            w = tc.guiWorld();
            db = tc.Fx.Db;
            aid = w.A(1);
            tc.selectRow("artifacts", aid);
            obs = tc.withEditor(@() TagGuiTests.key(tc.App.Fig, "t", {'control'}, char(20)), ...
                @(ed, obs) local_inspect(tc, ed, obs));

            tc.verifySubstring(obs("name"), "artifact " + aid);
            want = CarasLabDB.displayTag(tc.currentTags("artifact", aid));
            tc.verifyEqual(sort(obs("listed")), sort(want), "lists the current tags");
            NS = db.getTagNamespaces(AppliesTo="artifact");
            tc.verifyEqual(sort(obs("namespaces")), sort(string(NS.namespace)), ...
                "only namespaces whose applies_to includes artifact");
            tc.verifyEqual(obs("lastNamespace"), "tag", "bare tags last");
            tc.verifyTrue(obs("valueEditable"));
            tc.verifyEqual(obs("stageValues"), string(db.getTags(Namespace="stage").value), ...
                "value list = getTags of the namespace");
            tc.verifySubstring(obs("stageHint"), "stage: mutable · single-valued · closed vocabulary");
            tc.verifyTrue(obs("setEnabledForStage"));
            tc.verifyFalse(obs("setEnabledForTopic"));
            tc.verifyTrue(obs("escResumed"), "Esc closes the editor");

            function local_inspect(tc, ed, obs)
                obs("name") = string(ed.Fig.Name);
                obs("listed") = TagGuiTests.listed(ed);
                obs("namespaces") = reshape(string(ed.Ns.ItemsData), [], 1);
                obs("lastNamespace") = string(ed.Ns.ItemsData{end});
                obs("valueEditable") = logical(ed.Value.Editable);
                tc.choose(ed.Ns, "stage");
                obs("stageValues") = reshape(string(ed.Value.Items), [], 1);
                obs("stageHint") = string(ed.Hint.Text);
                obs("setEnabledForStage") = logical(ed.Set.Enable);
                tc.choose(ed.Ns, "topic");
                obs("setEnabledForTopic") = logical(ed.Set.Enable);
                TagGuiTests.key(ed.Fig, "escape", {});
                obs("escResumed") = TagGuiTests.resumed(ed.Fig);
            end
        end

        function addSetAndRemoveWork(tc)
            % Section 9: Add, Set and Remove through the buttons; bare tags.
            db = tc.Fx.Db;
            w = tc.Fx.makeWorld("gui-edit", 1);
            aid = w.ArtifactIds(1);
            tc.chooseTab("artifacts");
            tc.selectRow("artifacts", aid);
            obs = tc.withEditor(@() tc.press(tc.mainParts().TagsBtn), @(ed, obs) local_edit(tc, ed, obs));

            tc.verifyEqual(obs("afterAdd"), "topic:gui_add");
            tc.verifyEqual(obs("statusAdd"), "Added topic:gui_add.");
            tc.verifyEqual(obs("afterSet1"), ["stage:raw"; "topic:gui_add"]);
            tc.verifyEqual(obs("afterSet2"), ["stage:sorted"; "topic:gui_add"]);
            tc.verifyEqual(obs("statusSetAgain"), "stage:sorted was already set.");
            tc.verifyEqual(obs("rowsAfterSetAgain"), obs("rowsAfterSet2"), "Set of the current value writes nothing");
            tc.verifyEqual(obs("afterRemove"), "stage:sorted");
            tc.verifyEqual(obs("afterBare"), ["stage:sorted"; "tag:gui_bare2"]);
            tc.verifyTrue(ismember("gui_bare2", obs("listedBare")), "a bare tag is listed bare");
            tc.verifyEmpty(TagGuiTests.alerts());
            H = db.getEntityTags("artifact", aid, History=true);
            tc.verifyEqual(string(H.op)', ["add", "add", "remove", "add", "remove", "add"]);

            function local_edit(tc, ed, obs)
                cur = @() tc.currentTags("artifact", aid);
                tc.type(ed.Value, "topic:gui_add");
                tc.press(ed.Add);
                obs("afterAdd") = cur();
                obs("statusAdd") = string(ed.Status.Text);
                tc.choose(ed.Ns, "stage");
                tc.choose(ed.Value, "raw");
                tc.press(ed.Set);
                obs("afterSet1") = cur();
                tc.choose(ed.Ns, "stage");
                tc.choose(ed.Value, "sorted");
                tc.press(ed.Set);
                obs("afterSet2") = cur();
                obs("rowsAfterSet2") = height(db.getEntityTags("artifact", aid, History=true));
                tc.choose(ed.Ns, "stage");
                tc.choose(ed.Value, "sorted");
                tc.press(ed.Set);
                obs("statusSetAgain") = string(ed.Status.Text);
                obs("rowsAfterSetAgain") = height(db.getEntityTags("artifact", aid, History=true));
                tc.choose(ed.Table, [find(TagGuiTests.listed(ed) == "topic:gui_add"), 1]);
                tc.press(ed.Remove);
                obs("afterRemove") = cur();
                tc.choose(ed.Ns, "tag (bare)");
                tc.type(ed.Value, "gui_bare2");
                tc.press(ed.Add);
                obs("afterBare") = cur();
                obs("listedBare") = TagGuiTests.listed(ed);
                tc.press(ed.Close);
            end
        end

        function typingAValueNeverWrites(tc)
            % Section 9: typing in the Value box writes nothing, whatever is
            % clicked next; Enter selects the namespace and the button.
            db = tc.Fx.Db;
            w = tc.Fx.makeWorld("gui-typing", 1);
            aid = w.ArtifactIds(1);
            db.addTag("artifact", aid, "topic:keep");
            H0 = db.getEntityTags("artifact", aid, History=true);
            obs = tc.withEditor(@() tc.App.showTagEditor("artifact", aid), @(ed, obs) local_type(tc, ed, obs));

            tc.verifyEqual(obs("nsAfterTopic"), "topic");
            tc.verifyEqual(obs("statusTopic"), "Press Add (Enter or Space) to apply topic:typed_only.");
            tc.verifyEqual(obs("nsAfterStage"), "stage");
            tc.verifyEqual(obs("statusStage"), "Press Set (Enter or Space) to apply stage:raw.");
            tc.verifyEqual(obs("valueKept"), "stage:raw", "the typed text stays in the box");
            tc.verifyEqual(obs("rowsAfterTyping"), height(H0));
            tc.verifyEqual(obs("rowsAfterList"), height(H0), "type, then click the list");
            tc.verifyEqual(obs("rowsAfterRemove"), height(H0), "type, then Remove (nothing selected)");
            tc.verifySubstring(obs("removeAlert"), "does not currently have tag stage:sorted");
            H1 = db.getEntityTags("artifact", aid, History=true);
            tc.verifyEqual(H1.assignment_id, H0.assignment_id, "type, then Close: nothing written");

            function local_type(tc, ed, obs)
                rows = @() height(db.getEntityTags("artifact", aid, History=true));
                tc.type(ed.Value, "topic:typed_only");
                obs("nsAfterTopic") = string(ed.Ns.Value);
                obs("statusTopic") = string(ed.Status.Text);
                tc.type(ed.Value, "stage:raw");
                obs("nsAfterStage") = string(ed.Ns.Value);
                obs("statusStage") = string(ed.Status.Text);
                obs("valueKept") = string(ed.Value.Value);
                obs("rowsAfterTyping") = rows();
                % type, then Remove with nothing selected in the list (the
                % typed tag is registered but not on this artifact)
                tc.type(ed.Value, "stage:sorted");
                setappdata(groot, "TagGuiTests_alerts", []);
                tc.press(ed.Remove);
                a = TagGuiTests.alerts();
                obs("removeAlert") = strjoin([a.Message], newline);
                tc.dismissAlertDialog(ed.Fig);
                obs("rowsAfterRemove") = rows();
                % type, then click the list
                tc.type(ed.Value, "topic:typed_2");
                tc.choose(ed.Table, [1 1]);
                obs("rowsAfterList") = rows();
                % type, then Close
                tc.type(ed.Value, "topic:typed_4");
                tc.press(ed.Close);
            end
        end

        function removeWithoutSelectionUsesTheTypedTag(tc)
            % Section 9 (observation): with no row selected, Remove removes
            % the tag in the Value box. That is a write, so it is reported.
            db = tc.Fx.Db;
            w = tc.Fx.makeWorld("gui-rmtyped", 1);
            aid = w.ArtifactIds(1);
            db.addTag("artifact", aid, ["topic:keep", "topic:other"]);
            obs = tc.withEditor(@() tc.App.showTagEditor("artifact", aid), @(ed, obs) local_rm(tc, ed, obs));
            tc.verifyEmpty(obs("selection"), "nothing was selected in the list");
            tc.log(1, "Remove with no list selection removed the typed tag: now " + ...
                strjoin(tc.currentTags("artifact", aid), ", "));
            tc.verifyEqual(tc.currentTags("artifact", aid), "topic:other");

            function local_rm(tc, ed, obs)
                tc.type(ed.Value, "topic:keep");
                obs("selection") = ed.Table.Selection;
                tc.press(ed.Remove);
                tc.press(ed.Close);
            end
        end

        function editorKeyboardShortcuts(tc)
            % Section 9: Ctrl+Enter, Ctrl+S, Delete, Ctrl+R, Ctrl+?, Esc.
            db = tc.Fx.Db;
            w = tc.Fx.makeWorld("gui-keys", 1);
            aid = w.ArtifactIds(1);
            obs = tc.withEditor(@() tc.App.showTagEditor("artifact", aid), @(ed, obs) local_keys(tc, ed, obs));

            tc.verifyEqual(obs("ctrlEnter"), "topic:k1");
            tc.verifyEqual(obs("ctrlS"), ["stage:raw"; "topic:k1"]);
            tc.verifyEqual(obs("ctrlSMulti"), obs("ctrlS"), "Ctrl+S does nothing for a multi-valued namespace");
            tc.verifyEqual(obs("delete"), "stage:raw");
            tc.verifyFalse(ismember("topic:behind_its_back", obs("listedBeforeReload")));
            tc.verifyTrue(ismember("topic:behind_its_back", obs("listedAfterReload")), "Ctrl+R reloads");
            for s = ["Ctrl+Enter", "Ctrl+S", "Delete", "Ctrl+R", "Esc", "Ctrl+?"]
                tc.verifySubstring(obs("help"), s);
            end
            tc.verifyTrue(obs("escResumed"), "Esc closes the editor");

            function local_keys(tc, ed, obs)
                cur = @() tc.currentTags("artifact", aid);
                ctrl = {'control'};
                tc.type(ed.Value, "topic:k1");
                TagGuiTests.key(ed.Fig, "return", ctrl);
                obs("ctrlEnter") = cur();
                tc.choose(ed.Ns, "stage");
                tc.choose(ed.Value, "raw");
                TagGuiTests.key(ed.Fig, "s", ctrl, char(19));
                obs("ctrlS") = cur();
                tc.choose(ed.Ns, "topic");
                tc.type(ed.Value, "k2");
                TagGuiTests.key(ed.Fig, "s", ctrl, char(19));
                obs("ctrlSMulti") = cur();
                tc.choose(ed.Table, [find(TagGuiTests.listed(ed) == "topic:k1"), 1]);
                TagGuiTests.key(ed.Fig, "delete", {});
                obs("delete") = cur();
                db.addTag("artifact", aid, "topic:behind_its_back");
                obs("listedBeforeReload") = TagGuiTests.listed(ed);
                TagGuiTests.key(ed.Fig, "r", ctrl, char(18));
                obs("listedAfterReload") = TagGuiTests.listed(ed);
                setappdata(groot, "TagGuiTests_alerts", []);
                TagGuiTests.key(ed.Fig, "slash", ctrl, '?');
                a = TagGuiTests.alerts();
                obs("help") = strjoin([a.Message], newline);
                tc.dismissAlertDialog(ed.Fig);
                TagGuiTests.key(ed.Fig, "escape", {});
                obs("escResumed") = TagGuiTests.resumed(ed.Fig);
            end
        end

        function policyErrorsAreAlerts(tc)
            % Section 9: immutable remove, closed vocabulary and applies_to
            % refusals appear as alerts and the editor stays usable.
            db = tc.Fx.Db;
            w = tc.Fx.makeWorld("gui-policy", 1);
            db.setTag("subject", w.SubjectId, "cohort:a");

            obs = tc.withEditor(@() tc.App.showTagEditor("subject", w.SubjectId), ...
                @(ed, obs) local_immutable(tc, ed, obs));
            tc.verifyEqual(obs("title"), "Tag not applied");
            tc.verifySubstring(obs("message"), "tag namespace cohort is immutable");
            tc.verifyEqual(tc.currentTags("subject", w.SubjectId), ["cohort:a"; "topic:still_usable"]);

            obs = tc.withEditor(@() tc.App.showTagEditor("artifact", w.ArtifactIds(1)), ...
                @(ed, obs) local_closed(tc, ed, obs));
            tc.verifySubstring(obs("message"), "closed vocabulary");
            tc.verifyEqual(tc.currentTags("artifact", w.ArtifactIds(1)), "stage:raw");

            obs = tc.withEditor(@() tc.App.showTagEditor("event", w.EventId), ...
                @(ed, obs) local_applies(tc, ed, obs));
            tc.verifySubstring(obs("message"), "tags of namespace stage apply to artifact only, not to event");
            tc.verifyEqual(tc.currentTags("event", w.EventId), "qc:pass");

            function local_immutable(tc, ed, obs)
                tc.choose(ed.Table, [find(TagGuiTests.listed(ed) == "cohort:a"), 1]);
                tc.press(ed.Remove);
                local_alert(tc, ed, obs);
                tc.choose(ed.Ns, "topic");
                tc.type(ed.Value, "still_usable");
                tc.press(ed.Add);
                tc.press(ed.Close);
            end
            function local_closed(tc, ed, obs)
                tc.type(ed.Value, "stage:not_a_stage");
                tc.press(ed.Set);
                local_alert(tc, ed, obs);
                tc.choose(ed.Ns, "stage");
                tc.choose(ed.Value, "raw");
                tc.press(ed.Set);
                tc.press(ed.Close);
            end
            function local_applies(tc, ed, obs)
                tc.type(ed.Value, "stage:raw");
                tc.press(ed.Add);
                local_alert(tc, ed, obs);
                tc.choose(ed.Ns, "qc");
                tc.choose(ed.Value, "pass");
                tc.press(ed.Set);
                tc.press(ed.Close);
            end
            function local_alert(tc, ed, obs)
                a = TagGuiTests.alerts();
                tc.assertNotEmpty(a, "no alert was shown");
                obs("title") = a(end).Title;
                obs("message") = a(end).Message;
                tc.dismissAlertDialog(ed.Fig);       % fails if no real alert is open
                setappdata(groot, "TagGuiTests_alerts", []);
            end
        end
    end

    % =====================================================================
    % Toolbar, help, refresh
    % =====================================================================
    methods (Test)
        function toolbarButtonOpensTheSameEditor(tc)
            % Section 9: the Tags… button opens the editor for the selected row.
            w = tc.Fx.makeWorld("gui-toolbar", 0);
            tc.chooseTab("events");
            tc.selectRow("events", w.EventId);
            obs = tc.withEditor(@() tc.press(tc.mainParts().TagsBtn), @(ed, obs) local_name(ed, obs));
            tc.verifyEqual(obs("name"), "Tags · event " + w.EventId);
            tc.verifyEqual(sort(obs("namespaces")), ...
                sort(string(tc.Fx.Db.getTagNamespaces(AppliesTo="event").namespace)));

            function local_name(ed, obs)
                obs("name") = string(ed.Fig.Name);
                obs("namespaces") = reshape(string(ed.Ns.ItemsData), [], 1);
                uiresume(ed.Fig);
            end
        end

        function noSelectionGivesAMessage(tc)
            % Section 9: with no row selected the editor does not open; a
            % message says why. Ctrl+T on the Custom SQL tab likewise.
            m = tc.mainParts();
            tc.chooseTab("artifacts");
            m.Tables.artifacts.Selection = [];
            tc.press(m.TagsBtn);
            tc.dismissAlertDialog(m.Fig);
            TagGuiTests.key(m.Fig, "t", {'control'}, char(20));
            tc.dismissAlertDialog(m.Fig);
            a = TagGuiTests.alerts();
            tc.assertNumElements(a, 2);
            tc.verifyEqual([a.Title], ["Tags", "Tags"]);
            tc.verifyEqual([a.Message], ["Select a row first.", "Select a row first."]);
            tc.verifyEmpty(TagGuiTests.findEditor());
            setappdata(groot, "TagGuiTests_alerts", []);
            tc.chooseTab("sql");
            TagGuiTests.key(m.Fig, "t", {'control'}, char(20));
            a = TagGuiTests.alerts();
            tc.assertNumElements(a, 1);
            tc.verifyEqual(a.Message, "Tags are edited on the browse tabs.");
            tc.dismissAlertDialog(m.Fig);
        end

        function shortcutHelpListsCtrlT(tc)
            % Section 9: Ctrl+? lists Ctrl+T; no other main-window shortcut
            % takes Ctrl+T, and Ctrl+Shift+T reaches the same action.
            m = tc.mainParts();
            TagGuiTests.key(m.Fig, "slash", {'control'}, '?');
            a = TagGuiTests.alerts();
            tc.assertNumElements(a, 1);
            tc.verifyEqual(a.Title, "Keyboard shortcuts");
            tc.verifySubstring(a.Message, "Ctrl+T           Tags of the selected row");
            lines = splitlines(a.Message);
            tc.verifyEqual(nnz(contains(lines, "Ctrl+T")), 1, "Ctrl+T is listed once");
            tc.dismissAlertDialog(m.Fig);
            setappdata(groot, "TagGuiTests_alerts", []);
            tc.chooseTab("artifacts");
            m.Tables.artifacts.Selection = [];
            TagGuiTests.key(m.Fig, "t", {'control', 'shift'}, char(20));
            a = TagGuiTests.alerts();
            tc.assertNumElements(a, 1);
            tc.verifyEqual(a.Message, "Select a row first.", "Ctrl+Shift+T goes to the tag action");
            tc.dismissAlertDialog(m.Fig);
        end

        function tableRefreshesAfterAnEdit(tc)
            % Section 9: after an edit in the editor the main table is re-queried.
            w = tc.Fx.makeWorld("gui-refresh", 1);
            aid = w.ArtifactIds(1);
            tc.Fx.Db.setTag("artifact", aid, "stage:raw");
            m = tc.mainParts();
            tc.chooseTab("artifacts");
            tc.type(m.TagField, "stage:raw");
            tc.assertTrue(ismember(aid, LabScratchDb.column(m.Tables.artifacts.Data, "artifact_id")));
            tc.selectRow("artifacts", aid);
            tc.withEditor(@() TagGuiTests.key(m.Fig, "t", {'control'}, char(20)), @(ed, obs) local_set(tc, ed));
            tc.verifyEqual(tc.currentTags("artifact", aid), "stage:sorted");
            tc.verifyFalse(ismember(aid, LabScratchDb.column(m.Tables.artifacts.Data, "artifact_id")), ...
                "the filtered table no longer shows the row");

            function local_set(tc, ed)
                tc.choose(ed.Ns, "stage");
                tc.choose(ed.Value, "sorted");
                tc.press(ed.Set);
                tc.press(ed.Close);
            end
        end
    end

    % =====================================================================
    % Helpers
    % =====================================================================
    methods (Access = private)
        function w = guiWorld(tc)
            %GUIWORLD Tagged rows for the filter tests.
            db = tc.Fx.Db;
            x = tc.Fx.makeWorld("gui", 4);
            w.A = x.ArtifactIds;
            db.addTag("artifact", w.A(1), ["stage:raw", "topic:gui"]);
            db.addTag("artifact", w.A(2), ["stage:raw", "qc:fail"]);
            db.addTag("artifact", w.A(3), ["qc:pass", "gui_bare"]);
            db.addTag("event", x.EventId, "qc:pass");
            db.addTag("subject", x.SubjectId, "cohort:a");
            db.addTag("session", x.SessionId, "qc:pass");
        end

        function m = mainParts(tc)
            %MAINPARTS The main window's controls the tests use.
            f = tc.App.Fig;
            m.Fig = f;
            m.TagField = findall(f, "Type", "uieditfield", "Placeholder", "stage:raw -qc:fail topic:*");
            m.Clear = findall(f, "Type", "uibutton", "Text", "Clear");
            m.TagsBtn = findall(f, "Type", "uibutton", "Text", "Tags…");
            root = f.Children(1);
            m.Status = findall(root, "-depth", 1, "Type", "uilabel");
            m.Tables = struct();
            for key = ["subjects", "sessions", "events", "artifacts"]
                m.Tables.(key) = findall(findall(f, "Type", "uitab", "Tag", key), "Type", "uitable");
            end
        end

        function chooseTab(tc, key)
            tc.choose(findall(tc.App.Fig, "Type", "uitab", "Tag", key));
        end

        function selectRow(tc, key, id)
            %SELECTROW Select the row with primary key ID on browse tab KEY.
            tc.chooseTab(key);
            m = tc.mainParts();
            t = m.Tables.(key);
            col = t.Data.Properties.VariableNames{1};
            r = find(string(t.Data.(col)) == id, 1);
            tc.assertNotEmpty(r, "row " + id + " is not shown on the " + key + " tab");
            tc.choose(t, [r 1]);
        end

        function tags = currentTags(tc, kind, id)
            tags = sort(LabScratchDb.column(tc.Fx.Db.getEntityTags(kind, id), "tag"));
        end

        function obs = withEditor(tc, openFcn, steps)
            %WITHEDITOR Open the modal tag editor with OPENFCN and run STEPS on it.
            %   OPENFCN returns only when the editor closes (it blocks in
            %   uiwait). A timer finds the editor window and calls
            %   STEPS(ed, obs), where ed holds its controls and obs is a
            %   containers.Map for what the test wants to check afterwards;
            %   the editor is then closed if STEPS left it open. An error
            %   inside STEPS is rethrown here.
            % The timer callback is a static method, not a nested function:
            % a nested one would keep this workspace (and the timers) alive
            % after the test, and a stale driver would then act on the next
            % test's editor.
            obs = containers.Map();
            drive = timer("StartDelay", 0.5, "Period", 0.5, "ExecutionMode", "fixedSpacing", ...
                "TasksToExecute", 120, "TimerFcn", @(t, ~) TagGuiTests.drive(t, steps, obs));
            safety = timer("StartDelay", 90, "TimerFcn", @(~, ~) TagGuiTests.closeEditors());
            start(drive);
            start(safety);
            try
                openFcn();
            catch ME
                TagGuiTests.stopTimers([drive, safety]);
                rethrow(ME);
            end
            TagGuiTests.stopTimers([drive, safety]);
            if isKey(obs, "__error")
                rethrow(obs("__error"));
            end
            tc.assertTrue(isKey(obs, "__ran"), "the tag editor did not open");
        end

        function closeAll(tc)
            TagGuiTests.closeEditors();
            if ~isempty(tc.App) && isvalid(tc.App)
                delete(tc.App);
            end
        end
    end

    methods (Static, Access = private)
        function drive(t, steps, obs)
            %DRIVE Timer callback of WITHEDITOR: once the editor waits, run STEPS on it.
            f = TagGuiTests.findEditor();
            f = f(arrayfun(@(x) strcmp(get(x, "WaitStatus"), "waiting"), f));
            if isempty(f)
                return      % not open yet, or still being built
            end
            stop(t);
            obs("__ran") = true;
            try
                steps(TagGuiTests.editorParts(f(1)), obs);
            catch ME
                obs("__error") = ME;
            end
            TagGuiTests.closeEditors();
        end

        function ed = editorParts(f)
            %EDITORPARTS The tag editor's controls, found by type and text.
            ed.Fig = f;
            dds = findall(f, "Type", "uidropdown");
            editable = arrayfun(@(d) logical(d.Editable), dds);
            ed.Ns = dds(~editable);
            ed.Value = dds(editable);
            btn = @(txt) findall(f, "Type", "uibutton", "Text", txt);
            ed.Add = btn("Add");
            ed.Set = btn("Set");
            ed.Remove = btn("Remove");
            ed.Close = btn("Close");
            ed.Table = findall(f, "Type", "uitable");
            labels = findall(f, "Type", "uilabel");
            grey = arrayfun(@(l) isequal(l.FontColor, [0.35 0.35 0.35]), labels);
            ed.Hint = labels(grey);
            ed.Status = findall(ed.Close.Parent, "-depth", 1, "Type", "uilabel");
        end

        function f = findEditor()
            f = findall(groot, "Type", "figure");
            f = f(startsWith(string({f.Name}), "Tags "));
        end

        function tf = resumed(f)
            %RESUMED Whether uiresume was called on F (uiwait waits on WaitStatus).
            tf = ~isvalid(f) || strcmp(get(f, "WaitStatus"), "inactive");
        end

        function closeEditors()
            for f = reshape(TagGuiTests.findEditor(), 1, [])
                uiresume(f);
            end
        end

        function stopTimers(ts)
            for t = ts
                if isvalid(t)
                    stop(t);
                    delete(t);
                end
            end
            TagGuiTests.closeEditors();
        end

        function shown = listed(ed)
            %LISTED The Tag column of the editor's list (display form).
            if isempty(ed.Table.Data)
                shown = strings(0, 1);
            else
                shown = reshape(string(ed.Table.Data.Tag), [], 1);
            end
        end

        function key(fig, k, mods, ch)
            %KEY Deliver a key press to FIG's KeyPressFcn as a uifigure would.
            if nargin < 4
                ch = '';
            end
            evt = struct("Key", char(k), "Modifier", {mods}, "Character", ch);
            feval(fig.KeyPressFcn, fig, evt);
        end

        function a = alerts()
            a = getappdata(groot, "TagGuiTests_alerts");
            if isempty(a)
                a = struct("Figure", {}, "Message", {}, "Title", {});
            end
        end

        function t = nonEmpty(s)
            s = string(s);
            t = s(strlength(s) > 0);
        end

        function restorePrefs(had, saved)
            if had
                setpref("CarasLabDBApp", "Prefs", saved);
            elseif ispref("CarasLabDBApp", "Prefs")
                rmpref("CarasLabDBApp", "Prefs");
            end
        end
    end
end
