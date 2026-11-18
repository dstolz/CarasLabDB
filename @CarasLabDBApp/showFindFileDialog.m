function nRecorded = showFindFileDialog(obj, artifactIds, findings)
%SHOWFINDFILEDIALOG Look for missing files by size and checksum, and record where they are.
%
%   n = showFindFileDialog(obj, artifactIds)
%   n = showFindFileDialog(obj, artifactIds, findings)
%
%   Opened from the integrity report (Find files…, Ctrl+F) for the files
%   whose latest check did not find them. ARTIFACTIDS are artifact rows;
%   FINDINGS, when given, is the integrity finding about each (shown as the
%   row's tooltip text in the state column until a search is run).
%
%   Where to look: a storage root, the folder it is mounted at on this
%   computer (filled in from the computer's CarasLabDB client settings when
%   the root is mapped there, labclient.Settings) and, optionally, a folder
%   below it to search instead of the whole root. A folder holding the
%   storage-root marker of another root (.caraslabdb-root.json) is refused.
%
%   Search (Ctrl+F) lists every file below the folder and reads only those
%   whose size in bytes is the recorded size of a missing file, computing
%   their checksum with the missing file's algorithm (sha256 or md5;
%   CarasLabDB.fileChecksum). A file is reported as found only when its
%   checksum is the missing file's. Files with no recorded size, or with a
%   blake3 checksum, are not searched for, and say so. Nothing is written
%   by a search, and files are only read.
%
%   Each result is one row. Select a found file, check "When it moved" and
%   the note, and Record (Ctrl+S); a confirmation lists what will be
%   written, and nothing is written until it is accepted:
%     * found at another path: CarasLabDB.recordArtifactMove -- the row of
%       the file at its new path (its row there if one is registered, else
%       a new row with the same event, checksum, size, role, format,
%       subject, session and attributes), the 'ok' check just made of it,
%       and a 'moved' disposition of the old file, in one transaction;
%     * found at its own path (it came back): one 'ok' check of the file
%       (CarasLabDB.addArtifactVerification), which ends the finding.
%   "When it moved" starts at the first check that did not find the file at
%   its old path (it moved no later than that); the note starts with what is
%   known (where and when it was found, when it was last found at its old
%   path). Both can be changed before recording.
%
%   Returns the number of files recorded. Esc or Close ends the dialog.
%
%   See also CARASLABDBAPP/SHOWINTEGRITYREPORT, CARASLABDB/RECORDARTIFACTMOVE,
%   CARASLABDBAPP/SHOWFILEDISPOSITIONDIALOG, CARASLABDB.FILECHECKSUM.

    arguments
        obj (1,1) CarasLabDBApp
        artifactIds (:,1) string
        findings (:,1) string = repmat("", numel(artifactIds), 1)
    end

    db = obj.Db;
    nRecorded = 0;
    busy = false;
    searchedIn = "";

    % ---- what to look for -------------------------------------------------
    roots = db.getStorageRoots();
    rootIds = reshape(double(roots.root_id), [], 1);
    rootNames = local_text(roots.name);
    targets = local_targets(db, unique(artifactIds, "stable"), artifactIds, findings, ...
        rootIds, rootNames);
    rows = local_initialRows(targets);

    % ---- window -------------------------------------------------------------
    f = uifigure("Name", "Find files by checksum", ...
        "Position", local_center(1120, 620), "WindowStyle", "modal", ...
        "KeyPressFcn", @(~,e) onKey(e));
    g = uigridlayout(f, [7 1]);
    g.RowHeight = {22, 58, 22, '1x', 26, 26, 30};
    g.ColumnWidth = {'1x'};
    g.Padding = [12 12 12 12];
    g.RowSpacing = 6;

    headLbl = uilabel(g, "FontWeight", "bold", "Text", local_heading(targets));

    where = uigridlayout(g, [2 6]);
    where.ColumnWidth = {90, 170, 120, '1x', 80, 90};
    where.RowHeight = {26, 26};
    where.Padding = [0 0 0 0];
    where.RowSpacing = 6;
    uilabel(where, "Text", "Storage root");
    rootItems = rootNames + " (" + string(rootIds) + ")";
    if isempty(rootIds)
        rootDd = uidropdown(where, "Items", {'(no storage roots)'}, "Enable", "off");
    else
        rootDd = uidropdown(where, "Items", cellstr(rootItems), "ItemsData", num2cell(rootIds), ...
            "Value", local_firstRoot(targets, rootIds), ...
            "Tooltip", "The storage root the files are looked for in", ...
            "ValueChangedFcn", @(~,~) onRootChanged());
    end
    uilabel(where, "Text", "Mounted here at", "HorizontalAlignment", "right");
    mountEf = uieditfield(where, "text", "Placeholder", "the folder this storage root is on this computer", ...
        "Tooltip", "Where this storage root is on this computer, e.g. Z:\ or /mnt/nas-main");
    uibutton(where, "Text", "Browse…", "Tooltip", "Choose the folder of the storage root", ...
        "ButtonPushedFcn", @(~,~) onBrowse(mountEf));
    uilabel(where, "Text", "");
    uilabel(where, "Text", "Search in");
    folderEf = uieditfield(where, "text", "Placeholder", "the whole storage root, or a folder below it", ...
        "Tooltip", "Only files below this folder are looked at; empty: the whole storage root");
    folderEf.Layout.Row = 2;
    folderEf.Layout.Column = [2 4];
    b = uibutton(where, "Text", "Browse…", "Tooltip", "Choose a folder below the storage root", ...
        "ButtonPushedFcn", @(~,~) onBrowse(folderEf));
    b.Layout.Row = 2;
    b.Layout.Column = 5;
    b = uibutton(where, "Text", "Search", "Tooltip", "Look for the files (Ctrl+F)", ...
        "ButtonPushedFcn", @(~,~) onSearch());
    b.Layout.Row = 2;
    b.Layout.Column = 6;

    statusLbl = uilabel(g, "FontColor", [0.35 0.35 0.35], "Text", ...
        "Choose where to look, then Search (Ctrl+F). Only files of a missing file's size are read; nothing is written.");

    tbl = uitable(g, "RowName", {}, "ColumnSortable", false, ...
        "SelectionType", "row", "Multiselect", "off", ...
        "CellSelectionCallback", @(~,~) onPick());

    whenRow = uigridlayout(g, [1 4]);
    whenRow.ColumnWidth = {150, 130, 70, '1x'};
    whenRow.Padding = [0 0 0 0];
    uilabel(whenRow, "Text", "When it moved (local)");
    now0 = datetime("now", "TimeZone", "local");
    datePk = uidatepicker(whenRow, "Value", dateshift(now0, "start", "day"), ...
        "DisplayFormat", "yyyy-MM-dd", "Tooltip", "The day the file moved");
    timeEf = uieditfield(whenRow, "text", "Value", char(string(now0, "HH:mm")), ...
        "Tooltip", "The time it moved, HH:mm (24-hour)");
    whenHint = uilabel(whenRow, "FontColor", [0.35 0.35 0.35], "Text", ...
        "Select a found file: this starts at the first check that did not find it at its old path.");

    noteRow = uigridlayout(g, [1 2]);
    noteRow.ColumnWidth = {150, '1x'};
    noteRow.Padding = [0 0 0 0];
    uilabel(noteRow, "Text", "Note (optional)");
    noteEf = uieditfield(noteRow, "text", "Placeholder", "recorded with the move", ...
        "Tooltip", "Stored with the 'moved' disposition");

    foot = uigridlayout(g, [1 4]);
    foot.ColumnWidth = {'1x', 80, 90, 110};
    foot.Padding = [0 0 0 0];
    uilabel(foot, "FontColor", [0.35 0.35 0.35], "Text", ...
        "Record writes only after you confirm what it will write.");
    uibutton(foot, "Text", "Help", "Tooltip", "Keyboard shortcuts (Ctrl+?)", ...
        "ButtonPushedFcn", @(~,~) CarasLabDBApp.showShortcutHelp(f, "findfile"));
    uibutton(foot, "Text", "Close", "Tooltip", "Close (Esc)", ...
        "ButtonPushedFcn", @(~,~) uiresume(f));
    uibutton(foot, "Text", "Record…", "Tooltip", "Record the selected found file (Ctrl+S)", ...
        "ButtonPushedFcn", @(~,~) onRecord());

    onRootChanged();
    showRows();

    uiwait(f);
    if isvalid(f), delete(f); end
    if nRecorded > 0
        obj.pStatus("Recorded where " + string(nRecorded) + " missing file(s) are");
        obj.refreshActiveTab();
    end
    return

    % ---- nested callbacks -------------------------------------------------
    function onKey(e)
        %ONKEY Ctrl+F searches, Ctrl+S records, Esc closes, Ctrl+? lists the shortcuts.
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "findfile");
        elseif key == "escape"
            if ~busy
                uiresume(f);
            end
        elseif key == "f" && ctrl
            onSearch();
        elseif key == "s" && ctrl
            onRecord();
        end
    end

    function onRootChanged()
        %ONROOTCHANGED Fill "Mounted here at" from this computer's mapping of the root.
        if isempty(rootIds)
            return
        end
        name = rootNames(rootIds == rootDd.Value);
        mountEf.Value = char(local_mappedPath(name(1)));
    end

    function onBrowse(field)
        %ONBROWSE Choose a folder for FIELD, starting from what it holds.
        start = string(field.Value);
        if strlength(start) == 0 || ~isfolder(start)
            start = string(mountEf.Value);
        end
        if strlength(start) == 0 || ~isfolder(start)
            start = string(pwd);
        end
        chosen = uigetdir(char(start), "Choose a folder");
        figure(f);
        if ~isequal(chosen, 0)
            field.Value = chosen;
        end
    end

    function showRows()
        %SHOWROWS Put ROWS in the table.
        tbl.Data = local_table(rows, targets, rootIds, rootNames);
        tbl.Selection = [];
        try
            removeStyle(tbl);
            found = find(ismember([rows.Kind], ["hit", "inplace"]) & ~[rows.Done]);
            done = find([rows.Done]);
            if ~isempty(found)
                addStyle(tbl, uistyle("BackgroundColor", [0.85 0.95 0.85]), "row", found);
            end
            if ~isempty(done)
                addStyle(tbl, uistyle("FontColor", [0.45 0.45 0.45]), "row", done);
            end
        catch
            % Colouring is a convenience; the State column says the same.
        end
    end

    function onSearch()
        %ONSEARCH Search (Ctrl+F): list the files below the folder, hash those of a missing size.
        if busy || isempty(rootIds)
            return
        end
        rid = double(rootDd.Value);
        rootName = rootNames(rootIds == rid);
        rootName = rootName(1);
        mount = local_folder(mountEf.Value);
        if ismissing(mount)
            uialert(f, "Say where storage root " + rootName + " is on this computer " + ...
                "(""Mounted here at""): no folder " + string(mountEf.Value) + " here.", "Find files");
            return
        end
        why = local_markerProblem(mount, rootName);
        if strlength(why) > 0
            uialert(f, why, "Find files");
            return
        end
        folder = mount;
        if strlength(strtrim(string(folderEf.Value))) > 0
            folder = local_folder(folderEf.Value);
            if ismissing(folder)
                uialert(f, "No folder " + string(folderEf.Value) + " here.", "Find files");
                return
            end
            if ~startsWith(local_prefix(folder), local_prefix(mount), "IgnoreCase", ispc)
                uialert(f, folder + " is not below " + mount + ", where storage root " + ...
                    rootName + " is: a file found there would have no path in that root.", ...
                    "Find files");
                return
            end
        end
        openRows = find(~[rows.Done] & ismember([rows.Kind], ["pending", "none", "hit", "inplace", "gone"]));
        want = unique([rows(openRows).T]);
        if isempty(want)
            uialert(f, "There is nothing left to look for.", "Find files", "Icon", "info");
            return
        end

        busy = true;
        dlg = uiprogressdlg(f, "Title", "Find files", "Indeterminate", "on", ...
            "Cancelable", "on", "Message", "Listing the files below " + folder + "…");
        cleanup = onCleanup(@() local_close(dlg)); %#ok<NASGU>
        try
            L = dir(fullfile(char(folder), "**", "*"));
            L = L(~[L.isdir]);
            L = L(string({L.name}) ~= ".caraslabdb-root.json");
            sizes = reshape([L.bytes], [], 1);
            paths = strings(numel(L), 1);
            for i = 1:numel(L)
                paths(i) = string(fullfile(L(i).folder, L(i).name));
            end

            % What has to be read: each file once per checksum algorithm.
            need = strings(0, 1);       % "fileIndex|algo"
            for k = want
                if ~isnan(targets(k).Size) && ismember(targets(k).Algo, ["sha256", "md5"])
                    c = find(sizes == targets(k).Size);
                    need = [need; string(c) + "|" + targets(k).Algo]; %#ok<AGROW>
                end
            end
            need = unique(need);
            hashes = containers.Map('KeyType', 'char', 'ValueType', 'any');
            total = 0;
            for j = 1:numel(need)
                total = total + sizes(str2double(extractBefore(need(j), "|")));
            end
            unreadable = strings(0, 1);
            cancelled = false;
            dlg.Indeterminate = "off";
            readSoFar = 0;
            for j = 1:numel(need)
                if dlg.CancelRequested
                    cancelled = true;
                    break
                end
                i = str2double(extractBefore(need(j), "|"));
                algo = extractAfter(need(j), "|");
                dlg.Message = "Reading " + paths(i) + " (" + string(j) + " of " + ...
                    string(numel(need)) + ")";
                dlg.Value = min(1, readSoFar / max(total, 1));
                try
                    h = CarasLabDB.fileChecksum(paths(i), Algo=algo);
                    hashes(char(need(j))) = struct("Hash", h, ...
                        "At", datetime("now", "TimeZone", "local"));
                catch
                    unreadable(end+1) = paths(i); %#ok<AGROW>
                end
                readSoFar = readSoFar + sizes(i);
            end

            % The results, per target looked for.
            keep = rows([rows.Done] | ~ismember([rows.T], want));
            fresh = local_emptyRows();
            for k = want
                t = targets(k);
                if ~t.Active || isnan(t.Size) || ~ismember(t.Algo, ["sha256", "md5"])
                    fresh(end+1) = local_skipRow(k, t); %#ok<AGROW>
                    continue
                end
                hits = 0;
                for i = reshape(find(sizes == t.Size), 1, [])
                    key = char(string(i) + "|" + t.Algo);
                    if ~isKey(hashes, key)
                        continue
                    end
                    hv = hashes(key);
                    if hv.Hash ~= t.Checksum
                        continue
                    end
                    hits = hits + 1;
                    rel = local_relative(paths(i), mount);
                    r = local_row(k, "hit", "");
                    r.Abs = paths(i);
                    r.Rel = rel;
                    r.RootId = rid;
                    r.Hash = hv.Hash;
                    r.HashedAt = hv.At;
                    if rid == t.RootId && (rel == t.Rel || (ispc && strcmpi(rel, t.Rel)))
                        r.Kind = "inplace";
                        r.State = "found at its own path: Record adds the 'ok' check";
                    else
                        r = local_registration(db, r, t);
                    end
                    fresh(end+1) = r; %#ok<AGROW>
                end
                if hits == 0
                    r = local_row(k, "none", "");
                    if cancelled
                        r.State = "search cancelled before every candidate was read";
                    else
                        r.State = "not found below " + folder;
                    end
                    fresh(end+1) = r; %#ok<AGROW>
                end
            end
            rows = local_sortRows([keep, fresh]);
            searchedIn = folder;
        catch searchErr
            busy = false;
            uialert(f, string(searchErr.message), "Search failed");
            return
        end
        busy = false;
        showRows();
        nFound = nnz(ismember([rows.Kind], ["hit", "inplace"]) & ~[rows.Done]);
        note = string(numel(L)) + " file(s) below " + searchedIn + "; " + ...
            string(numel(need)) + " of a missing file's size read; " + ...
            string(nFound) + " found.";
        if cancelled
            note = note + " Cancelled before the end.";
        end
        if ~isempty(unreadable)
            note = note + " " + string(numel(unreadable)) + " could not be read (e.g. " + ...
                unreadable(1) + ").";
        end
        statusLbl.Text = note;
        statusLbl.Tooltip = note;
    end

    function onPick()
        %ONPICK A found file was selected: start "When" and the note from what is known.
        r = local_selected(tbl);
        if r == 0 || r > numel(rows) || ~ismember(rows(r).Kind, ["hit", "inplace"]) || rows(r).Done
            return
        end
        t = targets(rows(r).T);
        if rows(r).Kind == "inplace"
            whenHint.Text = "It is at its own path: nothing moved, so this is not used.";
            return
        end
        if isnat(t.GoneSince)
            at = datetime("now", "TimeZone", "local");
            whenHint.Text = "No check has missed it: say when it moved.";
        else
            at = t.GoneSince;
            whenHint.Text = "Starts at the first check that did not find it (" + ...
                local_when(t.GoneSince) + "): it moved no later than that.";
        end
        datePk.Value = dateshift(at, "start", "day");
        timeEf.Value = char(string(at, "HH:mm"));
        noteEf.Value = char(local_suggestedNote(rows(r), t, rootIds, rootNames));
    end

    function onRecord()
        %ONRECORD Record (Ctrl+S): write where the selected found file is, after a confirmation.
        if busy
            return
        end
        r = local_selected(tbl);
        if r == 0 || r > numel(rows) || ~ismember(rows(r).Kind, ["hit", "inplace"]) || rows(r).Done
            uialert(f, "Select a found file first (a green row).", "Record");
            return
        end
        row = rows(r);
        t = targets(row.T);
        from = local_place(t.RootId, t.Rel, rootIds, rootNames);
        to = local_place(row.RootId, row.Rel, rootIds, rootNames);
        if row.Kind == "inplace"
            question = "The file of artifact " + t.Id + " is at its own path again, " + from + ...
                ", with its bytes (checked " + local_when(row.HashedAt) + ")." + newline + newline + ...
                "Record writes one 'ok' check of the file. Nothing else changes.";
        else
            at = local_when_from(datePk.Value, timeEf.Value);
            if isnat(at)
                uialert(f, "Give the time as HH:mm, e.g. 14:05, and pick a day.", "Record");
                return
            end
            if strlength(row.Registered) > 0
                newRow = "its row there, artifact " + row.Registered;
            else
                newRow = "a new artifact row for it there: same event, checksum, size, " + ...
                    "role, format, subject, session and attributes";
            end
            question = "Record that the file of artifact " + t.Id + " moved." + newline + ...
                "From: " + from + newline + "To:   " + to + newline + newline + ...
                "This writes, in one transaction:" + newline + ...
                "  • " + newRow + ";" + newline + ...
                "  • the check just made of it there: ok (" + local_when(row.HashedAt) + ");" + newline + ...
                "  • a 'moved' disposition of the old file, " + local_when(at) + "." + newline + newline + ...
                "The old row stays active and keeps its lineage; its file is no longer " + ...
                "expected at the old path.";
        end
        answer = uiconfirm(f, question, "Record", "Options", {'Record', 'Cancel'}, ...
            "DefaultOption", 2, "CancelOption", 2);
        if string(answer) ~= "Record"
            return
        end

        busy = true;
        try
            if row.Kind == "inplace"
                db.addArtifactVerification(ArtifactId=t.Id, Status="ok", ...
                    ObservedChecksum=row.Hash, VerifiedAt=row.HashedAt);
                state = "recorded: checked ok at its own path";
            else
                note = strtrim(string(noteEf.Value));
                if strlength(note) == 0
                    note = string(missing);
                end
                out = db.recordArtifactMove(t.Id, StorageRootId=row.RootId, ...
                    RelativePath=row.Rel, OccurredAt=at, ObservedChecksum=row.Hash, ...
                    VerifiedAt=row.HashedAt, Note=note);
                state = "recorded: moved to " + to + " (artifact " + out.SuccessorArtifactId + ")";
            end
        catch saveErr
            busy = false;
            uialert(f, string(saveErr.message), "Not recorded");
            return
        end
        busy = false;
        nRecorded = nRecorded + 1;
        for j = find([rows.T] == row.T)
            rows(j).Done = true;
            if j == r
                rows(j).State = state;
            else
                rows(j).State = "the file is recorded (another row)";
            end
        end
        % A file just registered at a path is now the row there for any other
        % missing file with the same bytes.
        for j = find(~[rows.Done] & [rows.Kind] == "hit")
            rows(j) = local_registration(db, rows(j), targets(rows(j).T));
        end
        showRows();
        statusLbl.Text = "Recorded the file of artifact " + t.Id + ".";
    end
