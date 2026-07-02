function showEventEditor(obj, mode, eventType, eventId)
%SHOWEVENTEDITOR Add a new event, or supersede (correct) an existing one.
%
%   showEventEditor(obj, "add", "", "")            % pick a type, then add
%   showEventEditor(obj, "supersede", "", eventId) % correct an existing event
%
%   In "add" mode the user first picks an event type; the form then shows the
%   shared base fields plus that type's detail fields and dispatches to the
%   matching add*Event method. In "supersede" mode the form is prefilled from
%   getEventDetail and a superseding correction is inserted via supersedeEvent
%   (the original row is retained, hidden by the *_active view).
%
%   See also CARASLABDBAPP/PFORMDIALOG, CARASLABDB/SUPERSEDEEVENT.

    arguments
        obj (1,1) CarasLabDBApp
        mode (1,1) string
        eventType (1,1) string = ""
        eventId (1,1) string = ""
    end

    types = ["birth","surgery","recording","behavior", ...
             "husbandry","endpoint","histology","analysis"];

    if mode == "add"
        % Step 1: choose the event type.
        if strlength(eventType) == 0
            pick = CarasLabDBApp.pFormDialog("New event — choose type", ...
                struct("Key","Type", "Label","Event type", "Type","enum", ...
                       "Choices", {types}, "Value", ""));
            if ~pick.OK || strlength(pick.Values.Type) == 0
                return
            end
            eventType = pick.Values.Type;
        end
        fields = local_fields(eventType, table());          % blank defaults
        % Default OccurredAt to now.
        idx = find(strcmp({fields.Key}, "OccurredAt"), 1);
        fields(idx).Value = datetime("now", "TimeZone", "local");

        res = CarasLabDBApp.pFormDialog("Add " + eventType + " event", fields);
        if ~res.OK, return; end

        try
            args = local_addArgs(fields, res.Values);
        catch ME
            uialert(obj.Fig, string(ME.message), "Invalid input");
            return
        end
        if ~any(strcmp(args(1:2:end), "OccurredAt"))
            uialert(obj.Fig, "Occurred at is required.", "Add event");
            return
        end

        methodName = "add" + local_cap(eventType) + "Event";
        try
            newId = feval(char(methodName), obj.Db, args{:});
        catch ME
            uialert(obj.Fig, string(ME.message), "Add event failed");
            return
        end
        obj.pStatus("Added " + eventType + " event " + newId);
        obj.refreshActiveTab();

    elseif mode == "supersede"
        if strlength(eventId) == 0
            return
        end
        try
            D = obj.Db.getEventDetail(EventId = eventId);
        catch ME
            uialert(obj.Fig, string(ME.message), "Load event failed");
            return
        end
        if height(D) == 0
            uialert(obj.Fig, "Event not found: " + eventId, "Supersede");
            return
        end
        eventType = string(D.event_type(1));
        fields = local_fields(eventType, D);                % prefilled

        res = CarasLabDBApp.pFormDialog("Supersede " + eventType + " event (correction)", fields);
        if ~res.OK, return; end

        try
            [occ, notes, notesProvided, eventOv, detailOv] = ...
                local_overrides(fields, res.Values);
        catch ME
            uialert(obj.Fig, string(ME.message), "Invalid input");
            return
        end

        opts = {"EventOverrides", eventOv, "DetailOverrides", detailOv};
        if ~isnat(occ)
            opts = [{"OccurredAt", occ}, opts];
        end
        if notesProvided
            opts = [{"Notes", notes}, opts];
        end

        try
            newId = obj.Db.supersedeEvent(eventId, opts{:});
        catch ME
            uialert(obj.Fig, string(ME.message), "Supersede failed");
            return
        end
        obj.pStatus("Superseded " + eventId + " → " + newId + " (original retained)");
        obj.refreshActiveTab();
    end
end

% =============================================================================
function fields = local_fields(eventType, D)
    %LOCAL_FIELDS Base + detail field specs, prefilled from detail row D if given.
    base = [ ...
        local_spec("OccurredAt","OccurredAt","occurred_at","Occurred at","datetime"), ...
        local_spec("SubjectId","SubjectId","subject_id","Subject id","text"), ...
        local_spec("SessionId","SessionId","session_id","Session id","text"), ...
        local_spec("Notes","Notes","notes","Notes","textarea"), ...
        local_spec("Attributes","Attributes","attributes","Attributes (JSON)","textarea")];

    detail = CarasLabDBApp.eventFieldSpecs(eventType);
    detail = local_addValueField(detail);
    fields = [base, detail];

    % Prefill from D (a getEventDetail row) when superseding.
    if ~isempty(D) && height(D) > 0
        vars = string(D.Properties.VariableNames);
        for i = 1:numel(fields)
            c = fields(i).Col;
            if ismember(c, vars)
                fields(i).Value = local_scalar(D.(char(c)));
            end
        end
    end
