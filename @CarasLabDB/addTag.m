function assignmentId = addTag(obj, entityKind, entityId, tag, opts)
%ADDTAG Apply a tag to an event, artifact, subject, session or project.
%
%   id = addTag(db, "artifact", artifactId, "stage:raw")
%   id = addTag(db, "subject",  "G-0421",   "cohort:a")
%   id = addTag(db, "event",    eventId,    "auditory_cortex")   % bare tag
%   id = addTag(db, "artifact", artifactId, "stage:preprocessed", ...
%               Note="after CAR + bandpass")
%
%   Tags are "namespace:value", lower-case; the value is lower-cased and
%   trimmed on the way in and anything else malformed is rejected. A tag
%   with no namespace ("auditory_cortex") belongs to the reserved "tag"
%   namespace. The namespace's policy (see ADDTAGNAMESPACE) decides what
%   happens:
%     * single-valued and mutable (e.g. stage): adding "stage:preprocessed"
%       to a file that carries "stage:raw" records the removal of the old
%       value and then the addition -- one call, two rows in the log;
%     * single-valued and immutable (e.g. cohort): a second value is an
%       error; the first one is permanent;
%     * multi-valued: the tag is added alongside the others;
%     * open vocabulary: a value never seen before is registered on first
%       use; closed vocabulary: it must have been registered with REGISTERTAG.
%   Adding a tag the entity already carries writes nothing.
%
%   Every call goes through lab.fn_tag, so the same rules apply to any other
%   client. Returns the assignment_id of the log row (or of the row that
%   already made the tag current).
%
%   See also CARASLABDB, REMOVETAG, GETENTITYTAGS, FINDBYTAGS, REGISTERTAG.

    arguments
        obj (1,1) CarasLabDB
        entityKind (1,1) string
        entityId (1,1) string
        tag (1,1) string
        opts.Note (1,1) string = string(missing)
        opts.AppliedBy (1,1) string = string(missing)
    end

    assignmentId = obj.pTag(entityKind, entityId, tag, "add", opts.Note, opts.AppliedBy);
end
