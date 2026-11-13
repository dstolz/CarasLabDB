function eventId = addBirthEvent(obj, opts)
%ADDBIRTHEVENT Insert a birth event (base + lab.birth_event) in one transaction.
%
%   eventId = addBirthEvent(db, OccurredAt=t, SubjectId="G-0421", ...)
%
%   Required:
%       OccurredAt   - datetime the birth occurred (timestamptz)
%   Common event Name=Value:
%       SubjectId, SessionId, Notes, Attributes (jsonb),
%       RecordedBy, RecordedAt, Supersedes,
%       CarryInputs (with Supersedes=; see below)
%   Birth-specific Name=Value:
%       DamSubjectId, SireSubjectId, LitterId, BirthWeightG
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
%   See also CARASLABDB, ADDSUBJECT.

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
        % --- birth detail ---
        opts.DamSubjectId (1,1) string = string(missing)
        opts.SireSubjectId (1,1) string = string(missing)
        opts.LitterId (1,1) string = string(missing)
        opts.BirthWeightG (1,1) double = NaN
    end

    base = obj.pEventBase("birth", opts);

    detail = struct();
    detail = obj.pSet(detail, "dam_subject_id",  opts.DamSubjectId);
    detail = obj.pSet(detail, "sire_subject_id", opts.SireSubjectId);
    detail = obj.pSet(detail, "litter_id",       opts.LitterId);
    detail = obj.pSet(detail, "birth_weight_g",  opts.BirthWeightG);

    eventId = obj.pInsertEvent(base, obj.pT("birth_event"), detail, ...
        CarryInputs=opts.CarryInputs);
end
