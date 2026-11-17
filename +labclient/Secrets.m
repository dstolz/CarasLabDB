classdef Secrets
    % labclient.Secrets  The lab database password, kept in the MATLAB vault, never in a file.
    %   The password of your database login is stored with MATLAB's own
    %   secret store (setSecret / getSecret, MATLAB R2024a or later), under a
    %   name that says which login and server it is for:
    %
    %     name = labclient.Secrets.secretName(s)   % "CarasLabDB:<user>@<server>:<port>/<db>"
    %     labclient.Secrets.prompt(s)              % MATLAB's own dialog asks for it (setSecret)
    %     tf = labclient.Secrets.has(s)
    %     pw = labclient.Secrets.get(s)            % labclient:Secrets:None when there is none
    %     labclient.Secrets.remove(s)
    %
    %   S is the labclient.Settings struct. The password is never written to the
    %   preferences, a config, a script, a manifest or the outbox, and the
    %   apps never see it typed: setSecret's dialog takes it.
    %
    %   Tests do not touch the vault: useFake() keeps secrets in memory until
    %   the object it returns is cleared.
    %
    %     restore = labclient.Secrets.useFake();
    %     labclient.Secrets.setFake(s, "pw")
    %
    %   See also labclient.Settings, labclient.DB, setSecret, getSecret.

    methods (Static)
        function name = secretName(s)
            %secretName  The vault name of the password for settings S.
            name = "CarasLabDB:" + s.Username + "@" + s.Server + ":" + string(s.Port) + ...
                "/" + s.DatabaseName;
        end

        function tf = available()
            %available  True when this MATLAB has the vault (R2024a or later), or a fake is in use.
            tf = labclient.Secrets.fake().Active || exist("getSecret", "file") > 0 ...
                || exist("getSecret", "builtin") > 0;
        end

        function tf = has(s)
            %has  True when a password for settings S is stored.
            name = labclient.Secrets.secretName(s);
            f = labclient.Secrets.fake();
            if f.Active
                tf = isKey(f.Map, char(name));
                return
            end
            tf = false;
            if ~labclient.Secrets.available(); return; end
            try
                tf = isSecret(char(name));
            catch
            end
        end

        function pw = get(s)
            %get  The stored password for settings S (labclient:Secrets:None when there is none).
            name = labclient.Secrets.secretName(s);
            f = labclient.Secrets.fake();
            if f.Active
                if ~isKey(f.Map, char(name))
                    error("labclient:Secrets:None", "No password is stored for %s.", name);
                end
                pw = string(f.Map(char(name)));
                return
            end
            if ~labclient.Secrets.available()
                error("labclient:Secrets:NoVault", ...
                    "This MATLAB has no secret vault (getSecret needs R2024a or later).");
            end
            if ~labclient.Secrets.has(s)
                error("labclient:Secrets:None", ...
                    "No password is stored for %s: set it in the Database window.", name);
            end
            pw = string(getSecret(char(name)));
        end

        function prompt(s)
            %prompt  Ask for the password with MATLAB's own dialog and store it (setSecret).
            name = labclient.Secrets.secretName(s);
            if labclient.Secrets.fake().Active
                error("labclient:Secrets:Fake", "The fake vault in use cannot prompt.");
            end
            if ~labclient.Secrets.available()
                error("labclient:Secrets:NoVault", ...
                    "This MATLAB has no secret vault (setSecret needs R2024a or later).");
            end
            setSecret(char(name), "Overwrite", true);
        end

        function remove(s)
            %remove  Remove the stored password for settings S, if there is one.
            name = labclient.Secrets.secretName(s);
            f = labclient.Secrets.fake();
            if f.Active
                if isKey(f.Map, char(name)); remove(f.Map, char(name)); end
                return
            end
            if labclient.Secrets.has(s)
                removeSecret(char(name));
            end
        end

        function restore = useFake()
            %useFake  Keep secrets in memory, not the vault, until RESTORE is cleared.
            f = labclient.Secrets.fake();
            was = f.Active;
            old = f.Map;
            f.Active = true;
            f.Map = containers.Map();
            restore = onCleanup(@() labclient.Secrets.endFake(was, old));
        end

        function setFake(s, password)
            %setFake  Store PASSWORD for settings S in the fake vault (tests only).
            f = labclient.Secrets.fake();
            if ~f.Active
                error("labclient:Secrets:NotFake", "setFake works only after useFake.");
            end
            f.Map(char(labclient.Secrets.secretName(s))) = char(password);
        end
    end

    methods (Static, Access = private)
        function f = fake()
            %fake  The in-memory vault of the tests (a handle kept for the session).
            persistent store
            if isempty(store)
                store = labclient.FakeVault();
            end
            f = store;
        end

        function endFake(was, old)
            f = labclient.Secrets.fake();
            f.Active = was;
            f.Map = old;
        end
    end
end
