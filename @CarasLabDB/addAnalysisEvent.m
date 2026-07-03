function eventId = addAnalysisEvent(obj, opts)
%ADDANALYSISEVENT Insert an analysis run event (base + lab.analysis_event).
%
%   eventId = addAnalysisEvent(db, OccurredAt=t, SubjectId="G-0421", ...
%                   PipelineId=pid, PipelineName="kilosort4", ...
%                   CodeVersion="v4.0.1", Parameters=struct("Th",[9 3]), ...
%                   Status="succeeded", StartedAt=t0, FinishedAt=t1)
%
%   To wire inputs (which artifacts this run consumed) call ADDEVENTINPUT
%   after inserting; to register outputs call ADDARTIFACT with
%   ProducedByEventId set to the returned event_id.
%
%   Required:
%       OccurredAt   - datetime the run is logged against (timestamptz)
%   Common event Name=Value:
%       SubjectId, SessionId, Notes, Attributes, RecordedBy, RecordedAt, Supersedes
%   Analysis-specific Name=Value:
%       PipelineId, PipelineName, CodeVersion, Parameters (jsonb),
%       Environment (jsonb), StartedAt, FinishedAt,
%       Status ("running"|"succeeded"|"failed")
%
%   Returns the generated event_id (uuid string).
%
%   See also CARASLABDB, ADDARTIFACT, ADDEVENTINPUT, ARTIFACTLINEAGE.

    arguments
        obj (1,1) CarasLabDB
        % --- base event ---
        opts.OccurredAt (1,1) datetime
        opts.SubjectId (1,1) string = string(missing)
        opts.SessionId (1,1) string = string(missing)
        opts.Notes (1,1) string = string(missing)
        opts.Attributes = []
        opts.RecordedBy (1,1) string = string(missing)
        opts.RecordedAt (1,1) datetime = NaT
        opts.Supersedes (1,1) string = string(missing)
        % --- analysis detail ---
        opts.PipelineId (1,1) string = string(missing)
        opts.PipelineName (1,1) string = string(missing)
        opts.CodeVersion (1,1) string = string(missing)
        opts.Parameters = []
        opts.Environment = []
        opts.StartedAt (1,1) datetime = NaT
        opts.FinishedAt (1,1) datetime = NaT
        opts.Status (1,1) string = string(missing)
    end

    obj.pCheckMember(opts.Status, ["running", "succeeded", "failed"], "Status");

    base = obj.pEventBase("analysis", opts);

    detail = struct();
    detail = obj.pSet(detail, "pipeline_id",   opts.PipelineId);
    detail = obj.pSet(detail, "pipeline_name", opts.PipelineName);
    detail = obj.pSet(detail, "code_version",  opts.CodeVersion);
    detail = obj.pSet(detail, "parameters",    opts.Parameters);
    detail = obj.pSet(detail, "environment",   opts.Environment);
    detail = obj.pSet(detail, "started_at",    opts.StartedAt);
    detail = obj.pSet(detail, "finished_at",   opts.FinishedAt);
    detail = obj.pSet(detail, "status",        opts.Status);

    eventId = obj.pInsertEvent(base, obj.pT("analysis_event"), detail);
end
