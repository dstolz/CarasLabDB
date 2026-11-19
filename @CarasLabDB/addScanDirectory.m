function scanDirectoryId = addScanDirectory(obj, opts)
%ADDSCANDIRECTORY List a directory to be searched for new files; returns its scan_directory_id.
%
%   id = db.addScanDirectory(StorageRootId=1, RelativePath="rig1/epsych", ...
%            Layout="epsych", TimeZone="America/New_York", ScanIntervalMin=60)
%   id = db.addScanDirectory(StorageRootId=1, RelativePath="rig1/intan", ...
%            Layout="intan", TimeZone="America/New_York", ScanIntervalMin=1440, ...
%            WindowStart="01:00", WindowEnd="05:00", MinAgeMin=720, ...
%            Mode="register", Rig="rig1", PairWith=epsychId, Notes="nightly")
%
%   Inserts one row of lab.scan_directory, the list tools/import_nas_files.py
%   searches. Only the schema owner, or a login the owner grants INSERT on
%   lab.scan_directory to, may do this (CANEDITSCANDIRECTORIES); for anyone
%   else the database refuses it ("permission denied").
%
%   Required Name=Value:
%       StorageRootId    the registered storage root the directory is under
%       RelativePath     the directory, relative to the root ('/' separators,
%                        no '.' or '..' segment, no '//', no trailing '/')
%       Layout           how it is laid out: a code of lab.scan_layout
%                        (GETSCANLAYOUTS), e.g. "epsych", "intan"
%       TimeZone         the zone of the wall-clock times in its file names
%                        and of the window: a name the server knows, such
%                        as "America/New_York" (not an abbreviation)
%       ScanIntervalMin  minutes between searches: a whole number, 1 to
%                        527040 (366 days)
%   Optional:
%       WindowStart,     the hours it may be searched, [start, end), as
%       WindowEnd        "HH:mm" text in TimeZone; both or neither (neither:
%                        any time). Wraps midnight when start > end.
%       MinAgeMin        minutes a group must be seen unchanged before it is
%                        registered (whole number, >= 0; default 1440)
%       Mode             "off", "report" (default) or "register"
%       Rig              recorded on the sessions registered from it
%       PairWith         the scan_directory_id of another directory on the
%                        same storage root whose files belong with these
%       Notes            free text
%       CreatedBy        person_id (default: the current person)
%
%   The window, the mode and the whole-minute numbers are checked here,
%   before anything is sent (CarasLabDB:invalidWindow,
%   CarasLabDB:invalidValue, the MATLAB validators). The rest is the
%   database's: a directory that is the same as, contains or lies inside
%   another directory of the root that is not 'off' (compared without
%   regard to case), a time zone the server does not know, an unknown
%   layout or root. Its error reaches the caller with the database's
%   message.
%
%   See also GETSCANDIRECTORIES, UPDATESCANDIRECTORY, CANEDITSCANDIRECTORIES,
%   GETSCANLAYOUTS.

    arguments
        obj (1,1) CarasLabDB
        opts.StorageRootId (1,1) double {mustBeInteger}
        opts.RelativePath (1,1) string
        opts.Layout (1,1) string
        opts.TimeZone (1,1) string
        opts.ScanIntervalMin (1,1) double {mustBeInteger, mustBePositive}
        opts.WindowStart (1,1) string = string(missing)
        opts.WindowEnd (1,1) string = string(missing)
        opts.MinAgeMin double {mustBeInteger, mustBeNonnegative, mustBeScalarOrEmpty} = []
        opts.Mode (1,1) string = string(missing)
        opts.Rig (1,1) string = string(missing)
        opts.PairWith double {mustBeInteger, mustBeScalarOrEmpty} = []
        opts.Notes (1,1) string = string(missing)
        opts.CreatedBy (1,1) string = string(missing)
    end

    obj.pCheckMember(opts.Mode, ["off", "report", "register"], "Mode");
    [windowStart, windowEnd] = CarasLabDB.pScanWindow(opts.WindowStart, opts.WindowEnd);

    s = struct( ...
        "storage_root_id", opts.StorageRootId, ...
        "relative_path", opts.RelativePath, ...
        "layout", opts.Layout, ...
        "time_zone", opts.TimeZone, ...
        "scan_interval_min", opts.ScanIntervalMin);
    % The window goes as text ('01:00'), which the time columns read; it
    % comes back as the same text (window_start_text / window_end_text).
    s = obj.pSet(s, "window_start", windowStart);
    s = obj.pSet(s, "window_end", windowEnd);
    s = obj.pSet(s, "min_age_min", opts.MinAgeMin);
    s = obj.pSet(s, "mode", opts.Mode);
    s = obj.pSet(s, "rig", opts.Rig);
    s = obj.pSet(s, "pair_with", opts.PairWith);
    s = obj.pSet(s, "notes", opts.Notes);
    s = obj.pSet(s, "created_by", obj.pCreatedBy(opts.CreatedBy));
    scanDirectoryId = double(obj.pInsertReturning(obj.pT("scan_directory"), s, ...
        "scan_directory_id"));
end
