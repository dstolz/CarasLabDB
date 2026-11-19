# NAS import: registering the files already on the NAS

The raw data of the lab's rigs sits on the NAS. This feature finds new files
there, works out what each one is, and registers it: a session, the event
that produced it and one artifact row per file, with its SHA-256. The
administrator keeps a list of NAS directories and how often each is
searched. A scheduled tool searches the ones that are due, reads only files
it has not seen, and registers what is new and unambiguous. Everything it is
not sure of it holds, and reports, for a person to settle.

- Tool: `tools/import_nas_files.py` and the package `tools/nas_import/`
- Data model: [database-design.md](database-design.md) §3.10
- Deployment: [deployment-windows.md](deployment-windows.md) §4.4
- Two readers: the **administrator** who keeps the list (§3, §4, §5) and the
  person who deals with **held files** (§7 to §9).

## 1. What it does and what it never does

Registration is permanent. Artifacts and events are append-only, and a
file's first row can never be entered twice, even after a retraction. So the
tool is built to be safe to run again and again, and to hold anything
uncertain.

It never:

- writes, renames or deletes anything on the NAS. It lists folders and reads
  files, and never follows a symbolic link, a junction or a reparse point;
- creates a subject. A file in a folder that is not a known subject is held
  until the subject is added to the database;
- guesses. A name it cannot read, a subject it cannot match, a pairing that
  is ambiguous, a file that is damaged or that changed while it was read is
  held with a reason;
- concludes anything from a folder it could not list. If any folder cannot
  be listed the whole search of that directory fails, and nothing is
  registered and nothing is marked missing;
- deletes a row, or writes a `*_login` column (the database stamps those).

**An unattended run only adds.** It never supersedes an event or artifact,
never retracts one and never records a disposition. What would need one of
those is held (`would_correct`, `content_changed`, `late_recording`,
`registered_but_withdrawn`, §7) and left for a person.

A search that finds nothing new writes almost nothing: a file that does not
change has one row in the scan memory however often its directory is
searched.

## 2. The pieces

| Piece | What it is | Where |
|---|---|---|
| **The list** | Which directories are searched, how they are laid out and how often. Edited by the administrator. | `lab.scan_directory` (and `lab.scan_layout`) |
| **The schedule** | When each directory is next due, whether it is overdue. One definition, in the database. | `lab.fn_scan_status`, `lab.scan_directory_status`, `lab.fn_scan_due` |
| **The run log** | One row when a search starts, one when it ends. | `lab.scan_run`, `lab.scan_run_result` |
| **The scan memory** | What the tool last saw of each file and what it concluded: `pending`, `registered`, `known`, `held`, `cleared`. | `lab.scan_file`, `lab.scan_file_latest`, `lab.scan_held` |
| **The tool** | `import_nas_files.py`: `run` (scheduled, unattended), `check` (monitoring), `scan` and `apply` (the reviewed path, §10). | `tools/` |
| **The dialog** | "Scan directories…" in the MATLAB app (Ctrl+Shift+D): the list, its runs and its held files; editing for a login that may. | `@CarasLabDBApp` |
| **The MCP tools** | `get_scan_directories`, `get_scan_runs`, `get_scan_files`: the same reads for an agent. | `mcp-server/` |

## 3. Setting up

### 3.1 A storage root and its marker

Every directory is under a storage root (`lab.storage_root`). A root is a
folder of the NAS, such as one rig's backup folder, and paths are stored
relative to it. Register it once (any member may):

```sql
INSERT INTO lab.storage_root (name, description)
VALUES ('nas-rig3', 'RIG3 backup folder on the NAS share');
```

Where the root is mounted is not in the database. Each run says it with
`--root NAME=PATH` (§10). Give each root a marker file, so that one folder
cannot be searched under two names. Put a file called
`.caraslabdb-root.json` in the root folder, holding the root's name:

```json
{"name": "nas-rig3"}
```

The tool refuses a `--root` whose marker names another root. Without the
marker nothing stops two invocations from searching one folder under two
root names, and its files would be registered under both. The marker is
never registered or held: the walker ignores it.

### 3.2 The scanner login

The scheduled search connects as its own login. It inherits `lab_rw`, which
lets it write sessions, events, artifacts and verifications, and it has
`INSERT` on the three scan logs, which `grants.sql` withholds from `lab_rw`:

```sql
CREATE ROLE lab_scanner LOGIN PASSWORD 'CHANGE_ME_SCAN' IN ROLE lab_rw;
GRANT INSERT ON lab.scan_run, lab.scan_run_result, lab.scan_file TO lab_scanner;
```

The schema's owner may run the tool as well. Why not `lab_rw`: the logs
decide what the search does next. A member who could write `lab.scan_run`
could postpone a directory's search as long as they liked, and one who could
write `lab.scan_file` could make the search pass over a file as registered,
or hide one that is held. Members read all five tables. A login in `lab_rw`
without the grant is refused at start with exit 2 (except for `--dry-run`),
and nothing is searched.

A `lab.person` row with `db_login = 'lab_scanner'` is optional. Without it
`recorded_by` and `created_by` are NULL on what the tool registers, and
`recorded_login` and `created_login` still say `lab_scanner`.

### 3.3 Who may change the list

Only the schema owner may insert into `lab.scan_directory`, and no UPDATE is
granted to `lab_rw`. The list says what is registered without anyone
looking, so it is the administrator's, like the reference tables. To let a
member manage it, grant the table to that member's login by name:

```sql
GRANT INSERT, UPDATE ON lab.scan_directory TO jdoe;
```

INSERT and UPDATE are separate. A member with UPDATE alone can change a
directory but not add one. Whoever may UPDATE can switch a directory to
`register`, so grant it to few. Take it back with `REVOKE INSERT, UPDATE ON
lab.scan_directory FROM jdoe;`. Every change is kept in `lab.row_history`
under the login that made it, and each row names its creator
(`created_login` is stamped by the database). The grant does not include
DELETE, and a directory that has been searched cannot be deleted anyway. A
layout (`lab.scan_layout`) is a module of the tool, so only the owner adds
one (§12).

