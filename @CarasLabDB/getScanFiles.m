function T = getScanFiles(obj, opts)
%GETSCANFILES The scan memory: what the directory search last saw of each file.
%
%   T = db.getScanFiles(Status="held", StorageRootId=1, PathPrefix="rig1/epsych/")
%   T = db.getScanFiles(StorageRootId=1, PathPrefix="rig1/epsych/")   % every file's state
%   T = db.getScanFiles(ScanRunId=r, LatestPerFile=false)              % what run r wrote
%
%   With LatestPerFile=true (the default) reads lab.scan_file_latest: one
%   row per (storage root, path), its latest row -- the file's state. With
%   LatestPerFile=false reads the whole log, lab.scan_file. Columns:
%       scan_file_id, scan_run_id, storage_root_id, relative_path,
%       size_bytes, mtime_ns, group_key, status, reason_code, reason,
%       artifact_id
%       scan_directory_id, seen_at   the directory of the run that wrote the
%                                    row, and when that run started
%   mtime_ns comes back as text: it is a whole number of nanoseconds that a
%   double cannot hold exactly. status is 'pending', 'registered', 'known',
%   'held' or 'cleared'; reason_code and reason say why a file is held.
%
%   Name=Value filters: StorageRootId, PathPrefix (the path starts with
%   this text, compared exactly, case included: give a directory's path
%   followed by "/" for the files under it), Status, ScanRunId. Ordered by
%   storage root, path and scan_file_id.
%
%   See also GETSCANDIRECTORIES, GETSCANRUNS.

    arguments
        obj (1,1) CarasLabDB
        opts.StorageRootId double {mustBeInteger, mustBeScalarOrEmpty} = []
        opts.PathPrefix (1,1) string = string(missing)
        opts.Status (1,1) string = string(missing)
        opts.ScanRunId double {mustBeInteger, mustBeScalarOrEmpty} = []
        opts.LatestPerFile (1,1) logical = true
    end

    obj.pCheckMember(opts.Status, ["pending", "registered", "known", "held", "cleared"], "Status");
    clauses = strings(1, 0);
    if obj.pIsProvided(opts.StorageRootId)
        clauses(end+1) = "f.storage_root_id = " + obj.sqlLiteral(opts.StorageRootId);
    end
    if obj.pIsProvided(opts.PathPrefix)
        % starts_with, never LIKE: '_' and '%' are ordinary characters in a path.
        clauses(end+1) = "starts_with(f.relative_path, " + obj.sqlLiteral(opts.PathPrefix) + ")";
    end
    if obj.pIsProvided(opts.Status)
        clauses(end+1) = "f.status = " + obj.sqlLiteral(opts.Status);
    end
    if obj.pIsProvided(opts.ScanRunId)
        clauses(end+1) = "f.scan_run_id = " + obj.sqlLiteral(opts.ScanRunId);
    end
    if opts.LatestPerFile
        source = obj.pT("scan_file_latest");
    else
        source = obj.pT("scan_file");
    end
    where = "";
    if ~isempty(clauses)
        where = " WHERE " + strjoin(clauses, " AND ");
    end
    T = obj.pSelect("SELECT f.scan_file_id, f.scan_run_id, f.storage_root_id, f.relative_path, " + ...
        "f.size_bytes, f.mtime_ns::text AS mtime_ns, f.group_key, f.status, f.reason_code, " + ...
        "f.reason, f.artifact_id, r.scan_directory_id, r.started_at AS seen_at FROM " + ...
        source + " f JOIN " + obj.pT("scan_run") + " r ON r.scan_run_id = f.scan_run_id" + ...
        where + " ORDER BY f.storage_root_id, f.relative_path, f.scan_file_id;");
end
