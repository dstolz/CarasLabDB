function showHusbandryEntry(obj)
%SHOWHUSBANDRYENTRY Enter the day's weights, water and health checks for all animals (Ctrl+H).
%
%   showHusbandryEntry(obj)
%
%   One table for the daily round instead of one form per animal. Each row is
%   an active subject -- one that has no endpoint event (lab.subject_current's
%   is_endpointed) -- with, for reference, its latest recorded weight, when
%   that was, and its baseline weight if it has one. The four right-hand
%   columns are typed into:
%
%       Weight (g)   Water (ml)   Health status   Notes
%
%   A row left blank is not written. Save (Ctrl+S)
%     1. reads every cell: a weight must be a number greater than 0 and a
%        volume a number that is not negative, in plain decimal notation
%        (71.9, never 71,9: CarasLabDBApp.parseNumber). Any unreadable cell
%        stops the save and is named in an alert;
%     2. shows a summary of exactly what will be written -- the date and
%        time, the measure, and one line per animal -- and asks;
%     3. calls CarasLabDB.addHusbandryBatch once, which inserts all the
%        husbandry events in one transaction: either every row is recorded
%        or none is.
%   Nothing is written by typing in a cell, by Enter, or when a cell or box
%   loses focus.
%
%   Date and time. The date is picked in a date picker and the time typed as
%   HH:mm; together they are the occurred_at of every event of the batch, in
%   this workstation's time zone. They default to now.
%
%   Low weights. An entered weight below P % of the subject's baseline is
%   highlighted, and flagged again in the summary. The baseline is the
%   subject's variable 'baseline weight' (a number, in g or without units;
%   set it in the variables editor, Ctrl+L); subjects without one are never
%   flagged. P is typed in the "Flag below" box and remembered between
%   sessions with the app's other preferences (setpref).
%
%   Cancel (Esc) asks before discarding typed entries.
%
%   See also CARASLABDB/ADDHUSBANDRYBATCH, CARASLABDB/GETSUBJECTCURRENT,
%   CARASLABDBAPP/PARSENUMBER, CARASLABDBAPP/SHOWVARIABLEEDITOR.

    arguments
        obj (1,1) CarasLabDBApp
    end

    db = obj.Db;

    % ---- the animals ----------------------------------------------------
    try
        S = db.getSubjectCurrent();
    catch loadErr
        uialert(obj.Fig, string(loadErr.message), "Daily husbandry");
        return
    end
    [subj, latestG, latestAt] = local_activeSubjects(S);
    if isempty(subj)
        uialert(obj.Fig, "There are no active subjects (every subject has an endpoint event).", ...
            "Daily husbandry");
        return
    end
    baseG = local_baselines(db, obj.pQualify("variable_current"), subj);   % NaN = none

    % Position of the Weight (g) column in the table (fixed; see local_parse).
    COL_WEIGHT = 5;

    nSubj = numel(subj);
    cells = cell(nSubj, 8);
    cells(:, 1) = cellstr(subj);
    cells(:, 2) = cellstr(local_numCol(latestG));
    cells(:, 3) = cellstr(latestAt);
    cells(:, 4) = cellstr(local_numCol(baseG));
    cells(:, 5:8) = {''};

    % State shared with the nested callbacks.
    pct = local_validPercent(obj.Prefs.LowWeightPercent);
    busy = false;
    savedCount = 0;
    savedWhen = "";

    % ---- window ---------------------------------------------------------
    f = uifigure("Name", "Daily husbandry", ...
        "Position", local_center(1000, 620), "WindowStyle", "modal", ...
        "KeyPressFcn", @(~,e) onKey(e), ...
        "CloseRequestFcn", @(~,~) onCancel());
    g = uigridlayout(f, [4 1]);
    g.RowHeight = {30, '1x', 22, 30};
    g.ColumnWidth = {'1x'};
    g.Padding = [10 10 10 10];
    g.RowSpacing = 6;

    top = uigridlayout(g, [1 10]);
    top.ColumnWidth = {40, 130, 40, 70, 60, 130, '1x', 70, 50, 100};
    top.Padding = [0 0 0 0];
    top.ColumnSpacing = 6;
    uilabel(top, "Text", "Date", "HorizontalAlignment", "right", "FontWeight", "bold");
    datePk = uidatepicker(top, "Value", datetime("today"), "DisplayFormat", "yyyy-MM-dd", ...
        "Tooltip", "The day the animals were weighed / checked");
    uilabel(top, "Text", "Time", "HorizontalAlignment", "right", "FontWeight", "bold");
    timeEd = uieditfield(top, "text", "Value", char(string(datetime("now"), "HH:mm")), ...
        "Placeholder", "HH:mm", ...
        "Tooltip", "Time of day, 24-hour. Recorded as the time of every entry of this batch.");
    uilabel(top, "Text", "Measure", "HorizontalAlignment", "right", "FontWeight", "bold");
    measureEd = uieditfield(top, "text", "Value", 'weight', ...
        "Tooltip", "What was measured, stored on every event of this batch " + ...
            "(weight, water_restriction, health_check, ...)");
    uilabel(top, "Text", "");
    uilabel(top, "Text", "Flag below", "HorizontalAlignment", "right");
    pctEd = uieditfield(top, "text", "Value", char(local_numText(pct)), ...
        "HorizontalAlignment", "right", ...
        "Tooltip", "Highlight an entered weight below this percentage of the " + ...
            "subject's 'baseline weight' variable. Remembered between sessions.", ...
        "ValueChangedFcn", @(~,~) onThreshold());
    uilabel(top, "Text", "% of baseline");

    tbl = uitable(g, "Data", cells, "RowName", {}, ...
        "ColumnName", {'Subject', 'Latest (g)', 'Weighed', 'Baseline (g)', ...
                       'Weight (g)', 'Water (ml)', 'Health status', 'Notes'}, ...
        "ColumnFormat", repmat({'char'}, 1, 8), ...
        "ColumnEditable", [false false false false true true true true], ...
        "ColumnSortable", false, ...
        "CellEditCallback", @(~,~) refreshMarks());
    try
        tbl.ColumnWidth = {130, 80, 120, 90, 90, 90, 150, 'auto'};
    catch
    end

    uilabel(g, "Text", "Type in the four right-hand columns; a row left blank is not " + ...
        "written. Numbers use a period (71.9). Nothing is saved until you press Save.", ...
        "FontColor", [0.35 0.35 0.35]);

    foot = uigridlayout(g, [1 4]);
    foot.ColumnWidth = {'1x', 80, 90, 90};
    foot.Padding = [0 0 0 0];
    countLbl = uilabel(foot, "Text", "");
    uibutton(foot, "Text", "Help", "Tooltip", "Keyboard shortcuts (Ctrl+?)", ...
        "ButtonPushedFcn", @(~,~) CarasLabDBApp.showShortcutHelp(f, "husbandry"));
    uibutton(foot, "Text", "Cancel", "Tooltip", "Close without saving (Esc)", ...
        "ButtonPushedFcn", @(~,~) onCancel());
    uibutton(foot, "Text", "Save", "Tooltip", "Check, summarise and save (Ctrl+S)", ...
        "ButtonPushedFcn", @(~,~) onSave());

    refreshMarks();

    uiwait(f);
    if isvalid(f), delete(f); end
    if savedCount > 0
        obj.pStatus("Recorded " + string(savedCount) + " husbandry event(s) at " + savedWhen + ".");
        obj.refreshActiveTab();
    end
    return

    % ---- nested callbacks -------------------------------------------------
    function onKey(e)
        %ONKEY Ctrl+S saves, Esc cancels, Ctrl+? lists the shortcuts. A
        %   uifigure delivers these only while no cell or text box is being
        %   edited.
        mods = string(e.Modifier);
        ctrl = any(mods == "control") || any(mods == "command");
        key  = string(e.Key);
        if ctrl && (ismember(key, ["slash", "questionmark", "help"]) || ...
                string(e.Character) == "?")
            CarasLabDBApp.showShortcutHelp(f, "husbandry");
        elseif key == "escape"
            onCancel();
        elseif key == "s" && ctrl
            onSave();
        end
    end

    function refreshMarks()
        %REFRESHMARKS Mark unreadable cells and low weights; update the count.
        %   Display only: nothing is written here.
        [entries, problems, badCells] = local_parse(tbl.Data, subj);
        low = find(local_isLow(entries.WeightG, baseG, pct));
        try
            removeStyle(tbl);
            if ~isempty(badCells)
                addStyle(tbl, uistyle("BackgroundColor", [1.00 0.80 0.80]), "cell", badCells);
            end
            if ~isempty(low)
                addStyle(tbl, uistyle("BackgroundColor", [1.00 0.90 0.55]), "cell", ...
                    [low(:), repmat(COL_WEIGHT, numel(low), 1)]);
            end
        catch
            % Highlighting is a convenience; Save validates again.
        end
        note = string(nnz(entries.Used)) + " of " + string(nSubj) + " row(s) to save";
        if ~isempty(problems)
            note = note + " · " + string(numel(problems)) + " cell(s) cannot be read (red)";
        end
        if ~isempty(low)
            note = note + " · " + string(numel(low)) + " weight(s) below " + ...
                local_numText(pct) + "% of baseline (amber)";
        end
        countLbl.Text = note;
    end

    function onThreshold()
        %ONTHRESHOLD The "Flag below" percentage was changed: check and remember it.
        %   A preference, not data: it is stored when it is valid, and an
        %   invalid entry is put back to the value in force.
        [newPct, problem] = CarasLabDBApp.parseNumber(string(pctEd.Value));
        if strlength(problem) > 0 || isnan(newPct) || newPct <= 0 || newPct > 100
            pctEd.Value = char(local_numText(pct));
            uialert(f, "The percentage must be a number above 0 and at most 100 " + ...
                "(for example 85).", "Flag below");
            return
        end
        pct = newPct;
        obj.Prefs.LowWeightPercent = pct;
        obj.savePrefs();
        refreshMarks();
    end

    function onCancel()
        %ONCANCEL Cancel, Esc or the window's close box: ask before discarding entries.
        try
            if busy
                return
            end
            pending = local_parse(tbl.Data, subj);
            nPending = nnz(pending.Used);
            if nPending > 0
                answer = uiconfirm(f, string(nPending) + " row(s) have entries that were " + ...
                    "not saved. Discard them?", "Daily husbandry", ...
                    "Options", {'Discard', 'Keep editing'}, ...
                    "DefaultOption", 2, "CancelOption", 2, "Icon", "warning");
                if ~strcmp(answer, 'Discard')
                    return
                end
            end
            uiresume(f);
        catch
            % Never leave a window that cannot be closed.
            uiresume(f);
        end
    end

    function onSave()
        %ONSAVE Save button (or Ctrl+S): validate, summarise, confirm, write once.
        if busy || savedCount > 0
            return
        end
        [entries, problems] = local_parse(tbl.Data, subj);
        refreshMarks();
        if ~isempty(problems)
            uialert(f, "Nothing was saved. Correct these cells first:" + newline + newline + ...
                strjoin(problems, newline), "Invalid input");
            return
        end
        rows = find(entries.Used);
        if isempty(rows)
            uialert(f, "Nothing to save: no weight, water, health status or note was entered.", ...
                "Daily husbandry");
            return
        end
        [when, problem] = local_when(datePk.Value, string(timeEd.Value));
        if strlength(problem) > 0
            uialert(f, problem, "Invalid input");
            return
        end
        measure = strtrim(string(measureEd.Value));
        if strlength(measure) == 0
            uialert(f, "Measure is required (for example weight).", "Invalid input");
            return
        end

        % One summary of exactly what will be written; nothing is written
        % until it is confirmed.
        whenText = string(when, "yyyy-MM-dd HH:mm");
        question = "Record " + string(numel(rows)) + " husbandry event(s), measure '" + ...
            measure + "', at " + whenText + "?";
        if string(when, "yyyy-MM-dd") ~= string(datetime("today"), "yyyy-MM-dd")
            question = question + newline + "NOTE: that date is not today.";
        end
        question = question + newline + newline + ...
            strjoin(local_summary(subj, entries, rows, baseG, pct), newline) + ...
            newline + newline + "All rows are written together, or none.";
        answer = uiconfirm(f, question, "Confirm daily husbandry", ...
            "Options", {'Save', 'Go back'}, ...
            "DefaultOption", 1, "CancelOption", 2, "Icon", "question");
        if ~strcmp(answer, 'Save')
            return
        end

        batchTbl = local_batchTable(subj, entries, rows);
        busy = true;
        try
            newIds = db.addHusbandryBatch(batchTbl, OccurredAt=when, Measure=measure);
        catch saveErr
            busy = false;
            uialert(f, "Nothing was saved: " + string(saveErr.message), "Save failed");
            return
        end
        busy = false;
        savedCount = max(numel(newIds), numel(rows));
        savedWhen = whenText;
        uiresume(f);
    end
