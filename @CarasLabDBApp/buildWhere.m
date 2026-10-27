function w = buildWhere(obj, tabDef, rows, quickText, quickRegex, tagText)
%BUILDWHERE Assemble a safe SQL WHERE clause from the filter widgets.
%
%   w = buildWhere(obj, tabDef, rows, quickText, quickRegex, tagText) returns a string
%   beginning with " WHERE " (or "" when there is nothing to filter). Column
%   identifiers come only from tabDef (internal, trusted); every user VALUE is
%   escaped through CarasLabDB.sqlLiteral. Values are passed as quoted string
%   literals and Postgres casts them to the column type for =, >=, <= — so a
%   date/number typed as text still compares correctly.
%
%   Modes:
%       Exact    -> col = <lit>
%       Contains -> CAST(col AS text) ILIKE %val%   (case-insensitive substring)
%       Regex    -> CAST(col AS text) ~* val        (case-insensitive POSIX regex)
%       Range    -> col >= <lo> [AND col <= <hi>]
%
%   Tag filter (TAGTEXT), the same grammar as the web dashboard's: tokens
%   separated by spaces must all hold; "-tok" must not; "ns:*" is any current
%   tag of namespace ns; a bare token means tag:<token>. For example
%       stage:raw -qc:fail topic:*
%   becomes one clause
%       lab.fn_tag_match('artifact', artifact_id::text,
%                        ARRAY['stage:raw', 'topic:*']::text[], NULL::text[],
%                        ARRAY['qc:fail']::text[])
%   so the semantics are the database's own (lab.fn_tag_match), as in the
%   CarasLabDB get* methods and the MCP server. The entity kind comes from a
%   fixed map of the tab key and the id column from tabDef.Columns(1); each
%   token is validated with CarasLabDB.normalizeTag (a malformed token raises
%   CarasLabDB:invalidTag) and passed through CarasLabDB.sqlLiteral.
%
%   See also CARASLABDBAPP/APPLYFILTERS, CARASLABDB/SQLLITERAL.

    arguments
        obj (1,1) CarasLabDBApp
        tabDef (1,1) struct
        rows struct
        quickText (1,1) string
        quickRegex (1,1) logical
        tagText (1,1) string = ""
    end

    clauses = strings(1, 0);

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

    tagClause = local_tagClause(tabDef, tagText, obj.pQualify("fn_tag_match"));
    if strlength(tagClause) > 0
        clauses(end+1) = tagClause;
    end

    if isempty(clauses)
        w = "";
    else
        w = " WHERE " + strjoin(clauses, " AND ");
    end
end

% =============================================================================
function c = local_tagClause(tabDef, tagText, fnRef)
    %LOCAL_TAGCLAUSE The lab.fn_tag_match clause for the Tags field, or "".
    %   FNREF is the schema-qualified function name (internal).
    c = "";
    if ismissing(tagText)
        return
    end
    toks = string(regexp(char(tagText), '\S+', 'match'));
    allOf = strings(1, 0);
    noneOf = strings(1, 0);
    for i = 1:numel(toks)
        t = toks(i);
        if startsWith(t, "-")
            t = extractAfter(t, 1);
            if strlength(t) > 0
                noneOf(end+1) = t; %#ok<AGROW>
            end
        else
            allOf(end+1) = t; %#ok<AGROW>
        end
    end
    if isempty(allOf) && isempty(noneOf)
        return
    end

    % Fixed tab -> entity-kind map: the kind is never taken from user text.
    switch tabDef.Key
        case "subjects",  kind = "subject";
        case "sessions",  kind = "session";
        case "events",    kind = "event";
        case "artifacts", kind = "artifact";
        otherwise
            error("CarasLabDBApp:tagsUnavailable", ...
                "Tag filters are not available on the %s tab.", tabDef.Title);
    end
    pk = tabDef.Columns(1);              % PK is always the first column (internal)

    c = fnRef + "(" + CarasLabDB.sqlLiteral(kind) + ", " + pk + "::text, " + ...
        local_array(allOf) + ", NULL::text[], " + local_array(noneOf) + ")";
end

function a = local_array(tokens)
    %LOCAL_ARRAY Validated tag tokens as an ARRAY[...]::text[] literal (NULL if none).
    if isempty(tokens)
        a = "NULL::text[]";
        return
    end
    tokens = CarasLabDB.normalizeTag(tokens, AllowWildcard=true);
    lits = strings(1, numel(tokens));
    for i = 1:numel(tokens)
        lits(i) = CarasLabDB.sqlLiteral(tokens(i));
    end
    a = "ARRAY[" + strjoin(lits, ", ") + "]::text[]";
end
