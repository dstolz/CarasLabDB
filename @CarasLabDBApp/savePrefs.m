function savePrefs(obj)
%SAVEPREFS Persist obj.Prefs (updated from live UI state) via setpref.
%
%   Captures window geometry, the active-view toggle, the selected tab, and
%   the current SQL editor text before writing. The database password is
%   never stored.
%
%   See also CARASLABDBAPP/LOADPREFS.

    p = obj.Prefs;

    % Capture live UI state if the window still exists.
    if ~isempty(obj.Fig) && isvalid(obj.Fig)
        try
            p.Geometry = obj.Fig.Position;
        catch
        end
        if isfield(obj.UI, "ActiveOnly") && isvalid(obj.UI.ActiveOnly)
            p.UseActiveViews = logical(obj.UI.ActiveOnly.Value);
        end
        if isfield(obj.UI, "TabGroup") && isvalid(obj.UI.TabGroup)
            p.LastTab = string(obj.UI.TabGroup.SelectedTab.Tag);
        end
        if isfield(obj.UI, "SqlEditor") && isvalid(obj.UI.SqlEditor)
            p.LastSql = string(local_joinlines(obj.UI.SqlEditor.Value));
        end
    end

    obj.Prefs = p;

    try
        setpref(obj.PrefGroup, "Prefs", p);
    catch
    end
end

function s = local_joinlines(v)
    % uitextarea Value is a cellstr (one entry per line); rejoin to one string.
    if iscell(v)
        s = strjoin(string(v), newline);
    else
        s = string(v);
    end
end
