classdef Outbox
    % labclient.Outbox  What waits on this computer to be sent to the lab database: one file per record.
    %   Every record for the database is written here first (by the toolbox that captures it), so
    %   nothing is lost while the server is out of reach, MATLAB closes or
    %   the computer restarts. The outbox is the folder "outbox" in
    %   labclient.DB.folder(), one subfolder per state:
    %
    %     pending   waiting to be sent (an unsealed one still waits for the
    %               SHA-256 of an output, labclient.Hasher)
    %     claimed   being sent by one MATLAB; a heartbeat file says which
    %               and when it last showed life
    %     held      waiting for a person (a file that changed after it was
    %               captured, a subject to assign, ...); the note says why
    %     failed    the database refused it; the note gives its reason
    %     done      sent (kept as a local log)
    %     discarded put aside by a person, never to be sent (kept, with who
    %               and why)
    %
    %   A bundle is <bundle_id>.json (labclient.Bundles); a note beside it,
    %   <bundle_id>.note.json, says when and why it moved. Files are written
    %   to a temporary name and renamed into place, so a crash never leaves
    %   half a file. A claim is a rename, which only one process can win.
    %
    %     status = labclient.Outbox.put(b)           % a new bundle, pending; or the newer version of an unsent one;
    %                                                % held, with the reason, when the database would refuse it
    %     claim = labclient.Outbox.take(id)          % like claim, for an unsent record in any state (put uses it)
    %     [b, state] = labclient.Outbox.read(id)
    %     labclient.Outbox.update(b)                 % rewrite a pending or claimed bundle
    %     T = labclient.Outbox.list(State="pending") % id, state, type, captured_at, sealed, note
    %     n = labclient.Outbox.counts()              % one count per state
    %     st = labclient.Outbox.stateOf(id)          % "" when it is not here
    %     claim = labclient.Outbox.claim(id)         % [] when another process has it
    %     labclient.Outbox.heartbeat(claim)
    %     labclient.Outbox.finish(claim, "done" | "failed" | "held" | "pending", Reason=, Flags=)
    %     labclient.Outbox.move(id, state, Reason=, Flags=)  % hold, release, retry, discard
    %     n = labclient.Outbox.recoverStale(MaxAge=120)
    %
    %   Two MATLABs (of different toolboxes) may share one outbox: a claim is an
    %   atomic rename, a claim that shows no life for MaxAge seconds goes back
    %   to pending, and an owner that finds its claim gone does not touch what
    %   it no longer holds (finish returns false, heartbeat writes nothing).
    %
    %   See also labclient.Bundles, labclient.Sync, labclient.Hasher, labclient.DB.folder.

    properties (Constant)
        States = ["pending" "claimed" "held" "failed" "done" "discarded"]
        NotSendable = "not_sendable"   % the flag of a record held because the database would refuse it (put)
    end

    methods (Static)
        function d = root()
            %root  The outbox folder (each state's subfolder created when missing).
            d = string(fullfile(labclient.DB.folder(), "outbox"));
            for s = labclient.Outbox.States
                f = fullfile(d, s);
                if ~isfolder(f); mkdir(f); end
            end
        end

        function f = file(id, state)
            %file  Where bundle ID lives in STATE.
            f = string(fullfile(labclient.Outbox.root(), state, labclient.Outbox.checkId(id) + ".json"));
        end

        function [status, why] = put(b)
            %put  Write bundle B as pending: new, or the newer version of a record not sent yet.
            %   STATUS says what happened:
            %     "added"      B's id is new here; B waits to be sent
            %     "unchanged"  a bundle of this id with the same text is here
            %                  already (in any state): nothing was written
            %     "replaced"   a bundle of this id that was not sent yet (to
            %                  send, held or failed) is replaced by B, which
            %                  goes to pending with no flags (or is held: see
            %                  WHY); what its hash jobs
            %                  had is dropped. A toolbox that saves a session
            %                  again before the record was sent, or corrects a
            %                  weight the same day, puts the new bundle under
            %                  the same event id.
            %   Raised, for the caller to act on (it needs a new event, whose
            %   id supersedes the sent one's, not a replaced bundle):
            %     labclient:Outbox:Sent       B's id was sent already (done)
            %     labclient:Outbox:Discarded  a person discarded that id
            %     labclient:Outbox:Claimed    it is being sent this moment, by
            %                                 this or another MATLAB: try again
            %   A replacement takes the record the way a sender does (a
            %   rename into "claimed" that one process wins), so it can never
            %   be sent half old, half new, nor lose a race with a sender.
            %
            %   WHY is what the database would refuse in B, a row of
            %   sentences (labclient.Bundles.problems), empty when there is
            %   nothing. A record with something in it is kept all the same
            %   (STATUS says "added" or "replaced" as for any other), but
            %   HELD, with WHY as its reason and the flag NotSendable, and
            %   it is not sent until a person releases it in the Database
            %   window. So nothing a toolbox recorded is lost, and what is
            %   wrong shows here and now ("need you" on the lamp) instead of
            %   as a failed record once the database is reached. A corrected
            %   record put under the same id replaces it and goes to pending.
            id = labclient.Outbox.checkId(b.bundle_id);
            txt = labclient.Bundles.encode(b);
            why = labclient.Bundles.problems(b);
            reason = "";
            if ~isempty(why)
                reason = "The database would refuse this record: " + strjoin(why, "; ") + ...
                    ". It is kept and not sent: correct what records it and record again, or discard it.";
            end
            [old, state] = labclient.Outbox.readText(id);
            if state == ""
                if isempty(why)
                    writeJsonFile(labclient.Outbox.file(id, "pending"), txt, Text=true);
                else
                    writeJsonFile(labclient.Outbox.file(id, "held"), txt, Text=true);
                    labclient.Outbox.moveTo(id, "held", "held", reason, labclient.Outbox.NotSendable);   % its note
                end
                status = "added";
                return
            end
            if old == txt; status = "unchanged"; return; end
            switch state
                case "done"
                    error("labclient:Outbox:Sent", ...
                        "Record %s was sent already: it cannot be replaced; record a new event that supersedes it.", id);
                case "discarded"
                    error("labclient:Outbox:Discarded", "Record %s was discarded by a person: it is not replaced.", id);
                case "claimed"
                    error("labclient:Outbox:Claimed", "Record %s is being sent now: try again in a moment.", id);
            end
            c = labclient.Outbox.take(id);
            if isempty(c)
                error("labclient:Outbox:Claimed", "Record %s is being sent now: try again in a moment.", id);
            end
            try
                writeJsonFile(labclient.Outbox.file(id, "claimed"), txt, Text=true);
                labclient.Hasher.clearJobs(id);
            catch ME
                labclient.Outbox.finish(c, "pending", Reason="its replacement could not be written: " + string(ME.message));
                rethrow(ME);
            end
            if isempty(why)
                labclient.Outbox.finish(c, "pending", Reason="replaced by a newer version of the record (it was " + ...
                    state + ")", Flags=strings(1, 0));
            else
                labclient.Outbox.finish(c, "held", Reason=reason, Flags=labclient.Outbox.NotSendable);
            end
            status = "replaced";
        end

        function [b, state] = read(id)
            %read  Bundle ID and its state ([] and "" when it is not here).
            [txt, state] = labclient.Outbox.readText(id);
            b = [];
            if state == ""; return; end
            b = labclient.Bundles.decode(txt);
        end

        function tf = update(b)
            %update  Rewrite bundle B where it is (pending, claimed or held), e.g. with a hash added.
            %   TF is false, and nothing is written, when the bundle there is
            %   no longer B's capture: a newer version replaced it (put)
            %   while a hash was being taken, and B's hashes are not its.
            id = labclient.Outbox.checkId(b.bundle_id);
            [old, state] = labclient.Outbox.readText(id);
            if ~ismember(state, ["pending" "claimed" "held"])
                error("labclient:Outbox:State", "Bundle %s cannot be changed: it is %s.", id, ...
                    labclient.Outbox.stateWord(state));
            end
            tf = true;
            try
                tf = labclient.Bundles.decode(old).captured_at == string(b.captured_at);
            catch
            end
            if ~tf; return; end
            writeJsonFile(labclient.Outbox.file(id, state), labclient.Bundles.encode(b), Text=true);
        end

        function T = list(opts)
            %list  The bundles in STATE (all states when "") as a table, oldest capture first.
            %   Columns: id, state, type, captured_at, sealed, file, note (why
            %   it is held or failed, "" for none).
            arguments
                opts.State (1,1) string = ""
            end
            states = labclient.Outbox.States;
            if opts.State ~= ""; states = opts.State; end
            id = strings(0, 1); st = id; ty = id; at = id; fl = id; nt = id; sealed = false(0, 1);
            for s = states
                d = labclient.Outbox.bundleFiles(s);
                for k = 1:numel(d)
                    f = string(fullfile(d(k).folder, d(k).name));
                    try
                        b = labclient.Bundles.decode(fileread(f));
                    catch
                        continue   % not a bundle: left alone
                    end
                    id(end+1, 1) = b.bundle_id; %#ok<AGROW>
                    st(end+1, 1) = s; %#ok<AGROW>
                    ty(end+1, 1) = b.type; %#ok<AGROW>
                    at(end+1, 1) = b.captured_at; %#ok<AGROW>
                    sealed(end+1, 1) = labclient.Bundles.isSealed(b); %#ok<AGROW>
                    fl(end+1, 1) = f; %#ok<AGROW>
                    n = labclient.Outbox.note(b.bundle_id, s);
                    nt(end+1, 1) = n.reason; %#ok<AGROW>
                end
            end
            T = table(id, st, ty, at, sealed, fl, nt, ...
                'VariableNames', {'id', 'state', 'type', 'captured_at', 'sealed', 'file', 'note'});
            T = sortrows(T, 'captured_at');
        end

        function st = stateOf(id)
            %stateOf  The state bundle ID is in ("" when this computer's outbox does not have it).
            st = "";
            try
                id = labclient.Outbox.checkId(id);
            catch
                return
            end
            for s = labclient.Outbox.States
                if isfile(fullfile(labclient.Outbox.root(), s, id + ".json")); st = s; return; end
            end
        end

        function c = counts()
            %counts  The number of bundles in each state, as a struct.
            c = struct();
            for s = labclient.Outbox.States
                c.(s) = numel(labclient.Outbox.bundleFiles(s));
            end
        end

        function n = note(id, state)
            %note  The note of bundle ID in STATE: state, reason, at, host ("" each when none), flags.
            %   FLAGS (a string row) are what a person decided for it, e.g.
            %   "on_behalf" (send it although another login captured it).
            n = struct("state", "", "reason", "", "at", "", "host", "", "flags", strings(1, 0));
            f = fullfile(labclient.Outbox.root(), state, labclient.Outbox.checkId(id) + ".note.json");
            if ~isfile(f); return; end
            x = readJsonFile(f, ErrorOnFail=false);
            if ~isstruct(x); return; end
            for k = ["state" "reason" "at" "host"]
                if isfield(x, k); n.(k) = string(x.(k)); end
            end
            if isfield(x, "flags") && ~isempty(x.flags)
                n.flags = reshape(string(x.flags), 1, []);
            end
        end

        function c = claim(id)
            %claim  Take pending bundle ID for this MATLAB to send; [] when it is not pending (another process has it).
            c = labclient.Outbox.take(id, "pending");
        end

        function c = take(id, from)
            %take  Rename bundle ID from one of the states FROM (default: pending, held, failed) into claimed.
            %   The rename is atomic, so of several processes trying only one
            %   wins; the others get []. The winner owns the record until it
            %   ends the claim (finish) or its heartbeat goes stale
            %   (recoverStale). claim is take from pending; put takes an
            %   unsent record this way to replace it.
            arguments
                id (1,1) string
                from (1,:) string = ["pending" "held" "failed"]
            end
            id = labclient.Outbox.checkId(id);
            dst = labclient.Outbox.file(id, "claimed");
            c = [];
            for s = from
                src = labclient.Outbox.file(id, s);
                if ~isfile(src); continue; end
                [ok, ~] = movefile(src, dst);
                if ~ok || ~isfile(dst); return; end
                labclient.Outbox.moveNote(id, s, "claimed");
                c = struct("id", id, "host", labclient.Bundles.host(), "pid", labclient.Outbox.pid(), ...
                    "claimed_at", labclient.Bundles.now());
                labclient.Outbox.heartbeat(c);
                return
            end
        end

        function heartbeat(claim)
            %heartbeat  Say that the claim is still being worked on (nothing is written for a claim that was taken back).
            if ~labclient.Outbox.owns(claim); return; end
            hb = claim;
            hb.beat_at = labclient.Bundles.now();
            writeJsonFile(fullfile(labclient.Outbox.root(), "claimed", claim.id + ".claim.json"), hb);
        end

        function tf = owns(claim)
            %owns  True while CLAIM is the claim on its bundle (the bundle is claimed, and by this claim).
            tf = isfile(labclient.Outbox.file(claim.id, "claimed"));
            hbFile = fullfile(labclient.Outbox.root(), "claimed", claim.id + ".claim.json");
            if tf && isfile(hbFile)
                hb = readJsonFile(hbFile, ErrorOnFail=false);
                if isstruct(hb) && isfield(hb, "claimed_at")
                    tf = string(hb.claimed_at) == string(claim.claimed_at) && ...
                        string(hb.host) == string(claim.host) && isequaln(double(hb.pid), double(claim.pid));
                end
            end
        end

        function kept = finish(claim, state, opts)
            %finish  End a claim: the bundle goes to STATE (done, failed, held or back to pending).
            %   KEPT is false when the claim was no longer there to end: its
            %   heartbeat went stale and another MATLAB took the record
            %   back (a send that took longer than recoverStale's MaxAge
            %   with no sign of life). The send is then harmless to have
            %   made twice (the database writes a record once), and nothing
            %   here is changed.
            arguments
                claim (1,1) struct
                state (1,1) string {mustBeMember(state, ["done" "failed" "held" "pending"])}
                opts.Reason (1,1) string = ""
                opts.Flags (1,:) string = string(missing)   % replace the flags (default: keep them)
            end
            kept = labclient.Outbox.owns(claim);
            if ~kept; return; end
            flags = labclient.Outbox.flagsFor(claim.id, "claimed", opts.Flags);
            labclient.Outbox.moveTo(claim.id, "claimed", state, opts.Reason, flags);
            hb = fullfile(labclient.Outbox.root(), "claimed", claim.id + ".claim.json");
            if isfile(hb); delete(hb); end
        end

        function move(id, state, opts)
            %move  Move bundle ID (not claimed) to STATE: hold it, release it, retry a failed one.
            arguments
                id (1,1) string
                state (1,1) string {mustBeMember(state, ["pending" "held" "failed" "done" "discarded"])}
                opts.Reason (1,1) string = ""
                opts.Flags (1,:) string = string(missing)   % replace the flags (default: keep them)
            end
            [~, from] = labclient.Outbox.readText(id);
            if from == ""
                error("labclient:Outbox:Missing", "Bundle %s is not in the outbox.", id);
            elseif from == "claimed"
                error("labclient:Outbox:State", "Bundle %s is being sent; it cannot be moved now.", id);
            end
            keep = isscalar(opts.Flags) && ismissing(opts.Flags);
            if from == state && keep; return; end
            labclient.Outbox.moveTo(labclient.Outbox.checkId(id), from, state, opts.Reason, ...
                labclient.Outbox.flagsFor(id, from, opts.Flags));
        end

        function n = recoverStale(opts)
            %recoverStale  Give back claims whose heartbeat is older than MaxAge seconds (their MATLAB stopped).
            arguments
                opts.MaxAge (1,1) double {mustBePositive} = 120
            end
            n = 0;
            d = labclient.Outbox.bundleFiles("claimed");
            nowT = datetime("now", "TimeZone", "local");
            for k = 1:numel(d)
                id = string(erase(d(k).name, ".json"));
                hbFile = fullfile(d(k).folder, id + ".claim.json");
                beat = NaT("TimeZone", "local");
                if isfile(hbFile)
                    hb = readJsonFile(hbFile, ErrorOnFail=false);
                    if isstruct(hb) && isfield(hb, "beat_at")
                        try
                            beat = datetime(string(hb.beat_at), "InputFormat", labclient.Bundles.TimeFormat, ...
                                "TimeZone", "local");
                        catch
                        end
                    end
                end
                if isnat(beat)
                    dt = datetime(d(k).datenum, "ConvertFrom", "datenum", "TimeZone", "local");
                    beat = dt;   % no heartbeat: the claim's own time
                end
                if seconds(nowT - beat) > opts.MaxAge
                    try
                        labclient.Outbox.moveTo(id, "claimed", "pending", "claim given back: its MATLAB stopped");
                        n = n + 1;
                    catch
                        continue   % another MATLAB gave it back first, or its owner just ended it
                    end
                    if isfile(hbFile); delete(hbFile); end
                end
            end
        end
    end

    methods (Static, Access = private)
        function id = checkId(id)
            id = lower(string(id));
            if isempty(regexp(char(id), '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', 'once'))
                error("labclient:Outbox:BadId", "'%s' is not a bundle id (a uuid).", id);
            end
        end

        function d = bundleFiles(state)
            %bundleFiles  The bundle files in STATE's folder (not the notes and heartbeats).
            d = dir(fullfile(labclient.Outbox.root(), state, "*.json"));
            d = d(~endsWith({d.name}, [".note.json" ".claim.json"]));
        end

        function [txt, state] = readText(id)
            id = labclient.Outbox.checkId(id);
            txt = "";
            state = "";
            for s = labclient.Outbox.States
                f = fullfile(labclient.Outbox.root(), s, id + ".json");
                if isfile(f)
                    txt = string(fileread(f));
                    state = s;
                    return
                end
            end
        end

        function moveTo(id, from, to, reason, flags)
            if nargin < 5; flags = strings(1, 0); end
            old = fullfile(labclient.Outbox.root(), from, id + ".note.json");
            if from ~= to
                src = labclient.Outbox.file(id, from);
                dst = labclient.Outbox.file(id, to);
                [ok, msg] = movefile(src, dst);
                if ~ok
                    error("labclient:Outbox:Move", "Bundle %s could not be moved from %s to %s: %s", id, from, to, msg);
                end
            end
            if isfile(old); delete(old); end
            n = struct("state", to, "reason", reason, "at", labclient.Bundles.now(), "host", labclient.Bundles.host(), ...
                "flags", {cellstr(flags)});
            writeJsonFile(fullfile(labclient.Outbox.root(), to, id + ".note.json"), n);
        end

        function f = flagsFor(id, state, given)
            %flagsFor  GIVEN, or the flags of the note bundle ID has in STATE when GIVEN is missing.
            if isscalar(given) && ismissing(given)
                n = labclient.Outbox.note(id, state);
                f = n.flags;
            else
                f = given;
            end
        end

        function moveNote(id, from, to)
            src = fullfile(labclient.Outbox.root(), from, id + ".note.json");
            if isfile(src)
                movefile(src, fullfile(labclient.Outbox.root(), to, id + ".note.json"));
            end
        end

        function p = pid()
            try
                p = double(feature('getpid'));
            catch
                p = NaN;
            end
        end

        function w = stateWord(state)
            if state == ""; w = "not in the outbox"; else; w = state; end
        end
    end
end