end

% =============================================================================
function targets = local_targets(db, ids, allIds, findings, rootIds, rootNames)
    %LOCAL_TARGETS The files to look for, with what the database knows of each.
    targets = struct("Id", {}, "Active", {}, "RootId", {}, "RootName", {}, "Rel", {}, ...
        "Checksum", {}, "Algo", {}, "Size", {}, "Finding", {}, "GoneSince", {}, ...
        "LastSeen", {}, "Created", {});
    for k = 1:numel(ids)
        t = struct("Id", ids(k), "Active", false, "RootId", NaN, "RootName", "", "Rel", "", ...
            "Checksum", "", "Algo", "", "Size", NaN, "Finding", "", ...
            "GoneSince", NaT("TimeZone", "local"), "LastSeen", NaT("TimeZone", "local"), ...
            "Created", NaT("TimeZone", "local"));
        hit = find(allIds == ids(k), 1);
        if ~isempty(hit) && hit <= numel(findings)
            t.Finding = findings(hit);
        end
        A = db.getArtifacts(ArtifactId=ids(k), ActiveOnly=true);
        if height(A) > 0
            t.Active = true;
            t.RootId = double(A.storage_root_id(1));
            name = rootNames(rootIds == t.RootId);
            if ~isempty(name)
                t.RootName = name(1);
            end
            t.Rel = local_text(A.relative_path(1));
            t.Checksum = lower(strtrim(local_text(A.checksum(1))));
            t.Algo = local_text(A.checksum_algo(1));
            t.Size = local_num(A.size_bytes(1));
            t.Created = local_time(A.created_at(1));
            [t.GoneSince, t.LastSeen] = local_history(db, ids(k));
        end
        targets(end+1) = t; %#ok<AGROW>
    end
