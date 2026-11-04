function ids = findByTags(obj, entityKind, opts)
%FINDBYTAGS Ids of the entities of one kind whose current tags match a filter.
%
%   ids = findByTags(db, "artifact", Tags=["stage:raw", "qc:pass"])
%   ids = findByTags(db, "subject",  Tags="cohort:*", NotTags="auditory_cortex")
%   ids = findByTags(db, "event",    AnyTags=["qc:fail", "qc:pending"])
%
%   Name=Value (string arrays of tag patterns; each may be omitted):
%       Tags    - every pattern must match (all of)
%       AnyTags - at least one pattern must match (any of)
%       NotTags - no pattern may match (none of)
%   A pattern is a tag ("stage:raw", or a bare "auditory_cortex" for the
%   reserved namespace) matched exactly, or "namespace:*", which matches any
%   current tag of that namespace. Input is lower-cased and trimmed.
%
%   Only entities that carry at least one tag are considered, so a filter of
%   NotTags alone does not return untagged entities; use the Tags=/AnyTags=/
%   NotTags= arguments of GETEVENTS, GETARTIFACTS, GETSUBJECTS, GETSESSIONS
%   and GETPROJECTS for that, which apply the same filter to the whole table.
%
%   Returns a string column of ids (event_id / artifact_id / subject_id /
%   session_id / project_id as text).
%
%   See also CARASLABDB, GETENTITYTAGS, ADDTAG, GETARTIFACTS.

    arguments
        obj (1,1) CarasLabDB
        entityKind (1,1) string
        opts.Tags (1,:) string = strings(1, 0)
        opts.AnyTags (1,:) string = strings(1, 0)
        opts.NotTags (1,:) string = strings(1, 0)
    end

    ent = CarasLabDB.pTagEntity(entityKind);
    T = obj.pSelect("SELECT entity_id FROM " + obj.pT("fn_find_by_tags") + "(" + ...
        obj.sqlLiteral(ent.Kind) + ", " + ...
        CarasLabDB.pTagArrayLiteral(opts.Tags) + ", " + ...
        CarasLabDB.pTagArrayLiteral(opts.AnyTags) + ", " + ...
        CarasLabDB.pTagArrayLiteral(opts.NotTags) + ");");
    if height(T) == 0
        ids = strings(0, 1);
    else
        ids = CarasLabDB.pColText(T.entity_id);
    end
end
