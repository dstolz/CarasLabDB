function [v, err] = parseNumber(txt)
%PARSENUMBER Read a number a person typed, refusing anything ambiguous.
%
%   [v, err] = CarasLabDBApp.parseNumber(txt) returns the number written in
%   TXT with ERR = "". Blank (or missing) text gives v = NaN and ERR = "",
%   which callers read as "not provided". Anything else that is not plain
%   decimal notation gives v = NaN and an ERR that says what is wrong, for an
%   alert.
%
%   Accepted: 71.9, 30000, -0.5, .25, 1.5e3. Refused:
%     * any text containing a comma. str2double reads a comma as a thousands
%       separator and drops it wherever it stands, so "71,9" would become
%       719; text with a comma is therefore never passed to str2double.
%     * anything that is not a finite real number in decimal notation
%       ("3i", "inf", "nan", "1d3", "12 g").
%
%   This is the one definition of "a number typed into the app": the generic
%   form (pFormDialog), the variables editor and the daily husbandry table
%   all call it.
%
%   See also CARASLABDBAPP/PFORMDIALOG, CARASLABDBAPP/SHOWVARIABLEEDITOR,
%   CARASLABDBAPP/SHOWHUSBANDRYENTRY.

    arguments
        txt (1,1) string
    end

    v = NaN;
    err = "";
    if ismissing(txt)
        return
    end
    txt = strtrim(txt);
    if strlength(txt) == 0
        return                               % blank means "not provided"
    end
    if contains(txt, ",")
        err = "'" + txt + "' contains a comma. Use a period as the " + ...
            "decimal separator and no thousands separator (for " + ...
            "example 71.9 or 30000).";
        return
    end
    if isempty(regexp(char(txt), '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$', 'once'))
        % Plain decimal notation only: no "3i", "inf", "1d3".
        err = "'" + txt + "' is not a number.";
        return
    end
    x = str2double(txt);
    if ~isreal(x) || ~isfinite(x)
        err = "'" + txt + "' is not a number.";
        return
    end
    v = x;
end
