function showScanDirectoriesDialog(obj)
%SHOWSCANDIRECTORIESDIALOG The NAS directories searched for new files (toolbar "Scan directories…", Ctrl+Shift+D).
%
%   showScanDirectoriesDialog(obj)
%
%   tools/import_nas_files.py searches the directories listed in
%   lab.scan_directory for files it has not seen, on a schedule the
%   database keeps (lab.fn_scan_status). This window shows that list and,
%   for a login allowed to, edits it.
%
%   Top: the directories (CarasLabDB.getScanDirectories) -- storage root,
%   path, layout, mode, how often it is searched ("Every"), the hours it may
%   be searched in its time zone ("any" when there is no window), the
%   minimum age of a group before it is registered, the last run (local
%   time and outcome; "running", or "interrupted" when a run has no result
%   and is not running any more), when it is next due, and the files
%   pending and held under it. A directory that is overdue says so in the
%   State column and its row is shaded; one that is off is grey.
%
%   Middle: the form. Selecting a row of the list loads it; New (Ctrl+N)
%   clears it for a new directory. The interval and the minimum age are a
%   number and a unit (minutes, hours, days), stored as whole minutes; the
%   window is two times HH:mm (both empty: any time of day; 22:00 to 04:00
%   wraps midnight); the time zone of a new directory starts as that of an
%   existing one, else this computer's. Save (Ctrl+S) writes it --
%   CarasLabDB.addScanDirectory for a new one, updateScanDirectory with only
%   what changed for an existing one -- and keeps it selected. The form is
%   checked first (required fields, HH:mm, both or neither window time, a
%   positive interval in whole minutes) and what is wrong is said under it;
%   nothing is written then. A refusal by the database (another directory
%   that is the same, contains it or lies inside it; a frozen column; a
%   time zone the server does not know) is shown with the database's own
%   message.
%
%   A directory that has been searched keeps its storage root, path, layout
%   and time zone (the database freezes them): those controls are disabled
%   and their tooltip says to turn the directory off and add another.
%
%   Bottom: the runs of the selected directory (CarasLabDB.getScanRuns) and
%   its held files (CarasLabDB.getScanFiles with Status="held"), with the
%   reason code and the sentence of each.
%
%   Privileges: the list is the schema owner's, or a login's the owner
%   grants INSERT / UPDATE on lab.scan_directory to
%   (CarasLabDB.canEditScanDirectories). Without either, every control that
%   writes is disabled and a line at the top says so; with only one of
%   them, only its action is enabled (INSERT: New and the form of a new
%   directory; UPDATE: the form of an existing one).
%
%   Keys: Ctrl+S save, Ctrl+N new, Ctrl+R reload, Esc close (asks first
%   when the form has edits that were not saved), Ctrl+? the list. The
%   window's size and position are remembered (loadPrefs / savePrefs).
%
%   See also CARASLABDB/GETSCANDIRECTORIES, CARASLABDB/ADDSCANDIRECTORY,
%   CARASLABDB/UPDATESCANDIRECTORY, CARASLABDB/CANEDITSCANDIRECTORIES,
%   CARASLABDBAPP/SHOWSHORTCUTHELP.

    arguments
        obj (1,1) CarasLabDBApp
    end

    db = obj.Db;

    % ---- what this login may do, and the lists the form offers -----------
    canInsert = false;
    canUpdate = false;
    login = "";
    try
        priv = db.canEditScanDirectories();
        canInsert = logical(priv.Insert);
        canUpdate = logical(priv.Update);
        login = string(priv.Login);
    catch
        % Not known: offer nothing that writes. The database decides anyway.
    end

    rootIds = zeros(0, 1);
    rootNames = strings(0, 1);
    layoutCodes = strings(0, 1);
    layoutLabels = strings(0, 1);
    try
        rootRows = db.getStorageRoots();
        if istable(rootRows) && height(rootRows) > 0
            rootIds = local_num(rootRows.root_id);
            rootNames = local_blank(local_text(rootRows.name));
        end
        layoutRows = db.getScanLayouts();
        if istable(layoutRows) && height(layoutRows) > 0
            layoutCodes = local_blank(local_text(layoutRows.code));
            layoutLabels = local_blank(local_text(layoutRows.label));
        end
    catch loadErr
        uialert(obj.Fig, string(loadErr.message), "Scan directories");
        return
    end

    UNITS = ["minutes", "hours", "days"];
    UNIT_MIN = [1, 60, 1440];
    WORKSTATION_ZONE = local_workstationZone();

    % State shared with the nested callbacks.
    dirs = local_noDirs();          % the listed directories (getScanDirectories)
    editingId = NaN;                % the directory in the form; NaN = a new one
    orig = struct();                % its stored values, to send only what changed
    loaded = struct();              % the form as loaded, to tell unsaved edits
    busy = false;

    % ---- window -----------------------------------------------------------
    pos = local_geometry(obj.Prefs.ScanDialogGeometry, 1180, 780);
    f = uifigure("Name", "Scan directories", "Position", pos, "WindowStyle", "modal", ...
        "KeyPressFcn", @(~,e) onKey(e), "CloseRequestFcn", @(~,~) onClose());
    g = uigridlayout(f, [5 1]);
    g.RowHeight = {22, '1x', 206, '0.8x', 30};
    g.ColumnWidth = {'1x'};
    g.Padding = [10 10 10 10];
    g.RowSpacing = 6;

    noticeLbl = uilabel(g, "Text", "", "FontWeight", "bold", "Tag", "scan:notice");

    dirTbl = uitable(g, "RowName", {}, "ColumnSortable", false, ...
        "SelectionType", "row", "Multiselect", "off", "Tag", "scan:list", ...
        "CellSelectionCallback", @(~,e) onPick(e));

    % ---- the form ---------------------------------------------------------
    panel = uipanel(g, "Title", "Directory", "Tag", "scan:edit");
    ep = uigridlayout(panel, [5 8]);
    ep.ColumnWidth = {90, '1.2x', 70, '1x', 75, '1x', 70, '1x'};
    ep.RowHeight = {24, 24, 24, 24, '1x'};
    ep.Padding = [8 6 8 6];
    ep.RowSpacing = 6;
    ep.ColumnSpacing = 6;

    local_at(uilabel(ep, "Text", "Storage root"), 1, 1);
    if isempty(rootIds)
        rootDd = uidropdown(ep, "Items", {'(no storage roots)'}, "Enable", "off", ...
            "Tag", "scan:root");
    else
        rootDd = uidropdown(ep, ...
            "Items", reshape(cellstr(rootNames + " (" + string(rootIds) + ")"), 1, []), ...
            "ItemsData", reshape(num2cell(rootIds), 1, []), "Value", rootIds(1), ...
            "Tag", "scan:root", ...
            "ValueChangedFcn", @(~,~) onRootChanged());
    end
    local_at(rootDd, 1, 2);
    local_at(uilabel(ep, "Text", "Path", "HorizontalAlignment", "right"), 1, 3);
    pathEf = uieditfield(ep, "text", "Tag", "scan:path", ...
        "Placeholder", "the directory below the storage root, e.g. rig1/epsych", ...
        "ValueChangedFcn", @(~,~) onEdited());
    local_at(pathEf, 1, [4 6]);
    local_at(uilabel(ep, "Text", "Layout", "HorizontalAlignment", "right"), 1, 7);
    if isempty(layoutCodes)
        layoutDd = uidropdown(ep, "Items", {'(no layouts)'}, "Enable", "off", "Tag", "scan:layout");
    else
        layoutDd = uidropdown(ep, ...
            "Items", reshape(cellstr(layoutCodes + " (" + layoutLabels + ")"), 1, []), ...
            "ItemsData", reshape(cellstr(layoutCodes), 1, []), "Value", char(layoutCodes(1)), ...
            "Tag", "scan:layout", ...
            "ValueChangedFcn", @(~,~) onEdited());
    end
    local_at(layoutDd, 1, 8);

    local_at(uilabel(ep, "Text", "Every"), 2, 1);
    everyGrid = uigridlayout(ep, [1 2]);
    everyGrid.ColumnWidth = {'1x', 80};
    everyGrid.Padding = [0 0 0 0];
    everyGrid.ColumnSpacing = 4;
    local_at(everyGrid, 2, 2);
    intervalEf = uieditfield(everyGrid, "text", "Tag", "scan:interval", ...
        "Placeholder", "e.g. 1", ...
        "Tooltip", "How often the directory is searched: a number and its unit, stored as whole minutes", ...
        "ValueChangedFcn", @(~,~) onEdited());
    intervalUnitDd = uidropdown(everyGrid, "Items", cellstr(UNITS), "Value", 'hours', ...
        "Tag", "scan:intervalUnit", "ValueChangedFcn", @(~,~) onEdited());
    local_at(uilabel(ep, "Text", "Hours", "HorizontalAlignment", "right"), 2, 3);
    hoursGrid = uigridlayout(ep, [1 3]);
    hoursGrid.ColumnWidth = {'1x', 18, '1x'};
    hoursGrid.Padding = [0 0 0 0];
    hoursGrid.ColumnSpacing = 4;
    local_at(hoursGrid, 2, 4);
    startEf = uieditfield(hoursGrid, "text", "Tag", "scan:start", "Placeholder", "HH:mm", ...
        "Tooltip", "Start of the hours it may be searched, in its time zone (empty with the end: any time)", ...
        "ValueChangedFcn", @(~,~) onEdited());
    uilabel(hoursGrid, "Text", "to", "HorizontalAlignment", "center");
    endEf = uieditfield(hoursGrid, "text", "Tag", "scan:end", "Placeholder", "HH:mm", ...
        "Tooltip", "End of the hours (not included); before the start, the window wraps midnight", ...
        "ValueChangedFcn", @(~,~) onEdited());
    local_at(uilabel(ep, "Text", "Min. age", "HorizontalAlignment", "right"), 2, 5);
    ageGrid = uigridlayout(ep, [1 2]);
    ageGrid.ColumnWidth = {'1x', 80};
    ageGrid.Padding = [0 0 0 0];
    ageGrid.ColumnSpacing = 4;
    local_at(ageGrid, 2, 6);
    ageEf = uieditfield(ageGrid, "text", "Tag", "scan:age", "Placeholder", "e.g. 24", ...
        "Tooltip", "How long a group of files must be seen unchanged before it is registered", ...
        "ValueChangedFcn", @(~,~) onEdited());
    ageUnitDd = uidropdown(ageGrid, "Items", cellstr(UNITS), "Value", 'hours', ...
        "Tag", "scan:ageUnit", "ValueChangedFcn", @(~,~) onEdited());
    local_at(uilabel(ep, "Text", "Mode", "HorizontalAlignment", "right"), 2, 7);
    modeDd = uidropdown(ep, "Items", {'report', 'register', 'off'}, "Value", 'report', ...
        "Tag", "scan:mode", ...
        "Tooltip", "report: search and report, register nothing · register: register what is " + ...
        "new and unambiguous · off: not searched (frees its path for another directory)", ...
        "ValueChangedFcn", @(~,~) onEdited());
    local_at(modeDd, 2, 8);

    local_at(uilabel(ep, "Text", "Rig"), 3, 1);
    rigEf = uieditfield(ep, "text", "Tag", "scan:rig", "Placeholder", "optional", ...
        "Tooltip", "Recorded on the sessions registered from this directory", ...
        "ValueChangedFcn", @(~,~) onEdited());
    local_at(rigEf, 3, 2);
    local_at(uilabel(ep, "Text", "Pair with", "HorizontalAlignment", "right"), 3, 3);
    pairDd = uidropdown(ep, "Items", {'(none)'}, "ItemsData", {0}, "Value", 0, ...
        "Tag", "scan:pair", ...
        "Tooltip", "Another directory on the same storage root whose files belong with these " + ...
        "(the behavior files of a rig, for its recordings)", ...
        "ValueChangedFcn", @(~,~) onEdited());
    local_at(pairDd, 3, [4 6]);
    local_at(uilabel(ep, "Text", "Time zone", "HorizontalAlignment", "right"), 3, 7);
    tzEf = uieditfield(ep, "text", "Tag", "scan:tz", "Placeholder", "e.g. America/New_York", ...
        "ValueChangedFcn", @(~,~) onEdited());
    local_at(tzEf, 3, 8);

    local_at(uilabel(ep, "Text", "Notes"), 4, 1);
    notesEf = uieditfield(ep, "text", "Tag", "scan:notes", "Placeholder", "optional", ...
        "ValueChangedFcn", @(~,~) onEdited());
    local_at(notesEf, 4, [2 8]);

    msgLbl = uilabel(ep, "Text", "", "WordWrap", "on", "Tag", "scan:message", ...
        "VerticalAlignment", "top");
    local_at(msgLbl, 5, [1 6]);
    newBtn = uibutton(ep, "Text", "New", "Tag", "scan:new", ...
        "Tooltip", "Clear the form for a new directory (Ctrl+N)", ...
        "ButtonPushedFcn", @(~,~) onNew());
    local_at(newBtn, 5, 7);
    saveBtn = uibutton(ep, "Text", "Save", "Tag", "scan:save", ...
        "Tooltip", "Save the directory in the form (Ctrl+S)", ...
        "ButtonPushedFcn", @(~,~) onSave());
    local_at(saveBtn, 5, 8);

    % The tooltips the four frozen controls have while they can be changed.
    FROZEN = {rootDd, pathEf, layoutDd, tzEf};
    FROZEN_TIP = ["The storage root the directory is under", ...
        "The directory, relative to the storage root ('/' separators)", ...
        "How the directory is laid out: the module of the tool that reads it", ...
        "The zone of the times in its file names and of its hours: a name such as " + ...
        "America/New_York, not an abbreviation"];
    FORM = {rootDd, pathEf, layoutDd, intervalEf, intervalUnitDd, startEf, endEf, ...
        ageEf, ageUnitDd, modeDd, rigEf, pairDd, tzEf, notesEf};

    % ---- runs and held files of the selected directory ---------------------
    tg = uitabgroup(g);
    runsTab = uitab(tg, "Title", "Runs");
    rg = uigridlayout(runsTab, [1 1]);
    rg.Padding = [4 4 4 4];
    runsTbl = uitable(rg, "RowName", {}, "ColumnSortable", false, "Tag", "scan:runs");
    heldTab = uitab(tg, "Title", "Held files");
    hg = uigridlayout(heldTab, [1 1]);
    hg.Padding = [4 4 4 4];
    heldTbl = uitable(hg, "RowName", {}, "ColumnSortable", false, "Tag", "scan:held");

    foot = uigridlayout(g, [1 4]);
    foot.ColumnWidth = {'1x', 80, 90, 90};
    foot.Padding = [0 0 0 0];
    statusLbl = uilabel(foot, "Text", "", "Tag", "scan:status", "FontColor", [0.35 0.35 0.35]);
    uibutton(foot, "Text", "Help", "Tooltip", "Keyboard shortcuts (Ctrl+?)", ...
        "ButtonPushedFcn", @(~,~) CarasLabDBApp.showShortcutHelp(f, "scandirs"));
    uibutton(foot, "Text", "Refresh", "Tooltip", "Reload the list, its runs and held files (Ctrl+R)", ...
        "ButtonPushedFcn", @(~,~) onRefresh());
    uibutton(foot, "Text", "Close", "Tooltip", "Close (Esc)", ...
        "ButtonPushedFcn", @(~,~) onClose());

    showNotice();
    reloadList(NaN);
    if ~canInsert && canUpdate && ~isempty(dirs.Id)
        dirTbl.Selection = 1;
        loadRow(1);
    else
        clearForm();
    end

    uiwait(f);
    if isvalid(f)
        try
            obj.Prefs.ScanDialogGeometry = f.Position;
            obj.savePrefs();
        catch
            % Remembering the window is a convenience.
        end
        delete(f);
    end
    return

    % ---- nested callbacks -------------------------------------------------
    function onKey(e)
        %ONKEY Shortcuts while the list or a button has focus (a uifigure
        %   does not forward keys while a text box has focus).
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "scandirs");
        elseif key == "escape"
            onClose();
        elseif key == "s" && ctrl
            onSave();
        elseif key == "n" && ctrl
            onNew();
        elseif key == "r" && ctrl
            onRefresh();
        end
    end

    function onClose()
        %ONCLOSE Close, Esc or the window's close box: ask before discarding edits.
        try
            if busy
                return
            end
            if isDirty()
                answer = uiconfirm(f, "The form has changes that were not saved. Discard them?", ...
                    "Scan directories", "Options", {'Discard', 'Keep editing'}, ...
                    "DefaultOption", 2, "CancelOption", 2, "Icon", "warning");
                if ~strcmp(answer, 'Discard')
                    return
                end
            end
            uiresume(f);
        catch
            % Never leave a window that cannot be closed.
            uiresume(f);
        end
    end

    function showNotice()
        %SHOWNOTICE The line at the top: what this login may do here.
        who = login;
        if strlength(who) == 0
            who = "this login";
        end
        if ~canInsert && ~canUpdate
            noticeLbl.Text = "The list is read-only for this login (" + who + "): only the " + ...
                "schema owner, or a login the owner grants INSERT and UPDATE on " + ...
                "lab.scan_directory to, can change it.";
            noticeLbl.FontColor = [0.60 0.10 0.10];
        elseif canInsert && ~canUpdate
            noticeLbl.Text = "This login (" + who + ") can add directories but not change " + ...
                "them: UPDATE on lab.scan_directory is not granted to it.";
            noticeLbl.FontColor = [0.60 0.10 0.10];
        elseif ~canInsert && canUpdate
            noticeLbl.Text = "This login (" + who + ") can change directories but not add " + ...
                "them: INSERT on lab.scan_directory is not granted to it.";
            noticeLbl.FontColor = [0.60 0.10 0.10];
        else
            noticeLbl.Text = "Select a directory to edit it, or New (Ctrl+N) to add one. " + ...
                "Nothing is written until Save (Ctrl+S).";
            noticeLbl.FontColor = [0 0 0];
        end
        noticeLbl.Tooltip = noticeLbl.Text;
    end

    function reloadList(selectId)
        %RELOADLIST Re-read the directories; select SELECTID's row if it is listed.
        try
            D = db.getScanDirectories();
        catch listErr
            uialert(f, string(listErr.message), "Load scan directories failed");
            return
        end
        dirs = local_dirs(D);
        dirTbl.Data = local_dirTable(dirs);
        try
            removeStyle(dirTbl);
            late = find(dirs.Overdue & dirs.Mode ~= "off");
            off = find(dirs.Mode == "off");
            if ~isempty(late)
                addStyle(dirTbl, uistyle("BackgroundColor", [1.00 0.85 0.85], ...
                    "FontWeight", "bold"), "row", late);
            end
            if ~isempty(off)
                addStyle(dirTbl, uistyle("FontColor", [0.50 0.50 0.50]), "row", off);
            end
        catch
            % Shading is a convenience; the State column says the same.
        end
        k = find(dirs.Id == selectId, 1);
        if isempty(k)
            dirTbl.Selection = [];
        else
            dirTbl.Selection = k;
        end
    end

    function onPick(e)
        %ONPICK Selecting a row of the list loads that directory into the form.
        if busy || isempty(e.Indices)
            return
        end
        r = e.Indices(1, 1);
        if r < 1 || r > numel(dirs.Id) || dirs.Id(r) == editingId
            return
        end
        if isDirty()
            answer = uiconfirm(f, "The form has changes that were not saved. Discard them " + ...
                "and show directory " + string(dirs.Id(r)) + "?", "Scan directories", ...
                "Options", {'Discard', 'Keep editing'}, ...
                "DefaultOption", 2, "CancelOption", 2, "Icon", "warning");
            if ~strcmp(answer, 'Discard')
                k = find(dirs.Id == editingId, 1);
                if isempty(k)
                    dirTbl.Selection = [];
                else
                    dirTbl.Selection = k;
                end
                return
            end
        end
        loadRow(r);
    end

    function loadRow(k)
        %LOADROW Put directory K of the list in the form.
        editingId = dirs.Id(k);
        orig = struct("RootId", dirs.RootId(k), "Path", dirs.Path(k), ...
            "Layout", dirs.Layout(k), "IntervalMin", dirs.IntervalMin(k), ...
            "Start", dirs.Start(k), "End", dirs.End(k), "AgeMin", dirs.AgeMin(k), ...
            "Mode", dirs.Mode(k), "Rig", dirs.Rig(k), "PairWith", dirs.PairWith(k), ...
            "TimeZone", dirs.TimeZone(k), "Notes", dirs.Notes(k));
        if ~isempty(rootIds) && ismember(orig.RootId, rootIds)
            rootDd.Value = orig.RootId;
        end
        pathEf.Value = char(orig.Path);
        if ~isempty(layoutCodes) && ismember(orig.Layout, layoutCodes)
            layoutDd.Value = char(orig.Layout);
        end
        [n, unit] = local_splitMinutes(orig.IntervalMin, UNITS, UNIT_MIN);
        intervalEf.Value = char(n);
        intervalUnitDd.Value = char(unit);
        startEf.Value = char(orig.Start);
        endEf.Value = char(orig.End);
        [n, unit] = local_splitMinutes(orig.AgeMin, UNITS, UNIT_MIN);
        ageEf.Value = char(n);
        ageUnitDd.Value = char(unit);
        if ismember(orig.Mode, ["report", "register", "off"])
            modeDd.Value = char(orig.Mode);
        end
        rigEf.Value = char(orig.Rig);
        tzEf.Value = char(orig.TimeZone);
        notesEf.Value = char(orig.Notes);
        rebuildPair(orig.PairWith);
        loaded = readForm();
        setMessage("", false);
        applyEnable();
        loadDetails();
        statusLbl.Text = "Directory " + string(editingId) + ": " + dirs.Root(k) + ":" + orig.Path;
    end

    function clearForm()
        %CLEARFORM The form of a new directory, with its defaults.
        editingId = NaN;
        orig = struct();
        if ~isempty(rootIds)
            rootDd.Value = rootIds(1);
        end
        pathEf.Value = '';
        if ~isempty(layoutCodes)
            layoutDd.Value = char(layoutCodes(1));
        end
        intervalEf.Value = '1';
        intervalUnitDd.Value = 'hours';
        startEf.Value = '';
        endEf.Value = '';
        ageEf.Value = '24';
        ageUnitDd.Value = 'hours';
        modeDd.Value = 'report';
        rigEf.Value = '';
        % The zone of the directories listed already, else this computer's.
        zones = dirs.TimeZone(strlength(dirs.TimeZone) > 0);
        if isempty(zones)
            tzEf.Value = char(WORKSTATION_ZONE);
        else
            tzEf.Value = char(zones(1));
        end
        notesEf.Value = '';
        rebuildPair(0);
        loaded = readForm();
        setMessage("", false);
        applyEnable();
        loadDetails();
        if canInsert
            statusLbl.Text = "New directory: fill in the form and Save (Ctrl+S).";
        else
            statusLbl.Text = "";
        end
    end

    function onNew()
        %ONNEW New (Ctrl+N): clear the form for a directory to add.
        if busy
            return
        end
        if ~canInsert
            setMessage("This login cannot add directories: INSERT on lab.scan_directory " + ...
                "is not granted to it.", true);
            return
        end
        if isDirty()
            answer = uiconfirm(f, "The form has changes that were not saved. Discard them?", ...
                "Scan directories", "Options", {'Discard', 'Keep editing'}, ...
                "DefaultOption", 2, "CancelOption", 2, "Icon", "warning");
            if ~strcmp(answer, 'Discard')
                return
            end
        end
        dirTbl.Selection = [];
        clearForm();
        try
            focus(pathEf);
        catch
        end
    end

    function onRootChanged()
        %ONROOTCHANGED Another storage root: offer its directories to pair with.
        rebuildPair(double(pairDd.Value));
        onEdited();
    end

    function rebuildPair(want)
        %REBUILDPAIR The other directories on the form's storage root, or none.
        rid = NaN;
        if ~isempty(rootIds)
            rid = double(rootDd.Value);
        end
        mine = dirs.RootId == rid & dirs.Id ~= editingId;
        ids = dirs.Id(mine);
        labels = ["(none)"; string(ids) + ": " + dirs.Path(mine)];
        set(pairDd, "Items", reshape(cellstr(labels), 1, []), ...
            "ItemsData", reshape(num2cell([0; ids]), 1, []));
        if ~isnan(want) && ismember(want, ids)
            pairDd.Value = want;
        else
            pairDd.Value = 0;
        end
    end

    function onEdited()
        %ONEDITED A control of the form changed: say whether there are unsaved edits.
        if isDirty()
            statusLbl.Text = "Unsaved changes: Save (Ctrl+S) writes them.";
        elseif isnan(editingId)
            statusLbl.Text = "";
        else
            statusLbl.Text = "Directory " + string(editingId) + ": no unsaved changes.";
        end
    end

    function v = readForm()
        %READFORM The form's controls as they stand (text as typed).
        v = struct();
        if isempty(rootIds)
            v.RootId = NaN;
        else
            v.RootId = double(rootDd.Value);
        end
        v.Path = strtrim(string(pathEf.Value));
        if isempty(layoutCodes)
            v.Layout = "";
        else
            v.Layout = string(layoutDd.Value);
        end
        v.Interval = strtrim(string(intervalEf.Value));
        v.IntervalUnit = string(intervalUnitDd.Value);
        v.Start = strtrim(string(startEf.Value));
        v.End = strtrim(string(endEf.Value));
        v.Age = strtrim(string(ageEf.Value));
        v.AgeUnit = string(ageUnitDd.Value);
        v.Mode = string(modeDd.Value);
        v.Rig = strtrim(string(rigEf.Value));
        v.PairWith = double(pairDd.Value);
        v.TimeZone = strtrim(string(tzEf.Value));
        v.Notes = strtrim(string(notesEf.Value));
    end

    function tf = isDirty()
        tf = ~isequal(readForm(), loaded);
    end

    function setMessage(text, isProblem)
        %SETMESSAGE The line under the form: what is wrong (red), or what was done.
        msgLbl.Text = char(text);
        msgLbl.Tooltip = char(text);
        if isProblem
            msgLbl.FontColor = [0.75 0.00 0.00];
        else
            msgLbl.FontColor = [0.20 0.20 0.20];
        end
    end

    function applyEnable()
        %APPLYENABLE Enable what this login may write, and keep frozen columns frozen.
        isNew = isnan(editingId);
        canWrite = (isNew && canInsert) || (~isNew && canUpdate);
        frozen = false;
        if ~isNew
            k = find(dirs.Id == editingId, 1);
            frozen = ~isempty(k) && dirs.HasRuns(k);
        end
        for i = 1:numel(FORM)
            control = FORM{i};
            control.Enable = local_onoff(canWrite);
        end
        for i = 1:numel(FROZEN)
            control = FROZEN{i};
            if frozen
                control.Enable = 'off';
                control.Tooltip = char("Frozen: directory " + string(editingId) + ...
                    " has been searched, so the database keeps its storage root, path, " + ...
                    "layout and time zone. To change them, turn it off (Mode off) and " + ...
                    "add another directory.");
            else
                control.Tooltip = char(FROZEN_TIP(i));
            end
        end
        if isempty(rootIds)
            rootDd.Enable = 'off';
        end
        if isempty(layoutCodes)
            layoutDd.Enable = 'off';
        end
        newBtn.Enable = local_onoff(canInsert);
        saveBtn.Enable = local_onoff(canWrite);
    end

    function loadDetails()
        %LOADDETAILS The runs and the held files of the directory in the form.
        runsTab.Title = 'Runs';
        heldTab.Title = 'Held files';
        if isnan(editingId)
            runsTbl.Data = local_runTable(table());
            heldTbl.Data = local_heldTable(table());
            return
        end
        try
            R = db.getScanRuns(ScanDirectoryId=editingId, Limit=200);
            H = db.getScanFiles(Status="held", StorageRootId=orig.RootId, ...
                PathPrefix=orig.Path + "/");
        catch detailErr
            uialert(f, string(detailErr.message), "Load runs and held files failed");
            return
        end
        runsTbl.Data = local_runTable(R);
        heldTbl.Data = local_heldTable(H);
        runsTab.Title = char("Runs (" + string(height(runsTbl.Data)) + ")");
        heldTab.Title = char("Held files (" + string(height(heldTbl.Data)) + ")");
    end

    function onRefresh()
        %ONREFRESH Ctrl+R: reload the list; the form too unless it has unsaved edits.
        if busy
            return
        end
        keepEdits = isDirty();
        reloadList(editingId);
        k = find(dirs.Id == editingId, 1);
        if keepEdits
            statusLbl.Text = "Reloaded the list; the form keeps your unsaved changes.";
        elseif ~isempty(k)
            loadRow(k);
        else
            clearForm();
        end
    end

    function onSave()
        %ONSAVE Save (Ctrl+S): check the form, then add or update the directory.
        if busy
            return
        end
        isNew = isnan(editingId);
        if isNew && ~canInsert
            setMessage("This login cannot add directories: INSERT on lab.scan_directory " + ...
                "is not granted to it. Nothing was written.", true);
            return
        end
        if ~isNew && ~canUpdate
            setMessage("This login cannot change directories: UPDATE on " + ...
                "lab.scan_directory is not granted to it. Nothing was written.", true);
            return
        end
        [v, problems] = local_parseForm(readForm(), UNITS, UNIT_MIN);
        if ~isempty(problems)
            setMessage(strjoin(problems, " ") + " Nothing was written.", true);
            return
        end

        busy = true;
        try
            if isNew
                args = {"StorageRootId", v.RootId, "RelativePath", v.Path, ...
                    "Layout", v.Layout, "TimeZone", v.TimeZone, ...
                    "ScanIntervalMin", v.IntervalMin, "MinAgeMin", v.AgeMin, "Mode", v.Mode};
                if strlength(v.Start) > 0
                    args = [args, {"WindowStart", v.Start, "WindowEnd", v.End}];
                end
                if strlength(v.Rig) > 0
                    args = [args, {"Rig", v.Rig}];
                end
                if v.PairWith > 0
                    args = [args, {"PairWith", v.PairWith}];
                end
                if strlength(v.Notes) > 0
                    args = [args, {"Notes", v.Notes}];
                end
                savedId = db.addScanDirectory(args{:});
                done = "Added directory " + string(savedId) + ".";
            else
                args = local_changes(v, orig);
                if isempty(args)
                    busy = false;
                    setMessage("Nothing changed: nothing was written.", false);
                    return
                end
                db.updateScanDirectory(editingId, args{:});
                savedId = editingId;
                done = "Saved directory " + string(savedId) + ".";
            end
        catch saveErr
            busy = false;
            % An overlap, a frozen column, an unknown time zone, a missing
            % privilege: the database's own words.
            setMessage("Not saved: " + string(saveErr.message), true);
            uialert(f, string(saveErr.message), "Scan directory not saved");
            return
        end
        busy = false;
        reloadList(savedId);
        k = find(dirs.Id == savedId, 1);
        if isempty(k)
            clearForm();
        else
            loadRow(k);
        end
        setMessage(done, false);
        statusLbl.Text = done;
    end
