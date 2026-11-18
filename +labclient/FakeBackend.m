classdef FakeBackend < labclient.Backend
    % labclient.FakeBackend  An in-memory lab database for the tests: no server, the same answers.
    %   Set Reachable false to stand for a server that does not answer, and
    %   Refuse to a message to make open fail as a server that answers and
    %   refuses would. Tables can be filled directly (Roots, Sessions,
    %   Artifacts, Subjects, Projects, Species, Persons); Calls records every
    %   method called, in order.
    %
    %   recordEvent keeps CarasLabDB's rules: the same id and digest again is
    %   "existing" (nothing written), the same id with another digest is
    %   CarasLabDB:idConflict, a session or subject that is not there is
    %   refused (the foreign keys), a file already registered with the same
    %   bytes at the same path is reused (Unchanged), an input or a
    %   "replaces" row that is not there is skipped. Dispositions keeps
    %   when each happened (occurred_at, as the database does), and
    %   addDisposition refuses what the database's policy refuses: a file
    %   already gone, a "replaced" file whose successor is not other bytes
    %   at the same path, a "moved" one whose successor is not the same
    %   bytes at another place, a "deleted" or "restored" one with a
    %   successor, no time. recordEvent refuses a Detail field that is not
    %   a column of the event's type (labclient.Bundles.detailColumns), an
    %   analysis status that is none of the three, and no time. Fail makes the next
    %   call of a method fail: struct("Method", "recordEvent", "Identifier",
    %   "CarasLabDB:transactionInterrupted", "Message", "...", "AfterWrite",
    %   false); AfterWrite true writes first and then fails, as a commit
    %   whose answer was lost.
    %
    %   Event types: analysis, recording, behavior and husbandry (Detail
    %   measure, weight_g, water_ml, health_status). Every type but analysis
    %   needs a subject, as the database's event_subject_required_ck does.
    %   subjectCurrent answers as lab.subject_current: the latest weight is
    %   the newest husbandry event's weight_g; SubjectInfo (subject_id,
    %   date_of_birth, endpoint_at) fills what no event here gives. Variables
    %   (entity_kind, entity_id, variable, value, value_num, value_text,
    %   units, set_at) answers variableValues.
    %
    %     fake = labclient.FakeBackend();
    %     restore = labclient.DB.useBackend(@() fake);   % labclient.DB uses it until cleared
    %
    %   See also labclient.Backend, labclient.DB.

    properties
        Reachable (1,1) logical = true
        Refuse (1,1) string = ""            % open fails with this message (labclient:Refused)
        Password (1,1) string = "pw"        % the one open accepts
        PersonId (1,1) string = "00000000-0000-4000-8000-0000000000a1"
        Login (1,1) string = "jdoe"
        Roots table = table(zeros(0, 1), strings(0, 1), strings(0, 1), ...
            'VariableNames', {'root_id', 'name', 'description'})
        Sessions table = table(strings(0, 1), strings(0, 1), strings(0, 1), zeros(0, 1), strings(0, 1), ...
            NaT(0, 1, "TimeZone", "UTC"), 'VariableNames', {'session_id', 'subject_id', 'label', ...
            'storage_root_id', 'relative_path', 'started_at'})
        Artifacts table = table(strings(0, 1), strings(0, 1), zeros(0, 1), strings(0, 1), strings(0, 1), ...
            zeros(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), ...
            'VariableNames', {'artifact_id', 'produced_by_event_id', 'storage_root_id', 'relative_path', ...
            'checksum', 'size_bytes', 'role', 'format', 'subject_id', 'session_id', 'attributes'})
        Subjects table = table(strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), ...
            'VariableNames', {'subject_id', 'project_id', 'species_code', 'sex'})
        Projects table = table("P1", "Project one", 'VariableNames', {'project_id', 'name'})
        Species table = table(["meriones_unguiculatus"; "mus_musculus"], ["Mongolian gerbil"; "House mouse"], ...
            'VariableNames', {'code', 'common_name'})
        Persons table = table("00000000-0000-4000-8000-0000000000a1", "jdoe@example.edu", "J. Doe", ...
            'VariableNames', {'person_id', 'email', 'full_name'})
        SubjectInfo table = table(strings(0, 1), NaT(0, 1), NaT(0, 1, "TimeZone", "UTC"), ...
            'VariableNames', {'subject_id', 'date_of_birth', 'endpoint_at'})
        Variables table = table(strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), zeros(0, 1), ...
            strings(0, 1), strings(0, 1), NaT(0, 1, "TimeZone", "UTC"), 'VariableNames', {'entity_kind', ...
            'entity_id', 'variable', 'value', 'value_num', 'value_text', 'units', 'set_at'})
        Fail struct = struct("Method", {}, "Identifier", {}, "Message", {}, "AfterWrite", {})
        DispositionTimes (1,1) logical = true   % false: dispositions come back with no occurred_at, as a backend that gives none
        Verifications table = table(strings(0, 1), strings(0, 1), NaT(0, 1, "TimeZone", "UTC"), ...
            'VariableNames', {'artifact_id', 'status', 'verified_at'})
    end

    properties (SetAccess = private)
        Events struct = struct("event_id", {}, "event_type", {}, "occurred_at", {}, "subject_id", {}, ...
            "session_id", {}, "digest", {}, "recorded_by", {}, "notes", {}, "attributes", {}, "detail", {})
        Inputs table = table(strings(0, 1), strings(0, 1), strings(0, 1), ...
            'VariableNames', {'event_id', 'artifact_id', 'role'})
        Dispositions table = table(strings(0, 1), strings(0, 1), strings(0, 1), NaT(0, 1, "TimeZone", "UTC"), ...
            'VariableNames', {'artifact_id', 'disposition', 'successor_artifact_id', 'occurred_at'})
    end

    properties (SetAccess = private)
        Open (1,1) logical = false
        Calls (:,1) string = strings(0, 1)
        Opens (1,1) double = 0
    end

    methods
        function [ok, why] = probe(obj, ~)
            obj.Calls(end+1) = "probe";
            ok = obj.Reachable;
            why = "";
            if ~ok
                why = "the server did not answer (fake)";
            end
        end

        function open(obj, ~, password)
            obj.Calls(end+1) = "open";
            obj.Opens = obj.Opens + 1;
            if ~obj.Reachable
                error("labclient:Unreachable", "The server did not answer (fake).");
            end
            if obj.Refuse ~= ""
                error("labclient:Refused", "%s", obj.Refuse);
            end
            if password ~= obj.Password
                error("labclient:Refused", "password authentication failed (fake)");
            end
            obj.Open = true;
        end

        function tf = isOpen(obj)
            tf = obj.Open && obj.Reachable;
        end

        function close(obj)
            obj.Calls(end+1) = "close";
            obj.Open = false;
        end

        function p = person(obj)
            obj.requireOpen("person");
            p = struct("PersonId", obj.PersonId, "Login", obj.Login);
        end

        function T = storageRoots(obj)
            obj.requireOpen("storageRoots");
            T = obj.Roots;
        end

        function id = addStorageRoot(obj, name, description)
            obj.requireOpen("addStorageRoot");
            if any(obj.Roots.name == string(name))
                error("labclient:Refused", "duplicate key value violates unique constraint " + ...
                    "storage_root_name_key (fake)");
            end
            id = max([0; obj.Roots.root_id]) + 1;
            obj.Roots = [obj.Roots; table(id, string(name), string(description), ...
                'VariableNames', {'root_id', 'name', 'description'})];
        end

        function T = sessions(obj, filters)
            obj.requireOpen("sessions");
            T = labclient.FakeBackend.filterRows(obj.Sessions, filters);
        end

        function T = artifacts(obj, filters)
            obj.requireOpen("artifacts");
            T = labclient.FakeBackend.filterRows(obj.Artifacts, filters);
            if isfield(filters, "PresentOnly") && isequal(filters.PresentOnly, true)
                % as lab.artifact_present: not replaced, moved or deleted since (or restored)
                gone = false(height(T), 1);
                for k = 1:height(T)
                    D = obj.Dispositions(obj.Dispositions.artifact_id == T.artifact_id(k), :);
                    gone(k) = height(D) > 0 && D.disposition(end) ~= "restored";
                end
                T = T(~gone, :);
            end
        end

        function T = subjects(obj, filters)
            obj.requireOpen("subjects");
            T = labclient.FakeBackend.filterRows(obj.Subjects, filters);
        end

        function T = projects(obj)
            obj.requireOpen("projects");
            T = obj.Projects;
        end

        function T = species(obj)
            obj.requireOpen("species");
            T = obj.Species;
        end

        function T = persons(obj, filters)
            obj.requireOpen("persons");
            if isfield(filters, "Email")
                T = obj.Persons(lower(obj.Persons.email) == lower(string(filters.Email)), :);
                filters = rmfield(filters, "Email");
            else
                T = obj.Persons;
            end
            T = labclient.FakeBackend.filterRows(T, filters);
        end

        function id = addSubject(obj, a)
            obj.requireOpen("addSubject");
            obj.maybeFail("addSubject", false);
            if any(obj.Subjects.subject_id == a.SubjectId)
                error("labclient:Refused", "duplicate key value violates unique constraint subject_pkey (fake)");
            end
            if ~any(obj.Projects.project_id == a.ProjectId)
                error("labclient:Refused", "project %s does not exist (fake foreign key)", a.ProjectId);
            end
            sp = "";
            if isfield(a, "SpeciesCode"); sp = string(a.SpeciesCode); end
            obj.Subjects = [obj.Subjects; table(string(a.SubjectId), string(a.ProjectId), sp, ...
                string(a.Sex), 'VariableNames', obj.Subjects.Properties.VariableNames)];
            id = string(a.SubjectId);
        end

        function id = addSession(obj, a)
            obj.requireOpen("addSession");
            obj.maybeFail("addSession", false);
            if any(obj.Sessions.session_id == a.SessionId)
                error("labclient:Refused", "duplicate key value violates unique constraint session_pkey (fake)");
            end
            if ~any(obj.Subjects.subject_id == a.SubjectId)
                error("labclient:Refused", "subject %s does not exist (fake foreign key)", a.SubjectId);
            end
            if ~any(obj.Roots.root_id == a.StorageRootId)
                error("labclient:Refused", "storage root %d does not exist (fake foreign key)", a.StorageRootId);
            end
            t = NaT("TimeZone", "UTC");
            if isfield(a, "StartedAt") && ~isnat(a.StartedAt); t = a.StartedAt; t.TimeZone = "UTC"; end
            obj.Sessions = [obj.Sessions; table(string(a.SessionId), string(a.SubjectId), string(a.Label), ...
                double(a.StorageRootId), string(a.RelativePath), t, ...
                'VariableNames', obj.Sessions.Properties.VariableNames)];
            id = string(a.SessionId);
        end

        function out = recordEvent(obj, req)
            obj.requireOpen("recordEvent");
            obj.maybeFail("recordEvent", false);
            if isempty(req.OccurredAt.TimeZone)
                error("CarasLabDB:unzonedTime", "OccurredAt has no time zone (fake).");
            end
            if ~any(string(req.EventType) == ["analysis" "recording" "behavior" "husbandry"])
                error("MATLAB:validators:mustBeMember", "EventType %s cannot be recorded (fake).", req.EventType);
            end
            if isnat(req.OccurredAt)
                error("labclient:Refused", "null value in column occurred_at (fake not-null constraint)");
            end
            % as CarasLabDB.recordEvent: a Detail field must be a column of that type of event
            % (a JSON column arrives as <name>_json, which labclient.CarasBackend renames)
            allowed = labclient.Bundles.detailColumns(string(req.EventType));
            given = reshape(string(fieldnames(req.Detail)), 1, []);
            for j = labclient.Bundles.JsonDetail
                given(given == j + "_json") = j;
            end
            bad = setdiff(given, allowed);
            if ~isempty(bad)
                error("CarasLabDB:invalidValue", "Detail cannot set %s (allowed: %s).", ...
                    strjoin(bad, ", "), strjoin(allowed, ", "));
            end
            if string(req.EventType) == "analysis" && isfield(req.Detail, "status") ...
                    && (ischar(req.Detail.status) || isstring(req.Detail.status)) ...
                    && ~any(string(req.Detail.status) == labclient.Bundles.Statuses)
                error("CarasLabDB:invalidValue", "Detail.status must be one of %s (fake).", ...
                    strjoin(labclient.Bundles.Statuses, ", "));
            end
            if string(req.EventType) == "husbandry"
                if ~isfield(req.Detail, "measure") || strlength(strtrim(string(req.Detail.measure))) == 0
                    error("labclient:Refused", "a husbandry event needs a measure (fake check)");
                end
                if isfield(req.Detail, "weight_g") && ~isempty(req.Detail.weight_g) && ~(req.Detail.weight_g > 0)
                    error("labclient:Refused", "weight_g must be positive (fake check)");
                end
                if isfield(req.Detail, "water_ml") && ~isempty(req.Detail.water_ml) && ~(req.Detail.water_ml >= 0)
                    error("labclient:Refused", "water_ml must not be negative (fake check)");
                end
            end
            out = struct("EventId", req.EventId, "Outcome", "existing", "OutputIds", strings(0, 1), ...
                "Unchanged", false(0, 1), "SkippedInputs", strings(0, 1), "SkippedReplaces", strings(0, 1));
            k = find(string({obj.Events.event_id}) == req.EventId, 1);
            if ~isempty(k)
                if obj.Events(k).digest ~= req.Digest
                    error("CarasLabDB:idConflict", ...
                        "Event %s was recorded before with other content (fake).", req.EventId);
                end
                mine = obj.Artifacts.produced_by_event_id == req.EventId;
                out.OutputIds = obj.Artifacts.artifact_id(mine);
                return
            end
            if strlength(req.SessionId) > 0 && ~any(obj.Sessions.session_id == req.SessionId)
                error("labclient:Refused", "session %s does not exist (fake foreign key)", req.SessionId);
            end
            subject = req.SubjectId;
            if strlength(req.SessionId) > 0
                subject = obj.Sessions.subject_id(obj.Sessions.session_id == req.SessionId);
                if strlength(req.SubjectId) > 0 && req.SubjectId ~= subject
                    error("labclient:Refused", "the event's subject is not its session's (fake)");
                end
            end
            if strlength(subject) > 0 && ~any(obj.Subjects.subject_id == subject)
                error("labclient:Refused", "subject %s does not exist (fake foreign key)", subject);
            end
            if strlength(subject) == 0 && string(req.EventType) ~= "analysis"
                error("labclient:Refused", "a %s event needs a subject (fake event_subject_required_ck)", req.EventType);
            end
            jsondecode(char(req.AttributesJson));   % refused as the database would, when it is no JSON
            n = numel(req.Outputs);
            ids = strings(n, 1);
            unchanged = false(n, 1);
            newRows = obj.Artifacts([], :);
            for j = 1:n
                o = req.Outputs(j);
                hit = obj.Artifacts.storage_root_id == o.storage_root_id & ...
                    obj.Artifacts.relative_path == o.relative_path & obj.Artifacts.checksum == lower(o.checksum);
                if any(hit)
                    ids(j) = obj.Artifacts.artifact_id(find(hit, 1));
                    unchanged(j) = true;
                    continue
                end
                if ~any(obj.Roots.root_id == o.storage_root_id)
                    error("labclient:Refused", "storage root %d does not exist (fake foreign key)", o.storage_root_id);
                end
                ids(j) = string(o.artifact_id);
                if ids(j) == ""; ids(j) = labclient.Bundles.newId(); end
                jsondecode(char(o.attributes_json));
                newRows = [newRows; table(ids(j), string(req.EventId), double(o.storage_root_id), ...
                    string(o.relative_path), lower(string(o.checksum)), double(o.size_bytes), string(o.role), ...
                    string(o.format), subject, string(req.SessionId), string(o.attributes_json), ...
                    'VariableNames', obj.Artifacts.Properties.VariableNames)]; %#ok<AGROW>
            end
            known = [obj.Artifacts.artifact_id; newRows.artifact_id];
            skipped = strings(0, 1);
            edges = obj.Inputs([], :);
            for j = 1:numel(req.Inputs)
                a = string(req.Inputs(j).artifact_id);
                if ~any(known == a); skipped(end + 1, 1) = a; continue; end %#ok<AGROW>
                edges = [edges; table(string(req.EventId), a, string(req.Inputs(j).role), ...
                    'VariableNames', obj.Inputs.Properties.VariableNames)]; %#ok<AGROW>
            end
            skippedRep = strings(0, 1);
            dsp = obj.Dispositions([], :);
            doneAt = req.OccurredAt;   % as CarasLabDB.recordEvent: when the run finished, else when it occurred
            if isfield(req.Detail, "finished_at") && isdatetime(req.Detail.finished_at) && ~isnat(req.Detail.finished_at)
                doneAt = req.Detail.finished_at;
            end
            doneAt.TimeZone = "UTC";
            for j = 1:n
                r = string(req.Outputs(j).replaces);
                if r == "" || unchanged(j); continue; end
                if ~any(obj.Artifacts.artifact_id == r); skippedRep(end + 1, 1) = r; continue; end %#ok<AGROW>
                dsp = [dsp; table(r, "replaced", ids(j), doneAt, 'VariableNames', ...
                    obj.Dispositions.Properties.VariableNames)]; %#ok<AGROW>
            end
            % everything checked: written at once, as one transaction
            obj.Events(end + 1) = struct("event_id", string(req.EventId), "event_type", string(req.EventType), ...
                "occurred_at", req.OccurredAt, "subject_id", subject, "session_id", string(req.SessionId), ...
                "digest", string(req.Digest), "recorded_by", string(req.RecordedBy), "notes", string(req.Notes), ...
                "attributes", string(req.AttributesJson), "detail", req.Detail);
            obj.Artifacts = [obj.Artifacts; newRows];
            obj.Inputs = [obj.Inputs; edges];
            obj.Dispositions = [obj.Dispositions; dsp];
            out.Outcome = "inserted";
            out.OutputIds = ids;
            out.Unchanged = unchanged;
            out.SkippedInputs = skipped;
            out.SkippedReplaces = skippedRep;
            obj.maybeFail("recordEvent", true);
        end

        function T = eventRows(obj, filters)
            obj.requireOpen("eventRows");
            E = obj.Events;
            T = table(string({E.event_id}).', string({E.event_type}).', string({E.session_id}).', ...
                string({E.subject_id}).', string({E.digest}).', ...
                'VariableNames', {'event_id', 'event_type', 'session_id', 'subject_id', 'client_digest'});
            T = labclient.FakeBackend.filterRows(T, filters);
        end

        function T = verifications(obj, artifactId)
            obj.requireOpen("verifications");
            T = obj.Verifications(obj.Verifications.artifact_id == string(artifactId), :);
            T = sortrows(T, 'verified_at', 'descend');
        end

        function T = dispositions(obj, artifactId)
            obj.requireOpen("dispositions");
            T = flipud(obj.Dispositions(obj.Dispositions.artifact_id == string(artifactId), :));   % newest first
            if ~obj.DispositionTimes; T.occurred_at = []; end
        end

        function T = lineage(obj, artifactId, direction)
            %lineage  Depth, event_id, artifact_id: the files and events ARTIFACTID came from ("up") or led to ("down").
            obj.requireOpen("lineage");
            T = table(zeros(0, 1), strings(0, 1), strings(0, 1), 'VariableNames', {'depth', 'event_id', 'artifact_id'});
            front = string(artifactId);
            seen = strings(0, 1);
            d = 0;
            while ~isempty(front) && d < 50
                next = strings(0, 1);
                for a = reshape(front, 1, [])
                    if any(seen == a); continue; end
                    seen(end + 1, 1) = a; %#ok<AGROW>
                    k = find(obj.Artifacts.artifact_id == a, 1);
                    if isempty(k); continue; end
                    ev = obj.Artifacts.produced_by_event_id(k);
                    T = [T; table(d, ev, a, 'VariableNames', T.Properties.VariableNames)]; %#ok<AGROW>
                    if direction == "up"
                        next = [next; obj.Inputs.artifact_id(obj.Inputs.event_id == ev)]; %#ok<AGROW>
                    else
                        evs = obj.Inputs.event_id(obj.Inputs.artifact_id == a);
                        next = [next; obj.Artifacts.artifact_id(ismember(obj.Artifacts.produced_by_event_id, evs))]; %#ok<AGROW>
                    end
                end
                front = unique(next);
                d = d + 1;
            end
        end

        function id = addArtifact(obj, a)
            %addArtifact  As CarasLabDB.addArtifact: the event must be there; one active row per file (root, path, checksum).
            obj.requireOpen("addArtifact");
            obj.maybeFail("addArtifact", false);
            k = find(string({obj.Events.event_id}) == a.ProducedByEventId, 1);
            if isempty(k)
                error("labclient:Refused", "event %s does not exist (fake foreign key)", a.ProducedByEventId);
            end
            if any(obj.Artifacts.artifact_id == a.ArtifactId)
                error("labclient:Refused", "duplicate key value violates unique constraint artifact_pkey (fake)");
            end
            if any(obj.Artifacts.storage_root_id == a.StorageRootId & obj.Artifacts.relative_path == a.RelativePath ...
                    & obj.Artifacts.checksum == lower(a.Checksum))
                error("labclient:Refused", "uq_artifact_file_original: the file is registered already (fake)");
            end
            if strlength(a.Checksum) ~= 64
                error("labclient:Refused", "checksum must be 64 hexadecimal digits (fake)");
            end
            jsondecode(char(a.AttributesJson));
            obj.Artifacts = [obj.Artifacts; table(string(a.ArtifactId), string(a.ProducedByEventId), ...
                double(a.StorageRootId), string(a.RelativePath), lower(string(a.Checksum)), double(a.SizeBytes), ...
                string(a.Role), string(a.Format), obj.Events(k).subject_id, obj.Events(k).session_id, ...
                string(a.AttributesJson), 'VariableNames', obj.Artifacts.Properties.VariableNames)];
            id = string(a.ArtifactId);
        end

        function addDisposition(obj, d)
            %addDisposition  As CarasLabDB.addArtifactDisposition, with trg_artifact_disposition_policy's rules.
            obj.requireOpen("addDisposition");
            obj.maybeFail("addDisposition", false);
            k = find(obj.Artifacts.artifact_id == d.ArtifactId, 1);
            if isempty(k)
                error("labclient:Refused", "artifact %s does not exist (fake foreign key)", d.ArtifactId);
            end
            prev = obj.Dispositions(obj.Dispositions.artifact_id == d.ArtifactId, :);
            gone = height(prev) > 0 && prev.disposition(end) ~= "restored";
            if d.Disposition == "restored"
                if ~gone; error("labclient:Refused", "the file is present: it cannot be restored (fake)"); end
            elseif gone
                error("labclient:Refused", "the file was recorded as %s already (fake)", prev.disposition(end));
            end
            if d.Disposition == "moved"
                j = find(obj.Artifacts.artifact_id == d.SuccessorArtifactId, 1);
                if isempty(j) || obj.Artifacts.checksum(j) ~= obj.Artifacts.checksum(k) || ...
                        (obj.Artifacts.storage_root_id(j) == obj.Artifacts.storage_root_id(k) && ...
                        obj.Artifacts.relative_path(j) == obj.Artifacts.relative_path(k))
                    error("labclient:Refused", "a moved file's successor must be the same bytes at another place (fake)");
                end
            elseif d.Disposition == "replaced" && strlength(d.SuccessorArtifactId) > 0
                j = find(obj.Artifacts.artifact_id == d.SuccessorArtifactId, 1);
                if isempty(j) || obj.Artifacts.checksum(j) == obj.Artifacts.checksum(k) || ...
                        obj.Artifacts.storage_root_id(j) ~= obj.Artifacts.storage_root_id(k) || ...
                        obj.Artifacts.relative_path(j) ~= obj.Artifacts.relative_path(k)
                    error("labclient:Refused", "a replaced file's successor must be other bytes at the same path (fake)");
                end
            elseif any(d.Disposition == ["deleted" "restored"]) && strlength(d.SuccessorArtifactId) > 0
                error("labclient:Refused", "a %s file has no successor (fake)", d.Disposition);
            end
            if ~isdatetime(d.OccurredAt) || ~isscalar(d.OccurredAt) || isnat(d.OccurredAt)
                error("labclient:Refused", "null value in column occurred_at (fake not-null constraint)");
            end
            at = d.OccurredAt;   % kept as the database keeps it: when it happened, a zoned instant
            at.TimeZone = "UTC";
            obj.Dispositions = [obj.Dispositions; table(string(d.ArtifactId), string(d.Disposition), ...
                string(d.SuccessorArtifactId), at, 'VariableNames', obj.Dispositions.Properties.VariableNames)];
        end

        function T = subjectCurrent(obj, ids)
            %subjectCurrent  lab.subject_current as the fake knows it: the newest weight, the endpoint, the subject's columns.
            obj.requireOpen("subjectCurrent");
            obj.maybeFail("subjectCurrent", false);
            ids = reshape(string(ids), 1, []);
            S = obj.Subjects;
            if ~isempty(ids); S = S(ismember(S.subject_id, ids), :); end
            n = height(S);
            dob = NaT(n, 1);
            epAt = NaT(n, 1, "TimeZone", "UTC");
            wt = NaN(n, 1);
            wtAt = NaT(n, 1, "TimeZone", "UTC");
            for k = 1:n
                j = find(obj.SubjectInfo.subject_id == S.subject_id(k), 1);
                if ~isempty(j)
                    dob(k) = obj.SubjectInfo.date_of_birth(j);
                    epAt(k) = obj.SubjectInfo.endpoint_at(j);
                end
                for e = reshape(obj.Events, 1, [])
                    if e.event_type ~= "husbandry" || e.subject_id ~= S.subject_id(k); continue; end
                    if ~isfield(e.detail, "weight_g") || isempty(e.detail.weight_g); continue; end
                    at = e.occurred_at;
                    at.TimeZone = "UTC";
                    if isnat(wtAt(k)) || at >= wtAt(k)
                        wt(k) = double(e.detail.weight_g);
                        wtAt(k) = at;
                    end
                end
            end
            T = table(S.subject_id, S.project_id, S.species_code, S.sex, dob, wt, wtAt, ~isnat(epAt), epAt, ...
                'VariableNames', {'subject_id', 'project_id', 'species_code', 'sex', 'date_of_birth', ...
                'latest_weight_g', 'latest_weight_at', 'is_endpointed', 'endpoint_at'});
        end

        function T = variableValues(obj, name, kind)
            %variableValues  The rows of Variables named NAME (of one KIND).
            obj.requireOpen("variableValues");
            obj.maybeFail("variableValues", false);
            V = obj.Variables;
            keep = lower(V.variable) == lower(string(name)) & V.entity_kind == string(kind);
            T = V(keep, {'entity_kind', 'entity_id', 'value', 'value_num', 'value_text', 'units', 'set_at'});
        end

        function tf = addEventInput(obj, eventId, artifactId, role)
            obj.requireOpen("addEventInput");
            obj.maybeFail("addEventInput", false);
            if ~any(string({obj.Events.event_id}) == eventId) || ~any(obj.Artifacts.artifact_id == artifactId)
                error("labclient:Refused", "event_input violates a foreign key (fake): %s, %s", eventId, artifactId);
            end
            if any(obj.Inputs.event_id == eventId & obj.Inputs.artifact_id == artifactId)
                tf = false;
                return
            end
            obj.Inputs = [obj.Inputs; table(string(eventId), string(artifactId), string(role), ...
                'VariableNames', obj.Inputs.Properties.VariableNames)];
            tf = true;
        end
    end

    methods (Access = private)
        function maybeFail(obj, method, afterWrite)
            %maybeFail  Fail as the first matching Fail entry says (and drop it).
            for k = 1:numel(obj.Fail)
                f = obj.Fail(k);
                if string(f.Method) == method && isequal(logical(f.AfterWrite), afterWrite)
                    obj.Fail(k) = [];
                    error(char(f.Identifier), "%s", f.Message);
                end
            end
        end

        function requireOpen(obj, what)
            obj.Calls(end+1) = string(what);
            if ~obj.isOpen()
                error("labclient:Unreachable", "The database connection is not open (fake).");
            end
        end
    end

    methods (Static, Access = private)
        function T = filterRows(T, filters)
            %filterRows  The rows of T whose columns equal each filter (snake_case of the field).
            if isempty(T) || width(T) == 0
                return
            end
            keep = true(height(T), 1);
            for f = reshape(string(fieldnames(filters)), 1, [])
                v = filters.(f);
                col = lower(regexprep(f, '(?<=[a-z])([A-Z])', '_$1'));
                if col == "path_prefix"
                    keep = keep & startsWith(string(T.relative_path), string(v));
                elseif col == "present_only" || col == "active_only"
                    continue
                elseif ismember(col, string(T.Properties.VariableNames))
                    keep = keep & string(T.(col)) == string(v);
                end
            end
            T = T(keep, :);
        end
    end
end
