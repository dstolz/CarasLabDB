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
% Requires MATLAB R2025a+, Database Toolbox, and a reachable Postgres
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
% By default get* methods read the *_active views (superseded rows hidden).
% Flip this globally, or per call with ActiveOnly=false.
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

% 2c. All events for a subject, most recent activity table only (default)
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

% 2g. Full upstream provenance of a derived file (walks event_input edges)
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

rawArtifactId = db.addArtifact( ...
    ProducedByEventId = recEventId, ...
    StorageRootId     = 1, ...
    SubjectId         = subjectId, ...
    SessionId         = sessionId, ...
    RelativePath      = "G-0421/2026-07-03_pen1/raw.dat", ...
    Checksum          = "ab12cd34ef56", ...
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
    Checksum          = "99aa88bb", ...
    Role              = "spikes", ...
    Format            = "npy");

% 3e. Logging a checksum verification pass (e.g. a nightly NAS integrity job)
db.addArtifactVerification( ...
    ArtifactId       = rawArtifactId, ...
    Status           = "ok", ...
    ObservedChecksum = "ab12cd34ef56");

% 3f. A husbandry (weight) reading — a simple recurring measurement event
weightEventId = db.addHusbandryEvent( ...
    SubjectId  = subjectId, ...
    OccurredAt = datetime("now", "TimeZone", "local"), ...
    Measure    = "weight", ...
    WeightG    = 72.4);

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
% with a corrected checksum).
% correctedArtifactId = db.supersedeArtifact(rawArtifactId, ...
%     DetailOverrides = struct("checksum", "corrected-checksum-value"));

% 4c. The subject and session *dimension* tables are the one exception: they
% are ordinary mutable rows (no immutability trigger), so simple in-place
% updates are allowed and preferred over supersede for typo fixes.
db.updateSubject(subjectId, Strain="Long-Evans", Notes="re-typed after review");
% db.updateSession(sessionId, Notes="rig clock resynced mid-session");

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