end

% =============================================================================
function local_at(component, row, col)
    %LOCAL_AT Put COMPONENT in cell (ROW, COL) of its grid.
    component.Layout.Row = row;
    component.Layout.Column = col;
end

function s = local_onoff(tf)
    if tf
        s = 'on';
    else
        s = 'off';
    end
end

function z = local_workstationZone()
    %LOCAL_WORKSTATIONZONE This computer's time zone name (as the class sends it).
    try
        z = string(datetime("now", "TimeZone", "local").TimeZone);
    catch
        z = "";
    end
end

function dirs = local_noDirs()
    z = strings(0, 1);
    n = zeros(0, 1);
    b = false(0, 1);
    t = NaT(0, 1);
    dirs = struct("Id", n, "RootId", n, "Root", z, "Path", z, "Layout", z, "Rig", z, ...
        "PairWith", n, "TimeZone", z, "IntervalMin", n, "Start", z, "End", z, "AgeMin", n, ...
        "Mode", z, "Notes", z, "LastRunId", n, "LastStarted", t, "LastOutcome", z, ...
        "DueAt", t, "IsDue", b, "Overdue", b, "Running", b, "Pending", n, "Held", n, ...
        "HasRuns", b);
end

function dirs = local_dirs(D)
    %LOCAL_DIRS The rows of getScanDirectories as typed columns ("" for NULL text).
    dirs = local_noDirs();
    if ~istable(D) || height(D) == 0
        return
    end
    n = height(D);
    col = @(name) local_col(D, name, n);
    dirs.Id          = local_num(col("scan_directory_id"));
    dirs.RootId      = local_num(col("storage_root_id"));
    dirs.Root        = local_blank(local_text(col("storage_root")));
    dirs.Path        = local_blank(local_text(col("relative_path")));
    dirs.Layout      = local_blank(local_text(col("layout")));
    dirs.Rig         = local_blank(local_text(col("rig")));
    dirs.PairWith    = local_num(col("pair_with"));
    dirs.TimeZone    = local_blank(local_text(col("time_zone")));
    dirs.IntervalMin = local_num(col("scan_interval_min"));
    dirs.Start       = local_blank(local_text(col("window_start_text")));
    dirs.End         = local_blank(local_text(col("window_end_text")));
    dirs.AgeMin      = local_num(col("min_age_min"));
    dirs.Mode        = local_blank(local_text(col("mode")));
    dirs.Notes       = local_blank(local_text(col("notes")));
    dirs.LastRunId   = local_num(col("last_run_id"));
    dirs.LastStarted = local_time(col("last_run_started_at"));
    dirs.LastOutcome = local_blank(local_text(col("last_run_outcome")));
    dirs.DueAt       = local_time(col("due_at"));
    dirs.IsDue       = local_bool(col("is_due"));
    dirs.Overdue     = local_bool(col("is_overdue"));
    dirs.Running     = local_bool(col("is_running"));
    dirs.Pending     = local_num(col("n_pending"));
    dirs.Held        = local_num(col("n_held"));
    dirs.PairWith(isnan(dirs.PairWith)) = 0;
    dirs.HasRuns     = ~isnan(dirs.LastRunId) | ~isnat(dirs.LastStarted);
