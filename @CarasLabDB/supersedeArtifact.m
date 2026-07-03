function newArtifactId = supersedeArtifact(obj, oldArtifactId, opts)
%SUPERSEDEARTIFACT Correct an artifact by inserting a superseding copy.
%
%   Like SUPERSEDEEVENT, but for lab.artifact. Reads the old row, carries
%   every column forward except artifact_id and created_at (regenerated),
%   applies your overrides, sets supersedes to the old id and created_by to
%   the current person, and inserts the new row.
%
%   newId = supersedeArtifact(db, oldArtifactId, ...
%               Overrides=struct("checksum","ff00...", "size_bytes",123))
%
%   Name=Value:
%       Overrides - struct of lab.artifact column -> new value
%
%   Override struct field names must be actual database column names. Any
%   column not overridden is carried forward from the superseded row.
%
%   Returns the new artifact_id (uuid string).
%
%   See also CARASLABDB, ADDARTIFACT, SUPERSEDEEVENT.

    arguments
        obj (1,1) CarasLabDB
        oldArtifactId (1,1) string
        opts.Overrides (1,1) struct = struct()
    end

    A = obj.pSelect("SELECT * FROM " + obj.pT("artifact") + " WHERE artifact_id = " + ...
        obj.sqlLiteral(oldArtifactId) + ";");
    if height(A) == 0
        error("CarasLabDB:artifactNotFound", "No artifact with id %s.", oldArtifactId);
    end

    s = struct();
    cols = string(A.Properties.VariableNames);
    for i = 1:numel(cols)
        c = cols(i);
        if ismember(c, ["artifact_id", "created_at", "created_by", "supersedes"])
            continue    % regenerated / set explicitly below
        end
        s = obj.pSet(s, c, local_scalar(A.(c)));
    end
    s = obj.pMergeOverrides(s, opts.Overrides);
    s.supersedes = oldArtifactId;
    s = obj.pSet(s, "created_by", obj.pCreatedBy(string(missing)));

    newArtifactId = obj.pInsertReturning(obj.pT("artifact"), s, "artifact_id");
end

function v = local_scalar(colvals)
%LOCAL_SCALAR Extract row-1 of a fetched table column as an insertable scalar.
    if isempty(colvals)
        v = string(missing);
        return
    end
    if iscell(colvals)
        v = colvals{1};
    else
        v = colvals(1);
    end
    if ischar(v)
        if isempty(v)
            v = string(missing);
        else
            v = string(v);
        end
    end
end
