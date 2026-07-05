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
                    val = local_speciesDisplay(val, speciesCodes, speciesChoices);
                end
                fields(i).Value = val;
            end
            if fields(i).Key == "SubjectId"
                fields(i).Editable = false;   % key is immutable
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
        titleText = "Add subject";
    end

    res = CarasLabDBApp.pFormDialog(titleText, fields);
    if ~res.OK, return; end

    try
        [args, subjId] = local_args(fields, res.Values, isEdit, subjectId);
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
function [args, subjId] = local_args(fields, values, isEdit, subjectId)
    args = {};
    subjId = subjectId;
    for i = 1:numel(fields)
        f = fields(i);
        [provided, v] = local_convert(f, values.(char(f.Key)));
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

function [provided, v] = local_convert(f, raw)
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
            if provided && f.Key == "SpeciesCode"
                v = local_speciesCode(v);
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

% ---- species "Common name (code)" display helpers ----------------------------
function v = local_speciesDisplay(code, codes, choices)
    idx = find(codes == code, 1);
    if isempty(idx)
        v = string(code);
    else
        v = choices(idx);
    end
end

function code = local_speciesCode(display)
    tok = regexp(display, "\(([^()]+)\)\s*$", "tokens", "once");
    if isempty(tok)
        code = display;
    else
        code = string(tok{1});
    end
end

function v = local_scalar(colvals)
    if isempty(colvals), v = string(missing); return; end
    if iscell(colvals), v = colvals{1}; else, v = colvals(1); end
    if ischar(v)
        if isempty(v), v = string(missing); else, v = string(v); end
    end
end