end

function T = local_dirTable(dirs)
    %LOCAL_DIRTABLE The list of directories as shown.
    cols = ["Id", "Root", "Path", "Layout", "Mode", "Every", "Hours", "Min. age", ...
        "Last run", "Next due", "Pending", "Held", "State"];
    n = numel(dirs.Id);
    if n == 0
        T = local_emptyTable(cols);
        return
    end
    every = strings(n, 1);
    hoursText = strings(n, 1);
    age = strings(n, 1);
    last = strings(n, 1);
    due = strings(n, 1);
    state = strings(n, 1);
    for i = 1:n
        every(i) = local_minutesText(dirs.IntervalMin(i));
        age(i) = local_minutesText(dirs.AgeMin(i));
        if strlength(dirs.Start(i)) > 0 && strlength(dirs.End(i)) > 0
            hoursText(i) = dirs.Start(i) + "-" + dirs.End(i);
        else
            hoursText(i) = "any";
        end
        if ~dirs.HasRuns(i)
            last(i) = "never";
        else
            if strlength(dirs.LastOutcome(i)) > 0
                outcome = dirs.LastOutcome(i);
            elseif dirs.Running(i)
                outcome = "running";
            else
                outcome = "interrupted";
            end
            last(i) = strtrim(local_when(dirs.LastStarted(i)) + " " + outcome);
        end
        if dirs.Mode(i) == "off"
            due(i) = "-";
            state(i) = "off";
        else
            if dirs.IsDue(i)
                due(i) = "now";
            else
                due(i) = local_when(dirs.DueAt(i));
            end
            if dirs.Overdue(i)
                state(i) = "overdue";
            elseif dirs.Running(i)
                state(i) = "running";
            elseif dirs.IsDue(i)
                state(i) = "due";
            end
        end
    end
    T = table(string(dirs.Id), dirs.Root, dirs.Path, dirs.Layout, dirs.Mode, every, ...
        hoursText, age, last, due, local_count(dirs.Pending), local_count(dirs.Held), state, ...
        'VariableNames', cellstr(cols));