end

% =============================================================================
function [subj, latestG, latestAt] = local_activeSubjects(S)
    %LOCAL_ACTIVESUBJECTS The subjects with no endpoint event, from subject_current.
    %   SUBJ ids (sorted as the view returns them, by subject_id), LATESTG the
    %   latest recorded weight (NaN if none) and LATESTAT when it was ("" if
    %   never).
    subj = strings(0, 1);
    latestG = zeros(0, 1);
    latestAt = strings(0, 1);
    if ~istable(S) || height(S) == 0
        return
    end
    ids = local_text(S.subject_id);
    keep = ~local_bool(S.is_endpointed) & ~ismissing(ids);
    w = local_num(S.latest_weight_g);
    at = local_dateText(S.latest_weight_at);
    subj = ids(keep);
    latestG = w(keep);
    latestAt = at(keep);
end

function base = local_baselines(db, viewRef, subj)
    %LOCAL_BASELINES Each subject's 'baseline weight' variable in grams (NaN if none).
    %   One query on lab.variable_current (VIEWREF, schema-qualified,
    %   internal). Only a number recorded in g, or without units, counts: a
    %   baseline in other units would make the percentage meaningless. If
    %   the query fails nobody has a baseline, and nothing is flagged.
    base = nan(numel(subj), 1);
    try
        R = db.runQuery("SELECT entity_id, value_num FROM " + viewRef + ...
            " WHERE entity_kind = 'subject' AND variable = 'baseline weight'" + ...
            " AND value_num IS NOT NULL" + ...
            " AND (units IS NULL OR lower(units) IN ('g', 'gram', 'grams'));");
        if ~istable(R) || height(R) == 0
            return
        end
        ids = local_text(R.entity_id);
        val = local_num(R.value_num);
        [found, where] = ismember(subj, ids);
        base(found) = val(where(found));
    catch
        base = nan(numel(subj), 1);
    end
