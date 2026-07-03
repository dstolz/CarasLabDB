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
%                       Checksum="ab12...", Role="raw", Format="dat", SizeBytes=1.2e10);
%       T   = db.getArtifacts(SubjectId="G-0421");
%       L   = db.artifactLineage(aid, Direction="up");
%
%   Large methods live in their own files under @CarasLabDB and are declared
%   in the "methods" signature block below:
%       addBirthEvent, addSurgeryEvent, addRecordingEvent, addBehaviorEvent,
%       addHusbandryEvent, addEndpointEvent, addHistologyEvent,
%       addAnalysisEvent, addArtifact, supersedeEvent, supersedeArtifact,
%       artifactLineage.
%
%   Requires MATLAB R2025a or later and the Database Toolbox.
%
%   NOTE ON SQL SAFETY: values are escaped and formatted into SQL literals
%   by the private SQLLITERAL helper (single quotes doubled, typed casts for
%   timestamps/jsonb). Table and column identifiers are supplied internally,
%   never by end users. Do not pass untrusted strings as identifiers.

    properties (SetAccess = private)
        Connection                              % Database Toolbox connection object
        Schema (1,1) string = "lab"           % Postgres schema that owns the tables
        CurrentPersonId (1,1) string = string(missing)  % person_id for provenance columns
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
            f = obj.pSet(f, "email", opts.Email);
            f = obj.pSet(f, "full_name", opts.FullName);
            f = obj.pSet(f, "is_active", opts.IsActive);
            T = obj.pSelectFrom(obj.pT("person"), f);
        end

        function T = getSpecies(obj)
            T = obj.pSelectFrom(obj.pT("species"), struct());
        end

        function T = getStorageRoots(obj)
            T = obj.pSelectFrom(obj.pT("storage_root"), struct());
        end

        function T = getProbes(obj, opts)
            arguments
                obj (1,1) CarasLabDB
                opts.ProbeId (1,1) string = string(missing)
            end
            f = obj.pSet(struct(), "probe_id", opts.ProbeId);
            T = obj.pSelectFrom(obj.pT("probe"), f);
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
            T = obj.pSelectFrom(obj.pT("pipeline"), f);
        end

        function T = getEventTypes(obj)
            T = obj.pSelectFrom(obj.pT("event_type"), struct());
        end

        function T = getArtifactRoles(obj)
            T = obj.pSelectFrom(obj.pT("artifact_role"), struct());
        end

        function T = getAcquisitionSystems(obj)
            T = obj.pSelectFrom(obj.pT("acquisition_system"), struct());
        end
    end

    % ==================================================================
    % Retrieval — projects
    % ==================================================================
    methods
        function T = getProjects(obj, opts)
            %GETPROJECTS Retrieve projects filtered by any of the given columns.
            arguments
                obj (1,1) CarasLabDB
                opts.ProjectId (1,1) string = string(missing)
                opts.Name (1,1) string = string(missing)
                opts.IsActive = []   % logical scalar or [] for any
            end
            f = struct();
            f = obj.pSet(f, "project_id", opts.ProjectId);
            f = obj.pSet(f, "name", opts.Name);
            f = obj.pSet(f, "is_active", opts.IsActive);
            T = obj.pSelectFrom(obj.pT("project"), f);
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
            T = obj.pSelectFrom(obj.pT("project_member"), f);
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
            T = obj.pSelectFrom(obj.pT("project_artifact"), f);
        end
    end

    % ==================================================================
    % Retrieval — dimensions, events, artifacts, views
    % ==================================================================
    methods
        function T = getSubjects(obj, opts)
            %GETSUBJECTS Retrieve subjects filtered by any of the given columns.
            arguments
                obj (1,1) CarasLabDB
                opts.SubjectId (1,1) string = string(missing)
                opts.ProjectId (1,1) string = string(missing)
                opts.SpeciesCode (1,1) string = string(missing)
                opts.Sex (1,1) string = string(missing)
            end
            f = struct();
            f = obj.pSet(f, "subject_id", opts.SubjectId);
            f = obj.pSet(f, "project_id", opts.ProjectId);
            f = obj.pSet(f, "species_code", opts.SpeciesCode);
            f = obj.pSet(f, "sex", opts.Sex);
            T = obj.pSelectFrom(obj.pT("subject"), f);
        end

        function T = getSessions(obj, opts)
            %GETSESSIONS Retrieve sessions filtered by any of the given columns.
            arguments
                obj (1,1) CarasLabDB
                opts.SessionId (1,1) string = string(missing)
                opts.SubjectId (1,1) string = string(missing)
                opts.Label (1,1) string = string(missing)
                opts.StorageRootId double {mustBeInteger, mustBeScalarOrEmpty} = []
            end
            f = struct();
            f = obj.pSet(f, "session_id", opts.SessionId);
            f = obj.pSet(f, "subject_id", opts.SubjectId);
            f = obj.pSet(f, "label", opts.Label);
            f = obj.pSet(f, "storage_root_id", opts.StorageRootId);
            T = obj.pSelectFrom(obj.pT("session"), f);
        end

        function T = getEvents(obj, opts)
            %GETEVENTS Retrieve base event rows. Reads event_active unless ActiveOnly=false.
            arguments
                obj (1,1) CarasLabDB
                opts.EventId (1,1) string = string(missing)
                opts.EventType (1,1) string = string(missing)
                opts.SubjectId (1,1) string = string(missing)
                opts.SessionId (1,1) string = string(missing)
                opts.ActiveOnly (1,1) logical = obj.UseActiveViews
                opts.Limit (1,1) double {mustBeInteger, mustBeNonnegative} = 0
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
            T = obj.pSelectFrom(tbl, f, opts.Limit);
        end

        function T = getEventDetail(obj, opts)
            %GETEVENTDETAIL Join a base event to its type-specific detail table.
            %   Returns every lab.event column plus the detail columns that are
            %   not already present on the base row (event_id, event_type are the
            %   join/discriminator columns and are taken from the base only).
            arguments
                obj (1,1) CarasLabDB
                opts.EventId (1,1) string
            end
            E = obj.pSelect("SELECT event_type FROM " + obj.pT("event") + ...
                " WHERE event_id = " + obj.sqlLiteral(opts.EventId) + ";");
            if height(E) == 0
                error("CarasLabDB:eventNotFound", "No event with id %s.", opts.EventId);
            end
            detailTable = string(E.event_type(1)) + "_event";

            % Detail columns minus the ones the base already provides.
            C = obj.pSelect("SELECT column_name FROM information_schema.columns" + ...
                " WHERE table_schema = " + obj.sqlLiteral(obj.Schema) + ...
                " AND table_name = " + obj.sqlLiteral(detailTable) + ...
                " AND column_name NOT IN ('event_id', 'event_type')" + ...
                " ORDER BY ordinal_position;");
            detailCols = string(C.column_name);

            if isempty(detailCols)
                selectList = "e.*";
            else
                selectList = "e.*, " + strjoin("d." + reshape(detailCols, 1, []), ", ");
            end
            T = obj.pSelect("SELECT " + selectList + " FROM " + obj.pT("event") + " e " + ...
                "JOIN " + obj.pT(detailTable) + " d ON d.event_id = e.event_id " + ...
                "WHERE e.event_id = " + obj.sqlLiteral(opts.EventId) + ";");
        end

        function T = getArtifacts(obj, opts)
            %GETARTIFACTS Retrieve artifacts. Reads artifact_active unless ActiveOnly=false.
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
            T = obj.pSelectFrom(tbl, f, opts.Limit);
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
            T = obj.pSelectFrom(obj.pT("event_input"), f);
        end

        function T = getArtifactVerifications(obj, opts)
            %GETARTIFACTVERIFICATIONS Retrieve checksum verification history.
            arguments
                obj (1,1) CarasLabDB
                opts.ArtifactId (1,1) string = string(missing)
            end
            f = obj.pSet(struct(), "artifact_id", opts.ArtifactId);
            T = obj.pSelectFrom(obj.pT("artifact_verification"), f);
        end

        function T = getSubjectCurrent(obj, opts)
            %GETSUBJECTCURRENT Subject dimension enriched with latest weight/endpoint (view).
            arguments
                obj (1,1) CarasLabDB
                opts.SubjectId (1,1) string = string(missing)
            end
            f = obj.pSet(struct(), "subject_id", opts.SubjectId);
            T = obj.pSelectFrom(obj.pT("subject_current"), f);
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
            T = obj.pSelectFrom(obj.pT("provenance_edge"), f);
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

        function pUpdate(obj, tableRef, s, whereClause)
            %PUPDATE Build and execute an UPDATE from a column->value struct.
            %   No-op when S has no fields. WHERECLAUSE is built by the caller
            %   from internal identifiers plus sqlLiteral-escaped key values.
            arguments
                obj (1,1) CarasLabDB
                tableRef (1,1) string
                s (1,1) struct
                whereClause (1,1) string
            end
            [cols, vals] = obj.pColsVals(s);
            if isempty(cols)
                return    % nothing provided to change
            end
            assignments = cols + " = " + vals;
            sql = "UPDATE " + tableRef + " SET " + strjoin(assignments, ", ") + ...
                " WHERE " + whereClause + ";";
            obj.pExec(sql);
        end

        function eventId = pInsertEvent(obj, base, detailTable, detail)
            %PINSERTEVENT Insert the base event and its detail row in one transaction.
            conn = obj.Connection;
            priorAutoCommit = conn.AutoCommit;
            restore = onCleanup(@() obj.pRestoreAutoCommit(conn, priorAutoCommit));
            conn.AutoCommit = 'off';
            try
                eventId = obj.pInsertReturning(obj.pT("event"), base, "event_id");
                detail.event_id = eventId;
                if ~isfield(detail, "event_type")
                    detail.event_type = base.event_type;
                end
                obj.pInsert(detailTable, detail);
                commit(conn);
            catch ME
                rollback(conn);
                rethrow(ME);
            end
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
                where = "email = " + obj.sqlLiteral(email);
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

        function T = pSelectFrom(obj, tableRef, filters, limitN)
            %PSELECTFROM SELECT * FROM tableRef with equality filters and optional LIMIT.
            arguments
                obj (1,1) CarasLabDB
                tableRef (1,1) string
                filters (1,1) struct
                limitN (1,1) double = 0
            end
            sql = "SELECT * FROM " + tableRef + obj.pWhere(filters);
            if limitN > 0
                sql = sql + " LIMIT " + string(limitN);
            end
            T = obj.pSelect(sql + ";");
        end

        function w = pWhere(obj, filters)
            %PWHERE Build a WHERE clause of ANDed equality tests from a struct.
            fn = string(fieldnames(filters));
            clauses = strings(1, 0);
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

        function pRestoreAutoCommit(conn, state)
            %PRESTOREAUTOCOMMIT Best-effort restore of a connection's AutoCommit mode.
            try
                conn.AutoCommit = state;
            catch
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
                if isempty(v.TimeZone)
                    v.TimeZone = "local";
                end
                v.Format = "yyyy-MM-dd HH:mm:ss.SSSxxx";
                out = "TIMESTAMPTZ '" + string(v) + "'";
                return
            end
            if isstruct(v) || isa(v, "containers.Map") || isa(v, "dictionary")
                js = string(jsonencode(v));
                out = "'" + replace(js, "'", "''") + "'::jsonb";
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
                if v == floor(v) && abs(v) < 2^53
                    out = string(sprintf("%d", v));
                else
                    out = string(sprintf("%.15g", v));
                end
                return
            end
            % char or string scalar text
            s = string(v);
            if ~isscalar(s)
                error("CarasLabDB:scalarExpected", "Text SQL values must be scalar.");
            end
            out = "'" + replace(s, "'", "''") + "'";
        end
    end
end
