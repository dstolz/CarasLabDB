function out = recordArtifactMove(obj, artifactId, opts)
%RECORDARTIFACTMOVE Record that an artifact's file is now at another path, with the same bytes.
%
%   out = recordArtifactMove(db, aid, StorageRootId=1, ...
%             RelativePath="G-0421/archive/raw.dat", OccurredAt=t)
%   out = recordArtifactMove(db, aid, StorageRootId=1, ...
%             RelativePath="G-0421/archive/raw.dat", OccurredAt=t, ...
%             ObservedChecksum=hex, VerifiedAt=tHashed, Note="found by its checksum")
%
%   A file that has moved is not corrected (its row is a true record of what
%   was produced, and the analyses that read it go on pointing at it) and not
%   retracted: its file is recorded as 'moved' in lab.artifact_disposition,
%   which names the row of the same bytes at the new path. This method
%   writes all of that in one transaction, so nothing is half recorded:
%
%     1. The row of the file at its new path. An active row that already
%        describes it there (same storage root, path and checksum) is used,
%        if its file is present. Otherwise a new artifact row is
%        registered, its columns copied exactly as stored from the row of
%        ARTIFACTID: produced_by_event_id, checksum, checksum_algo,
%        size_bytes, role, format, subject_id, session_id and attributes;
%        created_by is the current person. The new row does not supersede
%        the old one, and it does not get the old row's tags or variables.
%     2. With ObservedChecksum=: one lab.artifact_verification row with
%        status 'ok' for the row of step 1, observed_checksum
%        ObservedChecksum and verified_at VerifiedAt -- the check the
%        caller made of the bytes at the new path. ObservedChecksum must be
%        the old row's checksum (compared ignoring case and surrounding
%        spaces); any other value raises CarasLabDB:checksumMismatch and
%        nothing is written.
%     3. A 'moved' disposition of ARTIFACTID's file, successor the row of
%        step 1, occurred_at OccurredAt, with Note.
%
%   The old row stays active and leaves lab.artifact_present; the integrity
%   checks and tools/verify_artifacts.py then look for the file at its new
%   path only. The database refuses the move (and so the whole transaction)
%   when the old file is already recorded as replaced, moved or deleted.
%
%   Required:
%       ARTIFACTID     - the active artifact row whose file moved
%       StorageRootId  - storage_root.root_id of the new place
%       RelativePath   - path below that root, '/' separators, as addArtifact
%                        takes it; it must differ from the old path
%       OccurredAt     - when the file moved (datetime; zoned preferred)
%   Optional Name=Value:
%       ObservedChecksum - the checksum the caller computed of the file at
%                          its new path (hex, the old row's algorithm)
%       VerifiedAt       - when it was computed; required with ObservedChecksum
%       Note             - free text on the disposition
%
%   Returns a struct with the fields
%       SuccessorArtifactId  the row of the file at its new path
%       Registered           true when step 1 inserted that row
%       VerificationId       the verification row of step 2 (NaN: none)
%       DispositionId        the disposition row of step 3
%
%   Errors (nothing is written): CarasLabDB:artifactNotFound (ARTIFACTID is
%   not an active row), CarasLabDB:invalidValue (the new path is the old
%   one, or VerifiedAt is missing), CarasLabDB:checksumMismatch,
%   CarasLabDB:fileRecordedGone (an active row describes these bytes at the
%   new path, but its file is recorded as gone: record it 'restored' first).
%
%   See also CARASLABDB, ADDARTIFACTDISPOSITION, ADDARTIFACT,
%   ADDARTIFACTVERIFICATION, GETARTIFACTDISPOSITIONS.

    arguments
        obj (1,1) CarasLabDB
        artifactId (1,1) string
        opts.StorageRootId (1,1) double {mustBeInteger}
        opts.RelativePath (1,1) string
        opts.OccurredAt (1,1) datetime
        opts.ObservedChecksum (1,1) string = string(missing)
        opts.VerifiedAt (1,1) datetime = NaT
        opts.Note (1,1) string = string(missing)
    end

    artifactId = CarasLabDB.pCheckUuid(artifactId, "artifactId");
    if ismissing(artifactId)
        error("CarasLabDB:invalidValue", "artifactId is required.");
    end
    if ismissing(opts.RelativePath) || strlength(strtrim(opts.RelativePath)) == 0
        error("CarasLabDB:invalidValue", "RelativePath is required.");
    end
    if isnat(opts.OccurredAt)
        error("CarasLabDB:invalidValue", "OccurredAt is required: when the file moved.");
    end
    checked = obj.pIsProvided(opts.ObservedChecksum);
    if checked && isnat(opts.VerifiedAt)
        error("CarasLabDB:invalidValue", ...
            "VerifiedAt is required with ObservedChecksum: when the checksum was computed.");
    end
    if ~checked && ~isnat(opts.VerifiedAt)
        error("CarasLabDB:invalidValue", ...
            "VerifiedAt is only recorded with ObservedChecksum: give the checksum computed.");
    end

    out = obj.pTransact(@() local_write(obj, artifactId, opts, checked));
end

% -------------------------------------------------------------------------
function out = local_write(obj, artifactId, opts, checked)
%LOCAL_WRITE The writes of RECORDARTIFACTMOVE. Runs inside PTRANSACT.
    rows = obj.pRowsAsText(obj.pT("artifact_active"), ...
        "r.artifact_id = " + obj.sqlLiteral(artifactId) + "::uuid", "artifact_id");
    if isempty(rows)
        error("CarasLabDB:artifactNotFound", ...
            "No active artifact with id %s: a move is recorded against the current row.", ...
            artifactId);
    end
    old = rows{1};

    if double(old.storage_root_id) == opts.StorageRootId ...
            && old.relative_path == opts.RelativePath
        error("CarasLabDB:invalidValue", ...
            "%s is the path artifact %s already has: a move is to another path.", ...
            opts.RelativePath, artifactId);
    end
    observed = string(missing);
    if checked
        observed = lower(strtrim(opts.ObservedChecksum));
        if observed ~= old.checksum
            error("CarasLabDB:checksumMismatch", ...
                "The file at %s has checksum %s, not the %s of artifact %s: " + ...
                "it is not the same bytes, so it is not where that file moved.", ...
                opts.RelativePath, observed, old.checksum, artifactId);
        end
    end

    % 1. The row of the bytes at the new path: an active one, or a new one.
    there = obj.getArtifacts(StorageRootId=opts.StorageRootId, ...
        RelativePath=opts.RelativePath, Checksum=old.checksum, ActiveOnly=true);
    out = struct("SuccessorArtifactId", string(missing), "Registered", false, ...
        "VerificationId", NaN, "DispositionId", NaN);
    if height(there) > 0
        ids = CarasLabDB.pColText(there.artifact_id);
        present = obj.getArtifacts(StorageRootId=opts.StorageRootId, ...
            RelativePath=opts.RelativePath, Checksum=old.checksum, PresentOnly=true);
        if height(present) == 0
            error("CarasLabDB:fileRecordedGone", ...
                "Artifact %s describes these bytes at %s, but its file is recorded as " + ...
                "replaced, moved or deleted. Record it 'restored' first, then the move.", ...
                ids(1), opts.RelativePath);
        end
        out.SuccessorArtifactId = CarasLabDB.pColText(present.artifact_id(1));
    else
        s = struct( ...
            "produced_by_event_id", old.produced_by_event_id, ...
            "storage_root_id",      opts.StorageRootId, ...
            "relative_path",        opts.RelativePath, ...
            "checksum",             old.checksum, ...
            "checksum_algo",        old.checksum_algo);
        for col = ["size_bytes", "role", "format", "subject_id", "session_id", "attributes"]
            s = obj.pSet(s, col, old.(col));    % exact text; NULL left to the default
        end
        s = obj.pSet(s, "created_by", obj.pCreatedBy(string(missing)));
        out.SuccessorArtifactId = obj.pInsertReturning(obj.pT("artifact"), s, "artifact_id");
        out.Registered = true;
    end

    % 2. The check of the bytes at the new path, as the caller made it.
    if checked
        out.VerificationId = obj.addArtifactVerification(ArtifactId=out.SuccessorArtifactId, ...
            Status="ok", ObservedChecksum=observed, VerifiedAt=opts.VerifiedAt);
    end

    % 3. The old file: moved, to that row.
    out.DispositionId = obj.addArtifactDisposition(ArtifactId=artifactId, Disposition="moved", ...
        OccurredAt=opts.OccurredAt, SuccessorArtifactId=out.SuccessorArtifactId, Note=opts.Note);
end