end

function [entries, problems, badCells] = local_parse(cells, subj)
    %LOCAL_PARSE Read the four entry columns of the table.
    %   ENTRIES holds one element per subject: Used (the row has an entry),
    %   WeightG and WaterMl (NaN when blank or unreadable), Health and Notes
    %   ("" when blank). PROBLEMS names every cell that cannot be read, for
    %   an alert, and BADCELLS lists them as [row column] for highlighting.
    %   A weight must be greater than 0 and a volume not negative, as the
    %   database requires (lab.husbandry_event).
    n = numel(subj);
    w = nan(n, 1);
    ml = nan(n, 1);
    health = strings(n, 1);
    notes = strings(n, 1);
    used = false(n, 1);
    problems = strings(1, 0);
    badCells = zeros(0, 2);
    for r = 1:min(n, size(cells, 1))
        wTxt = local_cellText(cells{r, 5});
        mTxt = local_cellText(cells{r, 6});
        health(r) = local_cellText(cells{r, 7});
        notes(r) = local_cellText(cells{r, 8});

        [w(r), err] = CarasLabDBApp.parseNumber(wTxt);
        if strlength(err) == 0 && ~isnan(w(r)) && w(r) <= 0
            err = "'" + wTxt + "' is not a weight: it must be greater than 0.";
        end
        if strlength(err) > 0
            problems(end+1) = subj(r) + ", weight: " + err; %#ok<AGROW>
            badCells(end+1, :) = [r 5]; %#ok<AGROW>
            w(r) = NaN;
        end

        [ml(r), err] = CarasLabDBApp.parseNumber(mTxt);
        if strlength(err) == 0 && ~isnan(ml(r)) && ml(r) < 0
            err = "'" + mTxt + "' is not a volume: it cannot be negative.";
        end
        if strlength(err) > 0
            problems(end+1) = subj(r) + ", water: " + err; %#ok<AGROW>
            badCells(end+1, :) = [r 6]; %#ok<AGROW>
            ml(r) = NaN;
        end

        used(r) = strlength(wTxt) > 0 || strlength(mTxt) > 0 ...
            || strlength(health(r)) > 0 || strlength(notes(r)) > 0;
    end
    entries = struct("Used", used, "WeightG", w, "WaterMl", ml);
    entries.Health = health;
    entries.Notes = notes;
