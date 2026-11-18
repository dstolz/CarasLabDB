classdef SubjectCache
    % labclient.SubjectCache  What the database last said about each subject, kept on this computer for a rig that must not wait for it.
    %   A behavior rig decides things about an animal as it starts a
    %   session (is it endpointed? its last weight? its baseline weight?)
    %   and may not wait for, or fail on, a server. The answers are kept in
    %   one JSON file in this computer's client folder
    %   (labclient.DB.folder(), subject_cache.json), per subject id:
    %
    %     the lab.subject_current row: is_endpointed, endpoint_at,
    %       latest_weight_g, latest_weight_at, project (the project id), sex,
    %       species (the code), date_of_birth;
    %     the subject variable "baseline weight" (grams) when it is set;
    %     as_of, when the database said so.
    %
    %     T = labclient.SubjectCache.status(ids)       % the file only; never the network
    %     r = labclient.SubjectCache.refresh(ids, Budget=15)   % ask the database, rewrite the file
    %
    %   status reads only the file, so it is as fast as a file read and the
    %   same with the database off. T has a row per id, in the order given:
    %   subject_id, known (the database had the subject when it was asked),
    %   is_endpointed (false when not known: test known first),
    %   endpoint_at, latest_weight_g, latest_weight_at, project, sex,
    %   species, date_of_birth, baseline_weight_g and as_of. Whatever is not
    %   known is missing: NaN, NaT or missing text. A subject never asked
    %   about has as_of NaT.
    %
    %   refresh probes the server first (labclient.DB.connect, bounded by
    %   the settings' ConnectTimeout and by Budget), then reads the rows of
    %   IDS (and the baseline weights) through the backend, merges them into
    %   the file (the entries of other subjects stay) and writes it
    %   atomically, so a reader never sees half a file. It never throws: R
    %   says what happened (Connected, Refreshed, NotFound, Message,
    %   AsOf). Nothing is changed when the database cannot be reached. A
    %   subject the database does not have is stored as not found (known
    %   false, as_of set) so a rig can tell "asked, absent" from "never asked".
    %
    %   See also labclient.DB, labclient.Backend.subjectCurrent.

    properties (Constant)
        Format = "caraslabdb-subject-cache/1"
        BaselineVariable = "baseline weight"
        FileName = "subject_cache.json"
    end

    methods (Static)
        function f = file()
            %file  The cache file of this computer.
            f = string(fullfile(labclient.DB.folder(), labclient.SubjectCache.FileName));
        end

        function T = status(ids)
            %status  The cached state of subjects IDS (a table, a row per id in order); reads only the file.
            arguments
                ids (:,1) string
            end
            E = labclient.SubjectCache.readEntries();
            n = numel(ids);
            known = false(n, 1); endpointed = false(n, 1);
            endpointAt = NaT(n, 1, "TimeZone", "local");
            weight = NaN(n, 1); weightAt = NaT(n, 1, "TimeZone", "local");
            project = strings(n, 1); sex = strings(n, 1); species = strings(n, 1);
            project(:) = missing; sex(:) = missing; species(:) = missing;
            dob = NaT(n, 1); baseline = NaN(n, 1); asOf = NaT(n, 1, "TimeZone", "local");
            for k = 1:n
                if ~isKey(E, char(ids(k))); continue; end
                e = E(char(ids(k)));
                asOf(k) = labclient.SubjectCache.timeFrom(e.as_of);
                baseline(k) = labclient.SubjectCache.numberFrom(e.baseline_weight_g);
                known(k) = e.found;
                if ~e.found; continue; end
                endpointed(k) = e.is_endpointed;
                endpointAt(k) = labclient.SubjectCache.timeFrom(e.endpoint_at);
                weight(k) = labclient.SubjectCache.numberFrom(e.latest_weight_g);
                weightAt(k) = labclient.SubjectCache.timeFrom(e.latest_weight_at);
                project(k) = labclient.SubjectCache.textFrom(e.project);
                sex(k) = labclient.SubjectCache.textFrom(e.sex);
                species(k) = labclient.SubjectCache.textFrom(e.species);
                dob(k) = labclient.SubjectCache.dateFrom(e.date_of_birth);
            end
            T = table(ids, known, endpointed, endpointAt, weight, weightAt, project, sex, species, dob, ...
                baseline, asOf, 'VariableNames', {'subject_id', 'known', 'is_endpointed', 'endpoint_at', ...
                'latest_weight_g', 'latest_weight_at', 'project', 'sex', 'species', 'date_of_birth', ...
                'baseline_weight_g', 'as_of'});
        end

        function r = refresh(ids, opts)
            %refresh  Ask the database about subjects IDS and rewrite the cache file; never throws.
            %   R: Connected (the database answered), Refreshed (subjects
            %   stored), NotFound (ids the database does not have), Message,
            %   AsOf (text of the time the answers are from, "" when none).
            arguments
                ids (:,1) string
                opts.Budget (1,1) double {mustBePositive} = 15
            end
            r = struct("Connected", false, "Refreshed", 0, "NotFound", strings(0, 1), "Message", "", "AsOf", "");
            try
                ids = unique(strtrim(ids(strlength(strtrim(ids)) > 0)), "stable");
                t0 = tic;
                s = labclient.Settings.load();
                if ~labclient.Sync.enabled(s)
                    r.Message = "The lab database is turned off on this computer.";
                    return
                end
                b = labclient.DB.connect(MaxWait=max(2, min(opts.Budget, s.ConnectTimeout)));
                if isempty(b)
                    r.Message = labclient.DB.status().Message;
                    return
                end
                r.Connected = true;
                if isempty(ids)
                    r.Message = "No subject was asked about.";
                    return
                end
                asOf = labclient.Bundles.now();
                T = b.subjectCurrent(ids);
                baseline = [];
                if toc(t0) < opts.Budget
                    try
                        baseline = b.variableValues(labclient.SubjectCache.BaselineVariable, "subject");
                    catch ME
                        if endsWith(string(ME.identifier), ":Unreachable"); rethrow(ME); end
                        baseline = [];   % no such variable, or not readable: the baselines stay as they were
                        r.Message = "The baseline weights could not be read: " + string(ME.message);
                    end
                else
                    r.Message = "The time budget ran out before the baseline weights were asked for.";
                end
                E = labclient.SubjectCache.readEntries();   % again: another MATLAB may have written since
                for id = reshape(ids, 1, [])
                    old = labclient.SubjectCache.blank(id);
                    if isKey(E, char(id)); old = E(char(id)); end
                    e = labclient.SubjectCache.blank(id);
                    e.as_of = asOf;
                    row = [];
                    if ~isempty(T) && height(T) > 0
                        row = find(string(T.subject_id) == id, 1);
                    end
                    if isempty(row)
                        r.NotFound(end + 1, 1) = id; %#ok<AGROW>
                        e.baseline_weight_g = old.baseline_weight_g;
                    else
                        e.found = true;
                        e.is_endpointed = labclient.SubjectCache.flagFrom(T.is_endpointed(row));
                        e.endpoint_at = labclient.SubjectCache.timeText(T.endpoint_at(row));
                        e.latest_weight_g = labclient.SubjectCache.numberFrom(T.latest_weight_g(row));
                        e.latest_weight_at = labclient.SubjectCache.timeText(T.latest_weight_at(row));
                        e.project = labclient.SubjectCache.textFrom(T.project_id(row));
                        e.sex = labclient.SubjectCache.textFrom(T.sex(row));
                        e.species = labclient.SubjectCache.textFrom(T.species_code(row));
                        e.date_of_birth = labclient.SubjectCache.dateText(T.date_of_birth(row));
                        e.baseline_weight_g = old.baseline_weight_g;
                    end
                    if istable(baseline)
                        j = find(string(baseline.entity_id) == id, 1);
                        e.baseline_weight_g = NaN;
                        if ~isempty(j)
                            e.baseline_weight_g = labclient.SubjectCache.baselineOf(baseline, j);
                        end
                    end
                    E(char(id)) = e;
                    r.Refreshed = r.Refreshed + 1;
                end
                labclient.SubjectCache.writeEntries(E);
                r.AsOf = asOf;
                if r.Message == ""
                    r.Message = sprintf("%d subject(s) refreshed, %d not in the database.", r.Refreshed, numel(r.NotFound));
                end
            catch ME
                if endsWith(string(ME.identifier), ":Unreachable") || contains(lower(string(ME.message)), ...
                        ["timeout", "timed out", "connection"])
                    try
                        labclient.DB.lost(ME.message);
                    catch
                    end
                end
                r.Message = "The subjects could not be refreshed: " + string(ME.message);
            end
        end
    end

    methods (Static, Access = private)
        function e = blank(id)
            e = struct("subject_id", string(id), "found", false, "as_of", "", "is_endpointed", false, ...
                "endpoint_at", "", "latest_weight_g", NaN, "latest_weight_at", "", "project", "", ...
                "sex", "", "species", "", "date_of_birth", "", "baseline_weight_g", NaN);
        end

        function E = readEntries()
            %readEntries  The cache file as a containers.Map of subject id to entry (empty when none or unreadable).
            E = containers.Map('KeyType', 'char', 'ValueType', 'any');
            f = labclient.SubjectCache.file();
            if ~isfile(f); return; end
            x = readJsonFile(f, ErrorOnFail=false);
            if ~isstruct(x) || ~isfield(x, "subjects") || isempty(x.subjects) || ~isstruct(x.subjects); return; end
            for k = 1:numel(x.subjects)
                s = x.subjects(k);
                if ~isfield(s, "subject_id") || isempty(s.subject_id); continue; end
                e = labclient.SubjectCache.blank(string(s.subject_id));
                for fn = reshape(string(fieldnames(e)), 1, [])
                    if ~isfield(s, fn) || isempty(s.(fn)); continue; end
                    v = s.(fn);
                    switch fn
                        case "found";                                       e.(fn) = logical(v);
                        case "is_endpointed";                               e.(fn) = logical(v);
                        case {"latest_weight_g", "baseline_weight_g"};      e.(fn) = double(v);
                        otherwise;                                          e.(fn) = string(v);
                    end
                end
                E(char(e.subject_id)) = e;
            end
        end

        function writeEntries(E)
            ks = keys(E);
            rows = cell(1, numel(ks));
            for k = 1:numel(ks)
                e = E(ks{k});
                e.subject_id = char(e.subject_id);
                for fn = ["as_of" "endpoint_at" "latest_weight_at" "project" "sex" "species" "date_of_birth"]
                    e.(fn) = char(e.(fn));
                end
                rows{k} = e;
            end
            x = struct("format", labclient.SubjectCache.Format, "written_at", char(labclient.Bundles.now()), ...
                "subjects", {rows});
            writeJsonFile(labclient.SubjectCache.file(), x);
        end

        function v = baselineOf(T, j)
            %baselineOf  The number of row J of a variableValues table (value_num, else the text read as a number).
            v = NaN;
            if ismember("value_num", string(T.Properties.VariableNames))
                v = labclient.SubjectCache.numberFrom(T.value_num(j));
            end
            if isnan(v) && ismember("value", string(T.Properties.VariableNames))
                v = labclient.SubjectCache.numberFrom(T.value(j));
            end
        end

        function v = numberFrom(x)
            %numberFrom  X (a number, numeric text, [] or missing) as a double, NaN when it is none.
            v = NaN;
            if isempty(x); return; end
            if isstring(x) || ischar(x) || iscellstr(x)
                x = str2double(string(x));
            end
            if isnumeric(x) && isscalar(x)
                v = double(x);
            end
        end

        function t = textFrom(x)
            %textFrom  X as a string; "" for [] and missing.
            t = "";
            if isempty(x); return; end
            if iscell(x); x = x{1}; end
            t = string(x);
            if ismissing(t); t = ""; end
        end

        function tf = flagFrom(x)
            tf = false;
            if isempty(x) || (isnumeric(x) && isnan(x)); return; end
            if isstring(x) || ischar(x); x = any(lower(string(x)) == ["true" "t" "1"]); end
            tf = logical(x(1));
        end

        function t = timeText(x)
            %timeText  A datetime (zoned or not; an unzoned one is this computer's) as labclient.Bundles text, "" for none.
            t = "";
            if isempty(x) || (isstring(x) && ismissing(x)); return; end
            if ~isdatetime(x)
                try
                    x = datetime(string(x), "TimeZone", "UTC");
                catch
                    return
                end
            end
            if isnat(x); return; end
            if isempty(x.TimeZone); x.TimeZone = "local"; end
            t = labclient.Bundles.timeText(x);
        end

        function t = dateText(x)
            %dateText  A date as yyyy-MM-dd, "" for none.
            t = "";
            if isempty(x) || (isstring(x) && ismissing(x)); return; end
            if ~isdatetime(x)
                try
                    x = datetime(string(x), "InputFormat", "yyyy-MM-dd");
                catch
                    return
                end
            end
            if isnat(x); return; end
            x.TimeZone = "";
            x.Format = "yyyy-MM-dd";
            t = string(x);
        end

        function dt = timeFrom(txt)
            %timeFrom  Text from timeText as a datetime in this computer's zone (NaT for "").
            dt = NaT("TimeZone", "local");
            txt = string(txt);
            if isempty(txt) || txt == ""; return; end
            try
                dt = datetime(txt, "InputFormat", labclient.Bundles.TimeFormat, "TimeZone", "local");
            catch
            end
        end

        function dt = dateFrom(txt)
            dt = NaT;
            txt = string(txt);
            if isempty(txt) || txt == ""; return; end
            try
                dt = datetime(txt, "InputFormat", "yyyy-MM-dd");
            catch
            end
        end
    end
end
