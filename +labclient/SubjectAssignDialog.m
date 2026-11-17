classdef SubjectAssignDialog < handle
    % labclient.SubjectAssignDialog  A folder names a subject the lab database does not have: create it, or assign the session to one it has.
    %   dlg = labclient.SubjectAssignDialog.open(Parent=fig, FolderId="G-0421")
    %
    %   Opened by labclient.Sync when a record waits for its subject (and from the
    %   Database window, Assign subjects...). The database must answer: the
    %   window lists its subjects. Two choices:
    %
    %     Create subject     add the subject to the database (its id, the
    %                        project, the species and the sex)
    %     Assign to existing the session belongs to a subject the database
    %                        has: the folder name may be misspelled. The
    %                        subjects are listed nearest first (editDistance
    %                        to the folder's subject id).
    %
    %   "Also for the other datasets ..." applies the choice to every dataset
    %   waiting with the same folder subject id. The choice is noted in each
    %   dataset's session file (<Name>_labdb.json, subject_id); the folders
    %   and their names are never changed. The records held for them are then
    %   sent again (labclient.Sync.release).
    %
    %   Keys: Enter OK · Esc cancel · Ctrl+? list the keys.
    %
    %   Methods, the same paths as the controls (tests): choose("create" |
    %   "existing"), pick(subjectId), ok(), cancel(). Result is "" until OK,
    %   then the subject id assigned.
    %
    %   See also labclient.Sync, labclient.Panel.

    properties (SetAccess = private)
        Fig = []
        Ctl struct = struct()
        FolderId (1,1) string = ""
        Datasets table = table()
        Result (1,1) string = ""
    end

    properties (Access = private)
        Backend = []
    end

    methods (Static)
        function dlg = open(opts)
            %open  The window for folder subject FolderId ([] when the database does not answer).
            arguments
                opts.Parent = []
                opts.FolderId (1,1) string
                opts.Visible (1,1) logical = true
            end
            dlg = [];
            b = labclient.DB.connect(MaxWait=2);
            if isempty(b)
                if ~isempty(opts.Parent) && isvalid(opts.Parent) && opts.Visible
                    uialert(opts.Parent, "The lab database does not answer now: " + ...
                        labclient.DB.status().Message, "Subjects", "Icon", "warning");
                end
                return
            end
            dlg = labclient.SubjectAssignDialog(b, opts.Parent, opts.FolderId, opts.Visible);
        end

        function r = ranked(id, ids)
            %ranked  IDS nearest to ID first (edit distance, ignoring case; ties by name).
            ids = reshape(string(ids), [], 1);
            if isempty(ids); r = ids; return; end
            d = zeros(numel(ids), 1);
            for k = 1:numel(ids)
                d(k) = labclient.SubjectAssignDialog.distance(char(lower(id)), char(lower(ids(k))));
            end
            [~, order] = sortrows(table(d, lower(ids)));
            r = ids(order);
        end
    end

    methods
        function choose(obj, how)
            %choose  "create" or "existing".
            arguments
                obj
                how (1,1) string {mustBeMember(how, ["create" "existing"])}
            end
            obj.Ctl.Create.Value = how == "create";
            obj.Ctl.Existing.Value = how == "existing";
            obj.showChoice();
        end

        function pick(obj, subjectId)
            %pick  Select SUBJECTID in the list of existing subjects.
            obj.choose("existing");
            items = string(obj.Ctl.List.Items);
            k = find(items == string(subjectId), 1);
            if isempty(k)
                error("labclient:SubjectAssignDialog:NoSubject", "Subject %s is not in the list.", subjectId);
            end
            obj.Ctl.List.Value = char(items(k));
        end

        function ok(obj)
            %ok  Create or assign, note it in the session files, send the held records again.
            c = obj.Ctl;
            try
                if c.Create.Value
                    id = strtrim(string(c.NewId.Value));
                    if id == ""
                        obj.say("Type the subject's id.");
                        return
                    end
                    if isempty(c.Project.Value) || string(c.Project.Value) == ""
                        obj.say("Choose the subject's project.");
                        return
                    end
                    a = struct("SubjectId", id, "ProjectId", string(c.Project.Value), ...
                        "SpeciesCode", string(c.Species.Value), "Sex", string(c.Sex.Value));
                    obj.Backend.addSubject(a);
                else
                    id = string(c.List.Value);
                    if isempty(id) || id == ""
                        obj.say("Choose the subject the session belongs to.");
                        return
                    end
                end
                D = obj.Datasets;
                if ~c.All.Value; D = D(1, :); end
                labclient.Sync.release(obj.FolderId, id, D);
            catch ME
                obj.say(string(ME.message));
                return
            end
            obj.Result = id;
            delete(obj.Fig);
        end

        function cancel(obj)
            %cancel  Close; the records stay held.
            if ~isempty(obj.Fig) && isvalid(obj.Fig); delete(obj.Fig); end
        end
    end

    methods (Access = private)
        function obj = SubjectAssignDialog(b, parent, folderId, visible)
            obj.Backend = b;
            obj.FolderId = folderId;
            T = labclient.Sync.subjectHolds();
            T = T(T.folder_id == folderId, :);
            % one row per dataset folder; a record of no dataset (no folder) is a row of its own
            key = labclient.pathKey(T.folder);
            key(T.folder == "") = "record:" + T.bundle_id(T.folder == "");
            [~, first] = unique(key, "stable");
            obj.Datasets = T(first, {'name', 'folder', 'bundle_id', 'tool'});
            S = b.subjects(struct());
            P = b.projects();
            Sp = b.species();
            pos = [100 100 560 460];
            if ~isempty(parent) && isvalid(parent)
                pp = parent.Position;
                pos(1:2) = pp(1:2) + max(0, (pp(3:4) - pos(3:4)) / 2);
            end
            f = uifigure("Name", "Subject " + folderId, "Position", pos, "Visible", "off", ...
                "WindowStyle", "modal", "Tag", "SubjectAssignDialog", "KeyPressFcn", @(~, e) obj.onKey(e));
            obj.Fig = f;
            g = uigridlayout(f, [8 2]);
            g.RowHeight = {'fit', 'fit', 24, 24, 24, '1x', 'fit', 30};
            g.ColumnWidth = {150, '1x'};
            c = struct();
            n = height(obj.Datasets);
            namedBy = "the folder of";
            if all(obj.Datasets.folder == ""); namedBy = "the record of"; end
            head = uilabel(g, "WordWrap", "on", "Text", sprintf( ...
                'Subject %s, named by %s %s, is not in the lab database.', folderId, namedBy, ...
                labclient.SubjectAssignDialog.listText(obj.Datasets.name)));
            head.Layout.Column = [1 2];
            c.Create = uicheckbox(g, "Text", "Create subject", "Value", true, ...
                "ValueChangedFcn", @(~, ~) obj.choose("create"));
            c.NewId = uieditfield(g, "text", "Value", char(folderId));
            uilabel(g, "Text", "Project");
            c.Project = uidropdown(g, "Items", reshape(cellstr(string(P.project_id) + " - " + string(P.name)), 1, []), ...
                "ItemsData", reshape(cellstr(string(P.project_id)), 1, []));
            uilabel(g, "Text", "Species");
            c.Species = uidropdown(g, "Items", [{'(not given)'}, reshape(cellstr(string(Sp.common_name)), 1, [])], ...
                "ItemsData", [{''}, reshape(cellstr(string(Sp.code)), 1, [])]);
            uilabel(g, "Text", "Sex");
            c.Sex = uidropdown(g, "Items", {'unknown', 'female', 'male'}, "ItemsData", {'U', 'F', 'M'});
            c.Existing = uicheckbox(g, "Text", "Assign to existing", "Value", false, ...
                "ValueChangedFcn", @(~, ~) obj.choose("existing"));
            c.Existing.Layout.Row = 6;
            c.Existing.Layout.Column = 1;
            ids = labclient.SubjectAssignDialog.ranked(folderId, string(S.subject_id));
            c.List = uilistbox(g, "Items", reshape(cellstr(ids), 1, []), "Tooltip", "Nearest to " + folderId + " first");
            c.List.Layout.Row = 6;
            c.List.Layout.Column = 2;
            c.All = uicheckbox(g, "Value", n > 1, "Enable", n > 1, "Text", sprintf( ...
                'Also for the other %d dataset(s) whose folders name subject %s', max(0, n - 1), folderId));
            c.All.Layout.Column = [1 2];
            bg = uigridlayout(g, [1 3]);
            bg.Layout.Column = [1 2];
            bg.ColumnWidth = {'1x', 90, 90};
            bg.Padding = [0 0 0 0];
            c.Message = uilabel(bg, "Text", "", "FontColor", [0.75 0.10 0.10], "WordWrap", "on");
            uibutton(bg, "Text", "OK", "Tooltip", "Create or assign (Enter)", "ButtonPushedFcn", @(~, ~) obj.ok());
            uibutton(bg, "Text", "Cancel", "Tooltip", "The records stay held (Esc)", ...
                "ButtonPushedFcn", @(~, ~) obj.cancel());
            obj.Ctl = c;
            obj.showChoice();
            if visible; f.Visible = "on"; end
        end

        function showChoice(obj)
            c = obj.Ctl;
            on = c.Create.Value;
            for h = {c.NewId, c.Project, c.Species, c.Sex}
                h{1}.Enable = on;
            end
            c.List.Enable = ~on;
        end

        function onKey(obj, e)
            mods = string(e.Modifier);
            ctrl = any(mods == "control") || any(mods == "command");
            key = string(e.Key);
            if ctrl && (ismember(key, ["slash", "questionmark"]) || string(e.Character) == "?")
                uialert(obj.Fig, sprintf(['Enter    OK: create or assign\n' ...
                    'Esc      Cancel (the records stay held)\n' ...
                    'Ctrl+?   This list']), "Keyboard shortcuts", "Icon", "info");
            elseif key == "return"
                obj.ok();
            elseif key == "escape"
                obj.cancel();
            end
        end

        function say(obj, text)
            if ~isempty(obj.Fig) && isvalid(obj.Fig)
                obj.Ctl.Message.Text = char(text);
            end
        end
    end

    methods (Static, Access = private)
        function n = distance(a, b)
            %distance  The Levenshtein distance of char rows A and B (no toolbox needed).
            prev = 0:numel(b);
            for i = 1:numel(a)
                cur = [i, zeros(1, numel(b))];
                for j = 1:numel(b)
                    cur(j + 1) = min([prev(j + 1) + 1, cur(j) + 1, prev(j) + (a(i) ~= b(j))]);
                end
                prev = cur;
            end
            n = prev(end);
        end

        function t = listText(names)
            names = reshape(string(names), 1, []);
            if numel(names) > 3
                t = strjoin(names(1:3), ", ") + sprintf(" and %d more", numel(names) - 3);
            else
                t = strjoin(names, ", ");
            end
        end
    end
end