### 3.4 The scheduled tasks

Two tasks on a machine that mounts the NAS: `run` every 15 minutes, which
searches only the directories that are due, and `check` once a day, which
exits 1 when something is wrong. [deployment-windows.md](deployment-windows.md)
§4.4 has the task definitions; [deployment-linux.md](deployment-linux.md)
§5 and [deployment-synology.md](deployment-synology.md) §5 the equivalents.

## 4. The list of directories

One row of `lab.scan_directory` is one directory to search. Add one in the
dialog (§9.2), with `CarasLabDB.addScanDirectory`, or in SQL:

```sql
INSERT INTO lab.scan_directory
    (storage_root_id, relative_path, layout, rig, time_zone, scan_interval_min)
SELECT root_id, 'epsych_files/Data', 'epsych', 'RIG3', 'America/New_York', 1440
FROM lab.storage_root WHERE name = 'nas-rig3';
```

| Setting | Meaning | Default |
|---|---|---|
| `storage_root_id` | The root the directory lies under. | required |
| `relative_path` | The directory, relative to the root, with `/` separators. No `.` or `..` segment, no `//`, no trailing `/`, not empty: the root itself cannot be listed, list its folders. | required |
| `layout` | Which module reads it: `epsych` or `intan` (§12). | required |
| `rig` | Recorded on the sessions registered from it. | none |
| `pair_with` | Another directory on the **same root** whose files belong with this one's. Set it on the Intan directory, naming the ePsych directory (§6.5). | none |
| `time_zone` | The zone of the wall-clock times in the file names, and of the window. A name from `pg_timezone_names`, spelled as it is there (`America/New_York`), not an abbreviation or an offset. | required |
| `scan_interval_min` | Minutes between searches, 1 to 527040 (366 days). | required |
| `window_start`, `window_end` | The hours of the day, in `time_zone`, in which the directory may be searched: from `window_start` up to, not including, `window_end`. Both or neither. Whole minutes. Wraps midnight when the start is after the end (22:00 to 04:00). | none: any time |
| `min_age_min` | How many minutes a group of files must have been seen unchanged before it is registered (§6.3). | 1440 |
| `mode` | `off`, `report` or `register` (below). | `report` |
| `notes` | Free text. | none |

`mode_changed_at`, `created_at`, `created_by` and `created_login` are kept
by the database. The dialog and the MATLAB methods take the interval and the
minimum age as whole minutes (the dialog also as hours or days) and the
window as `HH:mm`.

### 4.1 The three modes

| Mode | What a search does |
|---|---|
| `off` | Not searched. It takes no part in the overlap rule, so this is how a directory is replaced. |
| `report` | Lists the directory, reads the headers of recognised files, and writes what it saw to the scan memory (`pending`, `held`, `cleared`). Reads no file to its end and registers nothing: no session, event, artifact, `registered` or `known` row. Its report names the groups that have been seen unchanged long enough and would be registered. |
| `register` | As `report`, and registers every group that is stable (§6.3). |

**A new directory starts in `report`.** What is registered cannot be taken
back. Add the directory, let it run once or twice, read the report and the
held files (§9), settle what needs settling (§7, §8), and only then switch
it:

```sql
UPDATE lab.scan_directory SET mode = 'register' WHERE scan_directory_id = 1;
```

Groups that were already stable in `report` mode are registered by the next
run. Switching restarts the overdue count (§5).

### 4.2 What cannot overlap, and what is frozen

- Among the directories that are not `off`, no two on one storage root may be
  equal or nested, compared without regard to case (an SMB share does not
  tell `Data` from `data`). The database refuses the second one. A pair that
  got past it is reported by `lab.fn_check_integrity()` as
  `scan_directory_overlap`, and `check` exits 1.
- Once a directory has been searched (it has a row in `lab.scan_run`), its
  storage root, path, layout and time zone are frozen: the runs, and the
  files they registered, were made under them. The interval, the window,
  `min_age_min`, `mode`, `rig`, `pair_with` and `notes` can still be
  changed.
- A directory that has been searched cannot be deleted.

**To replace a directory** (a renamed folder, another layout): turn the old
one `off` and add a new one.

```sql
UPDATE lab.scan_directory SET mode = 'off' WHERE scan_directory_id = 3;
```

The scan memory belongs to the files' paths, not to a directory row. A new
directory on the same path therefore continues from what the old one saw.

## 5. The schedule

`lab.fn_scan_status(now)` is the one definition. The tool asks it which
directories to search, the dialog shows it, and no client does arithmetic on
times. All durations are counted in minutes, and the only time zone used is
the directory's own, so the answer does not depend on any session's
`TimeZone`.

A run of a directory is **scheduled** when it answers a `due_at`. A run made
by hand (`--now`) has none and never moves the schedule. A run with no result
row is running or was interrupted, and does not count either: an interrupted
run does not stall its directory.

- **Due** when the mode is not `off`, the time has reached `due_at` and the
  window is open.
- **`due_at`**, from the latest scheduled run that has a result:

  | Latest scheduled run | `due_at` |
  |---|---|
  | none yet | the time the directory was added |
  | `ok` | its `due_at` plus the interval (not the time it actually ran, so a daily search does not start a little later every day); if that is more than one interval in the past, now: one search is owed, not one for every interval missed |
  | `partial` | now: the rest is done at once, which with a window means at its next opening |
  | `failed` or `unreachable` | when it finished plus the interval or 60 minutes, whichever is shorter |

- **Overdue** when the mode is not `off` and now is later than *D* plus the
  interval plus 26 hours. *D* is the due time of the last `ok` scheduled run
  plus one interval (the time the directory was added, when there is none),
  or the time the mode last changed, whichever is later. It is measured from
  the last search that succeeded, so repeated failures or a stopped
  scheduler make a directory overdue and do not reset it. `check` exits 1
  for it.
- **Daylight saving.** The interval is counted in minutes, so a daily
  search moves by an hour on the wall clock at a change; with a window it
  then starts at the window's next opening. A window that lies inside the
  skipped hour does not open that day. The repeated hour is harmless.
