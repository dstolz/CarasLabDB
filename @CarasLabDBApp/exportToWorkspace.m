function exportToWorkspace(obj)
%EXPORTTOWORKSPACE Assign the focused table (browse or SQL results) to base.
%
%   Prompts for a variable name (validated with matlab.lang.makeValidName) and
%   assigns the currently displayed table into the base workspace so the user
%   can analyze the filtered result in MATLAB.
%
%   See also CARASLABDBAPP, ASSIGNIN.

    key = string(obj.UI.TabGroup.SelectedTab.Tag);
    if key == "sql"
        T = obj.UI.SqlResults.Data;
        defName = "sql_result";
    else
        T = obj.UI.Tables.(key).Data;
        defName = key;
    end

    if isempty(T)
        uialert(obj.Fig, "There is no data to export on this tab.", "Export");
        return
    end

    name = local_promptName(defName);
    if name == ""
        return   % cancelled
    end
    name = string(matlab.lang.makeValidName(name));

    assignin("base", char(name), T);
    obj.pStatus("Exported " + string(height(T)) + " row(s) to base variable '" + name + "'.");
end

% =============================================================================
function name = local_promptName(defName)
    %LOCAL_PROMPTNAME Small modal asking for a workspace variable name.
    name = "";
    f = uifigure("Name", "Export to workspace", ...
        "Position", local_center(360, 130), "WindowStyle", "modal", "Resize", "off", ...
        "KeyPressFcn", @(~,e) onKeyPress(e));
    g = uigridlayout(f, [2 2]);
    g.RowHeight = {30, 34};
    g.ColumnWidth = {110, '1x'};
    g.Padding = [15 15 15 15];

    uilabel(g, "Text", "Variable name", "HorizontalAlignment", "right");
    % Enter must be handled on the field too: a uifigure does not forward
    % keystrokes to its KeyPressFcn while a text component has focus.
    ed = uieditfield(g, "text", "Value", char(defName), ...
        "ValueChangedFcn", @(~,~) onOk());

    brow = uigridlayout(g, [1 2]);
    brow.Layout.Row = 2; brow.Layout.Column = [1 2];
    brow.ColumnWidth = {'1x', '1x'};
    brow.Padding = [0 0 0 0];
    uibutton(brow, "Text", "Cancel", "ButtonPushedFcn", @(~,~) onCancel());
    uibutton(brow, "Text", "Export", "ButtonPushedFcn", @(~,~) onOk());

    uiwait(f);
    if isvalid(f), delete(f); end
    return

    function onKeyPress(e)
        %ONKEYPRESS Enter exports, Escape cancels, Ctrl+? lists the shortcuts.
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "export");
        elseif key == "return"
            onOk();
        elseif key == "escape"
            onCancel();
        end
    end

    function onCancel()
        uiresume(f);
    end
    function onOk()
        name = strtrim(string(ed.Value));
        uiresume(f);
    end
end

function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [su(3)/2 - w/2, su(4)/2 - h/2, w, h];
end
