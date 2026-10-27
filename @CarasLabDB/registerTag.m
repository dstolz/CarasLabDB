function tag = registerTag(obj, tag, opts)
%REGISTERTAG Add a tag to the vocabulary without putting it on anything.
%
%   t = registerTag(db, "stage:spike_sorted", Description="after Kilosort")
%   t = registerTag(db, "Auditory_Cortex")     % -> "tag:auditory_cortex"
%
%   The tag is normalised and validated first (CarasLabDB.normalizeTag). This
%   is the deliberate way to add a value to a namespace with a *closed*
%   vocabulary (e.g. stage, qc), where addTag/setTag refuse to create values
%   so that a typo is caught instead of becoming vocabulary. It works for open
%   namespaces too.
%
%   Registering a tag that already exists changes nothing (its description is
%   not overwritten) and returns it; if that tag is retired a
%   CarasLabDB:tagRetired warning says so (see RETIRETAG).
%
%   Name=Value:
%       Description, CreatedBy
%
%   Returns the canonical tag.
%
%   See also CARASLABDB, ADDTAGNAMESPACE, GETTAGS, RETIRETAG, ADDTAG.

    arguments
        obj (1,1) CarasLabDB
        tag (1,1) string
        opts.Description (1,1) string = string(missing)
        opts.CreatedBy (1,1) string = string(missing)
    end

    [ns, ~] = CarasLabDB.parseTag(tag);
    tag = CarasLabDB.normalizeTag(tag);

    N = obj.pSelect("SELECT 1 AS present FROM " + obj.pT("tag_namespace") + ...
        " WHERE namespace = " + obj.sqlLiteral(ns) + ";");
    if height(N) == 0
        error("CarasLabDB:tagNamespaceNotFound", ...
            "Tag namespace %s does not exist (tag %s). Create it with " + ...
            "addTagNamespace, or write the tag without a colon to use the " + ...
            "default 'tag' namespace.", ns, tag);
    end

    s = struct("tag", tag);
    s = obj.pSet(s, "description", opts.Description);
    s = obj.pSet(s, "created_by",  obj.pCreatedBy(opts.CreatedBy));
    [cols, vals] = obj.pColsVals(s);
    R = obj.pSelect("INSERT INTO " + obj.pT("tag") + " (" + strjoin(cols, ", ") + ...
        ") VALUES (" + strjoin(vals, ", ") + ") ON CONFLICT (tag) DO NOTHING RETURNING tag;");
    if height(R) == 0
        E = obj.pSelect("SELECT (retired_at IS NOT NULL) AS is_retired FROM " + ...
            obj.pT("tag") + " WHERE tag = " + obj.sqlLiteral(tag) + ";");
        if height(E) > 0 && logical(E.is_retired(1))
            warning("CarasLabDB:tagRetired", ...
                "Tag %s is already registered but retired, so it cannot be assigned. " + ...
                "Use retireTag(..., Unretire=true) to bring it back.", tag);
        end
    end
end
