classdef Hasher
    % labclient.Hasher  The SHA-256 of the files a record names, taken without making anyone wait.
    %   The lab database keeps every file with its SHA-256. A file up to
    %   labclient.Settings.HashInProcessMB is hashed in MATLAB (labclient.fileSha256) as
    %   soon as it is captured; a larger one by a separate process, so the
    %   step that wrote it never waits minutes for it to be hashed:
    %   PowerShell (.NET's SHA-256) on Windows, shasum -a 256 on macOS,
    %   sha256sum on Linux. The job writes its result to a temporary name and
    %   renames it into place, in the outbox's "hashing" folder, so a job
    %   that was stopped leaves no half result and MATLAB can close while it
    %   runs.
    %
    %   A hash is kept only for the bytes that were captured: the file's size
    %   and time must be the same as when the record was captured, before and
    %   after it is hashed. A file that changed in between is not hashed: its
    %   bundle is held (labclient.Outbox) with the reason, for a person to look at.
    %
    %     [h, why] = labclient.Hasher.hashNow(item)  % in MATLAB, when the snapshot still holds
    %     job = labclient.Hasher.start(item, key)    % out of process
    %     [h, state] = labclient.Hasher.poll(job)    % "running" | "done" | "lost" | "failed"
    %     n = labclient.Hasher.work(Budget=seconds)  % every pending bundle: hash, collect, seal
    %
    %   See also labclient.fileSha256, labclient.Outbox, labclient.Bundles, labclient.Sync.

    methods (Static)
        function b = limitBytes(s)
            %limitBytes  Files up to this size are hashed in MATLAB.
            if nargin < 1; s = labclient.Settings.load(); end
            b = s.HashInProcessMB * 2^20;
        end

        function [h, why] = hashNow(it)
            %hashNow  SHA-256 of item IT's file in MATLAB, "" with WHY when its snapshot no longer holds.
            h = "";
            why = labclient.Hasher.changed(it);
            if why ~= ""; return; end
            try
                x = labclient.fileSha256(it.path);
            catch ME
                why = "could not be hashed: " + string(ME.message);
                return
            end
            why = labclient.Hasher.changed(it);   % changed while it was read: the hash is of no captured bytes
            if why == ""; h = x; end
        end

        function why = changed(it)
            %changed  "" when IT's file has the size and time it was captured with, else why not.
            cur = labclient.Bundles.snapshot(it.path);
            if isnan(cur.bytes)
                why = "is no longer there";
            elseif ~labclient.Bundles.sameSnapshot(cur, it)
                why = sprintf("changed after it was captured (%d bytes, %s; captured as %d bytes, %s)", ...
                    cur.bytes, cur.mtime, it.bytes, it.mtime);
            else
                why = "";
            end
        end

        function job = start(it, key)
            %start  Hash item IT's file in a separate process; KEY names the job (bundle id and output number).
            folder = labclient.Hasher.folder();
            out = string(fullfile(folder, key + ".sha256"));
            tmp = string(fullfile(folder, key + ".partial"));
            log = string(fullfile(folder, key + ".log"));
            if isfile(out); delete(out); end
            job = struct("key", key, "path", it.path, "bytes", it.bytes, "mtime", it.mtime, ...
                "out", out, "started_at", labclient.Bundles.now(), "host", labclient.Bundles.host());
            writeJsonFile(fullfile(folder, key + ".job.json"), job);
            pb = java.lang.ProcessBuilder(labclient.Hasher.command());
            env = pb.environment();
            env.put('LABHASH_FILE', char(it.path));
            env.put('LABHASH_TMP', char(tmp));
            env.put('LABHASH_OUT', char(out));
            pb.redirectErrorStream(true);
            pb.redirectOutput(java.io.File(char(log)));
            p = pb.start();
            labclient.Hasher.processes(key, p);
        end

        function [h, state] = poll(job)
            %poll  The result of JOB: "done" (H the hash), "running", "failed" or "lost" (no process and no result).
            h = "";
            if isfile(job.out)
                txt = strtrim(string(fileread(job.out)));
                tok = regexp(char(txt), '^([0-9a-fA-F]{64})', 'tokens', 'once');
                if isempty(tok)
                    state = "failed";
                else
                    h = string(lower(tok{1}));
                    state = "done";
                end
                return
            end
            p = labclient.Hasher.processes(job.key);
            if ~isempty(p)
                if p.isAlive()
                    state = "running";
                else
                    state = "failed";   % ended without writing a result
                end
                return
            end
            % Started by a MATLAB that has closed since: lost when it has
            % had far longer than the file needs (10 MB/s, plus 10 min).
            started = datetime(job.started_at, "InputFormat", labclient.Bundles.TimeFormat, "TimeZone", "local");
            allow = double(job.bytes) / 10e6 + 600;
            if seconds(datetime("now", "TimeZone", "local") - started) > allow
                state = "lost";
            else
                state = "running";
            end
        end

        function n = work(opts)
            %work  Hash what the pending bundles still need, within Budget seconds; seal those complete.
            %   Small files are hashed here, large ones get a job (one at a
            %   time per file); finished jobs are collected. A file that
            %   changed since it was captured holds its bundle. N is the
            %   number of bundles sealed.
            arguments
                opts.Budget (1,1) double = 10
            end
            n = 0;
            t0 = tic;
            limit = labclient.Hasher.limitBytes();
            T = labclient.Outbox.list(State="pending");
            for r = 1:height(T)
                if T.sealed(r); continue; end
                b = labclient.Outbox.read(T.id(r));
                if isempty(b); continue; end
                [b, why, changedAny] = labclient.Hasher.fill(b, limit, t0, opts.Budget);
                if why ~= ""
                    try
                        labclient.Outbox.move(b.bundle_id, "held", Reason=why);
                    catch
                        % replaced or taken by another MATLAB meanwhile: its new capture is looked at next time
                    end
                    continue
                end
                b = labclient.Bundles.seal(b);
                if changedAny || labclient.Bundles.isSealed(b)
                    labclient.Outbox.update(b);
                end
                if labclient.Bundles.isSealed(b)
                    n = n + 1;
                    labclient.Hasher.clearJobs(b.bundle_id);
                end
                if toc(t0) > opts.Budget; break; end
            end
        end

        function clearJobs(id)
            %clearJobs  Delete the out-of-process hash jobs (and their results) of bundle ID.
            %   A bundle replaced by a newer version (labclient.Outbox.put)
            %   must not inherit the hashes of the files it replaced.
            d = dir(fullfile(labclient.Hasher.folder(), string(id) + "_*"));
            for k = 1:numel(d)
                delete(fullfile(d(k).folder, d(k).name));
            end
        end
    end

    methods (Static, Access = private)
        function [b, why, changedAny] = fill(b, limit, t0, budget)
            why = "";
            changedAny = false;
            o = b.record.outputs;
            for k = 1:numel(o)
                if strlength(o(k).sha256) == 64; continue; end
                key = b.bundle_id + "_" + k;
                jobFile = fullfile(labclient.Hasher.folder(), key + ".job.json");
                if isfile(jobFile)
                    job = readJsonFile(jobFile, ErrorOnFail=false);
                    if ~isstruct(job)
                        delete(jobFile);
                        continue
                    end
                    if string(job.path) ~= o(k).path || double(job.bytes) ~= o(k).bytes || string(job.mtime) ~= o(k).mtime
                        % a job of a file this output is not (the bundle was replaced by a newer
                        % version of the record): its result is not this file's
                        for f = reshape(dir(fullfile(labclient.Hasher.folder(), key + ".*")), 1, [])
                            delete(fullfile(f.folder, f.name));
                        end
                        continue
                    end
                    job.out = string(job.out); job.key = string(job.key);
                    job.started_at = string(job.started_at);
                    [h, state] = labclient.Hasher.poll(job);
                    switch state
                        case "done"
                            w = labclient.Hasher.changed(o(k));
                            if w ~= ""
                                why = "Output " + o(k).path + " " + w + ".";
                                return
                            end
                            o(k).sha256 = h;
                            changedAny = true;
                        case {"failed", "lost"}
                            delete(jobFile);   % started again on the next pass
                    end
                    continue
                end
                w = labclient.Hasher.changed(o(k));
                if w ~= ""
                    why = "Output " + o(k).path + " " + w + ".";
                    return
                end
                if o(k).bytes <= limit && toc(t0) <= budget
                    [h, w] = labclient.Hasher.hashNow(o(k));
                    if w ~= ""
                        why = "Output " + o(k).path + " " + w + ".";
                        return
                    end
                    o(k).sha256 = h;
                    changedAny = true;
                elseif o(k).bytes > limit
                    try
                        labclient.Hasher.start(o(k), key);
                    catch ME
                        warning("labclient:Hasher:Start", "Could not start hashing %s: %s", o(k).path, ME.message);
                    end
                end
            end
            b.record.outputs = o;
        end

        function d = folder()
            %folder  Where the out-of-process jobs keep their files.
            d = string(fullfile(labclient.DB.folder(), "hashing"));
            if ~isfolder(d); mkdir(d); end
        end

        function c = command()
            if ispc
                % .NET only, no cmdlet: a PowerShell started by a process whose PSModulePath belongs to
                % another PowerShell (7, say) cannot load the modules Get-FileHash and Move-Item live in.
                % The result file does not exist when the job starts (start deletes it), so Move is a rename.
                script = ['$f = [IO.File]::OpenRead($env:LABHASH_FILE); ' ...
                    'try { $h = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($f)) -replace ''-'', '''').ToLowerInvariant() } finally { $f.Dispose() }; ' ...
                    '[IO.File]::WriteAllText($env:LABHASH_TMP, $h); ' ...
                    '[IO.File]::Move($env:LABHASH_TMP, $env:LABHASH_OUT)'];
                enc = matlab.net.base64encode(unicode2native(script, 'UTF-16LE'));
                c = {'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', ...
                    '-EncodedCommand', enc};
            elseif ismac
                c = {'/bin/sh', '-c', 'shasum -a 256 -- "$LABHASH_FILE" > "$LABHASH_TMP" && mv -f "$LABHASH_TMP" "$LABHASH_OUT"'};
            else
                c = {'/bin/sh', '-c', 'sha256sum -- "$LABHASH_FILE" > "$LABHASH_TMP" && mv -f "$LABHASH_TMP" "$LABHASH_OUT"'};
            end
        end

        function p = processes(key, proc)
            %processes  The process of job KEY started by this MATLAB ([] when none); with PROC, note it.
            persistent map
            if isempty(map); map = containers.Map('KeyType', 'char', 'ValueType', 'any'); end
            key = char(key);
            if nargin > 1
                map(key) = proc;
                p = proc;
                return
            end
            if isKey(map, key)
                p = map(key);
            else
                p = [];
            end
        end
    end
end
