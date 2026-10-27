function showTagEditor(obj, kind, entityId)
%SHOWTAGEDITOR View and edit the tags of one row (toolbar "Tags…", Ctrl+T).
%
%   showTagEditor(obj, kind, entityId)
%
%   KIND is "subject", "session", "event", "artifact" or "project" and
%   ENTITYID the row's id. The window lists the row's current tags (tick
%   History for the full add/remove log) and edits them through the
%   CarasLabDB tag methods, i.e. through lab.fn_tag, so every namespace
%   policy is the database's:
%
%     Namespace  only namespaces whose applies_to includes KIND; the line
%                under the controls states the chosen one's policy.
%     Value      pick a registered value, or type one -- or a whole tag such
%                as qc:fail, which also selects its namespace.
%     Add        CarasLabDB.addTag   (Ctrl+Enter)
%     Set        CarasLabDB.setTag   (Ctrl+S) -- single-valued namespaces only:
%                replaces the current value, does nothing if already set.
%     Remove     CarasLabDB.removeTag on the tag selected in the list (Delete).
%
%   Typing in the Value box never writes anything: the box also commits
%   when it loses focus, so a write there could apply a tag the user did
%   not confirm. Enter in the box selects the typed tag's namespace and
%   moves focus to the Set (single-valued) or Add button, so a second
%   Enter or Space applies it. A policy
%   refusal (closed vocabulary, duplicate, immutable, applies_to) is shown
%   as an alert with the database's message. Esc closes; the main table is
%   refreshed afterwards if anything changed.
%
%   See also CARASLABDB/ADDTAG, CARASLABDB/SETTAG, CARASLABDB/REMOVETAG,
%   CARASLABDB/GETENTITYTAGS, CARASLABDBAPP/SHOWSHORTCUTHELP.

    arguments
        obj (1,1) CarasLabDBApp
        kind (1,1) string {mustBeMember(kind, ["event", "artifact", "subject", "session", "project"])}
        entityId (1,1) string
    end

    db = obj.Db;
    try
        NS = db.getTagNamespaces(AppliesTo=kind);
    catch ME
        uialert(obj.Fig, string(ME.message), "Tags");
        return
    end
    if height(NS) == 0
        uialert(obj.Fig, "No tag namespace applies to " + kind + " rows.", "Tags");
        return
    end

    % Namespace policy, one element per namespace; bare tags ('tag') last.
    nsNames   = local_text(NS.namespace);
    order     = [find(nsNames ~= "tag"); find(nsNames == "tag")];
    nsNames   = nsNames(order);
    nsMut     = local_text(NS.mutability);      nsMut     = nsMut(order);
    nsCard    = local_text(NS.cardinality);     nsCard    = nsCard(order);
    nsApplies = local_text(NS.applies_to);      nsApplies = nsApplies(order);
    nsOpen    = local_bool(NS.open_vocabulary); nsOpen    = nsOpen(order);
    nsLabels  = nsNames;
    nsLabels(nsNames == "tag") = "tag (bare)";

    people      = local_people(db);
    vocab       = table();
    curTags     = strings(0, 1);
    showHistory = false;
    changed     = false;

    % ---- window ---------------------------------------------------------
    f = uifigure("Name", "Tags · " + kind + " " + entityId, ...
        "Position", local_center(700, 440), "WindowStyle", "modal", ...
        "KeyPressFcn", @(~,e) onKey(e));
    g = uigridlayout(f, [5 1]);
    g.RowHeight = {22, '1x', 30, 22, 30};
    g.ColumnWidth = {'1x'};
    g.Padding = [10 10 10 10];
    g.RowSpacing = 6;

    hdr = uigridlayout(g, [1 2]);
    hdr.ColumnWidth = {'1x', 90};
    hdr.Padding = [0 0 0 0];
    uilabel(hdr, "Text", kind + " " + entityId, "FontWeight", "bold");
    histCb = uicheckbox(hdr, "Text", "History", ...
        "Tooltip", "Show the full add/remove log instead of the current tags", ...
        "ValueChangedFcn", @(~,~) onHistory());

    tbl = uitable(g, "RowName", {}, "ColumnSortable", false, ...
        "SelectionType", "row", "Multiselect", "off", ...
        "CellSelectionCallback", @(~,e) onPick(e));

    ed = uigridlayout(g, [1 5]);
    ed.ColumnWidth = {130, '1x', 70, 70, 80};
    ed.Padding = [0 0 0 0];
    ed.ColumnSpacing = 4;
    nsDd = uidropdown(ed, "Items", cellstr(nsLabels), "ItemsData", cellstr(nsNames), ...
        "Value", char(nsNames(1)), ...
        "Tooltip", "Namespace (only those that apply to " + kind + " rows)", ...
        "ValueChangedFcn", @(~,~) onNamespace());
    valDd = uidropdown(ed, "Editable", "on", "Items", {}, "Value", '', ...
        "Tooltip", "Pick a value, or type one (or a whole tag such as qc:fail); Enter moves to Add / Set", ...
        "ValueChangedFcn", @(~,e) onValueTyped(e));
    addBtn = uibutton(ed, "Text", "Add", "Tooltip", "Add the tag (Ctrl+Enter)", ...
        "ButtonPushedFcn", @(~,~) onOp("add"));
    setBtn = uibutton(ed, "Text", "Set", ...
        "Tooltip", "Replace this namespace's current value (Ctrl+S)", ...
        "ButtonPushedFcn", @(~,~) onOp("set"));
    rmBtn = uibutton(ed, "Text", "Remove", ...
        "Tooltip", "Remove the tag selected in the list (Delete)", ...
        "ButtonPushedFcn", @(~,~) onRemove());

    hint = uilabel(g, "Text", "", "FontColor", [0.35 0.35 0.35]);

    foot = uigridlayout(g, [1 3]);
    foot.ColumnWidth = {'1x', 80, 90};
    foot.Padding = [0 0 0 0];
    status = uilabel(foot, "Text", "");
    uibutton(foot, "Text", "Help", "Tooltip", "Keyboard shortcuts (Ctrl+?)", ...
        "ButtonPushedFcn", @(~,~) CarasLabDBApp.showShortcutHelp(f, "tags"));
    uibutton(foot, "Text", "Close", "Tooltip", "Close (Esc)", ...
        "ButtonPushedFcn", @(~,~) uiresume(f));

    reload();
    onNamespace();
    try
        focus(valDd);
    catch
    end

    uiwait(f);
    if isvalid(f), delete(f); end
    if changed
        obj.refreshActiveTab();
    end
    return

    % ---- nested callbacks -------------------------------------------------
    function onKey(e)
        %ONKEY Shortcuts while the list or a button has focus (a uifigure
        %   does not forward keys while a text box has focus; Enter in the
        %   Value box is handled by its own callback).
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "tags");
        elseif key == "escape"
            uiresume(f);
        elseif key == "return" && ctrl
            onOp("add");
        elseif key == "s" && ctrl
            if logical(setBtn.Enable), onOp("set"); end
        elseif key == "r" && ctrl
            reload();
        elseif key == "delete"
            onRemove();
        end
    end

    function i = nsIndex(ns)
        i = find(nsNames == ns, 1);
    end

    function onNamespace()
        %ONNAMESPACE Refill the value list and the policy line for the namespace.
        ns = string(nsDd.Value);
        i = nsIndex(ns);
        refreshValues();
        setBtn.Enable = (nsCard(i) == "single");
        if ns == "tag"
            name = "bare tags";
        else
            name = ns;
        end
        if nsCard(i) == "single", card = "single-valued"; else, card = "multi-valued"; end
        if nsOpen(i)
            voc = "open vocabulary";
        else
            voc = "closed vocabulary (registered values only)";
        end
        hint.Text = name + ": " + nsMut(i) + " · " + card + " · " + voc + ...
            " · applies to " + replace(nsApplies(i), ",", ", ");
    end

    function refreshValues()
        %REFRESHVALUES Registered, non-retired values of the chosen namespace.
        vals = strings(0, 1);
        if height(vocab) > 0
            vals = local_text(vocab.value);
            vals = vals(local_text(vocab.namespace) == string(nsDd.Value));
        end
        valDd.Items = cellstr(vals);
        valDd.Value = '';
    end

    function reload()
        %RELOAD Re-read the vocabulary and the row's tags (or its log).
        try
            vocab = db.getTags();
            T = db.getEntityTags(kind, entityId, History=showHistory);
        catch ME
            uialert(f, string(ME.message), "Load tags failed");
            return
        end
        names = ["Tag", "Applied", "By", "Note"];
        if showHistory
            names = ["Tag", "Op", "Applied", "By", "Note"];
        end
        if height(T) == 0
            curTags = strings(0, 1);
            tbl.Data = table('Size', [0 numel(names)], ...
                'VariableTypes', repmat({'string'}, 1, numel(names)), ...
                'VariableNames', cellstr(names));
        else
            curTags = local_text(T.tag);
            shown = local_text(T.display_tag);
            when  = local_when(T.applied_at);
            by    = local_who(T.applied_by, people);
            note  = local_text(T.note);
            note(ismissing(note)) = "";
            if showHistory
                tbl.Data = table(shown, local_text(T.op), when, by, note, ...
                    'VariableNames', cellstr(names));
            else
                tbl.Data = table(shown, when, by, note, 'VariableNames', cellstr(names));
            end
        end
        tbl.Selection = [];
        rmBtn.Enable = ~showHistory;
    end

    function onHistory()
        showHistory = logical(histCb.Value);
        reload();
    end

    function onPick(e)
        %ONPICK Selecting a current tag selects its namespace, ready for Set/Remove.
        if showHistory || isempty(e.Indices) || isempty(curTags)
            return
        end
        r = e.Indices(1, 1);
        if r > numel(curTags), return; end
        [ns, ~] = CarasLabDB.parseTag(curTags(r));
        if ~isempty(nsIndex(ns)) && string(nsDd.Value) ~= ns
            nsDd.Value = char(ns);
            onNamespace();
        end
    end

    function tag = currentTag()
        %CURRENTTAG The tag the Namespace and Value controls describe ("" if none).
        %   A typed value containing a colon is a whole tag. Throws
        %   CarasLabDB:invalidTag for a malformed one.
        v = strtrim(string(valDd.Value));
        if strlength(v) == 0
            tag = "";
            return
        end
        if ~contains(v, ":")
            v = string(nsDd.Value) + ":" + v;
        end
        tag = CarasLabDB.normalizeTag(v);
    end

    function onValueTyped(e)
        %ONVALUETYPED A typed value selects its namespace; it is not applied.
        %   The box commits on Enter and also when it loses focus (to Close,
        %   Remove, the list...), and the two cannot be told apart, so no
        %   write happens here. Focus moves to the button that would apply
        %   the tag; Enter or Space there is the deliberate confirmation.
        edited = false;
        try
            edited = logical(e.Edited);
        catch
        end
        if ~edited
            return
        end
        try
            tag = currentTag();
        catch ME
            uialert(f, string(ME.message), "Invalid tag");
            return
        end
        if strlength(tag) == 0
            return
        end
        [ns, ~] = CarasLabDB.parseTag(tag);
        i = nsIndex(ns);
        if ~isempty(i) && string(nsDd.Value) ~= ns
            v = string(valDd.Value);
            nsDd.Value = char(ns);
            onNamespace();
            valDd.Value = char(v);         % keep what was typed
        end
        btn = addBtn;
        verb = "Add";
        if ~isempty(i) && nsCard(i) == "single"
            btn = setBtn;
            verb = "Set";
        end
        if ~isempty(i) && nsMut(i) == "immutable"
            status.Text = "Press " + verb + " to apply " + CarasLabDB.displayTag(tag) + ...
                " -- " + ns + " is immutable, so it is permanent once set.";
        else
            status.Text = "Press " + verb + " (Enter or Space) to apply " + ...
                CarasLabDB.displayTag(tag) + ".";
        end
        try
            focus(btn);
        catch
        end
    end

    function onOp(op)
        %ONOP Add / Set button (or Ctrl+Enter / Ctrl+S).
        try
            tag = currentTag();
        catch ME
            uialert(f, string(ME.message), "Invalid tag");
            return
        end
        if strlength(tag) == 0
            uialert(f, "Choose or type a value first.", "Tags");
            return
        end
        apply(op, tag);
    end

    function onRemove()
        %ONREMOVE Remove the tag selected in the list (else the one in the controls).
        if showHistory
            return
        end
        sel = tbl.Selection;
        if ~isempty(sel) && ~isempty(curTags) && sel(1) <= numel(curTags)
            tag = curTags(sel(1));
        else
            try
                tag = currentTag();
            catch ME
                uialert(f, string(ME.message), "Invalid tag");
                return
            end
            if strlength(tag) == 0
                uialert(f, "Select a tag in the list first.", "Remove tag");
                return
            end
        end
        apply("remove", tag);
    end

    function ok = apply(op, tag)
        %APPLY One tag write through the CarasLabDB methods; alerts on refusal.
        ok = false;
        shown = CarasLabDB.displayTag(tag);
        try
            switch op
                case "add"
                    db.addTag(kind, entityId, tag);
                    msg = "Added " + shown + ".";
                case "set"
                    [~, did] = db.setTag(kind, entityId, tag);
                    if did
                        msg = "Set " + shown + ".";
                    else
                        msg = shown + " was already set.";
                    end
                case "remove"
                    db.removeTag(kind, entityId, tag);
                    msg = "Removed " + shown + ".";
            end
        catch ME
            % Policy refusals (closed vocabulary, duplicate, immutable,
            % applies_to, retired) carry the database's own explanation.
            uialert(f, string(ME.message), "Tag not applied");
            return
        end
        ok = true;
        changed = true;
        status.Text = msg;
        reload();          % also re-reads the vocabulary (fn_tag may have registered a value)
        refreshValues();
    end
end

% =============================================================================
function s = local_text(col)
    %LOCAL_TEXT A fetched text column as a string column vector (NULL -> missing).
    if iscell(col)
        s = strings(numel(col), 1);
        for i = 1:numel(col)
            v = col{i};
            if (isstring(v) && isscalar(v)) || ischar(v)
                s(i) = string(v);
            else
                s(i) = string(missing);
            end
        end
    else
        s = reshape(string(col), [], 1);
    end
end

function b = local_bool(col)
    if iscell(col)
        b = cellfun(@(v) ~isempty(v) && logical(v(1)), col);
    else
        b = logical(col);
    end
    b = reshape(b, [], 1);
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

function s = local_who(col, people)
    %LOCAL_WHO person_id values shown as full names where known.
    s = local_text(col);
    for i = 1:numel(s)
        if ismissing(s(i))
            s(i) = "";
        elseif isKey(people, char(s(i)))
            s(i) = string(people(char(s(i))));
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
