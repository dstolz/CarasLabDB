function loadPrefs(obj)
%LOADPREFS Load persisted preferences into obj.Prefs, seeding defaults.
%
%   Preferences live under a single getpref/setpref value so a schema bump
%   never breaks launch; missing or invalid keys fall back to defaults.
%
%   See also CARASLABDBAPP/SAVEPREFS.

    d = local_defaults();

    stored = struct();
    try
        if ispref(obj.PrefGroup, "Prefs")
            stored = getpref(obj.PrefGroup, "Prefs");
        end
    catch
        stored = struct();
    end

    if ~isstruct(stored)
        stored = struct();
    end

    % Merge stored over defaults, key by key, keeping defaults for anything
    % missing or type-mismatched.
    p = d;
    fn = fieldnames(d);
    for i = 1:numel(fn)
        k = fn{i};
        if isfield(stored, k) && ~isempty(stored.(k)) ...
                && strcmp(class(stored.(k)), class(d.(k)))
            p.(k) = stored.(k);
        end
    end

    obj.Prefs = p;
end

function d = local_defaults()
    d = struct();
    d.Geometry     = [];                 % [x y w h] or [] -> centered default
    d.Connection   = struct("Server","localhost", "Port",5432, ...
                            "Username","", "DatabaseName","ephys", "PersonEmail","");
    d.UseActiveViews = true;
    d.LastTab      = "subjects";
    d.SqlHistory   = strings(0,1);
    d.LastSql      = "SELECT * FROM ephys.subject_current;";
end
