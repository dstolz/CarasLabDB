# Migrate the "CarasLab Master Log" Google Sheet into the `lab` database

## Context
The lab's subject records live in the Google Sheet "CarasLab Master Log". The sheet ID is 1IXt471rU74BIis-T1LUcZjV8KystJ83JwCZDxp6Z8kY. The data should move into the `lab` schema. The sheet and the database will run in parallel for a while, and then the sheet will be frozen. The importer therefore has to be safe to run again: it writes only what is new or changed and reports every conflict.

Data fidelity is the priority:
- Every value is kept as typed.
- Nothing is invented.
- Anything the importer derives or normalises is listed in a report.

### What the profile found (read-only, 2026-11-15)
- **Master Animal Log**
  - 1376 animals. IDs run SUBJ-ID-1..1376 with no gaps or duplicates.
  - 199 litters, and all of them exist in the Breeding Log. Pair, litter number and DOB agree with the Breeding Log in 0 of 0 mismatches.
  - DOB is `YYYY-Mon-DD`. Date of Death is in that format except one value, `8/11/25` on SUBJ-ID-421.
  - 8 animals have a Date of Death but no Manner of Death.
  - SUBJ-ID-810 has the literal text `Protocol Number` in its protocol cell.
  - 206 animals have no Experiment. Experiment and Data Log # are always blank together.
  - `PNN In vivo` and `PNN IHC` are not in the Experiments tab. Their Data Log # is `#N/A`.
  - Some values have stray spaces: Experiment titles, Lab Member `Derrick Antwi `, and a Slide Box case variant `DId not save tissue`.
  - `Current Age` is a formula: 1376 of 1376 rows equal (DOD or 2026-11-15) − DOB.
- **Breeding Log**
  - 210 litters, LITTER-ID-1..210.
  - 11 litters have no animals in the Master log.
  - 17 litters have more animals than their `Number of Pups`.
  - `Date of Wean` is DOB + about a month (computed). Three of its values are in the future.
- **Breeder Pairs**: pairs A..FF, with dams BF-n and sires BM-n. None of them is a SUBJ-ID.
- **Derived tabs**: ALIVE, UNASSIGNED and Current Animal Counts are filtered or derived views of the Master log.

### Decisions you made
| Topic | Decision |
|---|---|
| Projects | Each Experiment becomes a project. Animals with no Experiment go into an `Unassigned` project (no schema change to `subject.project_id`). |
| Breeders | Imported as subjects. |
| Litters and pairs | Go into **new tables**. |
| Date of Wean | Stored verbatim as a *scheduled* wean date. No wean events are created. |
| Notes | Stored **verbatim only**. No events are parsed out of them. |
| Scope | Everything in the sheet is migrated, with variables on subjects where there is no column for a value. |

## Part 1: Schema additions
Pre-launch, so these go into `design_docs/schema.sql` at version 1.

**`lab.breeder_pair`**
- Columns:
  - `pair_code text PK` (`A`..`FF`)
  - `dam_subject_id` and `sire_subject_id`, as FKs to `lab.subject` with `ON UPDATE CASCADE`
  - `arrived_on date`, `retired_on date`
  - `notes text`, `created_at`, `created_by`
- CHECK constraints: dam ≠ sire, and `retired_on >= arrived_on`.
- The table is mutable and is added to the `fn_log_row_change` list in `row_history`.

**`lab.litter`**
- Columns:
  - `litter_id text PK` (CHECK non-blank and trimmed, as for `subject_id`)
  - `pair_code` FK
  - `litter_number int`, with `UNIQUE (pair_code, litter_number)`
  - `born_on date`
  - `n_pups int` (nullable, ≥ 0)
  - `scheduled_wean_on date`
  - `claimed_by uuid → person`
  - `notes text`, `created_at`, `created_by`
- The table is mutable and is in `row_history`.

**`lab.birth_event.litter_id`**
- Gets an FK to `lab.litter(litter_id)` with no cascade.
- Confirm that `fn_forbid_mutation`'s subject-rename hatch is unaffected: the subject-id columns are the only cascading ones.

**`lab.protocol`** (IACUC protocols)
- Columns: `code text PK`, `title`, `description`, `approved_on date`, `expires_on date`.
- It is a reference table: `lab_rw` may insert it, and it is in `row_history`.

