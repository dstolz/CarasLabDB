function applyFilters(obj)
%APPLYFILTERS Run the current tab's filtered query and populate its table.
%
%   Builds "SELECT * FROM <table><where> ORDER BY <orderby>, <pk> LIMIT <cap+1>",
%   honoring the active-only toggle (events/artifacts read the *_active view,
%   or the *_version view for full history), executes via CarasLabDB.runQuery,
%   and shows the result. Event rows are color-coded by event_type,
%   recorded_login is shown next to recorded_by, and in full history the rows
%   that are no longer in force (superseded or retracted: is_current false)
%   are greyed. Errors (e.g. a bad regex) surface in the status bar and an
%   alert rather than throwing.
%
%   One row more than the row limit is asked for, so "capped" means that
%   more rows really match; the extra row is not shown. Whether the result
%   was capped is remembered per tab (obj.Capped) so an export can say it is
%   incomplete.
%
%   A Tags filter is checked with lab.fn_tag_filter_problems before the
%   query runs. lab.fn_tag_match treats an unknown tag as "no row has it",
%   so a typo in an excluded tag (-qc:fial) would silently exclude nothing;
%   a namespace that does not exist or does not apply to this tab's rows, or
%   a tag that is not registered, is reported instead (as CarasLabDB's get*
%   methods do with CarasLabDB:tagFilterProblem) and the table is left as it
%   was.
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

    % A tag filter that cannot mean what it says is refused, not run.
    problem = local_tagFilterProblem(obj.Db, obj.pQualify("fn_tag_filter_problems"), ...
        d.Entity, tagText);
    if strlength(problem) > 0
        obj.pStatus("Filter error: " + replace(problem, newline, " "));
        uialert(obj.Fig, problem, "Invalid filter");
        return
    end

    % The primary key as a last sort key makes the order total, so a result
    % cut off at the row limit is a stable, well-defined subset. One row
    % beyond the limit is fetched to learn whether more rows match.
    orderBy = d.OrderBy;
    pk = d.Columns(1);
    if ~startsWith(orderBy, pk)
        orderBy = orderBy + ", " + pk;
    end
    sql = "SELECT * FROM " + obj.pQualify(tableName) + where + ...
        " ORDER BY " + orderBy + " LIMIT " + string(obj.RowLimit + 1) + ";";

    tbl = obj.UI.Tables.(d.Key);
    try
        T = obj.Db.runQuery(sql);
    catch ME
        obj.pStatus("Query error: " + string(ME.message));
        uialert(obj.Fig, string(ME.message), "Query failed");
        return
    end
    capped = istable(T) && height(T) > obj.RowLimit;
    if capped
        T = T(1:obj.RowLimit, :);           % the extra row only proves there are more
    end
    T = local_placeColumns(d, T);

    tbl.Data = T;
    tbl.Selection = [];
    obj.DisplaySel.(char(d.Key)) = [];      % no selection event has happened on this data
    local_colorEvents(obj, d, tbl, T);
    local_greyNotCurrent(tbl, T);

    n = height(T);
    obj.Capped.(char(d.Key)) = capped;      % exportToWorkspace reports it
    capNote = "";
    if capped
        capNote = " (capped at " + string(obj.RowLimit) + ": more rows match)";
    end
    tagNote = "";
    if strlength(strtrim(tagText)) > 0
        tagNote = " · tags: " + strtrim(tagText);
        if n == 0
            tagNote = tagNote + " (no row matches)";
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

function problem = local_tagFilterProblem(db, fnRef, kind, tagText)
    %LOCAL_TAGFILTERPROBLEM What is wrong with the Tags filter, or "" if nothing.
    %   Asks lab.fn_tag_filter_problems (FNREF, schema-qualified, internal)
    %   about every token of TAGTEXT for rows of KIND (the tab's Entity, a
    %   fixed internal value). Tokens were already validated by buildWhere;
    %   they are canonicalised again here and passed as SQL literals. If the
    %   check itself cannot be run, "" is returned and the filter is applied
    %   as before.
    problem = "";
    toks = string(regexp(char(tagText), '\S+', 'match'));
    toks = regexprep(toks, '^-', '');
    toks = toks(strlength(toks) > 0);
    if isempty(toks)
        return
    end
    try
        toks = unique(CarasLabDB.normalizeTag(toks, AllowWildcard=true), "stable");
        lits = strings(1, numel(toks));
        for i = 1:numel(toks)
            lits(i) = CarasLabDB.sqlLiteral(toks(i));
        end
        R = db.runQuery("SELECT token, problem FROM " + fnRef + "(" + ...
            CarasLabDB.sqlLiteral(kind) + ", ARRAY[" + strjoin(lits, ", ") + "]::text[]);");
        if ~istable(R) || height(R) == 0
            return
        end
        found = reshape(string(R.token), 1, []) + ": " + reshape(string(R.problem), 1, []);
        problem = "The Tags filter cannot match " + kind + " rows as written:" + ...
            newline + strjoin("  " + found, newline) + newline + ...
            "Correct the tag; the tag editor (Ctrl+T) lists the vocabulary.";
    catch
        problem = "";
    end
end

function local_greyNotCurrent(tbl, T)
    %LOCAL_GREYNOTCURRENT Grey the rows that are no longer in force.
    %   Full history (event_version / artifact_version) carries is_current:
    %   false for a superseded or a retracted row. Greying them keeps a row
    %   that was replaced or withdrawn from being read as a current one.
    %   The active views have no such column, and nothing is styled.
    try
        if ~istable(T) || height(T) == 0 ...
                || ~ismember("is_current", string(T.Properties.VariableNames))
            return
        end
        cur = T.is_current;
        if iscell(cur)
            cur = cellfun(@(v) ~isempty(v) && logical(v(1)), cur);
        end
        idx = find(~logical(cur(:)));
        if isempty(idx)
            return
        end
        addStyle(tbl, uistyle("FontColor", [0.55 0.55 0.55]), "row", idx);
    catch
        % Styling is a convenience; the is_current column still says it.
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
