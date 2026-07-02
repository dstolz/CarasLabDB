function w = buildWhere(obj, tabDef, rows, quickText, quickRegex)
%BUILDWHERE Assemble a safe SQL WHERE clause from the filter widgets.
%
%   w = buildWhere(obj, tabDef, rows, quickText, quickRegex) returns a string
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
%   See also CARASLABDBAPP/APPLYFILTERS, CARASLABDB/SQLLITERAL.

    arguments
        obj (1,1) CarasLabDBApp %#ok<INUSA>
        tabDef (1,1) struct
        rows struct
        quickText (1,1) string
        quickRegex (1,1) logical
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

    if isempty(clauses)
        w = "";
    else
        w = " WHERE " + strjoin(clauses, " AND ");
    end
end
