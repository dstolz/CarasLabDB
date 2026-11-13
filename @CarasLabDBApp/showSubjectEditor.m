function showSubjectEditor(obj, mode, subjectId)
%SHOWSUBJECTEDITOR Add a subject, or edit one in place.
%
%   showSubjectEditor(obj, "add", "")
%   showSubjectEditor(obj, "edit", subjectId)
%
%   Subjects are a mutable dimension (not append-only), so "edit" is a true
%   in-place UPDATE via CarasLabDB.updateSubject. The natural key subject_id is
%   set only on add and is read-only when editing (renaming an animal is done
%   by an administrator with lab.fn_rename_subject).
%
%   Editing writes only what the user changed. A field that held a value and
%   is emptied is cleared (updateSubject's Clear=); Project and Sex cannot be
%   cleared. Before anything is written the form shows one confirmation that
%   lists each changed field with its old and its new value
%   (CarasLabDBApp.confirmChanges); "Go back" returns to the form. If nothing
%   was changed, nothing is written.
%
%   The entries are checked, confirmed and written while the form is still
%   open (pFormDialog's accept hook), so a value refused here or by the
%   database does not lose what was typed.
%
%   See also CARASLABDBAPP/PFORMDIALOG, CARASLABDBAPP/FIELDCHANGE,
%   CARASLABDBAPP/CONFIRMCHANGES, CARASLABDB/ADDSUBJECT,
%   CARASLABDB/UPDATESUBJECT.

    arguments
        obj (1,1) CarasLabDBApp
        mode (1,1) string
        subjectId (1,1) string = ""
    end

    isEdit = (mode == "edit");

    % Species choices for a friendly dropdown: "Common name (code)", fall back
    % to free text if the lookup table can't be read.
    try
        S = obj.Db.getSpecies();
        speciesCodes = string(S.code);
        speciesChoices = string(S.common_name) + " (" + speciesCodes + ")";
    catch
        speciesCodes = strings(1,0);
        speciesChoices = strings(1,0);
    end

    % Project is required by addSubject and NOT NULL in the schema, so it needs
    % its own dropdown; without one every "Add subject" fails in the argument
    % validator. Displayed by name, submitted as the project_id.
    try
        P = obj.Db.getProjects(IsActive = true);
        projects = struct("Ids", string(P.project_id), "Choices", string(P.name));
    catch
        projects = struct("Ids", strings(1,0), "Choices", strings(1,0));
    end

    row = table();
    if isEdit
        if strlength(subjectId) == 0, return; end
        try
            row = obj.Db.getSubjects(SubjectId = subjectId);
        catch ME
            uialert(obj.Fig, string(ME.message), "Load subject failed");
            return
        end
        if height(row) == 0
            uialert(obj.Fig, "Subject not found: " + subjectId, "Edit subject");
            return
        end
    end

    fields = [ ...
        local_spec("SubjectId","subject_id","Subject id","text", strings(1,0)), ...
        local_spec("ProjectId","project_id","Project","enum", projects.Choices), ...
        local_spec("SpeciesCode","species_code","Species","enum", speciesChoices), ...
        local_spec("Sex","sex","Sex","enum", ["M","F","U"]), ...
        local_spec("Strain","strain","Strain","text", strings(1,0)), ...
        local_spec("Genotype","genotype","Genotype","text", strings(1,0)), ...
        local_spec("Source","source","Source","text", strings(1,0)), ...
        local_spec("DateOfBirth","date_of_birth","Date of birth","datetime", strings(1,0)), ...
        local_spec("Notes","notes","Notes","textarea", strings(1,0))];

    headerText = "";
    if isEdit
        vars = string(row.Properties.VariableNames);
        for i = 1:numel(fields)
            if ismember(fields(i).Col, vars)
                val = local_scalar(row.(char(fields(i).Col)));
                if fields(i).Key == "SpeciesCode"
                    val = local_lookup(val, speciesCodes, speciesChoices);
                elseif fields(i).Key == "ProjectId"
                    % A project that is no longer active is not among the
                    % choices; the dropdown then shows blank, which the form
                    % treats as "untouched" (see CarasLabDBApp.fieldChange).
                    val = local_lookup(val, projects.Ids, projects.Choices);
                end
                fields(i).Value = val;
            end
            if fields(i).Key == "SubjectId"
                % The key is immutable here: shown for context only.
                fields(i).Editable = false;
            end
        end
        titleText = "Edit subject " + subjectId;
        headerText = "subject " + subjectId;
    else
        idx = find([fields.Key] == "Sex", 1);
        fields(idx).Value = "U";
        % The id format is shown as a placeholder, not prefilled: a prefilled
        % example can be saved as a real subject_id, which is a permanent key.
        idx = find([fields.Key] == "SubjectId", 1);
        fields(idx).Placeholder = "lab id, e.g. G-0421";
        idx = find([fields.Key] == "SpeciesCode", 1);
        gerbilIdx = find(contains(lower(speciesChoices), "gerbil"), 1);
        if ~isempty(gerbilIdx)
            fields(idx).Value = speciesChoices(gerbilIdx);
        end
        if isscalar(projects.Choices)
            idx = find([fields.Key] == "ProjectId", 1);
            fields(idx).Value = projects.Choices(1);   % only one choice to make
        end
        titleText = "Add subject";
    end

    % Set by the accept hook, which does the write while the form is open.
    saved = "";                 % "" (nothing to write), "added" or "updated"
    savedId = subjectId;

    res = CarasLabDBApp.pFormDialog(titleText, fields, headerText, @accept);
    if ~res.OK, return; end

    if saved == ""
        obj.pStatus("No changes to save for subject " + savedId + ".");
        return
    end
    if saved == "added"
        obj.pStatus("Added subject " + savedId);
    else
        obj.pStatus("Updated subject " + savedId);
    end
    obj.refreshActiveTab();

    % ---- nested: pFormDialog's accept hook ----------------------------------
    function accepted = accept(formValues, formFig)
        %ACCEPT Check the entries, show what will change, and write.
        %   Runs when OK is pressed, while the form is open; the form closes
        %   only if this returns true. An error thrown here (a required
        %   field emptied) is shown by pFormDialog as an alert on the form,
        %   and a refusal by the database is shown here, so in both cases
        %   the user keeps what they typed.
        accepted = false;
        [accArgs, accId, accClear, accChanges] = local_args(fields, formValues, isEdit, ...
            subjectId, speciesCodes, speciesChoices, projects);
        if isEdit
            if isempty(accArgs) && isempty(accClear)
                accepted = true;            % untouched: close, write nothing
                return
            end
            % Nothing is written until this is confirmed.
            if ~CarasLabDBApp.confirmChanges(formFig, "Subject " + accId + ".", accChanges)
                return
            end
            if ~isempty(accClear)
                accArgs = [accArgs, {"Clear", accClear}];
            end
            try
                obj.Db.updateSubject(accId, accArgs{:});
            catch accErr
                uialert(formFig, string(accErr.message), "Save subject failed");
                return
            end
            saved = "updated";
        else
            if strlength(accId) == 0
                uialert(formFig, "Subject id is required.", "Add subject");
                return
            end
            if ~any(string(accArgs(1:2:end)) == "ProjectId")
                uialert(formFig, "Project is required.", "Add subject");
                return
            end
            try
                obj.Db.addSubject("SubjectId", accId, accArgs{:});
            catch accErr
                uialert(formFig, string(accErr.message), "Save subject failed");
                return
            end
            saved = "added";
        end
        savedId = accId;
        accepted = true;
    end
end

% =============================================================================
function [args, subjId, clearCols, changes] = local_args(fields, values, isEdit, subjectId, ...
        speciesCodes, speciesChoices, projects)
    %LOCAL_ARGS Name=Value arguments for addSubject / updateSubject.
    %   Adding: every non-blank field. Editing: only the fields the user
    %   changed (ARGS), plus the columns of fields that were prefilled and
    %   are now blank (CLEARCOLS, for updateSubject's Clear=). An untouched
    %   field is never written back, so it cannot be altered by the form's
    %   rendering of it. Emptying a field the database requires is an error
    %   that names the field. CHANGES lists what an edit alters, as shown to
    %   the user: Label, Old and New (text; New is "(cleared)" for a clear).
    args = {};
    clearCols = strings(1, 0);
    changes = struct("Label", {}, "Old", {}, "New", {});
    subjId = subjectId;
    clearable = ["species_code","strain","genotype","source","date_of_birth","notes"];
    for i = 1:numel(fields)
        f = fields(i);
        if isEdit && f.Key == "SubjectId"
            continue   % read-only when editing: shown for context only
        end
        raw = values.(char(f.Key));
        [action, v] = local_convert(f, raw, isEdit, ...
            speciesCodes, speciesChoices, projects);
        if f.Key == "SubjectId"
            if action == "set"
                subjId = v;
            end
            continue   % handled as the positional key, never a Name=Value arg
        end
        if action == "set"
            args(end+1:end+2) = {f.Arg, v};
            newText = CarasLabDBApp.formatValue(raw);
        elseif action == "clear"
            if ~ismember(f.Col, clearable)
                error("CarasLabDBApp:requiredField", ...
                    "%s is required and cannot be cleared.", f.Label);
            end
            clearCols(end+1) = f.Col; %#ok<AGROW>
            newText = "(cleared)";
        else
            continue
        end
        if isEdit
            changes(end+1) = struct("Label", f.Label, ...
                "Old", CarasLabDBApp.formatValue(f.Value), "New", newText); %#ok<AGROW>
        end
    end
end

function [action, v] = local_convert(f, raw, isEdit, speciesCodes, speciesChoices, projects)
    %LOCAL_CONVERT What to do with one form value: "set", "clear" or "keep".
    %   CarasLabDBApp.fieldChange decides; date_of_birth is a calendar date,
    %   so it counts as unchanged while the day is the same.
    [action, v] = CarasLabDBApp.fieldChange(f, raw, isEdit, ...
        DateOnly=(f.Col == "date_of_birth"));
    if action == "set" && isstring(v)
        % Dropdowns show a friendly label; the database wants the key.
        if f.Key == "SpeciesCode"
            v = local_lookup(v, speciesChoices, speciesCodes);
        elseif f.Key == "ProjectId"
            v = local_lookup(v, projects.Choices, projects.Ids);
        end
    end
end

% ---- spec helpers ------------------------------------------------------------
function s = local_spec(key, col, label, type, choices)
    s = struct("Key", string(key), "Arg", string(key), "Col", string(col), ...
        "Label", string(label), "Type", string(type), ...
        "Choices", string(choices), "Value", string(missing), "Editable", true, ...
        "Placeholder", "");
end

% ---- dropdown label <-> key mapping ------------------------------------------
function out = local_lookup(key, keys, values)
    %LOCAL_LOOKUP Translate between a dropdown's label and the key it stands for.
    %   Used in both directions (label->key on save, key->label on prefill).
    %   An unknown value passes through, which is what keeps the form usable
    %   when the lookup table could not be read.
    idx = find(keys == string(key), 1);
    if isempty(idx)
        out = string(key);
    else
        out = values(idx);
    end
end

function v = local_scalar(colvals)
    if isempty(colvals), v = string(missing); return; end
    if iscell(colvals), v = colvals{1}; else, v = colvals(1); end
    if ischar(v)
        if isempty(v), v = string(missing); else, v = string(v); end
    end
end
