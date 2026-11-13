function eventIds = addHusbandryBatch(obj, T, opts)
%ADDHUSBANDRYBATCH Record one sheet of husbandry readings, one event per row, all or none.
%
%   T = table(["G-0421"; "G-0422"; "G-0423"], [71.9; NaN; 68.2], ...
%             VariableNames=["subject_id", "weight_g"]);
%   ids = addHusbandryBatch(db, T, OccurredAt=datetime("now", "TimeZone", "local"))
%   ids = addHusbandryBatch(db, T, Measure="water_restriction", Notes="week 3")
%
%   T is a table with a variable subject_id and any of
%       weight_g       numeric, grams, > 0     (NaN = not measured)
%       water_ml       numeric, millilitres, >= 0 (NaN = not measured)
%       health_status  text                    (missing or blank = none)
%       notes          text, stored on that row's event
%   Other variables of T are ignored. One husbandry event (lab.event +
%   lab.husbandry_event, like ADDHUSBANDRYEVENT) is written for every row
%   that has at least one of those four values; a row with none -- an animal
%   that was not weighed -- is skipped.
%
%   Everything is validated before anything is written: T must have
%   subject_id and at least one of the four variables, every row with a
%   value needs a subject_id, weights must be positive and water volumes
%   non-negative (CarasLabDB:invalidValue names the rows). The events are
%   then inserted in ONE transaction, so a failure on any row -- a
%   subject_id that does not exist, say -- leaves none of them behind.
%
%   Name=Value:
%       OccurredAt - when the readings were taken, for every row (default:
%                    now). Pass it for readings entered after the fact.
%       Measure    - what was measured, stored on every event (default
%                    "weight"; e.g. "health_check", "water_restriction")
%       Notes      - note for the rows that have none of their own
%       RecordedBy - person_id (default: the current person)
%
%   Returns the new event ids as a string column with one element per row of
%   T, in row order; the element of a skipped row is missing.
%
%   See also CARASLABDB, ADDHUSBANDRYEVENT, GETSUBJECTCURRENT, SUPERSEDEEVENT.

    arguments
        obj (1,1) CarasLabDB
        T table
        opts.OccurredAt (1,1) datetime = datetime("now", "TimeZone", "local")
        opts.Measure (1,1) string = "weight"
        opts.Notes (1,1) string = string(missing)
        opts.RecordedBy (1,1) string = string(missing)
    end

    % ---- validate: nothing is sent to the database before this passes ----
    valueVars = ["weight_g", "water_ml", "health_status", "notes"];
    names = string(T.Properties.VariableNames);
    if ~ismember("subject_id", names)
        error("CarasLabDB:invalidValue", "T needs a subject_id variable.");
    end
    if ~any(ismember(valueVars, names))
        error("CarasLabDB:invalidValue", ...
            "T needs at least one of the variables %s.", strjoin(valueVars, ", "));
    end
    if ismissing(opts.Measure) || strlength(strip(opts.Measure)) == 0
        error("CarasLabDB:invalidValue", "Measure must not be blank.");
    end
    if isnat(opts.OccurredAt)
        error("CarasLabDB:invalidValue", "OccurredAt must be a date and time, not NaT.");
    end

    nRows = height(T);
    eventIds = repmat(string(missing), nRows, 1);
    if nRows == 0
        return
    end

    subject = local_textColumn(T, "subject_id");
    weight  = local_numberColumn(T, "weight_g");
    water   = local_numberColumn(T, "water_ml");
    health  = local_textColumn(T, "health_status");
    notes   = local_textColumn(T, "notes");

    hasValue = ~isnan(weight) | ~isnan(water) | ~ismissing(health) | ~ismissing(notes);
    local_refuse(hasValue & ismissing(subject), "have a value but no subject_id");
    local_refuse(~isnan(weight) & ~(isfinite(weight) & weight > 0), ...
        "have a weight_g that is not a positive number");
    local_refuse(~isnan(water) & ~(isfinite(water) & water >= 0), ...
        "have a water_ml that is not zero or a positive number");

    rows = find(hasValue);
    if isempty(rows)
        return      % no row has a value: nothing to record
    end

    % ---- one insert struct pair per row to write ----
    recordedBy = obj.pCreatedBy(opts.RecordedBy);
    bases = cell(1, numel(rows));
    details = cell(1, numel(rows));
    for k = 1:numel(rows)
        r = rows(k);
        note = notes(r);
        if ismissing(note)
            note = opts.Notes;
        end
        base = struct("event_type", "husbandry");
        base.occurred_at = opts.OccurredAt;
        base.subject_id = subject(r);
        base = obj.pSet(base, "notes", note);
        base = obj.pSet(base, "recorded_by", recordedBy);

        detail = struct("measure", opts.Measure);
        detail = obj.pSet(detail, "weight_g", weight(r));
        detail = obj.pSet(detail, "water_ml", water(r));
        detail = obj.pSet(detail, "health_status", health(r));

        bases{k} = base;
        details{k} = detail;
    end

    % ---- write: every event of the sheet, or none ----
    detailTable = obj.pT("husbandry_event");
    eventIds(rows) = obj.pTransact(@() obj.pInsertEventBatch(bases, detailTable, details));
end

% -------------------------------------------------------------------------
function col = local_textColumn(T, name)
%LOCAL_TEXTCOLUMN Variable NAME of T as a string column; missing where blank or absent.
    nRows = height(T);
    col = repmat(string(missing), nRows, 1);
    if ~ismember(name, string(T.Properties.VariableNames))
        return
    end
    try
        v = string(T.(char(name)));
    catch
        error("CarasLabDB:invalidValue", "T.%s must hold text.", name);
    end
    if ~isequal(size(v), [nRows 1])
        error("CarasLabDB:invalidValue", "T.%s must be a single column of text.", name);
    end
    isBlank = ismissing(v);
    isBlank(~isBlank) = strlength(strip(v(~isBlank))) == 0;
    v(isBlank) = missing;
    col = v;
end

function col = local_numberColumn(T, name)
%LOCAL_NUMBERCOLUMN Variable NAME of T as a double column; NaN where absent.
    nRows = height(T);
    col = NaN(nRows, 1);
    if ~ismember(name, string(T.Properties.VariableNames))
        return
    end
    v = T.(char(name));
    if ~(isnumeric(v) && isreal(v) && isequal(size(v), [nRows 1]))
        error("CarasLabDB:invalidValue", ...
            "T.%s must be a single numeric column (NaN where there is no value).", name);
    end
    col = double(v);
end

function local_refuse(bad, problem)
%LOCAL_REFUSE Raise CarasLabDB:invalidValue naming the rows of T flagged in BAD.
    if any(bad)
        rowList = strjoin(string(reshape(find(bad), 1, [])), ", ");
        error("CarasLabDB:invalidValue", "Row(s) %s of T %s. Nothing was written.", rowList, problem);
    end
end