end

function [goneSince, lastSeen] = local_history(db, id)
    %LOCAL_HISTORY When the file's checks stopped finding it, and when one last did.
    %   From the checks of the file (every row describing it), newest
    %   first: GONESINCE is the oldest of the latest unbroken run of checks
    %   that did not find it, LASTSEEN the 'ok' check before that run. NaT
    %   for what the history does not say.
    goneSince = NaT("TimeZone", "local");
    lastSeen = NaT("TimeZone", "local");
    try
        V = db.getArtifactVerifications(ArtifactId=id, ByFile=true);
    catch
        return
    end
    if height(V) == 0
        return
    end
    status = local_text(V.status);
    at = local_time(V.verified_at);
    k = 1;
    while k <= numel(status) && status(k) ~= "ok"
        k = k + 1;
    end
    if k > 1
        goneSince = at(k - 1);
    end
    if k <= numel(status)
        lastSeen = at(k);
    end
end

function rows = local_emptyRows()
    rows = struct("T", {}, "Kind", {}, "State", {}, "Abs", {}, "Rel", {}, "RootId", {}, ...
        "Registered", {}, "Hash", {}, "HashedAt", {}, "Done", {});
end

function r = local_row(k, kind, state)
    %LOCAL_ROW One result row about target K.
    r = struct("T", k, "Kind", string(kind), "State", string(state), "Abs", "", "Rel", "", ...
        "RootId", NaN, "Registered", "", "Hash", "", "HashedAt", NaT("TimeZone", "local"), ...
        "Done", false);
