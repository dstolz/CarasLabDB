function T = getEntityTags(obj, entityKind, entityId, opts)
%GETENTITYTAGS The tags an event, artifact, subject, session or project carries.
%
%   T = getEntityTags(db, "artifact", artifactId)
%   T = getEntityTags(db, "subject", "G-0421", History=true)
%
%   By default returns the entity's *current* tags (lab.tag_current): one row
%   per tag with tag, namespace, value, display_tag (the tag as written, i.e.
%   without the reserved "tag:" prefix), note, applied_at and applied_by.
%   With History=true returns every lab.tag_assignment row for the entity in
%   log order -- each add and remove, with who and when -- so the full
%   history of a tag that changed over time (stage:raw -> stage:sorted) is
%   visible.
%
%   See also CARASLABDB, ADDTAG, REMOVETAG, FINDBYTAGS.

    arguments
        obj (1,1) CarasLabDB
        entityKind (1,1) string
        entityId (1,1) string
        opts.History (1,1) logical = false
    end

    ent = CarasLabDB.pTagEntity(entityKind);
    if opts.History
        T = obj.pSelectFrom(obj.pT("tag_assignment"), struct(), ...
            OrderBy="assignment_id", ...
            Where=["entity_kind = " + obj.sqlLiteral(ent.Kind), ...
                   ent.PK + " = " + obj.sqlLiteral(entityId)]);
    else
        T = obj.pSelectFrom(obj.pT("tag_current"), struct(), ...
            OrderBy="tag", ...
            Where=["entity_kind = " + obj.sqlLiteral(ent.Kind), ...
                   "entity_id = " + obj.sqlLiteral(entityId)]);
    end
end
