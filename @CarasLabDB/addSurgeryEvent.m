function eventId = addSurgeryEvent(obj, opts)
%ADDSURGERYEVENT Insert a surgery event (base + lab.surgery_event).
%
%   eventId = addSurgeryEvent(db, OccurredAt=t, SubjectId="G-0421", ...
%                             Procedure="craniotomy", TargetRegion="IC", ...
%                             Hemisphere="R", StereotaxApMm=-4.2)
%
%   Required:
%       OccurredAt   - datetime the surgery occurred (timestamptz)
%   Common event Name=Value:
%       SubjectId, SessionId, Notes, Attributes, RecordedBy, RecordedAt, Supersedes
%   Surgery-specific Name=Value:
%       Procedure, SurgeonId, Anesthesia, TargetRegion,
%       Hemisphere ("L"|"R"|"bilateral"),
%       StereotaxApMm, StereotaxMlMm, StereotaxDvMm, ProbeId, Outcome
%
%   Returns the generated event_id (uuid string).
%
%   See also CARASLABDB, ADDRECORDINGEVENT.

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
        % --- surgery detail ---
        opts.Procedure (1,1) string = string(missing)
        opts.SurgeonId (1,1) string = string(missing)
        opts.Anesthesia (1,1) string = string(missing)
        opts.TargetRegion (1,1) string = string(missing)
        opts.Hemisphere (1,1) string = string(missing)
        opts.StereotaxApMm (1,1) double = NaN
        opts.StereotaxMlMm (1,1) double = NaN
        opts.StereotaxDvMm (1,1) double = NaN
        opts.ProbeId (1,1) string = string(missing)
        opts.Outcome (1,1) string = string(missing)
    end

    obj.pCheckMember(opts.Hemisphere, ["L", "R", "bilateral"], "Hemisphere");

    base = obj.pEventBase("surgery", opts);

    detail = struct();
    detail = obj.pSet(detail, "procedure",       opts.Procedure);
    detail = obj.pSet(detail, "surgeon_id",      opts.SurgeonId);
    detail = obj.pSet(detail, "anesthesia",      opts.Anesthesia);
    detail = obj.pSet(detail, "target_region",   opts.TargetRegion);
    detail = obj.pSet(detail, "hemisphere",      opts.Hemisphere);
    detail = obj.pSet(detail, "stereotax_ap_mm", opts.StereotaxApMm);
    detail = obj.pSet(detail, "stereotax_ml_mm", opts.StereotaxMlMm);
    detail = obj.pSet(detail, "stereotax_dv_mm", opts.StereotaxDvMm);
    detail = obj.pSet(detail, "probe_id",        opts.ProbeId);
    detail = obj.pSet(detail, "outcome",         opts.Outcome);

    eventId = obj.pInsertEvent(base, obj.pT("surgery_event"), detail);
end
