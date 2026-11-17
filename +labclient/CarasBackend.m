classdef CarasBackend < labclient.Backend
    % labclient.CarasBackend  The lab database through the CarasLabDB MATLAB class (Database Toolbox).
    %   The only code of this package that calls CarasLabDB. It needs the
    %   CarasLabDB repository on the MATLAB path (its @CarasLabDB class
    %   folder) and the Database Toolbox; without either, open says so
    %   (labclient:NoCarasLabDB, labclient:NoDatabaseToolbox) and the apps go on
    %   working without the database.
    %
    %   See also labclient.Backend, labclient.DB.

    properties (Constant)
        % The CarasLabDB method this package needs: a CarasLabDB checkout
        % without it is too old.
        RequiredMethod = "recordEvent"
    end

    properties (SetAccess = private)
        Db = []     % the CarasLabDB object while connected
    end

    methods
        function [ok, why] = probe(~, s)
            %probe  Whether the server accepts a TCP connection within ConnectTimeout (tcpclient).
            ok = false;
            why = "";
            if strlength(s.Server) == 0
                why = "no server is set";
                return
            end
            try
                t = tcpclient(char(s.Server), s.Port, "ConnectTimeout", min(s.ConnectTimeout, 10)); %#ok<NASGU>
                clear t
                ok = true;
            catch ME
                why = "the server " + s.Server + ":" + string(s.Port) + " did not answer (" + ...
                    string(ME.message) + ")";
            end
        end

        function open(obj, s, password)
            %open  Connect as the settings' login.
            if ~labclient.CarasBackend.hasClass()
                error("labclient:NoCarasLabDB", "%s", labclient.CarasBackend.missingClassMessage());
            end
            if exist("postgresql") == 0 %#ok<EXIST>
                error("labclient:NoDatabaseToolbox", ...
                    "The Database Toolbox (postgresql) is not installed.");
            end
            obj.close();
            args = {"Username", s.Username, "Password", password, "Server", s.Server, ...
                "Port", s.Port, "DatabaseName", s.DatabaseName, ...
                "ConnectTimeout", s.ConnectTimeout, "StatementTimeout", s.StatementTimeout};
            if strlength(s.PersonEmail) > 0
                args = [args, {"PersonEmail", s.PersonEmail}];
            end
            try
                obj.Db = CarasLabDB(args{:});
            catch ME
                if ME.identifier == "CarasLabDB:connectionFailed"
                    error("labclient:Unreachable", "%s", ME.message);
                end
                rethrow(ME);
            end
        end

        function tf = isOpen(obj)
            tf = ~isempty(obj.Db) && isvalid(obj.Db) && obj.Db.isOpen();
        end

        function close(obj)
            if ~isempty(obj.Db) && isvalid(obj.Db)
                delete(obj.Db);
            end
            obj.Db = [];
        end

        function p = person(obj)
            obj.requireOpen();
            login = "";
            try
                T = obj.Db.runQuery("SELECT session_user AS login");
                login = string(T.login(1));
            catch
            end
            p = struct("PersonId", string(obj.Db.CurrentPersonId), "Login", login);
        end

        function T = storageRoots(obj)
            obj.requireOpen();
            T = obj.Db.getStorageRoots();
        end

        function id = addStorageRoot(obj, name, description)
            obj.requireOpen();
            id = double(obj.Db.addStorageRoot(Name=name, Description=description));
        end

        function T = sessions(obj, filters)
            obj.requireOpen();
            args = namedargs2cell(filters);
            T = obj.Db.getSessions(args{:});
        end

        function T = artifacts(obj, filters)
            obj.requireOpen();
            args = namedargs2cell(filters);
            T = obj.Db.getArtifacts(args{:});
        end

        function T = subjects(obj, filters)
            obj.requireOpen();
            args = namedargs2cell(filters);
            T = obj.Db.getSubjects(args{:});
        end

        function T = projects(obj)
            obj.requireOpen();
            T = obj.Db.getProjects();
        end

        function T = species(obj)
            obj.requireOpen();
            T = obj.Db.getSpecies();
        end

        function T = persons(obj, filters)
            obj.requireOpen();
            args = namedargs2cell(filters);
            T = obj.Db.getPersons(args{:});
        end

        function id = addSubject(obj, a)
            obj.requireOpen();
            args = {"SubjectId", a.SubjectId, "ProjectId", a.ProjectId, "Sex", a.Sex};
            if isfield(a, "SpeciesCode") && strlength(a.SpeciesCode) > 0
                args = [args, {"SpeciesCode", a.SpeciesCode}];
            end
            id = string(obj.Db.addSubject(args{:}));
        end

        function id = addSession(obj, a)
            obj.requireOpen();
            args = {"SessionId", a.SessionId, "SubjectId", a.SubjectId, "Label", a.Label, ...
                "StorageRootId", a.StorageRootId, "RelativePath", a.RelativePath};
            if isfield(a, "StartedAt") && ~isnat(a.StartedAt)
                args = [args, {"StartedAt", a.StartedAt}];
            end
            id = string(obj.Db.addSession(args{:}));
        end

        function out = recordEvent(obj, req)
            %recordEvent  CarasLabDB.recordEvent, with the JSON text sent as written (CarasLabDB.jsonText).
            obj.requireOpen();
            d = req.Detail;
            for f = ["parameters" "environment"]
                if isfield(d, f + "_json")
                    d.(f) = CarasLabDB.jsonText(d.(f + "_json"));
                    d = rmfield(d, f + "_json");
                end
            end
            O = struct("artifact_id", {}, "storage_root_id", {}, "relative_path", {}, ...
                "checksum", {}, "size_bytes", {}, "role", {}, "format", {}, "attributes", {}, ...
                "replaces", {});
            for k = 1:numel(req.Outputs)
                o = req.Outputs(k);
                O(k) = struct("artifact_id", labclient.CarasBackend.orMissing(o.artifact_id), ...
                    "storage_root_id", o.storage_root_id, "relative_path", o.relative_path, ...
                    "checksum", o.checksum, "size_bytes", o.size_bytes, ...
                    "role", labclient.CarasBackend.orMissing(o.role), ...
                    "format", labclient.CarasBackend.orMissing(o.format), ...
                    "attributes", CarasLabDB.jsonText(o.attributes_json), ...
                    "replaces", labclient.CarasBackend.orMissing(o.replaces));
            end
            I = struct("artifact_id", {}, "role", {});
            for k = 1:numel(req.Inputs)
                I(k) = struct("artifact_id", req.Inputs(k).artifact_id, ...
                    "role", labclient.CarasBackend.orMissing(req.Inputs(k).role));
            end
            args = {"EventId", req.EventId, "Digest", req.Digest, "OccurredAt", req.OccurredAt, ...
                "Attributes", CarasLabDB.jsonText(req.AttributesJson), "Detail", d, ...
                "Inputs", I, "Outputs", O, "MissingInputs", "skip"};
            for f = ["SubjectId" "SessionId" "Notes" "RecordedBy"]
                if isfield(req, f) && strlength(req.(f)) > 0
                    args = [args, {char(f), req.(f)}]; %#ok<AGROW>
                end
            end
            out = obj.Db.recordEvent(req.EventType, args{:});
        end

        function tf = addEventInput(obj, eventId, artifactId, role)
            obj.requireOpen();
            args = {"EventId", eventId, "ArtifactId", artifactId, "IfExists", "skip"};
            if strlength(role) > 0; args = [args, {"Role", role}]; end
            tf = obj.Db.addEventInput(args{:});
        end

        function T = eventRows(obj, filters)
            obj.requireOpen();
            args = namedargs2cell(filters);
            T = obj.Db.getEvents(args{:});
        end

        function T = verifications(obj, artifactId)
            obj.requireOpen();
            T = obj.Db.getArtifactVerifications(ArtifactId=artifactId);
        end

        function T = dispositions(obj, artifactId)
            obj.requireOpen();
            T = obj.Db.getArtifactDispositions(ArtifactId=artifactId);
        end

        function T = lineage(obj, artifactId, direction)
            obj.requireOpen();
            T = obj.Db.artifactLineage(artifactId, Direction=direction);
        end

        function id = addArtifact(obj, a)
            %addArtifact  One file produced by event a.ProducedByEventId, under that event's subject and session.
            obj.requireOpen();
            E = obj.Db.getEvents(EventId=a.ProducedByEventId, ActiveOnly=false);
            args = {"ArtifactId", a.ArtifactId, "ProducedByEventId", a.ProducedByEventId, ...
                "StorageRootId", a.StorageRootId, "RelativePath", a.RelativePath, "Checksum", a.Checksum, ...
                "Attributes", CarasLabDB.jsonText(a.AttributesJson)};
            if isfinite(a.SizeBytes); args = [args, {"SizeBytes", a.SizeBytes}]; end
            for f = ["Role" "Format"]
                if strlength(a.(f)) > 0; args = [args, {char(f), a.(f)}]; end %#ok<AGROW>
            end
            if height(E) > 0
                if ~ismissing(string(E.subject_id(1))) && string(E.subject_id(1)) ~= ""
                    args = [args, {"SubjectId", string(E.subject_id(1))}];
                end
                if ~ismissing(string(E.session_id(1))) && string(E.session_id(1)) ~= ""
                    args = [args, {"SessionId", string(E.session_id(1))}];
                end
            end
            id = string(obj.Db.addArtifact(args{:}));
        end

        function addDisposition(obj, d)
            obj.requireOpen();
            args = {"ArtifactId", d.ArtifactId, "Disposition", d.Disposition, "OccurredAt", d.OccurredAt, ...
                "Attributes", CarasLabDB.jsonText(d.AttributesJson)};
            if strlength(d.SuccessorArtifactId) > 0; args = [args, {"SuccessorArtifactId", d.SuccessorArtifactId}]; end
            if strlength(d.Note) > 0; args = [args, {"Note", d.Note}]; end
            obj.Db.addArtifactDisposition(args{:});
        end

        function T = subjectCurrent(obj, ids)
            %subjectCurrent  The lab.subject_current rows of subject ids IDS (all of them when empty).
            %   One CarasLabDB.getSubjectCurrent call per id; a subject the
            %   database does not have gives no row.
            obj.requireOpen();
            ids = reshape(string(ids), 1, []);
            if isempty(ids)
                T = obj.Db.getSubjectCurrent();
                return
            end
            T = [];
            for id = ids
                R = obj.Db.getSubjectCurrent(SubjectId=id);
                if isempty(T)
                    T = R;
                elseif height(R) > 0
                    T = [T; R]; %#ok<AGROW>
                end
            end
        end

        function T = variableValues(obj, name, kind)
            %variableValues  The current value of variable NAME on every KIND row that has one (CarasLabDB.getVariableValues).
            %   Columns entity_kind, entity_id, value, value_num, value_text,
            %   units, set_at.
            obj.requireOpen();
            T = obj.Db.getVariableValues(name, Kind=kind);
        end

        function delete(obj)
            obj.close();
        end
    end

    methods (Static)
        function tf = hasClass()
            %hasClass  True when a CarasLabDB class that has RequiredMethod is on the path.
            persistent found
            if ~isempty(found) && found; tf = true; return; end   % asked often; a found class stays found
            tf = false;
            try
                tf = any(string(methods("CarasLabDB")) == labclient.CarasBackend.RequiredMethod);
            catch
            end
            found = tf;
        end
    end

    methods (Static)
        function m = missingClassMessage()
            %missingClassMessage  What the lamp says when the CarasLabDB class cannot be used.
            m = "The CarasLabDB class is not on the MATLAB path, or it is too old (it has no " + ...
                labclient.CarasBackend.RequiredMethod + "): add a current CarasLabDB checkout to the path.";
        end
    end

    methods (Static, Access = private)
        function v = orMissing(v)
            %orMissing  "" as string(missing): a value not given, left to the database.
            v = string(v);
            if isempty(v) || v == ""; v = string(missing); end
        end
    end

    methods (Access = private)
        function requireOpen(obj)
            if ~obj.isOpen()
                error("labclient:Unreachable", "The database connection is not open.");
            end
        end
    end
end
