function k = pathKey(p)
%pathKey  Paths as comparable keys: "/" separators, no trailing separator, lower case on Windows.
%   K = labclient.pathKey(P) for a string array P. Windows paths ignore
%   case, so two spellings of one folder give one key.
%
%   See also labclient.Roots, labclient.Sync.

k = string(p);
k = replace(k, "\", "/");
k = regexprep(k, "/+$", "");
if ispc
    k = lower(k);
end
end
