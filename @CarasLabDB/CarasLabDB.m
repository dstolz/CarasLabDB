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
%   pointing its "supersedes" column at the row it replaces; a row that
%   should never have been written is *retracted* (retractEvent,
%   retractArtifact). Read helpers default to the *_active views (rows that
%   are neither superseded nor retracted); set UseActiveViews=false
%   (globally) or ActiveOnly=false (per call) to see full history, where
%   getEvents and getArtifacts add the columns superseded_by, is_current
%   and is_retracted to say what became of each row.
%
%   Construction (Name=Value):
%       db = CarasLabDB(Username="jdoe", Password=secret, ...
%                       Server="nas-main.lab", DatabaseName="lab");
%       db = CarasLabDB(Username="lab_rw", Password=secret, ...
%                       Server="nas-main.lab", DatabaseName="lab", ...
%                       PersonEmail="dstolz@umd.edu");
%
%   A "current person" resolved at construction auto-populates the
%   created_by / recorded_by provenance columns on inserts (override per
%   call with CreatedBy=/RecordedBy=). It is the person named by PersonId=,
%   PersonEmail= or PersonName=; a PersonId, email or name that matches no
%   one, and a PersonName shared by several people
%   (CarasLabDB:personAmbiguous), are errors. When none of the three is
%   given it is the person the database login is mapped to
%   (lab.person.db_login, read with lab.fn_current_person()), so a lab
%   member with a login of their own needs to name nobody. Only when the
%   login is mapped to no one either does the object warn
%   CarasLabDB:noCurrentPerson: it still works, but rows are then written
%   with a NULL recorded_by / created_by, and only the login the database
%   itself records (recorded_login, created_login, ...) says who wrote them.
%
%   At connection the session time zone is set to this workstation's zone,
%   so timestamps come back as local wall-clock time (see PINITSESSION), and
%   the database's schema version is read into SchemaVersion. A version other
%   than SchemaVersionExpected is an error (CarasLabDB:schemaVersionMismatch):
%   this class hard-codes the schema's columns, so against another version
%   it could write or read the wrong thing. AllowSchemaMismatch=true turns
%   the error into a warning with the same identifier, for deliberately
%   working with an older or newer database.
%
%   Time limits (seconds, Name=Value at construction; none by default):
%       ConnectTimeout   - how long opening the connection may take before it
%                          fails (PGCONNECT_TIMEOUT for the postgresql() call;
%                          the variable is put back afterwards). Without it an
%                          unreachable server can block for minutes.
%       StatementTimeout - how long one statement may run (statement_timeout)
%       LockTimeout      - how long a statement may wait for a lock (lock_timeout)
%   The last two are session settings, so they also apply to an injected
%   Connection. A connection that is lost is not reopened: construct a new
%   CarasLabDB object.
%
%   Ids. EventId= on the addXEvent methods, ArtifactId= on addArtifact /
%   addArtifactFromFile and SessionId= on addSession insert a row under an id
%   the caller minted (a uuid) instead of one the database generates, so a
%   client can refer to a row before it is written. recordEvent writes an
%   event, its input edges and its output files as one transaction that is
%   safe to send again (see RECORDEVENT).
%
%   Example:
%       db  = CarasLabDB(Username="u", Password="p", PersonEmail="me@lab");
%       pid = db.addProject(Name="Gerbil AC plasticity");
%       db.addSubject(SubjectId="G-0421", ProjectId=pid, ...
%                     SpeciesCode="meriones_unguiculatus", Sex="M");
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
%   in the "methods" signature blocks below:
%       addBirthEvent, addSurgeryEvent, addRecordingEvent, addBehaviorEvent,
%       addHusbandryEvent, addEndpointEvent, addHistologyEvent,
%       addAnalysisEvent, addHusbandryBatch, addArtifact,
%       addArtifactFromFile, fileChecksum (static), supersedeEvent,
%       supersedeArtifact, artifactLineage, runReadOnlyQuery, updateSubject,
%       updateSession, addTagNamespace, registerTag, addTag, removeTag,
%       setTag, getEntityTags, findByTags, setVariable, getVariables,
%       defineVariable, recordEvent.
%   Defined in this file: the add/get methods of the reference, project,
%   subject and session tables; getEvents, getEventDetail, getArtifacts and
%   the other readers; getTagNamespaces, getTags, updateTagNamespace,
%   retireTag; unsetVariable, getVariableValues, getVariableDefinitions,
%   updateVariableDefinition, retireVariable; retractEvent,
%   retractArtifact, getRetractions; checkIntegrity; and the static helpers
%   sqlLiteral, jsonText, normalizeTag, parseTag, displayTag,
%   normalizeVariableName.
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
%   in the same transaction. Correcting an event, by supersedeEvent or by
%   Supersedes= on an addXEvent method, also takes over its provenance: the
%   input edges are copied (unless CarryInputs=false) and the files it
%   produced are re-pointed at the new event, filed under its subject and
%   session.
%   A tag filter (Tags= / AnyTags= / NotTags=) naming a namespace that does
%   not exist or does not apply to the rows asked for, or a tag that is not
%   registered, raises CarasLabDB:tagFilterProblem instead of quietly
%   matching nothing.
%
%   Variables. The same five kinds of row can carry user-defined named
%   values -- one number or one string each, with units -- for what the
%   schema has no column for ("probe depth" 1200 um on a session). Every
%   write goes through lab.fn_set_variable / lab.fn_unset_variable:
%       db.setVariable("session", sid, "Probe Depth", 1200, Units="um");
%       db.setVariable("session", sid, "probe depth", 1350);   % an update
%       db.setVariable("subject", "G-0421", "housing", "pair");
%       T = db.getVariables("session", sid);                   % current values
%       H = db.getVariables("session", sid, History=true);     % the log
%       V = db.getVariableValues("probe depth");               % across rows
%       db.unsetVariable("session", sid, "probe depth");
%   A variable is defined on first use (or ahead of time with
%   defineVariable); its value type and units are then fixed, so a value in
%   other units is an error. Values are an append-only log, like tags: an
%   update is a new row, and the database copies a superseded event's or
%   artifact's current variables to its successor.
%
%   Retraction. An event or artifact that should never have been recorded
%   (entered twice, registered by mistake) is withdrawn, with a reason:
%       db.retractEvent(eid, "entered twice");
%       db.retractArtifact(aid, "registered under the wrong path");
%       R = db.getRetractions();
%   The row stays in the database; the *_active views, and so the get*
%   methods by default, stop returning it.
%
%   Housekeeping. checkIntegrity() returns lab.fn_check_integrity(), the
%   database's own list of what needs attention (errors first).
%   addHusbandryBatch writes one weigh-in sheet as one transaction, and
%   addArtifactFromFile registers a file from its path, computing the size
%   and SHA-256 itself (static fileChecksum).
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
        SchemaVersionExpected = 1               % schema version this class is written for
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
        valueId     = setVariable(obj, kind, entityId, name, value, opts)
        T           = getVariables(obj, kind, entityId, opts)
        name        = defineVariable(obj, name, opts)
        eventIds    = addHusbandryBatch(obj, T, opts)
        [artifactId, info] = addArtifactFromFile(obj, filePath, opts)
        out         = recordEvent(obj, eventType, opts)
    end

    methods (Static)
        checksum    = fileChecksum(filePath, opts)
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
                opts.AllowSchemaMismatch (1,1) logical = false  % warn, not error, on another schema version
                opts.ConnectTimeout double {mustBeInteger, mustBePositive, mustBeScalarOrEmpty} = []
                opts.StatementTimeout double {mustBeNonnegative, mustBeScalarOrEmpty} = []
                opts.LockTimeout double {mustBeNonnegative, mustBeScalarOrEmpty} = []
                opts.Connection = []    % inject an existing connection instead of opening one
                                        % (its session time zone is changed; see pInitSession)
            end

            % The schema name is the one identifier that comes from a caller
            % and is concatenated into every statement (pT), so it is held to
            % a plain lower-case identifier before it is ever used.
            if ismissing(opts.Schema) || ...
                    isempty(regexp(char(opts.Schema), '^[a-z_][a-z0-9_]*$', 'once'))
                error("CarasLabDB:invalidSchema", ...
                    "Schema must be a plain lower-case identifier (a-z, 0-9 and _, " + ...
                    "not starting with a digit).");
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
                % The native interface connects through libpq, which reads
                % PGCONNECT_TIMEOUT; it is set for this call only.
                restoreTimeout = []; %#ok<NASGU>
                if ~isempty(opts.ConnectTimeout)
                    restoreTimeout = CarasLabDB.pSetEnvFor("PGCONNECT_TIMEOUT", ...
                        string(opts.ConnectTimeout)); %#ok<NASGU>
                end
                obj.Connection = postgresql(opts.Username, opts.Password, ...
                    Server=opts.Server, PortNumber=opts.Port, DatabaseName=opts.DatabaseName);
                clear restoreTimeout
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

            try
                obj.pInitSession(opts.AllowSchemaMismatch);
                obj.pSetTimeouts(opts.StatementTimeout, opts.LockTimeout);
                obj.CurrentPersonId = obj.pResolvePerson(opts.PersonId, opts.PersonEmail, opts.PersonName);
            catch ME
                % A refused construction (schema version, unknown person) must
                % not leave behind a connection this object opened.
                if obj.OwnsConnection
                    try
                        obj.disconnect();
                    catch
                    end
                end
                rethrow(ME);
            end
            obj.pWarnNoPerson();
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
            %   setPerson() with no argument goes back to the person the
            %   database login is mapped to (lab.fn_current_person()), and
            %   warns CarasLabDB:noCurrentPerson when it is mapped to no one.
            arguments
                obj (1,1) CarasLabDB
                opts.PersonId (1,1) string = string(missing)
                opts.PersonEmail (1,1) string = string(missing)
                opts.PersonName (1,1) string = string(missing)
            end
            obj.CurrentPersonId = obj.pResolvePerson(opts.PersonId, opts.PersonEmail, opts.PersonName);
            obj.pWarnNoPerson();
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
            %   A trailing semicolon is removed before the statement is sent:
            %   the driver first wraps it as "SELECT * FROM (<sql>) as temp
            %   LIMIT 0" to learn the column types, and with the semicolon
            %   that is a syntax error in the server's log for every query.
            arguments
                obj (1,1) CarasLabDB
                sql (1,1) string
            end
            T = obj.pSelect(sql);
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
            %   For the schema owner only: design_docs/grants.sql withholds
            %   INSERT on lab.event_type from lab_rw, because every event
            %   type is one of the schema's detail tables and a new one
            %   arrives with a migration, not at run time.
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
            %ADDSESSION Insert a session; returns its session_id (uuid string).
            %   SessionId= inserts it under a uuid the caller minted; by
            %   default the database generates one.
            arguments
                obj (1,1) CarasLabDB
                opts.SessionId (1,1) string = string(missing)
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
            s = obj.pSet(s, "session_id", CarasLabDB.pCheckUuid(opts.SessionId, "SessionId"));
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
        function inserted = addEventInput(obj, opts)
            %ADDEVENTINPUT Record that an event consumed an artifact (event_input edge).
            %   An edge that is already recorded is an error, or with
            %   IfExists="skip" is left as it is (INSERTED is then false).
            %   Edges are immutable: a skipped edge keeps its own role.
            arguments
                obj (1,1) CarasLabDB
                opts.EventId (1,1) string
                opts.ArtifactId (1,1) string
                opts.Role (1,1) string = string(missing)
                opts.IfExists (1,1) string {mustBeMember(opts.IfExists, ["error", "skip"])} = "error"
            end
            s = struct("event_id", opts.EventId, "artifact_id", opts.ArtifactId);
            s = obj.pSet(s, "role", opts.Role);
            if opts.IfExists == "error"
                obj.pInsert(obj.pT("event_input"), s);
                inserted = true;
                return
            end
            [cols, vals] = obj.pColsVals(s);
            R = obj.pWrite("INSERT INTO " + obj.pT("event_input") + " (" + strjoin(cols, ", ") + ...
                ") VALUES (" + strjoin(vals, ", ") + ") ON CONFLICT (event_id, artifact_id) " + ...
                "DO NOTHING RETURNING event_id;");
            inserted = height(R) > 0;
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

        function dispositionId = addArtifactDisposition(obj, opts)
            %ADDARTIFACTDISPOSITION Record what became of a registered file; returns disposition_id.
            %   addArtifactDisposition(ArtifactId=aid, Disposition="deleted", OccurredAt=t)
            %   addArtifactDisposition(ArtifactId=aid, Disposition="moved", ...
            %       SuccessorArtifactId=newAid, OccurredAt=t, Note="to the NAS")
            %
            %   Disposition is "replaced" (other bytes are at the path now;
            %   SuccessorArtifactId, when given, is their row), "moved" (the
            %   bytes are elsewhere; SuccessorArtifactId is required: the row
            %   for the same checksum at the new path), "deleted", or
            %   "restored" (the same bytes are back at the path).
            %
            %   The artifact row stays active: a disposition is not a
            %   correction (lineage through the row is unchanged, so analyses
            %   that read the old bytes still point at them) and not a
            %   retraction (the row was not entered in error). The file
            %   leaves lab.artifact_present, i.e. getArtifacts(PresentOnly=true),
            %   and the integrity checks of files skip it. A disposition
            %   belongs to the file (storage root, path, checksum), so it may
            %   name any row describing that file, and every such row shares
            %   it. The database refuses one that does not fit the file's
            %   state: disposing of a file already recorded as gone, or
            %   restoring one that is present.
            arguments
                obj (1,1) CarasLabDB
                opts.ArtifactId (1,1) string
                opts.Disposition (1,1) string {mustBeMember(opts.Disposition, ...
                    ["replaced", "moved", "deleted", "restored"])}
                opts.OccurredAt (1,1) datetime
                opts.SuccessorArtifactId (1,1) string = string(missing)
                opts.Note (1,1) string = string(missing)
                opts.Attributes = []
                opts.RecordedBy (1,1) string = string(missing)
            end
            s = struct("artifact_id", obj.pCheckUuid(opts.ArtifactId, "ArtifactId"), ...
                "disposition", opts.Disposition, "occurred_at", opts.OccurredAt);
            s = obj.pSet(s, "successor_artifact_id", ...
                obj.pCheckUuid(opts.SuccessorArtifactId, "SuccessorArtifactId"));
            s = obj.pSet(s, "note", opts.Note);
            s = obj.pSet(s, "attributes", opts.Attributes);
            s = obj.pSet(s, "recorded_by", obj.pCreatedBy(opts.RecordedBy));
            dispositionId = double(obj.pInsertReturning(obj.pT("artifact_disposition"), ...
                s, "disposition_id"));
        end

        function T = getArtifactDispositions(obj, opts)
            %GETARTIFACTDISPOSITIONS The file-disposition log, or each file's latest disposition.
            %   T = getArtifactDispositions(ArtifactId=aid)
            %       the rows recorded against this artifact row, newest first
            %   T = getArtifactDispositions(ArtifactId=aid, LatestPerFile=true)
            %       the latest disposition of its file, whichever row of the
            %       file it was recorded against (disposed_artifact_id), from
            %       lab.artifact_disposition_latest; no row: never disposed of
            %   Disposition= filters on "replaced", "moved", "deleted" or
            %   "restored". See ADDARTIFACTDISPOSITION.
            arguments
                obj (1,1) CarasLabDB
                opts.ArtifactId (1,1) string = string(missing)
                opts.Disposition (1,1) string = string(missing)
                opts.LatestPerFile (1,1) logical = false
            end
            obj.pCheckMember(opts.Disposition, ["replaced", "moved", "deleted", "restored"], ...
                "Disposition");
            f = struct();
            f = obj.pSet(f, "artifact_id", opts.ArtifactId);
            f = obj.pSet(f, "disposition", opts.Disposition);
            if opts.LatestPerFile
                T = obj.pSelectFrom(obj.pT("artifact_disposition_latest"), f, OrderBy="artifact_id");
            else
                T = obj.pSelectFrom(obj.pT("artifact_disposition"), f, OrderBy="disposition_id DESC");
            end
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
                opts.RelativePath (1,1) string = string(missing)   % exactly, '/' separated
                opts.Tags string = strings(1, 0)       % must carry all of these
                opts.AnyTags string = strings(1, 0)    % ... and at least one of these
                opts.NotTags string = strings(1, 0)    % ... and none of these
            end
            f = struct();
            f = obj.pSet(f, "session_id", opts.SessionId);
            f = obj.pSet(f, "subject_id", opts.SubjectId);
            f = obj.pSet(f, "label", opts.Label);
            f = obj.pSet(f, "storage_root_id", opts.StorageRootId);
            f = obj.pSet(f, "relative_path", opts.RelativePath);
            T = obj.pSelectFrom(obj.pT("session"), f, OrderBy="subject_id, label", ...
                Where=obj.pTagWhere("session", opts.Tags, opts.AnyTags, opts.NotTags));
        end

        function T = getEvents(obj, opts)
            %GETEVENTS Retrieve base event rows. Reads event_active unless ActiveOnly=false.
            %   Rows are ordered newest first (occurred_at DESC, event_id).
            %
            %   By default only active rows are returned: events that have
            %   been neither superseded nor retracted. ActiveOnly=false reads
            %   lab.event_version instead, i.e. every version of every event,
            %   with three more columns that say what became of each row:
            %   superseded_by (the event_id of its correction, or missing),
            %   is_retracted, and is_current (false once a row is superseded
            %   or retracted).
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
            tbl = obj.pT("event_version");
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
            %   or retracted event is reported as not found rather than
            %   returned as if it were current. (With ActiveOnly=false the
            %   row comes from lab.event as recorded; GETEVENTS says whether
            %   it is still current.)
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
            %   By default only active rows are returned (neither superseded
            %   nor retracted). ActiveOnly=false reads lab.artifact_version:
            %   every version of every artifact, plus the columns
            %   superseded_by, is_current and is_retracted (see GETEVENTS).
            %   Tags= / AnyTags= / NotTags= filter on current tags (see GETEVENTS):
            %       T = db.getArtifacts(SessionId=sid, Tags="stage:raw");
            %   Checksum= is matched as the database stores it: surrounding
            %   whitespace is dropped and the hex lower-cased, so the
            %   upper-case digest some tools print finds the file.
            %   StorageRootId= and RelativePath= find a file by where it is
            %   (RelativePath exactly, with '/' separators, as stored);
            %   PathPrefix= keeps the rows whose relative_path starts with
            %   that text (a folder: end it with '/').
            %   PresentOnly=true reads lab.artifact_present instead: active
            %   rows whose file has not been recorded as replaced, moved or
            %   deleted since (see ADDARTIFACTDISPOSITION) -- where a file is
            %   now. It needs ActiveOnly=true.
            arguments
                obj (1,1) CarasLabDB
                opts.ArtifactId (1,1) string = string(missing)
                opts.ProducedByEventId (1,1) string = string(missing)
                opts.SubjectId (1,1) string = string(missing)
                opts.SessionId (1,1) string = string(missing)
                opts.Role (1,1) string = string(missing)
                opts.Checksum (1,1) string = string(missing)
                opts.StorageRootId double {mustBeInteger, mustBeScalarOrEmpty} = []
                opts.RelativePath (1,1) string = string(missing)
                opts.PathPrefix (1,1) string = string(missing)
                opts.PresentOnly (1,1) logical = false
                opts.ActiveOnly (1,1) logical = obj.UseActiveViews
                opts.Limit (1,1) double {mustBeInteger, mustBeNonnegative} = 0
                opts.Tags string = strings(1, 0)       % must carry all of these
                opts.AnyTags string = strings(1, 0)    % ... and at least one of these
                opts.NotTags string = strings(1, 0)    % ... and none of these
            end
            tbl = obj.pT("artifact_version");
            if opts.ActiveOnly
                tbl = obj.pT("artifact_active");
            end
            if opts.PresentOnly
                if ~opts.ActiveOnly
                    error("CarasLabDB:invalidValue", ...
                        "PresentOnly=true needs ActiveOnly=true: only a current row's file can be present.");
                end
                tbl = obj.pT("artifact_present");
            end
            f = struct();
            f = obj.pSet(f, "artifact_id", opts.ArtifactId);
            f = obj.pSet(f, "produced_by_event_id", opts.ProducedByEventId);
            f = obj.pSet(f, "subject_id", opts.SubjectId);
            f = obj.pSet(f, "session_id", opts.SessionId);
            f = obj.pSet(f, "role", opts.Role);
            if obj.pIsProvided(opts.Checksum)
                % The column holds lower(btrim(checksum)) (trg_artifact_normalize).
                f.checksum = lower(strtrim(opts.Checksum));
            end
            f = obj.pSet(f, "storage_root_id", opts.StorageRootId);
            f = obj.pSet(f, "relative_path", opts.RelativePath);
            where = obj.pTagWhere("artifact", opts.Tags, opts.AnyTags, opts.NotTags);
            if obj.pIsProvided(opts.PathPrefix)
                where(end+1) = "starts_with(relative_path, " + obj.sqlLiteral(opts.PathPrefix) + ")";
            end
            T = obj.pSelectFrom(tbl, f, Limit=opts.Limit, OrderBy="created_at DESC, artifact_id", ...
                Where=where);
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
    % Variables -- user-defined named values. Setting, reading and defining
    % them live in their own files: setVariable, getVariables,
    % defineVariable.
    % ==================================================================
    methods
        function valueId = unsetVariable(obj, kind, entityId, name, opts)
            %UNSETVARIABLE Clear a variable on an event, artifact, subject, session or project.
            %   id = db.unsetVariable("session", sid, "probe depth")
            %   id = db.unsetVariable("session", sid, "probe depth", Note="measured on the wrong probe")
            %
            %   Appends an 'unset' row to the value log through
            %   lab.fn_unset_variable, after which the row has no current
            %   value for the variable; the earlier values stay in the log
            %   (GETVARIABLES with History=true). The database refuses to
            %   unset a variable the row has no current value for. To change
            %   a value, set it again with SETVARIABLE instead.
            %
            %   Name=Value: Note (free text on the log row), SetBy (person_id;
            %   default: the current person). Returns the value_id written.
            %
            %   See also SETVARIABLE, GETVARIABLES.
            arguments
                obj (1,1) CarasLabDB
                kind (1,1) string {mustBeMember(kind, ["event", "artifact", "subject", "session", "project"])}
                entityId (1,1) string
                name (1,1) string
                opts.Note (1,1) string = string(missing)
                opts.SetBy (1,1) string = string(missing)
            end
            name = CarasLabDB.normalizeVariableName(name);
            R = obj.pWrite("SELECT " + obj.pT("fn_unset_variable") + "(" + ...
                obj.sqlLiteral(kind) + ", " + obj.sqlLiteral(entityId) + ", " + ...
                obj.sqlLiteral(name) + ", " + obj.sqlLiteral(opts.Note) + ", " + ...
                obj.sqlLiteral(obj.pCreatedBy(opts.SetBy)) + "::uuid) AS value_id;");
            valueId = double(R.value_id(1));
        end

        function T = getVariableValues(obj, name, opts)
            %GETVARIABLEVALUES The current value of one variable on every row that has one.
            %   T = db.getVariableValues("probe depth")
            %   T = db.getVariableValues("probe depth", Kind="session")
            %
            %   Reads lab.variable_current. One row per event, artifact,
            %   subject, session or project that currently has a value for
            %   the variable, ordered by entity_kind, entity_id, with columns
            %   entity_kind, entity_id, value (the value as text, exact
            %   digits), value_num (the number; NaN for a text variable),
            %   value_text, units, set_at (when that value was set).
            %
            %   Kind= keeps one kind of row. ActiveOnly (default:
            %   UseActiveViews) leaves out superseded and retracted events
            %   and artifacts; a correction carries its predecessor's
            %   values, so without it a corrected row would be listed twice.
            %
            %   See also SETVARIABLE, GETVARIABLES, GETVARIABLEDEFINITIONS.
            arguments
                obj (1,1) CarasLabDB
                name (1,1) string
                opts.Kind (1,1) string = string(missing)
                opts.ActiveOnly (1,1) logical = obj.UseActiveViews
            end
            name = CarasLabDB.normalizeVariableName(name);
            obj.pCheckMember(opts.Kind, ...
                ["event", "artifact", "subject", "session", "project"], "Kind");
            clauses = "c.variable = " + obj.sqlLiteral(name);
            if obj.pIsProvided(opts.Kind)
                clauses(end+1) = "c.entity_kind = " + obj.sqlLiteral(opts.Kind);
            end
            if opts.ActiveOnly
                clauses(end+1) = "(c.entity_kind <> 'event' OR c.event_id IN " + ...
                    "(SELECT event_id FROM " + obj.pT("event_active") + "))";
                clauses(end+1) = "(c.entity_kind <> 'artifact' OR c.artifact_id IN " + ...
                    "(SELECT artifact_id FROM " + obj.pT("artifact_active") + "))";
            end
            T = obj.pSelect("SELECT c.entity_kind, c.entity_id, c.value, c.value_num, " + ...
                "c.value_text, c.units, c.set_at FROM " + obj.pT("variable_current") + ...
                " c WHERE " + strjoin(clauses, " AND ") + ...
                " ORDER BY c.entity_kind, c.entity_id;");
        end

        function T = getVariableDefinitions(obj, opts)
            %GETVARIABLEDEFINITIONS The defined variables: name, label, units, value type.
            %   T = db.getVariableDefinitions()
            %   T = db.getVariableDefinitions(IncludeRetired=true)
            %   T = db.getVariableDefinitions(Name="Probe Depth", IncludeRetired=true)
            %
            %   Reads lab.variable, ordered by name: name, label,
            %   description, units, value_type ('number' or 'text'),
            %   applies_to, retired_at, created_at, created_by. applies_to
            %   comes back as comma-separated text ("session,event"), as in
            %   GETTAGNAMESPACES. Retired variables (retired_at set) are left
            %   out unless IncludeRetired=true.
            %
            %   See also DEFINEVARIABLE, UPDATEVARIABLEDEFINITION, RETIREVARIABLE.
            arguments
                obj (1,1) CarasLabDB
                opts.Name (1,1) string = string(missing)
                opts.IncludeRetired (1,1) logical = false
            end
            f = struct();
            if obj.pIsProvided(opts.Name)
                f.name = CarasLabDB.normalizeVariableName(opts.Name);
            end
            extra = strings(1, 0);
            if ~opts.IncludeRetired
                extra = "retired_at IS NULL";
            end
            T = obj.pSelect("SELECT name, label, description, units, value_type, " + ...
                "array_to_string(applies_to, ',') AS applies_to, retired_at, " + ...
                "created_at, created_by FROM " + obj.pT("variable") + ...
                obj.pWhere(f, extra) + " ORDER BY name;");
        end

        function updateVariableDefinition(obj, name, opts)
            %UPDATEVARIABLEDEFINITION Edit a variable's label or description (row_history logs it).
            %   db.updateVariableDefinition("probe depth", Label="Probe Depth (tip)")
            %   db.updateVariableDefinition("probe depth", Description="Below the pia, in um")
            %
            %   Only the arguments you supply are changed. The name never
            %   changes, and the value type and units are fixed once the
            %   variable has a value: for other units, define another
            %   variable. A name that is not defined raises
            %   CarasLabDB:variableNotFound.
            %
            %   See also DEFINEVARIABLE, GETVARIABLEDEFINITIONS, RETIREVARIABLE.
            arguments
                obj (1,1) CarasLabDB
                name (1,1) string
                opts.Label (1,1) string = string(missing)
                opts.Description (1,1) string = string(missing)
            end
            name = CarasLabDB.normalizeVariableName(name);
            s = struct();
            s = obj.pSet(s, "label", opts.Label);
            s = obj.pSet(s, "description", opts.Description);
            n = obj.pUpdate(obj.pT("variable"), s, "name = " + obj.sqlLiteral(name), "name");
            if n == 0
                error("CarasLabDB:variableNotFound", "No variable named %s.", name);
            end
        end

        function retireVariable(obj, name, opts)
            %RETIREVARIABLE Retire a variable (no new values), or bring it back.
            %   db.retireVariable("probe depth")
            %   db.retireVariable("probe depth", Retired=false)
            %
            %   A variable is never renamed or deleted, because the value
            %   log refers to it by name: retire it and define the
            %   replacement. Rows keep the values they have, and a
            %   correction still carries them forward; SETVARIABLE refuses
            %   new ones. Retiring a variable that is already retired (or
            %   un-retiring a live one) changes nothing, so the original
            %   retired_at is kept.
            %
            %   See also DEFINEVARIABLE, GETVARIABLEDEFINITIONS.
            arguments
                obj (1,1) CarasLabDB
                name (1,1) string
                opts.Retired (1,1) logical = true
            end
            name = CarasLabDB.normalizeVariableName(name);
            where = "name = " + obj.sqlLiteral(name);
            R = obj.pSelect("SELECT (retired_at IS NOT NULL) AS is_retired FROM " + ...
                obj.pT("variable") + " WHERE " + where + ";");
            if height(R) == 0
                error("CarasLabDB:variableNotFound", "No variable named %s.", name);
            end
            if logical(R.is_retired(1)) == opts.Retired
                return   % already in the requested state
            end
            if opts.Retired
                s = struct("retired_at", datetime("now", "TimeZone", "local"));
            else
                s = struct("retired_at", NaT);    % sqlLiteral(NaT) -> NULL
            end
            obj.pUpdate(obj.pT("variable"), s, where, "name");
        end
    end

    % ==================================================================
    % Retraction and the integrity report
    % ==================================================================
    methods
        function retractionId = retractEvent(obj, eventId, reason, opts)
            %RETRACTEVENT Withdraw an event that should never have been recorded.
            %   id = db.retractEvent(eid, "entered twice")
            %
            %   A correction (SUPERSEDEEVENT) replaces a statement of fact
            %   with a better one; a retraction withdraws a row that should
            %   not exist at all. Writes one lab.retraction row through
            %   lab.fn_retract. The event and everything that refers to it
            %   stay in the database, but event_active -- and so GETEVENTS,
            %   GETEVENTDETAIL and the other readers by default -- stop
            %   returning it; GETEVENTS with ActiveOnly=false shows it with
            %   is_retracted true.
            %
            %   REASON is required and must not be blank
            %   (CarasLabDB:reasonRequired). Only the current version of an
            %   event can be retracted, and only once; a retraction is
            %   permanent (to bring the event back, supersede it). The files
            %   the event produced are NOT retracted with it: CHECKINTEGRITY
            %   reports them as artifact_producer_retracted until each is
            %   retracted too (RETRACTARTIFACT) or re-pointed.
            %
            %   Name=Value: RetractedBy (person_id; default: the current
            %   person). Returns the retraction_id.
            %
            %   See also RETRACTARTIFACT, GETRETRACTIONS, SUPERSEDEEVENT, CHECKINTEGRITY.
            arguments
                obj (1,1) CarasLabDB
                eventId (1,1) string
                reason (1,1) string
                opts.RetractedBy (1,1) string = string(missing)
            end
            retractionId = obj.pRetract("event", eventId, reason, opts.RetractedBy);
        end

        function retractionId = retractArtifact(obj, artifactId, reason, opts)
            %RETRACTARTIFACT Withdraw an artifact (file registration) made by mistake.
            %   id = db.retractArtifact(aid, "registered under the wrong path")
            %
            %   Like RETRACTEVENT, for lab.artifact: the row stays, and
            %   artifact_active -- so GETARTIFACTS by default -- stops
            %   returning it. REASON is required and must not be blank.
            %   Only the current version of an artifact can be retracted,
            %   and only once. Nothing on disk is touched.
            %
            %   Name=Value: RetractedBy (person_id; default: the current
            %   person). Returns the retraction_id.
            %
            %   See also RETRACTEVENT, GETRETRACTIONS, SUPERSEDEARTIFACT.
            arguments
                obj (1,1) CarasLabDB
                artifactId (1,1) string
                reason (1,1) string
                opts.RetractedBy (1,1) string = string(missing)
            end
            retractionId = obj.pRetract("artifact", artifactId, reason, opts.RetractedBy);
        end

        function T = getRetractions(obj, opts)
            %GETRETRACTIONS The retraction log: which events and artifacts were withdrawn, and why.
            %   T = db.getRetractions()
            %   T = db.getRetractions(Kind="event")
            %   T = db.getRetractions(EventId=eid)       % is this event retracted?
            %
            %   Reads lab.retraction, oldest first: retraction_id,
            %   entity_kind ('event' or 'artifact'), event_id, artifact_id
            %   (the one matching entity_kind is set), reason, retracted_at,
            %   retracted_by, retracted_login.
            %
            %   See also RETRACTEVENT, RETRACTARTIFACT.
            arguments
                obj (1,1) CarasLabDB
                opts.Kind (1,1) string = string(missing)
                opts.EventId (1,1) string = string(missing)
                opts.ArtifactId (1,1) string = string(missing)
            end
            obj.pCheckMember(opts.Kind, ["event", "artifact"], "Kind");
            f = struct();
            f = obj.pSet(f, "entity_kind", opts.Kind);
            f = obj.pSet(f, "event_id", opts.EventId);
            f = obj.pSet(f, "artifact_id", opts.ArtifactId);
            T = obj.pSelectFrom(obj.pT("retraction"), f, OrderBy="retraction_id");
        end

        function R = checkIntegrity(obj)
            %CHECKINTEGRITY The database's integrity report (lab.fn_check_integrity()).
            %   R = db.checkIntegrity()
            %
            %   One row per finding, errors first, then by check_name and
            %   subject: severity ('error' or 'warning'), check_name,
            %   subject (the id of the row concerned) and detail. No rows
            %   means nothing needs attention. Examples of checks: an event
            %   with no detail row, a file never verified or whose last
            %   check failed, a correction that did not carry its tags or
            %   inputs forward, a file whose producing event was retracted.
            %
            %       R = db.checkIntegrity();
            %       disp(R(R.severity == "error", :));
            %
            %   See also ADDARTIFACTVERIFICATION, RETRACTEVENT, SUPERSEDEEVENT.
            arguments
                obj (1,1) CarasLabDB
            end
            R = obj.pSelect("SELECT severity, check_name, subject, detail FROM " + ...
                obj.pT("fn_check_integrity") + "() " + ...
                "ORDER BY (severity = 'error') DESC, severity, check_name, subject;");
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
            %PSELECT A read: one SELECT, as a table. Never used for a statement that writes.
            %   The Database Toolbox learns a result's column types by first
            %   sending "SELECT * FROM (<sql>) as temp LIMIT 0". A trailing
            %   semicolon makes that probe a syntax error, which the server
            %   logs for every query; so it is removed here.
            T = fetch(obj.Connection, regexprep(sql, ";\s*$", ""));
        end

        function T = pWrite(obj, sql)
            %PWRITE One statement that writes and returns rows; always inside a transaction.
            %   INSERT / UPDATE ... RETURNING and SELECT lab.fn_...() are sent
            %   through here. Inside a transaction that has already executed
            %   a statement the driver does not send its LIMIT 0 probe (see
            %   PSELECT), so the statement reaches the server once, as
            %   written, and no failed probe is logged. Outside PTRANSACT
            %   this starts a transaction of its own.
            if strcmpi(string(obj.Connection.AutoCommit), "off")
                T = fetch(obj.Connection, sql);
            else
                T = obj.pTransact(@() fetch(obj.Connection, sql));
            end
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
            T = obj.pWrite(sql);
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
            n = height(obj.pWrite(sql));
        end

        function eventId = pInsertEvent(obj, base, detailTable, detail, opts)
            %PINSERTEVENT Insert the base event and its detail row in one transaction.
            %   The one write path of every event, new or correcting.
            %
            %   When BASE sets supersedes (supersedeEvent, or Supersedes= on an
            %   addXEvent method) the new event is a correction, and it takes
            %   over the superseded event's provenance in the same transaction
            %   (PCARRYPROVENANCE reads it, PINSERTEVENTROWS writes it):
            %     * its event_input edges are copied to the new event, unless
            %       CarryInputs=false (the caller re-declares them);
            %     * every active artifact it produced is superseded by a row
            %       produced by the new event and filed under the new event's
            %       subject and session;
            %     * its current tags, and each re-pointed artifact's, are
            %       copied onto the new rows (PCARRYTAGS).
            %   A correction can therefore never commit an event whose edges,
            %   files or tags are only half-carried over, whichever method
            %   made it.
            arguments
                obj (1,1) CarasLabDB
                base (1,1) struct
                detailTable (1,1) string
                detail (1,1) struct
                opts.CarryInputs (1,1) logical = true
            end
            inputs = {};
            artifacts = {};
            if isfield(base, "supersedes") && obj.pIsProvided(base.supersedes)
                [inputs, artifacts] = obj.pCarryProvenance(base.supersedes, opts.CarryInputs);
            end
            eventId = obj.pTransact(@() ...
                obj.pInsertEventRows(base, detailTable, detail, inputs, artifacts));
        end

        function [inputs, artifacts] = pCarryProvenance(obj, oldEventId, carryInputs)
            %PCARRYPROVENANCE What a correction of event OLDEVENTID takes over from it.
            %   INPUTS is a cell array of lab.event_input insert structs
            %   (artifact_id, role; event_id is set on insert), one per edge
            %   of the old event, or empty when CARRYINPUTS is false.
            %   ARTIFACTS is a cell array of lab.artifact insert structs, the
            %   successor of each active artifact the old event produced
            %   (PARTIFACTSUCCESSOR; produced_by_event_id, subject_id and
            %   session_id are set on insert). Rows are read as exact text
            %   (PROWSASTEXT), so nothing carried passes through a double.
            arguments
                obj (1,1) CarasLabDB
                oldEventId (1,1) string
                carryInputs (1,1) logical = true
            end
            litOld = obj.sqlLiteral(oldEventId);
            inputs = {};
            if carryInputs
                inputs = obj.pRowsAsText(obj.pT("event_input"), ...
                    "r.event_id = " + litOld, "artifact_id");
                for k = 1:numel(inputs)
                    inputs{k} = rmfield(inputs{k}, "event_id");
                end
            end
            artifacts = obj.pRowsAsText(obj.pT("artifact_active"), ...
                "r.produced_by_event_id = " + litOld, "artifact_id");
            for k = 1:numel(artifacts)
                artifacts{k} = obj.pArtifactSuccessor(artifacts{k});
            end
        end

        function eventId = pInsertEventRows(obj, base, detailTable, detail, inputs, artifacts)
            %PINSERTEVENTROWS The writes of PINSERTEVENT. Run only inside PTRANSACT.
            %   INPUTS and ARTIFACTS are PCARRYPROVENANCE's outputs (empty for
            %   an event that corrects nothing).
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
            if isempty(artifacts)
                return
            end
            % The files follow the corrected event. The new event's subject
            % and session are read back as stored, i.e. after
            % trg_event_fill_subject has derived the subject from the session,
            % and each re-pointed file is filed under them; where the event
            % names none the file keeps its own. A correction that moves an
            % event to another animal or session thus moves its files too
            % (trg_artifact_matches_event rejects leaving them behind).
            stored = obj.pRowsAsText(obj.pT("event"), ...
                "r.event_id = " + obj.sqlLiteral(eventId), "event_id");
            for k = 1:numel(artifacts)
                a = artifacts{k};
                a.produced_by_event_id = eventId;
                if ~isempty(stored)
                    a = CarasLabDB.pFollowEvent(a, stored{1});
                end
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

        function out = pRecordEventRows(obj, eventType, base, detail, digest, attrs, ...
                inputs, outputs, replaces, skipMissing)
            %PRECORDEVENTROWS The writes of RECORDEVENT. Run only inside PTRANSACT.
            %   BASE is the lab.event insert struct with event_id set; ATTRS
            %   its attributes with client_digest added; INPUTS and OUTPUTS
            %   cell arrays of checked event_input / artifact insert structs;
            %   REPLACES the artifact_id each output overwrote ("" for none).
            eventId = base.event_id;
            litId = obj.sqlLiteral(eventId) + "::uuid";
            nOut = numel(outputs);
            out = struct("EventId", eventId, "Outcome", "inserted", ...
                "OutputIds", strings(nOut, 1), "Unchanged", false(nOut, 1), ...
                "SkippedInputs", strings(0, 1), "SkippedReplaces", strings(0, 1));

            % 1. This record sent before, or another record under this id.
            E = obj.pSelect("SELECT coalesce(attributes->>'client_digest', '') AS client_digest, " + ...
                "coalesce(attributes->'unchanged_outputs', '[]'::jsonb)::text AS unchanged_outputs " + ...
                "FROM " + obj.pT("event") + " WHERE event_id = " + litId + ";");
            if height(E) > 0
                stored = CarasLabDB.pColText(E.client_digest(1));
                if stored ~= digest
                    error("CarasLabDB:idConflict", ...
                        "Event %s is in the database already as a different record " + ...
                        "(digest '%s', not %s). Nothing was written.", eventId, stored, digest);
                end
                out.Outcome = "existing";
                listed = string(jsondecode(char(CarasLabDB.pColText(E.unchanged_outputs(1)))));
                for k = 1:nOut
                    out.OutputIds(k) = obj.pCurrentFileRow(outputs{k});
                    out.Unchanged(k) = ismember(out.OutputIds(k), listed);
                end
                return
            end

            % 2. Output files registered already with these bytes at this path.
            for k = 1:nOut
                id = obj.pCurrentFileRow(outputs{k});
                if id ~= ""
                    out.OutputIds(k) = id;
                    out.Unchanged(k) = true;
                end
            end
            if any(out.Unchanged)
                attrs = CarasLabDB.pAddJsonMember(attrs, "unchanged_outputs", ...
                    out.OutputIds(out.Unchanged), true);
            end
            base.attributes = attrs;

            % 3. The event and its detail row.
            obj.pInsertEventRows(base, obj.pT(obj.pDetailTable(eventType)), detail, {}, {});

            % 4. Its input edges.
            if skipMissing && ~isempty(inputs)
                ids = strings(1, numel(inputs));
                for k = 1:numel(inputs)
                    ids(k) = obj.sqlLiteral(inputs{k}.artifact_id) + "::uuid";
                end
                R = obj.pSelect("SELECT artifact_id::text AS artifact_id FROM " + ...
                    obj.pT("artifact") + " WHERE artifact_id IN (" + strjoin(ids, ", ") + ");");
                present = strings(0, 1);
                if height(R) > 0
                    present = CarasLabDB.pColText(R.artifact_id);
                end
                keep = false(1, numel(inputs));
                for k = 1:numel(inputs)
                    keep(k) = ismember(inputs{k}.artifact_id, present);
                    if ~keep(k)
                        out.SkippedInputs(end+1, 1) = inputs{k}.artifact_id;
                    end
                end
                inputs = inputs(keep);
            end
            for k = 1:numel(inputs)
                edge = inputs{k};
                edge.event_id = eventId;
                obj.pInsert(obj.pT("event_input"), edge);
            end

            % 5. The new output files. One that names no subject or session
            % takes the event's as stored (after trg_event_fill_subject); one
            % that names others is left for trg_artifact_matches_event to
            % refuse -- it is never re-filed here.
            recordedBy = string(missing);
            if isfield(base, "recorded_by")
                recordedBy = base.recorded_by;
            end
            if any(~out.Unchanged)
                stored = obj.pRowsAsText(obj.pT("event"), "r.event_id = " + litId, "event_id");
            end
            for k = find(~out.Unchanged).'
                a = outputs{k};
                a.produced_by_event_id = eventId;
                for col = ["subject_id", "session_id"]
                    c = char(col);
                    if ~isempty(stored) && ~isfield(a, c) && isfield(stored{1}, c) ...
                            && CarasLabDB.pIsProvided(stored{1}.(c))
                        a.(c) = stored{1}.(c);
                    end
                end
                a = obj.pSet(a, "created_by", obj.pCreatedBy(recordedBy));
                out.OutputIds(k) = obj.pInsertArtifact(a);
            end

            % 6. What became of the files the outputs took the place of, as
            % of when the run finished.
            doneAt = base.occurred_at;
            if isfield(detail, "finished_at") && isdatetime(detail.finished_at)
                doneAt = detail.finished_at;
            end
            by = obj.pCreatedBy(recordedBy);
            for k = find(out.Unchanged).'
                % The same bytes written again: if the file had been recorded
                % as gone, it is back.
                L = obj.pSelect("SELECT disposition FROM " + obj.pT("artifact_disposition_latest") + ...
                    " WHERE artifact_id = " + obj.sqlLiteral(out.OutputIds(k)) + "::uuid;");
                if height(L) > 0 && CarasLabDB.pColText(L.disposition(1)) ~= "restored"
                    d = struct("artifact_id", out.OutputIds(k), "disposition", "restored", ...
                        "occurred_at", doneAt);
                    obj.pInsert(obj.pT("artifact_disposition"), obj.pSet(d, "recorded_by", by));
                end
            end
            for k = 1:nOut
                r = replaces(k);
                if ismissing(r) || r == "" || r == out.OutputIds(k)
                    continue
                end
                if skipMissing
                    R = obj.pSelect("SELECT artifact_id::text AS artifact_id FROM " + ...
                        obj.pT("artifact") + " WHERE artifact_id = " + obj.sqlLiteral(r) + "::uuid;");
                    if height(R) == 0
                        out.SkippedReplaces(end+1, 1) = r;
                        continue
                    end
                end
                d = struct("artifact_id", r, "disposition", "replaced", ...
                    "successor_artifact_id", out.OutputIds(k), "occurred_at", doneAt);
                obj.pInsert(obj.pT("artifact_disposition"), obj.pSet(d, "recorded_by", by));
            end
        end

        function id = pCurrentFileRow(obj, a)
            %PCURRENTFILEROW The current row of the file A describes, or "" if none.
            %   A is an artifact insert struct (storage_root_id, relative_path,
            %   checksum as stored). uq_artifact_file_original allows one
            %   original row per (root, path, checksum); its current version
            %   (lab.fn_artifact_current) is the row that describes the file now.
            R = obj.pSelect("SELECT " + obj.pT("fn_artifact_current") + ...
                "(a.artifact_id)::text AS current_id FROM " + obj.pT("artifact") + " a " + ...
                "WHERE a.supersedes IS NULL AND a.storage_root_id = " + ...
                obj.sqlLiteral(a.storage_root_id) + " AND a.relative_path = " + ...
                obj.sqlLiteral(a.relative_path) + " AND a.checksum = " + ...
                obj.sqlLiteral(a.checksum) + ";");
            id = "";
            if height(R) > 0
                id = CarasLabDB.pColText(R.current_id(1));
            end
        end

        function ids = pInsertEventBatch(obj, bases, detailTable, details)
            %PINSERTEVENTBATCH Insert several new events, base + detail each. Run only inside PTRANSACT.
            %   BASES and DETAILS are parallel cell arrays of insert structs
            %   for lab.event and DETAILTABLE (none of them a correction).
            %   Returns the new event ids as a string column, in order.
            ids = strings(numel(bases), 1);
            for k = 1:numel(bases)
                ids(k) = obj.pInsertEventRows(bases{k}, detailTable, details{k}, {}, {});
            end
        end

        function id = pRetract(obj, kind, entityId, reason, by)
            %PRETRACT lab.fn_retract(KIND, id, reason, by); returns the retraction_id.
            %   KIND is 'event' or 'artifact', supplied by RETRACTEVENT /
            %   RETRACTARTIFACT. A missing or blank REASON is refused here,
            %   before the database's CHECK would refuse it less helpfully.
            if ismissing(reason) || strlength(strip(reason)) == 0
                error("CarasLabDB:reasonRequired", ...
                    "A reason is required to retract an %s: say why the row is withdrawn.", kind);
            end
            R = obj.pWrite("SELECT " + obj.pT("fn_retract") + "(" + ...
                obj.sqlLiteral(kind) + ", " + obj.sqlLiteral(entityId) + "::uuid, " + ...
                obj.sqlLiteral(reason) + ", " + ...
                obj.sqlLiteral(obj.pCreatedBy(by)) + "::uuid) AS retraction_id;");
            id = double(R.retraction_id(1));
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
            %   none of them can commit half its rows; so does every single
            %   statement that writes and returns rows (PWRITE).
            %
            %   The transaction is marked when it starts and the mark is
            %   checked before COMMIT. When a statement fails, the Database
            %   Toolbox rolls the transaction back by itself and starts
            %   another, unannounced, for whatever is sent next. Code that
            %   carried on after such a failure would otherwise commit the
            %   second half of its work without the first; with the check the
            %   commit is refused (CarasLabDB:transactionInterrupted) and
            %   nothing is written. Do not catch a database error inside FN
            %   and continue.
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
            [~, marker] = fileparts(tempname);
            marker = "tx_" + string(marker);
            try
                % The transaction's first statement. SET LOCAL lasts exactly
                % as long as the transaction it is issued in. It is sent with
                % execute, after which the driver no longer precedes a fetch
                % with its LIMIT 0 probe (see PSELECT).
                execute(conn, "SET LOCAL caraslabdb.txn = " + obj.sqlLiteral(marker) + ";");
                out = fn();
                M = fetch(conn, "SELECT current_setting('caraslabdb.txn', true) AS marker");
                if height(M) ~= 1 || ~isequal(CarasLabDB.pColText(M.marker(1)), marker)
                    error("CarasLabDB:transactionInterrupted", ...
                        "The transaction was rolled back part-way (a statement in it " + ...
                        "failed), so it was not committed and nothing was written. " + ...
                        "Correct the cause and repeat the whole operation.");
                end
                commit(conn);
            catch ME
                % After a failed statement the driver has already rolled
                % back, and it opens the next transaction only when another
                % statement is sent; a ROLLBACK now would draw "there is no
                % transaction in progress" from the server. The SELECT makes
                % sure there is one to roll back.
                try
                    execute(conn, "SELECT 1;");
                catch
                end
                % A failing rollback (dead connection) must not replace the
                % constraint violation the caller actually needs to see.
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
            obj.pCheckTagFilter(kind, allTags, anyTags, noneTags);
            w = obj.pT("fn_tag_match") + "(" + obj.sqlLiteral(kind) + ", " + ...
                pk + "::text, " + strjoin(arrs, ", ") + ")";
        end

        function pCheckTagFilter(obj, kind, allTags, anyTags, noneTags)
            %PCHECKTAGFILTER Refuse a tag filter that cannot mean what it says.
            %   lab.fn_tag_match treats an unknown token as "nothing carries
            %   it", so a typo is silent: NotTags="qc:fial" excludes nothing
            %   and returns the failed recordings. One call of
            %   lab.fn_tag_filter_problems per query reports a namespace that
            %   does not exist, one whose tags cannot be put on KIND, and a
            %   tag that is not registered; any row raises
            %   CarasLabDB:tagFilterProblem naming each token and what is
            %   wrong with it. Tokens are validated and canonicalised first
            %   (PTAGTOKENS), so a malformed one fails before any SQL is sent.
            tokens = unique([CarasLabDB.pTagTokens(allTags), ...
                             CarasLabDB.pTagTokens(anyTags), ...
                             CarasLabDB.pTagTokens(noneTags)], "stable");
            if isempty(tokens)
                return
            end
            R = obj.pSelect("SELECT token, problem FROM " + ...
                obj.pT("fn_tag_filter_problems") + "(" + obj.sqlLiteral(kind) + ", " + ...
                CarasLabDB.pTagArrayLiteral(tokens) + ");");
            if height(R) == 0
                return
            end
            found = reshape(CarasLabDB.pColText(R.token) + ": " + ...
                CarasLabDB.pColText(R.problem), 1, []);
            error("CarasLabDB:tagFilterProblem", ...
                "The tag filter cannot match %s rows as written:\n  %s\n" + ...
                "Correct the tag, or see getTags / getTagNamespaces for the vocabulary.", ...
                kind, strjoin(found, newline + "  "));
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
            R = obj.pWrite("SELECT " + obj.pT("fn_tag") + "(" + ...
                obj.sqlLiteral(kind) + ", " + obj.sqlLiteral(entityId) + ", " + ...
                obj.sqlLiteral(tag) + ", " + obj.sqlLiteral(op) + ", " + ...
                obj.sqlLiteral(note) + ", " + obj.sqlLiteral(by) + "::uuid) AS assignment_id;");
            id = double(R.assignment_id(1));
        end

        function base = pEventBase(obj, eventType, opts)
            %PEVENTBASE Assemble the lab.event insert struct shared by all event types.
            %   opts is the name-value struct of an addXEvent method; it must expose
            %   the common base fields (OccurredAt, SubjectId, SessionId, Notes,
            %   Attributes, RecordedBy, RecordedAt, Supersedes) and may expose
            %   EventId (a caller-minted uuid).
            base = struct("event_type", string(eventType));
            if isfield(opts, "EventId")
                base = obj.pSet(base, "event_id", CarasLabDB.pCheckUuid(opts.EventId, "EventId"));
            end
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
            %   When none of the three is given, the person is the one the
            %   database login is mapped to (PLOGINPERSON), or missing when
            %   it is mapped to nobody. An id, email or name that matches no
            %   lab.person row raises CarasLabDB:personNotFound; a name
            %   shared by several people raises CarasLabDB:personAmbiguous
            %   rather than attributing every later row to whichever of them
            %   the database returns first.
            if obj.pIsProvided(personId)
                % Checked now: a person_id that names no one would otherwise
                % surface only as a foreign-key error on the first insert.
                % The id is returned as the database spells it (lower case),
                % so it compares equal to the ids read back from other rows.
                T = obj.pSelect("SELECT person_id FROM " + obj.pT("person") + ...
                    " WHERE person_id = " + obj.sqlLiteral(personId) + ";");
                if height(T) == 0
                    error("CarasLabDB:personNotFound", "No person with id %s.", personId);
                end
                pid = string(T.person_id(1));
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
                pid = obj.pLoginPerson();
                return
            end
            % LIMIT 2 is enough to tell one match from several. Emails are
            % unique (uq_person_email_lower); full names are not.
            T = obj.pSelect("SELECT person_id FROM " + obj.pT("person") + ...
                " WHERE " + where + " ORDER BY person_id LIMIT 2;");
            if height(T) == 0
                error("CarasLabDB:personNotFound", "No person matches the supplied identity.");
            end
            if height(T) > 1
                error("CarasLabDB:personAmbiguous", ...
                    "More than one person matches the supplied identity. " + ...
                    "Use PersonEmail= or PersonId=, which are unique.");
            end
            pid = string(T.person_id(1));
        end

        function pid = pLoginPerson(obj)
            %PLOGINPERSON The person_id the connected database login is mapped to, or missing.
            %   SELECT lab.fn_current_person(): the lab.person row whose
            %   db_login is this session's login (an administrator sets
            %   db_login when a member is onboarded). Missing when the login
            %   is mapped to nobody, and on a database of unknown version (a
            %   pre-launch prototype with no lab.schema_version), which may
            %   have no such function -- asking would raise, and on an
            %   injected connection could abort the caller's transaction.
            pid = string(missing);
            if ~(obj.SchemaVersion >= 1)
                return
            end
            T = obj.pSelect("SELECT " + obj.pT("fn_current_person") + "()::text AS person_id;");
            if height(T) == 0
                return
            end
            found = CarasLabDB.pColText(T.person_id);
            if ~ismissing(found(1)) && strlength(found(1)) > 0
                pid = found(1);
            end
        end

        function pWarnNoPerson(obj)
            %PWARNNOPERSON Warn when inserts will carry no person (CurrentPersonId missing).
            if ismissing(obj.CurrentPersonId)
                warning("CarasLabDB:noCurrentPerson", ...
                    "No current person: no PersonEmail=, PersonId= or PersonName= was given " + ...
                    "and this database login is not mapped to a lab person " + ...
                    "(lab.person.db_login). Rows will be written with a NULL recorded_by / " + ...
                    "created_by; the database still records the login. Name a person, call " + ...
                    "setPerson, or ask the database administrator to map the login.");
            end
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

        function pInitSession(obj, allowMismatch)
            %PINITSESSION Align the session time zone and read the schema version.
            %   A schema version other than SchemaVersionExpected raises
            %   CarasLabDB:schemaVersionMismatch: an error, or with
            %   ALLOWMISMATCH true a warning.
            %
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

            % The first pre-launch schema had no schema_version table. Probe
            % for it rather than letting the SELECT fail, which would abort the
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
                    found = "unknown (no schema_version table: a pre-launch prototype)";
                else
                    found = string(obj.SchemaVersion);
                end
                msg = sprintf("Database schema version is %s; this CarasLabDB class is " + ...
                    "written for version %d. Upgrade the database with the " + ...
                    "scripts in design_docs/migrations/, or use a matching client.", ...
                    found, CarasLabDB.SchemaVersionExpected);
                if allowMismatch
                    warning("CarasLabDB:schemaVersionMismatch", "%s", msg);
                else
                    % The table and column names of the expected version are
                    % hard-coded throughout this class, so against any other
                    % version a write can fail half-way or land in the wrong
                    % column. Refusing is the safe default.
                    error("CarasLabDB:schemaVersionMismatch", ...
                        "%s (Pass AllowSchemaMismatch=true to connect anyway.)", msg);
                end
            end
        end

        function pSetTimeouts(obj, statementSeconds, lockSeconds)
            %PSETTIMEOUTS Apply StatementTimeout= / LockTimeout= to the session (seconds).
            %   Empty leaves the server's setting; 0 means no limit. Sent in
            %   whole milliseconds, PostgreSQL's unit for both settings.
            if ~isempty(statementSeconds)
                obj.pExec("SET statement_timeout = " + ...
                    sprintf("%d", round(1000 * statementSeconds)) + ";");
            end
            if ~isempty(lockSeconds)
                obj.pExec("SET lock_timeout = " + ...
                    sprintf("%d", round(1000 * lockSeconds)) + ";");
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
            %   carried forward except the regenerated ones (created_login is
            %   stamped by the database); supersedes points at ROW and
            %   created_by is the current person.
            s = rmfield(row, intersect(fieldnames(row), ...
                {'artifact_id', 'created_at', 'created_by', 'created_login', 'supersedes'}));
            s.supersedes = row.artifact_id;
            s = obj.pSet(s, "created_by", obj.pCreatedBy(string(missing)));
        end
    end

    methods (Static, Access = private)
        function id = pCheckUuid(id, name)
            %PCHECKUUID A caller-minted id, checked to be a uuid and lower-cased.
            %   A missing ID is returned as it is (the database then generates
            %   one); anything else that is not 8-4-4-4-12 hex digits raises
            %   CarasLabDB:invalidValue naming the argument NAME.
            if ~CarasLabDB.pIsProvided(id)
                return
            end
            if isempty(regexp(char(id), ['^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-' ...
                    '[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'], 'once'))
                error("CarasLabDB:invalidValue", ...
                    "%s must be a uuid (8-4-4-4-12 hexadecimal digits), not '%s'.", name, id);
            end
            id = lower(id);
        end

        function attrs = pAddJsonMember(attrs, name, value, asArray)
            %PADDJSONMEMBER A jsonb object value with member NAME = VALUE added.
            %   ATTRS is [] (none yet), a scalar struct or a CarasLabDBJson
            %   object. A struct gains a field (sent through jsonencode);
            %   JSON text is edited, the rest kept as written
            %   (CarasLabDBJson.withMember). VALUE is a string, or with
            %   ASARRAY a string array sent as a JSON array. A member that is
            %   there already is an error: only the caller of this sets it.
            if isempty(attrs)
                attrs = struct();
            end
            if isstruct(attrs)
                if ~isscalar(attrs)
                    error("CarasLabDB:invalidValue", "Attributes must be one JSON object.");
                end
                if isfield(attrs, name)
                    error("CarasLabDB:invalidValue", ...
                        "Attributes cannot set %s: recordEvent sets it.", name);
                end
                if asArray
                    attrs.(char(name)) = cellstr(reshape(value, 1, []));
                else
                    attrs.(char(name)) = value;
                end
            elseif isa(attrs, "CarasLabDBJson")
                attrs = attrs.withMember(name, value, Array=asArray);
            else
                error("CarasLabDB:invalidValue", ...
                    "Attributes must be a struct or CarasLabDB.jsonText(...), not a %s.", ...
                    class(attrs));
            end
        end

        function restore = pSetEnvFor(name, value)
            %PSETENVFOR Set environment variable NAME to VALUE until RESTORE is cleared.
            %   A variable that was not set is removed again afterwards, not
            %   set to "": libpq reads an empty PGCONNECT_TIMEOUT as an invalid
            %   integer and refuses to connect.
            wasSet = isenv(name);
            old = string(getenv(name));
            setenv(name, value);
            restore = onCleanup(@() CarasLabDB.pRestoreEnv(name, wasSet, old));
        end

        function pRestoreEnv(name, wasSet, old)
            %PRESTOREENV Put environment variable NAME back as PSETENVFOR found it.
            if wasSet
                setenv(name, old);
            else
                unsetenv(name);
            end
        end

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
            elseif isa(v, "missing")
                tf = false;     % the missing object itself, as string(missing)
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
            tokens = CarasLabDB.pTagTokens(tokens);
            if isempty(tokens)
                lit = "NULL::text[]";
                return
            end
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

        function tokens = pTagTokens(tokens)
            %PTAGTOKENS Tag-filter tokens as a validated, canonical 1-by-n string array.
            %   Missing and blank elements are dropped; the rest go through
            %   normalizeTag(AllowWildcard=true), which raises
            %   CarasLabDB:invalidTag for a malformed one. Applying it to its
            %   own output changes nothing.
            tokens = reshape(string(tokens), 1, []);
            tokens = tokens(~ismissing(tokens));
            tokens = tokens(strlength(strip(tokens, "both", " ")) > 0);
            if ~isempty(tokens)
                tokens = CarasLabDB.normalizeTag(tokens, AllowWildcard=true);
            end
        end

        function arg = pVariableValueArg(name, value)
            %PVARIABLEVALUEARG The value argument of lab.fn_set_variable for VALUE.
            %   "p_number => <literal>" for a finite real numeric scalar,
            %   "p_text => '<literal>'" for a non-blank string scalar or
            %   char row. Anything else raises CarasLabDB:invalidVariableValue;
            %   NAME only labels the message. The number is formatted by
            %   sqlLiteral (shortest decimal that reads back as the same
            %   double), so the numeric column stores the digits typed.
            if isnumeric(value) && isscalar(value)
                v = double(value);
                if ~isreal(v) || ~isfinite(v)
                    error("CarasLabDB:invalidVariableValue", ...
                        "Variable '%s' needs a finite real number; NaN, Inf and complex " + ...
                        "values are not stored. Use unsetVariable to clear a value.", name);
                end
                arg = "p_number => " + CarasLabDB.sqlLiteral(v);
            elseif (isstring(value) && isscalar(value)) || ...
                    (ischar(value) && (isrow(value) || isempty(value)))
                t = string(value);
                if ismissing(t) || strlength(strip(t)) == 0
                    error("CarasLabDB:invalidVariableValue", ...
                        "Variable '%s' needs a non-blank string. Use unsetVariable " + ...
                        "to clear a value.", name);
                end
                arg = "p_text => " + CarasLabDB.sqlLiteral(t);
            else
                error("CarasLabDB:invalidVariableValue", ...
                    "Variable '%s' takes one number or one string, not a %s of size %s.", ...
                    name, class(value), mat2str(size(value)));
            end
        end

        function a = pFollowEvent(a, ev)
            %PFOLLOWEVENT File artifact insert struct A under event EV's subject and session.
            %   EV is a pRowsAsText struct of the producing lab.event row.
            %   Where it names a subject or a session, A takes it; where it
            %   does not (NULL), A keeps its own value.
            for col = ["subject_id", "session_id"]
                c = char(col);
                if isfield(ev, c) && CarasLabDB.pIsProvided(ev.(c))
                    a.(c) = ev.(c);
                end
            end
        end

        function s = pApplyClear(s, cols, clearable)
            %PAPPLYCLEAR Add "column = NULL" to update struct S for each column in COLS.
            %   COLS holds database column names and must be a subset of
            %   CLEARABLE, the fixed list of nullable columns the calling
            %   update method edits -- so a caller's text can only select one
            %   of those identifiers, never become one. A column that S
            %   already sets raises CarasLabDB:clearAndSet.
            cols = unique(reshape(string(cols), 1, []), "stable");
            if isempty(cols)
                return
            end
            if any(ismissing(cols)) || ~all(ismember(cols, clearable))
                error("CarasLabDB:invalidValue", ...
                    "Clear must name columns from: %s.", strjoin(clearable, ", "));
            end
            both = cols(ismember(cols, reshape(string(fieldnames(s)), 1, [])));
            if ~isempty(both)
                error("CarasLabDB:clearAndSet", ...
                    "A column cannot be both cleared and set: %s.", strjoin(both, ", "));
            end
            for i = 1:numel(cols)
                s.(char(cols(i))) = string(missing);    % sqlLiteral -> NULL
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
            %   Handles NULLs (string(missing), the missing object, NaN, NaT,
            %   []), text (quotes doubled),
            %   numbers, logicals, datetime (timestamptz), and jsonb (struct /
            %   containers.Map / dictionary via jsonencode, or JSON text as
            %   written: CarasLabDB.jsonText).
            if isempty(v)
                out = "NULL";
                return
            end
            if isa(v, "CarasLabDBJson")
                out = CarasLabDB.pQuoteText(v.Text) + "::jsonb";
                return
            end
            if isstring(v) && isscalar(v) && ismissing(v)
                out = "NULL";
                return
            end
            if isa(v, "missing")
                % The missing object itself, e.g. struct("notes", missing) in
                % a supersede override: NULL, like string(missing).
                if ~isscalar(v)
                    error("CarasLabDB:scalarExpected", "missing SQL values must be scalar.");
                end
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

        function j = jsonText(text)
            %JSONTEXT JSON text for a jsonb value, sent as written (not re-encoded).
            %   j = CarasLabDB.jsonText('{"Th": [9, 3], "fs": 30000.0}')
            %   Pass the result where a jsonb value is taken (Parameters=,
            %   Attributes=, recordEvent's Detail and Outputs, ...). Unlike a
            %   struct, which goes through jsonencode, the text reaches
            %   PostgreSQL unchanged, so a value read from a JSON file keeps
            %   its numbers' digits rather than passing through a MATLAB
            %   double. (jsonb itself drops insignificant white space, orders
            %   an object's keys and keeps the last of duplicate keys.) The
            %   text must parse as JSON (CarasLabDB:invalidJson).
            %   See also CARASLABDBJSON.
            j = CarasLabDBJson(text);
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

        function names = normalizeVariableName(names)
            %NORMALIZEVARIABLENAME Canonical spelling of one or more variable names, validated locally.
            %   n = CarasLabDB.normalizeVariableName(" Probe   Depth ")   % -> "probe depth"
            %   n = CarasLabDB.normalizeVariableName(["Housing", "ISI_ms"])
            %
            %   Mirrors lab.fn_canonical_variable: lower case, every run of
            %   whitespace reduced to one space, and the spaces at either
            %   end removed, so "Probe  Depth " and "probe depth" are one
            %   variable everywhere. Nothing else is rewritten: a name that
            %   then is not words of a-z, 0-9, _ and - separated by single
            %   spaces and starting with a letter
            %   (^[a-z][a-z0-9_-]*( [a-z0-9_-]+)*$), or is longer than 63
            %   characters, raises CarasLabDB:invalidVariableName here,
            %   before the database would reject it.
            arguments
                names string
            end
            for i = 1:numel(names)
                raw = names(i);
                if ismissing(raw)
                    error("CarasLabDB:invalidVariableName", ...
                        "A variable name is required (got <missing>).");
                end
                n = strip(regexprep(lower(raw), '\s+', ' '), "both", " ");
                if strlength(n) > 63 || ...
                        isempty(regexp(char(n), '^[a-z][a-z0-9_-]*( [a-z0-9_-]+)*$', 'once'))
                    error("CarasLabDB:invalidVariableName", ...
                        "Invalid variable name '%s': use words of a-z, 0-9, _ and -, " + ...
                        "separated by single spaces and starting with a letter, at most " + ...
                        "63 characters (for example 'probe depth').", raw);
                end
                names(i) = n;
            end
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
