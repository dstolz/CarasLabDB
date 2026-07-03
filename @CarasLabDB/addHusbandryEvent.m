function eventId = addHusbandryEvent(obj, opts)
%ADDHUSBANDRYEVENT Insert a husbandry/health event (base + lab.husbandry_event).
%
%   eventId = addHusbandryEvent(db, OccurredAt=t, SubjectId="G-0421", ...
%                   Measure="weight", WeightG=72.4)
%
%   Required:
%       OccurredAt   - datetime the measurement/check occurred (timestamptz)
%       Measure      - what was measured ('weight','health_check',
%                      'water_restriction', ...); NOT NULL in the schema
%   Common event Name=Value:
%       SubjectId, SessionId, Notes, Attributes, RecordedBy, RecordedAt, Supersedes
%   Husbandry-specific Name=Value:
%       WeightG, WaterMl, HealthStatus
%
%   Returns the generated event_id (uuid string).
%
%   See also CARASLABDB, GETSUBJECTCURRENT.

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
        % --- husbandry detail ---
        opts.Measure (1,1) string
        opts.WeightG (1,1) double = NaN
        opts.WaterMl (1,1) double = NaN
        opts.HealthStatus (1,1) string = string(missing)
    end

    base = obj.pEventBase("husbandry", opts);

    detail = struct("measure", opts.Measure);
    detail = obj.pSet(detail, "weight_g",      opts.WeightG);
    detail = obj.pSet(detail, "water_ml",      opts.WaterMl);
    detail = obj.pSet(detail, "health_status", opts.HealthStatus);

    eventId = obj.pInsertEvent(base, obj.pT("husbandry_event"), detail);
end
