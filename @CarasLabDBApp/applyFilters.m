function applyFilters(obj)
%APPLYFILTERS Run the current tab's filtered query and populate its table.
%
%   Builds "SELECT * FROM <table><where> ORDER BY <orderby>, <pk> LIMIT <cap>",
%   honoring the active-only toggle (events/artifacts read the *_active view),
%   executes via CarasLabDB.runQuery, and shows the result. Event rows are
%   color-coded by event_type, and recorded_login is shown next to
%   recorded_by. Errors (e.g. a bad regex) surface in the status bar and an
%   alert rather than throwing. Whether the result hit the row limit is
%   remembered per tab (obj.Capped) so an export can say it is incomplete.
%
%   See also CARASLABDBAPP/BUILDWHERE, CARASLABDBAPP/REFRESHACTIVETAB.

    d = obj.pCurrentTabDef();
    if isempty(d)
        return
    end

    % Choose base table vs. active view.
    tableName = d.Table;
    if strlength(d.ActiveTable) > 0 && obj.pActiveOnly()
        tableName = d.ActiveTable;
    end

    rows = obj.pReadFilterRows();
    quickText = string(obj.UI.QuickSearch.Value);
    quickRegex = logical(obj.UI.QuickRegex.Value);
    tagText = string(obj.UI.TagFilter.Value);
    try
        where = obj.buildWhere(d, rows, quickText, quickRegex, tagText);
    catch ME
        % A malformed tag token (CarasLabDB:invalidTag) is reported, not thrown.
        obj.pStatus("Filter error: " + string(ME.message));
        uialert(obj.Fig, string(ME.message), "Invalid filter");
        return
    end

    % The primary key as a last sort key makes the order total, so a result
    % cut off at the row limit is a stable, well-defined subset.
    orderBy = d.OrderBy;
    pk = d.Columns(1);
    if ~startsWith(orderBy, pk)
        orderBy = orderBy + ", " + pk;
    end
    sql = "SELECT * FROM " + obj.pQualify(tableName) + where + ...
        " ORDER BY " + orderBy + " LIMIT " + string(obj.RowLimit) + ";";

    tbl = obj.UI.Tables.(d.Key);
    try
        T = obj.Db.runQuery(sql);
    catch ME
        obj.pStatus("Query error: " + string(ME.message));
        uialert(obj.Fig, string(ME.message), "Query failed");
        return
    end
    T = local_placeColumns(d, T);

    tbl.Data = T;
    tbl.Selection = [];
    obj.DisplaySel.(char(d.Key)) = [];      % no selection event has happened on this data
    local_colorEvents(obj, d, tbl, T);

    n = height(T);
    capped = n >= obj.RowLimit;
    obj.Capped.(char(d.Key)) = capped;      % exportToWorkspace reports it
    capNote = "";
    if capped
        capNote = " (capped at " + string(obj.RowLimit) + ")";
    end
    tagNote = "";
    if strlength(strtrim(tagText)) > 0
        tagNote = " · tags: " + strtrim(tagText);
        if n == 0
            % fn_tag_match gives no rows for a tag that does not exist or
            % does not apply to this kind of row, so say what to check.
            tagNote = tagNote + " (no match: check that each tag exists and applies to " + ...
                lower(d.Title) + ")";
        end
    end
    obj.pStatus(d.Title + ": " + string(n) + " row(s)" + capNote + " · " + tableName + tagNote);
end

% =============================================================================
function T = local_placeColumns(d, T)
    %LOCAL_PLACECOLUMNS Show recorded_login right after recorded_by on the Events tab.
    %   The column is last in lab.event; next to recorded_by it reads as
    %   "who recorded this: the person, and the database login".
    if d.Key ~= "events" || ~istable(T)
        return
    end
    vars = string(T.Properties.VariableNames);
    if all(ismember(["recorded_by", "recorded_login"], vars))
        T = movevars(T, "recorded_login", "After", "recorded_by");
    end
end

% =============================================================================
function local_colorEvents(~, d, tbl, T)
    %LOCAL_COLOREVENTS Shade the event_type cell using the dashboard palette.
    try
        removeStyle(tbl);
    catch
    end
    if d.Key ~= "events" || height(T) == 0
        return
    end
    vars = string(T.Properties.VariableNames);
    if ~ismember("event_type", vars)
        return
    end
    col = find(vars == "event_type", 1);
    types = string(T.event_type);
    pal = local_palette();
    keys = string(pal.keys);
    for i = 1:numel(keys)
        idx = find(types == keys(i));
        if isempty(idx), continue; end
        s = uistyle("BackgroundColor", pal(char(keys(i))));
        addStyle(tbl, s, "cell", [idx(:), repmat(col, numel(idx), 1)]);
    end
end

function m = local_palette()
    %LOCAL_PALETTE Event-type colors mirrored from web/lab-dashboard.html.
    m = containers.Map('KeyType', 'char', 'ValueType', 'any');
    m('birth')     = local_hex('55A868');
    m('surgery')   = local_hex('C44E52');
    m('recording') = local_hex('4C72B0');
    m('behavior')  = local_hex('DD8452');
    m('husbandry') = local_hex('8172B3');
    m('endpoint')  = local_hex('937860');
    m('histology') = local_hex('DA8BC3');
    m('analysis')  = local_hex('3FA7B7');
end

function rgb = local_hex(h)
    rgb = [hex2dec(h(1:2)), hex2dec(h(3:4)), hex2dec(h(5:6))] / 255;
end
