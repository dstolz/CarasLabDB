function showVariableEditor(obj, kind, entityId)
%SHOWVARIABLEEDITOR View and edit the variables of one row (toolbar "Variables…", Ctrl+L).
%
%   showVariableEditor(obj, kind, entityId)
%
%   KIND is "subject", "session", "event", "artifact" or "project" and
%   ENTITYID the row's id. Variables are the lab's user-defined named values
%   ('probe depth' = 1200 um on a session, 'housing' = 'pair' on an animal;
%   see lab.variable / lab.variable_value). The first line names the row
%   (CarasLabDBApp.describeRow) so it can be checked against the row selected
%   in the main window. The window lists the row's current variables -- label,
%   name, value with units, when and by whom it was set -- or, with History
%   ticked, every value ever set or unset, oldest first. Editing goes through
%   the CarasLabDB variable methods, i.e. through lab.fn_set_variable and
%   lab.fn_unset_variable, so every rule is the database's:
%
%     Variable   the definitions that apply to KIND rows (getVariableDefinitions);
%                the chosen one's type and units are shown next to the value
%                and cannot be changed here -- they are fixed by the definition.
%                Selecting a row of the list chooses its variable and shows its
%                current value, ready to edit.
%     Value      a number variable takes plain decimal notation (71.9, never
%                71,9: CarasLabDBApp.parseNumber) and is passed as a number; a
%                text variable is passed as text.
%     Note       optional, stored with the value saved or unset.
%     Save       CarasLabDB.setVariable (Ctrl+S). Saving the value the row
%                already has is refused: nothing is written.
%     Unset      CarasLabDB.unsetVariable (Delete), after a confirmation.
%     New…       define a new variable -- name, label, number or text, units,
%                description -- and set its first value on this row (Ctrl+N).
%                The definition and the value are written in one call.
%
%   Nothing is written by typing, by Enter in a text box or when a box loses
%   focus: only Save, Unset (confirmed) and the New… form's OK write. A
%   refusal by the database (other units, a retired variable, a variable that
%   does not apply to this kind of row) is shown as an alert with the
%   database's message. Esc closes.
%
%   See also CARASLABDB/SETVARIABLE, CARASLABDB/UNSETVARIABLE,
%   CARASLABDB/GETVARIABLES, CARASLABDB/GETVARIABLEDEFINITIONS,
%   CARASLABDBAPP/SHOWTAGEDITOR, CARASLABDBAPP/SHOWSHORTCUTHELP.

    arguments
        obj (1,1) CarasLabDBApp
        kind (1,1) string {mustBeMember(kind, ["event", "artifact", "subject", "session", "project"])}
        entityId (1,1) string
    end

    db = obj.Db;
    people = local_people(db);

    % State shared with the nested callbacks.
    NONE        = "-";                  % picker entry "no variable chosen" (never a valid name)
    pick        = local_emptyPick();    % the variables offered in the picker
    cur         = local_emptyCurrent(); % the row's current values
    rowNames    = strings(0, 1);        % variable name of each row shown in the list
    showHistory = false;
    newName     = "";                   % set by the New… form's accept hook

    % ---- window ---------------------------------------------------------
    f = uifigure("Name", "Variables · " + kind + " " + entityId, ...
        "Position", local_center(880, 480), "WindowStyle", "modal", ...
        "KeyPressFcn", @(~,e) onKey(e));
    g = uigridlayout(f, [5 1]);
    g.RowHeight = {22, '1x', 30, 22, 30};
    g.ColumnWidth = {'1x'};
    g.Padding = [10 10 10 10];
    g.RowSpacing = 6;

    hdr = uigridlayout(g, [1 2]);
    hdr.ColumnWidth = {'1x', 90};
    hdr.Padding = [0 0 0 0];
    rowText = CarasLabDBApp.describeRow(db, kind, entityId);
    uilabel(hdr, "Text", char(rowText), "FontWeight", "bold", "Tooltip", char(rowText));
    histCb = uicheckbox(hdr, "Text", "History", ...
        "Tooltip", "Show every value ever set or unset on this row instead of the current values", ...
        "ValueChangedFcn", @(~,~) onHistory());

    tbl = uitable(g, "RowName", {}, "ColumnSortable", false, ...
        "SelectionType", "row", "Multiselect", "off", ...
        "CellSelectionCallback", @(~,e) onPick(e));

    ed = uigridlayout(g, [1 7]);
    ed.ColumnWidth = {'1.4x', '1x', 110, '1x', 60, 60, 60};
    ed.Padding = [0 0 0 0];
    ed.ColumnSpacing = 4;
    varDd = uidropdown(ed, "Items", {'(choose a variable)'}, "ItemsData", {char(NONE)}, ...
        "Value", char(NONE), ...
        "Tooltip", "The variable to set or unset (those that apply to " + kind + " rows)", ...
        "ValueChangedFcn", @(~,~) onVariable());
    % No callback on the two text boxes: a box also commits when it loses
    % focus, so a write there could save a value the user did not confirm.
    valEd = uieditfield(ed, "text", "Placeholder", "value", ...
        "Tooltip", "The value. Typing here writes nothing: press Save (Ctrl+S).");
    unitsLbl = uilabel(ed, "Text", "", ...
        "Tooltip", "Type and units are fixed by the variable's definition");
    noteEd = uieditfield(ed, "text", "Placeholder", "note (optional)", ...
        "Tooltip", "Stored with the value you save or unset");
    uibutton(ed, "Text", "Save", "Tooltip", "Save the value (Ctrl+S)", ...
        "ButtonPushedFcn", @(~,~) onSave());
    uibutton(ed, "Text", "Unset", ...
        "Tooltip", "Remove the chosen variable's value from this row (Delete)", ...
        "ButtonPushedFcn", @(~,~) onUnset());
    uibutton(ed, "Text", "New…", ...
        "Tooltip", "Define a new variable and set it on this row (Ctrl+N)", ...
        "ButtonPushedFcn", @(~,~) onNew());

    hint = uilabel(g, "Text", "", "FontColor", [0.35 0.35 0.35]);

    foot = uigridlayout(g, [1 3]);
    foot.ColumnWidth = {'1x', 80, 90};
    foot.Padding = [0 0 0 0];
    status = uilabel(foot, "Text", "");
    uibutton(foot, "Text", "Help", "Tooltip", "Keyboard shortcuts (Ctrl+?)", ...
        "ButtonPushedFcn", @(~,~) CarasLabDBApp.showShortcutHelp(f, "variables"));
    uibutton(foot, "Text", "Close", "Tooltip", "Close (Esc)", ...
        "ButtonPushedFcn", @(~,~) uiresume(f));

    reload(NONE);
    try
        focus(varDd);
    catch
    end

    uiwait(f);
    if isvalid(f), delete(f); end
    return

    % ---- nested callbacks -------------------------------------------------
    function onKey(e)
        %ONKEY Shortcuts while the list or a button has focus (a uifigure
        %   does not forward keys while a text box has focus).
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "variables");
        elseif key == "escape"
            uiresume(f);
        elseif (key == "s" || key == "return") && ctrl
            onSave();
        elseif key == "n" && ctrl
            onNew();
        elseif key == "r" && ctrl
            reload(string(varDd.Value));
        elseif key == "delete"
            onUnset();
        end
    end

    function reload(keepName)
        %RELOAD Re-read the definitions and the row's values (and its log).
        %   KEEPNAME is the variable to leave chosen in the picker, if it is
        %   still offered.
        try
            defRows = db.getVariableDefinitions();
            valRows = db.getVariables(kind, entityId);
            logRows = table();
            if showHistory
                logRows = db.getVariables(kind, entityId, History=true);
            end
        catch loadErr
            uialert(f, string(loadErr.message), "Load variables failed");
            return
        end
        cur  = local_current(valRows, people);
        pick = local_pick(defRows, kind, cur);
        if showHistory
            [listed, rowNames] = local_historyTable(logRows, pick, people);
        else
            [listed, rowNames] = local_currentTable(cur);
        end
        tbl.Data = listed;
        tbl.Selection = [];

        labels = reshape(cellstr(["(choose a variable)"; pick.Shown]), 1, []);
        datas  = reshape(cellstr([NONE; pick.Name]), 1, []);
        set(varDd, "Items", labels, "ItemsData", datas);
        if ismember(string(keepName), pick.Name)
            varDd.Value = char(keepName);
        else
            varDd.Value = char(NONE);
        end
        onVariable();
    end

    function onHistory()
        showHistory = logical(histCb.Value);
        reload(string(varDd.Value));
    end

    function onVariable()
        %ONVARIABLE Show the chosen variable's type, units and current value.
        %   The Value box is filled with the row's current value (blank if it
        %   has none), ready to be edited; nothing is written.
        chosen = string(varDd.Value);
        p = find(pick.Name == chosen, 1);
        if isempty(p)
            unitsLbl.Text = "";
            valEd.Value = '';
            hint.Text = "Choose a variable to set its value on this row, or press New… to define one.";
            hint.Tooltip = "";
            return
        end
        unitsLbl.Text = char(pick.TypeUnits(p));
        c = find(cur.Name == chosen, 1);
        if isempty(c)
            valEd.Value = '';
            state = "no value on this row yet";
        else
            valEd.Value = char(cur.Value(c));
            state = "now " + cur.Shown(c) + ", set " + cur.When(c);
            if strlength(cur.Who(c)) > 0
                state = state + " by " + cur.Who(c);
            end
        end
        about = pick.Shown(p);
        if strlength(pick.Desc(p)) > 0
            about = about + ": " + pick.Desc(p);
        end
        hint.Text = about + " · " + state;
        hint.Tooltip = hint.Text;           % the line can be longer than the window
    end

    function onPick(e)
        %ONPICK Selecting a row of the list chooses its variable.
        if isempty(e.Indices) || isempty(rowNames)
            return
        end
        r = e.Indices(1, 1);
        if r < 1 || r > numel(rowNames)
            return
        end
        picked = rowNames(r);
        if ismember(picked, pick.Name) && string(varDd.Value) ~= picked
            varDd.Value = char(picked);
            onVariable();
        end
    end

    function onSave()
        %ONSAVE Save button (or Ctrl+S): set the chosen variable to the typed value.
        chosen = string(varDd.Value);
        p = find(pick.Name == chosen, 1);
        if isempty(p)
            uialert(f, "Choose a variable first, or press New… to define one.", "Variables");
            return
        end
        txt = strtrim(string(valEd.Value));
        if strlength(txt) == 0
            uialert(f, "Type a value first. To remove the value from this row use Unset.", ...
                "Variables");
            return
        end
        if pick.Type(p) == "number"
            % The same reading of a typed number as everywhere in the app:
            % no comma is ever passed to str2double.
            [newValue, problem] = CarasLabDBApp.parseNumber(txt);
            if strlength(problem) > 0
                uialert(f, pick.Label(p) + ": " + problem, "Invalid value");
                return
            end
        else
            newValue = txt;
        end

        % Setting the value the row already has would only add a duplicate
        % row to the log: refuse it.
        c = find(cur.Name == chosen, 1);
        if ~isempty(c)
            if isnumeric(newValue)
                same = ~isnan(cur.Num(c)) && cur.Num(c) == newValue;
            else
                same = ~ismissing(cur.Text(c)) && cur.Text(c) == newValue;
            end
            if same
                status.Text = chosen + " is already " + cur.Shown(c) + ": nothing was written.";
                uialert(f, chosen + " is already " + cur.Shown(c) + ...
                    " on this row. Nothing was written.", "Variables", "Icon", "info");
                return
            end
        end

        shownNew = strtrim(txt + " " + pick.Units(p));
        saveArgs = {};
        noteText = strtrim(string(noteEd.Value));
        if strlength(noteText) > 0
            saveArgs = {"Note", noteText};
        end
        try
            db.setVariable(kind, entityId, chosen, newValue, saveArgs{:});
        catch saveErr
            % Other units, a retired variable, a kind it does not apply to:
            % the database's own explanation.
            uialert(f, string(saveErr.message), "Variable not saved");
            return
        end
        noteEd.Value = '';
        reload(chosen);
        status.Text = "Saved " + chosen + " = " + shownNew + ".";
    end

    function onUnset()
        %ONUNSET Unset button (or Delete): clear the chosen variable on this row.
        chosen = string(varDd.Value);
        if chosen == NONE
            uialert(f, "Choose a variable, or select its row in the list, first.", ...
                "Unset variable");
            return
        end
        c = find(cur.Name == chosen, 1);
        if isempty(c)
            uialert(f, "This row has no value for " + chosen + ", so there is nothing to unset.", ...
                "Unset variable");
            return
        end
        noteText = strtrim(string(noteEd.Value));
        question = "Unset " + chosen + " (now " + cur.Shown(c) + ") on this " + kind + "?" + ...
            newline + newline + "The row then has no current value for it. Every earlier " + ...
            "value stays in the history.";
        if strlength(noteText) > 0
            question = question + newline + newline + "Note: " + noteText;
        else
            question = question + newline + newline + "No note was typed. To record why, " + ...
                "cancel and type one in the note box first.";
        end
        answer = uiconfirm(f, question, "Unset variable", ...
            "Options", {'Unset', 'Cancel'}, ...
            "DefaultOption", 2, "CancelOption", 2, "Icon", "warning");
        if ~strcmp(answer, 'Unset')
            return
        end
        unsetArgs = {};
        if strlength(noteText) > 0
            unsetArgs = {"Note", noteText};
        end
        try
            db.unsetVariable(kind, entityId, chosen, unsetArgs{:});
        catch unsetErr
            uialert(f, string(unsetErr.message), "Variable not unset");
            return
        end
        noteEd.Value = '';
        reload(chosen);
        status.Text = "Unset " + chosen + ".";
    end

    function onNew()
        %ONNEW New… button (or Ctrl+N): define a variable and set it on this row.
        %   One form asks for the definition and the first value; its accept
        %   hook (acceptNew) writes both with one setVariable call while the
        %   form is still open, so a refusal loses nothing typed.
        specs = [ ...
            local_spec("Name", "Name", "text", "e.g. probe depth"), ...
            local_spec("Label", "Label (shown to people)", "text", "e.g. Probe Depth (blank = the name)"), ...
            local_spec("Type", "Type", "enum", ""), ...
            local_spec("Units", "Units", "text", "e.g. um, g, dB SPL (blank = none)"), ...
            local_spec("Description", "Description", "text", "what the variable means"), ...
            local_spec("Value", "Value on this row", "text", "its first value"), ...
            local_spec("Note", "Note", "text", "optional, stored with the value")];
        specs(3).Choices = ["number", "text"];
        specs(3).Value = "number";
        newName = "";
        res = CarasLabDBApp.pFormDialog("New variable", specs, "for " + rowText, @acceptNew);
        if ~res.OK || strlength(newName) == 0
            return
        end
        defined = newName;
        reload(defined);
        status.Text = "Defined " + defined + " and set it on this " + kind + ".";
    end

    function accepted = acceptNew(formValues, formFig)
        %ACCEPTNEW Check a new definition and write it with its first value.
        %   An error thrown by normalizeVariableName (a malformed name) is
        %   shown by pFormDialog as an alert on the form.
        accepted = false;
        if strlength(formValues.Name) == 0
            uialert(formFig, "Name is required.", "New variable");
            return
        end
        canon = string(CarasLabDB.normalizeVariableName(formValues.Name));
        if ismember(canon, pick.Name)
            uialert(formFig, "A variable named '" + canon + "' already exists. Cancel " + ...
                "this form and choose it in the Variable list.", "New variable");
            return
        end
        if strlength(formValues.Type) == 0
            uialert(formFig, "Choose the type: number or text. It cannot be changed " + ...
                "once the variable has a value.", "New variable");
            return
        end
        if strlength(formValues.Value) == 0
            uialert(formFig, "A value is required: the variable is defined by setting " + ...
                "it for the first time.", "New variable");
            return
        end
        if formValues.Type == "number"
            [firstValue, problem] = CarasLabDBApp.parseNumber(formValues.Value);
            if strlength(problem) > 0
                uialert(formFig, "Value: " + problem, "Invalid value");
                return
            end
        else
            firstValue = formValues.Value;
        end
        defArgs = {};
        if strlength(formValues.Units) > 0
            defArgs = [defArgs, {"Units", formValues.Units}];
        end
        if strlength(formValues.Label) > 0
            defArgs = [defArgs, {"Label", formValues.Label}];
        end
        if strlength(formValues.Description) > 0
            defArgs = [defArgs, {"Description", formValues.Description}];
        end
        if strlength(formValues.Note) > 0
            defArgs = [defArgs, {"Note", formValues.Note}];
        end
        try
            db.setVariable(kind, entityId, canon, firstValue, defArgs{:});
        catch newErr
            % For example a name that exists already for another kind of
            % row, or in other units: the database's own explanation.
            uialert(formFig, string(newErr.message), "Variable not saved");
            return
        end
        newName = canon;
        accepted = true;
    end
