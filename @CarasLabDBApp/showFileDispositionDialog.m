function showFileDispositionDialog(obj, artifactId)
%SHOWFILEDISPOSITIONDIALOG Record what became of an artifact's file (Ctrl+Shift+F).
%
%   showFileDispositionDialog(obj, artifactId)
%
%   An artifact row is a permanent record that a file with these bytes was
%   produced at this path. When the file is later overwritten, moved or
%   deleted, that record is still true -- it is not corrected and not
%   retracted -- and the dialog records what happened to the file instead
%   (CarasLabDB.addArtifactDisposition, lab.artifact_disposition):
%
%     deleted   the file is gone
%     moved     the bytes are elsewhere now: give the artifact id of the row
%               registered for them at the new path (same checksum)
%     replaced  other bytes are at the path now: give their row's artifact
%               id if it is registered
%     restored  the same bytes are back at the path (offered only while the
%               file is recorded as gone)
%
%   The dialog names the row and the file's current state, and asks when it
%   happened (a date picker and a time, in this computer's time zone) and,
%   optionally, a note. Save (Ctrl+S) writes one disposition; Cancel (Esc)
%   writes nothing. The database refuses a disposition that does not fit
%   the file's state, and the message is shown as it comes.
%
%   See also CARASLABDB/ADDARTIFACTDISPOSITION, CARASLABDB/GETARTIFACTDISPOSITIONS,
%   CARASLABDBAPP/SHOWRETRACTDIALOG.

    arguments
        obj (1,1) CarasLabDBApp
        artifactId (1,1) string
    end

    db = obj.Db;
    rowText = CarasLabDBApp.describeRow(db, "artifact", artifactId);

    % The file's state now: its latest disposition, by file.
    current = "present";
    currentText = "The file is present: nothing has been recorded about it since it was registered.";
    try
        L = db.getArtifactDispositions(ArtifactId=artifactId, LatestPerFile=true);
        if height(L) > 0
            last = string(L.disposition(1));
            if last ~= "restored"
                current = last;
                currentText = "The file is recorded as " + last + " (" + ...
                    string(L.occurred_at(1)) + "). Only ""restored"" can be recorded now.";
            else
                currentText = "The file was restored (" + string(L.occurred_at(1)) + ...
                    ") and is present.";
            end
        end
    catch
        currentText = "The file's state could not be read; the database still checks " + ...
            "what is saved.";
    end
    if current == "present"
        choices = ["deleted", "moved", "replaced"];
    else
        choices = "restored";
    end

    saved = false;
    busy = false;

    % ---- window ---------------------------------------------------------
    f = uifigure("Name", "File disposition", ...
        "Position", local_center(640, 440), "WindowStyle", "modal", ...
        "KeyPressFcn", @(~,e) onKey(e));
    g = uigridlayout(f, [8 2]);
    g.RowHeight = {22, 44, 26, 26, 26, 22, '1x', 30};
    g.ColumnWidth = {150, '1x'};
    g.Padding = [12 12 12 12];
    g.RowSpacing = 6;

    t = uilabel(g, "Text", char(rowText), "FontWeight", "bold", "Tooltip", char(rowText));
    t.Layout.Column = [1 2];
    s = uilabel(g, "Text", char(currentText), "WordWrap", "on", "VerticalAlignment", "top");
    s.Layout.Column = [1 2];

    uilabel(g, "Text", "What happened");
    kindDd = uidropdown(g, "Items", cellstr(choices), "Value", char(choices(1)), ...
        "Tooltip", "deleted: gone · moved: the bytes are elsewhere · replaced: other bytes " + ...
        "at this path · restored: the same bytes are back");

    uilabel(g, "Text", "Row of the file now");
    successorEf = uieditfield(g, "text", "Placeholder", ...
        "artifact_id: required for moved, optional for replaced", ...
        "Tooltip", "The artifact id of the row for the bytes where they are now (moved: same " + ...
        "checksum at another path; replaced: other bytes at this path)");

    uilabel(g, "Text", "When (this computer's zone)");
    when = uigridlayout(g, [1 2]);
    when.ColumnWidth = {'1x', 90};
    when.Padding = [0 0 0 0];
    now0 = datetime("now", "TimeZone", "local");
    datePk = uidatepicker(when, "Value", dateshift(now0, "start", "day"), ...
        "DisplayFormat", "yyyy-MM-dd", "Tooltip", "The day it happened to the file");
    timeEf = uieditfield(when, "text", "Value", char(string(now0, "HH:mm")), ...
        "Tooltip", "The time it happened, HH:mm (24-hour)");

    n = uilabel(g, "Text", "Note (optional)", "FontWeight", "bold");
    n.Layout.Column = [1 2];
    noteTa = uitextarea(g, "Value", {''}, ...
        "Placeholder", "e.g. removed by the clean-up after the copy on the NAS was checked");
    noteTa.Layout.Column = [1 2];

    foot = uigridlayout(g, [1 4]);
    foot.Layout.Column = [1 2];
    foot.ColumnWidth = {'1x', 80, 100, 100};
    foot.Padding = [0 0 0 0];
    uilabel(foot, "Text", "");
    uibutton(foot, "Text", "Help", "Tooltip", "Keyboard shortcuts (Ctrl+?)", ...
        "ButtonPushedFcn", @(~,~) CarasLabDBApp.showShortcutHelp(f, "disposition"));
    uibutton(foot, "Text", "Cancel", "Tooltip", "Cancel: nothing is written (Esc)", ...
        "ButtonPushedFcn", @(~,~) uiresume(f));
    uibutton(foot, "Text", "Save", "Tooltip", "Record what became of the file (Ctrl+S)", ...
        "ButtonPushedFcn", @(~,~) onSave());

    uiwait(f);
    if isvalid(f), delete(f); end
    if saved
        obj.pStatus("Recorded the file of artifact " + artifactId + " as " + ...
            string(kindDd.Value) + " (its row stays active)");
        obj.refreshActiveTab();
    end
    return

    % ---- nested callbacks -------------------------------------------------
    function onKey(e)
        %ONKEY Ctrl+S saves, Esc cancels, Ctrl+? lists the shortcuts.
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "disposition");
        elseif key == "escape"
            uiresume(f);
        elseif key == "s" && ctrl
            onSave();
        end
    end

    function onSave()
        %ONSAVE Save (or Ctrl+S): check the entries, then write one disposition.
        if busy || saved
            return
        end
        kind = string(kindDd.Value);
        successor = strtrim(string(successorEf.Value));
        if kind == "moved" && strlength(successor) == 0
            uialert(f, "A move needs the artifact id of the row for the bytes at their " + ...
                "new path. Register the file there first.", "File disposition");
            return
        end
        if ismember(kind, ["deleted", "restored"]) && strlength(successor) > 0
            uialert(f, "A file that is " + kind + " has no row of its own elsewhere: " + ...
                "leave ""Row of the file now"" empty.", "File disposition");
            return
        end
        hm = regexp(char(strtrim(string(timeEf.Value))), '^(\d{1,2}):(\d{2})$', 'tokens', 'once');
        if isempty(hm) || str2double(hm{1}) > 23 || str2double(hm{2}) > 59
            uialert(f, "Give the time as HH:mm, e.g. 14:05.", "File disposition");
            return
        end
        day = datePk.Value;
        if isnat(day)
            uialert(f, "Pick the day it happened.", "File disposition");
            return
        end
        day.TimeZone = "local";
        at = dateshift(day, "start", "day") + hours(str2double(hm{1})) + minutes(str2double(hm{2}));
        note = strtrim(strjoin(reshape(string(noteTa.Value), 1, []), newline));
        if strlength(note) == 0
            note = string(missing);
        end
        if strlength(successor) == 0
            successor = string(missing);
        end
        busy = true;
        try
            db.addArtifactDisposition(ArtifactId=artifactId, Disposition=kind, OccurredAt=at, ...
                SuccessorArtifactId=successor, Note=note);
        catch saveErr
            busy = false;
            uialert(f, string(saveErr.message), "Not saved");
            return
        end
        busy = false;
        saved = true;
        uiresume(f);
    end
end

% =============================================================================
function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [su(3)/2 - w/2, su(4)/2 - h/2, w, h];
end