- **Window.** The window is asked again before each group is registered.
  When it has closed, the run ends `partial` and continues at the next
  opening. (A run made with `--now` ignores the window.)

Outcomes of a run (`lab.scan_run_result.outcome`):

| Outcome | Meaning |
|---|---|
| `ok` | The directory was listed completely and everything that could be done was done. |
| `partial` | It stopped early because the window closed. |
| `failed` | A folder could not be listed, a file or the connection failed, or the run broke off. Nothing was concluded from what was absent. |
| `unreachable` | The directory is missing or empty (an unmounted share looks like this). |

## 6. How a file gets registered

### 6.1 Listing

A search lists the directory completely with the file system's directory
listing: names, sizes and modification times (`st_mtime_ns`, a whole
number). No file is opened for this. A directory it is paired with (§6.5) is
listed in the same pass. A directory whose stored path is spelled on disk
with other letter case fails the run.

### 6.2 What is opened

| When | What is read |
|---|---|
| A file whose name a layout recognises, not yet registered | Its **start**: for a `.mat` file the beginning of each variable, for an `.rhd` its header, for a `.ts` its first packets. This is how the content check is made. |
| A registered file whose size and modification time are as the memory says, whose artifact is still active and present | **Nothing**, when the cache holds its header (§11). Without a cache entry its start is read again, as for a new file. |
| A file of a stable group, in `register` mode, not yet registered | **All of it**, once: SHA-256 in 4 MiB chunks. An ePsych `.mat` file is read a second time for a structural check (every compressed variable is inflated; a damaged file holds its group before any row is written). |
| A file held after it was read to its end | Not read again while its size and modification time stay the same: the hold stands until a person acts. |

A registered file whose size or modification time changed is treated like a
new one: it waits (§6.3) and is read once. If its bytes are the registered
ones (a backup tool touched it) it gets a `known` row and an `ok` check on
its existing artifact, and no artifact is written. Other bytes at the path
are held `content_changed`.

### 6.3 The stability wait

A group is registered only when it has been seen unchanged for at least
`min_age_min`. It does not use modification times: a backup tool that
preserves them would make a half-copied recording look old, and a rig clock
that runs ahead would make a file look young for ever. It uses the scan
memory and the **database's clock**.

A run registers a group only when every file listed in it now, registrable
or held one by one:

1. has a latest memory row written by an **earlier** run;
2. that row gives the same size, the same modification time, the same group
   and the same state the file would be given now, so that this run appends
   no row for any file of the group; and
3. no file that belonged to the group is gone without being recorded
   `cleared`;

and at least `min_age_min` minutes have passed between the start of the
latest run that wrote one of those rows (or wrote a `cleared` row for a file
of the group) and the start of this run.

So the time is counted from the start of the last run that saw the group
new or different. A file added, changed or gone appends a row, moves that
run forward and starts the wait again **for the whole group**. The first
sighting of a group never registers it, also with `min_age_min = 0`; the
second can. The wait is counted from the *start* of the earlier run, and its
listing ended a little later, so the true interval between the two listings
can be shorter than `min_age_min` by the length of a listing. Choose
`min_age_min` with that in mind.

When a hold is lifted (§7), the files become `pending` at the next run and
the wait starts again.

### 6.4 One group, one transaction

A group is one session's files (one recording folder, or one ePsych session
with its twin files and videos). It is registered in **one database
transaction**: the session if it is new, the event and its detail row, one
artifact per file, one `ok` verification per file (the tool has just read and
hashed it, so otherwise every file would show as `artifact_never_verified`)
and the group's memory rows. A session is registered whole or not at all,
and an interrupted run continues where it stopped.

What makes a run safe to repeat:

- Ids are deterministic (`uuid5` of the session path, and of the event type
  and source path), so a second try writes the same ids.
- Each event stores a digest of what it was registered from in
  `attributes.client_digest`. The same id with the same digest is the same
  event: its new files are added to it and it is not touched. Another digest
  would be a correction, so `run` holds the group `would_correct`.
- A file registered already with the same bytes at the same path is reused
  (`known`); `uq_artifact_file_original` makes a second registration
  impossible.
- A group with no event of its own whose raw files are, by checksum, the raw
  files of exactly one active event (registered by another client, for
  example from a local copy) is a copy: its files are added to that event,
  with attributes naming it (`copy_of_event`), and no event or session is
  made.
- A lock per directory (a PostgreSQL advisory lock) keeps a second process
  out of a directory being searched: it skips it. The lock only saves work;
  the ids, the unique index and the transaction are what prevent a double
  registration.

A registered event carries `attributes.import` (tool, layout, root, path, the
name the time was read from, and the override if one applied),
`captured_by_tool` (`import_nas_files`), `code_version`,
`occurred_at_source` and `client_digest`. Find them with
`WHERE attributes->>'captured_by_tool' = 'import_nas_files'`.

### 6.5 Pairs are judged together

A recording directory (Intan) is paired with a behavior directory (ePsych)
through `pair_with`. A directory and the one it is paired with are listed
and judged together, whichever of the two is being searched, and a run
writes memory rows and registers only for its own directory's files. The
pairing is the rule of `findCopySessions.m` in ephys_analysis:

- An ePsych session is a candidate for a recording of the same subject if it
  starts between 10 minutes before and 2 minutes after the recording starts
  (both ends included). The names' wall-clock times are compared.
- Candidates are paired closest first, one to one. When a rival candidate for
  the same recording or the same ePsych session is less than 30 seconds
  further away in time than the chosen one, the whole connected set is
  ambiguous and nothing in it is paired: its ePsych sessions are held
  `pairing_ambiguous`.
- A recording shorter than 2 minutes takes no part. A session known by its
  date only (§12) is never paired.
- A paired ePsych session joins the recording's session. It is registered
  after its recording is, and is held (`paired_recording_held`) while the
  recording is held.
- A session with no recording is registered on its own, with a session whose
  path is the ePsych file, only when no recording folder of that subject
  that could pair with it is in sight in any state. A folder that is held
  for any reason still counts, so a session near it is paired with it, and
  held, never registered alone. A recording skipped by an override no longer
  counts.