**New `fn_check_integrity` check (16th): `birth_parents_disagree_with_litter`**
- Fires when a birth event's dam or sire differs from its litter's pair.
- Update the check count in `database-design.md` §4.2 and in CLAUDE.md.

**Supporting changes**
- `grants.sql`: `lab_rw` gets INSERT and UPDATE on `breeder_pair`, `litter` and `protocol`.
- `tests/schema_test.sql`: assertions for the constraints, the history triggers, the FK and the new check.
- `tests/roles_test.sql`: what `lab_rw` and `lab_ro` may do on the new tables.
- Read surfaces:
  - `mcp-server/src/caraslabdb_mcp/tools/` gets read tools `get_breeder_pairs`, `get_litters` and `get_protocols`.
  - `@CarasLabDB` gets `getBreederPairs`, `getLitters` and `getProtocols` (inline, small).
  - `web/live/lab_data.sql` and the `check_lab_data.py` shape check: arrays are added only if the dashboard is to show them. Leave this out in the first pass.
- Docs: `database-design.md` §3 (new tables), `overview.md` (entity list).

## Part 2: Mapping, sheet → database

| Sheet | Target | Notes |
|---|---|---|
| Personnel (34) | `lab.person` (`full_name` trimmed, `role` = Position) | `email` and `db_login` are left NULL; the admin adds them at onboarding. Names are matched case-sensitively after trimming. |
| Experiments (55) + `PNN In vivo`, `PNN IHC` | `lab.project` (`name` = trimmed title) | Data Log # goes into the project variable `data log number` (text: `N/A` and `#N/A` are kept verbatim). Projects for the 6 unused titles are created too. |
| — | `lab.project` `Unassigned` and `Breeding colony` | `Unassigned` holds animals with no Experiment. `Breeding colony` holds BF-n/BM-n. |
| Lab Member | subject variable `lab member` (verbatim) + `lab.project_member` (project, person, role `member`) per distinct pair | |
| Protocols (3) | `lab.protocol` | Dates are parsed from `June 26, 2019`. |
| Protocol Number | subject variable `protocol` (text) | SUBJ-ID-810's `Protocol Number` is treated as blank and reported. |
| Breeder Pairs | breeder subjects BF-n (F) and BM-n (M), species `meriones_unguiculatus`, in `Breeding colony`; then `lab.breeder_pair` | DOB and source are left NULL. The pair notes are kept verbatim; "CR" is not expanded. |
| Breeding Log (210) | `lab.litter` | `Claimed by` → person. `Date of Wean` → `scheduled_wean_on`. Pup count and notes are verbatim. `Current Age` is not imported. |
| Master: SUBJ-ID, Sex, DOB, Notes | `lab.subject` | `species_code` is `meriones_unguiculatus`, `source` is `bred_in_house`, and `notes` is verbatim (whitespace untouched). |
| Master: litter / pair / litter # / DOB | one `birth` event per animal | `dam_subject_id` and `sire_subject_id` come from the pair, and `litter_id` is set. |
| Master: Date of Death + Manner of Death | one `endpoint` event when the DOD is non-blank | `method` is the Manner verbatim, or NULL for the 8 rows without one. `tissue_collected` comes from the Slide Box: `Did/DId not save tissue` → false, `Box #`/`Fridge…` → true, blank → NULL. The rule is reported. |
| Marking | subject variable `marking` | |
| Slide Box | subject variable `slide box` (verbatim, case preserved) | |
| Housed with which non-littermates? | subject variable `housed with non-littermates` (verbatim) | It is not parsed: ranges like `208-211` are ambiguous. |
| Electrodes (5) | `lab.probe` (manufacturer = first word(s), `model`, `n_channels`) | The full verbatim string goes in `description`. |
| Viruses, Rigs | tag namespaces `virus` and `rig` (closed vocabulary) | Each tag's `description` holds the verbatim sheet string. |
| Markings, Manner of Death, Animal Sex, Slide Boxes | not imported | These are dropdown-validation lists. Their values arrive through the columns above. |
| ALIVE, UNASSIGNED, Current Animal Counts | not imported | Used as cross-checks after the import (see Verification). |
| Data Log #, Current Age | not imported per animal | Both are formula-derived from the Experiment and the dates. |