end

function args = local_addArgs(fields, values)
    %LOCAL_ADDARGS Build a Name=Value cell for an add*Event call from form values.
    args = {};
    for i = 1:numel(fields)
        f = fields(i);
        [provided, v] = local_convert(f, values.(char(f.Key)));
        if provided
            args(end+1:end+2) = {f.Arg, v};
        end
    end
end

function [occ, notes, notesProvided, eventOv, detailOv] = local_overrides(fields, values)
    %LOCAL_OVERRIDES Split provided form values into supersede override structs.
    occ = NaT;
    notes = string(missing);
    notesProvided = false;
    eventOv = struct();
    detailOv = struct();
    baseCols = ["subject_id","session_id","attributes"];

    for i = 1:numel(fields)
        f = fields(i);
        [provided, v] = local_convert(f, values.(char(f.Key)));
        if ~provided
            continue
        end
        switch f.Key
            case "OccurredAt"
                occ = v;
            case "Notes"
                notes = v;
                notesProvided = true;
            otherwise
                if ismember(f.Col, baseCols)
                    eventOv.(char(f.Col)) = v;
                else
                    detailOv.(char(f.Col)) = v;
                end
        end
    end
end

function [provided, v] = local_convert(f, raw)
    %LOCAL_CONVERT Coerce a raw widget value to its typed form; report if set.
    switch f.Type
        case "number"
            v = raw;                 % double, NaN when blank
            provided = ~isnan(v);
        case "bool"
            v = logical(raw);
            provided = true;
        case "datetime"
            str = strtrim(string(raw));
            if strlength(str) == 0
                v = NaT; provided = false; return
            end
            v = local_parseDateTime(str, f.Label);
            provided = true;
        otherwise                    % text / textarea / enum
            v = strtrim(string(raw));
            provided = strlength(v) > 0;
            if provided && local_isJson(f)
                v = local_parseJson(v, f.Label);
            end
    end
end

function tf = local_isJson(f)
    tf = ismember(f.Col, ["attributes","hardware_config","parameters","environment"]);
end

function v = local_parseJson(str, label)
    %LOCAL_PARSEJSON Validate JSON and return a struct (so sqlLiteral emits ::jsonb).
    %   Non-object JSON (arrays/scalars) is passed through as the original string,
    %   which Postgres still casts into the jsonb column.
    try
        decoded = jsondecode(char(str));
    catch
        error("CarasLabDBApp:badJson", "%s is not valid JSON.", label);
    end
    if isstruct(decoded)
        v = decoded;
    else
        v = str;   % array/scalar JSON — let the DB cast the text literal
    end
end

function dt = local_parseDateTime(str, label)
    try
        dt = datetime(str, "InputFormat", "yyyy-MM-dd HH:mm:ss", "TimeZone", "local");
    catch
        dt = NaT;
    end
    if isnat(dt)
        try
            dt = datetime(str, "TimeZone", "local");
        catch
            dt = NaT;
        end
    end
    if isnat(dt)
        error("CarasLabDBApp:badDateTime", ...
            "'%s' is not a valid date/time for %s (use yyyy-MM-dd HH:mm:ss).", str, label);
    end
end

% ---- spec helpers ------------------------------------------------------------
function s = local_spec(key, arg, col, label, type)
    s = struct("Key", string(key), "Arg", string(arg), "Col", string(col), ...
        "Label", string(label), "Type", string(type), ...
        "Choices", strings(1,0), "Value", string(missing));
end

function d = local_addValueField(d)
    for i = 1:numel(d)
        d(i).Value = string(missing);
    end
end

function c = local_cap(t)
    t = char(t);
    c = string([upper(t(1)), t(2:end)]);
end

function v = local_scalar(colvals)
    if isempty(colvals)
        v = string(missing); return
    end
    if iscell(colvals)
        v = colvals{1};
    else
        v = colvals(1);
    end
    if ischar(v)
        if isempty(v), v = string(missing); else, v = string(v); end
    end
end
