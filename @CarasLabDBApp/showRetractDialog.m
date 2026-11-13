function showRetractDialog(obj, kind, entityId)
%SHOWRETRACTDIALOG Retract an event or artifact, with a stated reason (Ctrl+Delete).
%
%   showRetractDialog(obj, kind, entityId)
%
%   KIND is "event" or "artifact" and ENTITYID the row's id. A retraction
%   withdraws a row that should never have been recorded -- an event entered
%   twice, a file registered by mistake. (A wrong value is corrected instead:
%   Edit / Supersede.) The dialog is the confirmation. It
%
%     * names the row (CarasLabDBApp.describeRow), so it can be checked
%       against the row selected in the main window;
%     * explains what a retraction does: the row stays in the database with
%       the reason and who retracted it, but leaves the active views; it is
%       permanent, and superseding the retracted row later restores it as a
%       current row;
%     * says what else is affected: the files a retracted event produced are
%       not retracted with it, and the events that used a retracted file as
%       an input still point at it (the integrity report lists both);
%     * requires a non-blank reason.
%
%   Retract (Ctrl+S) calls CarasLabDB.retractEvent / retractArtifact, i.e.
%   lab.fn_retract; Cancel (Esc) writes nothing. A row that is already
%   retracted, or that has been superseded (only the current version of a
%   row can be retracted), is reported instead of opening the dialog, and
%   the database refuses both in any case.
%
%   See also CARASLABDB/RETRACTEVENT, CARASLABDB/RETRACTARTIFACT,
%   CARASLABDBAPP/SHOWEVENTEDITOR, CARASLABDBAPP/SHOWINTEGRITYREPORT.

    arguments
        obj (1,1) CarasLabDBApp
        kind (1,1) string {mustBeMember(kind, ["event", "artifact"])}
        entityId (1,1) string
    end

    db = obj.Db;

    % Where the row stands. The view and its id column are fixed per kind;
    % the id is passed as a SQL literal.
    try
        V = db.runQuery( ...
            "SELECT coalesce(superseded_by::text, '') AS superseded_by, " + ...
            "CASE WHEN is_retracted THEN 1 ELSE 0 END AS is_retracted FROM " + ...
            obj.pQualify(kind + "_version") + " WHERE " + kind + "_id = " + ...
            CarasLabDB.sqlLiteral(entityId) + ";");
        if height(V) > 0
            nextId = string(V.superseded_by(1));
            if isscalar(nextId) && ~ismissing(nextId) && strlength(nextId) > 0
                uialert(obj.Fig, "This " + kind + " has been superseded by " + nextId + ...
                    ". Only the current version of a row can be retracted: select that " + ...
                    "one instead (tick Active only to list current rows only).", "Retract");
                return
            end
            if double(V.is_retracted(1)) ~= 0
                uialert(obj.Fig, "This " + kind + " is already retracted.", "Retract", ...
                    "Icon", "info");
                return
            end
        end
    catch
        % The state could not be read; the database still refuses to retract
        % a superseded or an already retracted row.
    end

    rowText = CarasLabDBApp.describeRow(db, kind, entityId);
    explain = local_explain(db, kind, entityId);
    busy = false;
    retracted = false;

    % ---- window ---------------------------------------------------------
    f = uifigure("Name", "Retract " + kind, ...
        "Position", local_center(640, 480), "WindowStyle", "modal", ...
        "KeyPressFcn", @(~,e) onKey(e));
    g = uigridlayout(f, [5 1]);
    g.RowHeight = {22, '1x', 22, 90, 30};
    g.ColumnWidth = {'1x'};
    g.Padding = [12 12 12 12];
    g.RowSpacing = 6;

    uilabel(g, "Text", char(rowText), "FontWeight", "bold", "Tooltip", char(rowText));
    % One cell per line: the documented way to give a label several lines.
    uilabel(g, "Text", cellstr(splitlines(explain)), "WordWrap", "on", ...
        "VerticalAlignment", "top");
    uilabel(g, "Text", "Reason (required)", "FontWeight", "bold");
    reasonTa = uitextarea(g, "Value", {''}, ...
        "Placeholder", "Why this " + kind + " should never have been recorded", ...
        "Tooltip", "Stored with the retraction. Typing here writes nothing: press Retract.");

    foot = uigridlayout(g, [1 4]);
    foot.ColumnWidth = {'1x', 80, 100, 100};
    foot.Padding = [0 0 0 0];
    uilabel(foot, "Text", "");
    uibutton(foot, "Text", "Help", "Tooltip", "Keyboard shortcuts (Ctrl+?)", ...
        "ButtonPushedFcn", @(~,~) CarasLabDBApp.showShortcutHelp(f, "retract"));
    uibutton(foot, "Text", "Cancel", "Tooltip", "Cancel: nothing is written (Esc)", ...
        "ButtonPushedFcn", @(~,~) uiresume(f));
    uibutton(foot, "Text", "Retract", "Tooltip", "Retract this " + kind + " (Ctrl+S)", ...
        "ButtonPushedFcn", @(~,~) onRetract());

    try
        focus(reasonTa);
    catch
    end

    uiwait(f);
    if isvalid(f), delete(f); end
    if retracted
        obj.pStatus("Retracted " + kind + " " + entityId + ...
            " (kept in the database; no longer in the active views)");
        obj.refreshActiveTab();
    end
    return

    % ---- nested callbacks -------------------------------------------------
    function onKey(e)
        %ONKEY Ctrl+S retracts, Esc cancels, Ctrl+? lists the shortcuts. A
        %   uifigure delivers these only while the reason box does not have
        %   the focus.
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "retract");
        elseif key == "escape"
            uiresume(f);
        elseif key == "s" && ctrl
            onRetract();
        end
    end

    function onRetract()
        %ONRETRACT Retract button (or Ctrl+S): write the retraction once.
        if busy || retracted
            return
        end
        reason = strtrim(strjoin(reshape(string(reasonTa.Value), 1, []), newline));
        if strlength(reason) == 0
            uialert(f, "A reason is required. A retraction with no stated reason " + ...
                "cannot be told apart from lost data.", "Retract");
            try
                focus(reasonTa);
            catch
            end
            return
        end
        busy = true;
        try
            if kind == "event"
                db.retractEvent(entityId, reason);
            else
                db.retractArtifact(entityId, reason);
            end
        catch retractErr
            busy = false;
            uialert(f, string(retractErr.message), "Not retracted");
            return
        end
        busy = false;
        retracted = true;
        uiresume(f);
    end
