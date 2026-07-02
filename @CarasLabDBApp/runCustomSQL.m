function runCustomSQL(obj)
%RUNCUSTOMSQL Execute the Custom SQL editor's query, read-only, with history.
%
%   Two-layer safety: a syntactic guard requires the statement to be a single
%   SELECT/WITH query with no write/DDL keywords, and execution goes through
%   CarasLabDB.runReadOnlyQuery, which runs it inside a Postgres READ ONLY
%   transaction so anything that slips past the guard still cannot mutate data.
%
%   Successful queries are pushed onto the recall history (persisted in prefs)
%   and results are shown in the results table (exportable via Export → WS).
%
%   See also CARASLABDB/RUNREADONLYQUERY, CARASLABDBAPP/EXPORTTOWORKSPACE.

    arguments
        obj (1,1) CarasLabDBApp
    end

    sql = strtrim(strjoin(string(obj.UI.SqlEditor.Value), newline));
    if strlength(sql) == 0
        uialert(obj.Fig, "Enter a query first.", "Custom SQL");
        return
    end

    [ok, why] = local_isReadOnly(sql);
    if ~ok
        obj.pStatus("Refused: " + why);
        uialert(obj.Fig, why, "Read-only queries only");
        return
    end

    try
        T = obj.Db.runReadOnlyQuery(sql);
    catch ME
        obj.pStatus("SQL error: " + string(ME.message));
        uialert(obj.Fig, string(ME.message), "Query failed");
        return
    end

    obj.UI.SqlResults.Data = T;
    obj.pStatus("SQL: " + string(height(T)) + " row(s)");

    % Update history (most-recent-first, deduped, capped) and persist.
    obj.Prefs.SqlHistory = local_pushHistory(obj.Prefs.SqlHistory, sql, 25);
    obj.Prefs.LastSql = sql;
    obj.pRefreshSqlHistory();
    obj.savePrefs();
end

% =============================================================================
function [ok, why] = local_isReadOnly(sql)
    %LOCAL_ISREADONLY Heuristic guard: single SELECT/WITH statement, no writes.
    ok = false;
    core = regexprep(sql, ';\s*$', '');    % drop one trailing semicolon

    if contains(core, ';')
        why = "Only a single statement is allowed (found ';').";
        return
    end

    tok = regexp(lower(core), '^\s*(\w+)', 'tokens', 'once');
    if isempty(tok) || ~ismember(tok{1}, {'select', 'with'})
        why = "Only SELECT or WITH queries are permitted.";
        return
    end

    forbidden = "(insert|update|delete|drop|alter|create|truncate|grant|" + ...
                "revoke|copy|call|merge|vacuum|analyze|reindex|refresh|lock|" + ...
                "comment|do|set)";
    if ~isempty(regexpi(core, "\<" + forbidden + "\>", "once"))
        why = "Write/DDL keywords are not allowed in the Custom SQL panel.";
        return
    end

    ok = true;
    why = "";
end

function h = local_pushHistory(h, entry, capN)
    if isempty(h)
        h = strings(0, 1);
    end
    h = h(:);
    h(h == entry) = [];       % remove any prior copy
    h = [entry; h];           % most recent first
    if numel(h) > capN
        h = h(1:capN);
    end
end
