function eventId = addBehaviorEvent(obj, opts)
%ADDBEHAVIOREVENT Insert a behavior/training event (base + ephys.behavior_event).
%
%   eventId = addBehaviorEvent(db, OccurredAt=t, SubjectId="G-0421", ...
%                   Task="2AFC", Stage="shaping", TrialsCompleted=240, ...
%                   Performance=0.78)
%
%   Required:
%       OccurredAt   - datetime the session occurred (timestamptz)
%   Common event Name=Value:
%       SubjectId, SessionId, Notes, Attributes, RecordedBy, RecordedAt, Supersedes
%   Behavior-specific Name=Value:
%       Task, Paradigm, Stage, TrialsCompleted, Performance, Reward
%
%   Returns the generated event_id (uuid string).
%
%   See also CARASLABDB.

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
        % --- behavior detail ---
        opts.Task (1,1) string = string(missing)
        opts.Paradigm (1,1) string = string(missing)
        opts.Stage (1,1) string = string(missing)
        opts.TrialsCompleted double {mustBeInteger, mustBeScalarOrEmpty} = []
        opts.Performance (1,1) double = NaN
        opts.Reward (1,1) string = string(missing)
    end

    base = obj.pEventBase("behavior", opts);

    detail = struct();
    detail = obj.pSet(detail, "task",             opts.Task);
    detail = obj.pSet(detail, "paradigm",         opts.Paradigm);
    detail = obj.pSet(detail, "stage",            opts.Stage);
    detail = obj.pSet(detail, "trials_completed", opts.TrialsCompleted);
    detail = obj.pSet(detail, "performance",      opts.Performance);
    detail = obj.pSet(detail, "reward",           opts.Reward);

    eventId = obj.pInsertEvent(base, obj.pT("behavior_event"), detail);
end
