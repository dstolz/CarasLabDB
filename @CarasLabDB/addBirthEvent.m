function eventId = addBirthEvent(obj, opts)
%ADDBIRTHEVENT Insert a birth event (base + lab.birth_event) in one transaction.
%
%   eventId = addBirthEvent(db, OccurredAt=t, SubjectId="G-0421", ...)
%
%   Required:
%       OccurredAt   - datetime the birth occurred (timestamptz)
%   Common event Name=Value:
%       SubjectId, SessionId, Notes, Attributes (jsonb),
%       RecordedBy, RecordedAt, Supersedes
%   Birth-specific Name=Value:
%       DamSubjectId, SireSubjectId, LitterId, BirthWeightG
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

    eventId = obj.pInsertEvent(base, obj.pT("birth_event"), detail);
end
