function ids = findByTags(obj, kind, opts)
%FINDBYTAGS Ids of every event, artifact, subject, session or project matching a tag filter.
%
%   ids = findByTags(db, "artifact", Tags="stage:raw")
%   ids = findByTags(db, "artifact", Tags=["stage:sorted", "cohort:a"], NotTags="qc:fail")
%   ids = findByTags(db, "session", AnyTags=["qc:*", "pilot"])
%
%   Wraps lab.fn_find_by_tags. A row matches when it currently carries every
%   tag in Tags=, at least one in AnyTags= (when given), and none in NotTags=.
%   Tokens are tags ("stage:raw"), bare tags ("pilot" = "tag:pilot") or
%   wildcards ("qc:*" = any qc tag); each is validated locally first. Untagged
%   rows are candidates too, so a NotTags=-only filter finds them, and a call
%   with no tokens at all returns every row of the kind.
%
%   ActiveOnly (default: UseActiveViews) skips superseded events and
%   artifacts, like the *_active views; it has no effect on other kinds.
%
%   Returns the ids as a string column vector in id order (strings(0,1) when
%   nothing matches). For the rows themselves, pass the same filter to the
%   getter: getArtifacts(Tags=..., NotTags=...).
%
%   See also CARASLABDB, GETARTIFACTS, GETEVENTS, GETENTITYTAGS, ADDTAG.

    arguments
        obj (1,1) CarasLabDB
        kind (1,1) string {mustBeMember(kind, ["event", "artifact", "subject", "session", "project"])}
        opts.Tags string = strings(1, 0)
        opts.AnyTags string = strings(1, 0)
        opts.NotTags string = strings(1, 0)
        opts.ActiveOnly (1,1) logical = obj.UseActiveViews
    end

    sql = "SELECT entity_id FROM " + obj.pT("fn_find_by_tags") + "(" + ...
        obj.sqlLiteral(kind) + ", " + ...
        obj.pTagArrayLiteral(opts.Tags) + ", " + ...
        obj.pTagArrayLiteral(opts.AnyTags) + ", " + ...
        obj.pTagArrayLiteral(opts.NotTags) + ", " + ...
        obj.sqlLiteral(opts.ActiveOnly) + ") ORDER BY entity_id;";
    R = obj.pSelect(sql);
    if height(R) == 0
        ids = strings(0, 1);
    else
        ids = CarasLabDB.pColText(R.entity_id);
    end
end
