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
%   The supersede form names the event it corrects (id, type, subject,
%   occurred_at) in its first line. Only the fields the user changed are sent
%   as overrides; a prefilled field that is emptied is cleared (written as
%   NULL) unless the database requires it, in which case the form says so. If
%   nothing was changed, nothing is written.
%
%   See also CARASLABDBAPP/PFORMDIALOG, CARASLABDBAPP/FIELDCHANGE,
%   CARASLABDB/SUPERSEDEEVENT.

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

        % The form names the row it corrects (id, type, subject, time), so
        % the user can see that it is the one they selected.
        res = CarasLabDBApp.pFormDialog("Supersede " + eventType + " event (correction)", ...
            fields, local_header(eventId, eventType, D));
        if ~res.OK, return; end

        try
            [occ, eventOv, detailOv] = local_overrides(fields, res.Values, eventType);
        catch ME
            uialert(obj.Fig, string(ME.message), "Invalid input");
            return
        end

        % supersedeEvent inserts a correction even when nothing differs, so
        % an untouched form must not reach it.
        if isnat(occ) && isempty(fieldnames(eventOv)) && isempty(fieldnames(detailOv))
            obj.pStatus("No changes to save: event " + eventId + " was not superseded.");
            uialert(obj.Fig, "No changes to save. Nothing was written.", ...
                "Supersede", "Icon", "info");
            return
        end

        opts = {"EventOverrides", eventOv, "DetailOverrides", detailOv};
        if ~isnat(occ)
            opts = [{"OccurredAt", occ}, opts];
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
        [action, v] = local_convert(f, values.(char(f.Key)), false);
        if action == "set"
            args(end+1:end+2) = {f.Arg, v};
        end
    end
end

function [occ, eventOv, detailOv] = local_overrides(fields, values, eventType)
    %LOCAL_OVERRIDES Turn the edited form into supersedeEvent overrides.
    %   Only what the user altered is returned: OCC (NaT unless Occurred at
    %   was changed), EVENTOV for lab.event columns and DETAILOV for the
    %   detail table, both keyed by column name. An untouched field is left
    %   out, so supersedeEvent carries it forward exactly as stored; sending
    %   it back would rewrite it through the widget's rendering of it (a
    %   datetime to whole seconds, JSON re-spaced, a number re-parsed).
    %
    %   A field that was prefilled and is now blank is a request to clear
    %   it: its override is string(missing), which supersedeEvent writes as
    %   NULL. Clearing a column the database requires is refused here, with
    %   the field's name, rather than surfacing as a constraint violation.
    occ = NaT;
    eventOv = struct();
    detailOv = struct();
    baseCols = ["subject_id","session_id","notes","attributes"];
    required = local_requiredCols(eventType);

    for i = 1:numel(fields)
        f = fields(i);
        [action, v] = local_convert(f, values.(char(f.Key)), true);
        if action == "keep"
            continue
        end
        if action == "clear"
            if ismember(f.Col, required)
                error("CarasLabDBApp:requiredField", ...
                    "%s is required for a %s event and cannot be cleared.", ...
                    f.Label, eventType);
            end
            v = string(missing);          % supersedeEvent writes NULL
        end
        if f.Key == "OccurredAt"
            occ = v;                      % never a clear: occurred_at is required
        elseif ismember(f.Col, baseCols)
            eventOv.(char(f.Col)) = v;
        else
            detailOv.(char(f.Col)) = v;
        end
    end
end

function cols = local_requiredCols(eventType)
    %LOCAL_REQUIREDCOLS Columns of an event that may not be set to NULL.
    %   From design_docs/schema.sql: occurred_at and attributes are NOT NULL;
    %   every event except an analysis needs a subject
    %   (event_subject_required_ck); a recording needs a session
    %   (trg_require_session_for_recording) and a modality; a husbandry event
    %   a measure; an analysis its parameters.
    cols = ["occurred_at", "attributes"];
    if eventType ~= "analysis"
        cols(end+1) = "subject_id";
    end
    switch eventType
        case "recording"
            cols = [cols, "session_id", "modality"];
        case "husbandry"
            cols(end+1) = "measure";
        case "analysis"
            cols(end+1) = "parameters";
    end
end

function [action, v] = local_convert(f, raw, isEdit)
    %LOCAL_CONVERT What to do with one form value: "set", "clear" or "keep".
    %   CarasLabDBApp.fieldChange decides (see there); a value to set is then
    %   converted to what the database column takes: a true/false dropdown to
    %   a logical, JSON text validated.
    [action, v] = CarasLabDBApp.fieldChange(f, raw, isEdit);
    if action == "set" && isstring(v)
        if local_isBoolEnum(f)
            v = (v == "true");
        elseif local_isJson(f)
            v = local_parseJson(v, f.Label);
        end
    end
end

function h = local_header(eventId, eventType, D)
    %LOCAL_HEADER One line naming the event being corrected.
    parts = ["event " + eventId, eventType];
    try
        vars = string(D.Properties.VariableNames);
        if ismember("subject_id", vars)
            s = local_scalar(D.subject_id);
            if (ischar(s) || (isstring(s) && isscalar(s) && ~ismissing(s))) ...
                    && strlength(string(s)) > 0
                parts(end+1) = "subject " + string(s);
            end
        end
        if ismember("occurred_at", vars)
            t = local_scalar(D.occurred_at);
            if isdatetime(t) && ~isnat(t)
                t.Format = "yyyy-MM-dd HH:mm:ss";
                parts(end+1) = "occurred " + string(t);
            end
        end
    catch
        % The id and type alone still identify the row.
    end
    h = strjoin(parts, "  ·  ");
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
