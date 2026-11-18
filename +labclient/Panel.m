classdef Panel < handle
    % labclient.Panel  The Database window: set up the lab database on this computer and see its state.
    %   p = labclient.Panel.open()                 % one window per MATLAB; again brings it to the front
    %   p = labclient.Panel.open(Parent=appFigure) % placed over the app that asked
    %
    %   It holds the settings labclient.Settings keeps (turn the database on or
    %   off, the server, the database, your login, the zone old times are
    %   read in), sets your password with MATLAB's own vault dialog
    %   (labclient.Secrets; it is never shown or stored here), tests the
    %   connection, and maps the lab's storage roots to folders on this
    %   computer (labclient.Roots): pick a folder and the root's name; a root that
    %   is not in the database yet (this workstation's data disk, say) can
    %   be registered in it, and a marker file is written at its top.
    %
    %   The outbox (labclient.Outbox) lists what waits to be sent, or waits for
    %   you, with the reason: Send now (labclient.Sync.flush), Retry a failed
    %   record, Hold one, Release a held one (Send as me for one captured
    %   under another login), Discard (asks first; the record is kept,
    %   marked discarded, with who and why), Details (the record as
    %   written) and Assign subjects... (labclient.SubjectAssignDialog).
    %
    %   Keys: Ctrl+S save · F5 test the connection · Ctrl+R send now ·
    %   Esc or Ctrl+W close · Ctrl+? list the keys.
    %
    %   The toolboxes open it from their File > Database... menu and from the Database lamp
    %   in their status bar (labclient.Lamp).
    %
    %   See also labclient.DB, labclient.Settings, labclient.Secrets, labclient.Roots.

    properties (SetAccess = private)
        Fig = []
        Ctl struct = struct()
        Roots struct = struct("Name", {}, "Path", {})
        OutboxIds (:,1) string = strings(0, 1)   % the record of each outbox row
    end

    properties (Access = private)
        Listener = []
        OutboxListener = []
    end

    methods (Static)
        function p = open(opts)
            %open  Show the Database window (one per MATLAB).
            arguments
                opts.Parent = []
                opts.Visible (1,1) logical = true
            end
            persistent current
            if ~isempty(current) && isvalid(current) && ~isempty(current.Fig) && isvalid(current.Fig)
                if opts.Visible
                    current.Fig.Visible = "on";
                    figure(current.Fig);
                end
                p = current;
                return
            end
            current = labclient.Panel(opts.Parent, opts.Visible);
            p = current;
        end

        function fig = showText(title, text, parent)
            %showText  A small read-only window that lists TEXT (lines), with a Close button.
            arguments
                title (1,1) string
                text (:,1) string
                parent = []
            end
            pos = [200 200 560 420];
            try
                if ~isempty(parent) && isvalid(parent)
                    p = parent.Position;
                    pos(1:2) = p(1:2) + [40 p(4) - pos(4) - 40];
                end
            catch
            end
            fig = uifigure("Name", title, "Position", pos, "Tag", "LabClientText");
            g = uigridlayout(fig, [2 1], "RowHeight", {'1x', 34}, "Padding", [10 10 10 10], "RowSpacing", 8);
            area = uitextarea(g, "Value", cellstr(text), "Editable", "off", "FontName", "Consolas", "FontSize", 13);
            area.Layout.Row = 1;
            b = uibutton(g, "Text", "Close", "ButtonPushedFcn", @(~, ~) delete(fig));
            b.Layout.Row = 2;
        end
    end

    methods
        function s = formSettings(obj)
            %formSettings  The settings as the form shows them (not yet saved).
            c = obj.Ctl;
            s = labclient.Settings.load();
            s.Enabled = c.Enabled.Value;
            s.Server = string(c.Server.Value);
            s.Port = c.Port.Value;
            s.DatabaseName = string(c.Database.Value);
            s.Username = string(c.Username.Value);
            s.PersonEmail = string(c.PersonEmail.Value);
            s.LabTimeZone = string(c.TimeZone.Value);
            s.Roots = obj.Roots;
        end

        function ok = save(obj)
            %save  Store the form's settings (Ctrl+S); false, with a message, when one is wrong.
            ok = false;
            try
                labclient.Settings.save(obj.formSettings());
            catch ME
                obj.say(string(ME.message), true);
                return
            end
            labclient.DB.disconnect();
            labclient.Sync.start(IfEnabled=true);
            obj.say("Saved.", false);
            ok = true;
        end

        function testConnection(obj)
            %testConnection  Save, connect now and say what came of it (F5).
            if ~obj.save()
                return
            end
            obj.say("Connecting...", false);
            drawnow limitrate
            b = labclient.DB.connect(Force=true);
            st = labclient.DB.status();
            if isempty(b)
                obj.say(st.Message, st.State ~= "off");
                return
            end
            msg = st.Message;
            try
                who = b.person();
                s = labclient.Settings.load();
                if strlength(who.PersonId) > 0 && ~ismissing(who.PersonId)
                    s.PersonId = who.PersonId;
                    labclient.Settings.save(s);
                    msg = msg + " You are lab.person " + who.PersonId + ".";
                else
                    msg = msg + " Your login is mapped to no lab.person: ask the " + ...
                        "database administrator, or give your email.";
                end
                obj.markRoots(b);
            catch ME
                msg = msg + " (" + string(ME.message) + ")";
            end
            obj.say(msg, false);
        end

        function T = refreshOutbox(obj)
            %refreshOutbox  Show the outbox: state, captured, what, dataset, note (one row per record).
            T = labclient.Outbox.list();
            T = T(T.state ~= "done" & T.state ~= "discarded", :);
            n = height(T);
            data = cell(n, 5);
            for k = 1:n
                what = T.type(k);
                ds = "";
                try
                    b = labclient.Outbox.read(T.id(k));
                    if b.type == "event"
                        what = b.record.event.event_type;
                        a = jsondecode(char(b.record.event.attributes_json));
                        if isfield(a, "step"); what = what + " " + string(a.step); end
                        ds = b.record.dataset.name;
                    end
                catch
                end
                st = T.state(k);
                if st == "pending" && ~T.sealed(k); st = "hashing"; end
                data(k, :) = {char(st), char(T.captured_at(k)), char(what), char(ds), char(T.note(k))};
            end
            obj.Ctl.Outbox.Data = data;
            obj.OutboxIds = T.id;
            c = labclient.Outbox.counts();
            obj.Ctl.OutboxPanel.Title = sprintf('Outbox: %d to send, %d held, %d failed (%d sent)', ...
                c.pending + c.claimed, c.held, c.failed, c.done);
        end

        function sendNow(obj)
            %sendNow  Send what can be sent now, for up to 30 s (Ctrl+R).
            obj.say("Sending...", false);
            drawnow limitrate
            r = labclient.Sync.flush(Budget=30);
            obj.refreshOutbox();
            msg = sprintf('%d record(s) sent; %d waiting, %d held, %d failed.', r.sent, r.pending, r.held, r.failed);
            if r.message ~= ""; msg = msg + " " + r.message; end
            obj.say(msg, r.failed > 0);
        end

        function retry(obj, ids)
            %retry  Send failed records IDS again.
            obj.moveSelected(ids, "failed", "pending", "retried by " + labclient.Bundles.osUser());
        end

        function hold(obj, ids)
            %hold  Keep pending records IDS from being sent until released.
            obj.moveSelected(ids, "pending", "held", "held by " + labclient.Bundles.osUser());
        end

        function release(obj, ids, opts)
            %release  Let held records IDS be sent; OnBehalf=true sends one captured under another login as yours.
            arguments
                obj
                ids (1,:) string
                opts.OnBehalf (1,1) logical = false
            end
            for id = ids
                [~, st] = labclient.Outbox.read(id);
                if st ~= "held"; continue; end
                n = labclient.Outbox.note(id, "held");
                f = n.flags;
                if opts.OnBehalf; f = unique([f, labclient.Sync.OnBehalf], "stable"); end
                labclient.Outbox.move(id, "pending", Reason="released by " + labclient.Bundles.osUser(), Flags=f);
            end
            obj.refreshOutbox();
            labclient.DB.outboxChanged();
        end

        function discard(obj, ids, opts)
            %discard  Never send records IDS (asks first unless Confirm=false); they are kept, marked discarded.
            arguments
                obj
                ids (1,:) string
                opts.Confirm (1,1) logical = true
                opts.Reason (1,1) string = ""
            end
            if isempty(ids); return; end
            if opts.Confirm
                a = uiconfirm(obj.Fig, sprintf(['Discard %d record(s)? They are never sent to the lab ' ...
                    'database. They stay in the outbox, marked discarded with your name.'], numel(ids)), ...
                    "Discard", "Options", {'Discard', 'Cancel'}, "DefaultOption", 2, "CancelOption", 2, ...
                    "Icon", "warning");
                if a ~= "Discard"; return; end
            end
            why = "discarded by " + labclient.Bundles.osUser() + " on " + labclient.Bundles.host();
            if opts.Reason ~= ""; why = why + ": " + opts.Reason; end
            for id = ids
                [~, st] = labclient.Outbox.read(id);
                if ismember(st, ["pending" "held" "failed"])
                    labclient.Outbox.move(id, "discarded", Reason=why);
                end
            end
            obj.refreshOutbox();
            labclient.DB.outboxChanged();
        end

        function txt = details(obj, id)
            %details  The record ID as it is written, in a window of its own.
            [b, st] = labclient.Outbox.read(id);
            if isempty(b); txt = ""; return; end
            n = labclient.Outbox.note(id, st);
            txt = "State: " + st + newline + "Note: " + n.reason + newline + newline + ...
                string(jsonencode(jsondecode(char(labclient.Bundles.encode(b))), "PrettyPrint", true));
            if obj.Fig.Visible == "on"
                labclient.Panel.showText("Record " + id, split(txt, newline), obj.Fig);
            end
        end

        function assignSubjects(obj)
            %assignSubjects  The subject window for the first folder subject records wait for.
            T = labclient.Sync.subjectHolds();
            if isempty(T)
                obj.say("No record waits for a subject.", false);
                return
            end
            labclient.SubjectAssignDialog.open(Parent=obj.Fig, FolderId=T.folder_id(1));
            obj.refreshOutbox();
        end

        function setPassword(obj)
            %setPassword  Ask for the password with MATLAB's vault dialog (setSecret).
            if ~obj.save()
                return
            end
            s = labclient.Settings.load();
            if strlength(s.Username) == 0 || strlength(s.Server) == 0
                obj.say("Name the server and your login first.", true);
                return
            end
            try
                labclient.Secrets.prompt(s);
                obj.say("Password stored in the MATLAB vault as " + ...
                    labclient.Secrets.secretName(s) + ".", false);
            catch ME
                obj.say(string(ME.message), true);
            end
        end

        function addRoot(obj, name, folder)
            %addRoot  Map storage root NAME to FOLDER on this computer.
            name = strtrim(string(name));
            folder = strtrim(string(folder));
            if name == "" || folder == ""
                obj.say("Give the root's name and pick its folder.", true);
                return
            end
            if ~isfolder(folder)
                obj.say("There is no folder " + folder + ".", true);
                return
            end
            if any(string({obj.Roots.Name}) == name)
                obj.say("Storage root " + name + " is mapped already: remove it first.", true);
                return
            end
            probe = struct("Roots", struct("Name", name, "Path", folder));
            [ok, why] = labclient.Roots.checkMarker(name, probe);
            if ~ok
                obj.say(why, true);
                return
            end
            obj.Roots(end+1) = struct("Name", name, "Path", folder);
            obj.showRoots();
            obj.say("Mapped " + name + " to " + folder + " (not saved yet).", false);
        end

        function removeRoot(obj, name)
            %removeRoot  Forget the mapping of storage root NAME (the database is not changed).
            obj.Roots = obj.Roots(string({obj.Roots.Name}) ~= string(name));
            obj.showRoots();
        end

        function registerRoot(obj, name)
            %registerRoot  Add storage root NAME (mapped here) to the database, and mark its folder.
            name = string(name);
            k = find(string({obj.Roots.Name}) == name, 1);
            if isempty(k)
                obj.say("Map " + name + " to a folder first.", true);
                return
            end
            b = labclient.DB.connect(Force=true);
            if isempty(b)
                obj.say("Not connected: " + labclient.DB.status().Message, true);
                return
            end
            try
                R = b.storageRoots();
                hit = string(R.name) == name;
                if any(hit)
                    id = double(R.root_id(find(hit, 1)));
                else
                    id = b.addStorageRoot(name, "Registered from " + string(getenv("COMPUTERNAME")) + ...
                        " for " + obj.Roots(k).Path);
                end
                labclient.Roots.writeMarker(obj.Roots(k).Path, name, id);
                obj.say("Storage root " + name + " is lab.storage_root " + string(id) + ...
                    "; its folder is marked.", false);
                obj.markRoots(b);
            catch ME
                obj.say(string(ME.message), true);
            end
        end

        function close(obj)
            if ~isempty(obj.Fig) && isvalid(obj.Fig)
                delete(obj.Fig);
            end
        end

        function delete(obj)
            if ~isempty(obj.Listener) && isvalid(obj.Listener)
                delete(obj.Listener);
            end
            if ~isempty(obj.OutboxListener) && isvalid(obj.OutboxListener)
                delete(obj.OutboxListener);
            end
        end
    end

    methods (Access = private)
        function obj = Panel(parent, visible)
            s = labclient.Settings.load();
            obj.Roots = s.Roots;
            pos = [100 100 760 760];
            if ~isempty(parent) && isvalid(parent)
                pp = parent.Position;
                pos(1:2) = pp(1:2) + max(0, (pp(3:4) - pos(3:4)) / 2);
            end
            f = uifigure("Name", "Lab database", "Position", pos, "Visible", "off", ...
                "Tag", "LabClientPanel", "KeyPressFcn", @(~, e) obj.onKey(e));
            obj.Fig = f;
            g = uigridlayout(f, [5 1]);
            g.RowHeight = {'fit', 'fit', '1x', '1.3x', 'fit'};
            g.Padding = [12 12 12 12];

            % settings
            form = uigridlayout(g, [4 4]);
            form.ColumnWidth = {130, '1x', 110, '1x'};
            form.RowHeight = repmat({24}, 1, 4);
            c = struct();
            c.Enabled = uicheckbox(form, "Text", "Use the lab database on this computer", ...
                "Value", s.Enabled);
            c.Enabled.Layout.Column = [1 4];
            uilabel(form, "Text", "Server");
            c.Server = uieditfield(form, "text", "Value", char(s.Server), ...
                "Placeholder", "e.g. labdb.example.edu");
            uilabel(form, "Text", "Port");
            c.Port = uieditfield(form, "numeric", "Value", s.Port, "Limits", [1 65535], ...
                "RoundFractionalValues", "on", "ValueDisplayFormat", "%d");
            uilabel(form, "Text", "Database");
            c.Database = uieditfield(form, "text", "Value", char(s.DatabaseName));
            uilabel(form, "Text", "Your login");
            c.Username = uieditfield(form, "text", "Value", char(s.Username), ...
                "Tooltip", "Your own database login: never a shared one");
            uilabel(form, "Text", "Your email (optional)");
            c.PersonEmail = uieditfield(form, "text", "Value", char(s.PersonEmail), ...
                "Tooltip", "Only when your login is not mapped to you in the database");
            uilabel(form, "Text", "Lab time zone");
            c.TimeZone = uieditfield(form, "text", "Value", char(s.LabTimeZone), ...
                "Tooltip", "Times written without a zone (old files, rig clocks) are read in this zone");

            buttons = uigridlayout(g, [1 5]);
            buttons.ColumnWidth = {'fit', 'fit', 'fit', '1x', 'fit'};
            buttons.Padding = [0 0 0 0];
            uibutton(buttons, "Text", "Set password...", "Tooltip", ...
                "Store your password in the MATLAB vault (it is never shown or saved here)", ...
                "ButtonPushedFcn", @(~, ~) obj.setPassword());
            uibutton(buttons, "Text", "Test connection", "Tooltip", "Save and connect now (F5)", ...
                "ButtonPushedFcn", @(~, ~) obj.testConnection());
            uibutton(buttons, "Text", "Save", "Tooltip", "Save the settings (Ctrl+S)", ...
                "ButtonPushedFcn", @(~, ~) obj.save());
            c.State = uilabel(buttons, "Text", "", "FontWeight", "bold");
            uibutton(buttons, "Text", "Close", "Tooltip", "Close (Esc)", ...
                "ButtonPushedFcn", @(~, ~) obj.close());

            % storage roots
            rp = uipanel(g, "Title", "Storage roots on this computer");
            rg = uigridlayout(rp, [2 5]);
            rg.RowHeight = {'1x', 26};
            rg.ColumnWidth = {'1x', 140, 'fit', 'fit', 'fit'};
            c.Roots = uitable(rg, "ColumnName", {'Root', 'Folder here', 'Marker'}, ...
                "ColumnWidth", {150, 'auto', 220}, "RowName", {});
            c.Roots.Layout.Column = [1 5];
            c.RootFolder = uieditfield(rg, "text", "Placeholder", "folder (Browse...)");
            c.RootName = uieditfield(rg, "text", "Placeholder", "root name, e.g. nas-main");
            uibutton(rg, "Text", "Browse...", "ButtonPushedFcn", @(~, ~) obj.browse());
            uibutton(rg, "Text", "Add", "ButtonPushedFcn", @(~, ~) ...
                obj.addRoot(c.RootName.Value, c.RootFolder.Value));
            uibutton(rg, "Text", "Remove / Register...", "Tooltip", ...
                "Remove the selected mapping, or register the selected root in the database", ...
                "ButtonPushedFcn", @(~, ~) obj.rootAction());

            % the outbox
            c.OutboxPanel = uipanel(g, "Title", "Outbox");
            og = uigridlayout(c.OutboxPanel, [2 8]);
            og.RowHeight = {'1x', 26};
            og.ColumnWidth = {'fit', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit', '1x'};
            c.Outbox = uitable(og, "ColumnName", {'State', 'Captured', 'What', 'Dataset', 'Note'}, ...
                "ColumnWidth", {70, 170, 130, 150, 'auto'}, "RowName", {}, "SelectionType", "row", ...
                "Multiselect", "on");
            c.Outbox.Layout.Column = [1 8];
            uibutton(og, "Text", "Send now", "Tooltip", "Send what can be sent now (Ctrl+R)", ...
                "ButtonPushedFcn", @(~, ~) obj.sendNow());
            uibutton(og, "Text", "Retry", "Tooltip", "Send the selected failed records again", ...
                "ButtonPushedFcn", @(~, ~) obj.retry(obj.selectedIds()));
            uibutton(og, "Text", "Hold", "Tooltip", "Keep the selected records from being sent", ...
                "ButtonPushedFcn", @(~, ~) obj.hold(obj.selectedIds()));
            uibutton(og, "Text", "Release", "Tooltip", "Let the selected held records be sent", ...
                "ButtonPushedFcn", @(~, ~) obj.release(obj.selectedIds()));
            uibutton(og, "Text", "Send as me", "Tooltip", ...
                "Send the selected records captured under another login as yours (the database stamps your login)", ...
                "ButtonPushedFcn", @(~, ~) obj.release(obj.selectedIds(), OnBehalf=true));
            uibutton(og, "Text", "Discard...", "Tooltip", "Never send the selected records (asks first)", ...
                "ButtonPushedFcn", @(~, ~) obj.discard(obj.selectedIds()));
            uibutton(og, "Text", "Details", "Tooltip", "The selected record as it is written", ...
                "ButtonPushedFcn", @(~, ~) obj.detailsOfSelected());
            uibutton(og, "Text", "Assign subjects...", "Tooltip", ...
                "Create the subjects records wait for, or assign their sessions to existing ones", ...
                "ButtonPushedFcn", @(~, ~) obj.assignSubjects());

            c.Message = uilabel(g, "Text", "", "WordWrap", "on");
            obj.Ctl = c;
            obj.showRoots();
            obj.showState();
            obj.refreshOutbox();
            obj.Listener = listener(labclient.DB.instance(), "StateChanged", @(~, ~) obj.showState());
            obj.OutboxListener = listener(labclient.DB.instance(), "OutboxChanged", @(~, ~) obj.refreshOutboxIfOpen());
            addlistener(f, "ObjectBeingDestroyed", @(~, ~) obj.delete());
            if visible
                f.Visible = "on";
            end
        end

        function onKey(obj, e)
            mods = string(e.Modifier);
            ctrl = any(mods == "control") || any(mods == "command");
            key = string(e.Key);
            if ctrl && (ismember(key, ["slash", "questionmark"]) || string(e.Character) == "?")
                uialert(obj.Fig, sprintf(['Ctrl+S   Save the settings\n' ...
                    'F5       Test the connection (saves first)\n' ...
                    'Ctrl+R   Send what waits in the outbox now\n' ...
                    'Esc      Close (also Ctrl+W)\n' ...
                    'Ctrl+?   This list']), "Keyboard shortcuts", "Icon", "info");
            elseif ctrl && key == "s"
                obj.save();
            elseif ctrl && key == "r"
                obj.sendNow();
            elseif key == "f5"
                obj.testConnection();
            elseif key == "escape" || (ctrl && key == "w")
                obj.close();
            end
        end

        function ids = selectedIds(obj)
            sel = obj.Ctl.Outbox.Selection;
            ids = strings(1, 0);
            if isempty(sel); obj.say("Select records in the outbox first.", true); return; end
            rows = unique(sel(:, 1)).';
            rows = rows(rows <= numel(obj.OutboxIds));
            ids = reshape(obj.OutboxIds(rows), 1, []);
        end

        function detailsOfSelected(obj)
            ids = obj.selectedIds();
            if ~isempty(ids); obj.details(ids(1)); end
        end

        function moveSelected(obj, ids, from, to, reason)
            for id = reshape(string(ids), 1, [])
                [~, st] = labclient.Outbox.read(id);
                if st == from; labclient.Outbox.move(id, to, Reason=reason); end
            end
            obj.refreshOutbox();
            labclient.DB.outboxChanged();
        end

        function refreshOutboxIfOpen(obj)
            if ~isempty(obj.Fig) && isvalid(obj.Fig)
                obj.refreshOutbox();
            end
        end

        function browse(obj)
            d = uigetdir("", "The folder the storage root is on this computer");
            figure(obj.Fig);
            if ischar(d)
                obj.Ctl.RootFolder.Value = d;
            end
        end

        function rootAction(obj)
            sel = obj.Ctl.Roots.Selection;
            if isempty(sel)
                obj.say("Select a root in the table first.", true);
                return
            end
            name = obj.Roots(sel(1)).Name;
            answer = uiconfirm(obj.Fig, "Storage root " + name + ": remove its mapping on this " + ...
                "computer, or register it in the lab database (and mark its folder)?", ...
                "Storage root", "Options", {'Register', 'Remove mapping', 'Cancel'}, ...
                "DefaultOption", 3, "CancelOption", 3);
            switch answer
                case "Register"
                    obj.registerRoot(name);
                case "Remove mapping"
                    obj.removeRoot(name);
            end
        end

        function showRoots(obj, inDb)
            if nargin < 2
                inDb = strings(0, 1);
            end
            n = numel(obj.Roots);
            data = cell(n, 3);
            for k = 1:n
                data{k, 1} = char(obj.Roots(k).Name);
                data{k, 2} = char(obj.Roots(k).Path);
                [ok, why] = labclient.Roots.checkMarker(obj.Roots(k).Name, struct("Roots", obj.Roots(k)));
                if ~ok
                    data{k, 3} = char("refused: " + why);
                elseif isfile(fullfile(obj.Roots(k).Path, labclient.Roots.MarkerFile))
                    data{k, 3} = 'marked';
                elseif ~isempty(inDb) && ~any(inDb == obj.Roots(k).Name)
                    data{k, 3} = 'not in the database';
                else
                    data{k, 3} = 'no marker yet';
                end
            end
            obj.Ctl.Roots.Data = data;
        end

        function markRoots(obj, b)
            R = b.storageRoots();
            obj.showRoots(string(R.name));
        end

        function showState(obj)
            if isempty(obj.Fig) || ~isvalid(obj.Fig)
                return
            end
            st = labclient.DB.status();
            [label, color] = labclient.Lamp.look(st.State);
            obj.Ctl.State.Text = "Database: " + label;
            obj.Ctl.State.FontColor = color;
            obj.Ctl.State.Tooltip = char(st.Message);
        end

        function say(obj, text, isError)
            if isempty(obj.Fig) || ~isvalid(obj.Fig)
                return
            end
            obj.Ctl.Message.Text = char(text);
            if isError
                obj.Ctl.Message.FontColor = [0.75 0.10 0.10];
            else
                obj.Ctl.Message.FontColor = [0.15 0.15 0.15];
            end
        end
    end
end
