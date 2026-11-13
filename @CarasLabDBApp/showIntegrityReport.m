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
%   front. It reads only; nothing here writes to the database.
%
%   See also CARASLABDB/CHECKINTEGRITY, CARASLABDBAPP/SHOWRETRACTDIALOG.

    arguments
        obj (1,1) CarasLabDBApp
    end

    WINDOW_TAG = "CarasLabDBApp:integrity";
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

    foot = uigridlayout(g, [1 4]);
    foot.ColumnWidth = {'1x', 90, 80, 90};
    foot.Padding = [0 0 0 0];
    uilabel(foot, "Text", "Errors first. Select a row to read the whole finding.", ...
        "FontColor", [0.35 0.35 0.35]);
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
        %ONKEY Ctrl+R runs the check again, Esc closes, Ctrl+? lists the shortcuts.
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "integrity");
        elseif key == "escape"
            delete(f);
        elseif key == "r" && ctrl
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
