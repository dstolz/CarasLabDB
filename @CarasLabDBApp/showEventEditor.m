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
        idx = find([fields.Key] == "OccurredAt", 1);
        fields(idx).Value = datetime("now", "TimeZone", "local");

        res = CarasLabDBApp.pFormDialog("Add " + eventType + " event", fields);
        if ~res.OK, return; end

        try
            args = local_addArgs(fields, res.Values);
        catch ME
            uialert(obj.Fig, string(ME.message), "Invalid input");
            return
        end
        if ~any(string(args(1:2:end)) == "OccurredAt")
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
        [provided, v] = local_convert(f, values.(char(f.Key)), false);
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
        % A supersede prefills every field from the row being corrected, so
        % only send back what the user actually altered. Passing an untouched
        % datetime through as an override rewrites the stored value.
        [provided, v] = local_convert(f, values.(char(f.Key)), true);
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

function [provided, v] = local_convert(f, raw, onlyIfChanged)
    %LOCAL_CONVERT Coerce a raw widget value to its typed form; report if set.
    %   ONLYIFCHANGED suppresses "provided" for a datetime that still matches
    %   the value the form was prefilled with.
    switch f.Type
        case "number"
            v = raw;                 % double, NaN when blank
            provided = ~isnan(v);
        case "bool"
            v = logical(raw);
            provided = true;
        case "datetime"
            v = raw;
            if isnat(v)
                provided = false; return
            end
            v.TimeZone = "local";
            provided = ~(onlyIfChanged && local_sameInstant(v, f.Value));
        otherwise                    % text / textarea / enum
            v = strtrim(string(raw));
            provided = strlength(v) > 0;
            if ~provided
                return
            end
            if local_isBoolEnum(f)
                v = (v == "true");
            elseif local_isJson(f)
                v = local_parseJson(v, f.Label);
            end
    end
end

function tf = local_isJson(f)
    tf = ismember(f.Col, ["attributes","hardware_config","parameters","environment"]);
end

function tf = local_isBoolEnum(f)
    %LOCAL_ISBOOLENUM True for an enum standing in for a nullable boolean column.
    %   A checkbox cannot express NULL, so nullable booleans are offered as a
    %   true/false dropdown whose blank choice leaves the column unset.
    tf = f.Type == "enum" && ...
        isequal(sort(reshape(string(f.Choices), 1, [])), ["false", "true"]);
end

function tf = local_sameInstant(v, orig)
    %LOCAL_SAMEINSTANT True when a form datetime still equals what it was
    %   prefilled with. The form only surfaces whole seconds, so compare there.
    tf = false;
    if isempty(orig) || (isstring(orig) && isscalar(orig) && ismissing(orig))
        return
    end
    try
        if isdatetime(orig)
            o = orig;
        else
            o = datetime(string(orig), "TimeZone", "local");
        end
    catch
        return
    end
    if ~isscalar(o) || isnat(o)
        return
    end
    if isempty(o.TimeZone)
        o.TimeZone = "local";
    end
    tf = abs(seconds(v - o)) < 1;
end

function v = local_parseJson(str, label)
    %LOCAL_PARSEJSON Validate JSON syntax and hand back the user's own text.
    %   Decoding and re-encoding would rewrite the document: jsondecode renames
    %   keys that are not valid MATLAB identifiers ("sample-rate" -> sample_rate),
    %   collapses single-element arrays and reorders fields. sqlLiteral emits a
    %   quoted text literal for a string and Postgres assignment-casts it into
    %   the jsonb column, so passing the text straight through is lossless.
    try
        jsondecode(char(str));
    catch
        error("CarasLabDBApp:badJson", "%s is not valid JSON.", label);
    end
    v = strtrim(string(str));
    if ~startsWith(v, "{")
        % The schema constrains these columns to JSON objects; refusing here
        % names the offending field instead of surfacing a CHECK violation.
        error("CarasLabDBApp:jsonNotObject", ...
            "%s must be a JSON object, e.g. {""key"": 1}.", label);
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