- A recording that reaches the NAS after its ePsych session was registered on
  its own is held `late_recording`: joining them would be a correction. Give
  the ePsych directory a `min_age_min` longer than the longest delay between
  the two backups.

A partner directory is judged whatever its mode, so a session that pairs
with a recording on disk waits while the recordings' directory is `off` or
in `report` mode. More than one directory that is not `off` may not name the
same directory in `pair_with`: the search of either fails.

### 6.6 Subjects and times

The subject of a group is its level-1 folder, which must be an existing
`lab.subject` row, compared exactly. A name that spells the subject with
other letter case is accepted and noted. A name that names another subject
holds the group (`subject_mismatch`) until an override names the subject.
Nothing inside a file names the subject: the tool does not read
`settings.xml`.

Names carry lab wall-clock time. The tool sends that text with the
directory's `time_zone` and PostgreSQL converts it. A time that does not
exist in the zone (skipped by a daylight-saving change) or occurs twice is
held, never converted by guessing. A file known by its date only gets
`occurred_at` of 12:00 on that date, with `occurred_precision: "day"` in the
event's attributes.

## 7. What is held and why

A held file is in the scan memory with its reason, in `lab.scan_held`. It is
never registered while the reason stands. Most holds are decided anew at
every run and end by themselves when their cause is gone (a subject added, a
file renamed, the other file arriving); the files then become `pending` and
wait again (§6.3). The exceptions are holds decided after a file was read to
its end, which stand until the file changes or a person acts (§6.2).

| Code | Why | What resolves it |
|---|---|---|
| **Any layout** | | |
| `symbolic_link` | A symbolic link, junction or reparse point. Never followed. | Replace it by the real file or folder on the NAS. |
| `not_a_regular_file` | Neither a regular file nor a folder (device, FIFO, socket). | Remove it on the NAS. |
| `path_not_storable` | The path is not UTF-8, holds a backslash or a control character, or has white space at the end of a name. | Rename it on the NAS. |
| `unreadable_file` | The file could not be opened or read. Never remembered: tried again at the next run. | Fix the permission or the lock; nothing else is needed. |
| `changed_during_scan` | Its size or modification time changed between the listing and reading it. | Wait; it is looked at again at the next run. |
| `zero_byte` | The file holds zero bytes. Held alone; the rest of its group is registered. | The file is written; it is then added to its event. |
| `not_in_subject_folder` | A file directly in the listed directory. | Move it into a subject folder. |
| `unexpected_depth` | A file deeper than the layout allows. | Move it. |
| `unrecognised_name` | The name matches no rule of the layout. | Rename it, or leave it: a stray file stays held, and stays in `lab.scan_held`, until it is gone. |
| `invalid_name_time` | The name has the form but holds a date or time that does not exist. | Rename it. |
| `name_case_conflict` | Another name in the same folder differs from it only in letter case. No override releases it. | Rename one on the NAS. |
| `listing_incomplete` | Part of the listing could not be read. It fails the whole run, so it is never in the scan memory. | Fix the folder; the next run lists it again. |
| **MAT files** (ePsych) | | |
| `mat_v73` | A MATLAB v7.3 (HDF5) file; only MAT 5.0 is read. | Save it as v7 or earlier, or leave it held. |
| `mat_not_mat5` | Not a MAT 5.0 file (a v4 file, or not a MAT file). | As above. |
| `mat_truncated` | The file ends inside its header or a variable. | Copy it again. |
| `mat_corrupt` | The structure cannot be read. Includes damage found by the structural check made when the group is registered. | Copy it again. |
| `mat_big_endian` | A big-endian MAT file, which is not read. | None in the tool. |
| `mat_not_epsych` | It lacks the variables `Data` and `Info` of an ePsych session. | Rename or move it. |
| `mat_data_size_unknown` | The size of `Data` cannot be read from its header. | None in the tool. |
| **ePsych groups** | | |
| `epsych_trials_disagree` | The files of one session give different trial counts. | A person looks at the files. |
| `epsych_duplicate_session` | Two sessions of one subject folder share a time and spell the subject differently. | Rename one. |
| `no_valid_epsych_file` | No file of the session is a readable ePsych file. | Fix the files. |
| `video_without_mat` | A `.ts` or `_conv.mp4` that matches no session file of its folder. | Add or rename the `.mat`, or the video. |
| `video_not_mpeg_ts` | A `.ts` file without MPEG-TS sync bytes. | Replace it. |
| `converted_video_without_source` | A `_conv.mp4` whose `.ts` is not in the folder. | Add the `.ts`. |
| `converted_video_source_held` | A `_conv.mp4` whose `.ts` is held. | Resolve the `.ts`. |
| **Intan groups** | | |
| `not_in_recording_folder` | A file directly in a subject folder. | Move it. |
| `unrecognised_folder` | A folder whose name is not `<name>_<yyMMdd>_<HHmmss>`. | Rename it. |
| `recording_folder_without_rhd` | A recording-named folder with no `.rhd` directly in it. Still takes part in pairing. | It is registered once an `.rhd` arrives. |
| `rhd_in_subfolder` | An `.rhd` in a subfolder of a recording folder. | Move it. |
| `intan_split_format` | An `info.rhd`: a split-format recording, which this layout does not read. | None in the tool. |
| `rhd_unknown_version` | The main version of an `.rhd` is not 1, 2 or 3. | None in the tool. |
| `rhd_bad_magic`, `rhd_truncated`, `rhd_bad_header`, `rhd_partial_block` | An `.rhd` that is not one, ends inside its header, holds a value the reader will not accept, or is not a whole number of data blocks. Holds the whole recording. | Copy the recording again. |
| `rhd_header_mismatch` | The `.rhd` files of one recording disagree on sample rate or channel count. | A person looks at the recording. |
| `rhd_no_amplifier_channels` | The header has no enabled amplifier channel. | None in the tool. |
| `rhd_duration_inexact` | The duration has no exact decimal value. At 30 kS/s and 15 kS/s most recordings have none (§13). | None in the tool. |
| **Subjects and overrides** | | |
| `unknown_subject` | The level-1 folder is not a known subject (`TEST`, `videos`, a misspelt folder, a subject not yet in the database). | Add the subject to the database, or an override that skips the folder or names the subject (§8). |
| `subject_folder_case_variant` | The folder matches a subject only when case is ignored. | Rename the folder, or an override that names the subject. |
| `subject_mismatch` | The name says one subject and the folder another. | An override that names the subject. |
| `override_unknown_subject` | An override names a subject that does not exist. | Add the subject, or correct the override. |
| **Pairing** | | |
| `pairing_ambiguous` | Another candidate lies within 30 seconds (§6.5). | Skip one of the recordings with an override, or fix the names. |
| `paired_recording_held` | The recording it pairs with is held. | Resolve the recording. |
| `session_label_conflict` | Two sessions of one subject would get the same label. | A person looks at the two. |
| **Against the database** | | |
| `would_correct` | The group's event is in the database with another digest: registering would be a correction. | `scan` plans the correction and `apply` writes it, after a person has read the plan (§10.3). |
| `content_changed` | Other bytes at a registered path: registering them would record the registered file as replaced. Raw data should not change. | `scan` plans a new artifact with the old one recorded `replaced`; `apply` writes it. |
| `late_recording` | A recording arrived for an ePsych session already registered in a session of its own. Joining them is a correction. | `scan` plans the ePsych event corrected into the recording's session (`move_session`); `apply` writes it. |
| `path_case_conflict` | The path differs only in case from a registered one or from another listed path. `scan` holds it too. | Rename on the NAS. |
| `registered_but_withdrawn` | The file's artifact, or the group's event, was retracted, or the file was recorded as moved, replaced or deleted. A file's first row can never be entered twice. `scan` holds it too. | A person decides in the database (a `restored` disposition, or superseding a retracted row). |
| `copy_ambiguous` | The group's files are files of more than one event already in the database. `scan` holds it too. | A person looks at the events named in the reason. |
| `copy_event_mismatch` | The event the files already belong to is another subject's or of another type. `scan` holds it too. | As above. |
| `duplicate_content` | The group's raw files hold the bytes this tool registered already under another name. `scan` holds it too. | A person looks at the paths named in the reason. |
| `session_conflict` | The session the group needs cannot be used: another session holds its label or path, or belongs to another subject. `scan` holds it too. | As above. |
| `local_time_nonexistent`, `local_time_ambiguous` | The name's wall-clock time does not exist in the zone, or occurs twice (§6.6). `scan` holds it too. | A person decides the time. |

