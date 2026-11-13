classdef CarasLabDBApp < handle
%CARASLABDBAPP Interactive GUI for browsing and editing the CarasLabDB database.
%
%   CarasLabDBApp is a uifigure-based front end over the CarasLabDB class. It
%   lets you search and browse subjects, sessions, events and artifacts
%   (including by tag: stage:raw -qc:fail topic:*); add and correct events;
%   add/edit subjects and sessions; view and edit the tags (Ctrl+T) and the
%   user-defined variables (Ctrl+L) of any row; retract an event or artifact
%   that should never have been recorded (Ctrl+Delete); enter the day's
%   weights and water for all animals at once (Ctrl+H); show the database's
%   integrity report (Ctrl+I); export any filtered table to the base
%   workspace; and run vetted read-only custom SQL with history recall.
%   Window geometry, connection (minus password), the active view toggle,
%   and SQL history persist between sessions.
%
%   Because the lab schema is append-only, "editing" an event creates a
%   *superseding correction* (the original is retained and hidden by the
%   *_active views). Subjects and sessions are mutable dimensions and are
%   edited in place. Every edit and correction first shows what will change
%   (old value and new value) and writes nothing until that is confirmed.
%
%   Launch:
%       app = CarasLabDBApp();          % opens a login dialog
%       app = CarasLabDBApp(db);        % reuse an open CarasLabDB handle
%
%   Requires MATLAB R2024b or later and the Database Toolbox.
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
        DisplaySel struct = struct()    % per tab: DisplaySelection of the last selection event
        Capped  struct = struct()       % per tab: true when the last query hit RowLimit
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
        showTagEditor(obj, kind, entityId)
        showVariableEditor(obj, kind, entityId)
        showRetractDialog(obj, kind, entityId)
        showHusbandryEntry(obj)
        showIntegrityReport(obj)
        runCustomSQL(obj)
    end

    methods (Access = private)
        db = loginDialog(obj)
        loadPrefs(obj)
        savePrefs(obj)
        w = buildWhere(obj, tabDef, rows, quickText, quickRegex, tagText)
    end

    methods (Static, Access = private)
        out = pFormDialog(titleText, specs, headerText, acceptFcn)
    end

    methods (Static)
        specs = eventFieldSpecs(eventType)
        showShortcutHelp(fig, context)
        [action, v] = fieldChange(f, raw, isEdit, opts)
        [v, err] = parseNumber(txt)
        s = formatValue(v)
        tf = confirmChanges(fig, what, changes, note)
        s = describeRow(db, kind, entityId)
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
            try
                % The integrity report is the one window that is not modal,
                % so it can outlive the main window; it would then hold a
                % closed connection.
                delete(findall(groot, "Type", "figure", "Tag", "CarasLabDBApp:integrity"));
            catch
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
            %   Fields: Key, Title, Table (full history), ActiveTable ("" if
            %   none), Columns, DateCols, NumCols, HasSubject, OrderBy, Entity
            %   (subject|session|event|artifact for editor dispatch).
            %
            %   Full history of events and artifacts is read from the
            %   event_version / artifact_version views, which add
            %   superseded_by, is_current and is_retracted to every row, so a
            %   superseded or retracted row cannot be mistaken for a current
            %   one. Columns lists the columns offered in the filter
            %   dropdowns; it holds only columns that both views of a tab
            %   have.
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
                "Table", "event_version", "ActiveTable", "event_active", ...
                "Columns", ["event_id","event_type","subject_id","session_id", ...
                            "occurred_at","recorded_at","recorded_by","recorded_login", ...
                            "supersedes","notes"], ...
                "DateCols", ["occurred_at","recorded_at"], "NumCols", strings(1,0), ...
                "HasSubject", true, "OrderBy", "occurred_at DESC", "Entity", "event");

            defs(end+1) = struct( ...
                "Key", "artifacts", "Title", "Artifacts", ...
                "Table", "artifact_version", "ActiveTable", "artifact_active", ...
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
            %   Ctrl+D Edit/Supersede · Ctrl+T Tags, Ctrl+L Variables and
            %   Ctrl+Delete Retract for the selected row ·
            %   Ctrl+H Daily husbandry · Ctrl+I Integrity report ·
            %   Enter Apply filters (browse tabs) ·
            %   Ctrl+Enter Run (Custom SQL tab) · Escape Clear filters ·
            %   Ctrl+? Shortcut list. Keep CarasLabDBApp.showShortcutHelp
            %   ("main") in step with this list.
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
            elseif key == "t" && ctrl
                obj.onEditTags();
            elseif key == "l" && ctrl
                obj.onEditVariables();
            elseif key == "delete" && ctrl
                obj.onRetract();
            elseif key == "h" && ctrl
                obj.onHusbandry();
            elseif key == "i" && ctrl
                obj.onIntegrity();
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
            %ONEDITSELECTED Edit (subject, session) or supersede (event) the selected row.
            [d, id] = obj.pRequireSelection("Edit", "Editing is not available on this tab.");
            if ismissing(id)
                return
            end
            switch d.Entity
                case "event",   obj.showEventEditor("supersede", "", id);
                case "subject", obj.showSubjectEditor("edit", id);
                case "session", obj.showSessionEditor("edit", id);
                otherwise
                    uialert(obj.Fig, "Artifacts cannot be edited here. To withdraw one " + ...
                        "that should not have been registered, use Retract (Ctrl+Delete).", "Edit");
            end
        end

        function onEditTags(obj, ~, ~)
            %ONEDITTAGS Open the tag editor for the selected row (Ctrl+T).
            [d, id] = obj.pRequireSelection("Tags", "Tags are edited on the browse tabs.");
            if ismissing(id)
                return
            end
            obj.showTagEditor(d.Entity, id);
        end

        function onEditVariables(obj, ~, ~)
            %ONEDITVARIABLES Open the variables editor for the selected row (Ctrl+L).
            [d, id] = obj.pRequireSelection("Variables", ...
                "Variables are edited on the browse tabs.");
            if ismissing(id)
                return
            end
            obj.showVariableEditor(d.Entity, id);
        end

        function onRetract(obj, ~, ~)
            %ONRETRACT Retract the selected event or artifact (Ctrl+Delete).
            %   Only events and artifacts can be retracted; the dialog asks
            %   for the reason and writes nothing until it is confirmed.
            d = obj.pCurrentTabDef();
            if isempty(d) || ~ismember(d.Entity, ["event", "artifact"])
                uialert(obj.Fig, "Only events and artifacts can be retracted: select a " + ...
                    "row on the Events or Artifacts tab. Subjects and sessions are " + ...
                    "edited in place.", "Retract");
                return
            end
            [d, id] = obj.pRequireSelection("Retract", "Select a row first.");
            if ismissing(id)
                return
            end
            obj.showRetractDialog(d.Entity, id);
        end

        function onHusbandry(obj, ~, ~)
            %ONHUSBANDRY Open the daily husbandry entry table (Ctrl+H).
            obj.showHusbandryEntry();
        end

        function onIntegrity(obj, ~, ~)
            %ONINTEGRITY Show the database integrity report (Ctrl+I).
            obj.showIntegrityReport();
        end

        function [d, id] = pRequireSelection(obj, alertTitle, noTabMessage)
            %PREQUIRESELECTION The browse tab and the id of its selected row, or an alert.
            %   [d, id] = pRequireSelection(obj, alertTitle, noTabMessage).
            %   ID is <missing> when there is nothing to act on, and the user
            %   has then been told why in an alert titled ALERTTITLE: this is
            %   not a browse tab (NOTABMESSAGE), no row is selected, or the
            %   selected row could not be identified (see PSELECTEDID). D is
            %   the tab definition ([] off the browse tabs).
            id = string(missing);
            d = obj.pCurrentTabDef();
            if isempty(d)
                uialert(obj.Fig, noTabMessage, alertTitle);
                return
            end
            [id, problem] = obj.pSelectedId(d);
            if ismissing(id)
                if strlength(problem) == 0
                    problem = "Select a row first.";
                end
                uialert(obj.Fig, problem, alertTitle);
            end
        end

        function onTableSelection(obj, key, evt)
            %ONTABLESELECTION Remember where a selection sits in the sorted display.
            %   SelectionChangedFcn of the browse tables. The event's
            %   DisplaySelection (the selection as displayed, after a column
            %   sort) is kept per tab so PSELECTEDID can cross-check the row
            %   it is about to act on. [] when the event carries none.
            ds = [];
            try
                if (isstruct(evt) && isfield(evt, "DisplaySelection")) ...
                        || (isobject(evt) && isprop(evt, "DisplaySelection"))
                    ds = evt.DisplaySelection;
                end
            catch
                ds = [];
            end
            obj.DisplaySel.(char(key)) = ds;
        end

        function [id, problem] = pSelectedId(obj, d)
            %PSELECTEDID Primary-key value of the selected row on tab D, or <missing>.
            %   [id, problem] = pSelectedId(obj, d). ID is <missing> when no
            %   row is selected (PROBLEM "") or when the selected row cannot
            %   be identified with certainty (PROBLEM says why, for an alert).
            %
            %   An edit, a correction or a tag must never land on a guessed
            %   row. While the table is unsorted, the Selection index and the
            %   Data row are the same thing. Once the user has sorted a
            %   column, the id read from Data at Selection is accepted only if
            %   the id read from DisplayData at the DisplaySelection of the
            %   last selection event is the same row; otherwise nothing is
            %   returned and the caller tells the user.
            id = string(missing);
            problem = "";
            t = obj.UI.Tables.(d.Key);
            sel = t.Selection;
            if isempty(sel) || isempty(t.Data)
                return
            end
            r = sel(1);
            data = t.Data;
            idCol = char(d.Columns(1));          % PK is always the first column
            if ~istable(data) || ~ismember(idCol, data.Properties.VariableNames) ...
                    || r < 1 || r > height(data)
                return
            end
            idData = string(data.(idCol)(r));

            shown = [];
            try
                shown = t.DisplayData;
            catch
            end
            sorted = false;
            if istable(shown) && height(shown) > 0 ...
                    && ismember(idCol, shown.Properties.VariableNames)
                sorted = ~isequal(reshape(string(shown.(idCol)), [], 1), ...
                                  reshape(string(data.(idCol)), [], 1));
            end
            if ~sorted
                id = idData;
                return
            end

            ds = [];
            if isfield(obj.DisplaySel, char(d.Key))
                ds = obj.DisplaySel.(char(d.Key));
            end
            if ~isempty(ds) && isnumeric(ds) && ds(1) >= 1 && ds(1) <= height(shown)
                idDisp = string(shown.(idCol)(ds(1)));
                if isscalar(idDisp) && isscalar(idData) && ~ismissing(idData) ...
                        && idDisp == idData
                    id = idData;
                    return
                end
            end
            problem = "The selected row could not be identified with certainty " + ...
                "while the table is sorted, so nothing was opened. Click the row " + ...
                "again; if this message comes back, press Refresh (Ctrl+R) to " + ...
                "clear the sort and select the row in the unsorted table.";
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
            obj.UI.TagFilter.Value = '';
            obj.refreshActiveTab();
        end
    end
end