end

function T = local_runTable(R)
    %LOCAL_RUNTABLE The runs of one directory as shown, newest first.
    cols = ["Run", "Started", "Command", "Mode", "Scheduled for", "Outcome", "Finished", ...
        "Listed", "Registered", "Pending", "Held", "Message"];
    if ~istable(R) || height(R) == 0
        T = local_emptyTable(cols);
        return
    end
    n = height(R);
    col = @(name) local_col(R, name, n);
    outcome = local_blank(local_text(col("outcome")));
    running = local_bool(col("is_running"));
    none = strlength(outcome) == 0;
    outcome(none & running) = "running";
    outcome(none & ~running) = "interrupted";
    scheduled = local_whenCol(local_time(col("due_at")));
    scheduled(strlength(scheduled) == 0) = "by hand";
    T = table(string(local_num(col("scan_run_id"))), local_whenCol(local_time(col("started_at"))), ...
        local_blank(local_text(col("command"))), local_blank(local_text(col("mode"))), ...
        scheduled, outcome, local_whenCol(local_time(col("finished_at"))), ...
        local_count(local_num(col("files_listed"))), local_count(local_num(col("files_registered"))), ...
        local_count(local_num(col("files_pending"))), local_count(local_num(col("files_held"))), ...
        local_blank(local_text(col("message"))), 'VariableNames', cellstr(cols));
