classdef Roots
    % labclient.Roots  Where the lab database's storage roots are on this computer.
    %   The database stores a file as (storage root, path below it), e.g.
    %   ("nas-main", "G-0421/G-0421_260702_141210/G-0421_extract.mat"); which
    %   folder a root is on each computer is said here, in the settings
    %   (labclient.Settings Roots: Name and Path). A workstation's own data disk
    %   is a root of its own (e.g. "ws-rig2-d"), so files written there are
    %   recorded as soon as they are written.
    %
    %     [root, rel, why] = labclient.Roots.locate(file, s)   % "" root when FILE is under no root
    %     p = labclient.Roots.resolve(root, rel, s)            % "" when ROOT is not mapped here
    %     [ok, why] = labclient.Roots.checkMarker(root, s)
    %     labclient.Roots.writeMarker(folder, name, rootId)
    %
    %   A marker file (.caraslabdb-root.json, holding the root's name and id)
    %   sits at the top of each root. A mapping whose folder holds the marker
    %   of another root is refused, so a mistyped drive letter or a share
    %   mounted at another letter cannot file data under the wrong root.
    %   Paths below a root use forward slashes; on Windows they keep the
    %   spelling the file has on disk.
    %
    %   See also labclient.Settings, labclient.DB.

    properties (Constant)
        MarkerFile = ".caraslabdb-root.json"
    end

    methods (Static)
        function [root, rel, why] = locate(file, s)
            %locate  The storage root FILE is under, and its path below it.
            %   ROOT is "" (and WHY says why) when no root of the settings S
            %   holds FILE, or its folder's marker names another root. The
            %   longest matching root wins (roots may nest).
            arguments
                file (1,1) string
                s (1,1) struct
            end
            root = "";
            rel = "";
            why = "";
            if isempty(s.Roots)
                why = "no storage roots are mapped on this computer";
                return
            end
            f = labclient.Roots.normal(file);
            best = 0;
            for k = 1:numel(s.Roots)
                p = labclient.Roots.normal(s.Roots(k).Path);
                if p == ""; continue; end
                if labclient.Roots.startsWithFolder(f, p) && strlength(p) > best
                    best = strlength(p);
                    root = s.Roots(k).Name;
                    rel = extractAfter(f, strlength(p));
                end
            end
            if root == ""
                why = "it is under none of the mapped storage roots";
                return
            end
            rel = regexprep(rel, '^/+', '');
            if rel == ""
                root = "";
                why = "it is the root folder itself";
                return
            end
            [ok, markerWhy] = labclient.Roots.checkMarker(root, s);
            if ~ok
                why = markerWhy;
                root = "";
                rel = "";
                return
            end
            rel = labclient.Roots.diskSpelling(labclient.Roots.resolve(root, "", s), rel);
        end

        function p = resolve(root, rel, s)
            %resolve  The local path of (ROOT, REL), or "" when ROOT is not mapped on this computer.
            arguments
                root (1,1) string
                rel (1,1) string
                s (1,1) struct
            end
            p = "";
            for k = 1:numel(s.Roots)
                if s.Roots(k).Name == root
                    p = s.Roots(k).Path;
                    break
                end
            end
            if p == "" || rel == ""
                return
            end
            p = string(fullfile(p, strjoin(split(rel, "/"), filesep)));
        end

        function [ok, why] = checkMarker(root, s)
            %checkMarker  True when ROOT's folder holds no marker, or its own.
            %   A folder whose marker names another root is refused; a
            %   folder with no marker is accepted (writeMarker adds one when
            %   the root is mapped in the Database window).
            ok = true;
            why = "";
            folder = labclient.Roots.resolve(root, "", s);
            if folder == ""
                ok = false;
                why = "storage root " + root + " is not mapped on this computer";
                return
            end
            file = fullfile(folder, labclient.Roots.MarkerFile);
            if ~isfile(file)
                return
            end
            try
                m = jsondecode(fileread(file));
                name = string(m.name);
            catch
                ok = false;
                why = "the marker " + string(file) + " cannot be read";
                return
            end
            if name ~= root
                ok = false;
                why = "the folder " + folder + " is storage root " + name + ", not " + root + ...
                    " (its " + labclient.Roots.MarkerFile + " says so): check the mapping";
            end
        end

        function writeMarker(folder, name, rootId)
            %writeMarker  Mark FOLDER as storage root NAME (lab.storage_root ROOTID).
            arguments
                folder (1,1) string
                name (1,1) string
                rootId (1,1) double
            end
            m = struct("name", name, "root_id", rootId, ...
                "written", string(datetime("now", "TimeZone", "local", ...
                    "Format", "yyyy-MM-dd'T'HH:mm:ssXXX")));
            writeJsonFile(fullfile(folder, labclient.Roots.MarkerFile), m);
        end
    end

    methods (Static, Access = private)
        function p = normal(p)
            %normal  P with forward slashes, no trailing slash, and lower case on Windows.
            p = strtrim(string(p));
            p = replace(p, "\", "/");
            p = regexprep(p, '/+$', '');
            if ispc
                p = lower(p);
            end
        end

        function tf = startsWithFolder(f, p)
            %startsWithFolder  F is P or below it (P/...).
            tf = f == p || startsWith(f, p + "/");
        end

        function rel = diskSpelling(folder, rel)
            %diskSpelling  REL with each part spelled as on disk (Windows; elsewhere as given).
            %   The database compares paths exactly, case included, while
            %   Windows does not: a path typed in another case must not
            %   become a second file.
            if ~ispc
                return
            end
            parts = split(rel, "/");
            here = folder;
            for k = 1:numel(parts)
                d = dir(char(here));
                names = string({d.name});
                hit = names(strcmpi(names, parts(k)));
                if isscalar(hit)
                    parts(k) = hit;
                end
                here = fullfile(here, parts(k));
            end
            rel = strjoin(parts, "/");
        end
    end
end