Not held, only reported: an empty folder (`empty_folder`), the files under a
folder an override skips (`override_skip`), names ignored on purpose
(`.DS_Store`, `Thumbs.db`, `desktop.ini`, `@eaDir`, `#recycle`, `_gsdata_`,
names that start with `~$`, in any letter case, and the root marker) and
registered files that are not in the listing (`missing`: recording a deletion
is a person's decision, `lab.artifact_disposition`).

Every listed file ends in exactly one place: a group's files, a held file, a
reported file or an ignored one. After a search the counts add up to the
files on disk, which can be checked against an independent listing
(`Get-ChildItem -Recurse -File`).

## 8. Overrides

An overrides file is a reviewed CSV that tells the tool what a person
decided about a subject. It is given to `run` with `--overrides FILE`. Rows:

| Column | Meaning |
|---|---|
| `root` | The storage root's name. |
| `relative_path` | A path under it: a group's folder, an ePsych session's base path (without extension) or its `.mat` path, any one file of a group, or a level-1 folder. |
| `subject_id` | A subject of the database, or the word `skip`. |
| `reason` | Why. Stored on the event. |

```
root,relative_path,subject_id,reason
nas-rig3,intan_files/Data/SUBJ-ID-1225/SUBJ-ID-1255_260709_095155,SUBJ-ID-1225,name says 1255; the folder and the timing say 1225
nas-rig3,epsych_files/Data/TEST,skip,test subject
```

- A group-level row names the subject whatever the folder says. `skip` leaves
  the group unregistered and reported.
- A folder-level row (a level-1 folder) can only `skip` it: everything under
  it is reported, not held. A group-level row wins over a folder-level one.
- The file is UTF-8, with the header above (a BOM is allowed). No value may
  be empty or have white space at an end, a path must be clean, and a
  (root, path) may appear once. A malformed file is refused before anything
  is written, with the line.
- A row that matches nothing is listed at the end of the report.
- The reason is part of the event's digest. Rewording a reason of a group
  already registered makes the run hold it as `would_correct`.
- An override cannot resolve `name_case_conflict`: it cannot say which
  spelling is meant.

Overrides stay a file, not part of the database. A scheduled run reads the
file at every start, so keep it where the service account can read it and
under version control.

## 9. Reading the results

### 9.1 Reports

`--report-dir DIR` writes two files for each directory run in which something
happened: a file seen for the first time or changed, a registration, a hold
that began or changed, a file cleared, a registered file that is missing, a
group that would be a correction, or an error. A failed or unreachable run
is reported unless the run before it failed in the same way. They are named
`<run start, UTC>_dir<scan_directory_id>_run<scan_run_id>`, with `.csv` and
`.txt`. A `--dry-run` names them `..._dryrun`.

The text report starts with the run's line and the totals ("Files now:
registered, known, pending, held, reported, ignored"), then lists groups
(registered, would be registered now, waiting with the time from which they
may be registered, held, held because it would be a correction, changed
while read, errors) and files (seen new or changed, held with the reason,
cleared, registered, registered already with the same bytes, missing from
the listing). The CSV has one row per line of that, with these columns:

| Column | Meaning |
|---|---|
| `what` | `file`, `group` or `directory` |
| `action` | For a file: the row written (`pending`, `held`, `cleared`, `registered`, `known`) or `missing`. For a group: `registered`, `would_register` (stable; `report` mode or `--dry-run`), `waiting`, `held`, `would_correct`, `changed` (a file changed while it was read) or `error`. For a directory: `failed` or `unreachable`. |
| `root`, `path` | The storage root's name and the path under it (a group's folder or base path). |
| `group_key` | The group the file belongs to. |
| `reason_code`, `detail` | Why it is held, and the sentence for people. |
| `size_bytes`, `mtime_ns` | As listed. |
| `artifact_id`, `event_id` | Of a registered or known file; the event a file was registered under. |
| `until` | For a waiting group: from when it may be registered (UTC). |

