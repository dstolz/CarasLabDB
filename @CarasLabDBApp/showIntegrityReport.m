function showIntegrityReport(obj)
%SHOWINTEGRITYREPORT Show the database's integrity report, errors first (Ctrl+I).
%
%   showIntegrityReport(obj)
%
%   Runs CarasLabDB.checkIntegrity, i.e. lab.fn_check_integrity(), and lists
%   its findings in a table -- severity, check, subject (the id the finding
%   is about) and detail -- sorted with errors first, then warnings, then
%   anything else, and by check within each. Selecting a row shows the whole
%   finding in the box underneath, where the id can be selected and copied
%   (for example into a filter of the main window). An empty report means
%   the database is consistent.
%
%   The window is not modal: it can stay open next to the main window while
%   the findings are dealt with, and Refresh (Ctrl+R) runs the check again.
%   Opening the report while one is already open brings that window to the
%   front. The report itself writes nothing; two actions open the dialogs
%   that do, and the report runs the check again after either records
%   something:
%
%     File… (Ctrl+Shift+F)  for a finding about one artifact's file
%                           (artifact_verification_failed,
%                           artifact_never_verified, disposed_file_found):
%                           record what became of the file -- deleted,
%                           moved, replaced, restored
%                           (CARASLABDBAPP/SHOWFILEDISPOSITIONDIALOG).
%     Find files… (Ctrl+F)  look for missing files by size and checksum
%                           and record where they are
%                           (CARASLABDBAPP/SHOWFINDFILEDIALOG): the file of
%                           the selected finding when it is
%                           artifact_verification_failed or
%                           artifact_never_verified, otherwise every file
%                           of an artifact_verification_failed finding.
%
%   See also CARASLABDB/CHECKINTEGRITY, CARASLABDBAPP/SHOWRETRACTDIALOG,
%   CARASLABDBAPP/SHOWFILEDISPOSITIONDIALOG, CARASLABDBAPP/SHOWFINDFILEDIALOG.

    arguments
        obj (1,1) CarasLabDBApp
    end

    WINDOW_TAG = "CarasLabDBApp:integrity";
    % Findings whose subject is one artifact and that are about its file.
    FILE_CHECKS = ["artifact_verification_failed", "artifact_never_verified", ...
                   "disposed_file_found"];
    % Of those, the ones whose file may be missing, so worth looking for.
    FIND_CHECKS = ["artifact_verification_failed", "artifact_never_verified"];
    old = findall(groot, "Type", "figure", "Tag", WINDOW_TAG);
    if ~isempty(old)
        figure(old(1));                 % one report window: bring it forward
        return
    end

    db = obj.Db;
    rowText = strings(0, 1);            % the full text of each listed finding

    f = uifigure("Name", "Integrity report", "Tag", WINDOW_TAG, ...
        "Position", local_center(1000, 580), ...
        "KeyPressFcn", @(~,e) onKey(e));
    g = uigridlayout(f, [4 1]);
    g.RowHeight = {22, '1x', 80, 30};
    g.ColumnWidth = {'1x'};
    g.Padding = [10 10 10 10];
    g.RowSpacing = 6;

    headLbl = uilabel(g, "Text", "Checking…", "FontWeight", "bold");
    tbl = uitable(g, "RowName", {}, "ColumnSortable", false, ...
        "SelectionType", "row", "Multiselect", "off", ...
        "CellSelectionCallback", @(~,e) onPick(e));
    detail = uitextarea(g, "Editable", "off", "Value", {''}, ...
        "Tooltip", "The selected finding in full; the text can be selected and copied");

    foot = uigridlayout(g, [1 6]);
    foot.ColumnWidth = {'1x', 80, 110, 90, 80, 90};
    foot.Padding = [0 0 0 0];
    uilabel(foot, "Text", "Errors first. Select a row to read the whole finding.", ...
        "FontColor", [0.35 0.35 0.35]);
    uibutton(foot, "Text", "File…", "Tooltip", ...
        "Record what became of the file of the selected finding: deleted, moved, " + ...
        "replaced, restored (Ctrl+Shift+F)", ...
        "ButtonPushedFcn", @(~,~) onDisposition());
    uibutton(foot, "Text", "Find files…", "Tooltip", ...
        "Look for missing files by size and checksum: the selected finding's file, " + ...
        "or with no such finding selected every file whose latest check failed (Ctrl+F)", ...
        "ButtonPushedFcn", @(~,~) onFind());
    uibutton(foot, "Text", "Refresh", "Tooltip", "Run the check again (Ctrl+R)", ...
        "ButtonPushedFcn", @(~,~) reload());
    uibutton(foot, "Text", "Help", "Tooltip", "Keyboard shortcuts (Ctrl+?)", ...
        "ButtonPushedFcn", @(~,~) CarasLabDBApp.showShortcutHelp(f, "integrity"));
    uibutton(foot, "Text", "Close", "Tooltip", "Close (Esc)", ...
        "ButtonPushedFcn", @(~,~) delete(f));

    reload();
    return

    % ---- nested callbacks -------------------------------------------------
    function onKey(e)
        %ONKEY Ctrl+R runs the check again, Ctrl+Shift+F the file's disposition,
        %   Ctrl+F finds files, Esc closes, Ctrl+? lists the shortcuts.
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        shift = any(mods == "shift");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "integrity");
        elseif key == "escape"
            delete(f);
        elseif key == "r" && ctrl
            reload();
        elseif key == "f" && ctrl && shift
            onDisposition();
        elseif key == "f" && ctrl
            onFind();
        end
    end

    function [check, about, detailText] = picked()
        %PICKED The selected finding's check, subject and detail ("" when none).
        %   The table is not sortable, so the selected row is the row of Data.
        check = "";
        about = "";
        detailText = "";
        sel = tbl.Selection;
        data = tbl.Data;
        if isempty(sel) || ~isnumeric(sel) || ~istable(data) || sel(1) < 1 || sel(1) > height(data)
            return
        end
        check = string(data.Check(sel(1)));
        about = string(data.Subject(sel(1)));
        detailText = string(data.Detail(sel(1)));
    end

    function onDisposition()
        %ONDISPOSITION File… (Ctrl+Shift+F): what became of the selected finding's file.
        [check, about] = picked();
        if strlength(check) == 0
            uialert(f, "Select a finding about a file first.", "File disposition");
            return
        end
        if ~ismember(check, FILE_CHECKS)
            uialert(f, "A file's disposition is recorded from a finding about one " + ...
                "artifact's file: " + strjoin(FILE_CHECKS, ", ") + ". The selected " + ...
                "finding is " + check + ".", "File disposition");
            return
        end
        saved = obj.showFileDispositionDialog(about);
        if saved && isvalid(f)
            reload();
        end
    end

    function onFind()
        %ONFIND Find files… (Ctrl+F): look for missing files by size and checksum.
        [check, about, detailText] = picked();
        if ismember(check, FIND_CHECKS)
            ids = about;
            found = check + ": " + detailText;
        else
            data = tbl.Data;
            failed = istable(data) && height(data) > 0;
            if failed
                failed = string(data.Check) == "artifact_verification_failed";
            end
            if ~any(failed)
                uialert(f, "No finding says that a file is missing or changed " + ...
                    "(artifact_verification_failed), so there is nothing to look for. " + ...
                    "To look for one file, select its finding.", "Find files", "Icon", "info");
                return
            end
            ids = reshape(string(data.Subject(failed)), [], 1);
            found = reshape("artifact_verification_failed: " + string(data.Detail(failed)), [], 1);
        end
        try
            n = obj.showFindFileDialog(ids, found);
        catch findErr
            if isvalid(f)
                uialert(f, string(findErr.message), "Find files");
            end
            return
        end
        if n > 0 && isvalid(f)
            reload();
        end
    end

    function reload()
        %RELOAD Run the check and list what it found.
        headLbl.Text = "Checking…";
        drawnow;
        try
            R = db.checkIntegrity();
        catch checkErr
            if isvalid(f)
                headLbl.Text = "The integrity check could not be run.";
                uialert(f, string(checkErr.message), "Integrity check failed");
            end
            return
        end
        if ~isvalid(f)
            return                      % closed while the check ran
        end
        [listed, rowText, nErr, nWarn, nOther] = local_arrange(R);
        tbl.Data = listed;
        tbl.Selection = [];
        detail.Value = {''};
        try
            removeStyle(tbl);
            sev = lower(string(listed.Severity));
            iErr = find(sev == "error");
            iWarn = find(sev == "warning");
            if ~isempty(iErr)
                addStyle(tbl, uistyle("BackgroundColor", [1.00 0.85 0.85]), "row", iErr);
            end
            if ~isempty(iWarn)
                addStyle(tbl, uistyle("BackgroundColor", [1.00 0.95 0.75]), "row", iWarn);
            end
        catch
            % Colouring is a convenience; the Severity column says the same.
        end
        checkedAt = string(datetime("now"), "yyyy-MM-dd HH:mm:ss");
        if height(listed) == 0
            headLbl.Text = "No findings: the database is consistent. Checked " + checkedAt + ".";
        else
            note = string(nErr) + " error(s) · " + string(nWarn) + " warning(s)";
            if nOther > 0
                note = note + " · " + string(nOther) + " other";
            end
            headLbl.Text = note + " · checked " + checkedAt;
        end
    end

    function onPick(e)
        %ONPICK Show the selected finding in full, so its id can be copied.
        if isempty(e.Indices) || isempty(rowText)
            return
        end
        r = e.Indices(1, 1);
        if r < 1 || r > numel(rowText)
            return
        end
        detail.Value = cellstr(splitlines(rowText(r)));
    end
