function buildUI(obj)
%BUILDUI Construct the main window: toolbar, filter panel, tabs and tables.
%
%   Applies remembered geometry and the active-view toggle from preferences,
%   builds the four browse tabs (Subjects/Sessions/Events/Artifacts) plus the
%   Custom SQL tab, wires callbacks, and selects the last-used tab.
%
%   All obj-touching construction is done here in the primary method (a class
%   method with access to private members and permission to reference the
%   restricted callbacks); only obj-free geometry helpers are local functions.
%
%   See also CARASLABDBAPP, CARASLABDBAPP/REFRESHACTIVETAB.

    obj.TabKeys = ["subjects", "sessions", "events", "artifacts"];

    % ---- main figure --------------------------------------------------------
    pos = obj.Prefs.Geometry;
    if isempty(pos) || numel(pos) ~= 4
        pos = local_center(1180, 720);
    else
        pos = local_clampToMonitor(reshape(double(pos), 1, 4));
    end
    obj.Fig = uifigure("Name", "CarasLabDB Explorer", "Position", pos, ...
        "CloseRequestFcn", @(s,e) obj.pOnClose(s,e), ...
        "KeyPressFcn", @(s,e) obj.onKeyPress(s,e));

    root = uigridlayout(obj.Fig, [3 1]);
    root.RowHeight = {40, '1x', 24};
    root.ColumnWidth = {'1x'};
    root.RowSpacing = 4;
    root.Padding = [6 6 6 6];

    % ---- toolbar ------------------------------------------------------------
    tb = uigridlayout(root, [1 8]);
    tb.Layout.Row = 1; tb.Layout.Column = 1;
    tb.ColumnWidth = {90, 120, 100, 110, 110, 150, '1x', 130};
    tb.Padding = [0 0 0 0];

    uibutton(tb, "Text", "Refresh", "Tooltip", "Refresh (Ctrl+R)", ...
        "ButtonPushedFcn", @(s,e) obj.onRefresh(s,e));
    uibutton(tb, "Text", "Export → WS", "Tooltip", "Export → Workspace (Ctrl+E)", ...
        "ButtonPushedFcn", @(s,e) obj.onExport(s,e));
    uibutton(tb, "Text", "Add Event", "Tooltip", "Add Event (Ctrl+Shift+E)", ...
        "ButtonPushedFcn", @(~,~) obj.onAddMenu("event"));
    uibutton(tb, "Text", "Add Subject", "Tooltip", "Add Subject (Ctrl+Shift+S)", ...
        "ButtonPushedFcn", @(~,~) obj.onAddMenu("subject"));
    uibutton(tb, "Text", "Add Session", "Tooltip", "Add Session (Ctrl+Shift+N)", ...
        "ButtonPushedFcn", @(~,~) obj.onAddMenu("session"));
    uibutton(tb, "Text", "Edit / Supersede", "Tooltip", "Edit / Supersede (Ctrl+D)", ...
        "ButtonPushedFcn", @(s,e) obj.onEditSelected(s,e));
    uilabel(tb, "Text", "");   % spacer
    obj.UI.ActiveOnly = uicheckbox(tb, "Text", "Active only", ...
        "Value", logical(obj.Prefs.UseActiveViews), ...
        "ValueChangedFcn", @(s,e) obj.onRefresh(s,e));

    % ---- body: filter panel | tab group ------------------------------------
    body = uigridlayout(root, [1 2]);
    body.Layout.Row = 2; body.Layout.Column = 1;
    body.ColumnWidth = {330, '1x'};
    body.Padding = [0 0 0 0];
    body.ColumnSpacing = 6;

    % ---- filter panel -------------------------------------------------------
    panel = uipanel(body, "Title", "Search & Filter");
    panel.Layout.Row = 1; panel.Layout.Column = 1;

    nRows = obj.NumFilterRows;
    fg = uigridlayout(panel, [nRows + 4, 1]);
    fg.RowHeight = [{28, 30, 22}, repmat({30}, 1, nRows), {34}];
    fg.ColumnWidth = {'1x'};
    fg.RowSpacing = 5;
    fg.Padding = [8 8 8 8];

    uilabel(fg, "Text", "Quick subject search", "FontWeight", "bold");

    qrow = uigridlayout(fg, [1 2]);
    qrow.ColumnWidth = {'1x', 80};
    qrow.Padding = [0 0 0 0];
    obj.UI.QuickSearch = uieditfield(qrow, "text", ...
        "Placeholder", "subject_id contains…", ...
        "ValueChangedFcn", @(s,e) obj.onRefresh(s,e));
    obj.UI.QuickRegex = uicheckbox(qrow, "Text", "regex", ...
        "ValueChangedFcn", @(s,e) obj.onRefresh(s,e));

    uilabel(fg, "Text", "Column filters (all ANDed)", "FontWeight", "bold");

    modes = {'Exact', 'Contains', 'Regex', 'Range'};
    obj.UI.Filter = struct("Col", {}, "Mode", {}, "Val", {}, "Val2", {});
    for i = 1:nRows
        fr = uigridlayout(fg, [1 4]);
        fr.ColumnWidth = {'1.1x', '0.9x', '1x', '1x'};
        fr.Padding = [0 0 0 0];
        fr.ColumnSpacing = 4;
        colDd = uidropdown(fr, "Items", {'(none)'}, "Value", '(none)');
        modeDd = uidropdown(fr, "Items", modes, "Value", 'Exact');
        % A uifigure does not forward keystrokes to the figure KeyPressFcn
        % while a text field has focus, so Enter is applied here instead.
        valEd = uieditfield(fr, "text", "Placeholder", "value", ...
            "ValueChangedFcn", @(s,e) obj.onRefresh(s,e));
        val2Ed = uieditfield(fr, "text", "Placeholder", "…to (range)", ...
            "ValueChangedFcn", @(s,e) obj.onRefresh(s,e));
        obj.UI.Filter(i) = struct("Col", colDd, "Mode", modeDd, ...
            "Val", valEd, "Val2", val2Ed);
    end

    brow = uigridlayout(fg, [1 2]);
    brow.ColumnWidth = {'1x', '1x'};
    brow.Padding = [0 0 0 0];
    uibutton(brow, "Text", "Apply", "Tooltip", "Apply filters (Enter)", ...
        "ButtonPushedFcn", @(s,e) obj.onRefresh(s,e));
    uibutton(brow, "Text", "Clear", "Tooltip", "Clear filters (Esc)", ...
        "ButtonPushedFcn", @(s,e) obj.onClearFilters(s,e));

    % ---- tab group with browse tabs ----------------------------------------
    tg = uitabgroup(body);
    tg.Layout.Row = 1; tg.Layout.Column = 2;
    tg.SelectionChangedFcn = @(s,e) obj.onTabChanged(s,e);
    obj.UI.TabGroup = tg;

    defs = obj.pTabDefs();
    obj.UI.Tabs = struct();
    obj.UI.Tables = struct();
    for k = 1:numel(defs)
        d = defs(k);
        tabH = uitab(tg, "Title", d.Title, "Tag", char(d.Key));
        tgrid = uigridlayout(tabH, [1 1]);
        tgrid.Padding = [4 4 4 4];
        tblH = uitable(tgrid, ...
            "ColumnSortable", true, ...
            "SelectionType", "row", ...
            "Multiselect", "off", ...
            "RowName", {});
        obj.UI.Tabs.(d.Key) = tabH;
        obj.UI.Tables.(d.Key) = tblH;
    end

    % ---- Custom SQL tab -----------------------------------------------------
    sqlTab = uitab(tg, "Title", "Custom SQL", "Tag", "sql");
    sg = uigridlayout(sqlTab, [4 1]);
    sg.RowHeight = {28, 140, 34, '1x'};
    sg.ColumnWidth = {'1x'};
    sg.Padding = [6 6 6 6];
    sg.RowSpacing = 6;

    sqlTop = uigridlayout(sg, [1 3]);
    sqlTop.ColumnWidth = {90, '1x', 90};
    sqlTop.Padding = [0 0 0 0];
    uilabel(sqlTop, "Text", "Recall:", "HorizontalAlignment", "right");
    obj.UI.SqlHistory = uidropdown(sqlTop, ...
        "Items", local_historyItems(obj.Prefs.SqlHistory), ...
        "Value", "(history)", ...
        "ValueChangedFcn", @(s,e) obj.pRecallSql(s,e));
    uibutton(sqlTop, "Text", "Run", "Tooltip", "Run query (Ctrl+Enter)", ...
        "ButtonPushedFcn", @(~,~) obj.runCustomSQL());

    obj.UI.SqlEditor = uitextarea(sg, "Value", cellstr(splitlines(obj.Prefs.LastSql)));
    obj.UI.SqlEditor.FontName = "monospaced";

    uilabel(sg, "Text", ...
        "Read-only: only SELECT/WITH queries run, inside a READ ONLY transaction. Use Export → WS to capture results.", ...
        "FontColor", [0.35 0.35 0.35]);

    obj.UI.SqlResults = uitable(sg, "ColumnSortable", true, "RowName", {});

    % ---- status bar ---------------------------------------------------------
    obj.UI.Status = uilabel(root, "Text", "Ready.", "HorizontalAlignment", "left");
    obj.UI.Status.Layout.Row = 3; obj.UI.Status.Layout.Column = 1;
    person = obj.Db.CurrentPersonId;
    if ismissing(person), person = "(no person set)"; end
    obj.pStatus("Connected · schema " + obj.Db.Schema + " · person " + person);

    % ---- restore last tab, then populate filter columns --------------------
    keys = string({tg.Children.Tag});
    want = obj.Prefs.LastTab;
    if ~ismember(want, keys)
        want = defs(1).Key;
    end
    tg.SelectedTab = tg.Children(find(keys == want, 1));
    obj.pPopulateFilterColumns();