end

% =============================================================================
function s = local_spec(key, label, type, placeholder)
    %LOCAL_SPEC One field of the New variable form (see pFormDialog).
    s = struct("Key", string(key), "Label", string(label), "Type", string(type), ...
        "Choices", strings(1, 0), "Value", "", "Editable", true, ...
        "Placeholder", string(placeholder));
end

function pick = local_emptyPick()
    z = strings(0, 1);
    pick = struct("Name", z, "Label", z, "Units", z, "Type", z, "Desc", z, ...
        "TypeUnits", z, "Shown", z);
end

function cur = local_emptyCurrent()
    z = strings(0, 1);
    cur = struct("Name", z, "Label", z, "Value", z, "Num", zeros(0, 1), "Text", z, ...
        "Units", z, "Type", z, "Note", z, "When", z, "Who", z, "Shown", z);
end

function cur = local_current(C, people)
    %LOCAL_CURRENT The row's current values (getVariables) as string columns.
    %   Value is the value as text exactly as stored; Num / Text the typed
    %   value for comparison; Shown the value with its units.
    cur = local_emptyCurrent();
    if ~istable(C) || height(C) == 0
        return
    end
    cur.Name  = local_text(C.variable);
    cur.Label = local_text(C.label);
    cur.Value = local_blank(local_text(C.value));
    cur.Num   = local_num(C.value_num);
    cur.Text  = local_text(C.value_text);
    cur.Units = local_blank(local_text(C.units));
    cur.Type  = local_text(C.value_type);
    cur.Note  = local_blank(local_text(C.note));
    cur.When  = local_when(C.set_at);
    cur.Who   = local_who(C.set_by, C.set_login, people);
    missingLabel = ismissing(cur.Label);
    cur.Label(missingLabel) = cur.Name(missingLabel);
    cur.Shown = strtrim(cur.Value + " " + cur.Units);
