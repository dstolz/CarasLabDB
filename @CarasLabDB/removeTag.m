function assignmentIds = removeTag(obj, kind, entityId, tags, opts)
%REMOVETAG Take one or more tags off an event, artifact, subject, session or project.
%
%   id = removeTag(db, "artifact", aid, "qc:fail", Note="re-checked: fine")
%
%   Writes a 'remove' row to the append-only assignment log through
%   lab.fn_tag(kind, id, tag, 'remove'); the earlier 'add' is kept as history
%   (see GETENTITYTAGS with History=true). The database refuses to remove a
%   tag the row does not currently carry, or any tag of an immutable
%   namespace (cohort, condition). Tags are normalised like ADDTAG's; several
%   are removed in one transaction: all or none.
%
%   Name=Value:
%       Note      - free text stored on each assignment row
%       AppliedBy - person_id (default: the current person)
%
%   Returns the assignment_id of each 'remove' row (double row vector).
%
%   See also CARASLABDB, ADDTAG, SETTAG, GETENTITYTAGS.

    arguments
        obj (1,1) CarasLabDB
        kind (1,1) string {mustBeMember(kind, ["event", "artifact", "subject", "session", "project"])}
        entityId (1,1) string
        tags string {mustBeNonempty}
        opts.Note (1,1) string = string(missing)
        opts.AppliedBy (1,1) string = string(missing)
    end

    assignmentIds = obj.pApplyTags(kind, entityId, tags, "remove", opts.Note, opts.AppliedBy);
end