end

function T = local_heldTable(H)
    %LOCAL_HELDTABLE The held files under one directory as shown.
    cols = ["Path", "Reason", "Explanation", "Size (bytes)", "Seen"];
    if ~istable(H) || height(H) == 0
        T = local_emptyTable(cols);
        return
    end
    n = height(H);
    col = @(name) local_col(H, name, n);
    T = table(local_blank(local_text(col("relative_path"))), ...
        local_blank(local_text(col("reason_code"))), local_blank(local_text(col("reason"))), ...
        local_count(local_num(col("size_bytes"))), local_whenCol(local_time(col("seen_at"))), ...
        'VariableNames', cellstr(cols));
end

function args = local_changes(v, orig)
    %LOCAL_CHANGES The Name=Value arguments of updateScanDirectory for what changed.
    args = {};
    clearCols = strings(1, 0);
    if v.RootId ~= orig.RootId
        args = [args, {"StorageRootId", v.RootId}];
    end
    if v.Path ~= orig.Path
        args = [args, {"RelativePath", v.Path}];
    end
    if v.Layout ~= orig.Layout
        args = [args, {"Layout", v.Layout}];
    end
    if v.TimeZone ~= orig.TimeZone
        args = [args, {"TimeZone", v.TimeZone}];
    end
    if v.IntervalMin ~= orig.IntervalMin
        args = [args, {"ScanIntervalMin", v.IntervalMin}];
    end
    if v.AgeMin ~= orig.AgeMin
        args = [args, {"MinAgeMin", v.AgeMin}];
    end
    if v.Mode ~= orig.Mode
        args = [args, {"Mode", v.Mode}];
    end
    if v.Start ~= orig.Start || v.End ~= orig.End
        if strlength(v.Start) == 0
            clearCols(end+1) = "window";
        else
            args = [args, {"WindowStart", v.Start, "WindowEnd", v.End}];
        end
    end
    if v.Rig ~= orig.Rig
        if strlength(v.Rig) == 0
            clearCols(end+1) = "rig";
        else
            args = [args, {"Rig", v.Rig}];
        end
    end
    if v.PairWith ~= orig.PairWith
        if v.PairWith <= 0
            clearCols(end+1) = "pair_with";
        else
            args = [args, {"PairWith", v.PairWith}];
        end
    end
    if v.Notes ~= orig.Notes
        if strlength(v.Notes) == 0
            clearCols(end+1) = "notes";
        else
            args = [args, {"Notes", v.Notes}];
        end
    end
    if ~isempty(clearCols)
        args = [args, {"Clear", clearCols}];
    end