end

function tf = local_isLow(weightG, baseG, pct)
    %LOCAL_ISLOW Entered weights below PCT % of the subject's baseline.
    tf = ~isnan(weightG) & ~isnan(baseG) & baseG > 0 & (weightG < (pct / 100) .* baseG);
end

function lines = local_summary(subj, entries, rows, baseG, pct)
    %LOCAL_SUMMARY One line per row to be written, as the confirmation shows it.
    lines = strings(1, 0);
    for r = reshape(rows, 1, [])
        parts = strings(1, 0);
        if ~isnan(entries.WeightG(r))
            p = local_numText(entries.WeightG(r)) + " g";
            if ~isnan(baseG(r)) && baseG(r) > 0
                share = 100 * entries.WeightG(r) / baseG(r);
                p = p + " (" + string(round(share)) + "% of baseline " + ...
                    local_numText(baseG(r)) + " g";
                if share < pct
                    p = p + ", BELOW " + local_numText(pct) + "%";
                end
                p = p + ")";
            end
            parts(end+1) = p; %#ok<AGROW>
        end
        if ~isnan(entries.WaterMl(r))
            parts(end+1) = "water " + local_numText(entries.WaterMl(r)) + " ml"; %#ok<AGROW>
        end
        if strlength(entries.Health(r)) > 0
            parts(end+1) = "health: " + entries.Health(r); %#ok<AGROW>
        end
        if strlength(entries.Notes(r)) > 0
            parts(end+1) = "note: " + entries.Notes(r); %#ok<AGROW>
        end
        lines(end+1) = subj(r) + ":  " + strjoin(parts, "; "); %#ok<AGROW>
    end
