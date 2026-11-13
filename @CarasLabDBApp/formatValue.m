function s = formatValue(v)
%FORMATVALUE A form value as one short line of text, for a confirmation.
%
%   s = CarasLabDBApp.formatValue(v) returns V the way the change preview
%   shows it: text in double quotes (one line, at most about 160 characters),
%   a number in the shortest decimal that reads back as the same double, a
%   logical as true / false, a datetime as yyyy-MM-dd HH:mm:ss (the date
%   alone at midnight), and "(empty)" for a blank, missing, NaN or NaT value.
%   It never throws: a value it cannot render is "(empty)".
%
%   See also CARASLABDBAPP/CONFIRMCHANGES, CARASLABDBAPP/FIELDCHANGE.

    s = "(empty)";
    try
        if isempty(v)
            return
        end
        if isdatetime(v)
            if ~isscalar(v) || isnat(v)
                return
            end
            if v == dateshift(v, "start", "day")
                s = string(v, "yyyy-MM-dd");
            else
                s = string(v, "yyyy-MM-dd HH:mm:ss");
            end
            return
        end
        if islogical(v)
            if isscalar(v)
                if v
                    s = "true";
                else
                    s = "false";
                end
            end
            return
        end
        if isnumeric(v)
            if ~isscalar(v) || ~isreal(v) || ~isfinite(v)
                return
            end
            % The same text pFormDialog shows for a number.
            s = string(CarasLabDB.sqlLiteral(double(v)));
            return
        end
        t = string(v);
        if ~isscalar(t)
            t = strjoin(reshape(t, 1, []), " ");
        end
        if ismissing(t)
            return
        end
        t = strtrim(regexprep(t, '\s+', ' '));       % one line
        if strlength(t) == 0
            return
        end
        if strlength(t) > 160
            t = extractBefore(t, 158) + "…";
        end
        s = """" + t + """";
    catch
        s = "(empty)";
    end
end