end

function pick = local_pick(D, kind, cur)
    %LOCAL_PICK The variables offered in the picker.
    %   The definitions (getVariableDefinitions, retired ones left out) that
    %   apply to KIND, then any variable the row carries that is not among
    %   them (retired since, or no longer for this kind of row) so that it
    %   can still be chosen and unset.
    pick = local_emptyPick();
    if istable(D) && height(D) > 0
        names = local_text(D.name);
        keep  = local_applies(D.applies_to, kind) & ~ismissing(names);
        label = local_text(D.label);
        units = local_blank(local_text(D.units));
        vtype = local_text(D.value_type);
        desc  = local_blank(local_text(D.description));
        pick.Name  = names(keep);
        pick.Label = label(keep);
        pick.Units = units(keep);
        pick.Type  = vtype(keep);
        pick.Desc  = desc(keep);
    end
    extra = ~ismember(cur.Name, pick.Name);
    if any(extra)
        n = nnz(extra);
        pick.Name  = [pick.Name;  cur.Name(extra)];
        pick.Label = [pick.Label; cur.Label(extra)];
        pick.Units = [pick.Units; cur.Units(extra)];
        pick.Type  = [pick.Type;  cur.Type(extra)];
        pick.Desc  = [pick.Desc;  repmat("no longer offered for new values " + ...
            "(retired, or not for this kind of row)", n, 1)];
    end
    missingLabel = ismissing(pick.Label);
    pick.Label(missingLabel) = pick.Name(missingLabel);
    pick.Type(ismissing(pick.Type)) = "text";

    unitText = pick.Units;
    unitText(strlength(unitText) == 0) = "no units";
    pick.TypeUnits = pick.Type + " · " + unitText;

    pick.Shown = pick.Label + " (" + pick.Name + ")";
    sameAsName = lower(pick.Label) == pick.Name;
    pick.Shown(sameAsName) = pick.Name(sameAsName);
    hasUnits = strlength(pick.Units) > 0;
    pick.Shown(hasUnits) = pick.Shown(hasUnits) + " [" + pick.Units(hasUnits) + "]";
