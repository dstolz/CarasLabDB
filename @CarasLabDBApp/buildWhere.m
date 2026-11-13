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
%       Contains -> CAST(col AS text) ILIKE %val%   (case-insensitive substring;
%                   %, _ and \ in val are matched literally)
%       Regex    -> CAST(col AS text) ~* val        (case-insensitive POSIX regex)
%       Range    -> col >= <lo> [AND col <= <hi>]
%
%   Dates. On a date / timestamp column (tabDef.DateCols) a value written as a
%   bare date, yyyy-MM-dd (2026-7-2 is read the same), stands for that whole
%   day in the session time zone
%   (the workstation's): Exact becomes col >= <d> AND col < <d>::date + 1, and
%   the upper end of a Range becomes col < <hi>::date + 1, so "to 2026-07-02"
%   includes everything that happened on 2 July. A value with a time of day
%   is compared as written.
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
                CarasLabDB.sqlLiteral(local_likePattern(qt));
        end
    end

    for i = 1:numel(rows)
        col = rows(i).Col;
        mode = rows(i).Mode;
        val = strtrim(rows(i).Val);
        val2 = strtrim(rows(i).Val2);
        % A bare date on a date / timestamp column means that whole day.
        isDateCol = ismember(col, reshape(string(tabDef.DateCols), 1, []));

        switch mode
            case "Exact"
                if strlength(val) == 0, continue; end
                if isDateCol && local_isBareDate(val)
                    lit = CarasLabDB.sqlLiteral(val);
                    clauses(end+1) = "(" + col + " >= " + lit + " AND " + ...
                        col + " < (" + lit + "::date + 1))"; %#ok<AGROW>
                else
                    clauses(end+1) = col + " = " + CarasLabDB.sqlLiteral(val); %#ok<AGROW>
                end

            case "Contains"
                if strlength(val) == 0, continue; end
                clauses(end+1) = "CAST(" + col + " AS text) ILIKE " + ...
                    CarasLabDB.sqlLiteral(local_likePattern(val)); %#ok<AGROW>

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
                    if isDateCol && local_isBareDate(val2)
                        % "to 2026-07-02" includes all of 2 July.
                        parts(end+1) = col + " < (" + ...
                            CarasLabDB.sqlLiteral(val2) + "::date + 1)"; %#ok<AGROW>
                    else
                        parts(end+1) = col + " <= " + CarasLabDB.sqlLiteral(val2); %#ok<AGROW>
                    end
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
function p = local_likePattern(val)
    %LOCAL_LIKEPATTERN "%val%" with the LIKE wildcards in VAL made literal.
    %   Without this "G_04" also matches "GX04" and "%" matches every row.
    %   Backslash is Postgres's default LIKE escape character, so it is
    %   escaped first; sqlLiteral then quotes the whole pattern as a value.
    v = replace(val, "\", "\\");
    v = replace(v, "%", "\%");
    v = replace(v, "_", "\_");
    p = "%" + v + "%";
end

function tf = local_isBareDate(val)
    %LOCAL_ISBAREDATE True for a date with no time of day, written yyyy-MM-dd.
    %   One-digit months and days (2026-7-2) count too: Postgres reads them
    %   as the same date, and they must not fall back to "midnight only".
    tf = ~isempty(regexp(char(val), '^\d{4}-\d{1,2}-\d{1,2}$', 'once'));
end

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