end

% ---- obj-free helpers --------------------------------------------------------
function items = local_historyItems(hist)
    items = ["(history)"; hist(:)];
    items = cellstr(items);
end

function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [max(1, su(3)/2 - w/2), max(1, su(4)/2 - h/2), w, h];
end

function pos = local_clampToMonitor(pos)
    %LOCAL_CLAMPTOMONITOR Keep remembered geometry on a monitor that still exists.
    %   Geometry saved while docked on a second display would otherwise reopen
    %   the window off-screen, where it cannot be reached or moved back.
    mons = get(groot, "MonitorPositions");
    if isempty(mons)
        return
    end
    areas = zeros(size(mons, 1), 1);
    for i = 1:size(mons, 1)
        areas(i) = local_overlap(pos, mons(i, :));
    end
    [bestArea, best] = max(areas);
    if bestArea <= 0
        best = 1;               % nothing visible anywhere -> primary monitor
    end
    m = mons(best, :);
    w = min(pos(3), m(3));
    h = min(pos(4), m(4));
    x = min(max(pos(1), m(1)), m(1) + m(3) - w);
    y = min(max(pos(2), m(2)), m(2) + m(4) - h);
    pos = [x, y, w, h];
end

function a = local_overlap(p, m)
    dx = max(0, min(p(1) + p(3), m(1) + m(3)) - max(p(1), m(1)));
    dy = max(0, min(p(2) + p(4), m(2) + m(4)) - max(p(2), m(2)));
    a = dx * dy;
end