end

function tf = local_applies(col, kind)
    %LOCAL_APPLIES Which definitions apply to rows of KIND.
    %   applies_to is read as text whatever its form ("event,artifact",
    %   "{event,artifact}", or a list per row): KIND applies when it is one
    %   of the words. A value that cannot be read does not hide the variable.
    n = numel(col);
    tf = true(n, 1);
    for i = 1:n
        try
            if iscell(col)
                v = col{i};
            else
                v = col(i);
            end
            t = strjoin(reshape(string(v), 1, []), ",");
            if ismissing(t) || strlength(t) == 0
                continue
            end
            words = string(regexp(char(lower(t)), '[a-z]+', 'match'));
            tf(i) = ismember(kind, words);
        catch
            tf(i) = true;
        end
    end
end

function [T, names] = local_currentTable(cur)
    %LOCAL_CURRENTTABLE The list of current values, and each row's variable name.
    cols = ["Variable", "Name", "Value", "Set", "By", "Note"];
    names = cur.Name;
    if isempty(names)
        T = local_emptyTable(cols);
        return
    end
    T = table(cur.Label, cur.Name, cur.Shown, cur.When, cur.Who, cur.Note, ...
        'VariableNames', cellstr(cols));
end

function [T, names] = local_historyTable(H, pick, people)
    %LOCAL_HISTORYTABLE The value log (oldest first), and each row's variable name.
    cols = ["Name", "Op", "Value", "Set", "By", "Note"];
    names = strings(0, 1);
    if ~istable(H) || height(H) == 0
        T = local_emptyTable(cols);
        return
    end
    names = local_text(H.variable);
    num = local_num(H.value_num);
    txt = local_text(H.value_text);
    val = strings(numel(names), 1);
    for i = 1:numel(names)
        if ~ismissing(txt(i))
            val(i) = txt(i);
        elseif ~isnan(num(i))
            val(i) = local_numText(num(i));
        end
        j = find(pick.Name == names(i), 1);
        if strlength(val(i)) > 0 && ~isempty(j) && strlength(pick.Units(j)) > 0
            val(i) = val(i) + " " + pick.Units(j);
        end
    end
    T = table(names, local_blank(local_text(H.op)), val, local_when(H.set_at), ...
        local_who(H.set_by, H.set_login, people), local_blank(local_text(H.note)), ...
        'VariableNames', cellstr(cols));
