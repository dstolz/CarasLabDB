function out = pFormDialog(titleText, specs)
%PFORMDIALOG Generic modal form; returns entered values keyed by spec.Key.
%
%   out = CarasLabDBApp.pFormDialog(titleText, specs) builds a scrollable modal
%   form from a struct-array of field specs and blocks until the user clicks OK
%   or Cancel. Used by the event/subject/session editors.
%
%   Each spec element:
%       Key      - identifier used as the output struct field
%       Label    - label shown next to the widget
%       Type     - "text" | "textarea" | "number" | "enum" | "bool" | "datetime"
%       Choices  - items for Type=="enum" (else ignored)
%       Value    - initial value (string/double/logical/datetime; may be missing)
%       Editable - optional logical (default true)
%
%   Returns a struct with:
%       out.OK      - true if the user confirmed
%       out.Values  - struct keyed by Key. Text/enum -> string ("" when
%                     blank), number -> double (NaN when blank),
%                     datetime -> datetime (NaT when blank; date from a
%                     uidatepicker plus a HH:mm:ss time field), bool -> logical.
%
%   OK is refused while any field is unreadable (an unparseable number or
%   time-of-day), so a typo can never be silently dropped on the way to the
%   database.
%
%   See also CARASLABDBAPP/SHOWEVENTEDITOR.

    arguments
        titleText (1,1) string
        specs struct
    end

    out = struct("OK", false, "Values", struct());
    n = numel(specs);
    hasTextarea = any(string({specs.Type}) == "textarea");

    figH = min(720, 96 + n * 40);
    f = uifigure("Name", titleText, ...
        "Position", local_center(560, figH), "WindowStyle", "modal", ...
        "KeyPressFcn", @(~,e) onKeyPress(e));
    outer = uigridlayout(f, [2 1]);
    outer.RowHeight = {'1x', 44};
    outer.ColumnWidth = {'1x'};
    outer.Padding = [10 10 10 10];

    panel = uipanel(outer, "BorderType", "none", "Scrollable", "on");
    gg = uigridlayout(panel, [n 2]);
    gg.RowHeight = repmat({32}, 1, n);
    gg.ColumnWidth = {180, '1x'};
    gg.RowSpacing = 6;
    gg.Padding = [4 4 4 4];

    widgets = cell(1, n);
    for i = 1:n
        s = specs(i);
        editable = ~isfield(s, "Editable") || isempty(s.Editable) || logical(s.Editable);
        uilabel(gg, "Text", char(s.Label), "HorizontalAlignment", "right");
        widgets{i} = local_makeWidget(gg, s);
        if ~editable
            local_setEnable(widgets{i}, "off");
        end
    end

    brow = uigridlayout(outer, [1 3]);
    brow.ColumnWidth = {'1x', 100, 100};
    brow.Padding = [0 0 0 0];
    uilabel(brow, "Text", "");
    uibutton(brow, "Text", "Cancel", "Tooltip", "Cancel (Esc)", ...
        "ButtonPushedFcn", @(~,~) onCancel());
    okTip = "OK";
    if ~hasTextarea, okTip = okTip + " (Enter)"; end
    uibutton(brow, "Text", "OK", "Tooltip", char(okTip), "ButtonPushedFcn", @(~,~) onOk());

    uiwait(f);
    if isvalid(f), delete(f); end
    return

    % ---- nested callbacks -----------------------------------------------
    function onKeyPress(e)
        %ONKEYPRESS Escape cancels; Enter submits unless a textarea field
        %   is present (where Enter must insert a newline instead);
        %   Ctrl+? lists the shortcuts.
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "form");
        elseif key == "escape"
            onCancel();
        elseif key == "return"
            if ~hasTextarea, onOk(); end
        end
    end

    function onCancel()
        uiresume(f);
    end

    function onOk()
        vals = struct();
        problems = strings(1, 0);
        for k = 1:n
            [v, err] = local_readWidget(widgets{k}, specs(k).Type);
            if strlength(err) > 0
                problems(end+1) = string(specs(k).Label) + ": " + err; %#ok<AGROW>
                continue
            end
            vals.(char(specs(k).Key)) = v;
        end
        if ~isempty(problems)
            % Refusing here is the point: a value we cannot read would
            % otherwise be dropped from the INSERT without the user noticing.
            uialert(f, strjoin(problems, newline), "Invalid input");
            return
        end
        out.OK = true;
        out.Values = vals;
        uiresume(f);
    end
end

% =============================================================================
function w = local_makeWidget(parent, s)
    switch s.Type
        case "textarea"
            w = uitextarea(parent, "Value", cellstr(splitlines(local_initStr(s.Value))));
        case "number"
            w = uieditfield(parent, "text", "Value", local_initNum(s.Value), ...
                "Placeholder", "number");
        case "enum"
            items = [""; string(s.Choices(:))];
            w = uidropdown(parent, "Items", cellstr(items), ...
                "Value", char(local_initEnum(s.Value, items)));
        case "bool"
            w = uicheckbox(parent, "Text", "", "Value", local_initBool(s.Value));
        case "datetime"
            % uidatepicker captures a calendar date only. The database columns
            % behind these fields are timestamptz, so pair the picker with a
            % time-of-day field — otherwise every value written from this form
            % is floored to midnight, including prefilled values carried
            % forward by a supersede.
            [d0, t0] = local_initDatetime(s.Value);
            w = uigridlayout(parent, [1 2]);
            w.ColumnWidth = {'1.5x', '1x'};
            w.RowHeight = {'1x'};
            w.Padding = [0 0 0 0];
            w.ColumnSpacing = 4;
            uidatepicker(w, "Value", d0, "Tag", "date");
            uieditfield(w, "text", "Value", char(t0), "Tag", "time", ...
                "Placeholder", "HH:mm:ss", ...
                "Tooltip", "Time of day, 24-hour (blank = 00:00:00)");
        otherwise   % "text"
            w = uieditfield(parent, "text", "Value", local_initStr(s.Value));
    end
