classdef CarasLabDB < handle
%CARASLABDB Interface to the Caras Lab lab metadata PostgreSQL database.
%
%   CarasLabDB is a thin, opinionated MATLAB wrapper over the append-only
%   lab schema defined in design_docs/schema.sql. It connects with the
%   native Database Toolbox POSTGRESQL interface (no ODBC DSN or JDBC .jar
%   configuration required) and exposes typed helpers for inserting and
%   retrieving every table in the schema, including the class-table
%   inheritance event model, artifacts, provenance edges, the recursive
%   lineage function, and the supersede-based correction workflow.
%
%   The schema is append-only: UPDATE and DELETE are blocked by database
%   triggers. Corrections are made by inserting a *superseding* row and
%   pointing its "supersedes" column at the row it replaces. Read helpers
%   default to the *_active views (latest, non-superseded rows); set
%   UseActiveViews=false (globally) or ActiveOnly=false (per call) to see
%   full history.
%
%   Construction (Name=Value):
%       db = CarasLabDB(Username="lab_rw", Password=secret, ...
%                       Server="nas-main.lab", DatabaseName="lab", ...
%                       PersonEmail="dstolz@umd.edu");
%
%   A "current person" resolved at construction auto-populates the
%   created_by / recorded_by provenance columns on inserts (override per
%   call with CreatedBy=/RecordedBy=).
%
%   At connection the session time zone is set to this workstation's zone,
%   so timestamps come back as local wall-clock time (see PINITSESSION), and
%   the database's schema version is read into SchemaVersion; a version other
%   than SchemaVersionExpected raises a CarasLabDB:schemaVersionMismatch
%   warning.
%
%   Example:
%       db  = CarasLabDB(Username="u", Password="p", PersonEmail="me@lab");
%       db.addSubject(SubjectId="G-0421", SpeciesCode="meriones_unguiculatus", Sex="M");
%       sid = db.addSession(SubjectId="G-0421", Label="2026-07-02_pen1", ...
%                           StorageRootId=1, RelativePath="G-0421/2026-07-02_pen1");
%       eid = db.addRecordingEvent(SubjectId="G-0421", SessionId=sid, ...
%                       OccurredAt=datetime("now","TimeZone","local"), ...
%                       AcquisitionSystemCode="intan_rhx", SampleRateHz=30000, ...
%                       NChannels=64, DurationS=1800);
%       aid = db.addArtifact(ProducedByEventId=eid, StorageRootId=1, ...
%                       RelativePath="G-0421/2026-07-02_pen1/raw.dat", ...
%                       Checksum=sha256hex, ...   % 64 lower-case hex chars
%                       Role="raw", Format="dat", SizeBytes=1.2e10);
%       T   = db.getArtifacts(SubjectId="G-0421");
%       L   = db.artifactLineage(aid, Direction="up");
%
%   Large methods live in their own files under @CarasLabDB and are declared
%   in the "methods" signature block below:
%       addBirthEvent, addSurgeryEvent, addRecordingEvent, addBehaviorEvent,
%       addHusbandryEvent, addEndpointEvent, addHistologyEvent,
%       addAnalysisEvent, addArtifact, supersedeEvent, supersedeArtifact,
%       artifactLineage, addTagNamespace, registerTag, addTag, removeTag,
%       setTag, getEntityTags, findByTags.
%
%   Tags. Events, artifacts, subjects, sessions and projects can carry
%   namespace:value tags (stage:raw, cohort:a, qc:fail; a bare tag such as
%   auditory_cortex is stored as tag:auditory_cortex). Every tag write goes
%   through lab.fn_tag, so the namespace's policy (mutable/immutable,
%   single/multi, open/closed vocabulary, applies_to) is enforced by the
%   database for this class exactly as for psql or the MCP server:
%       db.setTag("artifact", aid, "stage:raw");          % single-valued: replace
%       db.addTag("artifact", aid, ["topic:a1", "auditory_cortex"]);
%       T   = db.getArtifacts(Tags="stage:raw", NotTags="qc:fail");
%       ids = db.findByTags("artifact", Tags="topic:*");
%   Superseding an event or artifact (supersedeEvent, supersedeArtifact, or
%   Supersedes= on an add method) copies its current tags onto the successor
%   in the same transaction.
%
%   Requires MATLAB R2024b or later and the Database Toolbox.
%
%   NOTE ON SQL SAFETY: values are escaped and formatted into SQL literals
%   by the private SQLLITERAL helper (single quotes doubled, typed casts for
%   timestamps/jsonb). Table and column identifiers are supplied internally,
%   never by end users. Do not pass untrusted strings as identifiers.

    properties (SetAccess = private)
        Connection                              % Database Toolbox connection object
        Schema (1,1) string = "lab"           % Postgres schema that owns the tables
        CurrentPersonId (1,1) string = string(missing)  % person_id for provenance columns
        SchemaVersion (1,1) double = NaN        % max(lab.schema_version.version); NaN if none
    end

    properties (Constant)
        SchemaVersionExpected = 3               % schema version this class is written for
    end

    properties
        UseActiveViews (1,1) logical = true     % default reads to *_active views
    end

    properties (Access = private)
        OwnsConnection (1,1) logical = true     % close connection on delete only if we opened it
    end

    % ------------------------------------------------------------------
    % Externally-defined methods (see @CarasLabDB/<name>.m)
    % ------------------------------------------------------------------
    methods
        eventId     = addBirthEvent(obj, opts)
        eventId     = addSurgeryEvent(obj, opts)
        eventId     = addRecordingEvent(obj, opts)
        eventId     = addBehaviorEvent(obj, opts)
        eventId     = addHusbandryEvent(obj, opts)
        eventId     = addEndpointEvent(obj, opts)
        eventId     = addHistologyEvent(obj, opts)
        eventId     = addAnalysisEvent(obj, opts)
        artifactId  = addArtifact(obj, opts)
        newEventId  = supersedeEvent(obj, oldEventId, opts)
        newArtifactId = supersedeArtifact(obj, oldArtifactId, opts)
        T           = artifactLineage(obj, artifactId, opts)
        T           = runReadOnlyQuery(obj, sql)
        updateSubject(obj, subjectId, opts)
        updateSession(obj, sessionId, opts)
        namespace   = addTagNamespace(obj, opts)
        tag         = registerTag(obj, tag, opts)
        assignmentIds = addTag(obj, kind, entityId, tags, opts)
        assignmentIds = removeTag(obj, kind, entityId, tags, opts)
        [assignmentId, changed] = setTag(obj, kind, entityId, tag, opts)
        T           = getEntityTags(obj, kind, entityId, opts)
        ids         = findByTags(obj, kind, opts)
    end

    % ==================================================================
    % Construction / connection lifecycle
    % ==================================================================
    methods
        function obj = CarasLabDB(opts)
            arguments
                opts.Username (1,1) string = string(missing)
                opts.Password (1,1) string = string(missing)
                opts.Server (1,1) string = "localhost"
                opts.Port (1,1) double {mustBeInteger, mustBePositive} = 5432
                opts.DatabaseName (1,1) string = "lab"
                opts.Schema (1,1) string = "lab"
                opts.PersonId (1,1) string = string(missing)
                opts.PersonEmail (1,1) string = string(missing)
                opts.PersonName (1,1) string = string(missing)
                opts.UseActiveViews (1,1) logical = true
                opts.Connection = []    % inject an existing connection instead of opening one
                                        % (its session time zone is changed; see pInitSession)
            end

            obj.Schema = opts.Schema;
            obj.UseActiveViews = opts.UseActiveViews;

            if ~isempty(opts.Connection)
                obj.Connection = opts.Connection;
                obj.OwnsConnection = false;
            else
                if exist("postgresql") == 0 %#ok<EXIST>
                    error("CarasLabDB:noDatabaseToolbox", ...
                        "The native postgresql() interface was not found. " + ...
                        "The Database Toolbox is required.");
                end
                if ismissing(opts.Username) || ismissing(opts.Password)
                    error("CarasLabDB:missingCredentials", ...
                        "Username and Password are required unless an existing Connection is supplied.");
                end
                obj.Connection = postgresql(opts.Username, opts.Password, ...
                    Server=opts.Server, PortNumber=opts.Port, DatabaseName=opts.DatabaseName);
                obj.OwnsConnection = true;
            end

            if ~obj.isOpen()
                msg = "";
                try
                    msg = string(obj.Connection.Message);
                catch
                end
                error("CarasLabDB:connectionFailed", "Database connection failed. %s", msg);
            end

            obj.pInitSession();
            obj.CurrentPersonId = obj.pResolvePerson(opts.PersonId, opts.PersonEmail, opts.PersonName);
        end

        function tf = isOpen(obj)
            %ISOPEN True if the underlying connection is live.
            tf = ~isempty(obj.Connection) && isopen(obj.Connection);
        end

        function disconnect(obj)
            %DISCONNECT Close the underlying database connection.
            if obj.isOpen()
                close(obj.Connection);
            end
        end

        function setPerson(obj, opts)
            %SETPERSON Change the current provenance identity after construction.
            %   setPerson(PersonId=...) | setPerson(PersonEmail=...) | setPerson(PersonName=...)
            arguments
                obj (1,1) CarasLabDB
                opts.PersonId (1,1) string = string(missing)
                opts.PersonEmail (1,1) string = string(missing)
                opts.PersonName (1,1) string = string(missing)
            end
            obj.CurrentPersonId = obj.pResolvePerson(opts.PersonId, opts.PersonEmail, opts.PersonName);
        end

        function delete(obj)
            %DELETE Destructor. Closes the connection if this object opened it.
            if obj.OwnsConnection
                obj.disconnect();
            end
        end
    end

    % ==================================================================
    % Raw passthrough
    % ==================================================================
    methods
        function T = runQuery(obj, sql)
            %RUNQUERY Execute a SELECT (or any row-returning) statement, return a table.
            arguments
                obj (1,1) CarasLabDB
                sql (1,1) string
            end
            T = fetch(obj.Connection, sql);
        end

        function runCommand(obj, sql)
            %RUNCOMMAND Execute a non-row-returning statement (INSERT/DDL/etc.).
            arguments
                obj (1,1) CarasLabDB
                sql (1,1) string
            end
            execute(obj.Connection, sql);
        end
    end

    % ==================================================================
    % Reference / lookup table inserts
    % ==================================================================
    methods
        function personId = addPerson(obj, opts)
            %ADDPERSON Insert a person; returns the generated person_id (uuid string).
            arguments
                obj (1,1) CarasLabDB
                opts.FullName (1,1) string
                opts.Email (1,1) string = string(missing)
                opts.Role (1,1) string = string(missing)
                opts.IsActive (1,1) logical = true
            end
            s = struct("full_name", opts.FullName);
            s = obj.pSet(s, "email", opts.Email);
            s = obj.pSet(s, "role", opts.Role);
            s.is_active = opts.IsActive;
            personId = obj.pInsertReturning(obj.pT("person"), s, "person_id");
        end

        function rootId = addStorageRoot(obj, opts)
            %ADDSTORAGEROOT Insert a storage root; returns the generated root_id.
            arguments
                obj (1,1) CarasLabDB
                opts.Name (1,1) string
                opts.Description (1,1) string = string(missing)
            end
            s = struct("name", opts.Name);
            s = obj.pSet(s, "description", opts.Description);
            rootId = double(obj.pInsertReturning(obj.pT("storage_root"), s, "root_id"));
        end

        function code = addSpecies(obj, opts)
            %ADDSPECIES Insert a species row (natural key = code); returns code.
            arguments
                obj (1,1) CarasLabDB
                opts.Code (1,1) string
                opts.CommonName (1,1) string
            end
            s = struct("code", opts.Code, "common_name", opts.CommonName);
            obj.pInsert(obj.pT("species"), s);
            code = opts.Code;
        end

        function probeId = addProbe(obj, opts)
            %ADDPROBE Insert a probe; returns the generated probe_id (uuid string).
            arguments
                obj (1,1) CarasLabDB
                opts.Manufacturer (1,1) string = string(missing)
                opts.Model (1,1) string = string(missing)
                opts.NChannels double {mustBeInteger, mustBeScalarOrEmpty} = []
                opts.Geometry = []   % struct / containers.Map / dictionary / json string -> jsonb
                opts.Description (1,1) string = string(missing)
            end
            s = struct();
            s = obj.pSet(s, "manufacturer", opts.Manufacturer);
            s = obj.pSet(s, "model", opts.Model);
            s = obj.pSet(s, "n_channels", opts.NChannels);
            s = obj.pSet(s, "geometry", opts.Geometry);
            s = obj.pSet(s, "description", opts.Description);
            probeId = obj.pInsertReturning(obj.pT("probe"), s, "probe_id");
        end

        function pipelineId = addPipeline(obj, opts)
            %ADDPIPELINE Insert a pipeline; returns the generated pipeline_id.
            arguments
                obj (1,1) CarasLabDB
                opts.Name (1,1) string
                opts.Description (1,1) string = string(missing)
                opts.RepoUrl (1,1) string = string(missing)
            end
            s = struct("name", opts.Name);
            s = obj.pSet(s, "description", opts.Description);
            s = obj.pSet(s, "repo_url", opts.RepoUrl);
            pipelineId = obj.pInsertReturning(obj.pT("pipeline"), s, "pipeline_id");
        end

        function code = addEventType(obj, opts)
            %ADDEVENTTYPE Insert an event_type vocabulary row; returns code.
            arguments
                obj (1,1) CarasLabDB
                opts.Code (1,1) string
                opts.Label (1,1) string
            end
            obj.pInsert(obj.pT("event_type"), struct("code", opts.Code, "label", opts.Label));
            code = opts.Code;
        end

        function code = addArtifactRole(obj, opts)
            %ADDARTIFACTROLE Insert an artifact_role vocabulary row; returns code.
            arguments
                obj (1,1) CarasLabDB
                opts.Code (1,1) string
                opts.Label (1,1) string
            end
            obj.pInsert(obj.pT("artifact_role"), struct("code", opts.Code, "label", opts.Label));
            code = opts.Code;
        end

        function code = addAcquisitionSystem(obj, opts)
            %ADDACQUISITIONSYSTEM Insert an acquisition_system vocabulary row; returns code.
            arguments
                obj (1,1) CarasLabDB
                opts.Code (1,1) string
                opts.Label (1,1) string
            end
            obj.pInsert(obj.pT("acquisition_system"), struct("code", opts.Code, "label", opts.Label));
            code = opts.Code;
        end
    end

    % ==================================================================
    % Project inserts
    % ==================================================================
    methods
        function projectId = addProject(obj, opts)
            %ADDPROJECT Insert a project (unique Name); returns the generated project_id.
            arguments
                obj (1,1) CarasLabDB
                opts.Name (1,1) string
                opts.Description (1,1) string = string(missing)
                opts.StartedOn (1,1) datetime = NaT
                opts.IsActive (1,1) logical = true
                opts.CreatedBy (1,1) string = string(missing)
            end
            s = struct("name", opts.Name);
            s = obj.pSet(s, "description", opts.Description);
            if obj.pIsProvided(opts.StartedOn)
                s.started_on = string(opts.StartedOn, "yyyy-MM-dd");
            end
            s.is_active = opts.IsActive;
            s = obj.pSet(s, "created_by", obj.pCreatedBy(opts.CreatedBy));
            projectId = obj.pInsertReturning(obj.pT("project"), s, "project_id");
        end

        function addProjectMember(obj, opts)
            %ADDPROJECTMEMBER Associate a person with a project (project_member edge).
            arguments
                obj (1,1) CarasLabDB
                opts.ProjectId (1,1) string
                opts.PersonId (1,1) string
                opts.Role (1,1) string = string(missing)
            end
            s = struct("project_id", opts.ProjectId, "person_id", opts.PersonId);
            s = obj.pSet(s, "role", opts.Role);
            obj.pInsert(obj.pT("project_member"), s);
        end

        function projectArtifactId = addProjectArtifact(obj, opts)
            %ADDPROJECTARTIFACT Attach a document to a project; returns project_artifact_id.
            %   Kind="file" requires StorageRootId + RelativePath (a NAS file);
            %   every other kind (google_doc / google_sheet / url / other) requires
            %   Uri. The database CHECK enforces this location consistency.
            arguments
                obj (1,1) CarasLabDB
                opts.ProjectId (1,1) string
                opts.Title (1,1) string
                opts.Kind (1,1) string = "file"
                opts.ContentType (1,1) string = string(missing)
                opts.Uri (1,1) string = string(missing)
                opts.StorageRootId double {mustBeInteger, mustBeScalarOrEmpty} = []
                opts.RelativePath (1,1) string = string(missing)
                opts.Description (1,1) string = string(missing)
                opts.CreatedBy (1,1) string = string(missing)
            end
            obj.pCheckMember(opts.Kind, ...
                ["file", "google_doc", "google_sheet", "url", "other"], "Kind");
            s = struct("project_id", opts.ProjectId, "title", opts.Title, "kind", opts.Kind);
            s = obj.pSet(s, "content_type", opts.ContentType);
            s = obj.pSet(s, "uri", opts.Uri);
            s = obj.pSet(s, "storage_root_id", opts.StorageRootId);
            s = obj.pSet(s, "relative_path", opts.RelativePath);
            s = obj.pSet(s, "description", opts.Description);
            s = obj.pSet(s, "created_by", obj.pCreatedBy(opts.CreatedBy));
            projectArtifactId = obj.pInsertReturning( ...
                obj.pT("project_artifact"), s, "project_artifact_id");
        end
    end

    % ==================================================================
    % Dimension inserts (subject, session)
    % ==================================================================
    methods
        function subjectId = addSubject(obj, opts)
            %ADDSUBJECT Insert a subject (natural key SubjectId); returns SubjectId.
            arguments
                obj (1,1) CarasLabDB
                opts.SubjectId (1,1) string
                opts.ProjectId (1,1) string
                opts.SpeciesCode (1,1) string = string(missing)
                opts.Sex (1,1) string = "U"
                opts.Strain (1,1) string = string(missing)
                opts.Genotype (1,1) string = string(missing)
                opts.Source (1,1) string = string(missing)
                opts.DateOfBirth (1,1) datetime = NaT
                opts.Notes (1,1) string = string(missing)
                opts.CreatedBy (1,1) string = string(missing)
            end
            obj.pCheckMember(opts.Sex, ["M", "F", "U"], "Sex");
            s = struct("subject_id", opts.SubjectId, "project_id", opts.ProjectId, "sex", opts.Sex);
            s = obj.pSet(s, "species_code", opts.SpeciesCode);
            s = obj.pSet(s, "strain", opts.Strain);
            s = obj.pSet(s, "genotype", opts.Genotype);
            s = obj.pSet(s, "source", opts.Source);
            if obj.pIsProvided(opts.DateOfBirth)
                s.date_of_birth = string(opts.DateOfBirth, "yyyy-MM-dd");
            end
            s = obj.pSet(s, "notes", opts.Notes);
            s = obj.pSet(s, "created_by", obj.pCreatedBy(opts.CreatedBy));
            obj.pInsert(obj.pT("subject"), s);
            subjectId = opts.SubjectId;
        end

        function sessionId = addSession(obj, opts)
            %ADDSESSION Insert a session; returns the generated session_id (uuid string).
            arguments
                obj (1,1) CarasLabDB
                opts.SubjectId (1,1) string
                opts.Label (1,1) string
                opts.StorageRootId (1,1) double {mustBeInteger}
                opts.RelativePath (1,1) string
                opts.StartedAt (1,1) datetime = NaT
                opts.EndedAt (1,1) datetime = NaT
                opts.Rig (1,1) string = string(missing)
                opts.Notes (1,1) string = string(missing)
                opts.CreatedBy (1,1) string = string(missing)
            end
            s = struct( ...
                "subject_id", opts.SubjectId, ...
                "label", opts.Label, ...
                "storage_root_id", opts.StorageRootId, ...
                "relative_path", opts.RelativePath);
            s = obj.pSet(s, "started_at", opts.StartedAt);
            s = obj.pSet(s, "ended_at", opts.EndedAt);
            s = obj.pSet(s, "rig", opts.Rig);
            s = obj.pSet(s, "notes", opts.Notes);
            s = obj.pSet(s, "created_by", obj.pCreatedBy(opts.CreatedBy));
            sessionId = obj.pInsertReturning(obj.pT("session"), s, "session_id");
        end
    end

    % ==================================================================
    % Artifact provenance edges & verification
    % ==================================================================
    methods
        function addEventInput(obj, opts)
            %ADDEVENTINPUT Record that an event consumed an artifact (event_input edge).
            arguments
                obj (1,1) CarasLabDB
                opts.EventId (1,1) string
                opts.ArtifactId (1,1) string
                opts.Role (1,1) string = string(missing)
            end
            s = struct("event_id", opts.EventId, "artifact_id", opts.ArtifactId);
            s = obj.pSet(s, "role", opts.Role);
            obj.pInsert(obj.pT("event_input"), s);
        end

        function verificationId = addArtifactVerification(obj, opts)
            %ADDARTIFACTVERIFICATION Log a checksum verification; returns verification_id.
            arguments
                obj (1,1) CarasLabDB
                opts.ArtifactId (1,1) string
                opts.Status (1,1) string
                opts.ObservedChecksum (1,1) string = string(missing)
                opts.VerifiedBy (1,1) string = string(missing)
                opts.VerifiedAt (1,1) datetime = NaT
            end
            obj.pCheckMember(opts.Status, ["ok", "missing", "mismatch"], "Status");
            s = struct("artifact_id", opts.ArtifactId, "status", opts.Status);
            s = obj.pSet(s, "observed_checksum", opts.ObservedChecksum);
            s = obj.pSet(s, "verified_by", obj.pCreatedBy(opts.VerifiedBy));
            s = obj.pSet(s, "verified_at", opts.VerifiedAt);
            verificationId = double(obj.pInsertReturning(obj.pT("artifact_verification"), s, "verification_id"));
        end
    end

    % ==================================================================
    % Retrieval — reference / lookup tables
    % ==================================================================
    methods
        function T = getPersons(obj, opts)
            arguments
                obj (1,1) CarasLabDB
                opts.PersonId (1,1) string = string(missing)
                opts.Email (1,1) string = string(missing)
                opts.FullName (1,1) string = string(missing)
                opts.IsActive = []   % logical scalar or [] for any
            end
            f = struct();
            f = obj.pSet(f, "person_id", opts.PersonId);
            f = obj.pSet(f, "full_name", opts.FullName);
            f = obj.pSet(f, "is_active", opts.IsActive);
            extra = strings(1, 0);
            if obj.pIsProvided(opts.Email)
                % Case-insensitive, like uq_person_email_lower and
                % pResolvePerson: 'Dan@umd.edu' and 'dan@umd.edu' are one
                % person, so a search for either must find the stored row.
                extra = "lower(email) = lower(" + obj.sqlLiteral(opts.Email) + ")";
            end
            T = obj.pSelectFrom(obj.pT("person"), f, ...
                OrderBy="full_name, person_id", Where=extra);
        end

        function T = getSpecies(obj)
            T = obj.pSelectFrom(obj.pT("species"), struct(), OrderBy="code");
        end

        function T = getStorageRoots(obj)
            T = obj.pSelectFrom(obj.pT("storage_root"), struct(), OrderBy="root_id");
        end

        function T = getProbes(obj, opts)
            arguments
                obj (1,1) CarasLabDB
                opts.ProbeId (1,1) string = string(missing)
            end
            f = obj.pSet(struct(), "probe_id", opts.ProbeId);
            T = obj.pSelectFrom(obj.pT("probe"), f, OrderBy="probe_id");
        end

        function T = getPipelines(obj, opts)
            arguments
                obj (1,1) CarasLabDB
                opts.PipelineId (1,1) string = string(missing)
                opts.Name (1,1) string = string(missing)
            end
            f = struct();
            f = obj.pSet(f, "pipeline_id", opts.PipelineId);
            f = obj.pSet(f, "name", opts.Name);
            T = obj.pSelectFrom(obj.pT("pipeline"), f, OrderBy="name");
        end

        function T = getEventTypes(obj)
            T = obj.pSelectFrom(obj.pT("event_type"), struct(), OrderBy="code");
        end

        function T = getArtifactRoles(obj)
            T = obj.pSelectFrom(obj.pT("artifact_role"), struct(), OrderBy="code");
        end

        function T = getAcquisitionSystems(obj)
            T = obj.pSelectFrom(obj.pT("acquisition_system"), struct(), OrderBy="code");
        end
    end

    % ==================================================================
    % Retrieval — projects
    % ==================================================================
    methods
        function T = getProjects(obj, opts)
            %GETPROJECTS Retrieve projects filtered by any of the given columns.
            %   Tags= / AnyTags= / NotTags= filter on current tags (see GETEVENTS).
            arguments
                obj (1,1) CarasLabDB
                opts.ProjectId (1,1) string = string(missing)
                opts.Name (1,1) string = string(missing)
                opts.IsActive = []   % logical scalar or [] for any
                opts.Tags string = strings(1, 0)       % must carry all of these
                opts.AnyTags string = strings(1, 0)    % ... and at least one of these
                opts.NotTags string = strings(1, 0)    % ... and none of these
            end
            f = struct();
            f = obj.pSet(f, "project_id", opts.ProjectId);
            f = obj.pSet(f, "name", opts.Name);
            f = obj.pSet(f, "is_active", opts.IsActive);
            T = obj.pSelectFrom(obj.pT("project"), f, OrderBy="name", ...
                Where=obj.pTagWhere("project", opts.Tags, opts.AnyTags, opts.NotTags));
        end

        function T = getProjectMembers(obj, opts)
            %GETPROJECTMEMBERS Retrieve project<->person membership rows.
            arguments
                obj (1,1) CarasLabDB
                opts.ProjectId (1,1) string = string(missing)
                opts.PersonId (1,1) string = string(missing)
            end
            f = struct();
            f = obj.pSet(f, "project_id", opts.ProjectId);
            f = obj.pSet(f, "person_id", opts.PersonId);
            T = obj.pSelectFrom(obj.pT("project_member"), f, OrderBy="project_id, person_id");
        end

        function T = getProjectArtifacts(obj, opts)
            %GETPROJECTARTIFACTS Retrieve project-level documents (files and links).
            arguments
                obj (1,1) CarasLabDB
                opts.ProjectArtifactId (1,1) string = string(missing)
                opts.ProjectId (1,1) string = string(missing)
                opts.Kind (1,1) string = string(missing)
            end
            f = struct();
            f = obj.pSet(f, "project_artifact_id", opts.ProjectArtifactId);
            f = obj.pSet(f, "project_id", opts.ProjectId);
            f = obj.pSet(f, "kind", opts.Kind);
            T = obj.pSelectFrom(obj.pT("project_artifact"), f, ...
                OrderBy="project_id, created_at, project_artifact_id");
        end
    end

    % ==================================================================
    % Retrieval — dimensions, events, artifacts, views
    % ==================================================================
    methods
        function T = getSubjects(obj, opts)
            %GETSUBJECTS Retrieve subjects filtered by any of the given columns.
            %   Tags= / AnyTags= / NotTags= filter on current tags (see GETEVENTS).
            arguments
                obj (1,1) CarasLabDB
                opts.SubjectId (1,1) string = string(missing)
                opts.ProjectId (1,1) string = string(missing)
                opts.SpeciesCode (1,1) string = string(missing)
                opts.Sex (1,1) string = string(missing)
                opts.Tags string = strings(1, 0)       % must carry all of these
                opts.AnyTags string = strings(1, 0)    % ... and at least one of these
                opts.NotTags string = strings(1, 0)    % ... and none of these
            end
            f = struct();
            f = obj.pSet(f, "subject_id", opts.SubjectId);
            f = obj.pSet(f, "project_id", opts.ProjectId);
            f = obj.pSet(f, "species_code", opts.SpeciesCode);
            f = obj.pSet(f, "sex", opts.Sex);
            T = obj.pSelectFrom(obj.pT("subject"), f, OrderBy="subject_id", ...
                Where=obj.pTagWhere("subject", opts.Tags, opts.AnyTags, opts.NotTags));
        end

        function T = getSessions(obj, opts)
            %GETSESSIONS Retrieve sessions filtered by any of the given columns.
            %   Tags= / AnyTags= / NotTags= filter on current tags (see GETEVENTS).
            arguments
                obj (1,1) CarasLabDB
                opts.SessionId (1,1) string = string(missing)
                opts.SubjectId (1,1) string = string(missing)
                opts.Label (1,1) string = string(missing)
                opts.StorageRootId double {mustBeInteger, mustBeScalarOrEmpty} = []
                opts.Tags string = strings(1, 0)       % must carry all of these
                opts.AnyTags string = strings(1, 0)    % ... and at least one of these
                opts.NotTags string = strings(1, 0)    % ... and none of these
            end
            f = struct();
            f = obj.pSet(f, "session_id", opts.SessionId);
            f = obj.pSet(f, "subject_id", opts.SubjectId);
            f = obj.pSet(f, "label", opts.Label);
            f = obj.pSet(f, "storage_root_id", opts.StorageRootId);
            T = obj.pSelectFrom(obj.pT("session"), f, OrderBy="subject_id, label", ...
                Where=obj.pTagWhere("session", opts.Tags, opts.AnyTags, opts.NotTags));
        end

        function T = getEvents(obj, opts)
            %GETEVENTS Retrieve base event rows. Reads event_active unless ActiveOnly=false.
            %   Rows are ordered newest first (occurred_at DESC, event_id).
            %
            %   Tag filters (string arrays; each element is a tag such as
            %   "stage:raw", a bare tag such as "auditory_cortex", which means
            %   "tag:auditory_cortex", or a wildcard "ns:*" for any tag of
            %   namespace ns). A row is kept when it currently carries every
            %   tag in Tags=, at least one in AnyTags= (when given), and none
            %   in NotTags=. Semantics are lab.fn_tag_match's, so they are the
            %   same as in the GUI, the dashboard and the MCP server:
            %       T = db.getEvents(Tags="qc:pass", NotTags=["qc:fail", "tag:pilot"]);
            arguments
                obj (1,1) CarasLabDB
                opts.EventId (1,1) string = string(missing)
                opts.EventType (1,1) string = string(missing)
                opts.SubjectId (1,1) string = string(missing)
                opts.SessionId (1,1) string = string(missing)
                opts.ActiveOnly (1,1) logical = obj.UseActiveViews
                opts.Limit (1,1) double {mustBeInteger, mustBeNonnegative} = 0
                opts.Tags string = strings(1, 0)       % must carry all of these
                opts.AnyTags string = strings(1, 0)    % ... and at least one of these
                opts.NotTags string = strings(1, 0)    % ... and none of these
            end
            tbl = obj.pT("event");
            if opts.ActiveOnly
                tbl = obj.pT("event_active");
            end
            f = struct();
            f = obj.pSet(f, "event_id", opts.EventId);
            f = obj.pSet(f, "event_type", opts.EventType);
            f = obj.pSet(f, "subject_id", opts.SubjectId);
            f = obj.pSet(f, "session_id", opts.SessionId);
            % Newest first, ties broken by a unique column, so a Limit= result
            % is a stable, well-defined subset (same order as the MCP server).
            T = obj.pSelectFrom(tbl, f, Limit=opts.Limit, OrderBy="occurred_at DESC, event_id", ...
                Where=obj.pTagWhere("event", opts.Tags, opts.AnyTags, opts.NotTags));
        end

        function T = getEventDetail(obj, opts)
            %GETEVENTDETAIL Join a base event to its type-specific detail table.
            %   Returns every lab.event column plus the detail columns that are
            %   not already present on the base row (event_id, event_type are the
            %   join/discriminator columns and are taken from the base only).
            %   Reads event_active unless ActiveOnly=false, so a superseded
            %   event is reported as not found rather than returned as if it
            %   were current.
            arguments
                obj (1,1) CarasLabDB
                opts.EventId (1,1) string
                opts.ActiveOnly (1,1) logical = obj.UseActiveViews
            end
            if opts.ActiveOnly
                eventSrc = obj.pT("event_active");
            else
                eventSrc = obj.pT("event");
            end
            litId = obj.sqlLiteral(opts.EventId);
            E = obj.pSelect("SELECT event_type FROM " + eventSrc + ...
                " WHERE event_id = " + litId + ";");
            if height(E) == 0
                error("CarasLabDB:eventNotFound", "No event with id %s.", opts.EventId);
            end
            detailTable = obj.pDetailTable(E.event_type(1));

            % JOIN ... USING emits event_id and event_type once, then the
            % remaining lab.event columns, then the remaining detail columns:
            % exactly the column set described above, with no catalog lookup.
            T = obj.pSelect("SELECT * FROM " + eventSrc + " e JOIN " + ...
                obj.pT(detailTable) + " d USING (event_id, event_type) " + ...
                "WHERE event_id = " + litId + ";");
        end

        function T = getArtifacts(obj, opts)
            %GETARTIFACTS Retrieve artifacts. Reads artifact_active unless ActiveOnly=false.
            %   Rows are ordered newest first (created_at DESC, artifact_id).
            %   Tags= / AnyTags= / NotTags= filter on current tags (see GETEVENTS):
            %       T = db.getArtifacts(SessionId=sid, Tags="stage:raw");
            arguments
                obj (1,1) CarasLabDB
                opts.ArtifactId (1,1) string = string(missing)
                opts.ProducedByEventId (1,1) string = string(missing)
                opts.SubjectId (1,1) string = string(missing)
                opts.SessionId (1,1) string = string(missing)
                opts.Role (1,1) string = string(missing)
                opts.Checksum (1,1) string = string(missing)
                opts.ActiveOnly (1,1) logical = obj.UseActiveViews
                opts.Limit (1,1) double {mustBeInteger, mustBeNonnegative} = 0
                opts.Tags string = strings(1, 0)       % must carry all of these
                opts.AnyTags string = strings(1, 0)    % ... and at least one of these
                opts.NotTags string = strings(1, 0)    % ... and none of these
            end
            tbl = obj.pT("artifact");
            if opts.ActiveOnly
                tbl = obj.pT("artifact_active");
            end
            f = struct();
            f = obj.pSet(f, "artifact_id", opts.ArtifactId);
            f = obj.pSet(f, "produced_by_event_id", opts.ProducedByEventId);
            f = obj.pSet(f, "subject_id", opts.SubjectId);
            f = obj.pSet(f, "session_id", opts.SessionId);
            f = obj.pSet(f, "role", opts.Role);
            f = obj.pSet(f, "checksum", opts.Checksum);
            T = obj.pSelectFrom(tbl, f, Limit=opts.Limit, OrderBy="created_at DESC, artifact_id", ...
                Where=obj.pTagWhere("artifact", opts.Tags, opts.AnyTags, opts.NotTags));
        end

        function T = getEventInputs(obj, opts)
            %GETEVENTINPUTS Retrieve event<->artifact consumption edges.
            arguments
                obj (1,1) CarasLabDB
                opts.EventId (1,1) string = string(missing)
                opts.ArtifactId (1,1) string = string(missing)
            end
            f = struct();
            f = obj.pSet(f, "event_id", opts.EventId);
            f = obj.pSet(f, "artifact_id", opts.ArtifactId);
            T = obj.pSelectFrom(obj.pT("event_input"), f, OrderBy="event_id, artifact_id");
        end

        function T = getArtifactVerifications(obj, opts)
            %GETARTIFACTVERIFICATIONS Retrieve checksum verification history.
            arguments
                obj (1,1) CarasLabDB
                opts.ArtifactId (1,1) string = string(missing)
            end
            f = obj.pSet(struct(), "artifact_id", opts.ArtifactId);
            T = obj.pSelectFrom(obj.pT("artifact_verification"), f, ...
                OrderBy="verified_at DESC, verification_id DESC");
        end

        function T = getSubjectCurrent(obj, opts)
            %GETSUBJECTCURRENT Subject dimension enriched with latest weight/endpoint (view).
            arguments
                obj (1,1) CarasLabDB
                opts.SubjectId (1,1) string = string(missing)
            end
            f = obj.pSet(struct(), "subject_id", opts.SubjectId);
            T = obj.pSelectFrom(obj.pT("subject_current"), f, OrderBy="subject_id");
        end

        function T = getProvenanceEdges(obj, opts)
            %GETPROVENANCEEDGES Uniform produces/consumes edge list (view).
            arguments
                obj (1,1) CarasLabDB
                opts.FromId (1,1) string = string(missing)
                opts.ToId (1,1) string = string(missing)
                opts.EdgeType (1,1) string = string(missing)
            end
            f = struct();
            f = obj.pSet(f, "from_id", opts.FromId);
            f = obj.pSet(f, "to_id", opts.ToId);
            f = obj.pSet(f, "edge_type", opts.EdgeType);
            T = obj.pSelectFrom(obj.pT("provenance_edge"), f, ...
                OrderBy="edge_type, from_id, to_id");
        end
    end

    % ==================================================================
    % Tags — vocabulary (namespaces and tags). Writing tags onto rows and
    % reading them back live in their own files: addTag, removeTag, setTag,
    % getEntityTags, findByTags, addTagNamespace, registerTag.
    % ==================================================================
    methods
        function T = getTagNamespaces(obj, opts)
            %GETTAGNAMESPACES Tag namespaces and their policies.
            %   T = db.getTagNamespaces()
            %   T = db.getTagNamespaces(AppliesTo="artifact")   % usable on artifacts
            %   T = db.getTagNamespaces(Namespace="stage")
            %
            %   applies_to comes back as comma-separated text
            %   ("event,artifact"). The column is a text[], which the native
            %   postgresql() interface does not read, so it is flattened with
            %   array_to_string in SQL instead of being fetched with SELECT *.
            arguments
                obj (1,1) CarasLabDB
                opts.Namespace (1,1) string = string(missing)
                opts.AppliesTo (1,1) string = string(missing)
            end
            f = obj.pSet(struct(), "namespace", opts.Namespace);
            extra = strings(1, 0);
            if obj.pIsProvided(opts.AppliesTo)
                CarasLabDB.pTagEntity(opts.AppliesTo);   % validates the kind
                extra = obj.sqlLiteral(opts.AppliesTo) + " = ANY (applies_to)";
            end
            T = obj.pSelect("SELECT namespace, description, mutability, cardinality, " + ...
                "open_vocabulary, array_to_string(applies_to, ',') AS applies_to, " + ...
                "created_at, created_by FROM " + obj.pT("tag_namespace") + ...
                obj.pWhere(f, extra) + " ORDER BY namespace;");
        end

        function T = getTags(obj, opts)
            %GETTAGS Registered tags (the vocabulary), optionally of one namespace.
            %   T = db.getTags()                                  % every live tag
            %   T = db.getTags(Namespace="stage")
            %   T = db.getTags(Namespace="stage", IncludeRetired=true)
            %   Retired tags (retired_at set) are left out unless
            %   IncludeRetired=true. Ordered by namespace, value.
            arguments
                obj (1,1) CarasLabDB
                opts.Namespace (1,1) string = string(missing)
                opts.IncludeRetired (1,1) logical = false
            end
            f = obj.pSet(struct(), "namespace", opts.Namespace);
            extra = strings(1, 0);
            if ~opts.IncludeRetired
                extra = "retired_at IS NULL";
            end
            T = obj.pSelectFrom(obj.pT("tag"), f, OrderBy="namespace, value", Where=extra);
        end

        function updateTagNamespace(obj, namespace, opts)
            %UPDATETAGNAMESPACE Edit a tag namespace in place (row_history logs it).
            %   db.updateTagNamespace("topic", Description="Free-form subject matter")
            %   db.updateTagNamespace("qc", AppliesTo=["artifact","event","session","subject"])
            %   db.updateTagNamespace("cohort", OpenVocabulary=false)
            %
            %   Only the arguments you supply are changed. AppliesTo is the
            %   complete new list of entity kinds. Once any tag of the
            %   namespace has been assigned the database freezes its policy:
            %   Mutability and Cardinality can no longer change and AppliesTo
            %   may only grow (the reserved 'tag' namespace is frozen from the
            %   start); such an update raises the database's error.
            arguments
                obj (1,1) CarasLabDB
                namespace (1,1) string
                opts.Description (1,1) string = string(missing)
                opts.OpenVocabulary logical {mustBeScalarOrEmpty} = logical.empty
                opts.AppliesTo string = strings(1, 0)
                opts.Mutability (1,1) string = string(missing)
                opts.Cardinality (1,1) string = string(missing)
            end
            obj.pCheckMember(opts.Mutability, ["mutable", "immutable"], "Mutability");
            obj.pCheckMember(opts.Cardinality, ["single", "multi"], "Cardinality");
            s = struct();
            s = obj.pSet(s, "description", opts.Description);
            s = obj.pSet(s, "open_vocabulary", opts.OpenVocabulary);
            if ~isempty(opts.AppliesTo)
                s.applies_to = CarasLabDB.pAppliesToLiteral(opts.AppliesTo);
            end
            s = obj.pSet(s, "mutability", opts.Mutability);
            s = obj.pSet(s, "cardinality", opts.Cardinality);
            n = obj.pUpdate(obj.pT("tag_namespace"), s, ...
                "namespace = " + obj.sqlLiteral(namespace), "namespace");
            if n == 0
                error("CarasLabDB:tagNamespaceNotFound", "No tag namespace %s.", namespace);
            end
        end

        function retireTag(obj, tag, opts)
            %RETIRETAG Retire a tag (no new assignments), or bring it back.
            %   db.retireTag("stage:curated")
            %   db.retireTag("stage:curated", Unretire=true)
            %
            %   A tag is never renamed or deleted, because the assignment log
            %   refers to it by name: retire it and register the replacement.
            %   Rows that carry it keep it until it is removed. Retiring a tag
            %   that is already retired (or un-retiring a live one) changes
            %   nothing, so the original retired_at is kept.
            arguments
                obj (1,1) CarasLabDB
                tag (1,1) string
                opts.Unretire (1,1) logical = false
            end
            tag = CarasLabDB.normalizeTag(tag);
            where = "tag = " + obj.sqlLiteral(tag);
            R = obj.pSelect("SELECT (retired_at IS NOT NULL) AS is_retired FROM " + ...
                obj.pT("tag") + " WHERE " + where + ";");
            if height(R) == 0
                error("CarasLabDB:tagNotFound", "No registered tag %s.", tag);
            end
            if logical(R.is_retired(1)) ~= opts.Unretire
                return   % already in the requested state
            end
            if opts.Unretire
                s = struct("retired_at", NaT);    % sqlLiteral(NaT) -> NULL
            else
                s = struct("retired_at", datetime("now", "TimeZone", "local"));
            end
            obj.pUpdate(obj.pT("tag"), s, where, "tag");
        end
    end

    % ==================================================================
    % Private helpers used by both inline and external methods
    % ==================================================================
    methods (Access = private)
        function ref = pT(obj, name)
            %PT Schema-qualified identifier, e.g. pT("event") -> "lab.event".
            ref = obj.Schema + "." + string(name);
        end

        function T = pSelect(obj, sql)
            T = fetch(obj.Connection, sql);
        end

        function pExec(obj, sql)
            execute(obj.Connection, sql);
        end

        function pInsert(obj, tableRef, s)
            %PINSERT Build and execute an INSERT from a column->value struct.
            [cols, vals] = obj.pColsVals(s);
            sql = "INSERT INTO " + tableRef + " (" + strjoin(cols, ", ") + ...
                ") VALUES (" + strjoin(vals, ", ") + ");";
            obj.pExec(sql);
        end

        function idOut = pInsertReturning(obj, tableRef, s, returningCol)
            %PINSERTRETURNING INSERT ... RETURNING <col>; returns that column as string.
            [cols, vals] = obj.pColsVals(s);
            sql = "INSERT INTO " + tableRef + " (" + strjoin(cols, ", ") + ...
                ") VALUES (" + strjoin(vals, ", ") + ") RETURNING " + string(returningCol) + ";";
            T = obj.pSelect(sql);
            if height(T) == 0
                error("CarasLabDB:insertFailed", "Insert into %s returned no rows.", tableRef);
            end
            v = T.(char(returningCol));
            idOut = string(v(1));
        end

        function n = pUpdate(obj, tableRef, s, whereClause, keyCol)
            %PUPDATE Build and execute an UPDATE from a column->value struct.
            %   Returns the number of rows updated (via RETURNING KEYCOL, so
            %   callers can detect a key that matched nothing without a
            %   separate existence query), or NaN when S has no fields and
            %   nothing was sent. WHERECLAUSE is built by the caller from
            %   internal identifiers plus sqlLiteral-escaped key values.
            arguments
                obj (1,1) CarasLabDB
                tableRef (1,1) string
                s (1,1) struct
                whereClause (1,1) string
                keyCol (1,1) string
            end
            [cols, vals] = obj.pColsVals(s);
            if isempty(cols)
                % Reporting success for a call that changed nothing is how a
                % caller ends up believing an edit was saved when it was not.
                warning("CarasLabDB:nothingToUpdate", ...
                    "No columns were supplied; %s was not changed.", tableRef);
                n = NaN;
                return
            end
            assignments = cols + " = " + vals;
            sql = "UPDATE " + tableRef + " SET " + strjoin(assignments, ", ") + ...
                " WHERE " + whereClause + " RETURNING " + keyCol + ";";
            n = height(obj.pSelect(sql));
        end

        function eventId = pInsertEvent(obj, base, detailTable, detail, inputs, artifacts)
            %PINSERTEVENT Insert the base event and its detail row in one transaction.
            %   INPUTS is an optional cell array of lab.event_input structs
            %   (artifact_id, role) to attach to the new event, and ARTIFACTS
            %   an optional cell array of lab.artifact insert structs for files
            %   the new event produced (supersedeEvent passes the successors
            %   of the old event's artifacts); event_id / produced_by_event_id
            %   are filled in here. Both are written inside the same
            %   transaction, so a correction can never commit an event whose
            %   provenance edges or files are only half-carried over.
            %
            %   When BASE sets supersedes (supersedeEvent, or Supersedes= on an
            %   addXEvent method), the superseded event's current tags are
            %   copied onto the new event, and each artifact with supersedes
            %   gets its predecessor's tags, in the same transaction (see
            %   PCARRYTAGS).
            arguments
                obj (1,1) CarasLabDB
                base (1,1) struct
                detailTable (1,1) string
                detail (1,1) struct
                inputs cell = {}
                artifacts cell = {}
            end
            eventId = obj.pTransact(@() ...
                obj.pInsertEventRows(base, detailTable, detail, inputs, artifacts));
        end

        function eventId = pInsertEventRows(obj, base, detailTable, detail, inputs, artifacts)
            %PINSERTEVENTROWS The writes of PINSERTEVENT. Run only inside PTRANSACT.
            eventId = obj.pInsertReturning(obj.pT("event"), base, "event_id");
            detail.event_id = eventId;
            if ~isfield(detail, "event_type")
                detail.event_type = base.event_type;
            end
            obj.pInsert(detailTable, detail);
            for k = 1:numel(inputs)
                edge = inputs{k};
                edge.event_id = eventId;
                obj.pInsert(obj.pT("event_input"), edge);
            end
            if isfield(base, "supersedes") && obj.pIsProvided(base.supersedes)
                obj.pCarryTags("event", base.supersedes, eventId);
            end
            for k = 1:numel(artifacts)
                a = artifacts{k};
                a.produced_by_event_id = eventId;
                obj.pInsertArtifact(a);
            end
        end

        function artifactId = pInsertArtifact(obj, s)
            %PINSERTARTIFACT Insert one lab.artifact row; carry tags if it supersedes.
            %   S is a column->value insert struct. When it sets supersedes, the
            %   predecessor's current tags are copied onto the new row, so the
            %   caller must run this inside PTRANSACT: the artifact and its
            %   carried tags commit together or not at all.
            artifactId = obj.pInsertReturning(obj.pT("artifact"), s, "artifact_id");
            if isfield(s, "supersedes") && obj.pIsProvided(s.supersedes)
                obj.pCarryTags("artifact", s.supersedes, artifactId);
            end
        end

        function pCarryTags(obj, kind, oldId, newId)
            %PCARRYTAGS Copy the current tags of a superseded event/artifact to its successor.
            %   A correction is a new row, so without this it would start with
            %   no tags and drop out of every tag filter the original matched
            %   (lab.fn_check_integrity reports that as tag_not_carried_forward).
            %   One INSERT ... SELECT writes a new 'add' log row per current tag
            %   of OLDID, noted "carried forward from <OLDID>" and applied by
            %   the current person; nothing existing is altered. The successor
            %   is brand new, so no row can be a duplicate, and copying the
            %   predecessor's (policy-valid) current set cannot break a
            %   single-valued namespace or applies_to.
            %
            %   Retired tags are skipped, with a CarasLabDB:retiredTagsNotCarried
            %   warning. The policy trigger rejects any new assignment of a
            %   retired tag, so carrying one would make the whole correction
            %   fail -- a weight could not be fixed because a stage value was
            %   retired. Skipping keeps the correction possible and stays
            %   visible: the warning names the tags, and fn_check_integrity
            %   keeps reporting tag_not_carried_forward for the successor until
            %   someone re-tags it (or un-retires the tag and adds it).
            %
            %   Must run inside PTRANSACT, with the successor's insert.
            arguments
                obj (1,1) CarasLabDB
                kind (1,1) string {mustBeMember(kind, ["event", "artifact"])}
                oldId (1,1) string
                newId (1,1) string
            end
            [~, pk] = CarasLabDB.pTagEntity(kind);
            litKind = obj.sqlLiteral(kind);
            litOld  = obj.sqlLiteral(oldId);
            src = " FROM " + obj.pT("tag_current") + " c JOIN " + obj.pT("tag") + ...
                " t ON t.tag = c.tag WHERE c.entity_kind = " + litKind + ...
                " AND c." + pk + " = " + litOld + "::uuid";

            R = obj.pSelect("SELECT c.tag" + src + " AND t.retired_at IS NOT NULL ORDER BY c.tag;");
            if height(R) > 0
                warning("CarasLabDB:retiredTagsNotCarried", ...
                    "%s %s supersedes %s, whose retired tag(s) %s were not carried " + ...
                    "forward (a retired tag cannot be assigned); lab.fn_check_integrity() " + ...
                    "reports this as tag_not_carried_forward.", kind, newId, oldId, ...
                    strjoin(reshape(CarasLabDB.pColText(R.tag), 1, []), ", "));
            end

            obj.pExec("INSERT INTO " + obj.pT("tag_assignment") + ...
                " (entity_kind, " + pk + ", tag, op, note, applied_by)" + ...
                " SELECT " + litKind + ", " + obj.sqlLiteral(newId) + "::uuid, c.tag, 'add', " + ...
                obj.sqlLiteral("carried forward from " + oldId) + ", " + ...
                obj.sqlLiteral(obj.CurrentPersonId) + "::uuid" + ...
                src + " AND t.retired_at IS NULL ORDER BY c.tag;");
        end

        function out = pTransact(obj, fn)
            %PTRANSACT Run FN() as one transaction: commit on success, roll back on error.
            %   OUT = pTransact(obj, @() ...) returns FN's single output. FN's
            %   statements go through obj.Connection with AutoCommit off; the
            %   prior AutoCommit mode is restored however this exits (onCleanup).
            %   Every multi-statement write of this class goes through here, so
            %   none of them can commit half its rows.
            arguments
                obj (1,1) CarasLabDB
                fn (1,1) function_handle
            end
            conn = obj.Connection;
            priorAutoCommit = conn.AutoCommit;
            restore = onCleanup(@() CarasLabDB.pRestoreAutoCommit(conn, priorAutoCommit)); %#ok<NASGU>
            % Refuse to run inside somebody else's transaction: the commit
            % below would commit their uncommitted work, and the rollback
            % would discard it.
            if strcmpi(string(priorAutoCommit), "off")
                error("CarasLabDB:transactionInProgress", ...
                    "AutoCommit is already off: another transaction is in " + ...
                    "progress on this connection. Commit or roll it back first.");
            end
            conn.AutoCommit = 'off';
            try
                out = fn();
                commit(conn);
            catch ME
                % A failing rollback (dead connection, already-aborted
                % transaction) must not replace the constraint violation the
                % caller actually needs to see.
                try
                    rollback(conn);
                catch
                end
                rethrow(ME);
            end
        end

        function w = pTagWhere(obj, kind, allTags, anyTags, noneTags)
            %PTAGWHERE The lab.fn_tag_match clause for Tags= / AnyTags= / NotTags=.
            %   Returns strings(1,0) when no token was given, so pSelectFrom
            %   adds nothing. The id column comes from the fixed PTAGENTITY
            %   map, never from the caller; every token is validated locally
            %   (PTAGARRAYLITERAL) and passed as a sqlLiteral value.
            [~, pk] = CarasLabDB.pTagEntity(kind);
            arrs = [CarasLabDB.pTagArrayLiteral(allTags), ...
                    CarasLabDB.pTagArrayLiteral(anyTags), ...
                    CarasLabDB.pTagArrayLiteral(noneTags)];
            if all(arrs == "NULL::text[]")
                w = strings(1, 0);
                return
            end
            w = obj.pT("fn_tag_match") + "(" + obj.sqlLiteral(kind) + ", " + ...
                pk + "::text, " + strjoin(arrs, ", ") + ")";
        end

        function ids = pApplyTags(obj, kind, entityId, tags, op, note, appliedBy)
            %PAPPLYTAGS lab.fn_tag(kind, id, tag, OP) for each tag; one transaction if several.
            %   Shared by ADDTAG and REMOVETAG. Tags are validated and
            %   canonicalised locally, then de-duplicated (so "Pilot" and
            %   "pilot" are one write, not a duplicate-add error).
            CarasLabDB.pTagEntity(kind);   % validates the kind
            tags = unique(CarasLabDB.normalizeTag(reshape(tags, 1, [])), "stable");
            by = obj.pCreatedBy(appliedBy);
            write = @() obj.pFnTagEach(kind, entityId, tags, op, note, by);
            if isscalar(tags)
                ids = write();            % one statement is atomic by itself
            else
                ids = obj.pTransact(write);
            end
        end

        function ids = pFnTagEach(obj, kind, entityId, tags, op, note, by)
            %PFNTAGEACH The loop of PAPPLYTAGS. Several tags: run only inside PTRANSACT.
            ids = zeros(1, numel(tags));
            for i = 1:numel(tags)
                ids(i) = obj.pFnTag(kind, entityId, tags(i), op, note, by);
            end
        end

        function id = pFnTag(obj, kind, entityId, tag, op, note, by)
            %PFNTAG One call of lab.fn_tag; returns the assignment_id it wrote.
            R = obj.pSelect("SELECT " + obj.pT("fn_tag") + "(" + ...
                obj.sqlLiteral(kind) + ", " + obj.sqlLiteral(entityId) + ", " + ...
                obj.sqlLiteral(tag) + ", " + obj.sqlLiteral(op) + ", " + ...
                obj.sqlLiteral(note) + ", " + obj.sqlLiteral(by) + "::uuid) AS assignment_id;");
            id = double(R.assignment_id(1));
        end

        function base = pEventBase(obj, eventType, opts)
            %PEVENTBASE Assemble the lab.event insert struct shared by all event types.
            %   opts is the name-value struct of an addXEvent method; it must expose
            %   the common base fields (OccurredAt, SubjectId, SessionId, Notes,
            %   Attributes, RecordedBy, RecordedAt, Supersedes).
            base = struct("event_type", string(eventType));
            base.occurred_at = opts.OccurredAt;   % required, validated datetime
            base = obj.pSet(base, "subject_id", opts.SubjectId);
            base = obj.pSet(base, "session_id", opts.SessionId);
            base = obj.pSet(base, "notes", opts.Notes);
            base = obj.pSet(base, "attributes", opts.Attributes);
            base = obj.pSet(base, "supersedes", opts.Supersedes);
            recordedBy = opts.RecordedBy;
            if ~obj.pIsProvided(recordedBy)
                recordedBy = obj.CurrentPersonId;
            end
            base = obj.pSet(base, "recorded_by", recordedBy);
            base = obj.pSet(base, "recorded_at", opts.RecordedAt);
        end

        function val = pCreatedBy(obj, provided)
            %PCREATEDBY Resolve a created_by/verified_by value, defaulting to CurrentPersonId.
            if obj.pIsProvided(provided)
                val = provided;
            else
                val = obj.CurrentPersonId;
            end
        end

        function pid = pResolvePerson(obj, personId, email, name)
            %PRESOLVEPERSON Resolve a person_id from an id, email, or full name.
            if obj.pIsProvided(personId)
                pid = personId;
                return
            end
            if obj.pIsProvided(email)
                % Case-insensitive to match the schema's uq_person_email_lower
                % index: 'Dan@umd.edu' and 'dan@umd.edu' are one person, and a
                % case-sensitive lookup here would raise personNotFound for a
                % user who capitalises their own address.
                where = "lower(email) = lower(" + obj.sqlLiteral(email) + ")";
            elseif obj.pIsProvided(name)
                where = "full_name = " + obj.sqlLiteral(name);
            else
                pid = string(missing);
                return
            end
            T = obj.pSelect("SELECT person_id FROM " + obj.pT("person") + ...
                " WHERE " + where + " LIMIT 1;");
            if height(T) == 0
                error("CarasLabDB:personNotFound", "No person matches the supplied identity.");
            end
            pid = string(T.person_id(1));
        end

        function T = pSelectFrom(obj, tableRef, filters, opts)
            %PSELECTFROM SELECT * FROM tableRef with equality filters, ORDER BY and LIMIT.
            %   OrderBy and Where (extra ANDed clauses) are built internally,
            %   never from caller input. Every getter passes an OrderBy whose
            %   columns together are unique, so the order is total: without
            %   one, LIMIT returns whichever rows the planner reaches first
            %   and row 1 can change between calls.
            arguments
                obj (1,1) CarasLabDB
                tableRef (1,1) string
                filters (1,1) struct
                opts.Limit (1,1) double = 0
                opts.OrderBy (1,1) string = ""
                opts.Where (1,:) string = strings(1, 0)
            end
            sql = "SELECT * FROM " + tableRef + obj.pWhere(filters, opts.Where);
            if strlength(opts.OrderBy) > 0
                sql = sql + " ORDER BY " + opts.OrderBy;
            end
            if opts.Limit > 0
                sql = sql + " LIMIT " + string(opts.Limit);
            end
            T = obj.pSelect(sql + ";");
        end

        function w = pWhere(obj, filters, extra)
            %PWHERE Build a WHERE clause of ANDed equality tests from a struct.
            %   EXTRA is an optional string array of further internally-built
            %   clauses to AND in.
            arguments
                obj (1,1) CarasLabDB
                filters (1,1) struct
                extra (1,:) string = strings(1, 0)
            end
            fn = string(fieldnames(filters));
            clauses = extra;
            for i = 1:numel(fn)
                v = filters.(char(fn(i)));
                if obj.pIsProvided(v)
                    clauses(end+1) = fn(i) + " = " + obj.sqlLiteral(v); %#ok<AGROW>
                end
            end
            if isempty(clauses)
                w = "";
            else
                w = " WHERE " + strjoin(clauses, " AND ");
            end
        end

        function pInitSession(obj)
            %PINITSESSION Align the session time zone and read the schema version.
            %   The native driver returns timestamptz as an *unzoned* datetime
            %   holding the server session's wall-clock reading, while
            %   sqlLiteral tags an unzoned datetime as this workstation's
            %   "local" zone. Setting the session zone to the workstation's
            %   zone makes the two agree: get* results and the GUI show local
            %   time (not the server's zone, typically UTC, unlabelled), and a
            %   timestamp read back and written again keeps its instant.
            tz = string(datetime("now", "TimeZone", "local").TimeZone);
            try
                obj.pExec("SET TIME ZONE " + obj.sqlLiteral(tz) + ";");
            catch ME
                warning("CarasLabDB:timeZoneNotSet", ...
                    "Could not set the session time zone to '%s'; timestamps " + ...
                    "read from the database are in the server's zone. (%s)", ...
                    tz, ME.message);
            end

            % Version 1 of the schema had no schema_version table. Probe for
            % it rather than letting the SELECT fail, which would abort the
            % caller's transaction on an injected connection.
            obj.SchemaVersion = NaN;
            R = obj.pSelect("SELECT to_regclass(" + ...
                obj.sqlLiteral(obj.pT("schema_version")) + ") IS NOT NULL AS present;");
            if logical(R.present(1))
                V = obj.pSelect("SELECT max(version) AS v FROM " + ...
                    obj.pT("schema_version") + ";");
                obj.SchemaVersion = double(V.v(1));
            end
            if ~isequal(obj.SchemaVersion, CarasLabDB.SchemaVersionExpected)
                if isnan(obj.SchemaVersion)
                    found = "unknown (no schema_version table, i.e. version 1)";
                else
                    found = string(obj.SchemaVersion);
                end
                warning("CarasLabDB:schemaVersionMismatch", ...
                    "Database schema version is %s; this CarasLabDB class is " + ...
                    "written for version %d. Upgrade the database with the " + ...
                    "scripts in design_docs/migrations/, or use a matching client.", ...
                    found, CarasLabDB.SchemaVersionExpected);
            end
        end

        function rows = pRowsAsText(obj, tableRef, whereClause, idCol)
            %PROWSASTEXT Read rows as structs of exact text values (missing = NULL).
            %   Each column comes back as the text Postgres itself prints for
            %   it (jsonb_each_text(to_jsonb(row))): numeric with its stored
            %   digits and scale, timestamptz as ISO 8601 with an explicit
            %   offset, jsonb as its JSON text, '' distinct from NULL. Written
            %   back through sqlLiteral those strings are assignment-cast into
            %   the same column types, so a value carried forward by a
            %   correction is stored exactly as it was: it never passes through
            %   a MATLAB double or an unzoned datetime. WHERECLAUSE refers to
            %   the row as alias r; IDCOL is a column unique within the result.
            %   Returns a cell array of structs, one per row, ordered by IDCOL.
            R = obj.pSelect("SELECT r." + idCol + "::text AS row_id, j.key, j.value, " + ...
                "(j.value IS NULL) AS is_null FROM " + tableRef + " r " + ...
                "CROSS JOIN LATERAL jsonb_each_text(to_jsonb(r)) j " + ...
                "WHERE " + whereClause + " ORDER BY r." + idCol + ", j.key;");
            rows = {};
            if height(R) == 0
                return
            end
            ids = CarasLabDB.pColText(R.row_id);
            keys = CarasLabDB.pColText(R.key);
            vals = CarasLabDB.pColText(R.value);
            vals(logical(R.is_null)) = string(missing);
            [~, first] = unique(ids, "stable");
            bounds = [first; numel(ids) + 1];
            rows = cell(1, numel(first));
            for k = 1:numel(first)
                s = struct();
                for i = bounds(k):bounds(k + 1) - 1
                    s.(char(keys(i))) = vals(i);
                end
                rows{k} = s;
            end
        end

        function s = pArtifactSuccessor(obj, row)
            %PARTIFACTSUCCESSOR Insert struct for the row that supersedes artifact ROW.
            %   ROW is a pRowsAsText struct of lab.artifact. Every column is
            %   carried forward except the regenerated ones; supersedes points
            %   at ROW and created_by is the current person.
            s = rmfield(row, intersect(fieldnames(row), ...
                {'artifact_id', 'created_at', 'created_by', 'supersedes'}));
            s.supersedes = row.artifact_id;
            s = obj.pSet(s, "created_by", obj.pCreatedBy(string(missing)));
        end
    end

    methods (Static, Access = private)
        function s = pSet(s, name, value)
            %PSET Add field NAME=VALUE to struct S only if VALUE is "provided".
            %   Unprovided values (missing string, NaN, NaT, []) are omitted so the
            %   database default (or NULL) applies.
            if CarasLabDB.pIsProvided(value)
                s.(char(name)) = value;
            end
        end

        function tf = pIsProvided(v)
            %PISPROVIDED Whether a value should be written (vs. left to DB default/NULL).
            if isstring(v)
                tf = isscalar(v) && ~ismissing(v);
            elseif isdatetime(v)
                tf = ~isempty(v) && ~all(isnat(v(:)));
            elseif isnumeric(v)
                tf = ~isempty(v) && ~all(isnan(v(:)));
            else
                tf = ~isempty(v);
            end
        end

        function tbl = pDetailTable(eventType)
            %PDETAILTABLE Map an event_type code to its detail table name, safely.
            %   event_type is FK-constrained to lab.event_type(code), but
            %   addEventType is public, so the vocabulary is not a closed set at
            %   runtime -- a code inserted there comes back out of the database
            %   and would otherwise be concatenated straight into SQL as an
            %   *identifier*, which sqlLiteral does not and cannot protect
            %   (it escapes values). Validating against the eight types that
            %   actually have detail tables closes that stored-injection path
            %   and turns an unknown code into a clear error instead of a
            %   confusing "relation does not exist".
            known = ["birth", "surgery", "recording", "behavior", ...
                     "husbandry", "endpoint", "histology", "analysis"];
            eventType = string(eventType);
            if ~isscalar(eventType) || ismissing(eventType) || ~ismember(eventType, known)
                error("CarasLabDB:unknownEventType", ...
                    "Event type '%s' has no detail table (expected one of: %s).", ...
                    eventType, strjoin(known, ", "));
            end
            tbl = eventType + "_event";
        end

        function [tbl, pk] = pTagEntity(kind)
            %PTAGENTITY Map a taggable entity kind to its table and id column, safely.
            %   The id column is also the column of that kind in
            %   lab.tag_assignment / lab.tag_current. Like PDETAILTABLE, this
            %   is a fixed map so that a caller's kind string can only select
            %   one of five internal identifiers, never become one.
            kind = string(kind);
            if ~isscalar(kind) || ismissing(kind)
                kind = "<missing>";
            end
            switch kind
                case "event",    tbl = "event";    pk = "event_id";
                case "artifact", tbl = "artifact"; pk = "artifact_id";
                case "subject",  tbl = "subject";  pk = "subject_id";
                case "session",  tbl = "session";  pk = "session_id";
                case "project",  tbl = "project";  pk = "project_id";
                otherwise
                    error("CarasLabDB:unknownEntityKind", ...
                        "Entity kind '%s' cannot be tagged (expected one of: " + ...
                        "event, artifact, subject, session, project).", kind);
            end
        end

        function lit = pTagArrayLiteral(tokens)
            %PTAGARRAYLITERAL Tag-filter tokens as an ARRAY[...]::text[] literal.
            %   Missing and blank elements are dropped (lab.fn_tag_match ignores
            %   them too); the rest are validated and canonicalised with
            %   normalizeTag(AllowWildcard=true) so a malformed token fails here
            %   with a clear message. No token left gives NULL::text[], which
            %   lab.fn_tag_match treats as "no constraint".
            tokens = reshape(string(tokens), 1, []);
            tokens = tokens(~ismissing(tokens));
            tokens = tokens(strlength(strip(tokens, "both", " ")) > 0);
            if isempty(tokens)
                lit = "NULL::text[]";
                return
            end
            tokens = CarasLabDB.normalizeTag(tokens, AllowWildcard=true);
            lits = strings(1, numel(tokens));
            for i = 1:numel(tokens)
                lits(i) = CarasLabDB.sqlLiteral(tokens(i));
            end
            lit = "ARRAY[" + strjoin(lits, ", ") + "]::text[]";
        end

        function lit = pAppliesToLiteral(kinds)
            %PAPPLIESTOLITERAL Validated text[] literal body for applies_to, e.g. {event,artifact}.
            %   Every element must be a taggable kind; duplicates are dropped
            %   and the kinds put in a fixed order. The result is plain text
            %   ('{event,artifact}') that sqlLiteral quotes and Postgres
            %   assignment-casts to text[]; validation here means it can only
            %   ever contain the five known words.
            known = ["event", "artifact", "subject", "session", "project"];
            kinds = reshape(string(kinds), 1, []);
            if isempty(kinds) || any(ismissing(kinds)) || ~all(ismember(kinds, known))
                error("CarasLabDB:invalidValue", ...
                    "AppliesTo must be a non-empty list of: %s.", strjoin(known, ", "));
            end
            lit = "{" + strjoin(known(ismember(known, kinds)), ",") + "}";
        end

        function pCheckMember(value, allowed, name)
            %PCHECKMEMBER Error if a provided VALUE is not in ALLOWED (skips unprovided).
            if CarasLabDB.pIsProvided(value) && ~ismember(string(value), allowed)
                error("CarasLabDB:invalidValue", "%s must be one of: %s (got '%s').", ...
                    name, strjoin(allowed, ", "), string(value));
            end
        end

        function [cols, vals] = pColsVals(s)
            %PCOLSVALS Split a struct into parallel column-name and SQL-literal arrays.
            cols = string(fieldnames(s))';
            vals = strings(1, numel(cols));
            for i = 1:numel(cols)
                vals(i) = CarasLabDB.sqlLiteral(s.(char(cols(i))));
            end
        end

        function s = pMergeOverrides(s, ov)
            %PMERGEOVERRIDES Copy every field of override struct OV onto S (column names).
            fn = fieldnames(ov);
            for i = 1:numel(fn)
                s.(fn{i}) = ov.(fn{i});
            end
        end

        function s = pColText(col)
            %PCOLTEXT A fetched text column as a string column vector.
            %   The driver may hand text back as a string array or a cell of
            %   char; anything else in a cell (a NULL) becomes missing.
            if iscell(col)
                s = strings(numel(col), 1);
                for i = 1:numel(col)
                    v = col{i};
                    if isstring(v) && isscalar(v)
                        s(i) = v;
                    elseif ischar(v)
                        s(i) = string(v);
                    else
                        s(i) = string(missing);
                    end
                end
            else
                s = reshape(string(col), [], 1);
            end
        end

        function s = pShortestDecimal(v)
            %PSHORTESTDECIMAL Shortest %g text (15-17 significant digits) that reads back as V.
            %   %.17g always round-trips an IEEE double, but it spells out the
            %   binary value: 71.9 becomes 71.900000000000006, and a numeric
            %   column stores that text verbatim, so weight_g = 71.9 is then
            %   false. The decimal the user typed is the shortest text that
            %   parses back to the same double; 15 significant digits are
            %   enough for any value typed by hand, and the loop falls through
            %   to 17 only for doubles that need it (e.g. 0.1 + 0.2).
            for fmt = ["%.15g", "%.16g", "%.17g"]
                s = string(sprintf(fmt, v));
                if str2double(s) == v
                    return
                end
            end
        end

        function pRestoreAutoCommit(conn, state)
            %PRESTOREAUTOCOMMIT Restore a connection's AutoCommit mode, loudly on failure.
            %   Swallowing a failure here is silent data loss: the connection
            %   stays with AutoCommit='off', every later insert runs inside a
            %   transaction nothing ever commits, the caller gets its generated
            %   UUIDs back and believes the write succeeded, and the data
            %   disappears when the connection closes.
            try
                conn.AutoCommit = state;
            catch ME
                warning("CarasLabDB:autoCommitNotRestored", ...
                    "Could not restore AutoCommit='%s'; later writes may never " + ...
                    "commit. Reconnect before writing again. (%s)", ...
                    string(state), ME.message);
            end
        end
    end

    % ------------------------------------------------------------------
    % Public static SQL helper (used by @CarasLabDBApp to build filters).
    % Identifiers are still supplied internally; only VALUES pass through
    % this escaper. Do not pass untrusted strings as identifiers.
    % ------------------------------------------------------------------
    methods (Static)
        function out = sqlLiteral(v)
            %SQLLITERAL Format a MATLAB value as a Postgres SQL literal.
            %   Handles NULLs (missing/NaN/NaT/[]), text (quotes doubled),
            %   numbers, logicals, datetime (timestamptz), and jsonb (struct /
            %   containers.Map / dictionary via jsonencode).
            if isempty(v)
                out = "NULL";
                return
            end
            if isstring(v) && isscalar(v) && ismissing(v)
                out = "NULL";
                return
            end
            if isdatetime(v)
                if ~isscalar(v)
                    error("CarasLabDB:scalarExpected", "datetime SQL values must be scalar.");
                end
                if isnat(v)
                    out = "NULL";
                    return
                end
                % An unzoned datetime is ambiguous: it has to be *assumed* to be
                % in some zone, and "local" is the only defensible guess for a
                % value the user typed at this workstation. Prefer passing a
                % zoned datetime (datetime(..., "TimeZone", "local")) so the
                % instant is explicit. Note this is why values read back OUT of
                % the database must not be round-tripped through here -- the
                % driver returns timestamptz unzoned, so re-tagging it "local"
                % would shift the instant whenever the server session zone
                % differs. pInitSession sets the session zone to the local
                % zone to keep the two aligned, and supersedeEvent carries
                % values forward as exact text (pRowsAsText), not datetimes.
                if isempty(v.TimeZone)
                    v.TimeZone = "local";
                end
                % Microseconds: timestamptz stores them, and a millisecond
                % format would drop the last three digits of every value.
                v.Format = "yyyy-MM-dd HH:mm:ss.SSSSSSxxx";
                out = "TIMESTAMPTZ '" + string(v) + "'";
                return
            end
            if isstruct(v) || isa(v, "containers.Map") || isa(v, "dictionary")
                js = string(jsonencode(v));
                out = CarasLabDB.pQuoteText(js) + "::jsonb";
                return
            end
            if islogical(v)
                if ~isscalar(v)
                    error("CarasLabDB:scalarExpected", "logical SQL values must be scalar.");
                end
                if v
                    out = "true";
                else
                    out = "false";
                end
                return
            end
            if isnumeric(v)
                if ~isscalar(v)
                    error("CarasLabDB:scalarExpected", "Numeric SQL values must be scalar.");
                end
                if isnan(v)
                    out = "NULL";
                    return
                end
                % Inf would otherwise be emitted verbatim and fail in the server
                % as a syntax error; catch it here where the message can name
                % the culprit.
                if ~isfinite(v)
                    error("CarasLabDB:nonFiniteValue", ...
                        "Cannot write a non-finite numeric value (%g) to the database.", v);
                end
                if v == floor(v) && abs(v) < 2^53
                    out = string(sprintf("%d", v));
                else
                    out = CarasLabDB.pShortestDecimal(v);
                end
                return
            end
            % char or string scalar text
            s = string(v);
            if ~isscalar(s)
                error("CarasLabDB:scalarExpected", "Text SQL values must be scalar.");
            end
            out = CarasLabDB.pQuoteText(s);
        end

        function tags = normalizeTag(tags, opts)
            %NORMALIZETAG Canonical spelling of one or more tags, validated locally.
            %   t = CarasLabDB.normalizeTag(" Stage:Raw ")      % -> "stage:raw"
            %   t = CarasLabDB.normalizeTag("Auditory_Cortex")  % -> "tag:auditory_cortex"
            %   t = CarasLabDB.normalizeTag("qc:*", AllowWildcard=true)   % filters only
            %
            %   Mirrors lab.fn_canonical_tag: lower case, surrounding spaces
            %   removed, and a tag with no colon placed in the reserved 'tag'
            %   namespace. Nothing else is rewritten: a tag whose namespace
            %   does not match ^[a-z][a-z0-9_]{0,31}$ or whose value does not
            %   match ^[a-z0-9][a-z0-9_.-]{0,63}$ raises CarasLabDB:invalidTag
            %   here, before the database would reject it less helpfully.
            %   AllowWildcard=true also accepts the value '*' ("any tag of the
            %   namespace"), which only tag filters understand.
            arguments
                tags string
                opts.AllowWildcard (1,1) logical = false
            end
            for i = 1:numel(tags)
                [ns, val] = CarasLabDB.parseTag(tags(i), AllowWildcard=opts.AllowWildcard);
                tags(i) = ns + ":" + val;
            end
        end

        function [namespace, value] = parseTag(tag, opts)
            %PARSETAG Split a tag into its namespace and value, after normalizing it.
            %   [ns, val] = CarasLabDB.parseTag("Stage:Raw")       % "stage", "raw"
            %   [ns, val] = CarasLabDB.parseTag("auditory_cortex") % "tag", "auditory_cortex"
            %   Same rules and errors as NORMALIZETAG; the split is at the
            %   first colon, so a second colon lands in the value and fails
            %   its pattern.
            arguments
                tag (1,1) string
                opts.AllowWildcard (1,1) logical = false
            end
            if ismissing(tag)
                error("CarasLabDB:invalidTag", "A tag is required (got <missing>).");
            end
            % lab.fn_canonical_tag uses btrim(), which strips spaces only.
            t = lower(strip(tag, "both", " "));
            k = strfind(t, ":");
            if isempty(k)
                namespace = "tag";
                value = t;
            else
                namespace = extractBefore(t, k(1));
                value = extractAfter(t, k(1));
            end
            if isempty(regexp(char(namespace), '^[a-z][a-z0-9_]{0,31}$', 'once'))
                error("CarasLabDB:invalidTag", ...
                    "Invalid tag '%s': the namespace '%s' must be a lower-case letter " + ...
                    "followed by at most 31 of a-z, 0-9 and _.", tag, namespace);
            end
            isWildcard = opts.AllowWildcard && value == "*";
            if ~isWildcard && isempty(regexp(char(value), '^[a-z0-9][a-z0-9_.-]{0,63}$', 'once'))
                error("CarasLabDB:invalidTag", ...
                    "Invalid tag '%s': the value '%s' must start with a-z or 0-9 and " + ...
                    "have at most 64 characters of a-z, 0-9, _, . and -.", tag, value);
            end
        end

        function d = displayTag(tags)
            %DISPLAYTAG A tag as people write it: a bare tag shows without 'tag:'.
            %   CarasLabDB.displayTag("tag:auditory_cortex")   % -> "auditory_cortex"
            %   CarasLabDB.displayTag("stage:raw")             % -> "stage:raw"
            %   The same rule as the display_tag column of lab.tag_current.
            arguments
                tags string
            end
            d = tags;
            bare = startsWith(d, "tag:");
            d(bare) = extractAfter(d(bare), 4);
        end
    end

    methods (Static, Access = private)
        function out = pQuoteText(s)
            %PQUOTETEXT Quote text as a Postgres literal, safe under either
            %   setting of standard_conforming_strings.
            %
            %   Doubling single quotes is only sufficient while
            %   standard_conforming_strings = on (the default since PG 9.1). If
            %   a server or role has it off, a backslash becomes an escape
            %   character, so the input \' is read as an escaped quote and the
            %   following quote *closes* the literal -- everything after it
            %   executes. Emitting an explicit E'' literal (with backslashes
            %   doubled) is unambiguous under both settings. The jsonb path
            %   relies on this too, since JSON escaping is backslash-heavy.
            s = replace(s, "'", "''");
            if contains(s, "\")
                out = "E'" + replace(s, "\", "\\") + "'";
            else
                out = "'" + s + "'";
            end
        end
    end
end