end

% =============================================================================
function [T, fullText, nErr, nWarn, nOther] = local_arrange(R)
    %LOCAL_ARRANGE The findings as a display table, errors first.
    %   R is checkIntegrity's table (severity, check_name, subject, detail).
    %   FULLTEXT holds, per listed row, the finding written out in full.
    cols = {'Severity', 'Check', 'Subject', 'Detail'};
    fullText = strings(0, 1);
    nErr = 0;
    nWarn = 0;
    nOther = 0;
    if ~istable(R) || height(R) == 0
        T = table('Size', [0 4], 'VariableTypes', repmat({'string'}, 1, 4), ...
            'VariableNames', cols);
        return
    end
    sev    = local_blank(local_text(R.severity));
    check  = local_blank(local_text(R.check_name));
    about  = local_blank(local_text(R.subject));
    detail = local_blank(local_text(R.detail));

    rank = 3 * ones(numel(sev), 1);
    rank(lower(sev) == "warning") = 2;
    rank(lower(sev) == "error") = 1;
    [~, order] = sortrows(table(rank, check, about));
    sev = sev(order);
    check = check(order);
    about = about(order);
    detail = detail(order);
    rank = rank(order);

    nErr = nnz(rank == 1);
    nWarn = nnz(rank == 2);
    nOther = nnz(rank == 3);
    T = table(sev, check, about, detail, 'VariableNames', cols);
    fullText = sev + ": " + check + newline + about + newline + detail;
end

function s = local_text(col)
    %LOCAL_TEXT A fetched text column as a string column vector (NULL -> missing).
    if iscell(col)
        s = strings(numel(col), 1);
        for i = 1:numel(col)
            v = col{i};
            if (isstring(v) && isscalar(v)) || ischar(v)
                s(i) = string(v);
            else
                s(i) = string(missing);
            end
        end
    else
        s = reshape(string(col), [], 1);
    end
end

function s = local_blank(s)
    %LOCAL_BLANK Missing text shown as "".
    s(ismissing(s)) = "";
end

function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [su(3)/2 - w/2, su(4)/2 - h/2, w, h];
end