end

function [v, problems] = local_parseForm(raw, units, unitMin)
    %LOCAL_PARSEFORM Check the form; V holds what would be sent (minutes as whole numbers).
    problems = strings(1, 0);
    v = raw;
    v.IntervalMin = NaN;
    v.AgeMin = NaN;
    if isnan(raw.RootId)
        problems(end+1) = "Choose a storage root.";
    end
    if strlength(raw.Path) == 0
        problems(end+1) = "Path is required.";
    end
    if strlength(raw.Layout) == 0
        problems(end+1) = "Choose a layout.";
    end
    if strlength(raw.TimeZone) == 0
        problems(end+1) = "Time zone is required (a name such as America/New_York).";
    end
    [v.IntervalMin, why] = local_minutes(raw.Interval, raw.IntervalUnit, units, unitMin, false);
    if strlength(why) > 0
        problems(end+1) = "Every: " + why;
    elseif v.IntervalMin > 527040
        problems(end+1) = "Every: at most 366 days (527040 minutes).";
    end
    [v.AgeMin, why] = local_minutes(raw.Age, raw.AgeUnit, units, unitMin, true);
    if strlength(why) > 0
        problems(end+1) = "Min. age: " + why;
    end
    hasStart = strlength(raw.Start) > 0;
    hasEnd = strlength(raw.End) > 0;
    pattern = '^([01]\d|2[0-3]):[0-5]\d$';
    if hasStart ~= hasEnd
        problems(end+1) = "Hours: give both a start and an end (HH:mm), or neither for any time of day.";
    elseif hasStart
        okStart = ~isempty(regexp(char(raw.Start), pattern, 'once'));
        okEnd = ~isempty(regexp(char(raw.End), pattern, 'once'));
        if ~okStart
            problems(end+1) = "Hours: the start must be a time written HH:mm, 00:00 to 23:59 " + ...
                "(not '" + raw.Start + "').";
        end
        if ~okEnd
            problems(end+1) = "Hours: the end must be a time written HH:mm, 00:00 to 23:59 " + ...
                "(not '" + raw.End + "').";
        end
        if okStart && okEnd && raw.Start == raw.End
            problems(end+1) = "Hours: the start and the end are the same time; leave both " + ...
                "empty for any time of day.";
        end
    end
