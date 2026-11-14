%% CarasLabDB — integration examples
% A set of independent, copy-pasteable recipes for wiring CarasLabDB into an
% analysis pipeline, acquisition script, or app. Each section below stands on
% its own (re-declares the IDs it needs) so you can run just the one section
% you care about, rather than the whole file top to bottom.
%
% This complements examples/carasLabDB_demo.m, which is a single linear
% walkthrough of the whole schema. This file is organized by *task* ("how do
% I connect", "how do I pull X", "how do I add Y") for people integrating
% CarasLabDB into their own code.
%
% Open this file in MATLAB — it opens directly in the Live Editor. Use
% File > Save As > Live Script (.mlx) if you want the binary Live Script
% format instead of this plain .m.
%
% Requires MATLAB R2024b+, Database Toolbox, and a reachable Postgres
% instance with design_docs/schema.sql applied.
addpath("C:\src\CarasLabDB");

%% 1. Connecting
% Never hardcode credentials in a checked-in script. Pull them from
% environment variables (or a local config file that is gitignored) instead.
db = CarasLabDB( ...
    Username     = getenv("CARASLABDB_USER"), ...
    Password     = getenv("CARASLABDB_PASSWORD"), ...
    Server       = "nas-main.lab", ...
    Port         = 5432, ...
    DatabaseName = "lab", ...
    PersonEmail  = "dstolz@umd.edu");   % resolves CurrentPersonId for created_by/recorded_by

assert(db.isOpen(), "CarasLabDB failed to connect.");

% With a database login of your own that the administrator has mapped to
% you (lab.person.db_login), leave PersonEmail out: the current person is
% then the login's (lab.fn_current_person()). Only a login mapped to nobody
% warns CarasLabDB:noCurrentPerson.

%% 1a. Reusing an existing connection
% If your pipeline already opens its own Database Toolbox connection (e.g. a
% shared connection pool in a larger app), inject it instead of letting
% CarasLabDB open a second one. CarasLabDB will not close a connection it
% didn't open.
%
%   conn = postgresql(user, pass, Server="nas-main.lab", DatabaseName="lab");
%   db2  = CarasLabDB(Connection=conn, PersonEmail="dstolz@umd.edu");

%% 1b. Switching the "current person" mid-session
% Useful for a shared kiosk/rig script that multiple lab members run.
% db.setPerson(PersonEmail="another.person@umd.edu");

%% 1c. Reading full history instead of just the latest (active) rows
% By default get* methods read the *_active views (superseded and retracted
% rows hidden). Flip this globally, or per call with ActiveOnly=false;
% getEvents / getArtifacts then return every version of every row with the
% columns superseded_by, is_current and is_retracted.
% db.UseActiveViews = false;              % global
% db.getEvents(SubjectId="G-0421", ActiveOnly=false);   % per-call override

%% 2. Pulling specific data
% getSubjects/getSessions/getEvents/getArtifacts all take Name=Value filters;
% omit an argument to leave it unconstrained. Every filter is ANDed.

% 2a. A single subject by its natural key
subj = db.getSubjects(SubjectId="G-0421");

% 2b. All subjects in a project
proj = db.getProjects(Name="Gerbil AC plasticity");
if height(proj) > 0
    subjectsInProject = db.getSubjects(ProjectId=proj.project_id(1));
end

% 2c. All events for a subject, active (non-superseded) rows only (default).
% Results are ordered newest first, so row 1 is the most recent event.
events = db.getEvents(SubjectId="G-0421");

% 2d. Just the recording events for a subject
recordingEvents = db.getEvents(SubjectId="G-0421", EventType="recording");

% 2e. The type-specific detail row joined onto the base event row
% (getEvents only returns lab.event columns; getEventDetail adds e.g.
% sample_rate_hz, n_channels for a recording, or pipeline_name for analysis.)
if height(events) > 0
    detail = db.getEventDetail(EventId=events.event_id(1));
end

% 2f. Artifacts produced within one session
sess = db.getSessions(SubjectId="G-0421", Label="2026-07-02_pen1");
if height(sess) > 0
    artifacts = db.getArtifacts(SessionId=sess.session_id(1));
end

% 2g. Full upstream provenance of a derived file (walks event_input edges).
% The ids returned are the current versions of each node: corrections made
% since are followed. FollowCorrections=false returns the rows as recorded.
if exist("artifacts", "var") && height(artifacts) > 0
    lineage = db.artifactLineage(artifacts.artifact_id(1), Direction="up");
end

% 2h. Subject dimension enriched with latest weight/endpoint (a view, not a
% table you insert into — it's derived from husbandry/endpoint events)
current = db.getSubjectCurrent(SubjectId="G-0421");

% 2i. Ad-hoc SQL for anything the typed getters don't cover.
% Prefer runReadOnlyQuery for anything driven by user input or a UI text box
% — it wraps the statement in a Postgres READ ONLY transaction, so even a
% query that slips past your own guard cannot mutate data.
activeEventCount = db.runReadOnlyQuery("SELECT count(*) AS n FROM lab.event_active;");
fprintf("active events: %d\n", activeEventCount.n(1));

%% 3. Adding data
% 3a. Idempotent "insert if missing" pattern
% Natural-key tables (subject, project by name, species, etc.) will error on
% a duplicate insert because the key is UNIQUE. Check first if a script may
% run more than once against the same data.
subjectId = "G-0421";
existing = db.getSubjects(SubjectId=subjectId);
if height(existing) == 0
    db.addSubject( ...
        SubjectId   = subjectId, ...
        ProjectId   = proj.project_id(1), ...
        SpeciesCode = "meriones_unguiculatus", ...
        Sex         = "M", ...
        DateOfBirth = datetime(2026, 1, 15));
end

% 3b. A new session under an existing subject
sessionId = db.addSession( ...
    SubjectId     = subjectId, ...
    Label         = "2026-07-03_pen1", ...
    StorageRootId = 1, ...                  % see db.getStorageRoots() for valid ids
    RelativePath  = "G-0421/2026-07-03_pen1", ...
    StartedAt     = datetime("now", "TimeZone", "local"), ...
    Rig           = "rig-A");

% 3c. A recording event tied to that session, then the raw file it produced
recEventId = db.addRecordingEvent( ...
    SubjectId             = subjectId, ...
    SessionId             = sessionId, ...
    OccurredAt            = datetime("now", "TimeZone", "local"), ...
    AcquisitionSystemCode = "intan_rhx", ...
    SampleRateHz          = 30000, ...
    NChannels             = 64, ...
    DurationS             = 1800, ...
    HardwareConfig        = struct("gain", 200, "reference", "common_median"));

% SubjectId / SessionId, where given, must be the producing event's: the
% database rejects a file filed under another animal or session.
rawArtifactId = db.addArtifact( ...
    ProducedByEventId = recEventId, ...
    StorageRootId     = 1, ...
    SubjectId         = subjectId, ...
    SessionId         = sessionId, ...
    RelativePath      = "G-0421/2026-07-03_pen1/raw.dat", ...
    Checksum          = "96856fa7376e06ee8614e194b4ca38a6372e1f7a32861a99b0ab10e680391bd7", ...
    ChecksumAlgo      = "sha256", ...
    SizeBytes         = 1.2e10, ...
    Role              = "raw", ...
    Format            = "dat");

% 3d. An analysis event that *consumes* an existing artifact and produces a
% new one — this is how the provenance DAG gets built. addEventInput records
% the "consumed" edge; addArtifact's ProducedByEventId records the "produced" edge.
analysisEventId = db.addAnalysisEvent( ...
    SubjectId    = subjectId, ...
    SessionId    = sessionId, ...
    OccurredAt   = datetime("now", "TimeZone", "local"), ...
    PipelineName = "kilosort4", ...
    CodeVersion  = "v4.0.1", ...
    Parameters   = struct("Th", [9 3], "nblocks", 5), ...
    Status       = "succeeded");

db.addEventInput(EventId=analysisEventId, ArtifactId=rawArtifactId, Role="raw");

spikesArtifactId = db.addArtifact( ...
    ProducedByEventId = analysisEventId, ...
    StorageRootId     = 1, ...
    SubjectId         = subjectId, ...
    SessionId         = sessionId, ...
    RelativePath      = "G-0421/2026-07-03_pen1/spikes.npy", ...
    Checksum          = "89ea16571245ee09db9c76596ab6bdfb7b420545f038c0f16ca1bda7c9c7db13", ...
    Role              = "spikes", ...
    Format            = "npy");

% 3e. Logging a checksum verification pass (e.g. a nightly NAS integrity job)
db.addArtifactVerification( ...
    ArtifactId       = rawArtifactId, ...
    Status           = "ok", ...
    ObservedChecksum = "96856fa7376e06ee8614e194b4ca38a6372e1f7a32861a99b0ab10e680391bd7");

% 3f. A husbandry (weight) reading — a simple recurring measurement event
weightEventId = db.addHusbandryEvent( ...
    SubjectId  = subjectId, ...
    OccurredAt = datetime("now", "TimeZone", "local"), ...
    Measure    = "weight", ...
    WeightG    = 72.4);

% 3g. A whole weigh-in sheet at once: one husbandry event per row that has
% a value, written as one transaction (all rows or none). Rows with no value
% (NaN) are skipped; ids(k) is missing for those.
sheet = table([subjectId; "G-0422"], [71.9; NaN], ...
    'VariableNames', {'subject_id', 'weight_g'});
batchIds = db.addHusbandryBatch(sheet, OccurredAt=datetime("now", "TimeZone", "local"));

% 3h. Registering a file from its path: the size, the SHA-256 and the path
% relative to the storage root are worked out from the file. RootPath is
% where storage root 1 is mounted on THIS computer. Check the first files
% registered this way against a known hash (see help CarasLabDB.fileChecksum).
% [lfpArtifactId, info] = db.addArtifactFromFile( ...
%     "Z:\data\G-0421\2026-07-03_pen1\lfp.npy", ...
%     ProducedByEventId=analysisEventId, StorageRootId=1, RootPath="Z:\data", ...
%     Role="lfp", SubjectId=subjectId, SessionId=sessionId);

% 3i. User-defined variables: a named number or string, with units, on any
% event, artifact, subject, session or project. Defined on first use;
% setting it again is an update (the log keeps every value).
db.setVariable("session", sessionId, "Probe Depth", 1200, Units="um");
db.setVariable("session", sessionId, "probe depth", 1350);          % update
sessionVariables = db.getVariables("session", sessionId);           % current values
depthLog         = db.getVariables("session", sessionId, History=true);
allDepths        = db.getVariableValues("probe depth", Kind="session");
% db.unsetVariable("session", sessionId, "probe depth", Note="wrong probe");

%% 3j. Recording work that may have to be sent later (recordEvent)
% A pipeline that must keep working while the database is out of reach
% mints the ids itself, keeps the record, and sends it when it can.
% recordEvent writes the event, its input edges and its output files in one
% transaction, and sending the same record again changes nothing. The
% digest is the client's own hash of what it records: the same record must
% always give the same digest. Every datetime must carry a time zone.
% runId  = string(java.util.UUID.randomUUID());
% fileId = string(java.util.UUID.randomUUID());
% out = db.recordEvent("analysis", EventId=runId, Digest=recordSha256, ...
%     OccurredAt=datetime("now", "TimeZone", "local"), SessionId=sessionId, ...
%     Detail=struct("pipeline_name", "ephys_analysis/signals", ...
%         "code_version", "c677202", ...
%         "parameters", CarasLabDB.jsonText(optionsJsonText), ...   % stored as written
%         "status", "succeeded"), ...
%     Inputs=struct("artifact_id", rawArtifactId, "role", "raw"), ...
%     Outputs=struct("artifact_id", fileId, "storage_root_id", 1, ...
%         "relative_path", "G-0421/2026-07-03_pen1/pen1_extract.mat", ...
%         "checksum", extractSha256, "size_bytes", 123456, "role", "lfp", "format", "mat"), ...
%     MissingInputs="skip");     % an input not registered yet is added later:
% db.addEventInput(EventId=runId, ArtifactId=rawArtifactId, IfExists="skip");
% A connection that should not block for minutes when the server is down:
% db = CarasLabDB(..., ConnectTimeout=5, StatementTimeout=60);

%% 4. Correcting data (append-only: no UPDATE/DELETE on events/artifacts)
% Events and artifacts are immutable — a database trigger blocks UPDATE and
% DELETE outright. To fix a mistake, insert a new row whose `supersedes`
% column points at the row it replaces; the *_active views then show only
% the newest row in the chain.

% 4a. Correct an event: carry every column forward except the overrides.
correctedWeightEventId = db.supersedeEvent(weightEventId, ...
    DetailOverrides = struct("weight_g", 71.9), ...
    Notes           = "scale recalibrated");
fprintf("weight event %s superseded by %s\n", weightEventId, correctedWeightEventId);

% 4b. Correct an artifact the same way (e.g. re-registering after a re-copy
% with a corrected checksum, or fixing its role). A correction may keep the
% same file; the database only refuses a second *active* row for one file.
% supersedeEvent (4a) already re-points the files an event produced at the
% corrected event (and files them under its subject and session), so there
% is no need to do that by hand. Supersedes= on an addXEvent method does the
% same.
% correctedArtifactId = db.supersedeArtifact(rawArtifactId, ...
%     Overrides = struct("checksum", ...
%         "4da8f728d65b6887cace643d842d3007e4a7765ab3c3caebd7844288ddf23648"));

% 4c. The subject and session *dimension* tables are the one exception: they
% are ordinary mutable rows (no immutability trigger), so simple in-place
% updates are allowed and preferred over supersede for typo fixes. The
% database keeps the previous values, and the login that changed them, in
% lab.row_history.
db.updateSubject(subjectId, Strain="Long-Evans", Notes="re-typed after review");
% db.updateSession(sessionId, Notes="rig clock resynced mid-session");
% Clear= sets columns to NULL (database column names, from a fixed list):
% db.updateSubject(subjectId, Clear=["genotype", "notes"]);
% db.updateSession(sessionId, Clear="ended_at");

% 4d. A row that should never have been recorded at all (entered twice,
% registered by mistake) is retracted rather than corrected. It stays in the
% database, with the reason, but leaves the *_active views.
% db.retractEvent(duplicateEventId, "entered twice");
% db.retractArtifact(wrongArtifactId, "registered under the wrong path");
% retractions = db.getRetractions();

% 4e. What needs attention, according to the database itself (errors first):
% events without a detail row, files never verified, corrections that lost
% their tags or inputs, files whose producing event was retracted, ...
integrityFindings = db.checkIntegrity();

%% 5. Error handling around inserts
% pInsertEvent (used internally by every addXEvent method) already wraps the
% base+detail insert in one transaction with automatic rollback on failure,
% so a partial event row can never be left behind. Your own code just needs
% to decide what to do when the insert itself throws (e.g. a bad
% AcquisitionSystemCode that fails the lookup FK):
try
    db.addRecordingEvent( ...
        SubjectId             = subjectId, ...
        SessionId             = sessionId, ...
        OccurredAt            = datetime("now", "TimeZone", "local"), ...
        AcquisitionSystemCode = "not_a_real_system", ...
        SampleRateHz          = 30000, ...
        NChannels             = 64, ...
        DurationS             = 1800);
catch ME
    fprintf("insert failed as expected: %s\n", ME.message);
end

%% 6. Disconnecting
% Always close (or let `clear`/`delete` close) a connection you opened.
% Connections injected via Connection= at construction are left open for the
% caller to manage.
delete(db);
