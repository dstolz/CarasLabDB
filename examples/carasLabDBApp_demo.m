%% CarasLabDBApp demo — launching the GUI
%
% The GUI is a thin front end over the CarasLabDB class. There are two ways to
% start it; both require the repo root on the MATLAB path so that the
% @CarasLabDB and @CarasLabDBApp class folders are visible, and a reachable
% Postgres instance with design_docs/schema.sql applied.
%
% This is a walkthrough script, not an automated test.

%% Option A — let the app open a login dialog
% Non-secret fields (server/port/username/database/person email) are remembered
% between sessions via setpref; the password is never stored and is prompted
% each launch.
app = CarasLabDBApp();

%% Option B — reuse an already-open CarasLabDB connection
% Useful when you are already scripting against the database and want to browse
% the same session interactively.
db = CarasLabDB( ...
    Username="ephys_rw", ...
    Password="change-me", ...
    Server="nas-main.lab", ...
    DatabaseName="ephys", ...
    PersonEmail="dstolz@umd.edu");
app = CarasLabDBApp(db);   %#ok<NASGU>

%% What you can do in the window
%  * Browse Subjects / Sessions / Events / Artifacts in sortable tables.
%  * Quick subject search (substring or regex) plus up to four column filters
%    with Exact / Contains / Regex / Range modes (regex uses Postgres ~*).
%  * Toggle "Active only" to switch between the *_active views and full history.
%  * "Export → WS" copies the currently displayed table into the base workspace
%    for further analysis.
%  * "Add Event" opens a type-aware form; select a row and "Edit / Supersede"
%    to correct an event (append-only correction) or edit a subject/session in
%    place.
%  * The "Custom SQL" tab runs read-only SELECT/WITH queries (enforced by both a
%    syntactic guard and a Postgres READ ONLY transaction), remembers a recall
%    history, and lets you edit and re-run queries.

%% Closing
% Closing the window (or deleting the handle) persists preferences. If the app
% opened its own connection (Option A), it is closed too; an injected
% connection (Option B) is left open for you to manage.
delete(app);
