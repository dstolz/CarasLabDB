# Register the existing files on the Synology NAS in the `lab` database

## Context
The lab's raw data already sits on the Synology share (`S:` = `\\carassynology.resource.dyn.umd.edu\homes\Caras Lab`), but the database knows none of it. This plan adds a tool that walks a list of prespecified directories, works out what each file is, and registers it: a session, the recording or behavior event that produced it, and one `lab.artifact` row per file with its SHA-256.

The backups keep growing, so the tool has to be safe to run again: it writes only what is new and reports everything it did not understand. Registration is permanent (`artifact` and `event` are append-only, and a file's first row can never be entered twice, even after a retraction), so **anything uncertain is held and reported, never guessed**.

It depends on the master-log migration (`plans/master-log-migration.md`): subjects must exist before their files can be registered. The importer never creates a subject.

`plans/nas-auto-scan.md` builds on this plan: it moves the list of directories into the database, adds the unattended `run` and `check` commands, and changes four points here. Each is marked "Amended" below.

### What the profile found (read-only, 2026-11-17, RIG3 only)
- **`S:/RIG3_Backup_2025/epsych_files/Data`**: 2,475 files, 14.6 GiB, layout `Data/<SUBJ>/<files>` with no deeper folders.
  - 60 subject folders `SUBJ-ID-<n>`, plus `TEST`, `TEST_SUBJECT`, `SUBJ-ID-TEST` and `videos`.
  - 2,343 `.mat` (all MATLAB 5.0, none v7.3), 107 `.ts` session videos, 24 `_conv.mp4` conversions of them.
  - Three name formats: `<SUBJ>_<yyMMdd>T<HHmmss>.mat` (from 2026-03-07), `<SUBJ>_<dd-Mon-yyyy>[_A|_B].mat` (421 older files) and `<SUBJ>_<yyMMdd>.mat` (2 files).
  - Suffixed files (`_psych`, `_delay`, `_rand`, `_SI`) usually have an un-suffixed twin with the same timestamp and size.
  - About 617 `.mat` are 400 bytes or smaller (211 of them in `TEST`).
  - 16 `.ts` videos have no `.mat`; two `.ts` are zero bytes.
  - Stray files in real subject folders: `test.mat`, `test3.mat`, `SUBJ-ID-TEST.mat`, `SUBJ-ID-TEST-2.mat`.
- **`S:/RIG3_Backup_2025/intan_files/Data`**: 1,334 files, 191.3 GiB, layout `Data/<SUBJ>/<name>_<yyMMdd>_<HHmmss>/<files>`.
  - 9 subjects, all also in the epsych tree. 120 recording folders.
  - Every recording is Intan *traditional* format: `settings.xml` plus one `.rhd` per minute (RHX 3.5, 25 kHz, 64 or 32 channels). There are no `.dat`, `info.rhd` or sorting outputs.
  - 12 folders of SUBJ-ID-1255 also hold a `_manifest.json` written later by a lab tool.
  - Subject problems: `SUBJ-ID-1225/SUBJ-ID-1255_260709_095155` (the name says 1255, the folder and the timing say 1225) and `SUBj-ID-1278_261015_094835` (lower-case `j`). `settings.xml` names a stale subject in at least two folders, so it is not a source of the subject.
  - Not recordings: `Data/New folder` (empty), `Data/TEST_260619_144257`, `SUBJ-ID-1154/SUBJ-ID-1154_impedance_03182026.csv`, three `.DS_Store`.
- **Pairing**: an epsych file starts 1–5 minutes before its Intan recording and is saved just after it ends. Five recordings have no epsych file that day, and most epsych days have no recording.
- **The lab's own code already reads these trees.** `ephys_analysis` has both paths as defaults (`findCopySessions.m`), parses the same names, pairs recordings with epsych files, and registers its *local copies* through `LabCapture` / `LabSync` (being moved into this repository's `client/` folder, uncommitted). The importer has to produce rows those tools recognise.

