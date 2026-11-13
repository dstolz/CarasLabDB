function [action, v] = fieldChange(f, raw, isEdit, opts)
%FIELDCHANGE Decide what one form field's value means: set, clear or keep.
%
%   [action, v] = CarasLabDBApp.fieldChange(f, raw, isEdit) compares RAW, the
%   value pFormDialog read back for field spec F, with F.Value, the value the
%   form was prefilled with, and returns
%
%       "set"   - write V (the typed value: string, double or a datetime in
%                 the local zone);
%       "clear" - the field was prefilled and the user emptied it (only when
%                 ISEDIT): the caller writes NULL, or refuses if the column is
%                 required;
%       "keep"  - nothing to write: blank on a new row, or (when ISEDIT) still
%                 what it was prefilled with.
%
%   With ISEDIT false (an "add" form) a non-blank value is "set" and a blank
%   one "keep", whatever F.Value holds.
%
%   An untouched field is always "keep", so it is never rewritten through the
%   widget's rendering of it (a timestamp to whole seconds, text trimmed, a
%   number re-parsed). "Untouched" is judged the way pFormDialog shows the
%   value: a field the form displayed as blank (a NULL, a dropdown value
%   outside its choices, a timestamp it could not read) can never be reported
%   as "clear".
%
%   Name=Value:
%       DateOnly - true for a field stored as a calendar date: a datetime
%                  field is then unchanged when the day is the same.
%
%   The three editors share this one definition; each still does its own
%   conversion of a "set" value (dropdown label to key, JSON validation).
%
%   See also CARASLABDBAPP/PFORMDIALOG, CARASLABDBAPP/SHOWEVENTEDITOR,
%   CARASLABDBAPP/SHOWSUBJECTEDITOR, CARASLABDBAPP/SHOWSESSIONEDITOR.

    arguments
        f (1,1) struct
        raw
        isEdit (1,1) logical
        opts.DateOnly (1,1) logical = false
    end

    action = "keep";
    switch string(f.Type)
        case "number"
            v = double(raw);                 % NaN when the field is blank
            orig = local_origNumber(f.Value);
            if isnan(v)
                if isEdit && ~isnan(orig)
                    action = "clear";
                end
            elseif ~(isEdit && ~isnan(orig) && v == orig)
                action = "set";
            end

        case "bool"
            v = logical(raw);
            if ~(isEdit && islogical(f.Value) && isscalar(f.Value) && f.Value == v)
                action = "set";
            end

        case "datetime"
            v = raw;                         % NaT when the field is blank
            orig = local_origDatetime(f.Value);
            if isnat(v)
                if isEdit && ~isnat(orig)
                    action = "clear";
                end
                return
            end
            v.TimeZone = "local";
            if isEdit && ~isnat(orig)
                if opts.DateOnly
                    same = string(v, "yyyy-MM-dd") == string(orig, "yyyy-MM-dd");
                else
                    % The form surfaces whole seconds only.
                    same = abs(seconds(v - orig)) < 1;
                end
                if same
                    return
                end
            end
            action = "set";

        otherwise                            % text / textarea / enum
            v = strtrim(string(raw));
            if isEdit
                was = local_prefillText(f);
                if ~ismissing(was)
                    if v == was
                        return
                    end
                    if strlength(v) == 0
                        action = "clear";
                        return
                    end
                end
            end
            if strlength(v) > 0
                action = "set";
            end
    end
end

% =============================================================================
function x = local_origNumber(orig)
    %LOCAL_ORIGNUMBER The number a field was prefilled with (NaN if shown blank).
    x = NaN;
    if isempty(orig)
        return
    end
    if isnumeric(orig) && isscalar(orig)
        x = double(orig);
    elseif ischar(orig) || (isstring(orig) && isscalar(orig) && ~ismissing(orig))
        % Read the text the way the form reads its number fields back
        % (CarasLabDBApp.parseNumber): never through a bare str2double.
        try
            x = CarasLabDBApp.parseNumber(string(orig));
        catch
            x = NaN;
        end
    end
end

function o = local_origDatetime(orig)
    %LOCAL_ORIGDATETIME The instant a datetime field was prefilled with, in the
    %   local zone; NaT when pFormDialog showed the field blank (a NULL, or a
    %   value it could not read as a datetime).
    o = NaT("TimeZone", "local");
    if isempty(orig) || (isstring(orig) && isscalar(orig) && ismissing(orig))
        return
    end
    try
        if isdatetime(orig)
            t = orig;
        else
            t = datetime(string(orig), "TimeZone", "local");
        end
    catch
        return
    end
    if ~isscalar(t) || isnat(t)
        return
    end
    if isempty(t.TimeZone)
        t.TimeZone = "local";             % unzoned = wall-clock reading here
    end
    o = t;
end

function t = local_prefillText(f)
    %LOCAL_PREFILLTEXT The text a text/textarea/enum field was prefilled with,
    %   normalized the way pFormDialog reads it back (lines joined with
    %   newline, trimmed). <missing> when the value has no text form, which
    %   the caller treats as "cannot tell": only a typed value then counts.
    orig = f.Value;
    if isempty(orig) || (isstring(orig) && isscalar(orig) && ismissing(orig))
        t = "";
    else
        try
            t = strtrim(strjoin(reshape(splitlines(string(orig)), 1, []), newline));
        catch
            t = string(missing);
            return
        end
        if ~isscalar(t) || ismissing(t)
            t = string(missing);
            return
        end
    end
    if string(f.Type) == "enum" && ~ismember(t, reshape(string(f.Choices), 1, []))
        t = "";                           % a dropdown shows an unlisted value as blank
    end
end
