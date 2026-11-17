classdef Settings
    % labclient.Settings  How this computer reaches the lab database (CarasLabDB): one set of settings for every toolbox.
    %   The toolboxes (ephys_analysis, EPsych, ...) record their work in the lab's CarasLabDB database when it
    %   is enabled here, and keep working when it is not, or cannot be
    %   reached (see labclient.DB). The settings are one struct in the preference
    %   group "CarasLabDBClient" (labclient.Prefs, so the tests use a temporary
    %   store). A computer is set up once, whichever toolbox records:
    %
    %     s = labclient.Settings.load()      % the saved settings, defaults filled in
    %     labclient.Settings.save(s)         % checked first (labclient:Settings:Invalid)
    %     s = labclient.Settings.defaults()
    %
    %   Fields
    %     Enabled           true to use the database at all (default false)
    %     Server, Port, DatabaseName   where it is (default "", 5432, "lab")
    %     Username          your own database login (never a shared one)
    %     PersonEmail       your lab.person email, when your login is not
    %                       mapped to you in the database ("" = the login's)
    %     PersonId          your lab.person id, as the database last said
    %                       (filled in by Test connection; work recorded
    %                       while offline names this person)
    %     LabTimeZone       the zone in which times written without one (old
    %                       manifests, rig clocks) are read, e.g.
    %                       "America/New_York" (default: this computer's)
    %     ConnectTimeout    seconds to wait for the server (default 5)
    %     StatementTimeout  seconds one statement may run (default 30)
    %     Roots             the storage roots mounted on this computer: a
    %                       struct array with Name (lab.storage_root.name)
    %                       and Path (where it is here), e.g. "nas-main" and
    %                       "\\nas\data"; see labclient.Roots
    %     HashInProcessMB   files up to this size are hashed in MATLAB;
    %                       larger ones out of process (default 256)
    %
    %   The password is not here: it is in the MATLAB vault (labclient.Secrets).
    %
    %   See also labclient.DB, labclient.Secrets, labclient.Roots, labclient.Prefs.

    properties (Constant)
        Group = "CarasLabDBClient"   % labclient.Prefs.Group
        Name = "Settings"
    end

    methods (Static)
        function s = defaults()
            %defaults  The settings of a computer that has not been set up.
            s = struct( ...
                "Enabled", false, ...
                "Server", "", ...
                "Port", 5432, ...
                "DatabaseName", "lab", ...
                "Username", "", ...
                "PersonEmail", "", ...
                "PersonId", "", ...
                "LabTimeZone", labclient.Settings.localZone(), ...
                "ConnectTimeout", 5, ...
                "StatementTimeout", 30, ...
                "Roots", struct("Name", {}, "Path", {}), ...
                "HashInProcessMB", 256);
        end

        function s = load()
            %load  The saved settings, each missing or unusable field taken from the defaults.
            s = labclient.Settings.defaults();
            if ~labclient.Prefs.ispref(labclient.Settings.Name)
                return
            end
            try
                stored = labclient.Prefs.getpref(labclient.Settings.Name);
            catch
                return
            end
            if ~isstruct(stored) || ~isscalar(stored)
                return
            end
            for f = reshape(string(fieldnames(s)), 1, [])
                if ~isfield(stored, f); continue; end
                v = stored.(f);
                try
                    s.(f) = labclient.Settings.checkField(f, v);
                catch
                    % a stored value of the wrong kind: keep the default
                end
            end
        end

        function save(s)
            %save  Check S field by field and store it (labclient:Settings:Invalid when a field is wrong).
            arguments
                s (1,1) struct
            end
            clean = labclient.Settings.defaults();
            for f = reshape(string(fieldnames(clean)), 1, [])
                if ~isfield(s, f); continue; end
                try
                    clean.(f) = labclient.Settings.checkField(f, s.(f));
                catch ME
                    error("labclient:Settings:Invalid", "%s: %s", f, ME.message);
                end
            end
            labclient.Prefs.setpref(labclient.Settings.Name, clean);
        end

        function tf = isConfigured(s)
            %isConfigured  Enabled, with a server, a database and a login named.
            tf = s.Enabled && strlength(s.Server) > 0 && strlength(s.DatabaseName) > 0 ...
                && strlength(s.Username) > 0;
        end

        function z = localZone()
            %localZone  This computer's time zone (an IANA name such as "Europe/Berlin").
            z = string(datetime("now", "TimeZone", "local").TimeZone);
        end
    end

    methods (Static, Access = private)
        function v = checkField(name, v)
            %checkField  V as field NAME holds it, or an error saying what is wrong.
            switch name
                case "Enabled"
                    if ~(islogical(v) || isnumeric(v)) || ~isscalar(v)
                        error("must be true or false");
                    end
                    v = logical(v);
                case {"Server", "DatabaseName", "Username", "PersonEmail", "PersonId"}
                    v = labclient.Settings.text(v);
                    if name == "PersonId" && v ~= "" && isempty(regexp(char(v), ...
                            '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', 'once'))
                        error("must be a lab.person id (a uuid)");
                    end
                    if name == "PersonId"
                        v = lower(v);
                    end
                case "LabTimeZone"
                    v = labclient.Settings.text(v);
                    try
                        datetime("now", "TimeZone", char(v));
                    catch
                        error("'%s' is not a time zone MATLAB knows", v);
                    end
                case "Port"
                    if ~isnumeric(v) || ~isscalar(v) || v ~= fix(v) || v < 1 || v > 65535
                        error("must be a whole number from 1 to 65535");
                    end
                    v = double(v);
                case {"ConnectTimeout", "StatementTimeout", "HashInProcessMB"}
                    if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v) || v <= 0
                        error("must be a positive number");
                    end
                    v = double(v);
                    if name == "ConnectTimeout"
                        v = max(2, ceil(v));   % libpq's smallest connect_timeout
                    end
                case "Roots"
                    if isempty(v)
                        v = struct("Name", {}, "Path", {});
                        return
                    end
                    if ~isstruct(v) || ~all(isfield(v, ["Name" "Path"]))
                        error("must be a struct array with Name and Path");
                    end
                    out = struct("Name", {}, "Path", {});
                    for k = 1:numel(v)
                        n = labclient.Settings.text(v(k).Name);
                        p = labclient.Settings.text(v(k).Path);
                        if n == "" || p == ""
                            error("root %d has no name or no path", k);
                        end
                        if any(string({out.Name}) == n)
                            error("root %s is listed twice", n);
                        end
                        out(end+1) = struct("Name", n, "Path", p); %#ok<AGROW>
                    end
                    v = out;
            end
        end

        function t = text(v)
            %text  V as a trimmed string scalar ("" for empty).
            if isempty(v)
                t = "";
                return
            end
            if ~(ischar(v) || (isstring(v) && isscalar(v))) || (isstring(v) && ismissing(v))
                error("must be text");
            end
            t = strtrim(string(v));
        end
    end
end