end

function T = local_batchTable(subj, entries, rows)
    %LOCAL_BATCHTABLE The table addHusbandryBatch takes: subject_id plus the
    %   columns that have at least one value. Within a column a blank is NaN
    %   (numbers) or <missing> (text), the class's "not provided".
    rows = reshape(rows, [], 1);
    T = table(reshape(subj(rows), [], 1), 'VariableNames', {'subject_id'});
    w = entries.WeightG(rows);
    if any(~isnan(w))
        T.weight_g = w;
    end
    ml = entries.WaterMl(rows);
    if any(~isnan(ml))
        T.water_ml = ml;
    end
    health = entries.Health(rows);
    if any(strlength(health) > 0)
        health(strlength(health) == 0) = string(missing);
        T.health_status = health;
    end
    notes = entries.Notes(rows);
    if any(strlength(notes) > 0)
        notes(strlength(notes) == 0) = string(missing);
        T.notes = notes;
    end
end

function [when, problem] = local_when(day, timeText)
    %LOCAL_WHEN The batch's occurred_at: the picked day plus HH:mm, local zone.
    when = NaT;
    problem = "";
    if isempty(day) || ~isdatetime(day) || isnat(day)
        problem = "Choose the date.";
        return
    end
    timeText = strtrim(timeText);
    tok = regexp(char(timeText), '^(\d{1,2}):(\d{2})(?::(\d{2}))?$', 'tokens', 'once');
    if isempty(tok)
        problem = "'" + timeText + "' is not a time of day. Use HH:mm, for example 09:30.";
        return
    end
    hh = str2double(tok{1});
    mm = str2double(tok{2});
    ss = 0;
    if numel(tok) >= 3 && ~isempty(tok{3})
        ss = str2double(tok{3});
    end
    if hh > 23 || mm > 59 || ss > 59
        problem = "'" + timeText + "' is not a time of day. Use HH:mm, for example 09:30.";
        return
    end
    when = dateshift(day, "start", "day") + duration(hh, mm, ss);
    if isempty(when.TimeZone)
        when.TimeZone = "local";          % what was typed is wall-clock time here
    end
