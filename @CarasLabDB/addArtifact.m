function artifactId = addArtifact(obj, opts)
%ADDARTIFACT Register a file artifact produced by an event.
%
%   artifactId = addArtifact(db, ProducedByEventId=eid, StorageRootId=1, ...
%                   RelativePath="G-0421/sess/raw.dat", ...
%                   Checksum="96856fa7376e06ee8614e194b4ca38a6" + ...
%                              "372e1f7a32861a99b0ab10e680391bd7", ...
%                   Role="raw", Format="dat", SizeBytes=1.2e10)
%
%   Required:
%       ProducedByEventId - event that produced this artifact (uuid)
%       StorageRootId     - storage_root.root_id the path is relative to
%       RelativePath      - path under the storage root. Must be genuinely
%                           relative and use forward slashes: the database
%                           rejects absolute paths, drive letters, backslashes
%                           and '..' segments, so that one stored path resolves
%                           on every machine that mounts the NAS.
%       Checksum          - content checksum, as hex of the exact width the
%                           algorithm produces (sha256/blake3 = 64 chars,
%                           md5 = 32). Case is normalised to lower on insert.
%                           The database rejects anything else, so a truncated
%                           or placeholder value fails fast here rather than
%                           making every later integrity check report a
%                           mismatch it cannot explain.
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