end

function rows = local_initialRows(targets)
    %LOCAL_INITIALROWS One row per target before any search.
    rows = local_emptyRows();
    for k = 1:numel(targets)
        t = targets(k);
        if ~t.Active || isnan(t.Size) || ~ismember(t.Algo, ["sha256", "md5"])
            rows(end+1) = local_skipRow(k, t); %#ok<AGROW>
        else
            rows(end+1) = local_row(k, "pending", "not searched yet"); %#ok<AGROW>
        end
    end
end

function r = local_skipRow(k, t)
    %LOCAL_SKIPROW The row of a target that cannot be looked for by size and checksum.
    if ~t.Active
        r = local_row(k, "skip", "not an active row any more: nothing to look for");
    elseif isnan(t.Size)
        r = local_row(k, "skip", "no size recorded: not searched (files are matched by size first)");
    else
        r = local_row(k, "skip", "checksum algorithm " + t.Algo + " cannot be computed here: not searched");
    end
end

function r = local_registration(db, r, t)
    %LOCAL_REGISTRATION Whether the bytes found at R's path are registered there already.
    r.Kind = "hit";
    r.Registered = "";
    there = db.getArtifacts(StorageRootId=r.RootId, RelativePath=r.Rel, Checksum=t.Checksum, ...
        ActiveOnly=true);
    if height(there) == 0
        r.State = "found: Record registers it here and records the move";
        return
    end
    present = db.getArtifacts(StorageRootId=r.RootId, RelativePath=r.Rel, Checksum=t.Checksum, ...
        PresentOnly=true);
    if height(present) == 0
        r.Kind = "gone";
        r.State = "found, but artifact " + local_text(there.artifact_id(1)) + " for it here is " + ...
            "recorded as gone: record it restored first (File… in the integrity report)";
        return
    end
    r.Registered = local_text(present.artifact_id(1));
    r.State = "found, registered here as artifact " + r.Registered + ": Record records the move";
