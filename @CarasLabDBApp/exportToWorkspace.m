function exportToWorkspace(obj)
%EXPORTTOWORKSPACE Assign the focused table (browse or SQL results) to base.
%
%   Prompts for a variable name (validated with matlab.lang.makeValidName) and
%   assigns the currently displayed table into the base workspace so the user
%   can analyze the filtered result in MATLAB. Only the Export button (or
%   Enter on it) exports; an existing variable of that name is replaced only
%   after confirmation; and when the tab's query was cut off at the row limit
%   the status line and an alert say that the export is incomplete.
%
%   See also CARASLABDBAPP, ASSIGNIN.

    key = string(obj.UI.TabGroup.SelectedTab.Tag);
    capped = false;
    if key == "sql"
        T = obj.UI.SqlResults.Data;
        defName = "sql_result";
    else
        T = obj.UI.Tables.(key).Data;
        defName = key;
        % applyFilters records whether this tab's query hit the row limit.
        capped = isfield(obj.Capped, char(key)) && logical(obj.Capped.(char(key)));
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

    % Never replace a variable the user already has without asking. NAME is a
    % valid identifier at this point, so it is safe inside the expression.
    exists = false;
    try
        exists = evalin("base", char("exist('" + name + "', 'var')")) == 1;
    catch
    end
    if exists
        answer = uiconfirm(obj.Fig, ...
            "A variable named '" + name + "' already exists in the base workspace. Replace it?", ...
            "Export", "Options", {'Replace', 'Cancel'}, ...
            "DefaultOption", 2, "CancelOption", 2, "Icon", "warning");
        if ~strcmp(answer, 'Replace')
            obj.pStatus("Export cancelled: '" + name + "' was left as it is.");
            return
        end
    end

    assignin("base", char(name), T);
    msg = "Exported " + string(height(T)) + " row(s) to base variable '" + name + "'.";
    if capped
        % A capped table is not the whole answer to the filter; an analysis
        % run on it would silently miss rows.
        note = "INCOMPLETE: this tab shows at most " + string(obj.RowLimit) + ...
            " rows and more match. Narrow the filters to export every matching row.";
        msg = msg + " " + note;
        uialert(obj.Fig, "'" + name + "' holds the first " + string(height(T)) + ...
            " rows only. " + note, "Export is incomplete", "Icon", "warning");
    end
    obj.pStatus(msg);
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
    % Typing a name must not export by itself. The field commits on Enter
    % but also when it loses focus (for example to the Cancel button), and
    % the two cannot be told apart; exporting there made Cancel export. So a
    % commit only moves the focus to the Export button, where Enter or Space
    % is the deliberate confirmation.
    ed = uieditfield(g, "text", "Value", char(defName), ...
        "ValueChangedFcn", @(~,~) onNameTyped());

    brow = uigridlayout(g, [1 2]);
    brow.Layout.Row = 2; brow.Layout.Column = [1 2];
    brow.ColumnWidth = {'1x', '1x'};
    brow.Padding = [0 0 0 0];
    uibutton(brow, "Text", "Cancel", "Tooltip", "Cancel (Esc)", ...
        "ButtonPushedFcn", @(~,~) onCancel());
    okBtn = uibutton(brow, "Text", "Export", "Tooltip", "Export (Enter)", ...
        "ButtonPushedFcn", @(~,~) onOk());

    uiwait(f);
    if isvalid(f), delete(f); end
    return

    function onNameTyped()
        %ONNAMETYPED The name was committed: move to the Export button only.
        try
            focus(okBtn);
        catch
        end
    end

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