end

function p = local_validPercent(v)
    %LOCAL_VALIDPERCENT The stored percentage, or 85 if it is not usable.
    p = 85;
    if isnumeric(v) && isscalar(v) && isreal(v) && isfinite(v) && v > 0 && v <= 100
        p = double(v);
    end
end

function s = local_cellText(v)
    %LOCAL_CELLTEXT One table cell as trimmed text ("" for an empty cell).
    s = "";
    if ischar(v)
        s = strtrim(string(v));
    elseif isstring(v) && isscalar(v) && ~ismissing(v)
        s = strtrim(v);
    elseif isnumeric(v) && isscalar(v) && isfinite(v)
        s = local_numText(v);
    end
    if ~isscalar(s)
        s = "";
    end
end

function s = local_numText(x)
    %LOCAL_NUMTEXT A number as the shortest text that reads back the same.
    try
        s = string(CarasLabDB.sqlLiteral(double(x)));
    catch
        s = string(x);
    end
end

function s = local_numCol(x)
    %LOCAL_NUMCOL A numeric column as text ("" for NaN).
    s = strings(numel(x), 1);
    for i = 1:numel(x)
        if ~isnan(x(i))
            s(i) = local_numText(x(i));
        end
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
            else
                s(i) = string(missing);
            end
        end
    else
        s = reshape(string(col), [], 1);
    end
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
        x = str2double(reshape(string(col), [], 1));
    end
end

function b = local_bool(col)
    %LOCAL_BOOL A fetched boolean column as a logical column vector (NULL -> false).
    if iscell(col)
        b = cellfun(@(v) ~isempty(v) && logical(v(1)), col);
    elseif isnumeric(col)
        b = col ~= 0 & ~isnan(double(col));
    elseif islogical(col)
        b = col;
    else
        b = ismember(lower(string(col)), ["true", "t", "1", "yes"]);
    end
    b = reshape(logical(b), [], 1);
end

function s = local_dateText(col)
    %LOCAL_DATETEXT Timestamps as "yyyy-MM-dd HH:mm" text ("" for none).
    if isdatetime(col)
        col.Format = "yyyy-MM-dd HH:mm";
        s = reshape(string(col), [], 1);
    else
        s = local_text(col);
    end
    s(ismissing(s)) = "";
end

function pos = local_center(w, h)
    su = get(groot, "ScreenSize");
    pos = [su(3)/2 - w/2, su(4)/2 - h/2, w, h];
end
