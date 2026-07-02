function eventId = addEndpointEvent(obj, opts)
%ADDENDPOINTEVENT Insert an endpoint/euthanasia event (base + ephys.endpoint_event).
%
%   eventId = addEndpointEvent(db, OccurredAt=t, SubjectId="G-0421", ...
%                   Method="perfusion", PerfusionFixative="4% PFA", ...
%                   TissueCollected=true)
%
%   Required:
%       OccurredAt   - datetime the endpoint occurred (timestamptz)
%   Common event Name=Value:
%       SubjectId, SessionId, Notes, Attributes, RecordedBy, RecordedAt, Supersedes
%   Endpoint-specific Name=Value:
%       Method, PerfusionFixative, TissueCollected (logical), Disposition
%
%   Returns the generated event_id (uuid string).
%
%   See also CARASLABDB, ADDHISTOLOGYEVENT.

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
        % --- endpoint detail ---
        opts.Method (1,1) string = string(missing)
        opts.PerfusionFixative (1,1) string = string(missing)
        opts.TissueCollected {mustBeScalarOrEmpty, mustBeNumericOrLogical} = logical.empty
        opts.Disposition (1,1) string = string(missing)
    end

    base = obj.pEventBase("endpoint", opts);

    detail = struct();
    detail = obj.pSet(detail, "method",             opts.Method);
    detail = obj.pSet(detail, "perfusion_fixative", opts.PerfusionFixative);
    if obj.pIsProvided(opts.TissueCollected)
        detail.tissue_collected = logical(opts.TissueCollected);
    end
    detail = obj.pSet(detail, "disposition",        opts.Disposition);

    eventId = obj.pInsertEvent(base, obj.pT("endpoint_event"), detail);
end