### Decisions you made
| Topic | Decision |
|---|---|
| Storage roots | One root per rig backup folder: `nas-rig3` = `S:/RIG3_Backup_2025`. Paths are stored relative to it (`intan_files/Data/SUBJ-ID-1255/...`), so renaming the yearly folder changes only the mount setting. |
| What is registered | Every file under a real subject folder, including the tiny sessions, with the trial count read from the file. Test folders are reported, not registered. |
| Behavior-only sessions | Every epsych session gets a session row. A paired one joins its recording's session; an unpaired one gets a session whose path is the epsych file. |

## Part 1: Database changes
**No schema change for the data.** The existing tables hold every session, event and file. *Amended:* the list of directories, the run log and the scan memory are new tables (`plans/nas-auto-scan.md`, Part 1); the schema version stays 1.

**New rows, entered once by a lab member** (`lab_rw` may insert them):
- `lab.storage_root`: `nas-rig3`, described with the share path. `nas-rig1` and `nas-rig2` follow when those rigs are added.

**Mount paths** stay out of the database, as now. Scheduled runs use the UNC path (`deployment-windows.md` already says a mapped drive belongs to one signed-in user).

## Part 2: Interpretation and mapping

**Directories are rows of `lab.scan_directory`** (*Amended:* not a config file; the administrator keeps the list, `plans/nas-auto-scan.md`), each with the root it belongs to, a layout, a rig name, the time zone of its file names and a minimum age:

| root | path | layout | rig | pair_with | time_zone | min_age_min |
|---|---|---|---|---|---|---|
| `nas-rig3` | `epsych_files/Data` | `epsych` | RIG3 | | `America/New_York` | 1440 |
| `nas-rig3` | `intan_files/Data` | `intan` | RIG3 | `epsych_files/Data` | `America/New_York` | 1440 |

A layout is one module that turns a directory tree into *groups* (one session and one event each, with its files). The first pass implements `epsych` and `intan`.

**How a file is recognised** (name first, then content; a disagreement holds the file):

| Layout | Name or place | Content check | Becomes |
|---|---|---|---|
| epsych | `<SUBJ>_<yyMMdd>T<HHmmss>[_suffix].mat` | MAT 5.0 header with top-level variables `Data` and `Info` (the rule in `epsychSessionMeta.m`) | behavior data, start time to the second |
| epsych | `<SUBJ>_<dd-Mon-yyyy>[_A\|_B].mat`, `<SUBJ>_<yyMMdd>.mat` | same | behavior data, date only |
| epsych | `<stem>.ts`, `<stem>-<n>.ts` | MPEG-TS sync byte | session video |
| epsych | `<stem>_conv.mp4` | — | converted video |
| intan | folder `<name>_<yyMMdd>_<HHmmss>` directly under a subject, holding at least one `.rhd` | `.rhd` magic `0xC6912702` | one recording; **every** file in the folder, recursively, belongs to it |
| any | `.DS_Store`, `Thumbs.db`, `@eaDir`, `#recycle`, `_gsdata_`, `~$*` | — | ignored, counted in the report |
| any | anything else | — | held and reported |

- **Trial count**: the number of elements of `Data`, read from the MAT file's variable headers by a small standard-library reader (it decompresses only the start of each variable). A v7.3 file is held.
- **Recording header**: sample rate, amplifier channel count and duration come from the `.rhd` headers and file sizes, a port of `@IntanReader/parseIntanHeader.m`.
- **Subject**: the level-1 folder name, which must be an existing `lab.subject` row.
  - A name prefix that differs only in case is accepted and reported.
  - A different subject in the name holds the group until an override names the subject.
  - **Overrides** are a reviewed CSV (`root, relative_path, subject_id or skip, reason`). The reason is stored on the event.
- **Pairing** uses the rule in `findCopySessions.m`: an epsych file is a candidate if it starts between 10 minutes before and 2 minutes after the recording, the closest wins, a rival within 30 s makes the group ambiguous (held), and recordings under 2 minutes are not paired. Date-only epsych files are never paired.

**Mapping**

