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
%       SubjectId, SessionId, Notes, Attributes, RecordedBy, RecordedAt, Supersedes
%   Histology-specific Name=Value:
%       Technique, TargetRegion, Stain, Microscope
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

    eventId = obj.pInsertEvent(base, obj.pT("histology_event"), detail);
end
