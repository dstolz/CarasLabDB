classdef (Abstract) Backend < handle
    % labclient.Backend  What the toolbox asks of the lab database: the one seam to CarasLabDB.
    %   labclient.DB talks to the database only through these methods. The real
    %   backend is labclient.CarasBackend (the CarasLabDB class, Database
    %   Toolbox); the tests use labclient.FakeBackend, which keeps the same
    %   rules in memory, so every path is tested without a server.
    %
    %     [ok, why] = b.probe(s)     % is the server there? (quick; nothing opened)
    %     b.open(s, password)        % connect (errors say why)
    %     tf = b.isOpen()
    %     b.close()
    %     p = b.person()             % struct: PersonId, Login
    %     T = b.storageRoots()       % root_id, name, description
    %     id = b.addStorageRoot(name, description)
    %     T = b.sessions(filters)    % filters: struct of SubjectId, StorageRootId, RelativePath, ...
    %     T = b.artifacts(filters)   % filters: struct of SessionId, StorageRootId, RelativePath,
    %                                %   PathPrefix, PresentOnly, ...
    %     T = b.subjects(filters)    % filters: SubjectId, ProjectId
    %     T = b.projects()           % project_id, name, ...
    %     T = b.species()            % code, common_name
    %     T = b.persons(filters)     % filters: PersonId, Email
    %     id = b.addSubject(a)       % a: SubjectId, ProjectId, SpeciesCode, Sex
    %     id = b.addSession(a)       % a: SessionId, SubjectId, Label, StorageRootId,
    %                                %   RelativePath, StartedAt (zoned or NaT)
    %     out = b.recordEvent(req)   % one event, its inputs and outputs, once (labclient.Sync)
    %     tf = b.addEventInput(eventId, artifactId, role)   % false when it was there
    %     T = b.eventRows(filters)   % filters: EventId, SessionId (event_id, event_type, occurred_at, ...)
    %     T = b.verifications(id)    % the checks of artifact ID, newest first (status, verified_at, ...)
    %     T = b.dispositions(id)     % what became of artifact ID's file, newest first (disposition, ...)
    %     T = b.lineage(id, dir)     % depth, event_id, artifact_id; dir "up" (what it came from) or "down"
    %
    %     id = b.addArtifact(a)      % a: ArtifactId, ProducedByEventId, StorageRootId, RelativePath,
    %                                %   Checksum, SizeBytes, Role, Format, AttributesJson (one file, filed
    %                                %   under its event's subject and session)
    %     T = b.subjectCurrent(ids)  % lab.subject_current rows of subject ids IDS (none for an unknown one)
    %     T = b.variableValues(name, kind)   % variable_current: entity_kind, entity_id, value, value_num, value_text, units, set_at
    %     b.addDisposition(d)        % d: ArtifactId, Disposition, SuccessorArtifactId ("" none),
    %                                %   OccurredAt (zoned), Note, AttributesJson
    %
    %   recordEvent's REQ: EventType ("analysis", "recording", "behavior" or
    %   "husbandry"; husbandry Detail: measure, weight_g, water_ml, health_status), EventId, Digest, OccurredAt (zoned),
    %   SubjectId, SessionId, Notes, AttributesJson (JSON text), RecordedBy
    %   (a person id), Detail (the type's columns; parameters_json and
    %   environment_json as JSON text), Inputs (artifact_id, role) and
    %   Outputs (artifact_id, storage_root_id, relative_path, checksum,
    %   size_bytes, role, format, attributes_json, replaces; "" for none).
    %   OUT: EventId, Outcome ("inserted" | "existing"), OutputIds,
    %   Unchanged, SkippedInputs, SkippedReplaces. Errors keep CarasLabDB's
    %   identifiers (CarasLabDB:idConflict for an id sent before with other
    %   content).
    %
    %   S is the labclient.Settings struct. Errors whose identifier ends in
    %   ":Unreachable" mean the server could not be reached; any other
    %   error means it answered and refused.
    %
    %   See also labclient.DB, labclient.CarasBackend, labclient.FakeBackend.

    methods (Abstract)
        [ok, why] = probe(obj, s)
        open(obj, s, password)
        tf = isOpen(obj)
        close(obj)
        p = person(obj)
        T = storageRoots(obj)
        id = addStorageRoot(obj, name, description)
        T = sessions(obj, filters)
        T = artifacts(obj, filters)
        T = subjects(obj, filters)
        T = projects(obj)
        T = species(obj)
        T = persons(obj, filters)
        id = addSubject(obj, a)
        id = addSession(obj, a)
        out = recordEvent(obj, req)
        tf = addEventInput(obj, eventId, artifactId, role)
        T = eventRows(obj, filters)   % ("events" is a classdef keyword)
        T = verifications(obj, artifactId)
        T = dispositions(obj, artifactId)
        T = lineage(obj, artifactId, direction)
        id = addArtifact(obj, a)
        addDisposition(obj, d)
        T = subjectCurrent(obj, ids)
        T = variableValues(obj, name, kind)
    end
end
