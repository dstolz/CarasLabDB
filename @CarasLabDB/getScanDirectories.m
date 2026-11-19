function T = getScanDirectories(obj, opts)
%GETSCANDIRECTORIES The directories searched for new files, with their schedule.
%
%   T = db.getScanDirectories()
%   T = db.getScanDirectories(ScanDirectoryId=id)
%   T = db.getScanDirectories(StorageRootId=1, Mode="register")
%
%   Reads lab.scan_directory_status: one row per listed directory, as
%   lab.fn_scan_status gives it at the database's now(). Every member can
%   read it. Columns:
%       scan_directory_id, storage_root_id, storage_root (its name),
%       relative_path, layout, rig, pair_with, time_zone
%       scan_interval_min      minutes between searches (a whole number)
%       window_start_text,     the hours the directory may be searched, as
%       window_end_text        'HH:mm' text in its time_zone; both missing
%                              when it may be searched at any time
%       min_age_min            minutes a group must be seen unchanged
%       mode                   'off', 'report' or 'register'
%       mode_changed_at, notes, created_at, created_by, created_login
%       last_run_id, last_run_command, last_run_mode, last_run_started_at,
%       last_run_outcome,      the latest run of any kind; outcome missing
%       last_run_finished_at   while it runs or when it was interrupted
%       last_ok_run_id, last_ok_due_at, last_ok_finished_at
%       due_at                 when it is next due (the database decides)
%       window_open, is_due, is_overdue, is_running
%       n_pending, n_held      files under it whose latest memory row is
%                              'pending' / 'held'
%   Timestamps come back in the workstation's zone (the session zone is
%   set to it at connection). No client does arithmetic on the schedule.
%
%   Name=Value filters: ScanDirectoryId, StorageRootId, Mode ("off",
%   "report" or "register"). Ordered by storage root name, path and id.
%
%   See also ADDSCANDIRECTORY, UPDATESCANDIRECTORY, GETSCANRUNS, GETSCANFILES.

    arguments
        obj (1,1) CarasLabDB
        opts.ScanDirectoryId double {mustBeInteger, mustBeScalarOrEmpty} = []
        opts.StorageRootId double {mustBeInteger, mustBeScalarOrEmpty} = []
        opts.Mode (1,1) string = string(missing)
    end

    obj.pCheckMember(opts.Mode, ["off", "report", "register"], "Mode");
    f = struct();
    f = obj.pSet(f, "scan_directory_id", opts.ScanDirectoryId);
    f = obj.pSet(f, "storage_root_id", opts.StorageRootId);
    f = obj.pSet(f, "mode", opts.Mode);
    T = obj.pSelectFrom(obj.pT("scan_directory_status"), f, ...
        OrderBy="storage_root, relative_path, scan_directory_id");
end