**Events from date-only values**
- `occurred_at` = 12:00 America/New_York on that date. Noon keeps the calendar date stable in any viewer's time zone.
- `attributes`: `{"occurred_precision":"day","import":{"sheet":"CarasLab Master Log","tab":…,"row":…,"source_value":"<verbatim date>"}}`.
- `recorded_by` = the person running the import.

**Provenance**
- The sheet is registered as a `lab.project_artifact` (kind `google_sheet`, with its URI) on the `Unassigned` and `Breeding colony` projects.

## Part 3: The importer, `tools/import_master_log.py`
Python standard library + psycopg, like `tools/verify_artifacts.py`. The connection comes from the `PG*` environment, as a member login in `lab_rw`. Reference rows (person, probe, protocol) need only INSERT.

**Input**
- A directory of per-tab CSV exports (File → Download → CSV). This keeps the tool free of the Google API.
- Every cell is read as text. Nothing passes through a float or an auto-parsed date.

**Stages**
1. **Parse and validate.** Strict date formats per column. Any value that cannot be parsed is an error, never a guess.
2. **Plan.** Compute the desired rows, using deterministic ids:
   - Events: `uuid5(NS, "birth:"+subject_id)` and `uuid5(NS, "endpoint:"+subject_id)`.
   - A digest of the source values goes in `attributes.client_digest`, as `recordEvent` does.
3. **Diff against the database.**
   - New → insert.
   - A mutable row that differs → UPDATE, recorded in `row_history`.
   - A variable that differs → `lab.fn_set_variable`. One that is unchanged is skipped, so the value log does not grow on every run. A cleared value → `fn_unset_variable`.
   - An event whose source values changed → a correction row (`supersedes`). The superseded endpoint is never touched.
   - A sheet row now missing a DOD that the DB has (e.g. SUBJ-ID-611-type cases) is reported, not retracted automatically. Retraction is a human decision with `fn_retract`.
4. **Report.** A CSV and a text summary of every insert, update, correction and normalisation:
   - trimmed names and titles;
   - the `8/11/25` date;
   - the SUBJ-ID-810 protocol cell;
   - pup-count shortfalls;
   - future scheduled-wean dates;
   - the unknown experiments;
   - the `tissue_collected` derivations.
5. **Apply.** `--dry-run` is the default and only produces the report. `--apply` writes everything in **one transaction** and rolls back on any error.

**Safety**
- Refuses to run if the schema version or the new tables are missing.
- Never deletes anything.
- Never writes the `*_login` columns.

**Tests**
- `tests/check_import_master_log.py`, with fixture CSVs covering each anomaly above. It runs against a scratch database in CI the way `check_verify_artifacts.py` does.
- It asserts that a first run imports, a second run writes nothing, and an edited row produces exactly one correction or update.

## Part 4: Cutover procedure
1. Merge the schema and the importer. Deploy them to a staging copy (a restore via `tools/restore_lab.py` into a new database) first.
2. Export the CSVs → dry run → review the report with the lab → `--apply` on production.
3. During the parallel run, re-export and run regularly (e.g. weekly). Only differences are applied.
4. Freeze: protect the sheet as view-only, do a final run, and archive the CSV exports plus the report on the NAS. Optionally register them as a `project_artifact` with a checksum.

## Verification
- `tests/schema_test.sql` and `tests/roles_test.sql` pass on PG 14–17. The MCP pytest suite and the MATLAB tests (new getters) pass.
- After the import, SQL cross-checks against the sheet:
  - 1376 + 64 subjects;
  - 210 litters and 32 pairs;
  - 1376 birth events;
  - endpoint count = 1227 non-blank DODs;
  - animals without an endpoint = ALIVE tab IDs;
  - `Unassigned` members = UNASSIGNED tab IDs (minus the dead);
  - the per-variable value counts match the sheet's per-column non-blank counts.
- `lab.fn_check_integrity()` returns no new problems.
- A second `--apply` on the same CSVs reports 0 changes.
- Spot-check 20 random animals field by field, sheet vs `lab.subject` + `variable_current` + events.
