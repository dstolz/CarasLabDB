function showTagEditor(obj, entityKind, entityId)
%SHOWTAGEDITOR Modal editor for the tags of one event, artifact, subject, session or project.
%
%   showTagEditor(obj, "artifact", artifactId)
%
%   Lists the entity's current tags, and lets you add one (pick a namespace,
%   then pick or type a value -- or type a whole "namespace:value" tag, or a
%   bare free-form tag) or remove the selected one. Every change goes
%   through CarasLabDB.addTag / removeTag, i.e. lab.fn_tag, so the namespace
%   policy (immutable, single-valued, closed vocabulary) is enforced by the
%   database and any refusal is shown as is. The policy of the chosen
%   namespace is displayed so a refusal is not a surprise.
%
%   Shortcuts: Enter adds, Delete removes the selected tag, Esc closes,
%   Ctrl+? lists them.
%
%   See also CARASLABDBAPP, CARASLABDB/ADDTAG, CARASLABDB/REMOVETAG, CARASLABDB/GETENTITYTAGS.

    arguments
        obj (1,1) CarasLabDBApp
        entityKind (1,1) string
        entityId (1,1) string
    end

    db = obj.Db;

    % Namespaces that may be applied to this kind, with their policies.
    try
        NS = db.getTagNamespaces();
    catch ME
        uialert(obj.Fig, string(ME.message), "Tags");
        return
    end
    keep = false(height(NS), 1);
    for i = 1:height(NS)
        kinds = split(string(NS.applies_to(i)), ",");
        keep(i) = ismember(entityKind, kinds);
    end
    NS = NS(keep, :);
    if height(NS) == 0
        uialert(obj.Fig, "No tag namespace applies to a " + entityKind + ".", "Tags");
        return
    end
    nsNames = string(NS.namespace);
    % The reserved free-form namespace first: it is the one most tags land in.
    [~, order] = sort(nsNames ~= "tag");
    NS = NS(order, :);
    nsNames = nsNames(order);

    f = uifigure("Name", "Tags · " + entityKind + " " + entityId, ...
        "Position", local_center(640, 460), "WindowStyle", "modal", ...
        "KeyPressFcn", @(~,e) onKeyPress(e));
    g = uigridlayout(f, [4 1]);
    g.RowHeight = {'1x', 24, 64, 36};
    g.ColumnWidth = {'1x'};
    g.Padding = [10 10 10 10];
    g.RowSpacing = 6;

    tbl = uitable(g, "ColumnSortable", true, "SelectionType", "row", ...
        "Multiselect", "off", "RowName", {});
    tbl.Layout.Row = 1;

    policy = uilabel(g, "Text", "", "FontColor", [0.35 0.35 0.35]);
    policy.Layout.Row = 2;

    addRow = uigridlayout(g, [2 3]);
    addRow.Layout.Row = 3;
    addRow.RowHeight = {18, 30};
    addRow.ColumnWidth = {160, '1x', 200};
    addRow.Padding = [0 0 0 0];
    addRow.RowSpacing = 2;
    uilabel(addRow, "Text", "Namespace");
    uilabel(addRow, "Text", "Value (or a whole namespace:value tag)");
    uilabel(addRow, "Text", "Note (optional)");
    nsDd = uidropdown(addRow, "Items", cellstr(nsNames), "Value", char(nsNames(1)), ...
        "ValueChangedFcn", @(~,~) refreshValues());
    valDd = uidropdown(addRow, "Items", {''}, "Value", '', "Editable", "on", ...
        "Placeholder", "value");
    noteEd = uieditfield(addRow, "text", "Placeholder", "why / context");

    brow = uigridlayout(g, [1 5]);
    brow.Layout.Row = 4;
    brow.ColumnWidth = {100, 150, 110, '1x', 90};
    brow.Padding = [0 0 0 0];
    uibutton(brow, "Text", "Add", "Tooltip", "Add the tag (Enter)", ...
        "ButtonPushedFcn", @(~,~) onAdd());
    uibutton(brow, "Text", "Remove selected", "Tooltip", "Remove the selected tag (Delete)", ...
        "ButtonPushedFcn", @(~,~) onRemove());
    histCb = uicheckbox(brow, "Text", "Show history", ...
        "ValueChangedFcn", @(~,~) refreshTable());
    uilabel(brow, "Text", "");
    uibutton(brow, "Text", "Close", "Tooltip", "Close (Esc)", ...
        "ButtonPushedFcn", @(~,~) onClose());

    refreshValues();
    refreshTable();
    uiwait(f);
    if isvalid(f), delete(f); end
    return

    % ---- nested callbacks -----------------------------------------------
    function refreshTable()
        try
            T = db.getEntityTags(entityKind, entityId, History=logical(histCb.Value));
        catch ME
            uialert(f, string(ME.message), "Tags");
            return
        end
        vars = string(T.Properties.VariableNames);
        if histCb.Value
            want = ["assignment_id", "tag", "op", "note", "applied_at", "applied_by"];
        else
            want = ["display_tag", "namespace", "value", "note", "applied_at", "applied_by"];
        end
        want = want(ismember(want, vars));
        tbl.Data = T(:, cellstr(want));
        tbl.Selection = [];
    end

    function refreshValues()
        ns = string(nsDd.Value);
        row = NS(nsNames == ns, :);
        if height(row) == 1
            vocab = "open vocabulary (a new value is registered on first use)";
            if ~logical(row.open_vocabulary(1))
                vocab = "closed vocabulary (pick a registered value)";
            end
            card = "any number per " + entityKind;
            if string(row.cardinality(1)) == "single"
                card = "one per " + entityKind;
            end
            mut = "can be changed later";
            if string(row.mutability(1)) == "immutable"
                mut = "permanent once applied";
            end
            policy.Text = ns + ": " + card + " · " + mut + " · " + vocab;
        end
        items = {''};
        try
            TG = db.getTags(Namespace=ns);
            if height(TG) > 0
                items = [{''}; cellstr(string(TG.value))];
            end
        catch
        end
        valDd.Items = items;
        valDd.Value = '';
    end

    function onAdd()
        v = strtrim(string(valDd.Value));
        if strlength(v) == 0
            uialert(f, "Enter or pick a value.", "Tags");
            return
        end
        if contains(v, ":")
            tag = v;                       % a whole tag overrides the namespace
        elseif string(nsDd.Value) == "tag"
            tag = v;                       % bare: the free-form namespace
        else
            tag = string(nsDd.Value) + ":" + v;
        end
        note = string(noteEd.Value);
        if strlength(strtrim(note)) == 0, note = string(missing); end
        try
            db.addTag(entityKind, entityId, tag, Note=note);
        catch ME
            uialert(f, string(ME.message), "Tag not added");
            return
        end
        noteEd.Value = '';
        refreshValues();
        refreshTable();
    end

    function onRemove()
        sel = tbl.Selection;
        if isempty(sel) || isempty(tbl.Data)
            uialert(f, "Select a tag first.", "Tags");
            return
        end
        data = tbl.Data;
        try
            if ~isempty(tbl.DisplayData), data = tbl.DisplayData; end
        catch
        end
        r = sel(1);
        if histCb.Value
            uialert(f, "Untick 'Show history' to remove a current tag.", "Tags");
            return
        end
        % display_tag may be a bare tag; namespace:value is always canonical.
        tag = string(data.namespace(r)) + ":" + string(data.value(r));
        try
            db.removeTag(entityKind, entityId, tag);
        catch ME
            uialert(f, string(ME.message), "Tag not removed");
            return
        end
        refreshTable();
    end

    function onKeyPress(e)
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "tags");
        elseif key == "escape"
            onClose();
        elseif key == "return"
            onAdd();
        elseif key == "delete"
            onRemove();
        end
    end

    function onClose()
        uiresume(f);
    end
end

function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [max(1, su(3)/2 - w/2), max(1, su(4)/2 - h/2), w, h];
end
