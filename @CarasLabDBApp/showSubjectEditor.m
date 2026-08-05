function showSubjectEditor(obj, mode, subjectId)
%SHOWSUBJECTEDITOR Add a subject, or edit one in place.
%
%   showSubjectEditor(obj, "add", "")
%   showSubjectEditor(obj, "edit", subjectId)
%
%   Subjects are a mutable dimension (not append-only), so "edit" is a true
%   in-place UPDATE via CarasLabDB.updateSubject. The natural key subject_id is
%   set only on add and is read-only when editing.
%
%   See also CARASLABDBAPP/PFORMDIALOG, CARASLABDB/ADDSUBJECT, CARASLABDB/UPDATESUBJECT.

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
        local_espec("ProjectId","project_id","Project","enum", projects.Choices), ...
        local_espec("SpeciesCode","species_code","Species","enum", speciesChoices), ...
        local_espec("Sex","sex","Sex","enum", ["M","F","U"]), ...
        local_spec("Strain","strain","Strain","text", strings(1,0)), ...
        local_spec("Genotype","genotype","Genotype","text", strings(1,0)), ...
        local_spec("Source","source","Source","text", strings(1,0)), ...
        local_spec("DateOfBirth","date_of_birth","Date of birth","datetime", strings(1,0)), ...
        local_spec("Notes","notes","Notes","textarea", strings(1,0))];

    if isEdit
        vars = string(row.Properties.VariableNames);
        for i = 1:numel(fields)
            if ismember(fields(i).Col, vars)
                val = local_scalar(row.(char(fields(i).Col)));
                if fields(i).Key == "SpeciesCode"
                    val = local_lookup(val, speciesCodes, speciesChoices);
                elseif fields(i).Key == "ProjectId"
                    val = local_lookup(val, projects.Ids, projects.Choices);
                end
                fields(i).Value = val;
            end
            if ismember(fields(i).Key, ["SubjectId", "ProjectId"])
                % The key is immutable, and updateSubject takes no ProjectId —
                % both are shown for context only.
                fields(i).Editable = false;
            end
        end
        titleText = "Edit subject " + subjectId;
    else
        idx = find([fields.Key] == "Sex", 1);
        fields(idx).Value = "U";
        idx = find([fields.Key] == "SubjectId", 1);
        fields(idx).Value = "SUBJ-ID-";
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

    res = CarasLabDBApp.pFormDialog(titleText, fields);
    if ~res.OK, return; end

    try
        [args, subjId] = local_args(fields, res.Values, isEdit, subjectId, ...
            speciesCodes, speciesChoices, projects);
    catch ME
        uialert(obj.Fig, string(ME.message), "Invalid input");
        return
    end

    try
        if isEdit
            obj.Db.updateSubject(subjId, args{:});
            obj.pStatus("Updated subject " + subjId);
        else
            if strlength(subjId) == 0
                uialert(obj.Fig, "Subject id is required.", "Add subject");
                return
            end
            if ~any(string(args(1:2:end)) == "ProjectId")
                uialert(obj.Fig, "Project is required.", "Add subject");
                return
            end
            obj.Db.addSubject("SubjectId", subjId, args{:});
            obj.pStatus("Added subject " + subjId);
        end
    catch ME
        uialert(obj.Fig, string(ME.message), "Save subject failed");
        return
    end
    obj.refreshActiveTab();
end

% =============================================================================
function [args, subjId] = local_args(fields, values, isEdit, subjectId, ...
        speciesCodes, speciesChoices, projects)
    args = {};
    subjId = subjectId;
    for i = 1:numel(fields)
        f = fields(i);
        if isEdit && f.Key == "ProjectId"
            continue   % updateSubject cannot move a subject between projects
        end
        [provided, v] = local_convert(f, values.(char(f.Key)), ...
            speciesCodes, speciesChoices, projects);
        if f.Key == "SubjectId"
            if ~isEdit && provided
                subjId = v;
            end
            continue   % handled as the positional key, never a Name=Value arg
        end
        if provided
            args(end+1:end+2) = {f.Arg, v};
        end
    end
end

function [provided, v] = local_convert(f, raw, speciesCodes, speciesChoices, projects)
    switch f.Type
        case "datetime"
            v = raw;
            if isnat(v)
                provided = false; return
            end
            v.TimeZone = "local";
            provided = true;
        otherwise
            v = strtrim(string(raw));
            provided = strlength(v) > 0;
            if ~provided
                return
            end
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
        "Choices", string(choices), "Value", string(missing), "Editable", true);
end

function s = local_espec(key, col, label, type, choices)
    s = local_spec(key, col, label, type, choices);
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
