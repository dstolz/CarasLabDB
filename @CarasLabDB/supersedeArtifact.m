function newArtifactId = supersedeArtifact(obj, oldArtifactId, opts)
%SUPERSEDEARTIFACT Correct an artifact by inserting a superseding copy.
%
%   Like SUPERSEDEEVENT, but for lab.artifact. Reads the old row, carries
%   every column forward exactly as stored except artifact_id and created_at
%   (regenerated), applies your overrides, sets supersedes to the old id and
%   created_by to the current person, and inserts the new row.
%
%   newId = supersedeArtifact(db, oldArtifactId, ...
%               Overrides=struct("checksum","ff00...", "size_bytes",123))
%   newId = supersedeArtifact(db, oldArtifactId, ...
%               Overrides=struct("role","derived"))          % metadata only
%
%   Name=Value:
%       Overrides - struct of lab.artifact column -> new value
%
%   Override struct field names must be actual database column names. Any
%   column not overridden is carried forward from the superseded row.
%
%   A correction may keep the same file (storage_root_id, relative_path,
%   checksum) -- e.g. to fix role/format/session, or to re-point
%   produced_by_event_id at a corrected event, which SUPERSEDEEVENT does for
%   you. The database still rejects a second *active* row for one file, so
%   this cannot be used to register a file twice.
%
%   Returns the new artifact_id (uuid string).
%
%   See also CARASLABDB, ADDARTIFACT, SUPERSEDEEVENT.

    arguments
        obj (1,1) CarasLabDB
        oldArtifactId (1,1) string
        opts.Overrides (1,1) struct = struct()
    end

    if isfield(opts.Overrides, "supersedes")
        error("CarasLabDB:supersedesNotOverridable", ...
            "supersedes is set by this method and cannot be overridden.");
    end

    A = obj.pRowsAsText(obj.pT("artifact"), ...
        "r.artifact_id = " + obj.sqlLiteral(oldArtifactId), "artifact_id");
    if isempty(A)
        error("CarasLabDB:artifactNotFound", "No artifact with id %s.", oldArtifactId);
    end

    s = obj.pArtifactSuccessor(A{1});
    s = obj.pMergeOverrides(s, opts.Overrides);

    newArtifactId = obj.pInsertReturning(obj.pT("artifact"), s, "artifact_id");
end
