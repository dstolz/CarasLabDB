function T = getScanRuns(obj, opts)
%GETSCANRUNS The runs of the directory search, each with its result, newest first.
%
%   T = db.getScanRuns(ScanDirectoryId=id)
%   T = db.getScanRuns(ScanDirectoryId=id, Limit=20)
%   T = db.getScanRuns(Limit=0)                 % every run of every directory
%
%   Reads lab.scan_run (one row when a run of one directory starts) with
%   its lab.scan_run_result (one row when it ends), ordered by
%   scan_run_id, newest first. Columns:
%       scan_run_id, scan_directory_id, command ('run' or 'apply'), mode,
%       due_at (missing for a run made by hand), started_at, tool_version,
%       host, run_login
%       has_result     whether the run has ended
%       is_running     no result yet and started less than 24 hours ago,
%                      as lab.fn_scan_status counts it; a run with no
%                      result that is not running was interrupted
%       finished_at, outcome ('ok', 'partial', 'failed', 'unreachable'),
%       files_listed, files_unchanged, files_pending, files_registered,
%       files_known, files_held, files_ignored, files_cleared,
%       groups_registered, groups_waiting, groups_held, bytes_read,
%       message, details (JSON text)
%   The result columns are missing for a run that has none.
%
%   Limit= caps the number of rows (default 100; 0 = no cap).
%
%   See also GETSCANDIRECTORIES, GETSCANFILES.

    arguments
        obj (1,1) CarasLabDB
        opts.ScanDirectoryId double {mustBeInteger, mustBeScalarOrEmpty} = []
        opts.Limit (1,1) double {mustBeInteger, mustBeNonnegative} = 100
    end

    where = "";
    if obj.pIsProvided(opts.ScanDirectoryId)
        where = " WHERE r.scan_directory_id = " + obj.sqlLiteral(opts.ScanDirectoryId);
    end
    sql = "SELECT r.scan_run_id, r.scan_directory_id, r.command, r.mode, r.due_at, " + ...
        "r.started_at, r.tool_version, r.host, r.run_login, " + ...
        "(x.scan_run_id IS NOT NULL) AS has_result, " + ...
        "(x.scan_run_id IS NULL AND r.started_at > now() - make_interval(mins => 24 * 60)) " + ...
        "AS is_running, " + ...
        "x.finished_at, x.outcome, x.files_listed, x.files_unchanged, x.files_pending, " + ...
        "x.files_registered, x.files_known, x.files_held, x.files_ignored, x.files_cleared, " + ...
        "x.groups_registered, x.groups_waiting, x.groups_held, x.bytes_read, x.message, " + ...
        "x.details::text AS details " + ...
        "FROM " + obj.pT("scan_run") + " r LEFT JOIN " + obj.pT("scan_run_result") + ...
        " x ON x.scan_run_id = r.scan_run_id" + where + " ORDER BY r.scan_run_id DESC";
    if opts.Limit > 0
        sql = sql + " LIMIT " + string(opts.Limit);
    end
    T = obj.pSelect(sql + ";");
end