### 9.2 The dialog

"Scan directories…" in the toolbar of the MATLAB app, or Ctrl+Shift+D, opens
the list. Every member can open it.

- **The list** shows for each directory: root, path, layout, mode, how often
  ("Every"), the hours it may be searched, the minimum age, the last run with
  its outcome ("running", or "interrupted" when a run has no result and is
  not running any more), when it is next due, and the files pending and held
  under it. The State column says `off`, `overdue`, `running` or `due`; an
  overdue row is shaded and an `off` row grey.
- **The form** under it edits the selected directory, or a new one (Ctrl+N).
  Ctrl+S saves it. The interval and the minimum age are a number and a unit.
  What is wrong is said under the form and nothing is written then; a
  refusal by the database (an overlap, a frozen column, an unknown time
  zone) is shown with the database's own message. Once a directory has been
  searched, its root, path, layout and time zone are disabled, with a tooltip
  that says to turn it off and add another. Without INSERT or UPDATE on
  `lab.scan_directory` every control that writes is disabled and the top
  line says so.
- **The tabs** at the bottom list the selected directory's runs, and its
  **Held files** with the reason code and the sentence of each.
- Ctrl+R reloads, Esc closes, Ctrl+? lists the keys. The window's size and
  position are remembered.

### 9.3 SQL, MATLAB and MCP

SQL (every member may read these):

```sql
-- every directory, with the schedule
SELECT scan_directory_id, storage_root, relative_path, mode, last_run_outcome,
       due_at, is_due, is_overdue, n_pending, n_held
FROM lab.scan_directory_status;

-- what is waiting for a person
SELECT storage_root, relative_path, reason_code, reason, first_held_at
FROM lab.scan_held
ORDER BY reason_code, relative_path;

-- the latest runs of one directory
SELECT r.scan_run_id, r.started_at, r.command, r.mode, x.outcome,
       x.files_registered, x.files_held, x.message
FROM lab.scan_run r LEFT JOIN lab.scan_run_result x USING (scan_run_id)
WHERE r.scan_directory_id = 1
ORDER BY r.scan_run_id DESC LIMIT 20;
```

`lab.scan_held.first_held_at` is when the file was first held for this
reason, without interruption. `lab.scan_file_latest` is each path's current
state; `lab.scan_file` is the whole log.

MATLAB (`CarasLabDB`):

```matlab
T = db.getScanDirectories();                          % the schedule, as the database gives it
H = db.getScanFiles(Status="held", StorageRootId=1, PathPrefix="epsych_files/Data/");
R = db.getScanRuns(ScanDirectoryId=1, Limit=20);
c = db.canEditScanDirectories();                      % c.Insert, c.Update
```

`addScanDirectory`, `updateScanDirectory` and `getScanLayouts` write and
read the list; their help says what each takes.

MCP: `get_scan_directories` (with `due_only` and `overdue_only`),
`get_scan_runs` and `get_scan_files` (`status="held"`, `reason_code`,
`relative_path_prefix`, `latest_per_file=False` for the whole log). They
read the same views.

## 10. The tool

```
python tools/import_nas_files.py COMMAND [options]
```

The connection comes from the libpq environment (`PGHOST`, `PGPORT`,
`PGDATABASE`, `PGUSER`, `PGPASSWORD` or the password file). It needs
Python 3 and `psycopg` v3 (`pip install "psycopg[binary]"`). The login of
`run` inherits `lab_rw` and has `INSERT` on the three scan logs
(`lab_scanner`), or is the schema's owner. `check` only reads.

### 10.1 `run`

The unattended search. It reads the due directories (`lab.fn_scan_due()`,
the longest due first) and searches each in turn: takes its lock, appends the
`lab.scan_run` row, lists, remembers, registers (mode `register`), appends
the result row, writes the report.

| Option | Meaning |
|---|---|
| `--root NAME=PATH` | Where storage root NAME is mounted here; repeatable, at least one. Refused: an unknown root, a path that is missing or empty (an unmounted share), two paths one inside the other, a root whose marker names another root. A due directory whose root was not given is skipped and counted. |
| `--directory ID` | Only this `scan_directory_id`; repeatable. |
| `--now` | Search the named directories (or all that are not `off`) whether due or not. A run made by hand: it records no `due_at`, never moves the schedule and does not ask whether the window is open. Naming an `off` directory is refused. |
| `--overrides FILE` | The overrides CSV (§8). |
| `--cache-file FILE` | The header cache (§11). |
| `--report-dir DIR` | Where the reports go (§9.1). Created if missing. |
| `--log-file FILE` | Append one line per process run, `OK` or `ERROR`. The folder of this file, and that of `--cache-file`, must exist. |
| `--dry-run` | Write nothing to the database, the cache or a report; read no file to its end; print the text report of what would be done. |

Exit status:

| Code | Meaning |
|---|---|
| 0 | Every directory searched ended `ok` or `partial`. Directories skipped (locked by another process, root not given, no longer due) do not change it. |
| 1 | Some directory ended `failed` or `unreachable`. |
| 2 | A usage or connection error, including a login that may not write the scan logs, and a lost connection that could not be restored. Nothing, or not everything, was searched. |

When the connection drops the tool reconnects once and takes its lock again,
or stops. A group is never half written.

### 10.2 `check`

```
python tools/import_nas_files.py check [--root NAME=PATH ...] [--log-file FILE]
```

It searches nothing and writes nothing. It prints each directory that is not
`off` with its pending and held files and its last outcome, and exits 1 when
a directory is overdue (§5), when two listed directories overlap, or when a
directory that is due lies on a storage root not given with `--root`. The
third test is skipped, and says so, when no `--root` is given. Held files do
not make it fail: read them (§9). Schedule it and alert on it, as for
`backup_lab.py --check`. Exit 0 means none of this; 2 is a usage or
connection error.

