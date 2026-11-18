classdef Prefs
    % labclient.Prefs  Where the client keeps its settings: MATLAB's preferences, or a file (tests).
    %   The settings of the lab database client (labclient.Settings) are
    %   one preference of the group "CarasLabDBClient", the same for every
    %   toolbox on this computer. The methods take the arguments of MATLAB's
    %   own preference functions, minus the group:
    %
    %     tf = labclient.Prefs.ispref(name)
    %     v  = labclient.Prefs.getpref(name)     % labclient:Prefs:NoPreference when missing
    %     labclient.Prefs.setpref(name, value)
    %     labclient.Prefs.rmpref(name)
    %
    %   getpref never adds a preference (MATLAB's three-argument form
    %   creates a missing one), so the callers test ispref first.
    %
    %   By default they are MATLAB's preferences. When the environment
    %   variable CARASLABDB_CLIENT_PREFS_FILE names a file, the preferences
    %   live in that .mat file instead (variable "prefs", one field per
    %   name) and MATLAB's are neither read nor written. Tests use that, so
    %   they never touch the user's own settings:
    %
    %     restore = labclient.Prefs.useTemporary();   % a new, empty file in tempdir
    %     ...
    %     clear restore                                % the file is deleted
    %
    %   See also labclient.Settings.

    properties (Constant)
        Group = "CarasLabDBClient"
        EnvVar = "CARASLABDB_CLIENT_PREFS_FILE"   % names the file store; "" = MATLAB preferences
    end

    methods (Static)
        function tf = ispref(name)
            %ispref  True when preference NAME exists.
            arguments
                name (1,1) string
            end
            file = labclient.Prefs.storeFile();
            if file == ""
                tf = ispref(char(labclient.Prefs.Group), char(name));
                return
            end
            S = labclient.Prefs.loadStore(file);
            tf = isfield(S, char(name));
        end

        function v = getpref(name)
            %getpref  The value of preference NAME (an error, labclient:Prefs:NoPreference, when it does not exist).
            arguments
                name (1,1) string
            end
            file = labclient.Prefs.storeFile();
            if file == ""
                if ~ispref(char(labclient.Prefs.Group), char(name))
                    error("labclient:Prefs:NoPreference", 'Preference "%s" does not exist.', name);
                end
                v = getpref(char(labclient.Prefs.Group), char(name));
                return
            end
            S = labclient.Prefs.loadStore(file);
            if ~isfield(S, char(name))
                error("labclient:Prefs:NoPreference", 'Preference "%s" does not exist.', name);
            end
            v = S.(char(name));
        end

        function setpref(name, value)
            %setpref  Set preference NAME to VALUE.
            arguments
                name (1,1) string
                value
            end
            file = labclient.Prefs.storeFile();
            if file == ""
                setpref(char(labclient.Prefs.Group), char(name), value);
                return
            end
            S = labclient.Prefs.loadStore(file);
            S.(char(name)) = value;
            labclient.Prefs.saveStore(file, S);
        end

        function rmpref(name)
            %rmpref  Remove preference NAME; nothing happens when it does not exist.
            arguments
                name (1,1) string
            end
            file = labclient.Prefs.storeFile();
            if file == ""
                if ispref(char(labclient.Prefs.Group), char(name))
                    rmpref(char(labclient.Prefs.Group), char(name));
                end
                return
            end
            S = labclient.Prefs.loadStore(file);
            if isfield(S, char(name))
                S = rmfield(S, char(name));
                labclient.Prefs.saveStore(file, S);
            end
        end

        function file = storeFile()
            %storeFile  The file the preferences live in, "" for MATLAB's preferences.
            file = string(getenv(labclient.Prefs.EnvVar));
        end

        function useFile(file)
            %useFile  Keep the preferences in FILE from now on ("" = MATLAB's).
            arguments
                file (1,1) string
            end
            setenv(labclient.Prefs.EnvVar, char(file));
        end

        function restore = useTemporary()
            %useTemporary  Use a new, empty preference file until RESTORE is cleared.
            %   RESTORE is an onCleanup object: clearing it deletes the file
            %   and puts back the store that was in use before.
            previous = labclient.Prefs.storeFile();
            file = string(tempname) + "_labclient_prefs.mat";
            labclient.Prefs.useFile(file);
            restore = onCleanup(@() labclient.Prefs.endTemporary(file, previous));
        end
    end

    methods (Static, Hidden)
        function endTemporary(file, previous)
            %endTemporary  Delete the temporary file and restore the previous store.
            if isfile(file)
                delete(file);
            end
            labclient.Prefs.useFile(previous);
        end
    end

    methods (Static, Access = private)
        function S = loadStore(file)
            S = struct();
            if ~isfile(file); return; end
            L = load(file, 'prefs');
            if isfield(L, 'prefs') && isstruct(L.prefs) && isscalar(L.prefs)
                S = L.prefs;
            end
        end

        function saveStore(file, S)
            prefs = S; %#ok<NASGU> saved by name
            save(file, 'prefs');
        end
    end
end