end

function rows = local_sortRows(rows)
    %LOCAL_SORTROWS Rows in target order, found files first within a target.
    if isempty(rows)
        return
    end
    rank = 4 * ones(1, numel(rows));
    rank([rows.Kind] == "hit" | [rows.Kind] == "inplace") = 1;
    rank([rows.Kind] == "gone") = 2;
    rank([rows.Kind] == "none" | [rows.Kind] == "pending") = 3;
    [~, order] = sortrows([[rows.T]; rank]');
    rows = rows(order);
end

function T = local_table(rows, targets, rootIds, rootNames)
    %LOCAL_TABLE ROWS as the display table.
    n = numel(rows);
    art = strings(n, 1);
    file = strings(n, 1);
    bytes = strings(n, 1);
    found = strings(n, 1);
    reg = strings(n, 1);
    state = strings(n, 1);
    for j = 1:n
        t = targets(rows(j).T);
        art(j) = t.Id;
        if t.Active
            file(j) = local_place(t.RootId, t.Rel, rootIds, rootNames);
        end
        if ~isnan(t.Size)
            bytes(j) = string(sprintf("%d", t.Size));
        end
        if strlength(rows(j).Rel) > 0
            found(j) = local_place(rows(j).RootId, rows(j).Rel, rootIds, rootNames);
        end
        reg(j) = rows(j).Registered;
        state(j) = rows(j).State;
        if rows(j).Kind == "pending" && strlength(t.Finding) > 0
            state(j) = state(j) + " · " + t.Finding;
        end
    end
    T = table(art, file, bytes, found, reg, state, 'VariableNames', ...
        {'Artifact', 'Missing file', 'Bytes', 'Found at', 'Registered as', 'State'});
end

function s = local_heading(targets)
    %LOCAL_HEADING The first line: how many files are looked for.
    n = numel(targets);
    if n == 1
        s = "Looking for the file of artifact " + targets(1).Id + " by its size and checksum.";
    else
        s = "Looking for " + string(n) + " files by their size and checksum.";
    end
end

function v = local_firstRoot(targets, rootIds)
    %LOCAL_FIRSTROOT The storage root to look in first: the first target's.
    v = rootIds(1);
    for k = 1:numel(targets)
        if targets(k).Active && any(rootIds == targets(k).RootId)
            v = targets(k).RootId;
            return
        end
    end
end

function s = local_place(rootId, rel, rootIds, rootNames)
    %LOCAL_PLACE A file's place as "root:relative/path".
    name = rootNames(rootIds == rootId);
    if isempty(name)
        name = "root " + string(rootId);
    else
        name = name(1);
    end
    s = name + ":" + rel;
end

function s = local_suggestedNote(row, t, rootIds, rootNames)
    %LOCAL_SUGGESTEDNOTE The note a move starts with: what is known, nothing assumed.
    s = "Found by its checksum at " + local_place(row.RootId, row.Rel, rootIds, rootNames) + ...
        " on " + string(row.HashedAt, "yyyy-MM-dd") + ".";
    if ~isnat(t.LastSeen)
        s = s + " Last found at its old path " + local_when(t.LastSeen) + ".";
    else
        s = s + " Never checked ok at its old path (registered " + local_when(t.Created) + ").";
    end
    if ~isnat(t.GoneSince)
        s = s + " Not found there from " + local_when(t.GoneSince) + ".";
    end
end

function at = local_when_from(day, hhmm)
    %LOCAL_WHEN_FROM The date picker's day and an HH:mm text as a local datetime (NaT if invalid).
    at = NaT("TimeZone", "local");
    hm = regexp(char(strtrim(string(hhmm))), '^(\d{1,2}):(\d{2})$', 'tokens', 'once');
    if isempty(hm) || str2double(hm{1}) > 23 || str2double(hm{2}) > 59 || isnat(day)
        return
    end
    day.TimeZone = "local";
    at = dateshift(day, "start", "day") + hours(str2double(hm{1})) + minutes(str2double(hm{2}));
end

function s = local_when(t)
    %LOCAL_WHEN A datetime as "yyyy-MM-dd HH:mm" (local), "" for NaT.
    if isnat(t)
        s = "";
        return
    end
    if isempty(t.TimeZone)
        t.TimeZone = "local";
    end
    t.TimeZone = "local";
    s = string(t, "yyyy-MM-dd HH:mm");
end

function r = local_selected(tbl)
    %LOCAL_SELECTED The selected table row, 0 when none.
    r = 0;
    sel = tbl.Selection;
    if ~isempty(sel) && isnumeric(sel)
        r = sel(1);
    end
end

function p = local_mappedPath(rootName)
    %LOCAL_MAPPEDPATH Where this computer's client settings say ROOTNAME is ("" if not mapped).
    p = "";
    try
        s = labclient.Settings.load();
        p = string(labclient.Roots.resolve(rootName, "", s));
    catch
        p = "";
    end
end

function why = local_markerProblem(folder, rootName)
    %LOCAL_MARKERPROBLEM Why FOLDER cannot be storage root ROOTNAME, "" when it can.
    %   The marker file at the top of a storage root (labclient.Roots) names
    %   the root; a folder whose marker names another root is refused, so a
    %   mistyped drive letter cannot file a found file under the wrong root.
    why = "";
    marker = fullfile(char(folder), '.caraslabdb-root.json');
    if ~isfile(marker)
        return
    end
    try
        m = jsondecode(fileread(marker));
        name = string(m.name);
    catch
        why = "The storage-root marker " + string(marker) + " cannot be read.";
        return
    end
    if name ~= rootName
        why = "The folder " + folder + " is storage root " + name + ", not " + rootName + ...
            " (its .caraslabdb-root.json says so). Choose the folder of " + rootName + ".";
    end
end

function p = local_folder(name)
    %LOCAL_FOLDER The absolute path of an existing folder (on Windows as spelled on disk), or missing.
    p = string(missing);
    name = strtrim(string(name));
    if isempty(name) || ismissing(name) || strlength(name) == 0
        return
    end
    [ok, a] = fileattrib(char(name));
    if ~ok || ~isstruct(a) || ~isscalar(a) || ~a.directory
        return
    end
    p = string(a.Name);
    if ispc && usejava('jvm')
        try
            javaFile = java.io.File(char(p));
            p = string(char(javaFile.getCanonicalPath()));
        catch
            % keep the path as fileattrib reported it
        end
    end
end

function p = local_prefix(folder)
    %LOCAL_PREFIX FOLDER with one trailing separator.
    p = folder;
    if ~endsWith(p, filesep)
        p = p + filesep;
    end
end

function rel = local_relative(path, mount)
    %LOCAL_RELATIVE PATH below the folder MOUNT, with '/' separators.
    rel = extractAfter(path, strlength(local_prefix(mount)));
    if ispc
        rel = replace(rel, "\", "/");
    end
end

function local_close(dlg)
    if isvalid(dlg)
        close(dlg);
    end
end

function s = local_text(col)
    %LOCAL_TEXT A fetched text value or column as a string column ("" for NULL).
    if iscell(col)
        s = strings(numel(col), 1);
        for i = 1:numel(col)
            v = col{i};
            if (isstring(v) && isscalar(v)) || ischar(v)
                s(i) = string(v);
            end
        end
    else
        s = reshape(string(col), [], 1);
    end
    s(ismissing(s)) = "";
end

function v = local_num(x)
    %LOCAL_NUM A fetched number as a double, NaN for NULL.
    if iscell(x)
        x = x{1};
    end
    if isempty(x) || (isstring(x) && ismissing(x))
        v = NaN;
    else
        v = double(x);
    end
    if ~isscalar(v)
        v = NaN;
    end
end

function t = local_time(col)
    %LOCAL_TIME A fetched timestamp column as local datetimes (the session zone is local).
    if isdatetime(col)
        t = reshape(col, [], 1);
    else
        s = local_text(col);
        t = NaT(numel(s), 1);
        for i = 1:numel(s)
            if strlength(s(i)) > 0
                try
                    t(i) = datetime(s(i));
                catch
                end
            end
        end
    end
    if isempty(t.TimeZone)
        t.TimeZone = "local";
    end
end

function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [su(3)/2 - w/2, su(4)/2 - h/2, w, h];
end
