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
%       out.Values  - struct keyed by Key. Text/enum/datetime -> string
%                     ("" when blank), number -> double (NaN when blank),
%                     bool -> logical.
%
%   See also CARASLABDBAPP/SHOWEVENTEDITOR.

    arguments
        titleText (1,1) string
        specs struct
    end

    out = struct("OK", false, "Values", struct());
    n = numel(specs);

    figH = min(720, 96 + n * 40);
    f = uifigure("Name", titleText, ...
        "Position", local_center(560, figH), "WindowStyle", "modal");
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
            widgets{i}.Enable = "off";
        end
    end

    brow = uigridlayout(outer, [1 3]);
    brow.ColumnWidth = {'1x', 100, 100};
    brow.Padding = [0 0 0 0];
    uilabel(brow, "Text", "");
    uibutton(brow, "Text", "Cancel", "ButtonPushedFcn", @(~,~) onCancel());
    uibutton(brow, "Text", "OK", "ButtonPushedFcn", @(~,~) onOk());

    uiwait(f);
    if isvalid(f), delete(f); end
    return

    % ---- nested callbacks -----------------------------------------------
    function onCancel()
        uiresume(f);
    end

    function onOk()
        vals = struct();
        for k = 1:n
            vals.(char(specs(k).Key)) = local_readWidget(widgets{k}, specs(k).Type);
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
            w = uieditfield(parent, "text", "Value", local_initStr(s.Value), ...
                "Placeholder", "yyyy-MM-dd HH:mm:ss");
        otherwise   % "text"
            w = uieditfield(parent, "text", "Value", local_initStr(s.Value));
    end
end

function v = local_readWidget(w, type)
    switch type
        case "textarea"
            v = strjoin(string(w.Value), newline);
            v = strtrim(v);
        case "number"
            v = str2double(strtrim(string(w.Value)));   % NaN if blank/invalid
        case "bool"
            v = logical(w.Value);
        otherwise   % text / enum / datetime
            v = strtrim(string(w.Value));
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
    if isempty(v)
        tf = false;
    elseif isstring(v) || ischar(v)
        s = lower(strtrim(string(v)));
        tf = ismember(s, ["1","true","t","yes","on"]);
    else
        tf = logical(v);
    end
end

function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [su(3)/2 - w/2, su(4)/2 - h/2, w, h];
end
