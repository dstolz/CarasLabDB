function showSessionEditor(obj, mode, sessionId)
%SHOWSESSIONEDITOR Add a session, or edit one in place.
%
%   showSessionEditor(obj, "add", "")
%   showSessionEditor(obj, "edit", sessionId)
%
%   Sessions are a mutable dimension, so "edit" is a true in-place UPDATE via
%   CarasLabDB.updateSession. session_id and the owning subject_id are set only
%   on add and are read-only when editing.
%
%   Editing writes only what the user changed. Started at, Ended at, Rig and
%   Notes are cleared (updateSession's Clear=) when emptied; Label, Storage
%   root id and Relative path are required. If nothing was changed, nothing
%   is written.
%
%   See also CARASLABDBAPP/PFORMDIALOG, CARASLABDBAPP/FIELDCHANGE,
%   CARASLABDB/ADDSESSION, CARASLABDB/UPDATESESSION.

    arguments
        obj (1,1) CarasLabDBApp
        mode (1,1) string
        sessionId (1,1) string = ""
    end

    isEdit = (mode == "edit");

    try
        subs = obj.Db.getSubjects();
        subjChoices = string(subs.subject_id);
    catch
        subjChoices = strings(1,0);
    end

    row = table();
    if isEdit
        if strlength(sessionId) == 0, return; end
        try
            row = obj.Db.getSessions(SessionId = sessionId);
        catch ME
            uialert(obj.Fig, string(ME.message), "Load session failed");
            return
        end
        if height(row) == 0
            uialert(obj.Fig, "Session not found: " + sessionId, "Edit session");
            return
        end
    end

    fields = [ ...
        local_spec("SubjectId","subject_id","Subject id", ...
            local_ifelse(isempty(subjChoices), "text", "enum"), subjChoices), ...
        local_spec("Label","label","Label","text", strings(1,0)), ...
        local_spec("StorageRootId","storage_root_id","Storage root id","number", strings(1,0)), ...
        local_spec("RelativePath","relative_path","Relative path","text", strings(1,0)), ...
        local_spec("StartedAt","started_at","Started at","datetime", strings(1,0)), ...
        local_spec("EndedAt","ended_at","Ended at","datetime", strings(1,0)), ...
        local_spec("Rig","rig","Rig","text", strings(1,0)), ...
        local_spec("Notes","notes","Notes","textarea", strings(1,0))];

    if isEdit
        vars = string(row.Properties.VariableNames);
        for i = 1:numel(fields)
            if ismember(fields(i).Col, vars)
                fields(i).Value = local_scalar(row.(char(fields(i).Col)));
            end
            if fields(i).Key == "SubjectId"
                fields(i).Editable = false;   % session's subject is fixed
            end
        end
        titleText = "Edit session " + sessionId;
    else
        titleText = "Add session";
    end

    res = CarasLabDBApp.pFormDialog(titleText, fields);
    if ~res.OK, return; end

    try
        [args, clearCols] = local_args(fields, res.Values, isEdit);
    catch ME
        uialert(obj.Fig, string(ME.message), "Invalid input");
        return
    end

    try
        if isEdit
            if isempty(args) && isempty(clearCols)
                obj.pStatus("No changes to save for session " + sessionId + ".");
                return
            end
            if ~isempty(clearCols)
                args = [args, {"Clear", clearCols}];
            end
            obj.Db.updateSession(sessionId, args{:});
            obj.pStatus("Updated session " + sessionId);
        else
            missingReq = local_missingRequired(fields, res.Values);
            if ~isempty(missingReq)
                uialert(obj.Fig, "Required: " + strjoin(missingReq, ", "), "Add session");
                return
            end
            newId = obj.Db.addSession(args{:});
            obj.pStatus("Added session " + newId);
        end
    catch ME
        uialert(obj.Fig, string(ME.message), "Save session failed");
        return
    end
    obj.refreshActiveTab();
end

% =============================================================================
function [args, clearCols] = local_args(fields, values, isEdit)
    %LOCAL_ARGS Name=Value arguments for addSession / updateSession.
    %   Adding: every non-blank field. Editing: only the fields the user
    %   changed (ARGS), plus the columns of fields that were prefilled and
    %   are now blank (CLEARCOLS, for updateSession's Clear=). An untouched
    %   field is never written back. Emptying a field the database requires
    %   is an error that names the field.
    args = {};
    clearCols = strings(1, 0);
    clearable = ["started_at","ended_at","rig","notes"];
    for i = 1:numel(fields)
        f = fields(i);
        if isEdit && f.Key == "SubjectId"
            continue   % subject is fixed for an existing session
        end
        [action, v] = CarasLabDBApp.fieldChange(f, values.(char(f.Key)), isEdit);
        if action == "set"
            args(end+1:end+2) = {f.Arg, v};
        elseif action == "clear"
            if ~ismember(f.Col, clearable)
                error("CarasLabDBApp:requiredField", ...
                    "%s is required and cannot be cleared.", f.Label);
            end
            clearCols(end+1) = f.Col;
        end
    end
end

function req = local_missingRequired(fields, values)
    required = ["SubjectId","Label","StorageRootId","RelativePath"];
    req = strings(1,0);
    for i = 1:numel(fields)
        f = fields(i);
        if ~ismember(f.Key, required), continue; end
        [action, ~] = CarasLabDBApp.fieldChange(f, values.(char(f.Key)), false);
        if action ~= "set"
            req(end+1) = f.Label; %#ok<AGROW>
        end
    end
end

% ---- helpers -----------------------------------------------------------------
function s = local_spec(key, col, label, type, choices)
    s = struct("Key", string(key), "Arg", string(key), "Col", string(col), ...
        "Label", string(label), "Type", string(type), ...
        "Choices", string(choices), "Value", string(missing), "Editable", true);
end

function out = local_ifelse(cond, a, b)
    if cond, out = a; else, out = b; end
end

function v = local_scalar(colvals)
    if isempty(colvals), v = string(missing); return; end
    if iscell(colvals), v = colvals{1}; else, v = colvals(1); end
    if ischar(v)
        if isempty(v), v = string(missing); else, v = string(v); end
    end
end
