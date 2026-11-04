function w = buildWhere(obj, tabDef, rows, quickText, quickRegex, tagText)
%BUILDWHERE Assemble a safe SQL WHERE clause from the filter widgets.
%
%   w = buildWhere(obj, tabDef, rows, quickText, quickRegex, tagText) returns
%   a string beginning with " WHERE " (or "" when there is nothing to
%   filter). Column identifiers come only from tabDef (internal, trusted);
%   every user VALUE is escaped through CarasLabDB.sqlLiteral. Values are
%   passed as quoted string literals and Postgres casts them to the column
%   type for =, >=, <= — so a date/number typed as text still compares
%   correctly.
%
%   Modes:
%       Exact    -> col = <lit>
%       Contains -> CAST(col AS text) ILIKE %val%   (case-insensitive substring)
%       Regex    -> CAST(col AS text) ~* val        (case-insensitive POSIX regex)
%       Range    -> col >= <lo> [AND col <= <hi>]
%
%   TAGTEXT is the hashtag filter: whitespace-separated tag patterns, where
%   a plain pattern must match, "-pattern" must not, "?pattern" is one of a
%   set of which at least one must match, "ns:*" matches any tag of a
%   namespace and a bare word is a free-form "tag:" tag. It becomes one
%   lab.fn_tag_match(...) clause on the tab's entity kind and primary key
%   (both from tabDef), so the GUI, the MATLAB class and the dashboards
%   agree on what a filter means. A malformed pattern raises.
%
%   See also CARASLABDBAPP/APPLYFILTERS, CARASLABDB/SQLLITERAL, CARASLABDB/NORMALIZETAG.

    arguments
        obj (1,1) CarasLabDBApp
        tabDef (1,1) struct
        rows struct
        quickText (1,1) string
        quickRegex (1,1) logical
        tagText (1,1) string = ""
    end

    clauses = strings(1, 0);

    % Tag filter (applies to every browse tab; the entity kind and key come
    % from the tab definition, never from the text).
    tagClause = local_tagClause(obj, tabDef, tagText);
    if strlength(tagClause) > 0
        clauses(end+1) = tagClause;
    end

    % Quick subject search (applies to any tab that has a subject_id column).
    qt = strtrim(quickText);
    if strlength(qt) > 0 && tabDef.HasSubject
        if quickRegex
            clauses(end+1) = "CAST(subject_id AS text) ~* " + CarasLabDB.sqlLiteral(qt);
        else
            clauses(end+1) = "CAST(subject_id AS text) ILIKE " + ...
                CarasLabDB.sqlLiteral("%" + qt + "%");
        end
    end

    for i = 1:numel(rows)
        col = rows(i).Col;
        mode = rows(i).Mode;
        val = strtrim(rows(i).Val);
        val2 = strtrim(rows(i).Val2);

        switch mode
            case "Exact"
                if strlength(val) == 0, continue; end
                clauses(end+1) = col + " = " + CarasLabDB.sqlLiteral(val); %#ok<AGROW>

            case "Contains"
                if strlength(val) == 0, continue; end
                clauses(end+1) = "CAST(" + col + " AS text) ILIKE " + ...
                    CarasLabDB.sqlLiteral("%" + val + "%"); %#ok<AGROW>

            case "Regex"
                if strlength(val) == 0, continue; end
                clauses(end+1) = "CAST(" + col + " AS text) ~* " + ...
                    CarasLabDB.sqlLiteral(val); %#ok<AGROW>

            case "Range"
                parts = strings(1, 0);
                if strlength(val) > 0
                    parts(end+1) = col + " >= " + CarasLabDB.sqlLiteral(val); %#ok<AGROW>
                end
                if strlength(val2) > 0
                    parts(end+1) = col + " <= " + CarasLabDB.sqlLiteral(val2); %#ok<AGROW>
                end
                if ~isempty(parts)
                    clauses(end+1) = "(" + strjoin(parts, " AND ") + ")"; %#ok<AGROW>
                end
        end
    end

    if isempty(clauses)
        w = "";
    else
        w = " WHERE " + strjoin(clauses, " AND ");
    end
end

% =============================================================================
function c = local_tagClause(obj, tabDef, tagText)
    %LOCAL_TAGCLAUSE lab.fn_tag_match(...) for the parsed tag filter, or "".
    c = "";
    tokens = split(strtrim(tagText));
    tokens = tokens(strlength(tokens) > 0);
    if isempty(tokens)
        return
    end
    allOf = strings(1, 0); anyOf = strings(1, 0); noneOf = strings(1, 0);
    for i = 1:numel(tokens)
        t = tokens(i);
        if startsWith(t, "-")
            noneOf(end+1) = extractAfter(t, 1); %#ok<AGROW>
        elseif startsWith(t, "?") || startsWith(t, "|")
            anyOf(end+1) = extractAfter(t, 1); %#ok<AGROW>
        else
            allOf(end+1) = t; %#ok<AGROW>
        end
    end
    c = obj.pQualify("fn_tag_match") + "(" + CarasLabDB.sqlLiteral(tabDef.Entity) + ...
        ", " + tabDef.Columns(1) + "::text, " + local_arr(allOf) + ", " + ...
        local_arr(anyOf) + ", " + local_arr(noneOf) + ")";
end

function lit = local_arr(patterns)
    %LOCAL_ARR text[] literal of normalized patterns ('{}' when empty).
    if isempty(patterns)
        lit = "ARRAY[]::text[]";
        return
    end
    parts = strings(1, numel(patterns));
    for i = 1:numel(patterns)
        parts(i) = CarasLabDB.sqlLiteral( ...
            CarasLabDB.normalizeTag(patterns(i), AllowWildcard=true));
    end
    lit = "ARRAY[" + strjoin(parts, ", ") + "]::text[]";
end
