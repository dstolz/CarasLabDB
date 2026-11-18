classdef Bundles
    % labclient.Bundles  What a toolbox records for the lab database, as files: building, sealing, reading.
    %   A bundle is one record waiting in the outbox (labclient.Outbox) to be sent
    %   to the lab database: an event (an analysis step that wrote files, a
    %   recording, a behavior session, a weighing, ...) with the files it
    %   read and the files it wrote. It is a JSON file in the format
    %   caraslabdb-bundle/1, which this class defines
    %   (tests/matlab/testdata/bundle_event_v1.json is a complete example;
    %   the members added since the first records are optional, so the
    %   format stays /1):
    %
    %     format       "caraslabdb-bundle/1"
    %     bundle_id    the event's id (a uuid the toolbox minted)
    %     type         "event"; "edges" (inputs of an event already sent,
    %                  whose files were not in the database yet); or "files"
    %                  (copies of files an event produced, and what became of
    %                  files: moved, deleted)
    %     captured_at  when it was captured (zoned, microseconds)
    %     captured_by  host, os_user, db_username, person_id, person_email
    %     after        bundles to send before this one
    %     digest       SHA-256 of the record's canonical JSON text; "" until
    %                  every output's SHA-256 is known (sealed)
    %     record       dataset (name, folder, session_id, subject_folder_id,
    %                  recording_start, tool), subject_id (the subject of an event
    %                  with no dataset; omitted when ""), event, inputs, outputs
    %                  ("edges": event_id,
    %                  inputs; "files": event_id, artifacts, dispositions)
    %
    %   Everything the database stores as JSON (parameters, environment,
    %   attributes) is kept as JSON text in a string member (*_json), so it
    %   is sent exactly as captured and never decoded and encoded again.
    %   Times are text with their zone offset and microseconds (timeText).
    %
    %     b = labclient.Bundles.event(Name=Value)     % build a bundle
    %     it = labclient.Bundles.item(path, Role=, Kind=, ...)   % an input or output file
    %     b = labclient.Bundles.seal(b)               % the digest, once complete
    %     txt = labclient.Bundles.encode(b); b = labclient.Bundles.decode(txt)
    %
    %   The other helpers: timeText (a zoned datetime as text), newId (a
    %   random uuid), snapshot (a file's size and time), sameSnapshot.
    %
    %   See also labclient.Outbox, labclient.Sync, labclient.Hasher.

    properties (Constant)
        Format = "caraslabdb-bundle/1"
        TimeFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx"
        MtimeFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"
        ItemFields = ["artifact_id" "path" "root" "rel" "bytes" "mtime" "sha256" "role" ...
            "format" "kind" "replaces" "attributes_json"]
        Untagged = "(untagged)"   % what toolOf gives for a dataset record that names no tool; never a tool's name
    end

    methods (Static)
        function t = timeText(dt)
            %timeText  A zoned datetime as text with its offset and microseconds ("" for NaT).
            %   "2026-11-14T09:30:00.123456-05:00". An unzoned datetime is an
            %   error (labclient:Bundles:Unzoned): a record sent later, or from
            %   another computer, must not depend on where it is sent from.
            arguments
                dt (1,1) datetime
            end
            if isnat(dt)
                t = "";
                return
            end
            if isempty(dt.TimeZone)
                error("labclient:Bundles:Unzoned", "A time recorded for the lab database must carry its time zone.");
            end
            dt.Format = labclient.Bundles.TimeFormat;
            t = string(dt);
        end

        function t = now()
            %now  This moment as timeText.
            t = labclient.Bundles.timeText(datetime("now", "TimeZone", "local"));
        end

        function id = newId()
            %newId  A random (version 4) uuid, lowercase.
            %   From the operating system's secure generator (Java's
            %   SecureRandom); where Java is not there (a thread-based
            %   worker) from a private random stream seeded from the clock,
            %   this process and a counter. Neither touches MATLAB's global
            %   random stream, which a caller's experiment may be drawing from.
            try
                id = string(lower(char(java.util.UUID.randomUUID().toString())));
            catch
                id = labclient.Bundles.uuidWithoutJava();
            end
        end

        function s = snapshot(file)
            %snapshot  FILE's size in bytes and modification time (ms, zoned text); NaN and "" when it is not there.
            s = struct("bytes", NaN, "mtime", "");
            d = dir(file);
            if ~isscalar(d) || d.isdir
                return
            end
            s.bytes = double(d.bytes);
            s.mtime = labclient.Bundles.mtimeText(d.datenum);
        end

        function tf = sameSnapshot(a, b)
            %sameSnapshot  True when snapshots (or items) A and B have the same size and time.
            tf = isequal(double(a.bytes), double(b.bytes)) && ~isnan(double(a.bytes)) ...
                && string(a.mtime) == string(b.mtime);
        end

        function it = item(path, opts)
            %item  An input or output file of a record, snapshot taken now.
            %   IT = labclient.Bundles.item(PATH, Role=, Kind=, Format=, ArtifactId=,
            %   Root=, Rel=, Sha256=, Replaces=, Attributes=): the fields of
            %   ItemFields. Format defaults to the extension, lowercase;
            %   attributes_json is the JSON object of Attributes (a struct)
            %   with kind set.
            arguments
                path (1,1) string
                opts.Role (1,1) string = "derived"
                opts.Kind (1,1) string = ""
                opts.Format (1,1) string = string(missing)
                opts.ArtifactId (1,1) string = ""
                opts.Root (1,1) string = ""
                opts.Rel (1,1) string = ""
                opts.Sha256 (1,1) string = ""
                opts.Replaces (1,1) string = ""
                opts.Attributes (1,1) struct = struct()
                opts.Snapshot = []
            end
            fmt = opts.Format;
            if ismissing(fmt)
                [~, ~, ext] = fileparts(path);
                fmt = lower(erase(string(ext), "."));
            end
            snap = opts.Snapshot;
            if isempty(snap); snap = labclient.Bundles.snapshot(path); end
            a = struct("kind", opts.Kind);
            for f = string(fieldnames(opts.Attributes)).'
                a.(f) = opts.Attributes.(f);
            end
            it = struct("artifact_id", opts.ArtifactId, "path", path, "root", opts.Root, ...
                "rel", opts.Rel, "bytes", snap.bytes, "mtime", string(snap.mtime), ...
                "sha256", opts.Sha256, "role", opts.Role, "format", fmt, "kind", opts.Kind, ...
                "replaces", opts.Replaces, "attributes_json", string(jsonencode(a)));
        end

        function items = toItems(in)
            %toItems  IN (a struct array, a cell of structs, [] or a decoded JSON list) as a row of items with every field.
            items = labclient.Bundles.items(in);
        end

        function items = noItems()
            %noItems  An empty list of items, with every field.
            c = cell(1, 2 * numel(labclient.Bundles.ItemFields));
            c(1:2:end) = cellstr(labclient.Bundles.ItemFields);
            c(2:2:end) = {{}};
            items = struct(c{:});
        end

        function b = event(opts)
            %event  A bundle for one event (see the class help for the members).
            %   B = labclient.Bundles.event(EventId=, EventType=, OccurredAt=,
            %   Detail=, Attributes=, Notes=, Performer=, Dataset=, SubjectId=,
            %   Inputs=, Outputs=, CapturedAt=, CapturedBy=, After=).
            %   EventType is "analysis", "recording", "behavior" or
            %   "husbandry"; OccurredAt text from timeText; Detail a struct of
            %   the type's detail columns (parameters and environment as
            %   parameters_json / environment_json text; husbandry: measure,
            %   weight_g, water_ml, health_status); Attributes a struct.
            %
            %   Dataset (noDataset, the default, or a struct with a folder
            %   and a tool, for a record about a dataset folder) and
            %   SubjectId are two ways to say whom the event is about. With
            %   a Dataset folder the dataset's session decides (SubjectId
            %   must then be ""). With none, SubjectId names the subject
            %   directly: the event is sent for that subject with no session
            %   (a behavior or husbandry event needs none), and a subject the
            %   database does not have holds it (labclient.Sync.subjectHolds).
            %   Only an analysis event may name nobody.
            arguments
                opts.EventId (1,1) string
                opts.EventType (1,1) string {mustBeMember(opts.EventType, ["analysis" "recording" "behavior" "husbandry"])}
                opts.OccurredAt (1,1) string
                opts.Detail (1,1) struct = struct()
                opts.Attributes (1,1) struct = struct()
                opts.Notes (1,1) string = ""
                opts.Performer (1,1) struct = struct("person_id", "", "person_email", "")
                opts.Dataset (1,1) struct = labclient.Bundles.noDataset()
                opts.SubjectId (1,1) string = ""
                opts.Inputs struct = labclient.Bundles.noItems()
                opts.Outputs struct = labclient.Bundles.noItems()
                opts.CapturedAt (1,1) string = ""
                opts.CapturedBy (1,1) struct = labclient.Bundles.capturedBy()
                opts.After (1,:) string = string.empty(1, 0)
            end
            opts.SubjectId = strtrim(opts.SubjectId);
            if string(opts.Dataset.folder) ~= "" && opts.SubjectId ~= ""
                error("labclient:Bundles:SubjectAndDataset", ...
                    "An event about a dataset folder takes its subject from the dataset's session: leave SubjectId empty.");
            end
            if opts.CapturedAt == ""; opts.CapturedAt = labclient.Bundles.now(); end
            ev = struct("event_id", opts.EventId, "event_type", opts.EventType, ...
                "occurred_at", opts.OccurredAt, "notes", opts.Notes, ...
                "performer", struct("person_id", string(opts.Performer.person_id), ...
                "person_email", string(opts.Performer.person_email)), ...
                "attributes_json", string(jsonencode(opts.Attributes)), "detail", opts.Detail);
            rec = struct("dataset", labclient.Bundles.dataset(opts.Dataset), "subject_id", opts.SubjectId, ...
                "event", ev, "inputs", labclient.Bundles.items(opts.Inputs), ...
                "outputs", labclient.Bundles.items(opts.Outputs));
            b = struct("format", labclient.Bundles.Format, "bundle_id", opts.EventId, "type", "event", ...
                "captured_at", opts.CapturedAt, "captured_by", opts.CapturedBy, ...
                "after", opts.After, "digest", "", "record", rec);
        end

        function b = edges(opts)
            %edges  A bundle of input edges to add to event EventId once their files are in the database.
            arguments
                opts.EventId (1,1) string
                opts.Inputs struct
                opts.After (1,:) string = string.empty(1, 0)
                opts.CapturedBy (1,1) struct = labclient.Bundles.capturedBy()
            end
            rec = struct("event_id", opts.EventId, "inputs", labclient.Bundles.items(opts.Inputs));
            b = struct("format", labclient.Bundles.Format, "bundle_id", labclient.Bundles.newId(), "type", "edges", ...
                "captured_at", labclient.Bundles.now(), "captured_by", opts.CapturedBy, ...
                "after", opts.After, "digest", "", "record", rec);
            b = labclient.Bundles.seal(b);
        end

        function b = files(opts)
            %files  A bundle of files of an event already recorded (or about to be): new files and what became of old ones.
            %   B = labclient.Bundles.files(EventId=E, Artifacts=items,
            %   Dispositions=, Attributes=, After=, CapturedBy=). Outputs= is
            %   the same list as Artifacts= (use either).
            %
            %   The files are items (labclient.Bundles.item) that become files
            %   of event E, registered once each. Sent, it waits while E is not
            %   in the database. Two uses:
            %     - a copy of a file a step wrote, as a file of that step: the
            %       item's attributes name what it copies (copied_from,
            %       copied_from_sha256); a copy that is not its source's bytes
            %       is held;
            %     - NEW BYTES AT THE SAME PATH as a file of E already sent
            %       (a session file saved again, a report redone): the item
            %       is the new file (its sha256 and the same Root/Rel or path)
            %       and its Replaces is the artifact_id of the file it takes
            %       the place of. The new file is registered as a file of E
            %       and the old one recorded as "replaced" by it, so the
            %       database does not hold two present files at one path.
            %       Replaces may name any earlier version of the file (the
            %       first one, each time it is saved again): one that was
            %       replaced since is followed to the version at the path
            %       now, which is the one recorded as replaced. When a later
            %       save reached the database first, this file is the
            %       earlier version and is the one recorded as replaced
            %       (labclient.Sync.replaceFile). An earlier file the
            %       database does not have is noted and left; one moved or
            %       deleted since is left. A file already registered with
            %       the same bytes is that file. (An output of an EVENT
            %       record is different: its Replaces must name the file
            %       present at the path, see CarasLabDB.recordEvent.)
            %   Dispositions a struct array (labclient.Bundles.disposition).
            %   It is sealed when every file's SHA-256 is known (the hasher
            %   takes it, as for an event).
            arguments
                opts.EventId (1,1) string
                opts.Artifacts struct = labclient.Bundles.noItems()
                opts.Outputs struct = labclient.Bundles.noItems()
                opts.Dispositions struct = labclient.Bundles.noDispositions()
                opts.Attributes (1,1) struct = struct()
                opts.After (1,:) string = string.empty(1, 0)
                opts.CapturedBy (1,1) struct = labclient.Bundles.capturedBy()
            end
            files = labclient.Bundles.items(opts.Artifacts);
            if ~isempty(opts.Outputs)
                files = [files, labclient.Bundles.items(opts.Outputs)];
            end
            rec = struct("event_id", opts.EventId, "attributes_json", string(jsonencode(opts.Attributes)), ...
                "outputs", labclient.Bundles.items(files), ...
                "dispositions", labclient.Bundles.dispositionRows(opts.Dispositions));
            b = struct("format", labclient.Bundles.Format, "bundle_id", labclient.Bundles.newId(), "type", "files", ...
                "captured_at", labclient.Bundles.now(), "captured_by", opts.CapturedBy, ...
                "after", opts.After, "digest", "", "record", rec);
            b = labclient.Bundles.seal(b);
        end

        function d = disposition(artifactId, what, opts)
            %disposition  One disposition row: what became of artifact ARTIFACTID's file.
            %   WHAT is "moved", "deleted", "replaced" or "restored";
            %   Successor (the artifact id of the file's new place, for
            %   "moved"), OccurredAt (zoned text; default now), Note,
            %   Attributes (a struct, e.g. method "recycle").
            arguments
                artifactId (1,1) string
                what (1,1) string {mustBeMember(what, ["moved" "deleted" "replaced" "restored"])}
                opts.Successor (1,1) string = ""
                opts.OccurredAt (1,1) string = ""
                opts.Note (1,1) string = ""
                opts.Attributes (1,1) struct = struct()
            end
            if opts.OccurredAt == ""; opts.OccurredAt = labclient.Bundles.now(); end
            d = struct("artifact_id", artifactId, "disposition", what, "successor_artifact_id", opts.Successor, ...
                "occurred_at", opts.OccurredAt, "note", opts.Note, ...
                "attributes_json", string(jsonencode(opts.Attributes)));
        end

        function d = noDispositions()
            %noDispositions  An empty list of disposition rows.
            d = struct("artifact_id", {}, "disposition", {}, "successor_artifact_id", {}, ...
                "occurred_at", {}, "note", {}, "attributes_json", {});
        end

        function d = noDataset()
            %noDataset  The dataset block of a record about no dataset.
            %   name, folder, session_id, subject_folder_id, recording_start
            %   as the toolbox that owns the dataset knows them, and TOOL: the
            %   name that toolbox registered with labclient.Sync.registerTool
            %   ("" for a record of no dataset). A record with a folder
            %   names its tool: one that names none (written before records
            %   named their tool) is sent only by the tool registered with
            %   TakesUntagged=true (see toolOf).
            d = struct("name", "", "folder", "", "session_id", "", "subject_folder_id", "", ...
                "recording_start", "", "tool", "");
        end

        function d = dataset(d)
            %dataset  D as a complete dataset block: every member of noDataset, as a string.
            base = labclient.Bundles.noDataset();
            for f = reshape(string(fieldnames(base)), 1, [])
                if ~isfield(d, f) || isempty(d.(f)); d.(f) = base.(f); end
                d.(f) = string(d.(f));
            end
        end

        function tool = toolOf(b)
            %toolOf  The tool whose hooks sending bundle B needs: "" for a record of no dataset folder.
            %   A record of a dataset folder gives the tool it names
            %   (dataset.tool). One that names none gives
            %   labclient.Bundles.Untagged: no tool is assumed for it, and
            %   labclient.Sync sends it only through the tool that registered
            %   with TakesUntagged=true.
            tool = "";
            if ~isstruct(b) || ~isfield(b, "record") || ~isfield(b.record, "dataset"); return; end
            d = b.record.dataset;
            if ~isfield(d, "folder") || strlength(string(d.folder)) == 0; return; end
            if isfield(d, "tool") && strlength(string(d.tool)) > 0
                tool = string(d.tool);
            else
                tool = labclient.Bundles.Untagged;
            end
        end

        function c = capturedBy(s)
            %capturedBy  Who and where a bundle is captured: host, os_user and the database login and person set up here.
            if nargin < 1; s = labclient.Settings.load(); end
            c = struct("host", labclient.Bundles.host(), "os_user", labclient.Bundles.osUser(), ...
                "db_username", s.Username, "person_id", s.PersonId, "person_email", s.PersonEmail);
        end

        function h = host()
            %host  This computer's name.
            h = string(getenv('COMPUTERNAME'));
            if h == ""; h = string(getenv('HOSTNAME')); end
            if h == ""
                [st, out] = system('hostname');
                if st == 0; h = strtrim(string(out)); end
            end
        end

        function u = osUser()
            %osUser  The operating-system user running MATLAB.
            u = string(getenv('USERNAME'));
            if u == ""; u = string(getenv('USER')); end
        end

        function n = missingHashes(b)
            %missingHashes  How many outputs of B have no SHA-256 yet.
            n = 0;
            if ~isfield(b.record, "outputs"); return; end
            o = b.record.outputs;
            for k = 1:numel(o)
                if strlength(string(o(k).sha256)) ~= 64; n = n + 1; end
            end
        end

        function b = seal(b)
            %seal  Set B's digest when every output's SHA-256 is known (else leave it "").
            if labclient.Bundles.missingHashes(b) > 0
                b.digest = "";
                return
            end
            b.digest = labclient.fileSha256(labclient.Bundles.encodeRecord(b.record), Text=true);
        end

        function tf = isSealed(b)
            %isSealed  True when B carries its digest.
            tf = strlength(string(b.digest)) == 64;
        end

        function txt = encode(b)
            %encode  B as the canonical JSON text written to its file.
            e = b;
            e.after = cellstr(string(b.after));
            e.record = labclient.Bundles.canonicalRecord(b.record);
            txt = string(jsonencode(e));
        end

        function b = decode(txt)
            %decode  A bundle from its JSON text, every list as a struct array with every field.
            %   labclient:Bundles:Format when TXT is not a caraslabdb-bundle/1 bundle.
            try
                b = jsondecode(char(txt));
            catch ME
                error("labclient:Bundles:Format", "Not a bundle: %s", ME.message);
            end
            if ~isstruct(b) || ~isfield(b, "format") || string(b.format) ~= labclient.Bundles.Format ...
                    || ~isfield(b, "record") || ~isfield(b, "bundle_id")
                error("labclient:Bundles:Format", "Not a %s bundle.", labclient.Bundles.Format);
            end
            b.format = string(b.format);
            b.bundle_id = string(b.bundle_id);
            b.type = string(b.type);
            b.captured_at = string(b.captured_at);
            b.digest = string(b.digest);
            b.after = reshape(string(b.after), 1, []);
            if isempty(b.after); b.after = string.empty(1, 0); end
            b.captured_by = labclient.Bundles.strings(b.captured_by);
            r = b.record;
            if b.type == "edges"
                r.event_id = string(r.event_id);
                r.inputs = labclient.Bundles.items(r.inputs);
                b.record = r;
                return
            end
            if b.type == "files"
                r.event_id = string(r.event_id);
                r.attributes_json = string(r.attributes_json);
                r.outputs = labclient.Bundles.items(r.outputs);
                r.dispositions = labclient.Bundles.dispositionRows(r.dispositions);
                b.record = r;
                return
            end
            r.dataset = labclient.Bundles.dataset(labclient.Bundles.strings(r.dataset));
            if isfield(r, "subject_id") && ~isempty(r.subject_id)
                r.subject_id = string(r.subject_id);
            else
                r.subject_id = "";   % a record written before records could name their subject
            end
            ev = r.event;
            for f = ["event_id" "event_type" "occurred_at" "notes" "attributes_json"]
                ev.(f) = string(ev.(f));
            end
            ev.performer = labclient.Bundles.strings(ev.performer);
            if isempty(ev.detail); ev.detail = struct(); end
            for f = string(fieldnames(ev.detail)).'
                v = ev.detail.(f);
                if ischar(v) || iscellstr(v); ev.detail.(f) = string(v); end
            end
            r.event = ev;
            r.inputs = labclient.Bundles.items(r.inputs);
            r.outputs = labclient.Bundles.items(r.outputs);
            b.record = r;
        end

        function txt = encodeRecord(rec)
            %encodeRecord  The canonical JSON text of a record (what the digest is taken of).
            txt = string(jsonencode(labclient.Bundles.canonicalRecord(rec)));
        end
    end

    methods (Static, Access = private)
        function id = uuidWithoutJava()
            %uuidWithoutJava  A version 4 uuid from a private stream (never the global one).
            persistent stream count
            if isempty(stream)
                count = 0;
                pid = 0;
                try
                    pid = double(feature('getpid'));
                catch
                end
                t = posixtime(datetime("now", "TimeZone", "UTC"));
                seed = mod(floor(t * 1e6) + pid * 7919 + sum(double(char(getenv('COMPUTERNAME')))) * 104729, 2^32 - 1);
                stream = RandStream("threefry", "Seed", seed);
            end
            count = count + 1;
            stream.Substream = count;
            b = randi(stream, [0 255], 1, 16);
            b(7) = bitor(bitand(b(7), 15), 64);    % version 4
            b(9) = bitor(bitand(b(9), 63), 128);   % variant 10
            h = lower(reshape(dec2hex(b, 2).', 1, []));
            id = string(h(1:8) + "-" + h(9:12) + "-" + h(13:16) + "-" + h(17:20) + "-" + h(21:32));
        end

        function t = mtimeText(dn)
            %mtimeText  A dir() datenum as zoned text to the millisecond.
            dt = datetime(dn, "ConvertFrom", "datenum", "TimeZone", "local");
            dt.Format = labclient.Bundles.MtimeFormat;
            t = string(dt);
        end

        function items = items(in)
            %items  IN (a struct array, a cell of structs, [] or a decoded list) as a struct row with every item field.
            items = labclient.Bundles.noItems();
            if isempty(in); return; end
            if isstruct(in); in = num2cell(in); end
            for k = 1:numel(in)
                x = in{k};
                it = struct();
                for f = labclient.Bundles.ItemFields
                    if isfield(x, f); v = x.(f); else; v = []; end
                    if f == "bytes"
                        if isempty(v); v = NaN; end
                        it.(f) = double(v);
                    else
                        if isempty(v); v = ""; end
                        it.(f) = string(v);
                    end
                end
                items(1, end + 1) = it; %#ok<AGROW>
            end
        end

        function s = strings(s)
            %strings  Every char member of the scalar struct S as a string.
            if isempty(s); s = struct(); return; end
            for f = string(fieldnames(s)).'
                v = s.(f);
                if ischar(v) || (isnumeric(v) && isempty(v)); s.(f) = string(v); end
                if isempty(s.(f)) && isstring(s.(f)); s.(f) = ""; end
            end
        end

        function r = canonicalRecord(rec)
            %canonicalRecord  REC with its lists as cells, so a list of one is still a JSON list.
            r = rec;
            % optional members left out while empty, so a record written before they existed
            % (and its digest) reads and writes back exactly as it was
            if isfield(r, "dataset") && isfield(r.dataset, "tool") && strlength(string(r.dataset.tool)) == 0
                r.dataset = rmfield(r.dataset, "tool");
            end
            if isfield(r, "subject_id") && strlength(string(r.subject_id)) == 0
                r = rmfield(r, "subject_id");
            end
            if isfield(rec, "inputs"); r.inputs = labclient.Bundles.itemCells(rec.inputs); end
            if isfield(rec, "outputs"); r.outputs = labclient.Bundles.itemCells(rec.outputs); end
            if isfield(rec, "dispositions"); r.dispositions = num2cell(labclient.Bundles.dispositionRows(rec.dispositions)); end
        end

        function d = dispositionRows(in)
            %dispositionRows  IN (struct array, cell, [] or decoded) as a row of disposition rows, every field a string.
            d = labclient.Bundles.noDispositions();
            if isempty(in); return; end
            if isstruct(in); in = num2cell(in); end
            f = string(fieldnames(labclient.Bundles.noDispositions())).';
            for k = 1:numel(in)
                x = in{k};
                row = struct();
                for g = f
                    v = "";
                    if isfield(x, g) && ~isempty(x.(g)); v = string(x.(g)); end
                    row.(g) = v;
                end
                d(1, end + 1) = row; %#ok<AGROW>
            end
        end

        function c = itemCells(items)
            items = labclient.Bundles.items(items);
            c = cell(1, numel(items));
            for k = 1:numel(items)
                c{k} = items(k);   % a size not known (NaN) is written null
            end
        end
    end
end
