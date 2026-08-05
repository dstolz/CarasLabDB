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
        if ~isfield(stored, k) || isempty(stored.(k))
            continue
        end
        if isstruct(d.(k))
            % Nested structs must be merged field by field. Taking a stored
            % struct wholesale accepts one written by an older build, and the
            % first read of a field it predates throws from the constructor,
            % before any window exists to report it.
            if isstruct(stored.(k)) && isscalar(stored.(k))
                p.(k) = local_mergeStruct(d.(k), stored.(k));
            end
        elseif strcmp(class(stored.(k)), class(d.(k)))
            p.(k) = stored.(k);
        end
    end

    obj.Prefs = p;
end

function m = local_mergeStruct(defaults, stored)
    %LOCAL_MERGESTRUCT Overlay STORED onto DEFAULTS, one field at a time.
    m = defaults;
    fn = fieldnames(defaults);
    for i = 1:numel(fn)
        k = fn{i};
        if isfield(stored, k) && ~isempty(stored.(k)) ...
                && strcmp(class(stored.(k)), class(defaults.(k)))
            m.(k) = stored.(k);
        end
    end
end

function d = local_defaults()
    d = struct();
    d.Geometry     = [];                 % [x y w h] or [] -> centered default
    d.Connection   = struct("Server","localhost", "Port",5432, ...
                            "Username","", "DatabaseName","lab", "PersonEmail","");
    d.UseActiveViews = true;
    d.LastTab      = "subjects";
    d.SqlHistory   = strings(0,1);
    d.LastSql      = "SELECT * FROM lab.subject_current;";
end
