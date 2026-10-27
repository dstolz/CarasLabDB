function assignmentIds = addTag(obj, kind, entityId, tags, opts)
%ADDTAG Put one or more tags on an event, artifact, subject, session or project.
%
%   id  = addTag(db, "artifact", aid, "topic:tonotopy")
%   ids = addTag(db, "subject", "G-0421", ["cohort:a", "auditory_cortex"], ...
%                Note="assigned at weaning")
%
%   KIND is "event", "artifact", "subject", "session" or "project" and
%   ENTITYID that row's id (uuid, or the subject_id). Each tag is normalised
%   and validated locally (CarasLabDB.normalizeTag: lower case, trimmed, a
%   bare tag goes to the 'tag' namespace), duplicates in TAGS are dropped,
%   and each is written with lab.fn_tag(kind, id, tag, 'add'), so the
%   database applies the namespace's policy:
%     * a new value of an open namespace is registered on first use; a
%       closed namespace (stage, qc) only accepts registered values -- see
%       REGISTERTAG;
%     * in a mutable single-valued namespace the new tag replaces the current
%       one (the 'remove' and 'add' are two log rows of one call);
%     * a tag already current on the row, a second value of an immutable
%       single-valued namespace, a retired tag, or a kind outside the
%       namespace's applies_to raise the database's error.
%   Several tags are written in one transaction: all or none.
%
%   Name=Value:
%       Note      - free text stored on each assignment row
%       AppliedBy - person_id (default: the current person)
%
%   Returns the assignment_id of each tag's 'add' row (double row vector).
%
%   See also CARASLABDB, SETTAG, REMOVETAG, GETENTITYTAGS, FINDBYTAGS.

    arguments
        obj (1,1) CarasLabDB
        kind (1,1) string {mustBeMember(kind, ["event", "artifact", "subject", "session", "project"])}
        entityId (1,1) string
        tags string {mustBeNonempty}
        opts.Note (1,1) string = string(missing)
        opts.AppliedBy (1,1) string = string(missing)
    end

    assignmentIds = obj.pApplyTags(kind, entityId, tags, "add", opts.Note, opts.AppliedBy);
end
