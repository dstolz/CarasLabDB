function eventId = addHistologyEvent(obj, opts)
%ADDHISTOLOGYEVENT Insert a histology event (base + lab.histology_event).
%
%   eventId = addHistologyEvent(db, OccurredAt=t, SubjectId="G-0421", ...
%                   Technique="immunostain", TargetRegion="IC", ...
%                   Stain="DAPI", Microscope="confocal")
%
%   Required:
%       OccurredAt   - datetime the histology was performed (timestamptz)
%   Common event Name=Value:
%       SubjectId, SessionId, Notes, Attributes, RecordedBy, RecordedAt, Supersedes,
%       CarryInputs (with Supersedes=; see below)
%   Histology-specific Name=Value:
%       Technique, TargetRegion, Stain, Microscope
%
%   Supersedes=oldEventId makes this event a correction of that one. It then
%   takes over the old event's provenance in the same transaction, exactly as
%   SUPERSEDEEVENT does: the old event's input edges are copied to this
%   event (CarryInputs=false copies none -- declare the right ones with
%   ADDEVENTINPUT), every active artifact the old event produced is
%   re-pointed at this event and filed under its subject and session, and
%   the old event's current tags are carried forward.
%
%   Returns the generated event_id (uuid string).
%
%   See also CARASLABDB, ADDENDPOINTEVENT.

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
        opts.CarryInputs (1,1) logical = true
        % --- histology detail ---
        opts.Technique (1,1) string = string(missing)
        opts.TargetRegion (1,1) string = string(missing)
        opts.Stain (1,1) string = string(missing)
        opts.Microscope (1,1) string = string(missing)
    end

    base = obj.pEventBase("histology", opts);

    detail = struct();
    detail = obj.pSet(detail, "technique",     opts.Technique);
    detail = obj.pSet(detail, "target_region", opts.TargetRegion);
    detail = obj.pSet(detail, "stain",         opts.Stain);
    detail = obj.pSet(detail, "microscope",    opts.Microscope);

    eventId = obj.pInsertEvent(base, obj.pT("histology_event"), detail, ...
        CarryInputs=opts.CarryInputs);
end