| Source | Target | Notes |
|---|---|---|
| Intan recording folder | `lab.session` | `label` = folder name, `relative_path` = the folder, `started_at` from the name, `ended_at` = start + duration, `rig` from the config. |
| | `recording` event in that session | `acquisition_system_code` `intan_rhx`, `modality` `ephys`, `sample_rate_hz`, `n_channels`, `duration_s`. |
| Every file in the folder | `lab.artifact`, role `raw` | `format` = lower-case extension, attributes `{"kind":"raw","reader":"intan"}`, as `LabCapture.copiedSession` writes them. This includes `settings.xml` and `_manifest.json`. |
| Paired epsych session | `behavior` event in the recording's session | `trials_completed` from the file. |
| Unpaired epsych session | `lab.session` + `behavior` event | `label` = the file stem, `relative_path` = the epsych file, `started_at` from the name (NULL when only the date is known). |
| epsych `.mat` | `lab.artifact`, role `raw` | Attributes `{"kind":"epsych"}`. Files sharing a subject and timestamp are one session and one event. |
| `.ts` video | `lab.artifact`, role `video`, on the same behavior event | A video with no `.mat` is held. |
| `_conv.mp4` | `lab.artifact`, role `video` | Attributes `{"kind":"video_converted","converted_from":"<path>"}`. |

**Times**
- Names carry lab wall-clock time. The tool sends that text with `lab_time_zone` and lets PostgreSQL convert it, so it needs no time-zone database (Python on Windows has none in the standard library).
- A date-only name gives `occurred_at` = 12:00 on that date with `"occurred_precision":"day"`, as in the master-log plan.
- Each file's modification time is kept verbatim in the artifact's attributes (`source_mtime`). It is not used to derive an end time.

**Provenance on every event**: `attributes.import` = `{tool, layout, root, path, source_value, override?}`, plus `captured_by_tool`, `code_version` and `occurred_at_source` in the form `LabCapture` uses. `recorded_by` is the person running the import.

## Part 3: The importer, `tools/import_nas_files.py`
Python standard library plus psycopg, built like `tools/verify_artifacts.py`: `--root NAME=PATH` (repeatable, refuses an empty or unknown root), connection from the `PG*` environment. *Amended:* the login is `lab_scanner` (in `lab_rw`, with INSERT on the scan logs) or the owner, because `apply` also writes the scan memory.

**Two commands** (`plans/nas-auto-scan.md` adds the unattended `run` and `check`)
1. **`scan --directory <id> ... --out <dir>`** reads the NAS and the database and writes nothing to either. It produces a plan file (JSON lines: every group, file, size, modification time and SHA-256) and a report (CSV and text).
2. **`apply <plan file>`** writes exactly the reviewed plan. Before each group it checks every file's size and modification time again; a group that changed is refused and reported.

**Stages of a scan**
1. **Walk** each named directory. Symbolic links are not followed. *Amended:* a folder that cannot be listed fails the scan of its directory, and modification times no longer decide whether a group is complete: `apply` refuses a group whose sighting in the plan file is younger than the directory's `min_age_min`, so a session still being recorded or copied is never registered half-way.
2. **Interpret** with the layout module: groups, subjects, times, pairing, held items.
3. **Diff against the database**, so unchanged files are not read again:
   - *Amended:* a file whose latest row in the scan memory (`lab.scan_file`) is `registered` or `known` with the same size and modification time, and whose artifact is active and present, is unchanged;
   - everything else is hashed (4 MiB chunks, a few worker threads).
4. **Report** every insert, correction, held item and normalisation.

**What makes a re-run safe** (there is no SQL function for this; the logic of `@CarasLabDB/recordEvent.m` is reproduced)
- Ids are deterministic: `uuid5` of `session:<root>:<path>` and `event:<type>:<root>:<path>`.
- Each event stores a digest of its source values in `attributes.client_digest`. The tool's version is not part of the digest.
  - Same id and digest: nothing is written.
  - Another digest: a correction, following `@CarasLabDB/supersedeEvent.m` (new event and detail row with `supersedes`, each active artifact superseded by a row that points at the new event, tags copied; variables are carried by the database trigger).
- A file is looked up by (root, path, checksum) among original rows, as `recordEvent` does. A hit is reused.