end

function [m, why] = local_minutes(text, unit, units, unitMin, zeroOk)
    %LOCAL_MINUTES A number and its unit as whole minutes, or why it cannot be.
    m = NaN;
    why = "";
    if strlength(text) == 0
        why = "a number is required.";
        return
    end
    [x, problem] = CarasLabDBApp.parseNumber(text);
    if strlength(problem) > 0
        why = problem;
        return
    end
    if isnan(x)
        why = "a number is required.";
        return
    end
    k = find(units == unit, 1);
    if isempty(k)
        k = 1;
    end
    total = x * unitMin(k);
    if zeroOk && total < 0
        why = "it cannot be negative.";
        return
    elseif ~zeroOk && total <= 0
        why = "it must be more than 0.";
        return
    end
    if abs(total - round(total)) > 1e-6
        why = "it must come to whole minutes (" + text + " " + unit + " is not).";
        return
    end
    m = round(total);
end

function [n, unit] = local_splitMinutes(m, units, unitMin)
    %LOCAL_SPLITMINUTES Whole minutes as a number in the largest unit that holds it exactly.
    unit = units(1);
    n = "";
    if isnan(m)
        return
    end
    for k = numel(units):-1:1
        if m > 0 && mod(m, unitMin(k)) == 0
            unit = units(k);
            n = string(sprintf("%d", round(m / unitMin(k))));
            return
        end
    end
    n = string(sprintf("%d", round(m)));
end

function s = local_minutesText(m)
    %LOCAL_MINUTESTEXT Whole minutes as "15 min", "1 h", "24 h" or "7 d".
    if isnan(m)
        s = "";
    elseif m >= 2880 && mod(m, 1440) == 0
        s = string(sprintf("%d d", round(m / 1440)));
    elseif m > 0 && mod(m, 60) == 0
        s = string(sprintf("%d h", round(m / 60)));
    else
        s = string(sprintf("%d min", round(m)));
    end
