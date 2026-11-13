function [artifactId, info] = addArtifactFromFile(obj, filePath, opts)
%ADDARTIFACTFROMFILE Register a file as an artifact, computing its size, checksum and path.
%
%   aid = addArtifactFromFile(db, "Z:\data\G-0421\2026-07-02_pen1\raw.dat", ...
%             ProducedByEventId=eid, StorageRootId=1, RootPath="Z:\data", ...
%             Role="raw")
%   [aid, info] = addArtifactFromFile(db, file, ProducedByEventId=eid, ...
%             StorageRootId=1, RootPath="/Volumes/data", SessionId=sid)
%
%   ADDARTIFACT needs a path relative to the storage root, a checksum and a
%   size; this method works all three out from the file itself and then
%   calls ADDARTIFACT:
%     * the size in bytes, as the file system reports it;
%     * the SHA-256 of the contents (CarasLabDB.fileChecksum; a large
%       recording takes as long as reading it once);
%     * the path relative to RootPath, with forward slashes. RootPath is
%       where the storage root StorageRootId is mounted on THIS computer
%       ("Z:\data" on one machine, "/Volumes/data" on another), so that the
%       stored path resolves on every machine. A file that is not under
%       RootPath raises CarasLabDB:fileNotUnderRoot. On Windows the
%       comparison ignores letter case; the stored path keeps the spelling
%       the file system reports.
%   Nothing is written if any of these steps fails, and the file is only
%   read, never changed.
%
%   Required Name=Value:
%       ProducedByEventId - event that produced the file (uuid)
%       StorageRootId     - storage_root.root_id (see getStorageRoots)
%       RootPath          - local folder that storage root is mounted at
%   Optional Name=Value:
%       Role       - artifact_role.code ('raw', 'spikes', ...)
%       Format     - file format (default: the file's extension, lower case)
%       SessionId, SubjectId - where given they must be the producing
%                    event's (the database rejects any other)
%       Attributes - struct / containers.Map / dictionary -> jsonb
%
%   Returns the new artifact_id (uuid string) and INFO, a struct with the
%   fields checksum, checksum_algo ("sha256"), size_bytes and relative_path
%   as registered.
%
%   NOT YET RUN: see the note in the help of CarasLabDB.fileChecksum, and
%   check the first few files registered this way against a known hash
%   (e.g. certutil -hashfile <file> SHA256 on Windows) and the relative_path
%   against the path you expect.
%
%   See also CARASLABDB, ADDARTIFACT, CARASLABDB.FILECHECKSUM, GETSTORAGEROOTS,
%   ADDARTIFACTVERIFICATION.

    arguments
        obj (1,1) CarasLabDB
        filePath (1,1) string
        opts.ProducedByEventId (1,1) string
        opts.StorageRootId (1,1) double {mustBeInteger}
        opts.RootPath (1,1) string
        opts.Role (1,1) string = string(missing)
        opts.Format (1,1) string = string(missing)
        opts.SessionId (1,1) string = string(missing)
        opts.SubjectId (1,1) string = string(missing)
        opts.Attributes = []
    end

    [fileAbs, isFolder] = local_absolutePath(filePath);
    if ismissing(fileAbs) || isFolder
        error("CarasLabDB:fileNotFound", "No file at %s.", filePath);
    end
    [rootAbs, isFolder] = local_absolutePath(opts.RootPath);
    if ismissing(rootAbs) || ~isFolder
        error("CarasLabDB:rootNotFound", ...
            "RootPath %s is not a folder on this computer.", opts.RootPath);
    end
    relativePath = local_relativePath(fileAbs, rootAbs);

    listing = dir(char(fileAbs));
    if ~isscalar(listing)
        error("CarasLabDB:fileNotFound", "No single file at %s.", fileAbs);
    end
    sizeBytes = listing.bytes;

    fileFormat = opts.Format;
    if ismissing(fileFormat)
        [~, ~, ext] = fileparts(fileAbs);
        if strlength(ext) > 1
            fileFormat = lower(extractAfter(ext, 1));   % ".DAT" -> "dat"
        end
    end

    checksum = CarasLabDB.fileChecksum(fileAbs, Algo="sha256");

    info = struct("checksum", checksum, "checksum_algo", "sha256", ...
        "size_bytes", sizeBytes, "relative_path", relativePath);
    artifactId = obj.addArtifact( ...
        ProducedByEventId=opts.ProducedByEventId, StorageRootId=opts.StorageRootId, ...
        RelativePath=relativePath, Checksum=checksum, ChecksumAlgo="sha256", ...
        SizeBytes=sizeBytes, Role=opts.Role, Format=fileFormat, ...
        SubjectId=opts.SubjectId, SessionId=opts.SessionId, Attributes=opts.Attributes);
end

% -------------------------------------------------------------------------
function [absPath, isFolder] = local_absolutePath(name)
%LOCAL_ABSOLUTEPATH Absolute path of an existing file or folder; missing if there is none.
%   fileattrib resolves a relative name against the current folder and
%   reports the full path in the operating system's own spelling.
    absPath = string(missing);
    isFolder = false;
    if ismissing(name) || strlength(name) == 0
        return
    end
    [ok, attributes] = fileattrib(char(name));
    if ~ok || ~isstruct(attributes) || ~isscalar(attributes)
        return      % nothing there, or a wildcard that matched several
    end
    absPath = string(attributes.Name);
    isFolder = logical(attributes.directory);
end

function relativePath = local_relativePath(fileAbs, rootAbs)
%LOCAL_RELATIVEPATH FILEABS relative to the folder ROOTABS, with forward slashes.
%   Both are absolute paths in the operating system's spelling. The root is
%   compared with a trailing separator, so "Z:\data" is not taken for the
%   parent of "Z:\database\x.dat".
    root = rootAbs;
    while strlength(root) > 0 && endsWith(root, filesep)
        root = extractBefore(root, strlength(root));
    end
    prefix = root + filesep;
    if ~startsWith(fileAbs, prefix, "IgnoreCase", ispc)
        error("CarasLabDB:fileNotUnderRoot", ...
            "%s is not under RootPath %s, so it has no path relative to that storage root.", ...
            fileAbs, rootAbs);
    end
    relativePath = extractAfter(fileAbs, strlength(prefix));
    if ispc
        relativePath = replace(relativePath, "\", "/");
    end
end
