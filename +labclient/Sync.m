classdef Sync
    % labclient.Sync  Send what waits in the outbox to the lab database, one record at a time, never in the way.
    %   The apps start one timer per MATLAB (start): every few seconds it
    %   finishes the hashes still needed (labclient.Hasher), gives back the claims
    %   of a MATLAB that stopped, and, when the database answers within 2 s,
    %   sends one record (labclient.Outbox, oldest first, a record after those it
    %   names in "after"). While a toolbox has a run going that must not be
    %   disturbed (suspend), it waits. flush sends as many as a time budget
    %   allows: a script calls it, and so can a toolbox at the end of a run.
    %
    %   Sending a record (sendBundle):
    %     - the dataset's session is found by the id its session file holds,
    %       or created: in the folder's storage root, for the subject the
    %       session file names (labclient.SubjectAssignDialog) or else the one the
    %       folder's name gives. A subject that is not in the database holds
    %       the record until a person creates it or assigns the session to
    %       another (the folder is never renamed);
    %     - the person who did the work is named: the record's performer,
    %       found by id or email; else, for a record captured under this
    %       computer's login, the person the connection is. A record captured
    %       under another login is held until a person chooses "Send as me"
    %       in the Database window (the database stamps the real login);
    %     - every input whose file the database has is an edge; one it does
    %       not have yet is sent later as an "edges" record; one this
    %       computer cannot name is listed in attributes.unresolved_inputs,
    %       never guessed from its path;
    %     - CarasLabDB.recordEvent writes it once, in one transaction: sent
    %       again, it is "existing".
    %   A connection that breaks or times out puts the record back to wait
    %   (labclient.DB.lost); the same id with other content is held (a conflict);
    %   anything else the database refuses fails, with its reason. Nothing
    %   is renamed, dropped or merged.
    %
    %     labclient.Sync.start(Parent=fig)     % the timer (once per MATLAB)
    %     r = labclient.Sync.useManual()       % tests: no timer until R is cleared
    %     r = labclient.Sync.suspend()         % no sending until R is cleared
    %     res = labclient.Sync.flush(Budget=10)
    %     res = labclient.Sync.sendNext(backend)
    %     T = labclient.Sync.subjectHolds()    % the records waiting for a subject
    %     labclient.Sync.release(folderId, subjectId, datasets)
    %     tf = labclient.Sync.enabled()        % the settings say Enabled and CarasLabDB can be used
    %     labclient.Sync.registerTool(name, hooks, TakesUntagged=false)   % see "Tools and their hooks"
    %
    %   Sending a "files" record (labclient.Bundles.files) registers copies of
    %   files an event produced, once each, after the event; an item that
    %   names the artifact it Replaces (new bytes at the same path of a file
    %   of an event already sent) records that file as replaced by it.
    %   A "husbandry" event goes as any other (Detail measure, weight_g,
    %   water_ml, health_status; a column not measured is not sent).
    %   A record whose raw files are byte for byte files of a recording or
    %   behavior event already in the database is recorded as a copy of that
    %   event's files, whichever toolbox sent it first.
    %
    %   Tools and their hooks. A record about a dataset FOLDER (the folder
    %   of one recording, say) needs the toolbox that made it for three
    %   things only that toolbox knows: reading the dataset's session file,
    %   noting a copy of another session in it, and noting the subject a
    %   person assigned. A toolbox registers them once per MATLAB, under a
    %   name of its own choosing:
    %
    %     labclient.Sync.registerTool("my_toolbox", struct( ...
    %         "readSession",   @(folder, name) ..., ...   % struct: session_id, subject_id, recording_event_id
    %         "copyOfSession", @(folder, name, sessionId, kind, eventId) ..., ...
    %         "assignSubject", @(folder, name, subjectId) ...))
    %
    %   A record carries its tool in dataset.tool. This package knows no
    %   toolbox by name: a dataset record that names no tool (written before
    %   records named their tool; labclient.Bundles.Untagged) belongs to the
    %   toolbox that says so when it registers (TakesUntagged=true), and
    %   waits untouched while none has.
    %
    %   THE SHARED OUTBOX RULE: several MATLABs (of different toolboxes) may
    %   run over one outbox; a process never claims a record it cannot fully
    %   send, so a record whose tool is not registered here is left untouched
    %   (not claimed, not failed) for a process that has it. A record with no
    %   dataset folder needs no hooks and any process sends it. The claim
    %   itself is a rename that one process wins; a claim keeps a heartbeat
    %   (kept fresh while the record is worked on) and is given back when
    %   its MATLAB stopped; sending a record twice writes it once.
    %
    %   A record with no dataset can name its subject directly
    %   (labclient.Bundles.event, SubjectId=): it is sent for that subject
    %   with no session. A subject the database does not have holds it, as
    %   it holds a dataset's records (subjectHolds, release).
    %
    %   See also labclient.Outbox, labclient.DB, labclient.SubjectAssignDialog, labclient.Panel.

    properties (Constant)
        Period = 15          % seconds between ticks
        TickWait = 2         % seconds a tick waits for the server at most
        EdgesRetry = 600     % seconds an edges record waiting for its files steps aside (unless a record was sent since)
        NeedsSubject = "needs_subject"
        NeedsLogin = "needs_login"       % captured under another login: a person must say "send as me"
        OnBehalf = "on_behalf"
        Transient = ["CarasLabDB:transactionInterrupted" "CarasLabDB:connectionFailed"]
    end

    methods (Static)
        function start(opts)
            %start  The drain timer of this MATLAB (started once); PARENT is the app that may show the subject dialog.
            %   IfEnabled=true starts it only when the database is turned on
            %   here (the apps; the Database window starts it when it is).
            arguments
                opts.Parent = []
                opts.IfEnabled (1,1) logical = false
            end
            if opts.IfEnabled && ~labclient.Sync.enabled(); return; end
            st = labclient.Sync.state();
            if st.Manual; return; end   % useManual: the tests send by hand
            if ~isempty(opts.Parent); st.Parent = opts.Parent; end
            if ~isempty(st.Timer) && isvalid(st.Timer)
                labclient.Sync.state(st);
                return
            end
            t = timer("Name", "labclient.Sync", "Period", labclient.Sync.Period, "StartDelay", 5, ...
                "ExecutionMode", "fixedSpacing", "BusyMode", "drop", ...
                "TimerFcn", @(~, ~) labclient.Sync.tick());
            st.Timer = t;
            labclient.Sync.state(st);
            start(t);
        end

        function stop()
            %stop  Stop the drain timer.
            st = labclient.Sync.state();
            if ~isempty(st.Timer) && isvalid(st.Timer)
                stop(st.Timer);
                delete(st.Timer);
            end
            st.Timer = [];
            labclient.Sync.state(st);
        end

        function tf = enabled(s)
            %enabled  True when records are to be kept and sent for the lab database on this computer.
            %   The settings say Enabled and the CarasLabDB class can be
            %   used (not asked while a test backend stands in for it).
            if nargin < 1; s = labclient.Settings.load(); end
            tf = s.Enabled && (labclient.DB.hasFactory() || labclient.CarasBackend.hasClass());
        end

        function registerTool(name, hooks, opts)
            %registerTool  Say how this MATLAB's toolbox NAME reads and writes its datasets' session files.
            %   HOOKS is a struct of function handles: readSession(folder,
            %   name) returning a struct with session_id, subject_id and
            %   recording_event_id (strings, "" for none);
            %   copyOfSession(folder, name, sessionId, kind, eventId) and
            %   assignSubject(folder, name, subjectId). Registering again
            %   replaces the registration (hooks and TakesUntagged). Records
            %   of datasets of NAME are sent only by a MATLAB that registered
            %   it (see the class help).
            %
            %   TakesUntagged=true: NAME also sends, with these hooks, the
            %   dataset records that name no tool (labclient.Bundles.Untagged:
            %   written before records named their tool). Only the toolbox
            %   that wrote such records says so. One tool per MATLAB can:
            %   another is refused (labclient:Sync:UntaggedTaken), since no
            %   record may be sent through hooks that are not its own.
            arguments
                name (1,1) string {mustBeNonzeroLengthText}
                hooks (1,1) struct
                opts.TakesUntagged (1,1) logical = false
            end
            if name == labclient.Bundles.Untagged
                error("labclient:Sync:BadName", ...
                    "%s is not a tool's name: it stands for the records that name no tool.", name);
            end
            need = ["readSession" "copyOfSession" "assignSubject"];
            for f = need
                if ~isfield(hooks, f) || ~isa(hooks.(f), "function_handle")
                    error("labclient:Sync:BadHooks", "The hooks of tool %s must have a function handle %s.", name, f);
                end
            end
            if opts.TakesUntagged
                other = labclient.Sync.untaggedTool();
                if other ~= "" && other ~= name
                    error("labclient:Sync:UntaggedTaken", ...
                        "The dataset records that name no tool are tool %s's in this MATLAB already: %s cannot take them too.", ...
                        other, name);
                end
            end
            R = labclient.Sync.registry();
            R.(matlab.lang.makeValidName(name)) = struct("name", name, "untagged", opts.TakesUntagged, ...
                "hooks", struct("readSession", hooks.readSession, "copyOfSession", hooks.copyOfSession, ...
                "assignSubject", hooks.assignSubject));
            labclient.Sync.registry(R);
        end

        function unregisterTool(name)
            %unregisterTool  Forget tool NAME's hooks in this MATLAB.
            arguments
                name (1,1) string
            end
            R = labclient.Sync.registry();
            key = matlab.lang.makeValidName(name);
            if isfield(R, key)
                R = rmfield(R, key);
                labclient.Sync.registry(R);
            end
        end

        function tf = hasTool(name)
            %hasTool  True when tool NAME is registered in this MATLAB ("" needs none: always true).
            %   labclient.Bundles.Untagged: true when a tool registered here
            %   takes the dataset records that name no tool.
            name = string(name);
            if name == labclient.Bundles.Untagged
                tf = labclient.Sync.untaggedTool() ~= "";
                return
            end
            tf = name == "" || isfield(labclient.Sync.registry(), matlab.lang.makeValidName(name));
        end

        function name = untaggedTool()
            %untaggedTool  The tool registered here that takes the dataset records naming no tool ("" when none).
            name = "";
            R = labclient.Sync.registry();
            for f = reshape(string(fieldnames(R)), 1, [])
                if R.(f).untagged
                    name = string(R.(f).name);
                    return
                end
            end
        end

        function names = tools()
            %tools  The tools registered in this MATLAB.
            R = labclient.Sync.registry();
            names = strings(1, 0);
            for f = reshape(string(fieldnames(R)), 1, [])
                names(end + 1) = string(R.(f).name); %#ok<AGROW>
            end
        end

        function h = hooks(name)
            %hooks  The hooks of tool NAME (labclient:Sync:NoTool when it is not registered here).
            %   labclient.Bundles.Untagged gives the hooks of the tool that
            %   takes the dataset records naming no tool.
            name = string(name);
            if name == labclient.Bundles.Untagged
                name = labclient.Sync.untaggedTool();
                if name == ""
                    error("labclient:Sync:NoTool", ...
                        "No tool running in this MATLAB takes the dataset records that name no tool: they wait for one that does.");
                end
            end
            R = labclient.Sync.registry();
            key = matlab.lang.makeValidName(name);
            if name == "" || ~isfield(R, key)
                error("labclient:Sync:NoTool", ...
                    "The tool %s is not running in this MATLAB: its datasets' records wait for it.", name);
            end
            h = R.(key).hooks;
        end

        function r = useManual()
            %useManual  No timer until R is cleared (tests: they call tick, flush and sendNext themselves).
            labclient.Sync.stop();
            st = labclient.Sync.state();
            st.Manual = true;
            st.Offered = strings(1, 0);
            st.LastSent = NaT("TimeZone", "local");
            labclient.Sync.state(st);
            r = onCleanup(@() labclient.Sync.endManual());
        end

        function r = suspend()
            %suspend  No sending until R is cleared (a run that must not be disturbed is going).
            st = labclient.Sync.state();
            st.Suspended = st.Suspended + 1;
            labclient.Sync.state(st);
            r = onCleanup(@() labclient.Sync.resume());
        end

        function tf = suspended()
            st = labclient.Sync.state();
            tf = st.Suspended > 0;
        end

        function tick()
            %tick  One pass of the timer: hashes, stale claims, and one record sent when the server answers.
            try
                if ~labclient.Sync.enabled() || labclient.Sync.suspended(); return; end
                labclient.Outbox.recoverStale();
                sealed = labclient.Hasher.work(Budget=1);
                if isempty(labclient.Sync.nextIds())
                    if sealed > 0; labclient.DB.outboxChanged(); end
                    return
                end
                b = labclient.DB.connect(MaxWait=labclient.Sync.TickWait);
                if isempty(b); return; end
                labclient.Sync.sendNext(b);
                labclient.Sync.offerSubjects();
            catch ME
                st = labclient.Sync.state();
                if ~st.Warned
                    warning("labclient:Sync:Tick", "Sending to the lab database stopped for now: %s", ME.message);
                    st.Warned = true;
                    labclient.Sync.state(st);
                end
            end
        end

        function res = flush(opts)
            %flush  Send what can be sent within Budget seconds; RES counts sent, waiting, held, failed.
            arguments
                opts.Budget (1,1) double {mustBeNonnegative} = 10
            end
            res = struct("sent", 0, "pending", 0, "held", 0, "failed", 0, "message", "");
            if ~labclient.Sync.enabled()
                res.message = "The lab database is turned off on this computer.";
                return
            end
            t0 = tic;
            labclient.Outbox.recoverStale();
            labclient.Hasher.work(Budget=max(0, opts.Budget / 2));
            if ~isempty(labclient.Sync.nextIds())
                b = labclient.DB.connect(MaxWait=max(2, min(5, opts.Budget)));
                if isempty(b)
                    res.message = labclient.DB.status().Message;
                else
                    while toc(t0) < opts.Budget
                        r = labclient.Sync.sendNext(b);
                        if r.outcome == "none"; break; end
                        if r.outcome == "done"; res.sent = res.sent + 1; end
                        if r.outcome == "pending"; break; end   % the server stopped answering
                    end   % ("waiting": an edges record whose files are not there yet steps aside)
                end
            end
            c = labclient.Outbox.counts();
            res.pending = c.pending + c.claimed;
            res.held = c.held;
            res.failed = c.failed;
            labclient.DB.outboxChanged();
        end

        function r = sendNext(b)
            %sendNext  Claim and send the next record that may go; R.outcome "none" when nothing may.
            r = struct("id", "", "outcome", "none", "reason", "");
            for id = labclient.Sync.nextIds()
                claim = labclient.Outbox.claim(id);
                if isempty(claim); continue; end   % another MATLAB took it
                r = labclient.Sync.sendClaimed(b, claim);
                labclient.DB.outboxChanged();
                return
            end
        end

        function T = subjectHolds()
            %subjectHolds  The records held for a subject: folder_id, name, folder, bundle_id, tool (a row each).
            %   A dataset's record: folder_id is the subject its folder's
            %   name gives, name and folder the dataset's, tool its tool
            %   (labclient.Bundles.Untagged when it names none). A
            %   record of no dataset that names its subject
            %   (labclient.Bundles.event, SubjectId=): folder_id is that
            %   subject id, folder and tool "", name says what the record is
            %   ("husbandry 2026-11-17").
            T = table(strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), ...
                'VariableNames', {'folder_id', 'name', 'folder', 'bundle_id', 'tool'});
            H = labclient.Outbox.list(State="held");
            for k = 1:height(H)
                n = labclient.Outbox.note(H.id(k), "held");
                if ~any(n.flags == labclient.Sync.NeedsSubject); continue; end
                b = labclient.Outbox.read(H.id(k));
                if isempty(b) || b.type ~= "event"; continue; end
                d = b.record.dataset;
                if string(d.folder) ~= ""
                    row = table(string(d.subject_folder_id), string(d.name), string(d.folder), b.bundle_id, ...
                        labclient.Bundles.toolOf(b), 'VariableNames', T.Properties.VariableNames);
                else
                    nm = string(b.record.event.event_type) + " " + extractBefore(string(b.record.event.occurred_at) + "          ", 11);
                    row = table(string(b.record.subject_id), strtrim(nm), "", b.bundle_id, "", ...
                        'VariableNames', T.Properties.VariableNames);
                end
                T = [T; row]; %#ok<AGROW>
            end
        end

        function [t, c] = datasetText(P)
            %datasetText  Where a dataset's records stand: "4 sent, 1 to send, 1 needs you".
            %   P is what a toolbox keeps of the records it captured for one
            %   dataset: a scalar struct with one member per record, each a
            %   struct with the record's event_id (a member without one is
            %   skipped). C counts sent, waiting, need (held or failed),
            %   discarded and elsewhere (no record in this computer's outbox:
            %   captured while the database was off, or on another computer).
            %   "" when no record has an event id.
            c = struct("sent", 0, "waiting", 0, "need", 0, "discarded", 0, "elsewhere", 0);
            t = "";
            if ~isstruct(P) || ~isscalar(P); return; end
            any_ = false;
            for k = string(fieldnames(P)).'
                r = P.(k);
                if ~isstruct(r) || ~isscalar(r) || ~isfield(r, "event_id"); continue; end
                any_ = true;
                switch labclient.Outbox.stateOf(string(r.event_id))
                    case "done";                  c.sent = c.sent + 1;
                    case {"pending", "claimed"};  c.waiting = c.waiting + 1;
                    case {"held", "failed"};      c.need = c.need + 1;
                    case "discarded";             c.discarded = c.discarded + 1;
                    otherwise;                    c.elsewhere = c.elsewhere + 1;
                end
            end
            if ~any_; return; end
            parts = strings(1, 0);
            if c.sent > 0; parts(end + 1) = c.sent + " sent"; end
            if c.waiting > 0; parts(end + 1) = c.waiting + " to send"; end
            if c.need > 0; parts(end + 1) = c.need + labclient.Sync.plural(c.need, " needs you", " need you"); end
            if c.discarded > 0; parts(end + 1) = c.discarded + " discarded"; end
            if c.elsewhere > 0; parts(end + 1) = c.elsewhere + " not recorded here"; end
            t = strjoin(parts, ", ");
        end

        function release(folderId, subjectId, datasets)
            %release  Assign subject SUBJECTID to the held records of DATASETS (a subjectHolds table) and send them again.
            %   FOLDERID is the subject id the records name (a dataset's
            %   folder name gives it; a record of no dataset states it). The
            %   records held for it that are among DATASETS go back to wait:
            %     - a dataset's record (folder ~= ""): SUBJECTID is noted in
            %       its session file through its tool's assignSubject hook
            %       (labclient:Sync:NoTool when this MATLAB does not run that
            %       tool; a row that names no tool is the tool's that takes
            %       the records naming none); the folder is not renamed;
            %     - a record of no dataset (folder == "", matched by its
            %       bundle_id): its subject id is rewritten to SUBJECTID
            %       (the old one is kept in the event's attributes as
            %       subject_assigned_from) and the record sealed again.
            %   DATASETS needs the columns name and folder, and bundle_id and
            %   tool for those two kinds (as subjectHolds gives them).
            subjectId = string(subjectId);
            folderId = string(folderId);
            vars = string(datasets.Properties.VariableNames);
            hasTool = ismember("tool", vars);
            hasBundle = ismember("bundle_id", vars);
            for k = 1:height(datasets)
                if string(datasets.folder(k)) == ""; continue; end
                tool = labclient.Bundles.Untagged;
                if hasTool && string(datasets.tool(k)) ~= ""; tool = string(datasets.tool(k)); end
                h = labclient.Sync.hooks(tool);
                h.assignSubject(datasets.folder(k), datasets.name(k), subjectId);
            end
            T = labclient.Sync.subjectHolds();
            T = T(T.folder_id == folderId, :);
            isDs = T.folder ~= "";
            keep = isDs & ismember(labclient.pathKey(T.folder), ...
                labclient.pathKey(string(datasets.folder(string(datasets.folder) ~= ""))));
            if hasBundle
                keep = keep | (~isDs & ismember(T.bundle_id, string(datasets.bundle_id)));
            end
            for id = reshape(T.bundle_id(keep & ~isDs), 1, [])
                labclient.Sync.retarget(id, subjectId);
            end
            for id = reshape(T.bundle_id(keep), 1, [])
                labclient.Outbox.move(id, "pending", Reason="subject " + subjectId + " assigned");
            end
            labclient.DB.outboxChanged();
        end

        function r = sendClaimed(be, claim)
            %sendClaimed  Send the claimed record CLAIM through backend BE and end the claim.
            r = struct("id", claim.id, "outcome", "", "reason", "");
            note = labclient.Outbox.note(claim.id, "claimed");
            % What a person decided (send as me) stays; what the last try
            % found missing is found again by the next.
            keep = reshape(setdiff(note.flags, [labclient.Sync.NeedsSubject, labclient.Sync.NeedsLogin], "stable"), 1, []);
            flags = strings(1, 0);
            st = labclient.Sync.state();
            st.Claim = claim;
            labclient.Sync.state(st);
            clearClaim = onCleanup(@() labclient.Sync.endClaim());
            try
                b = labclient.Outbox.read(claim.id);
                if b.type == "edges"
                    [state, reason] = labclient.Sync.sendEdges(be, b);
                elseif b.type == "files"
                    [state, reason] = labclient.Sync.sendFiles(be, b);
                else
                    [state, reason, flags] = labclient.Sync.sendEvent(be, b, note);
                end
            catch ME
                if string(ME.identifier) == "labclient:Sync:NoTool"
                    state = "pending";
                    reason = "waiting: " + string(ME.message);
                else
                    [state, reason] = labclient.Sync.classify(ME);
                    if state == "pending"; labclient.DB.lost(ME.message); end
                end
            end
            clear clearClaim
            labclient.Outbox.finish(claim, state, Reason=reason, ...
                Flags=reshape(unique([keep, reshape(string(flags), 1, [])], "stable"), 1, []));
            r.outcome = state;
            if state == "pending" && startsWith(reason, "waiting")
                r.outcome = "waiting";
            end
            if state == "done"
                st = labclient.Sync.state();
                st.LastSent = datetime("now", "TimeZone", "local");
                labclient.Sync.state(st);
            end
            r.reason = reason;
        end
    end

    methods (Static, Access = private)
        function R = registry(new)
            %registry  The tools registered in this MATLAB (a struct keyed by valid tool names).
            persistent r
            if isempty(r); r = struct(); end
            if nargin > 0; r = new; end
            R = r;
        end

        function endClaim()
            st = labclient.Sync.state();
            st.Claim = [];
            labclient.Sync.state(st);
        end

        function retarget(id, subjectId)
            %retarget  Rewrite held record ID of no dataset to name subject SUBJECTID, and seal it again.
            [b, st] = labclient.Outbox.read(id);
            if isempty(b) || st ~= "held" || b.type ~= "event"; return; end
            old = string(b.record.subject_id);
            attr = string(b.record.event.attributes_json);
            if ~contains(attr, '"subject_assigned_from"') && old ~= ""
                attr = labclient.Sync.addMember(attr, "subject_assigned_from", string(jsonencode(char(old))));
            end
            b.record.event.attributes_json = attr;
            b.record.subject_id = string(subjectId);
            b.digest = "";
            b = labclient.Bundles.seal(b);
            labclient.Outbox.update(b);
        end

        function beat()
            %beat  Say that the record being sent is still worked on (so no other MATLAB takes its claim back).
            st = labclient.Sync.state();
            if ~isempty(st.Claim)
                try
                    labclient.Outbox.heartbeat(st.Claim);
                catch
                end
            end
        end

        function st = state(new)
            persistent s
            if isempty(s)
                s = struct("Timer", [], "Parent", [], "Suspended", 0, "Warned", false, ...
                    "Offered", strings(1, 0), "Manual", false, ...
                    "LastSent", NaT("TimeZone", "local"), "Claim", []);
            end
            if nargin > 0; s = new; end
            st = s;
        end

        function endManual()
            st = labclient.Sync.state();
            st.Manual = false;
            st.Parent = [];
            st.Suspended = 0;
            labclient.Sync.state(st);
        end

        function t = plural(n, one, many)
            if n == 1; t = one; else; t = many; end
        end

        function resume()
            st = labclient.Sync.state();
            st.Suspended = max(0, st.Suspended - 1);
            labclient.Sync.state(st);
        end

        function ids = nextIds()
            %nextIds  The sealed pending records that may go now, oldest first.
            T = labclient.Outbox.list(State="pending");
            T = T(T.sealed, :);
            ids = strings(1, 0);
            if isempty(T); return; end
            waiting = labclient.Outbox.list();
            waiting = waiting.id(waiting.state ~= "done" & waiting.state ~= "discarded");
            st = labclient.Sync.state();
            nowT = datetime("now", "TimeZone", "local");
            for k = 1:height(T)
                b = labclient.Outbox.read(T.id(k));
                if isempty(b); continue; end
                % The shared-outbox rule: a record this MATLAB cannot fully
                % send (its dataset's tool is not running here) is left for
                % one that can; it is neither claimed nor failed.
                if b.type == "event" && ~labclient.Sync.hasTool(labclient.Bundles.toolOf(b)); continue; end
                if any(ismember(b.after, waiting)); continue; end   % after a record still to be sent
                if startsWith(T.note(k), "waiting")
                    % its files were not there (edges, files), or a folder's
                    % raw files are still being hashed (an event): tried
                    % again once something was sent since, or after EdgesRetry
                    n = labclient.Outbox.note(T.id(k), "pending");
                    at = NaT("TimeZone", "local");
                    try
                        at = datetime(n.at, "InputFormat", labclient.Bundles.TimeFormat, "TimeZone", "local");
                    catch
                    end
                    sentSince = ~isnat(st.LastSent) && ~isnat(at) && st.LastSent > at;
                    if ~sentSince && ~isnat(at) && seconds(nowT - at) < labclient.Sync.EdgesRetry; continue; end
                end
                ids(end + 1) = T.id(k); %#ok<AGROW>
            end
        end

        function [state, reason, flags] = sendEvent(be, b, note)
            %sendEvent  Send event record B; STATE done / held / failed / pending, FLAGS for a held one.
            flags = strings(1, 0);
            s = labclient.Settings.load();
            ev = b.record.event;
            by = b.captured_by.db_username;
            if by ~= "" && by ~= s.Username && ~any(note.flags == labclient.Sync.OnBehalf)
                state = "held";
                reason = "Captured under the login " + by + ", not " + s.Username + ...
                    ": send it as yourself from the Database window, or from " + by + "'s login.";
                flags = labclient.Sync.NeedsLogin;
                return
            end
            roots = be.storageRoots();
            also = strings(1, 0);
            if any(ev.event_type == ["recording" "behavior"])
                % A second copy of a recording (or behavior session) already in
                % the database: its files are copies of that event's, not a
                % new recording.
                [cs, S, E, why, from, also] = labclient.Sync.copyOf(be, b.record.outputs);
                if cs == "ambiguous"
                    state = "held";
                    reason = why;
                    return
                elseif cs == "copy"
                    [state, reason] = labclient.Sync.sendCopy(be, b, S, E, from, roots, s);
                    return
                end
            end
            [sid, subject, why, need] = labclient.Sync.resolveSession(be, b.record, roots, s);
            if need == "wait"
                state = "pending";
                reason = why;
                return
            elseif why ~= ""
                state = "held";
                reason = why;
                if need ~= ""; flags = need; end
                return
            end
            if subject == "" && ev.event_type ~= "analysis"
                state = "held";
                reason = "A " + ev.event_type + " event is about an animal: this record names no subject " + ...
                    "(Bundles.event, SubjectId=), and has no dataset to give one.";
                return
            end
            person = labclient.Sync.performer(be, ev.performer, by == "" || by == s.Username || ...
                any(note.flags == labclient.Sync.OnBehalf));
            if person == ""
                state = "held";
                reason = "No lab person is named for this record, and none could be found for it.";
                return
            end
            [outs, why] = labclient.Sync.outputs(b.record.outputs, roots, s);
            if why ~= ""
                state = "held";
                reason = why;
                return
            end
            [ins, unresolved] = labclient.Sync.inputs(be, b.record.inputs, roots, s);
            attr = ev.attributes_json;
            if ~isempty(also)
                % some raw files are byte for byte files of other events (a settings file the same in two recordings)
                attr = labclient.Sync.addMember(attr, "raw_files_also_in_events", string(jsonencode(cellstr(also))));
            end
            if ~isempty(unresolved)
                attr = labclient.Sync.addMember(attr, "unresolved_inputs", string(jsonencode(unresolved)));
            end
            if any(note.flags == labclient.Sync.OnBehalf)
                attr = labclient.Sync.addMember(attr, "sent_on_behalf_of", string(jsonencode(by)));
            end
            d = ev.detail;
            for f = ["started_at" "finished_at"]
                if isfield(d, f)
                    if string(d.(f)) == ""
                        d = rmfield(d, f);
                    else
                        d.(f) = labclient.Sync.parseTime(d.(f));
                    end
                end
            end
            if ev.event_type == "husbandry"
                % a column not measured is not sent (the database leaves it NULL), whatever way it was written
                for f = reshape(string(fieldnames(d)), 1, [])
                    v = d.(f);
                    if isempty(v) || (isstring(v) && all(strlength(v) == 0)) || (isnumeric(v) && isscalar(v) && isnan(v))
                        d = rmfield(d, f);
                    end
                end
            end
            req = struct("EventType", ev.event_type, "EventId", ev.event_id, "Digest", b.digest, ...
                "OccurredAt", labclient.Sync.parseTime(ev.occurred_at), "SubjectId", subject, "SessionId", sid, ...
                "Notes", ev.notes, "AttributesJson", attr, "RecordedBy", person, "Detail", d, ...
                "Inputs", ins, "Outputs", outs);
            out = be.recordEvent(req);
            state = "done";
            if out.Outcome == "existing"
                reason = "already in the database";
            else
                reason = "sent";
            end
            skipped = reshape(string(out.SkippedInputs), 1, []);
            if ~isempty(skipped)
                items = b.record.inputs(ismember([b.record.inputs.artifact_id], skipped));
                labclient.Outbox.put(labclient.Bundles.edges(EventId=ev.event_id, Inputs=items, ...
                    CapturedBy=b.captured_by));
                reason = reason + sprintf("; %d input(s) sent later, when their files are in the database", ...
                    numel(skipped));
            end
            if ~isempty(out.SkippedReplaces)
                reason = reason + sprintf("; %d replaced file(s) not in the database, not marked replaced", ...
                    numel(out.SkippedReplaces));
            end
            if any(out.Unchanged)
                reason = reason + sprintf("; %d file(s) already registered with the same bytes", nnz(out.Unchanged));
            end
        end

        function [state, reason] = sendEdges(be, b)
            %sendEdges  Add the input edges of edges record B; what is still missing waits.
            missing = 0;
            for k = 1:numel(b.record.inputs)
                it = b.record.inputs(k);
                try
                    be.addEventInput(b.record.event_id, it.artifact_id, it.role);
                catch ME
                    if endsWith(string(ME.identifier), ":Unreachable") || ...
                            any(string(ME.identifier) == labclient.Sync.Transient)
                        rethrow(ME);
                    end
                    missing = missing + 1;
                end
            end
            if missing == 0
                state = "done";
                reason = "sent";
            else
                state = "pending";
                reason = sprintf("waiting: %d input file(s) not in the database yet", missing);
            end
        end

        function [state, S, E, why, from, also] = copyOf(be, items)
            %copyOf  Whether the raw files ITEMS are, by their SHA-256, the files of one event already in the database.
            %   STATE "copy": each is a raw file of event E (session S; FROM
            %   the artifact each copies): byte for byte the same raw files
            %   are the same recording, wherever they were copied to.
            %   "ambiguous": they are all files of more than one event (WHY
            %   names them). "none": not all of them are files of one event;
            %   ALSO lists the events some of them are files of (a settings
            %   file can be the same in two recordings). "unhashed": a
            %   SHA-256 is not known yet.
            state = "none"; S = ""; E = ""; why = ""; from = strings(1, 0); also = strings(1, 0);
            if isempty(items); return; end
            items = items(string({items.role}) == "raw");
            if isempty(items); return; end
            n = numel(items);
            evs = cell(1, n); ids = cell(1, n); ses = cell(1, n);   % per file: the events, artifacts, sessions it matches
            for k = 1:n
                sha = lower(string(items(k).sha256));
                if strlength(sha) ~= 64
                    state = "unhashed";
                    return
                end
                A = be.artifacts(struct("Checksum", sha, "Role", "raw"));
                evs{k} = strings(1, 0); ids{k} = strings(1, 0); ses{k} = strings(1, 0);
                if height(A) == 0 || ~all(ismember(["artifact_id" "produced_by_event_id" "session_id"], ...
                        string(A.Properties.VariableNames))); continue; end
                keep = string(A.artifact_id) ~= string(items(k).artifact_id);   % not the file itself (a record sent again)
                evs{k} = reshape(string(A.produced_by_event_id(keep)), 1, []);
                ids{k} = reshape(string(A.artifact_id(keep)), 1, []);
                ses{k} = reshape(string(A.session_id(keep)), 1, []);
            end
            common = unique(evs{1});
            for k = 2:n; common = intersect(common, evs{k}); end
            also = unique([strings(1, 0), evs{:}]);
            if isempty(common); return; end
            if numel(common) > 1
                state = "ambiguous";
                why = "Its raw files are, by their SHA-256, the files of each of " + strjoin("event " + common, ", ") + ...
                    " already in the database: one recording recorded twice there. Check those events.";
                return
            end
            state = "copy";
            E = common;
            from = strings(1, n);
            for k = 1:n
                r = find(evs{k} == E, 1);
                from(k) = ids{k}(r);
                if k == 1; S = ses{k}(r); end
            end
            if ismissing(S); S = ""; end   % an event of no session (a record of no dataset)
            also = strings(1, 0);
        end

        function [state, reason] = sendCopy(be, b, S, E, from, roots, s)
            %sendCopy  Record B's raw files as copies of event E's (session S), and give its folder that session.
            ev = b.record.event;
            items = b.record.outputs;
            items = items(string({items.role}) == "raw");
            [outs, why] = labclient.Sync.outputs(items, roots, s);
            if why ~= ""
                state = "held";
                reason = why;
                return
            end
            want = string(b.record.subject_id);
            if want ~= ""
                % a record that names its subject must not file its files under another's event
                Er = be.eventRows(struct("EventId", E));
                if height(Er) > 0 && string(Er.subject_id(1)) ~= "" && string(Er.subject_id(1)) ~= want
                    state = "held";
                    reason = "Its files are, byte for byte, files of " + ev.event_type + " event " + E + ...
                        ", which is subject " + string(Er.subject_id(1)) + "'s, not " + want + "'s. Check both.";
                    return
                end
            end
            n = 0;
            for k = 1:numel(outs)
                labclient.Sync.beat();
                o = outs(k);
                there = be.artifacts(struct("StorageRootId", o.storage_root_id, "RelativePath", o.relative_path));
                if height(there) > 0 && any(string(there.checksum) == lower(o.checksum)); continue; end   % that file already
                attr = labclient.Sync.addMember(o.attributes_json, "copied_from", string(jsonencode(from(k))));
                attr = labclient.Sync.addMember(attr, "copy_of_event", string(jsonencode(E)));
                attr = labclient.Sync.addMember(attr, "copy_recorded_as", string(jsonencode(ev.event_id)));
                be.addArtifact(struct("ArtifactId", o.artifact_id, "ProducedByEventId", E, ...
                    "StorageRootId", o.storage_root_id, "RelativePath", o.relative_path, "Checksum", o.checksum, ...
                    "SizeBytes", o.size_bytes, "Role", o.role, "Format", o.format, "AttributesJson", attr));
                n = n + 1;
            end
            ds = b.record.dataset;
            if string(ds.folder) ~= "" && S ~= ""
                % the folder's session file takes that session (the tool's own file, so its hook);
                % a record of no dataset has none, and an event with no session gives none
                h = labclient.Sync.hooks(labclient.Bundles.toolOf(b));
                h.copyOfSession(string(ds.folder), string(ds.name), S, ev.event_type, E);
            end
            state = "done";
            if S == ""
                where = "no session";
            else
                where = "session " + S;
            end
            reason = sprintf("a copy of the %s %s (%s), already in the database: %d file(s) recorded as its copies", ...
                ev.event_type, E, where, n);
        end

        function [state, reason] = sendFiles(be, b)
            %sendFiles  Register the copies of files record B and its dispositions, each once.
            %   Waits while the event that produced the files is not in the
            %   database. A copy whose SHA-256 is not its source's is held. A
            %   copy that overwrote a file records that file as replaced. A
            %   file already registered with the same bytes at the same place
            %   is that file. A disposition already recorded is not recorded
            %   again.
            s = labclient.Settings.load();
            ev = b.record.event_id;
            if height(be.eventRows(struct("EventId", ev))) == 0
                state = "pending";
                reason = "waiting: the event that produced these files (" + ev + ") is not in the database yet";
                return
            end
            roots = be.storageRoots();
            idOf = containers.Map('KeyType', 'char', 'ValueType', 'char');   % a copy's id -> the row that describes it
            notes = strings(1, 0);
            for k = 1:numel(b.record.outputs)
                labclient.Sync.beat();
                it = b.record.outputs(k);
                a = jsondecode(char(it.attributes_json));
                if isfield(a, "copied_from_sha256") && strlength(string(a.copied_from_sha256)) == 64 ...
                        && string(a.copied_from_sha256) ~= it.sha256
                    state = "held";
                    reason = "The copy " + it.path + " is not the bytes of the file it copies (SHA-256 " + ...
                        it.sha256 + ", its source " + string(a.copied_from_sha256) + ").";
                    return
                end
                root = it.root; rel = it.rel;
                if root == ""; [root, rel] = labclient.Roots.locate(it.path, s); end
                rid = roots.root_id(string(roots.name) == root);
                if root == "" || isempty(rid)
                    state = "held";
                    reason = "The copy " + it.path + " is not under a storage root the database has: " + ...
                        "map or register its root in the Database window.";
                    return
                end
                if height(be.artifacts(struct("ArtifactId", it.artifact_id))) > 0
                    idOf(char(it.artifact_id)) = char(it.artifact_id);   % sent before
                    notes = [notes, labclient.Sync.replaceFile(be, it, it.artifact_id, b.captured_at)]; %#ok<AGROW>
                    continue
                end
                there = be.artifacts(struct("StorageRootId", rid(1), "RelativePath", rel));
                same = there(string(there.checksum) == it.sha256, :);
                if height(same) > 0
                    idOf(char(it.artifact_id)) = char(string(same.artifact_id(1)));
                    notes(end + 1) = rel + " was registered already"; %#ok<AGROW>
                    continue
                end
                be.addArtifact(struct("ArtifactId", it.artifact_id, "ProducedByEventId", ev, ...
                    "StorageRootId", double(rid(1)), "RelativePath", rel, "Checksum", it.sha256, ...
                    "SizeBytes", it.bytes, "Role", it.role, "Format", it.format, ...
                    "AttributesJson", it.attributes_json));
                idOf(char(it.artifact_id)) = char(it.artifact_id);
                notes = [notes, labclient.Sync.replaceFile(be, it, it.artifact_id, b.captured_at)]; %#ok<AGROW>
                if isfield(a, "overwrote") && isequal(a.overwrote, true)
                    for j = 1:height(there)
                        old = string(there.artifact_id(j));
                        if labclient.Sync.disposed(be, old); continue; end
                        be.addDisposition(struct("ArtifactId", old, "Disposition", "replaced", ...
                            "SuccessorArtifactId", it.artifact_id, "OccurredAt", labclient.Sync.parseTime(b.captured_at), ...
                            "Note", "overwritten by a copy", "AttributesJson", "{}"));
                    end
                end
            end
            for k = 1:numel(b.record.dispositions)
                d = b.record.dispositions(k);
                succ = d.successor_artifact_id;
                if succ ~= "" && isKey(idOf, char(succ)); succ = string(idOf(char(succ))); end
                D = be.dispositions(d.artifact_id);
                if height(D) > 0 && any(string(D.disposition) == d.disposition & ...
                        string(D.successor_artifact_id) == succ)
                    continue   % recorded before
                end
                if height(be.artifacts(struct("ArtifactId", d.artifact_id))) == 0
                    state = "pending";
                    reason = "waiting: the file " + d.artifact_id + " is not in the database yet";
                    return
                end
                be.addDisposition(struct("ArtifactId", d.artifact_id, "Disposition", d.disposition, ...
                    "SuccessorArtifactId", succ, "OccurredAt", labclient.Sync.parseTime(d.occurred_at), ...
                    "Note", d.note, "AttributesJson", d.attributes_json));
            end
            state = "done";
            reason = sprintf("sent: %d file(s), %d disposition(s)", numel(b.record.outputs), numel(b.record.dispositions));
            if ~isempty(notes); reason = reason + "; " + strjoin(notes, "; "); end
        end

        function notes = replaceFile(be, it, newId, capturedAt)
            %replaceFile  Record the file item IT replaces (its "replaces" artifact id) as replaced by NEWID, once.
            %   The new bytes are at the same path as the earlier file's,
            %   which is how a file of an event already sent is replaced
            %   (Bundles.files). An earlier file the database does not have,
            %   or that is gone already, is noted and left.
            notes = strings(1, 0);
            old = string(it.replaces);
            if old == "" || old == string(newId); return; end
            if height(be.artifacts(struct("ArtifactId", old))) == 0
                notes = "the replaced file " + old + " is not in the database, not marked replaced";
                return
            end
            if labclient.Sync.disposed(be, old); return; end
            be.addDisposition(struct("ArtifactId", old, "Disposition", "replaced", ...
                "SuccessorArtifactId", string(newId), "OccurredAt", labclient.Sync.parseTime(capturedAt), ...
                "Note", "replaced by a newer version of the file", "AttributesJson", "{}"));
        end

        function tf = disposed(be, id)
            %disposed  True when artifact ID's file is recorded as gone (replaced, moved or deleted, not restored since).
            D = be.dispositions(id);
            tf = height(D) > 0 && string(D.disposition(1)) ~= "restored";   % newest first
        end

        function [sid, subject, why, need] = resolveSession(be, rec, roots, s)
            %resolveSession  The record's session in the database, created when it is not there yet.
            %   A record of no dataset has no session; when it names a
            %   subject (rec.subject_id) the subject must be in the database,
            %   or the record is held for it (NEED NeedsSubject).
            ds = rec.dataset;
            sid = string(ds.session_id);
            subject = "";
            why = "";
            need = "";
            if string(ds.folder) == ""
                sid = "";
                want = string(rec.subject_id);
                if want == ""; return; end   % an analysis of no dataset, or a record that names nobody
                if height(be.subjects(struct("SubjectId", want))) == 0
                    why = "Subject " + want + " is not in the database: create it, or assign this record " + ...
                        "to a subject that is.";
                    need = labclient.Sync.NeedsSubject;
                    return
                end
                subject = want;
                return
            end
            hooks = labclient.Sync.hooks(labclient.Bundles.toolOf(struct("record", rec)));
            if sid ~= ""
                T = be.sessions(struct("SessionId", sid));
                if height(T) > 0
                    subject = string(T.subject_id(1));
                    return
                end
            end
            here = string(hooks.readSession(string(ds.folder), string(ds.name)).session_id);
            if here ~= "" && here ~= sid
                % the folder's session file names another session: its folder
                % is a copy of that session's recording (the tool's copyOfSession hook)
                T = be.sessions(struct("SessionId", here));
                if height(T) > 0
                    sid = here;
                    subject = string(T.subject_id(1));
                    return
                end
            end
            [root, rel, w] = labclient.Roots.locate(string(ds.folder), s);
            if root == ""
                why = "The dataset folder " + ds.folder + " is not under a storage root mapped here (" + w + ...
                    "): map its root in the Database window.";
                return
            end
            rootId = roots.root_id(string(roots.name) == root);
            if isempty(rootId)
                why = "The storage root " + root + " is not in the database: register it in the Database window.";
                return
            end
            T = be.sessions(struct("StorageRootId", rootId(1), "RelativePath", rel));
            if height(T) > 0
                if sid == "" || string(T.session_id(1)) == sid
                    sid = string(T.session_id(1));
                    subject = string(T.subject_id(1));
                else
                    why = "The folder " + rel + " is session " + string(T.session_id(1)) + ...
                        " in the database, but its session file says " + sid + ".";
                end
                return
            end
            ses = hooks.readSession(string(ds.folder), string(ds.name));
            if ses.recording_event_id ~= "" && height(be.eventRows(struct("EventId", ses.recording_event_id))) == 0
                % Its recording is not in the database yet: when the record of
                % it is here, it says whether the folder is a second copy of a
                % recording that is (then the folder takes that session).
                [rb, rst] = labclient.Outbox.read(ses.recording_event_id);
                if rst ~= "" && rst ~= "discarded"
                    if ~labclient.Bundles.isSealed(rb)
                        why = "waiting: the SHA-256 of the folder's raw files, to tell whether it is a copy of a recording in the database";
                        need = "wait";
                        return
                    end
                    [cs, S, ~, cwhy] = labclient.Sync.copyOf(be, rb.record.outputs);
                    if cs == "ambiguous"
                        why = cwhy;
                        return
                    elseif cs == "copy"
                        T = be.sessions(struct("SessionId", S));
                        if height(T) > 0
                            sid = S;
                            subject = string(T.subject_id(1));
                            hooks.copyOfSession(string(ds.folder), string(ds.name), S, "recording", "");
                            return
                        end
                    end
                end
            end
            candidate = ses.subject_id;
            if candidate == ""; candidate = string(ds.subject_folder_id); end
            if candidate == ""
                why = "The folder name of " + ds.name + " gives no subject: assign one.";
                need = labclient.Sync.NeedsSubject;
                return
            end
            if height(be.subjects(struct("SubjectId", candidate))) == 0
                why = "Subject " + candidate + " is not in the database: create it, or assign " + ...
                    ds.name + " to a subject that is.";
                need = labclient.Sync.NeedsSubject;
                return
            end
            if sid == ""; sid = labclient.Bundles.newId(); end
            a = struct("SessionId", sid, "SubjectId", candidate, "Label", string(ds.name), ...
                "StorageRootId", rootId(1), "RelativePath", rel, ...
                "StartedAt", labclient.Sync.parseTime(ds.recording_start));
            be.addSession(a);
            subject = candidate;
        end

        function id = performer(be, p, mine)
            %performer  The lab person of performer P; the connection's person for a record of this login (MINE).
            id = string(p.person_id);
            if id ~= ""; return; end
            if string(p.person_email) ~= ""
                T = be.persons(struct("Email", string(p.person_email)));
                if height(T) == 1; id = string(T.person_id(1)); return; end
            end
            if mine
                me = be.person();
                id = string(me.PersonId);
            end
        end

        function [outs, why] = outputs(items, roots, s)
            why = "";
            outs = struct("artifact_id", {}, "storage_root_id", {}, "relative_path", {}, "checksum", {}, ...
                "size_bytes", {}, "role", {}, "format", {}, "attributes_json", {}, "replaces", {});
            for k = 1:numel(items)
                it = items(k);
                root = it.root; rel = it.rel;
                if root == ""
                    [root, rel] = labclient.Roots.locate(it.path, s);   % a root mapped since it was captured
                end
                if root == ""
                    why = "Output " + it.path + " is not under a storage root mapped here: map its root in the Database window.";
                    return
                end
                rid = roots.root_id(string(roots.name) == root);
                if isempty(rid)
                    why = "The storage root " + root + " is not in the database: register it in the Database window.";
                    return
                end
                outs(end + 1) = struct("artifact_id", it.artifact_id, "storage_root_id", double(rid(1)), ...
                    "relative_path", rel, "checksum", it.sha256, "size_bytes", it.bytes, "role", it.role, ...
                    "format", it.format, "attributes_json", it.attributes_json, "replaces", it.replaces); %#ok<AGROW>
            end
        end

        function [ins, unresolved] = inputs(be, items, roots, s)
            %inputs  The inputs the database can be told of, and those this computer cannot name.
            ins = struct("artifact_id", {}, "role", {});
            unresolved = struct("path", {}, "root", {}, "rel", {}, "bytes", {}, "mtime", {}, "role", {});
            for k = 1:numel(items)
                it = items(k);
                id = it.artifact_id;
                if id == "" && strlength(it.sha256) == 64
                    root = it.root; rel = it.rel;
                    if root == ""; [root, rel] = labclient.Roots.locate(it.path, s); end
                    rid = roots.root_id(string(roots.name) == root);
                    if ~isempty(rid)
                        T = be.artifacts(struct("StorageRootId", rid(1), "RelativePath", rel));
                        hit = string(T.checksum) == it.sha256;
                        if any(hit); id = string(T.artifact_id(find(hit, 1))); end
                    end
                end
                if id == ""
                    unresolved(end + 1) = struct("path", it.path, "root", it.root, "rel", it.rel, ...
                        "bytes", it.bytes, "mtime", it.mtime, "role", it.role); %#ok<AGROW>
                elseif ~any(string({ins.artifact_id}) == id)
                    ins(end + 1) = struct("artifact_id", id, "role", it.role); %#ok<AGROW>
                end
            end
        end

        function [state, reason] = classify(ME)
            %classify  What a failure means: try again later, hold for a person, or failed.
            id = string(ME.identifier);
            msg = string(ME.message);
            if endsWith(id, ":Unreachable") || any(id == labclient.Sync.Transient) || ...
                    contains(lower(msg), ["timeout", "timed out", "canceling statement", "connection"])
                state = "pending";
                reason = "will try again: " + msg;
            elseif id == "CarasLabDB:idConflict"
                state = "held";
                reason = "Conflict: " + msg;
            else
                state = "failed";
                reason = msg;
            end
        end

        function t = parseTime(txt)
            %parseTime  Zoned text (labclient.Bundles.timeText) as a datetime in UTC (NaT for "").
            txt = string(txt);
            if txt == ""
                t = NaT("TimeZone", "UTC");
                return
            end
            t = datetime(txt, "InputFormat", labclient.Bundles.TimeFormat, "TimeZone", "UTC");
        end

        function txt = addMember(json, name, valueJson)
            %addMember  The JSON object text JSON with member NAME (JSON text VALUEJSON) added, the rest as it was.
            json = strtrim(string(json));
            if ~startsWith(json, "{") || ~endsWith(json, "}")
                error("labclient:Sync:Json", "Not a JSON object: %s", json);
            end
            body = strtrim(extractBetween(json, 2, strlength(json) - 1));
            member = string(jsonencode(char(name))) + ":" + valueJson;
            if body == ""
                txt = "{" + member + "}";
            else
                txt = "{" + body + "," + member + "}";
            end
        end

        function offerSubjects()
            %offerSubjects  Show the subject dialog once for a folder subject that is new, when an app is open.
            st = labclient.Sync.state();
            if isempty(st.Parent) || ~isvalid(st.Parent); return; end
            T = labclient.Sync.subjectHolds();
            ids = setdiff(unique(T.folder_id), st.Offered);
            if isempty(ids); return; end
            st.Offered = [st.Offered, reshape(ids, 1, [])];
            labclient.Sync.state(st);
            labclient.SubjectAssignDialog.open(Parent=st.Parent, FolderId=ids(1));
        end
    end
end