### 10.3 `scan` and `apply`

The reviewed path: for what an unattended run holds, and for a first look at
a tree. A person reads a plan, and `apply` writes exactly that plan.

```
python tools/import_nas_files.py scan --root NAME=PATH ... --directory ID ... --out DIR
                                      [--overrides FILE] [--cache-file FILE]
python tools/import_nas_files.py apply PLANFILE --root NAME=PATH ...
                                      [--only GROUP_KEY ...] [--dry-run] [--log-file FILE]
```

**`scan`** reads the named directories (in any mode; name a directory and the
one it is paired with together, so that a pair is judged together) and the
database. It writes **nothing** to the NAS, the database or the cache file
(`--cache-file` is read, never written), and it makes no `lab.scan_run` row.
It reads to their end the files an action would write (SHA-256; an ePsych
`.mat` is also checked structurally). It does not wait: whether the files
are old enough is decided by `apply`. `--directory` (at least one), `--root`
and `--out` are required. Into `--out` it writes, named for the database's
clock in UTC (`plan_<yyyyMMddTHHmmssZ>`):

- `.jsonl`, the plan: one JSON line per directory, held file and group, and
  an end line holding a SHA-256 of every line before it, so that an edited or
  truncated plan is refused;
- `.csv` and `.txt`, the report to read, with the columns of §9.1. For a group
  `action` is what the plan does with it; for a file it is the file's state.

A group's action:

| Action | What `apply` writes |
|---|---|
| `register` | A new session (unless it exists), the event and its detail row, one artifact per new file. |
| `add_files` | New files on the group's event, which is there with the same digest. |
| `attach_copy` | The group's files are added to an event another client registered; no event or session is made. |
| `correct` | The event is there with another digest. A new event supersedes it (the report lists each changed value, old and new), the event's inputs are carried, each active artifact of the old event is superseded by a row of the new one, tags are copied, and the database carries variables. |
| `move_session` | A `correct` whose only change is the session: a recording arrived for an ePsych session registered on its own. The session it leaves stays and gets a note. |
| `none` | Nothing to do. |
| `wait`, `held` | Not carried out; the reason code and the sentence say why. `wait`: a paired session whose recording is neither registered nor in this plan, so scan both directories together. |

A file in a group the plan acts on is `new`, `replace` (other bytes at a
registered path: a new artifact, and the old file is recorded `replaced` by
it), `known` (registered already with these bytes: a memory row and an `ok`
check), `registered` (unchanged, nothing written) or `held`. A correction to
another subject cannot reuse the session: the old session is moved aside
(its path gets the suffix `#superseded-by-<new session id>` and a note) and a
session of the new subject takes the path.

**`apply`** carries out the groups whose action writes something, each in
one transaction, and refuses a group, writing nothing for it, unless:

- the plan is as it was written (its digest matches), has the format this
  version reads, and was made against this database;
- every listed file of the group has the size and modification time the plan
  recorded. **The files are not read again**; the verification rows carry
  the time of the scan's read;
- the plan's listing of the directory is at least the directory's
  `min_age_min` old;
- the database is as the scan found it: the event, the artifacts at the
  group's paths, the sessions and the active artifacts of the event being
  corrected.

A refused group is reported and the others go on. `--only GROUP_KEY`
applies one group (repeatable). `--dry-run` makes every check and writes
nothing. A paired ePsych session is applied after its recording, which the
plan lists first. A run is recorded in `lab.scan_run` with command `apply`
and no `due_at`, so it never moves the schedule, and its result is `ok`, or
`failed` when a group was refused. Run it as the scanner login or the owner.

Exit status of `scan`: 0; 1 when a directory could not be listed
completely (it is not planned); 2 on a usage or connection error. Of
`apply`: 0; 1 when a group was refused; 2 on a usage or connection error,
including a plan that cannot be used and a login that may not write the scan
logs.

## 11. The header cache

`--cache-file` names a JSON file in which `run` keeps the header results of
registered files, so that they are not opened again every time. It is an
optimisation only:

- A missing, unreadable or malformed cache loads as empty, and every file
  not in it is read exactly as without one.
- An entry is trusted for the key it was stored under (storage root, path,
  size, modification time) and for nothing else. A file whose bytes changed
  while its size and modification time did not would be answered from the
  cache. That is the same assumption under which registered files are not
  read again at all.
- Only the entries of files whose registration is confirmed are used or
  kept. An entry that is damaged, hostile, or written by an older reader is a
  miss. The file is replaced atomically, so its folder must exist.
- Nothing in it decides what is registered: no hash and no database row
  comes from it.

Delete the file at any time.

## 12. Layouts

A layout is a module of the tool that turns a directory tree into **groups**
(one session and one event each, with its files). `lab.scan_layout` lists
the layouts the tool implements: `epsych` and `intan`. The walker lists the
tree; a layout only interprets the listing.

### 12.1 `epsych`

Tree: `<directory>/<subject folder>/<files>`, no deeper folders.

| Name | Becomes |
|---|---|
| `<SUBJ>_<yyMMdd>T<HHmmss>[_<suffix>].mat` | Behavior data, start to the second. A suffix is one run of letters and digits (`_psych`, `_delay`). |
| `<SUBJ>_<dd-Mon-yyyy>[_A\|_B].mat` and `<SUBJ>_<yyMMdd>.mat` | Behavior data, date only. |
| `<stem>.ts`, `<stem>-<n>.ts` | A session video, where `<stem>` is the stem of one of the session's `.mat` files or `<SUBJ>_<stamp>`. |
| `<stem>_conv.mp4` | A converted video of `<stem>.ts` of the same folder. |

- `<SUBJ>` is any run of characters without `_` or white space. A subject id
  that contains `_` is not recognised: its files are held
  `unrecognised_name` (§13).
