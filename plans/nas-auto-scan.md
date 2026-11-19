# Search the listed NAS directories for new files and register them automatically

## Context
`plans/nas-file-registration.md` specifies the importer (`tools/import_nas_files.py`): it reads a directory tree, works out what each file is, and registers a session, an event and one `lab.artifact` row per file. There the directories are listed in a file on the server and a person reviews every scan before `apply`.

This plan adds the recurring, unattended part: a scheduled run that looks at the listed directories, reads **only files it has not seen**, and registers what is new and unambiguous. The administrator decides **which directories are searched and how often**, in the database, through a dialog of the MATLAB app.

Registration is permanent (`artifact` and `event` are append-only, and a file's first row can never be entered twice), so the rule of the importer stands and is tightened for unattended runs: **anything uncertain is held and reported, never guessed, and an unattended run only ever adds.**

### Decisions you made
| Topic | Decision |
|---|---|
| Where the settings live | In the database, in an admin-only table. Only the schema owner, or a login the owner grants it to, can change it. Members can read it. |
| How they are edited | A dialog of the MATLAB app (read-only without the privilege), or SQL. |
| Frequency | Per directory: an interval and an optional allowed time-of-day window. A scheduled task wakes every 15 minutes and searches only the directories that are due. |

### What this changes in `plans/nas-file-registration.md`
| There | Now |
|---|---|
| "No schema change" (Part 1) | Five tables, three views, three read functions, two policy triggers and one integrity check (Part 1 here). Version stays 1: the database is not launched. |
| Directories in a TOML config (Part 2) | Rows of `lab.scan_directory`. `lab_time_zone` and `min_age_hours` become columns of the directory. |
| A group younger than `min_age_hours` by its files' modification times is skipped | A group is registered once two complete listings at least `min_age` apart show it unchanged (below). Modification times no longer decide it. |
| Unchanged files found by size and `attributes.source_mtime` | Found by the scan memory (`lab.scan_file`), which names the artifact. `source_mtime` is still stored. |
| Runs as a member login in `lab_rw` | Runs as `lab_scanner` (in `lab_rw`, plus INSERT on the scan logs) or as the owner. |

## Part 1: Database (`design_docs/schema.sql`, version 1)

**`lab.scan_layout`** (`code`, `label`), seeded `epsych` and `intan`. A layout is a module of the tool, so a row without its module is useless: INSERT is the owner's, as for `event_type`.

**`lab.scan_directory`**: one directory to search. Mutable; every UPDATE and DELETE goes to `row_history`.

| Column | Meaning |
|---|---|
| `scan_directory_id` | identity key |
| `storage_root_id`, `relative_path` | the directory, under a registered storage root. Path rules of `session`, and also no `.` segment, no `//`, no trailing `/`. |
| `layout` | which module reads it |
| `rig`, `pair_with` | as in the importer plan; `pair_with` names another directory on the same root |
| `time_zone` | zone of the wall-clock times in the file names, and of the window. Must be in `pg_timezone_names`. |
| `scan_interval_min` | minutes between searches, at least 1 |
| `window_start`, `window_end` | allowed hours `[start, end)`, both or neither; wraps midnight when start > end |
| `min_age_min` | how long a group must be seen unchanged before it is registered. Default 1440. |
| `mode` | `off`, `report` (search, remember what was seen and report what would be registered; registers nothing and reads no file to its end) or `register`. Default `report`. |
| `mode_changed_at` | kept by the trigger, so a directory that was `off` is not called overdue for that time |
| `notes`, `created_at`, `created_by`, `created_login` | `row_history` does not log an INSERT, so the creator is stamped on the row |

Rules, in `trg_scan_directory_policy` (advisory lock per root; the name sorts after the path normalisation):
- Among directories that are not `off`, no two on one root may be equal or nested, compared without regard to case (SMB ignores it). Not with `LIKE`: `_` is a wildcard. Case is folded with `lower()`, which in a C-locale database folds ASCII letters only.
- Root, path, layout, `time_zone` and the `created_*` columns are frozen once the directory has a run. To change them, turn the directory `off` and add another.
- A directory with runs cannot be deleted (foreign key).

**`lab.scan_run`** (append-only): written when a run of one directory starts. Directory, `command` (`run` or `apply`), `mode`, `due_at` (the scheduled time it answers, as the database gave it; NULL for a run made by hand, which never moves the schedule), `started_at` (database clock), tool version, host, `run_login` (stamped). A run locks its directory against a concurrent change of the frozen columns.

**`lab.scan_run_result`** (append-only): written when it ends. `outcome` (`ok`, `partial`, `failed`, `unreachable`), counts of files and groups, bytes read, message. A run with no result is running or was interrupted.

**`lab.scan_file`** (append-only): the scan memory. A row is appended only when what the tool sees of a file differs from the latest row for that path.

| Column | Meaning |
|---|---|
| `scan_run_id`, `storage_root_id`, `relative_path` | when and where, spelled as on disk |
| `size_bytes`, `mtime_ns` | as listed (`st_mtime_ns`, a whole number: never a float) |
| `group_key` | the group the file belongs to |
| `status` | `pending` (seen, waiting to be seen unchanged), `registered` (this tool registered it), `known` (another client had registered these bytes at this path; confirmed by reading), `held`, `cleared` (a pending or held file is no longer there) |
| `reason_code`, `reason` | for `held` |
| `artifact_id` | required for `registered` and `known`, with a foreign key on (artifact, root, path) so a memory row cannot name a file other than its artifact's |

Views `scan_file_latest` (latest row per root and path) and `scan_held`.

**The schedule has one definition**: `lab.fn_scan_status(p_now)`, one row per directory; `scan_directory_status` is it at `now()`, `fn_scan_due(p_now)` its due rows, `fn_scan_window_open(id, p_now)` the window test alone. Times of day and durations are returned as text and whole numbers, so no client does interval arithmetic.
- **Due** when `mode <> 'off'`, `p_now >= due_at` and the local time in `time_zone` is inside the window.
- **`due_at`** is anchored, so a daily search does not start a little later each day: the directory's `created_at` if it never ran; else the last `ok` scheduled run's `due_at` plus the interval, moved up to `p_now` when more than one interval behind; at once after `partial`; `least(interval, 60 min)` after `failed` or `unreachable`.
- A run with no result does not move the schedule, so an interrupted run does not stall its directory.
- **Overdue** when `p_now > D + interval + 26 h`, where D is the later of the time the last `ok` search was due plus the interval (the directory's `created_at` when there is none) and `mode_changed_at`. It is measured from the last search that succeeded, so repeated failures do not reset it.
- Daylight saving: the interval is counted in minutes, so a daily search moves one hour on the wall clock at a change; with a window it then starts at the window's next opening. A window inside the skipped hour does not open that day; the repeated hour is harmless.

**Integrity**: check 16, `scan_directory_overlap` (the nesting rule is a trigger, so it gets a check).

**Privileges** (`design_docs/grants.sql`): INSERT on all five tables is revoked from `lab_rw`; no UPDATE is granted. A member who could write `scan_run` could postpone a search, and one who could write `scan_file` could hide a file. No new group role:

```sql
CREATE ROLE lab_scanner LOGIN PASSWORD '...' IN ROLE lab_rw;
GRANT INSERT ON lab.scan_run, lab.scan_run_result, lab.scan_file TO lab_scanner;
-- to let a member manage the list:
GRANT INSERT, UPDATE ON lab.scan_directory TO jdoe;
```

## Part 2: The tool (`tools/import_nas_files.py`)

Commands: `scan` and `apply` (the reviewed path of the importer plan, now reading directories from the database), and two new ones.

**`run --root NAME=PATH ... --report-dir DIR [--overrides FILE] [--directory ID] [--now] [--dry-run] [--log-file FILE]`**
1. Read the due directories, earliest `due_at` first. A directory whose root was not given is skipped and counted.
2. Per directory: take an advisory lock (a second process skips it), check the root marker, append the `scan_run` row. A missing or empty directory is `unreachable`.
3. **List** it completely with `os.scandir`: names and sizes only, no file is opened, symbolic links are not followed. A paired directory is listed in the same pass. **If any folder cannot be listed the run is `failed`: nothing is registered and nothing is concluded from what is absent.**
4. **Decide what to read.** A file whose latest memory row is `registered` or `known` with the same size and `mtime_ns`, and whose artifact is still active and present, is not opened: its header comes from a local cache (`--cache-file`, an optimisation only; without it the first few kilobytes are read again). A held file with the same size, `mtime_ns` and reason is not read to its end again either.
5. **Interpret** with the layout, as in the importer plan. **A directory and the one it is paired with are judged together**, whichever of the two is being searched:
   - an ePsych session paired with a recording waits until that recording is registered, and is held while the recording is held;
   - an ePsych session with no recording is registered on its own only when no recording folder of that subject that could pair with it is in sight in any state;
   - a run writes memory rows, and registers, only for its own directory's files.
   
   A recording that reaches the NAS after its ePsych session was registered on its own is held as `late_recording`. Give the ePsych directory a minimum age longer than the longest delay between the two backups.
6. **Wait for stability.** A group is registered only when two complete listings at least `min_age_min` apart, by the database clock, show the same files with the same sizes and `mtime_ns`; the first sighting writes `pending` rows. This replaces the modification-time rule: a backup tool that preserves timestamps would make a half-copied recording look old, and a rig clock that runs ahead would make a file look young for ever.
7. **Register** (mode `register`): hash the group's files (4 MiB chunks), stat each again, and write the group in one transaction exactly as `apply` does (session, event, artifacts, `ok` verification rows) together with its memory rows. The window is asked again before each group; when it has closed the run ends `partial` and continues at the next opening. **Mode `report`** does steps 1 to 6, writes the same `pending`, `held` and `cleared` rows, and stops there: its report names the groups that are stable and would be registered.
8. Append the `scan_run_result` row, write the report (CSV and text) when anything happened, one line to the log file.

**An unattended run only adds.** These are held for a person, and done with `scan` / `apply`:

| Seen | Held as |
|---|---|
| A group whose event exists with another digest (it would be a correction) | `would_correct` |
| Other bytes at a registered path (it would record `replaced`) | `content_changed` |
| A recording arriving for a behavior-only session already registered | `late_recording` |
| A path that differs only in case from a registered one | `path_case_conflict` |
| A file whose artifact was retracted or recorded as moved, replaced or deleted | `registered_but_withdrawn` |
| Everything the importer plan holds (unknown subject, mislabelled folder, ambiguous pairing, orphan video, unreadable or unrecognised file) | its own code |

A file whose size or `mtime_ns` changed but whose bytes are the registered ones is read once and gets a new `known` row; no artifact is written. Registered files missing from a listing are reported only: recording a deletion stays a person's decision.

**`check`** searches nothing and exits 1 when a directory is overdue, when two listed directories overlap, or when a due directory's root was not given. It prints the number of held files. Schedule it and alert on it, as for `backup_lab.py --check`.

**Safety**
- Never writes, renames or deletes anything on the NAS.
- The advisory lock only saves work. What prevents a double registration is the deterministic ids, `uq_artifact_file_original` and one transaction per group. After a dropped connection the tool reconnects and takes the lock again, or stops.
- `--root` paths that contain each other are refused, and a directory whose stored spelling differs from the names on disk.
- `apply` refuses a group whose sighting in the plan file is younger than `min_age_min`.

**Scheduling** (`deployment-windows.md` §4): Task Scheduler, every 15 minutes, "do not start a new instance", as `LAB\svc-caraslabdb` with `PGUSER=lab_scanner` and UNC paths; `check` once a day. A `lab.person` row with `db_login = 'lab_scanner'` is optional: without it `recorded_by` is NULL and `recorded_login` still says who wrote the row.

## Part 3: MATLAB

**`@CarasLabDB`**: `getScanDirectories` (the status view), `addScanDirectory`, `updateScanDirectory`, `getScanRuns`, `getScanFiles(Status=, LatestPerFile=)`, `canEditScanDirectories` (INSERT and UPDATE tested separately). Intervals travel as whole minutes and window times as `HH:mm` text.

**`@CarasLabDBApp/showScanDirectoriesDialog.m`** (Ctrl+Shift+D, in the toolbar and the Ctrl+? list):
- A table of the directories: root, path, layout, mode, every, window, last run and its outcome, next due, pending and held counts, overdue marked.
- An edit panel inside the dialog (not a second modal window): root and layout dropdowns, path, interval with a unit, window start and end, minimum age, mode, rig, time zone, notes. Ctrl+S saves, Ctrl+N starts a new one, Ctrl+R refreshes, Esc closes.
- "Runs" and "Held files" lists for the selected directory.
- Without the privilege every control that writes is disabled and the dialog says why.
- Size and position persist through `loadPrefs` / `savePrefs`.

## Part 4: Mirrors, tests, documents
- **MCP server**: read tools `get_scan_directories`, `get_scan_runs`, `get_scan_files` (`tools/scans.py`), the views added to the allowlist in `db.py`, the integrity tool's count.
- **Dashboard**: unchanged. Its export has a fixed set of keys.
- **Tests**: `tests/schema_test.sql` (policies, append-only, the schedule at fixed instants including daylight-saving days and a wrapping window), `tests/roles_test.sql` (a member is refused; a delegated login and the scanner are allowed; `run_login` is stamped), `tests/check_nas_import_parsing.py` (no database), `tests/check_import_nas_files.py` (end to end, in CI), `tests/matlab/ScanDirectoryTests.m` and dialog tests in `TagGuiTests.m`, the MCP suite.
- **Documents**: `design_docs/nas-import.md` (new guide), `database-design.md`, the deployment guides (login, scheduled tasks), `mcp-server.md`, `testing-locally.md`, `CLAUDE.md`.

## Not in this plan
- Overrides in the database. They stay a reviewed CSV given with `--overrides`.
- A "search now" button. The administrator shortens the interval, or runs the tool with `--now`.
- More layouts (RIG1, RIG2, Open Ephys, TDT, videos): one module and one `scan_layout` row each.

## Verification
- `tests/schema_test.sql`, `grants.sql` twice, `tests/roles_test.sql`: no assertion fails, on PostgreSQL 14 to 17.
- `tests/check_import_nas_files.py`:
  - the first sighting registers nothing; a second after `min_age_min` registers; a third reads 0 bytes;
  - a folder that grows between sightings stays pending;
  - a folder that cannot be listed gives `failed` and no rows;
  - a touched file is read once, becomes `known`, and gets no artifact;
  - a changed file, a late recording and a case variant are held, and nothing is superseded;
  - `report` mode writes sightings and registers nothing; switched to `register`, a group that was already stable is registered by the next run;
  - an ePsych session waits for its recording, and is registered alone only when no recording could pair with it;
  - a member's INSERT into `scan_file` is refused.
- `python -m pytest -q mcp-server/tests` passes with the three new tools.
- MATLAB CI: a member sees disabled controls; the owner adds and edits a directory; `row_history` holds the edit.
- `ruff check mcp-server web/live web/forms tests tools` is clean.
- On staging: `check` exits 0 after a run and 1 with a directory made overdue; after a week of scheduled runs, files registered + pending + held + ignored = files on disk for each directory (`Get-ChildItem -Recurse -File`).
