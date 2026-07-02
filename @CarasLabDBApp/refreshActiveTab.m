function refreshActiveTab(obj)
%REFRESHACTIVETAB Reload the current browse tab (no-op on the Custom SQL tab).
%
%   See also CARASLABDBAPP/APPLYFILTERS.

    d = obj.pCurrentTabDef();
    if isempty(d)
        return   % Custom SQL tab (or unknown) — nothing to auto-refresh
    end
    obj.applyFilters();
end