end

function s = local_count(x)
    %LOCAL_COUNT Whole numbers as text ("" for NULL).
    s = strings(numel(x), 1);
    for i = 1:numel(x)
        if ~isnan(x(i))
            s(i) = string(sprintf("%d", round(x(i))));
        end
    end
end

function T = local_emptyTable(cols)
    T = table('Size', [0 numel(cols)], ...
        'VariableTypes', repmat({'string'}, 1, numel(cols)), ...
        'VariableNames', cellstr(cols));
end

function c = local_col(T, name, n)
    %LOCAL_COL Column NAME of the fetched table T, or N empty cells if it has none.
    if ismember(char(name), T.Properties.VariableNames)
        c = T.(char(name));
    else
        c = cell(n, 1);
    end
end

function s = local_text(col)
    %LOCAL_TEXT A fetched text column as a string column vector (NULL -> missing).
    if iscell(col)
        s = strings(numel(col), 1);
        for i = 1:numel(col)
            v = col{i};
            if (isstring(v) && isscalar(v)) || ischar(v)
                s(i) = string(v);
            elseif isnumeric(v) && isscalar(v) && ~isnan(v)
                s(i) = string(v);
            else
                s(i) = string(missing);
            end
        end
    elseif isnumeric(col)
        s = reshape(string(col), [], 1);
        s(isnan(reshape(double(col), [], 1))) = string(missing);   % a column of NULLs
    else
        s = reshape(string(col), [], 1);
    end
end

function s = local_blank(s)
    %LOCAL_BLANK Missing text as "".
    s(ismissing(s)) = "";
end

function x = local_num(col)
    %LOCAL_NUM A fetched numeric column as a double column vector (NULL -> NaN).
    if isnumeric(col) || islogical(col)
        x = double(reshape(col, [], 1));
    elseif iscell(col)
        x = nan(numel(col), 1);
        for i = 1:numel(col)
            v = col{i};
            if (isnumeric(v) || islogical(v)) && isscalar(v)
                x(i) = double(v);
            elseif (isstring(v) && isscalar(v) && ~ismissing(v)) || ischar(v)
                x(i) = double(string(v));
            end
        end
    else
        t = reshape(string(col), [], 1);
        x = nan(numel(t), 1);
        for i = 1:numel(t)
            if ~ismissing(t(i))
                x(i) = double(t(i));
            end
        end
    end
end

function b = local_bool(col)
    %LOCAL_BOOL A fetched boolean column as a logical column vector (NULL -> false).
    if islogical(col)
        b = reshape(col, [], 1);
    elseif isnumeric(col)
        c = double(reshape(col, [], 1));
        b = ~isnan(c) & c ~= 0;
    elseif iscell(col)
        b = false(numel(col), 1);
        for i = 1:numel(col)
            v = col{i};
            if islogical(v) && isscalar(v)
                b(i) = v;
            elseif isnumeric(v) && isscalar(v)
                b(i) = ~isnan(v) && v ~= 0;
            elseif (isstring(v) && isscalar(v)) || ischar(v)
                b(i) = ismember(lower(string(v)), ["t", "true", "1"]);
            end
        end
    else
        t = lower(reshape(string(col), [], 1));
        b = ~ismissing(t) & ismember(t, ["t", "true", "1"]);
    end
end

function t = local_time(col)
    %LOCAL_TIME A fetched timestamp column as a datetime column (NULL -> NaT).
    %   The session zone is the workstation's, so the values are local time.
    if isdatetime(col)
        t = reshape(col, [], 1);
        return
    end
    if iscell(col)
        n = numel(col);
        s = strings(n, 1);
        for i = 1:n
            v = col{i};
            if isdatetime(v) && isscalar(v)
                s(i) = string(v, "yyyy-MM-dd HH:mm:ss");
            elseif (isstring(v) && isscalar(v) && ~ismissing(v)) || ischar(v)
                s(i) = string(v);
            end
        end
    elseif isnumeric(col)
        s = strings(numel(col), 1);          % a column of NULLs
    else
        s = reshape(string(col), [], 1);
        s(ismissing(s)) = "";
    end
    t = NaT(numel(s), 1);
    for i = 1:numel(s)
        if strlength(s(i)) > 0
            try
                t(i) = datetime(s(i));
            catch
                try
                    t(i) = datetime(extractBefore(s(i) + "+", "+"));
                catch
                end
            end
        end
    end
end

function s = local_when(t)
    %LOCAL_WHEN One timestamp as "yyyy-MM-dd HH:mm", "" for NaT.
    if isnat(t)
        s = "";
    else
        s = string(t, "yyyy-MM-dd HH:mm");
    end
end

function s = local_whenCol(t)
    %LOCAL_WHENCOL A timestamp column as "yyyy-MM-dd HH:mm" text ("" for NaT).
    s = strings(numel(t), 1);
    for i = 1:numel(t)
        s(i) = local_when(t(i));
    end
end

function pos = local_geometry(saved, w, h)
    %LOCAL_GEOMETRY The remembered position, kept on a monitor that exists; else centred.
    if isnumeric(saved) && numel(saved) == 4 && all(isfinite(saved(:)))
        pos = local_clampToMonitor(reshape(double(saved), 1, 4));
    else
        su = get(groot, "ScreenSize");
        pos = local_clampToMonitor([max(1, su(3)/2 - w/2), max(1, su(4)/2 - h/2), w, h]);
    end
end

function pos = local_clampToMonitor(pos)
    %LOCAL_CLAMPTOMONITOR Keep a window on a monitor that still exists (as buildUI does).
    mons = get(groot, "MonitorPositions");
    if isempty(mons)
        return
    end
    areas = zeros(size(mons, 1), 1);
    for i = 1:size(mons, 1)
        p = pos;
        m = mons(i, :);
        dx = max(0, min(p(1) + p(3), m(1) + m(3)) - max(p(1), m(1)));
        dy = max(0, min(p(2) + p(4), m(2) + m(4)) - max(p(2), m(2)));
        areas(i) = dx * dy;
    end
    [bestArea, best] = max(areas);
    if bestArea <= 0
        best = 1;
    end
    m = mons(best, :);
    w = min(pos(3), m(3));
    h = min(pos(4), m(4));
    x = min(max(pos(1), m(1)), m(1) + m(3) - w);
    y = min(max(pos(2), m(2)), m(2) + m(4) - h);
    pos = [x, y, w, h];
end