end

function T = local_emptyTable(cols)
    T = table('Size', [0 numel(cols)], ...
        'VariableTypes', repmat({'string'}, 1, numel(cols)), ...
        'VariableNames', cellstr(cols));
end

function s = local_numText(x)
    %LOCAL_NUMTEXT A number as the shortest text that reads back the same.
    try
        s = string(CarasLabDB.sqlLiteral(double(x)));
    catch
        s = string(x);
    end
end

function s = local_text(col)
    %LOCAL_TEXT A fetched text column as a string column vector (NULL -> missing).
    if iscell(col)
        s = strings(numel(col), 1);
        for i = 1:numel(col)
            v = col{i};
            if (isstring(v) && isscalar(v)) || ischar(v)
                s(i) = string(v);
            elseif isnumeric(v) && isscalar(v) && ~isnan(v)
                s(i) = string(v);
            else
                s(i) = string(missing);
            end
        end
    elseif isnumeric(col)
        s = reshape(string(col), [], 1);
        s(isnan(reshape(double(col), [], 1))) = string(missing);   % a column of NULLs
    else
        s = reshape(string(col), [], 1);
    end
end

function s = local_blank(s)
    %LOCAL_BLANK Missing text shown as "".
    s(ismissing(s)) = "";
end

function x = local_num(col)
    %LOCAL_NUM A fetched numeric column as a double column vector (NULL -> NaN).
    if isnumeric(col)
        x = double(reshape(col, [], 1));
    elseif iscell(col)
        x = nan(numel(col), 1);
        for i = 1:numel(col)
            v = col{i};
            if isnumeric(v) && isscalar(v)
                x(i) = double(v);
            end
        end
    else
        % Text: read like any other number in the app (no bare str2double).
        t = reshape(string(col), [], 1);
        x = nan(numel(t), 1);
        for i = 1:numel(t)
            if ~ismissing(t(i))
                x(i) = CarasLabDBApp.parseNumber(t(i));
            end
        end
    end