**What happens when the NAS changes**
| Change | Action |
|---|---|
| New file in a registered folder | A new artifact on the existing event. The event is not touched. |
| Different bytes at a registered path | A new artifact plus a `replaced` disposition on the old one, flagged in the report: raw data should not change. |
| Registered file missing | Reported only. Recording a deletion is a person's decision (`addArtifactDisposition`). |
| A recording appears for a behavior-only session | A correction moves the behavior event into the recording's session. The file-path session stays, with a note, and is reported. |
| Recording already registered by `ephys_analysis` from a local copy | If every file's checksum is already a `raw` artifact of exactly one event, the NAS files are added to that event. Several events: held. |

**Verification rows**: each newly registered file gets an `artifact_verification` row with status `ok`, since the tool has just read and hashed it. Otherwise every file would show as `artifact_never_verified`.

**Safety**
- Never writes, renames or deletes anything on the NAS. If a root has a `.caraslabdb-root.json` marker naming another root, the run is refused.
- Never creates a subject, never deletes a row, never writes the `*_login` columns.
- Each group is one transaction, so a session is registered whole or not at all, and an interrupted run continues where it stopped.

**Tests**: `tests/check_import_nas_files.py`, run in CI on a scratch database the way `check_verify_artifacts.py` is.
- Parsing without a database: the three epsych name formats, the Intan folder name, the MAT variable reader, the `.rhd` header, the pairing rule.
- A fixture tree built in a temporary folder covering each anomaly above: a twin file, a tiny session, an orphan video, a zero-byte file, a mislabelled folder with and without an override, a case variant, a test folder, a stray file, a too-young group.
- It asserts that a first `apply` registers, a second scan plans nothing, an added file gives exactly one artifact, a changed file one artifact and one `replaced` row, and a late recording exactly one correction.

**Docs**: a short guide `design_docs/nas-import.md`, the `tools/` entry in CLAUDE.md, and a scheduled-task example in `deployment-windows.md`.

## Part 4: Procedure
1. The master-log migration is applied first, on staging and then production.
2. On a staging copy (`tools/restore_lab.py` into a new database): insert `nas-rig3`, run `scan`, and review the report with the lab. Settle the held items in the overrides file.
3. Before production, check the three points where `ephys_analysis` meets these rows, on staging, by copying sessions with `copySessions`:
   - a paired session is recognised as a copy (`LabSync.copyOf`) and no second recording event appears;
   - an epsych event with two `raw` twins and a video is still recognised;
   - an unpaired epsych copy takes the importer's file-path session without error.
   If one fails, the mapping in Part 2 is adjusted before anything is written to production.
4. `apply` on production. RIG3 is 206 GiB to read once; later runs read only new files.
5. Run it on a schedule (for example nightly) while the rigs keep backing up.
6. Further directories are added one at a time: profile it read-only, write or reuse a layout, extend the config.

**Not in the first pass**
- RIG1 and RIG2, and RIG3's `openephys_files`, `behavior_videos` and `noise_exposure_files`. TDT Synapse, Open Ephys, miniscope and MABR data each need their own layout.
- The folders beside `Data` (`Configs`, `Protocols`, `Calibrations`, `Rosters`, `RPvds_Circuits`, `ProbeMap`) and `ANALYSIS_BACKUPS`.
- What is inside an epsych file beyond the trial count (protocol, box, notes). These can be added later as variables on the event without a correction.
- Tags such as `stage:raw`. The role and `attributes.kind` already say it.

## Verification
- `tests/check_import_nas_files.py` passes on PostgreSQL 14–17, and `ruff check tools tests` is clean.
- After the RIG3 import, cross-checks against an independent listing of the two trees (`Get-ChildItem -Recurse -File`):
  - registered + held + ignored + too-young files = files on disk, per directory;
  - one session and one recording event per Intan recording folder under a real subject;
  - every artifact's `size_bytes` equals the file's size;
  - every registered subject is one of the 60 epsych and 9 Intan subject folders.
- `tools/verify_artifacts.py --root nas-rig3=<path>` reports every file `ok`.
- `lab.fn_check_integrity()` returns no new problems.
- A second `scan` on an unchanged tree plans 0 changes.
- Spot-check 20 random sessions, NAS against `session` + event + artifacts, including the mislabelled folder and one date-only file.
