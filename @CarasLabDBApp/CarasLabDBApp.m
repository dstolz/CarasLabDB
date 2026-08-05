classdef CarasLabDBApp < handle
%CARASLABDBAPP Interactive GUI for browsing and editing the CarasLabDB database.
%
%   CarasLabDBApp is a uifigure-based front end over the CarasLabDB class. It
%   lets you search and browse subjects, sessions, events and artifacts; add
%   and correct events; add/edit subjects and sessions; export any filtered
%   table to the base workspace; and run vetted read-only custom SQL with
%   history recall. Window geometry, connection (minus password), the active
%   view toggle, and SQL history persist between sessions.
%
%   Because the lab schema is append-only, "editing" an event creates a
%   *superseding correction* (the original is retained and hidden by the
%   *_active views). Subjects and sessions are mutable dimensions and are
%   edited in place.
%
%   Launch:
%       app = CarasLabDBApp();          % opens a login dialog
%       app = CarasLabDBApp(db);        % reuse an open CarasLabDB handle
%
%   Requires MATLAB R2025a or later and the Database Toolbox.
%
%   See also CARASLABDB.

    properties (SetAccess = private)
        Db                          % CarasLabDB handle (may be empty until connected)
        Fig                         % main uifigure
    end

    properties (Access = private)
        UI      struct = struct()   % component handles
        Prefs   struct = struct()   % live preferences (persisted on close)
        OwnsDb  (1,1) logical = false   % delete Db on close only if we opened it
        TabKeys string = strings(1,0)   % ordered browse-tab keys
    end

    properties (Constant, Access = private)
        PrefGroup = "CarasLabDBApp"
        NumFilterRows = 4
        RowLimit = 5000             % safety cap on browse queries
    end

    % ------------------------------------------------------------------
    % Externally-defined methods (see @CarasLabDBApp/<name>.m)
    % ------------------------------------------------------------------
    methods (Access = public)
        buildUI(obj)
        refreshActiveTab(obj)
        applyFilters(obj)
        exportToWorkspace(obj)
        showEventEditor(obj, mode, eventType, eventId)
        showSubjectEditor(obj, mode, subjectId)
        showSessionEditor(obj, mode, sessionId)
        runCustomSQL(obj)
    end

    methods (Access = private)
        db = loginDialog(obj)
        loadPrefs(obj)
        savePrefs(obj)
        w = buildWhere(obj, tabDef, rows, quickText, quickRegex)
    end

    methods (Static, Access = private)
        out = pFormDialog(titleText, specs)
    end

    methods (Static)
        specs = eventFieldSpecs(eventType)
        showShortcutHelp(fig, context)
    end

    % ==================================================================
    % Construction / lifecycle
    % ==================================================================
    methods
        function obj = CarasLabDBApp(db)
            %CARASLABDBAPP Construct the app, optionally reusing an open CarasLabDB.
            arguments
                db = []
            end

            obj.loadPrefs();

            if ~isempty(db)
                if ~isa(db, "CarasLabDB")
                    error("CarasLabDBApp:badArg", ...
                        "Input must be a CarasLabDB handle.");
                end
                obj.Db = db;
                obj.OwnsDb = false;
            else
                obj.Db = obj.loginDialog();
                if isempty(obj.Db)
                    error("CarasLabDBApp:cancelled", "Connection cancelled.");
                end
                obj.OwnsDb = true;
            end

            obj.buildUI();
            obj.refreshActiveTab();
        end

        function delete(obj)
            %DELETE Persist preferences, close window, close owned connection.
            try
                obj.savePrefs();
            catch
            end
            if ~isempty(obj.Fig) && isvalid(obj.Fig)
                delete(obj.Fig);
            end
            if obj.OwnsDb && ~isempty(obj.Db) && isvalid(obj.Db)
                delete(obj.Db);
            end
        end
    end

    % ==================================================================
    % Browse-tab definitions (single source of truth for columns / typing)
    % ==================================================================
    methods (Access = ?CarasLabDBApp)
        function defs = pTabDefs(~)
            %PTABDEFS Struct array describing each browse tab.
            %   Fields: Key, Title, Table (base), ActiveTable ("" if none),
            %   Columns, DateCols, NumCols, HasSubject, OrderBy, Entity
            %   (subject|session|event|artifact for editor dispatch).
            defs = struct( ...
                "Key", {}, "Title", {}, "Table", {}, "ActiveTable", {}, ...
                "Columns", {}, "DateCols", {}, "NumCols", {}, ...
                "HasSubject", {}, "OrderBy", {}, "Entity", {});

            defs(end+1) = struct( ...
                "Key", "subjects", "Title", "Subjects", ...
                "Table", "subject", "ActiveTable", "", ...
                "Columns", ["subject_id","project_id","species_code","sex","strain", ...
                            "genotype","source","date_of_birth","notes","created_at"], ...
                "DateCols", ["date_of_birth","created_at"], "NumCols", strings(1,0), ...
                "HasSubject", true, "OrderBy", "subject_id", "Entity", "subject");

            defs(end+1) = struct( ...
                "Key", "sessions", "Title", "Sessions", ...
                "Table", "session", "ActiveTable", "", ...
                "Columns", ["session_id","subject_id","label","storage_root_id", ...
                            "relative_path","started_at","ended_at","rig","notes","created_at"], ...
                "DateCols", ["started_at","ended_at","created_at"], ...
                "NumCols", "storage_root_id", ...
                "HasSubject", true, "OrderBy", "started_at DESC", "Entity", "session");

            defs(end+1) = struct( ...
                "Key", "events", "Title", "Events", ...
                "Table", "event", "ActiveTable", "event_active", ...
                "Columns", ["event_id","event_type","subject_id","session_id", ...
                            "occurred_at","recorded_at","recorded_by","supersedes","notes"], ...
                "DateCols", ["occurred_at","recorded_at"], "NumCols", strings(1,0), ...
                "HasSubject", true, "OrderBy", "occurred_at DESC", "Entity", "event");

            defs(end+1) = struct( ...
                "Key", "artifacts", "Title", "Artifacts", ...
                "Table", "artifact", "ActiveTable", "artifact_active", ...
                "Columns", ["artifact_id","produced_by_event_id","storage_root_id", ...
                            "relative_path","checksum","checksum_algo","size_bytes", ...
                            "role","format","subject_id","session_id","supersedes","created_at"], ...
                "DateCols", "created_at", "NumCols", ["storage_root_id","size_bytes"], ...
                "HasSubject", true, "OrderBy", "created_at DESC", "Entity", "artifact");
        end

        function d = pCurrentTabDef(obj)
            %PCURRENTTABDEF Definition for the currently selected browse tab, or [].
            defs = obj.pTabDefs();
            sel = obj.UI.TabGroup.SelectedTab;
            key = string(sel.Tag);
            idx = find(strcmp([defs.Key], key), 1);
            if isempty(idx)
                d = [];
            else
                d = defs(idx);
            end
        end

        function pStatus(obj, msg)
            %PSTATUS Update the status bar text.
            if isfield(obj.UI, "Status") && isvalid(obj.UI.Status)
                obj.UI.Status.Text = string(msg);
            end
        end

        function tf = pActiveOnly(obj)
            %PACTIVEONLY Current state of the active-only toggle.
            tf = obj.UI.ActiveOnly.Value;
        end

        function ref = pQualify(obj, tableName)
            %PQUALIFY Schema-qualified table reference, e.g. "lab.subject".
            ref = obj.Db.Schema + "." + string(tableName);
        end
    end

    % ==================================================================
    % Toolbar / widget callbacks (small; heavy logic lives in file methods)
    % ==================================================================
    methods (Access = ?CarasLabDBApp)
        function onRefresh(obj, ~, ~)
            obj.refreshActiveTab();
        end

        function onKeyPress(obj, ~, evt)
            %ONKEYPRESS Keyboard shortcuts mirroring the toolbar/filter buttons.
            %   Ctrl+R Refresh · Ctrl+E Export→WS · Ctrl+Shift+E Add Event ·
            %   Ctrl+Shift+S Add Subject · Ctrl+Shift+N Add Session ·
            %   Ctrl+D Edit/Supersede · Enter Apply filters (browse tabs) ·
            %   Ctrl+Enter Run (Custom SQL tab) · Escape Clear filters ·
            %   Ctrl+? Shortcut list.
            mods  = string(evt.Modifier);
            ctrl  = any(mods == "control") || any(mods == "command");
            shift = any(mods == "shift");
            key   = string(evt.Key);

            sel = obj.UI.TabGroup.SelectedTab;
            onSqlTab = ~isempty(sel) && string(sel.Tag) == "sql";

            % "?" is Shift+/, and which of these the event reports varies by
            % keyboard layout, so accept every spelling.
            if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                    string(evt.Character) == "?")
                CarasLabDBApp.showShortcutHelp(obj.Fig, "main");
            elseif key == "return" && ctrl
                if onSqlTab, obj.runCustomSQL(); end
            elseif key == "return"
                if ~onSqlTab, obj.onRefresh(); end
            elseif key == "escape"
                obj.onClearFilters();
            elseif key == "e" && ctrl && shift
                obj.onAddMenu("event");
            elseif key == "s" && ctrl && shift
                obj.onAddMenu("subject");
            elseif key == "n" && ctrl && shift
                obj.onAddMenu("session");
            elseif key == "e" && ctrl
                obj.onExport();
            elseif key == "d" && ctrl
                obj.onEditSelected();
            elseif key == "r" && ctrl
                obj.onRefresh();
            end
        end

        function onTabChanged(obj, ~, ~)
            obj.pPopulateFilterColumns();
            obj.refreshActiveTab();
        end

        function onAddMenu(obj, entity)
            switch entity
                case "event",   obj.showEventEditor("add", "", "");
                case "subject", obj.showSubjectEditor("add", "");
                case "session", obj.showSessionEditor("add", "");
            end
        end

        function onEditSelected(obj, ~, ~)
            d = obj.pCurrentTabDef();
            if isempty(d)
                uialert(obj.Fig, "Editing is not available on this tab.", "Edit");
                return
            end
            id = obj.pSelectedId(d);
            if ismissing(id)
                uialert(obj.Fig, "Select a row first.", "Edit");
                return
            end
            switch d.Entity
                case "event",   obj.showEventEditor("supersede", "", id);
                case "subject", obj.showSubjectEditor("edit", id);
                case "session", obj.showSessionEditor("edit", id);
                otherwise
                    uialert(obj.Fig, "This entity is read-only in the GUI.", "Edit");
            end
        end

        function id = pSelectedId(obj, d)
            %PSELECTEDID Primary-key value of the selected row on tab D, or <missing>.
            id = string(missing);
            t = obj.UI.Tables.(d.Key);
            sel = t.Selection;
            if isempty(sel) || isempty(t.Data)
                return
            end
            r = sel(1);
            % Selection indexes the displayed (possibly sorted) order, so read
            % from DisplayData when available to stay aligned after a sort.
            data = t.Data;
            try
                if ~isempty(t.DisplayData)
                    data = t.DisplayData;
                end
            catch
            end
            idCol = d.Columns(1);          % PK is always the first column
            if ismember(idCol, string(data.Properties.VariableNames)) && r <= height(data)
                id = string(data.(char(idCol))(r));
            end
        end

        function onExport(obj, ~, ~)
            obj.exportToWorkspace();
        end

        function pRecallSql(obj, src, ~)
            %PRECALLSQL Load a history entry into the SQL editor.
            v = string(src.Value);
            if v == "(history)" || strlength(v) == 0
                return
            end
            obj.UI.SqlEditor.Value = cellstr(splitlines(v));
            src.Value = "(history)";   % reset the picker
        end

        function pRefreshSqlHistory(obj)
            %PREFRESHSQLHISTORY Rebuild the recall dropdown from prefs.
            items = ["(history)"; obj.Prefs.SqlHistory(:)];
            obj.UI.SqlHistory.Items = cellstr(items);
            obj.UI.SqlHistory.Value = "(history)";
        end

        function pOnClose(obj, ~, ~)
            %PONCLOSE Window close request -> tidy up via delete().
            delete(obj);
        end
    end

    % ==================================================================
    % Filter-panel helpers (shared across browse tabs)
    % ==================================================================
    methods (Access = ?CarasLabDBApp)
        function pPopulateFilterColumns(obj)
            %PPOPULATEFILTERCOLUMNS Refresh the per-row column dropdowns for the tab.
            d = obj.pCurrentTabDef();
            if isempty(d)
                % The Custom SQL tab has no browse columns. Blanking the
                % dropdowns here would orphan the filter values the user has
                % typed — they stay visible but stop being applied — so leave
                % the browse filters exactly as they are.
                return
            end
            items = ["(none)", d.Columns];
            for i = 1:obj.NumFilterRows
                w = obj.UI.Filter(i);
                prev = string(w.Col.Value);
                w.Col.Items = cellstr(items);
                if ismember(prev, items)
                    w.Col.Value = char(prev);
                else
                    w.Col.Value = '(none)';
                end
            end
        end

        function rows = pReadFilterRows(obj)
            %PREADFILTERROWS Collect the non-empty filter rows as a struct array.
            rows = struct("Col", {}, "Mode", {}, "Val", {}, "Val2", {});
            for i = 1:obj.NumFilterRows
                w = obj.UI.Filter(i);
                col = string(w.Col.Value);
                if col == "(none)" || col == ""
                    continue
                end
                rows(end+1) = struct( ...
                    "Col", col, "Mode", string(w.Mode.Value), ...
                    "Val", string(w.Val.Value), "Val2", string(w.Val2.Value)); %#ok<AGROW>
            end
        end

        function onClearFilters(obj, ~, ~)
            for i = 1:obj.NumFilterRows
                w = obj.UI.Filter(i);
                w.Col.Value = '(none)';
                w.Mode.Value = 'Exact';
                w.Val.Value = '';
                w.Val2.Value = '';
            end
            obj.UI.QuickSearch.Value = '';
            obj.refreshActiveTab();
        end
    end
end
