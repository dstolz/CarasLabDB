function out = recordEvent(obj, eventType, opts)
%RECORDEVENT Write an event, its input edges and its output files once, as one transaction.
%
%   out = recordEvent(db, "analysis", EventId=eid, Digest=d, ...
%           OccurredAt=datetime(2026,11,14,9,30,0,"TimeZone","America/New_York"), ...
%           SessionId=sid, ...
%           Detail=struct("pipeline_name", "ephys_analysis/signals", ...
%                         "code_version", "c677202", ...
%                         "parameters", CarasLabDB.jsonText(optionsJson), ...
%                         "started_at", t0, "finished_at", t1, "status", "succeeded"), ...
%           Inputs=struct("artifact_id", {rawId}, "role", {"raw"}), ...
%           Outputs=struct("artifact_id", {aid}, "storage_root_id", {1}, ...
%                          "relative_path", {"G-0421/s1/s1_extract.mat"}, ...
%                          "checksum", {sha256hex}, "size_bytes", {n}, ...
%                          "role", {"lfp"}, "format", {"mat"}))
%
%   For a client that records work while the database may be out of reach:
%   it mints the event's id (and its files' ids) itself, keeps what it
%   means to write, and sends it when it can -- possibly more than once, if
%   a send was cut off after the commit. Sending the same record again is
%   harmless. In one transaction RECORDEVENT:
%     1. Looks for an event with id EventId. One whose
%        attributes.client_digest equals Digest is this same record, sent
%        before: nothing is written (out.Outcome "existing"). One with
%        another digest, or none, is a different record under that id:
%        CarasLabDB:idConflict, and nothing is written.
%     2. Looks up each output file by (storage root, relative path,
%        checksum). A file already registered with exactly those bytes at
%        that path is not registered again -- a row describes a file once
%        (uq_artifact_file_original): the output keeps the existing row,
%        out.Unchanged says so, and the event lists the row in
%        attributes.unchanged_outputs.
%     3. Inserts the event (attributes gain client_digest, and
%        unchanged_outputs when there are any) and its detail row.
%     4. Inserts its input edges. An input artifact the database does not
%        have is an error (the foreign key), or with MissingInputs="skip" it
%        is left out and listed in out.SkippedInputs, to be added later with
%        ADDEVENTINPUT(..., IfExists="skip") once the file is registered.
%     5. Inserts the new output files, produced by this event. An output
%        that names no subject or session is filed under the event's; one
%        that names others is refused by the database, never re-filed.
%   Any failure rolls the whole transaction back: nothing is half written.
%
%   EventType is "analysis", "recording" or "behavior". Detail holds that
%   type's detail columns, by their names in design_docs/schema.sql:
%     analysis:  pipeline_id, pipeline_name, code_version, parameters,
%                environment, started_at, finished_at, status
%     recording: acquisition_system_code, probe_id, modality,
%                sample_rate_hz, n_channels, duration_s, stimulus_protocol,
%                hardware_config
%     behavior:  task, paradigm, stage, trials_completed, performance, reward
%   A jsonb value (parameters, environment, hardware_config, Attributes, an
%   output's attributes) is a struct (sent through jsonencode) or
%   CarasLabDB.jsonText(text) (sent as written). Every datetime must carry
%   a time zone (CarasLabDB:unzonedTime): a record sent later, or from
%   another computer, must not depend on the zone of the computer that
%   sends it.
%
%   Inputs is a struct array with fields artifact_id and, optionally, role.
%   Outputs is a struct array with fields storage_root_id, relative_path
%   and checksum, and optionally artifact_id, checksum_algo, size_bytes,
%   role, format, subject_id, session_id and attributes. A field outside
%   these lists is an error (CarasLabDB:invalidValue): field names become
%   column names, so they are checked against fixed lists here.
%
%   Required Name=Value:
%       EventId    - the event's id, a uuid the caller minted
%       Digest     - the caller's digest of what it records, 32 to 128
%                    hexadecimal digits (e.g. SHA-256): the same record must
%                    always give the same digest, and a different one a
%                    different digest
%       OccurredAt - when it happened (zoned datetime)
%   Optional Name=Value:
%       SubjectId, SessionId, Notes, Attributes, RecordedBy (a person_id;
%       default: the current person), RecordedAt, Detail, Inputs, Outputs,
%       MissingInputs ("error" | "skip")
%
%   Returns struct OUT:
%       EventId        the event's id
%       Outcome        "inserted", or "existing" when the record was sent before
%       OutputIds      string column, one per output: the row that now
%                      describes that file (its own new row, or the existing one)
%       Unchanged      logical column: the file was registered already
%       SkippedInputs  string column: input artifact ids left out (MissingInputs="skip")
%
%   See also CARASLABDB, ADDANALYSISEVENT, ADDARTIFACT, ADDEVENTINPUT,
%   CARASLABDB.JSONTEXT.

    arguments
        obj (1,1) CarasLabDB
        eventType (1,1) string {mustBeMember(eventType, ["analysis", "recording", "behavior"])}
        opts.EventId (1,1) string
        opts.Digest (1,1) string
        opts.OccurredAt (1,1) datetime
        opts.SubjectId (1,1) string = string(missing)
        opts.SessionId (1,1) string = string(missing)
        opts.Notes (1,1) string = string(missing)
        opts.Attributes = []
        opts.RecordedBy (1,1) string = string(missing)
        opts.RecordedAt (1,1) datetime = NaT
        opts.Detail (1,1) struct = struct()
        opts.Inputs struct = struct("artifact_id", {}, "role", {})
        opts.Outputs struct = struct("storage_root_id", {}, "relative_path", {}, "checksum", {})
        opts.MissingInputs (1,1) string {mustBeMember(opts.MissingInputs, ["error", "skip"])} = "error"
    end

    % ---- check everything before any statement is sent -------------------
    if ~obj.pIsProvided(opts.EventId)
        error("CarasLabDB:invalidValue", "EventId is required: the caller mints the event's id.");
    end
    eventId = obj.pCheckUuid(opts.EventId, "EventId");
    digest = lower(strip(opts.Digest));
    if ismissing(digest) || isempty(regexp(char(digest), '^[0-9a-f]{32,128}$', 'once'))
        error("CarasLabDB:invalidValue", ...
            "Digest must be 32 to 128 hexadecimal digits (got '%s').", opts.Digest);
    end
    local_requireZone(opts.OccurredAt, "OccurredAt");
    local_requireZone(opts.RecordedAt, "RecordedAt");

    detailColumns = local_detailColumns(eventType);
    local_onlyFields(opts.Detail, detailColumns, "Detail");
    detail = struct();
    for f = reshape(string(fieldnames(opts.Detail)), 1, [])
        v = opts.Detail.(char(f));
        local_requireZone(v, "Detail." + f);
        detail = obj.pSet(detail, f, v);
    end
    if eventType == "analysis" && isfield(detail, "status")
        obj.pCheckMember(detail.status, ["running", "succeeded", "failed"], "Detail.status");
    end

    inputs = cell(1, numel(opts.Inputs));
    local_onlyFields(opts.Inputs, ["artifact_id", "role"], "Inputs");
    for k = 1:numel(opts.Inputs)
        in = opts.Inputs(k);
        if ~isfield(in, "artifact_id") || ~obj.pIsProvided(string(in.artifact_id))
            error("CarasLabDB:invalidValue", "Inputs(%d) has no artifact_id.", k);
        end
        e = struct("artifact_id", obj.pCheckUuid(string(in.artifact_id), "Inputs.artifact_id"));
        if isfield(in, "role")
            e = obj.pSet(e, "role", string(in.role));
        end
        inputs{k} = e;
    end
    inputIds = strings(1, numel(inputs));
    for k = 1:numel(inputs)
        inputIds(k) = inputs{k}.artifact_id;
    end
    if numel(unique(inputIds)) < numel(inputIds)
        error("CarasLabDB:invalidValue", "Inputs names an artifact more than once.");
    end

    outputColumns = ["artifact_id", "storage_root_id", "relative_path", "checksum", ...
        "checksum_algo", "size_bytes", "role", "format", "subject_id", "session_id", "attributes"];
    local_onlyFields(opts.Outputs, outputColumns, "Outputs");
    outputs = cell(1, numel(opts.Outputs));
    where = strings(1, numel(opts.Outputs));
    for k = 1:numel(opts.Outputs)
        o = opts.Outputs(k);
        a = struct();
        for f = reshape(string(fieldnames(o)), 1, [])
            v = o.(char(f));
            if ischar(v)
                v = string(v);
            end
            a = obj.pSet(a, f, v);
        end
        for f = ["storage_root_id", "relative_path", "checksum"]
            if ~isfield(a, f)
                error("CarasLabDB:invalidValue", "Outputs(%d) has no %s.", k, f);
            end
        end
        if isfield(a, "artifact_id")
            a.artifact_id = obj.pCheckUuid(a.artifact_id, "Outputs.artifact_id");
        end
        if isfield(a, "checksum_algo")
            obj.pCheckMember(a.checksum_algo, ["sha256", "md5", "blake3"], "Outputs.checksum_algo");
        end
        a.checksum = lower(strip(a.checksum));      % as trg_artifact_normalize stores it
        outputs{k} = a;
        where(k) = string(a.storage_root_id) + ":" + a.relative_path;
    end
    if numel(unique(where)) < numel(where)
        error("CarasLabDB:invalidValue", "Outputs names one file (root and path) more than once.");
    end

    % The digest goes into the event's attributes, where step 1 of a later
    % send finds it.
    attrs = obj.pAddJsonMember(opts.Attributes, "client_digest", digest, false);

    fake = struct("EventId", eventId, "OccurredAt", opts.OccurredAt, ...
        "SubjectId", opts.SubjectId, "SessionId", opts.SessionId, "Notes", opts.Notes, ...
        "Attributes", [], "RecordedBy", opts.RecordedBy, "RecordedAt", opts.RecordedAt, ...
        "Supersedes", string(missing));
    base = obj.pEventBase(eventType, fake);

    out = obj.pTransact(@() obj.pRecordEventRows(eventType, base, detail, digest, attrs, ...
        inputs, outputs, opts.MissingInputs == "skip"));
end

% -------------------------------------------------------------------------
function cols = local_detailColumns(eventType)
%LOCAL_DETAILCOLUMNS The detail columns RECORDEVENT may write, per event type.
    switch eventType
        case "analysis"
            cols = ["pipeline_id", "pipeline_name", "code_version", "parameters", ...
                    "environment", "started_at", "finished_at", "status"];
        case "recording"
            cols = ["acquisition_system_code", "probe_id", "modality", "sample_rate_hz", ...
                    "n_channels", "duration_s", "stimulus_protocol", "hardware_config"];
        case "behavior"
            cols = ["task", "paradigm", "stage", "trials_completed", "performance", "reward"];
    end
end

function local_onlyFields(s, allowed, what)
%LOCAL_ONLYFIELDS Refuse a struct field that is not one of ALLOWED.
    bad = setdiff(reshape(string(fieldnames(s)), 1, []), allowed);
    if ~isempty(bad)
        error("CarasLabDB:invalidValue", "%s cannot set %s (allowed: %s).", ...
            what, strjoin(bad, ", "), strjoin(allowed, ", "));
    end
end

function local_requireZone(v, what)
%LOCAL_REQUIREZONE Refuse an unzoned datetime (NaT is "not given" and passes).
    if isdatetime(v) && isscalar(v) && ~isnat(v) && isempty(v.TimeZone)
        error("CarasLabDB:unzonedTime", ...
            "%s has no time zone. Give the zone it was read in, e.g. " + ...
            "datetime(..., ""TimeZone"", ""America/New_York"").", what);
    end
end