end

function [v, err] = local_readWidget(w, type)
    %LOCAL_READWIDGET Read one widget. ERR is "" unless the entry is unreadable.
    err = "";
    switch type
        case "textarea"
            v = strjoin(string(w.Value), newline);
            v = strtrim(v);
        case "number"
            txt = strtrim(string(w.Value));
            v = str2double(txt);
            if strlength(txt) == 0
                v = NaN;                     % blank means "not provided"
            elseif isnan(v)
                err = "'" + txt + "' is not a number.";
            end
        case "bool"
            v = logical(w.Value);
        case "datetime"
            [v, err] = local_readDatetime(w);
        otherwise   % text / enum
            v = strtrim(string(w.Value));
    end
end

function [v, err] = local_readDatetime(w)
    %LOCAL_READDATETIME Recombine the date picker and the time-of-day field.
    err = "";
    dp = local_child(w, "date");
    te = local_child(w, "time");
    d = dp.Value;
    if isempty(d) || isnat(d)
        v = NaT;
        return
    end
    v = dateshift(d, "start", "day");
    txt = strtrim(string(te.Value));
    if strlength(txt) == 0
        return                                % date only -> midnight
    end
    [tod, ok] = local_parseTimeOfDay(txt);
    if ~ok
        err = "'" + txt + "' is not a time of day (use HH:mm or HH:mm:ss).";
        return
    end
    v = v + tod;
end

function [tod, ok] = local_parseTimeOfDay(txt)
    tod = duration(0, 0, 0);
    ok = false;
    tok = regexp(txt, '^(\d{1,2}):(\d{1,2})(?::(\d{1,2}(?:\.\d+)?))?$', ...
        'tokens', 'once');
    if isempty(tok)
        return
    end
    hh = str2double(tok{1});
    mm = str2double(tok{2});
    ss = 0;
    if numel(tok) >= 3 && ~isempty(tok{3})
        ss = str2double(tok{3});
    end
    if hh > 23 || mm > 59 || ss >= 60
        return
    end
    tod = duration(hh, mm, ss);
    ok = true;
end

function c = local_child(w, tag)
    %LOCAL_CHILD Fetch a tagged child of a composite widget by Tag, not by
    %   position — Children order is not part of the documented interface.
    kids = w.Children;
    c = kids(find(string({kids.Tag}) == tag, 1));
end

function local_setEnable(w, state)
    %LOCAL_SETENABLE Disable a widget, or all children of a composite widget
    %   (the datetime pair is a layout container with no Enable property).
    if isprop(w, "Enable")
        w.Enable = state;
        return
    end
    kids = w.Children;
    for i = 1:numel(kids)
        if isprop(kids(i), "Enable")
            kids(i).Enable = state;
        end
    end
end

% ---- initial-value coercion --------------------------------------------------
function s = local_initStr(v)
    if isempty(v) || (isstring(v) && isscalar(v) && ismissing(v))
        s = "";
    elseif isdatetime(v)
        if isnat(v)
            s = "";
        else
            v.Format = "yyyy-MM-dd HH:mm:ss";
            s = string(v);
        end
    else
        s = string(v);
    end
    s = char(s);
end

function [d, tstr] = local_initDatetime(val)
    %LOCAL_INITDATETIME Split a spec's initial Value into a date and a time.
    %   D feeds the uidatepicker (unzoned, which is what the picker accepts)
    %   and TSTR the paired time field. Midnight leaves the time field blank,
    %   which reads back as midnight, so date-only columns stay uncluttered.
    d = NaT;
    tstr = "";
    if isempty(val) || (isstring(val) && isscalar(val) && ismissing(val))
        return
    end
    if isdatetime(val)
        v = val;
    else
        try
            v = datetime(string(val), "TimeZone", "local");
        catch
            return
        end
    end
    if ~isscalar(v) || isnat(v)
        return
    end
    v.TimeZone = "";                      % keep the wall-clock reading
    d = dateshift(v, "start", "day");
    if v > d
        tstr = string(v, "HH:mm:ss");
    end
end

function s = local_initNum(v)
    if isempty(v)
        s = "";
    elseif isstring(v) && isscalar(v) && (ismissing(v) || strlength(v) == 0)
        s = "";
    elseif isnumeric(v) && isnan(v)
        s = "";
    else
        s = char(string(v));
    end
end

function v = local_initEnum(val, items)
    v = local_initStr(val);
    if ~ismember(string(v), items)
        v = "";
    end
end

function tf = local_initBool(v)
    %LOCAL_INITBOOL Coerce an initial Value to a checkbox state, never throwing.
    %   A SQL NULL arrives here as NaN and logical(NaN) errors; this runs during
    %   form construction, where nothing would catch it and the editor would
    %   simply fail to open.
    if isempty(v) ...
            || (isstring(v) && isscalar(v) && ismissing(v)) ...
            || (isnumeric(v) && any(isnan(v(:))))
        tf = false;
    elseif isstring(v) || ischar(v)
        s = lower(strtrim(string(v)));
        tf = ismember(s, ["1","true","t","yes","on"]);
    else
        try
            tf = logical(v(1));
        catch
            tf = false;
        end
    end
end

function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [su(3)/2 - w/2, su(4)/2 - h/2, w, h];
end
