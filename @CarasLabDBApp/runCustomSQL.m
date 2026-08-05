function runCustomSQL(obj)
%RUNCUSTOMSQL Execute the Custom SQL editor's query, read-only, with history.
%
%   Safety comes from CarasLabDB.runReadOnlyQuery, which runs the statement
%   inside a Postgres READ ONLY transaction: that is what actually prevents a
%   write. The syntactic guard below is a typo-catcher that fails fast with a
%   readable message; it is not a security boundary and must not be relied on
%   as one.
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
    %LOCAL_ISREADONLY Typo-catcher: single SELECT/WITH statement, no writes.
    %   Every check runs against a scratch copy with string literals and
    %   comments blanked out, so a value such as '%do not use%' is not mistaken
    %   for the DO keyword and a ';' inside a literal is not read as a second
    %   statement. The READ ONLY transaction in runReadOnlyQuery is what
    %   actually enforces read-only access; this only produces a clearer
    %   message for the common mistakes.
    ok = false;
    scratch = local_stripNoise(sql);
    scratch = regexprep(scratch, ';\s*$', '');   % one trailing semicolon is fine

    if contains(scratch, ';')
        why = "Only a single statement is allowed (found ';').";
        return
    end

    % Skip leading whitespace and open parens so a leading comment (already
    % blanked above) or a parenthesised "(SELECT ...)" still resolves.
    tok = regexp(lower(scratch), '^[\s(]*(\w+)', 'tokens', 'once');
    if isempty(tok) || ~ismember(tok{1}, {'select', 'with'})
        why = "Only SELECT or WITH queries are permitted.";
        return
    end

    % "into" catches SELECT ... INTO, which creates a table without any of the
    % other keywords appearing.
    forbidden = "(insert|update|delete|drop|alter|create|truncate|grant|" + ...
                "revoke|copy|call|merge|vacuum|analyze|reindex|refresh|lock|" + ...
                "comment|do|set|into|notify|declare|import|security)";
    if ~isempty(regexpi(scratch, "\<" + forbidden + "\>", "once"))
        why = "Write/DDL keywords are not allowed in the Custom SQL panel.";
        return
    end

    ok = true;
    why = "";
end

function out = local_stripNoise(sql)
    %LOCAL_STRIPNOISE Blank out string literals, quoted identifiers and comments.
    %   Content is replaced by spaces (not removed) so nothing on either side
    %   of it can be glued into a new token.
    s = char(sql);
    out = s;
    n = numel(s);
    i = 1;
    while i <= n
        c = s(i);
        if c == '''' || c == '"'
            j = i + 1;
            while j <= n
                if s(j) == c
                    if j < n && s(j+1) == c
                        j = j + 2;      % doubled quote: still inside
                        continue
                    end
                    break
                end
                j = j + 1;
            end
            j = min(j, n);
            out(i+1:j-1) = ' ';         % keep the quotes, blank the contents
            i = j + 1;
        elseif c == '-' && i < n && s(i+1) == '-'
            j = i;
            while j <= n && s(j) ~= newline
                j = j + 1;
            end
            out(i:j-1) = ' ';
            i = j;
        elseif c == '/' && i < n && s(i+1) == '*'
            % Block comments nest in Postgres, so track the depth.
            depth = 1;
            j = i + 2;
            while j < n && depth > 0
                if s(j) == '/' && s(j+1) == '*'
                    depth = depth + 1; j = j + 2;
                elseif s(j) == '*' && s(j+1) == '/'
                    depth = depth - 1; j = j + 2;
                else
                    j = j + 1;
                end
            end
            j = min(j, n + 1);
            out(i:j-1) = ' ';
            i = j;
        else
            i = i + 1;
        end
    end
    out = string(out);
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
