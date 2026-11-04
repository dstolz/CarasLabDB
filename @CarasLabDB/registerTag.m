function tag = registerTag(obj, tag, opts)
%REGISTERTAG Register a tag value without applying it to anything.
%
%   tag = registerTag(db, "stage:archived", Description="Moved to cold storage")
%   tag = registerTag(db, "auditory_cortex")        % -> "tag:auditory_cortex"
%
%   This is the deliberate way to add a value to a namespace: it works in a
%   closed-vocabulary namespace too (ADDTAG only auto-registers values in
%   open namespaces). The tag is lower-cased and trimmed; a tag with no
%   namespace goes into the reserved "tag" namespace. Anything else malformed
%   is rejected. Registering a tag that already exists is a no-op.
%
%   Returns the canonical tag string.
%
%   See also CARASLABDB, ADDTAG, RETIRETAG, GETTAGS, ADDTAGNAMESPACE.

    arguments
        obj (1,1) CarasLabDB
        tag (1,1) string
        opts.Description (1,1) string = string(missing)
        opts.CreatedBy (1,1) string = string(missing)
    end

    canonical = CarasLabDB.normalizeTag(tag);
    T = obj.pSelect("SELECT " + obj.pT("fn_register_tag") + "(" + ...
        obj.sqlLiteral(canonical) + ", " + obj.sqlLiteral(opts.Description) + ", " + ...
        obj.sqlLiteral(obj.pCreatedBy(opts.CreatedBy)) + ") AS tag;");
    tag = string(T.tag(1));
end