end

function s = local_when(col)
    %LOCAL_WHEN Timestamps as "yyyy-MM-dd HH:mm" text (the session zone is local).
    if isdatetime(col)
        col.Format = "yyyy-MM-dd HH:mm";
        s = reshape(string(col), [], 1);
    else
        s = local_text(col);
    end
    s(ismissing(s)) = "";
end

function s = local_who(byCol, loginCol, people)
    %LOCAL_WHO Who set a value: the person's name where known, else the login.
    s = local_text(byCol);
    login = local_text(loginCol);
    for i = 1:numel(s)
        if ~ismissing(s(i)) && isKey(people, char(s(i)))
            s(i) = string(people(char(s(i))));
        elseif ismissing(s(i)) || strlength(s(i)) == 0
            if i <= numel(login) && ~ismissing(login(i)) && strlength(login(i)) > 0
                s(i) = "login " + login(i);
            else
                s(i) = "";
            end
        end
    end
end

function m = local_people(db)
    %LOCAL_PEOPLE person_id -> full_name, or an empty map if it cannot be read.
    m = containers.Map('KeyType', 'char', 'ValueType', 'any');
    try
        P = db.getPersons();
        ids = local_text(P.person_id);
        names = local_text(P.full_name);
        for i = 1:numel(ids)
            m(char(ids(i))) = names(i);
        end
    catch
    end
end

function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [su(3)/2 - w/2, su(4)/2 - h/2, w, h];
end
