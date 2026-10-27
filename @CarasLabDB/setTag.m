function [assignmentId, changed] = setTag(obj, kind, entityId, tag, opts)
%SETTAG Set the value of a single-valued namespace on a row ("stage is now X").
%
%   setTag(db, "artifact", aid, "stage:raw")
%   setTag(db, "artifact", aid, "stage:preprocessed")   % replaces stage:raw
%   [id, changed] = setTag(db, "subject", "G-0421", "cohort:a")
%
%   lab.fn_tag already replaces the current value when it adds a tag of a
%   mutable single-valued namespace, so ADDTAG can do the replace too. What
%   SETTAG adds is the meaning of "set":
%     * it only accepts a single-valued namespace (stage, qc, cohort,
%       condition, ...). Setting a tag of a multi-valued namespace (topic,
%       or a bare tag) would silently *add* a value instead of replacing
%       one, so it raises CarasLabDB:notSingleValued -- use ADDTAG/REMOVETAG;
%     * it is idempotent: when TAG is already the row's current value nothing
%       is written and CHANGED is false, where ADDTAG would raise the
%       database's "already has tag" error. Scripts can re-run safely.
%   Otherwise it writes through lab.fn_tag, so the namespace's policy still
%   applies: an immutable namespace (cohort) can be set once, and setting a
%   different value afterwards raises the database's error; a closed
%   namespace only accepts registered values (REGISTERTAG).
%
%   Name=Value:
%       Note      - free text stored on the assignment row
%       AppliedBy - person_id (default: the current person)
%
%   Returns the assignment_id of the row that makes TAG current (the
%   existing one when nothing changed) and whether anything was written.
%
%   See also CARASLABDB, ADDTAG, REMOVETAG, GETENTITYTAGS, GETTAGNAMESPACES.

    arguments
        obj (1,1) CarasLabDB
        kind (1,1) string {mustBeMember(kind, ["event", "artifact", "subject", "session", "project"])}
        entityId (1,1) string
        tag (1,1) string
        opts.Note (1,1) string = string(missing)
        opts.AppliedBy (1,1) string = string(missing)
    end

    [ns, ~] = CarasLabDB.parseTag(tag);
    tag = CarasLabDB.normalizeTag(tag);
    [~, pk] = obj.pTagEntity(kind);
    litNs = obj.sqlLiteral(ns);

    N = obj.pSelect("SELECT cardinality FROM " + obj.pT("tag_namespace") + ...
        " WHERE namespace = " + litNs + ";");
    if height(N) == 0
        error("CarasLabDB:tagNamespaceNotFound", "Tag namespace %s does not exist (tag %s).", ...
            ns, tag);
    end
    if CarasLabDB.pColText(N.cardinality(1)) ~= "single"
        error("CarasLabDB:notSingleValued", ...
            "setTag replaces the one current value of a single-valued namespace, " + ...
            "but namespace %s is multi-valued. Use addTag / removeTag for %s.", ns, tag);
    end

    C = obj.pSelect("SELECT assignment_id, tag FROM " + obj.pT("tag_current") + ...
        " WHERE entity_kind = " + obj.sqlLiteral(kind) + " AND " + pk + " = " + ...
        obj.sqlLiteral(entityId) + " AND namespace = " + litNs + " ORDER BY tag;");
    if height(C) > 0
        hit = find(CarasLabDB.pColText(C.tag) == tag, 1);
        if ~isempty(hit)
            assignmentId = double(C.assignment_id(hit));
            changed = false;
            return
        end
    end

    assignmentId = obj.pFnTag(kind, entityId, tag, "add", opts.Note, ...
        obj.pCreatedBy(opts.AppliedBy));
    changed = true;
end
