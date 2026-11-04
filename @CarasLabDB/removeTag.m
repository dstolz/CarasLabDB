function assignmentId = removeTag(obj, entityKind, entityId, tag, opts)
%REMOVETAG Take a tag off an entity by appending a removal to the tag log.
%
%   id = removeTag(db, "artifact", artifactId, "qc:fail", Note="re-checked")
%
%   Nothing is deleted: lab.tag_assignment is append-only and the removal is
%   a new row, so GETENTITYTAGS(..., History=true) still shows when the tag
%   was applied and when it was taken off. A tag in an immutable namespace
%   cannot be removed, and removing a tag the entity does not currently carry
%   is an error.
%
%   Returns the assignment_id of the removal row.
%
%   See also CARASLABDB, ADDTAG, GETENTITYTAGS.

    arguments
        obj (1,1) CarasLabDB
        entityKind (1,1) string
        entityId (1,1) string
        tag (1,1) string
        opts.Note (1,1) string = string(missing)
        opts.AppliedBy (1,1) string = string(missing)
    end

    assignmentId = obj.pTag(entityKind, entityId, tag, "remove", opts.Note, opts.AppliedBy);
end