- Name first, then content. A `.mat` file must be MAT 5.0 with the top-level
  variables `Data` and `Info`; the trial count is the number of elements of
  `Data`, read from the variable's header. A `.ts` file must show MPEG-TS
  sync bytes at the start of its first packets.
- Files sharing the subject (as spelled) and the date or time text are one
  session and one event: the twin files `_psych`, `_delay` and so on, and the
  videos. Their trial counts must agree. The session's identity never
  depends on which files exist, so adding a twin or a video later changes
  neither the session, the event, the label nor the digest.
- Session: `label` is the base stem `<SUBJ>_<stamp>`; `relative_path` is
  `<directory>/<subject folder>/<SUBJ>_<stamp>.mat` whether or not that plain
  file exists (unless it is paired: it then joins the recording's session).
  Event: `behavior`, with `trials_completed`.
- Artifacts: a `.mat` is role `raw`, format `mat`, attributes
  `{"kind": "epsych"}`; a `.ts` role `video`, `{"kind": "video"}`; a
  `_conv.mp4` role `video`, `{"kind": "video_converted", "converted_from":
  <path>}`. Every artifact also holds `source_mtime`, the modification time
  as listed.
- A member held for a reason that depends on the moment (`unreadable_file`,
  `changed_during_scan`) holds the whole session: what could be read at that
  moment must not decide it.

### 12.2 `intan`

Tree: `<directory>/<subject folder>/<name>_<yyMMdd>_<HHmmss>/<files>`. A
**recording folder** is a folder directly under a subject folder with a name
of that form. It is registrable when it holds at least one `.rhd` file
directly in it (compared without regard to case).

- **Every** file in the folder, recursively, belongs to the recording: one
  session, one `recording` event, and one artifact per file, role `raw`,
  attributes `{"kind": "raw", "reader": "intan"}` plus `source_mtime`.
  `settings.xml` and a `_manifest.json` written later by a lab tool are
  included. A zero-byte file other than an `.rhd` is held alone.
- Session: `label` is the folder name, `relative_path` the folder,
  `started_at` from the name and `ended_at` that plus the duration. Event:
  `acquisition_system_code` `intan_rhx`, `modality` `ephys`, and from the
  `.rhd` headers `sample_rate_hz`, `n_channels` (enabled amplifier channels)
  and `duration_s` (the sum of each file's samples over the sample rate,
  exact).
- Held: files directly in the listed directory or in a subject folder; a
  folder of another name; a recording whose `.rhd` files cannot be read or
  disagree; an `.rhd` in a subfolder; an `info.rhd` (split format). A link,
  a special entry or an unstorable name anywhere in a recording folder holds
  the whole recording.
- Not read: the timestamps inside the data blocks. Gaps and resets of the
  acquisition clock are not detected: the duration is samples over rate.

### 12.3 Adding a layout

A layout is a module `tools/nas_import/layouts/<name>.py` with a function
that turns a listing into groups, held items and reported items, registered
in `tools/nas_import/layouts/__init__.py`, and a row in `lab.scan_layout`
inserted by the schema's owner:

```sql
INSERT INTO lab.scan_layout (code, label) VALUES ('newlayout', 'Label shown in the dialog');
```

The module and the row arrive together: a row without its module names a
layout nothing can read, and a module without its row cannot be chosen.
Pairing is defined only for `intan` with `epsych`. Each new layout needs its
own tests (`tests/check_nas_import_parsing.py`).

## 13. Limits and what is not verified

- **No file from the lab's NAS has been read by this code.** The `.rhd`
  header reader is a port of `parseIntanHeader.m`, checked against the Intan
  RHX writer's source and its own reader, and tested against headers built
  in the tests from that format. The MAT reader is tested against
  files written by scipy. Neither has met a real recorded file. The first use
  on real data follows the staging procedure below.
- **Windows and SMB.** The tool runs on Linux in CI. Reading a UNC path, the
  treatment of reparse points, and the way a share reports sizes and
  modification times on Windows have not been exercised there. The
  scheduled-task definitions are not verified either.
- **Recordings at 30 kS/s or 15 kS/s are held** (`rhd_duration_inexact`):
  the duration has no finite decimal for most block counts, `duration_s` is
  a numeric column, and the tool never rounds. The usual 25 kS/s is exact.
- **A subject id containing `_` is not recognised** in ePsych names or in
  Intan folder names.
- **Pairing compares wall-clock times**, as `findCopySessions.m` does. Across
  a daylight-saving change the comparison is off by the hour that changed.
- **The wait is counted from the start** of the earlier run (§6.3).
- **Date-only ePsych sessions are never paired** and get a session of their
  own.
- Only `.mat`, `.ts`, `_conv.mp4` (ePsych) and recording folders (Intan) are
  recognised. Other files are held. RIG1, RIG2, Open Ephys, TDT, miniscope
  and the folders beside `Data` have no layout yet.
- What is inside an ePsych file beyond the trial count (protocol, box, notes)
  is not read.

**First use on real data** (the procedure of `plans/nas-file-registration.md`,
Part 4; not yet carried out):

1. Restore a backup into a new database (`tools/restore_lab.py`) and work
   there. The subjects must exist first: the tool never creates one.
2. Register the storage root, put its marker on the NAS, add the directories
   in `report` mode and run them by hand (`run --now --dry-run`, then
   `run --now`), or make a plan with `scan`, which writes nothing. Read the
   reports and the held files with the lab, and settle them in the overrides
   file.
3. Check the three points where ephys_analysis meets these rows, by copying
   sessions with it: a paired session is recognised as a copy and no second
   recording event appears; an ePsych event with two `raw` twins and a video
   is still recognised; an unpaired ePsych copy takes the importer's
   file-path session without error. If one fails, adjust the mapping before
   anything is written to production.
4. On production, add the directories in `report` mode, read the first
   reports, then switch to `register`. The first run reads every file once;
   later runs read only new files.
5. After a week, compare the counts of each directory with an independent
   listing: registered, known, pending, held, reported and ignored files add
   up to the files on disk.
6. `tools/verify_artifacts.py --root NAME=PATH` reports every registered file
   `ok`, and `lab.fn_check_integrity()` shows nothing new.
