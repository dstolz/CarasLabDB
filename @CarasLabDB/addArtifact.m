function artifactId = addArtifact(obj, opts)
%ADDARTIFACT Register a file artifact produced by an event.
%
%   artifactId = addArtifact(db, ProducedByEventId=eid, StorageRootId=1, ...
%                   RelativePath="G-0421/sess/raw.dat", Checksum="ab12...", ...
%                   Role="raw", Format="dat", SizeBytes=1.2e10)
%
%   Required:
%       ProducedByEventId - event that produced this artifact (uuid)
%       StorageRootId     - storage_root.root_id the path is relative to
%       RelativePath      - path under the storage root
%       Checksum          - content checksum
%   Optional Name=Value:
%       ChecksumAlgo ("sha256"|"md5"|"blake3"; default sha256 in DB),
%       SizeBytes, Role (artifact_role.code), Format, SubjectId, SessionId,
%       Supersedes, Attributes (jsonb), CreatedBy
%
%   Returns the generated artifact_id (uuid string).
%
%   See also CARASLABDB, ADDEVENTINPUT, SUPERSEDEARTIFACT, ARTIFACTLINEAGE.

    arguments
        obj (1,1) CarasLabDB
        opts.ProducedByEventId (1,1) string
        opts.StorageRootId (1,1) double {mustBeInteger}
        opts.RelativePath (1,1) string
        opts.Checksum (1,1) string
        opts.ChecksumAlgo (1,1) string = string(missing)
        opts.SizeBytes (1,1) double = NaN
        opts.Role (1,1) string = string(missing)
        opts.Format (1,1) string = string(missing)
        opts.SubjectId (1,1) string = string(missing)
        opts.SessionId (1,1) string = string(missing)
        opts.Supersedes (1,1) string = string(missing)
        opts.Attributes = []
        opts.CreatedBy (1,1) string = string(missing)
    end

    obj.pCheckMember(opts.ChecksumAlgo, ["sha256", "md5", "blake3"], "ChecksumAlgo");

    s = struct( ...
        "produced_by_event_id", opts.ProducedByEventId, ...
        "storage_root_id",      opts.StorageRootId, ...
        "relative_path",        opts.RelativePath, ...
        "checksum",             opts.Checksum);
    s = obj.pSet(s, "checksum_algo", opts.ChecksumAlgo);
    s = obj.pSet(s, "size_bytes",    opts.SizeBytes);
    s = obj.pSet(s, "role",          opts.Role);
    s = obj.pSet(s, "format",        opts.Format);
    s = obj.pSet(s, "subject_id",    opts.SubjectId);
    s = obj.pSet(s, "session_id",    opts.SessionId);
    s = obj.pSet(s, "supersedes",    opts.Supersedes);
    s = obj.pSet(s, "attributes",    opts.Attributes);
    s = obj.pSet(s, "created_by",    obj.pCreatedBy(opts.CreatedBy));

    artifactId = obj.pInsertReturning(obj.pT("artifact"), s, "artifact_id");
end
