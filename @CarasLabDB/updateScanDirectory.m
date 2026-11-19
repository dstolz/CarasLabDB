function updateScanDirectory(obj, scanDirectoryId, opts)
%UPDATESCANDIRECTORY Change a listed directory in place (row_history logs it).
%
%   db.updateScanDirectory(id, Mode="register")
%   db.updateScanDirectory(id, ScanIntervalMin=1440, WindowStart="22:00", WindowEnd="04:00")
%   db.updateScanDirectory(id, Clear="window")             % any time of day
%   db.updateScanDirectory(id, Clear=["rig", "pair_with", "notes"])
%   db.updateScanDirectory(id, Mode="off")                  % stop searching it
%
%   Updates the row of lab.scan_directory with this scan_directory_id. Only
%   the arguments you supply are changed; omitted ones are left as they are
%   (not set to NULL -- use Clear= for that). The database records the old
%   row, the new row and the login in lab.row_history. Only the schema
%   owner, or a login the owner grants UPDATE on lab.scan_directory to, may
%   do this (CANEDITSCANDIRECTORIES).
%
%   Name=Value: StorageRootId, RelativePath, Layout, TimeZone,
%   ScanIntervalMin, WindowStart, WindowEnd, MinAgeMin, Mode, Rig,
%   PairWith, Notes -- as in ADDSCANDIRECTORY -- and
%       Clear   what to set to NULL, any of:
%                 "window"     both window times: search at any time of day
%                 "rig", "pair_with", "notes"
%               (the other columns cannot be NULL). A column cannot be both
%               cleared and set (CarasLabDB:clearAndSet).
%   WindowStart and WindowEnd are given together, as on ADDSCANDIRECTORY;
%   each is "HH:mm" text (CarasLabDB:invalidWindow otherwise).
%
%   Once the directory has been searched (it has a lab.scan_run), its
%   storage root, path, layout and time zone are frozen: the database
%   refuses to change them. Turn it off (Mode="off") and add another
%   directory instead; a directory that is off also frees its path for a
%   new one. A change that would make it equal to, or nested with, another
%   directory of its root that is not off is refused too. The database's
%   error reaches the caller with its message. An id that matches no
%   directory raises CarasLabDB:scanDirectoryNotFound.
%
%   See also ADDSCANDIRECTORY, GETSCANDIRECTORIES, CANEDITSCANDIRECTORIES.

    arguments
        obj (1,1) CarasLabDB
        scanDirectoryId (1,1) double {mustBeInteger}
        opts.StorageRootId double {mustBeInteger, mustBeScalarOrEmpty} = []
        opts.RelativePath (1,1) string = string(missing)
        opts.Layout (1,1) string = string(missing)
        opts.TimeZone (1,1) string = string(missing)
        opts.ScanIntervalMin double {mustBeInteger, mustBePositive, mustBeScalarOrEmpty} = []
        opts.WindowStart (1,1) string = string(missing)
        opts.WindowEnd (1,1) string = string(missing)
        opts.MinAgeMin double {mustBeInteger, mustBeNonnegative, mustBeScalarOrEmpty} = []
        opts.Mode (1,1) string = string(missing)
        opts.Rig (1,1) string = string(missing)
        opts.PairWith double {mustBeInteger, mustBeScalarOrEmpty} = []
        opts.Notes (1,1) string = string(missing)
        opts.Clear (1,:) string = strings(1, 0)
    end

    obj.pCheckMember(opts.Mode, ["off", "report", "register"], "Mode");
    [windowStart, windowEnd] = CarasLabDB.pScanWindow(opts.WindowStart, opts.WindowEnd);

    % Clear= names what to empty. "window" stands for both window columns,
    % which the table holds both or neither; the names are checked against a
    % fixed list, so a caller's text never reaches the SQL as an identifier.
    clearable = ["window", "rig", "pair_with", "notes"];
    toClear = reshape(unique(opts.Clear, "stable"), 1, []);
    if any(ismissing(toClear)) || ~all(ismember(toClear, clearable))
        error("CarasLabDB:invalidValue", "Clear must name columns from: %s.", ...
            strjoin(clearable, ", "));
    end
    cols = strings(1, 0);
    for c = toClear
        if c == "window"
            cols = [cols, "window_start", "window_end"]; %#ok<AGROW>
        else
            cols(end+1) = c; %#ok<AGROW>
        end
    end

    s = struct();
    s = obj.pSet(s, "storage_root_id", opts.StorageRootId);
    s = obj.pSet(s, "relative_path", opts.RelativePath);
    s = obj.pSet(s, "layout", opts.Layout);
    s = obj.pSet(s, "time_zone", opts.TimeZone);
    s = obj.pSet(s, "scan_interval_min", opts.ScanIntervalMin);
    s = obj.pSet(s, "window_start", windowStart);
    s = obj.pSet(s, "window_end", windowEnd);
    s = obj.pSet(s, "min_age_min", opts.MinAgeMin);
    s = obj.pSet(s, "mode", opts.Mode);
    s = obj.pSet(s, "rig", opts.Rig);
    s = obj.pSet(s, "pair_with", opts.PairWith);
    s = obj.pSet(s, "notes", opts.Notes);
    s = obj.pApplyClear(s, cols, ["window_start", "window_end", "rig", "pair_with", "notes"]);

    % A wrong id would otherwise update zero rows and report success;
    % RETURNING reports the row count.
    n = obj.pUpdate(obj.pT("scan_directory"), s, ...
        "scan_directory_id = " + obj.sqlLiteral(scanDirectoryId), "scan_directory_id");
    if n == 0
        error("CarasLabDB:scanDirectoryNotFound", "No scan directory with id %d.", scanDirectoryId);
    end
end