end

% =============================================================================
function txt = local_explain(db, kind, entityId)
    %LOCAL_EXPLAIN What retracting this row does, and what else it touches.
    txt = "Retract a row that should never have been recorded (entered twice, " + ...
        "registered by mistake). If a value is merely wrong, cancel and correct it " + ...
        "instead." + newline + newline + ...
        "The row is not deleted. It stays in the database with your reason and " + ...
        "who retracted it, but it leaves the active views: it is no longer listed " + ...
        "while Active only is ticked and no longer counts as current. A retraction " + ...
        "is permanent; ";
    if kind == "event"
        txt = txt + "superseding the retracted event later (untick Active only, " + ...
            "select it, Edit / Supersede) restores it as a current event.";
    else
        txt = txt + "superseding the retracted artifact later " + ...
            "(CarasLabDB.supersedeArtifact) restores it as a current row.";
    end

    % What else is affected. Counting is a convenience: if it fails, the
    % general explanation above still stands.
    try
        if kind == "event"
            A = db.getArtifacts(ProducedByEventId=entityId, ActiveOnly=true);
            if height(A) > 0
                txt = txt + newline + newline + "This event produced " + string(height(A)) + ...
                    " file(s) that are still current. They are NOT retracted with it: " + ...
                    "the integrity report lists them (artifact_producer_retracted) " + ...
                    "until each is retracted too or re-pointed at the right event.";
            end
        else
            E = db.getEventInputs(ArtifactId=entityId);
            if height(E) > 0
                txt = txt + newline + newline + string(height(E)) + " event(s) used this " + ...
                    "file as an input. They still point at it: the integrity report " + ...
                    "lists them (input_retracted) until they are corrected.";
            end
        end
    catch
    end
end

function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [su(3)/2 - w/2, su(4)/2 - h/2, w, h];
end
