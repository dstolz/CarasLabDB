function T = getEntityTags(obj, kind, entityId, opts)
%GETENTITYTAGS The tags of one event, artifact, subject, session or project.
%
%   T = getEntityTags(db, "artifact", aid)                 % current tags
%   H = getEntityTags(db, "artifact", aid, History=true)   % the full log
%
%   History=false (default) reads lab.tag_current: one row per tag the entity
%   carries now, ordered by tag, with columns tag, display_tag (a bare tag
%   without its 'tag:' prefix), namespace, value, applied_at, applied_by,
%   note, assignment_id.
%
%   History=true reads the lab.tag_assignment log: every 'add' and 'remove'
%   ever written for the entity, oldest first, with columns assignment_id,
%   tag, display_tag, op, applied_at, applied_by, note.
%
%   See also CARASLABDB, ADDTAG, SETTAG, REMOVETAG, FINDBYTAGS.

    arguments
        obj (1,1) CarasLabDB
        kind (1,1) string {mustBeMember(kind, ["event", "artifact", "subject", "session", "project"])}
        entityId (1,1) string
        opts.History (1,1) logical = false
    end

    [~, pk] = obj.pTagEntity(kind);
    where = " WHERE x.entity_kind = " + obj.sqlLiteral(kind) + ...
        " AND x." + pk + " = " + obj.sqlLiteral(entityId);

    if opts.History
        sql = "SELECT x.assignment_id, x.tag, " + ...
            "CASE WHEN t.namespace = 'tag' THEN t.value ELSE t.tag END AS display_tag, " + ...
            "x.op, x.applied_at, x.applied_by, x.note FROM " + obj.pT("tag_assignment") + ...
            " x JOIN " + obj.pT("tag") + " t ON t.tag = x.tag" + where + ...
            " ORDER BY x.applied_at, x.assignment_id;";
    else
        sql = "SELECT x.tag, x.display_tag, x.namespace, x.value, x.applied_at, " + ...
            "x.applied_by, x.note, x.assignment_id FROM " + obj.pT("tag_current") + ...
            " x" + where + " ORDER BY x.tag;";
    end
    T = obj.pSelect(sql);
end
