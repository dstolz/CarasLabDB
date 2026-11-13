# MATLAB first-run checklist

The MATLAB class (`@CarasLabDB`) and GUI (`@CarasLabDBApp`) were extended for
schema versions 4 and 5 in an environment that had **no MATLAB**. The SQL each
method generates was run against PostgreSQL, and the files were checked by
reading and by a structural check (balanced blocks, declared methods), but
**none of the MATLAB code has been executed**. Work through this list on a
workstation, against a scratch database, before anyone relies on it.

Set up the scratch database as in [testing-locally.md](testing-locally.md),
then:

```matlab
addpath(pwd)                       % repository root
results = runtests("tests/matlab") % with and without CARASLABDB_MTEST_ADMIN
```

A failure in any item below is a bug to report, not something to work around.

## 1. Class (`@CarasLabDB`)

- [ ] **The class loads.** `methods CarasLabDB` lists the methods, and
      `CarasLabDB.fileChecksum(f)` resolves (it is declared in a
      `methods (Static)` signature block).
- [ ] **`fileChecksum` is right.** `VariableTests/fileChecksumMatchesKnownHashes`
      passes (`'abc'`, an empty file, an 8 MiB + 5 byte file). Then hash one
      real recording and compare with `certutil -hashfile <file> SHA256`. This
      depends on MATLAB passing `uint8` to Java bit-for-bit and on
      `typecast(digester.digest(), 'uint8')`; a wrong hash here would register
      wrong checksums, so do not skip it.
- [ ] **`addArtifactFromFile` paths.** `info.relative_path` is correct for a
      file under the storage root, including a `RootPath` with a trailing
      separator; a file outside the root raises `fileNotUnderRoot`.
- [ ] **Windows path case.** Register a file typed in the wrong case
      (`z:\DATA\...\raw.dat`) and check `info.relative_path` has the on-disk
      spelling. A mapped drive against a UNC `RootPath` should raise
      `fileNotUnderRoot`.
- [ ] **Driver return types.** `value_num` comes back as double with `NaN`
      for NULL; NULL uuid/text columns (`superseded_by`, `value_text`,
      `units`) as missing strings; `is_current` / `is_retracted` work with
      `logical()`; the ids returned by `setVariable` and `retractEvent` are
      doubles.
- [ ] **Person from the login.** With the login mapped in
      `lab.person.db_login`, `CarasLabDB(...)` with no person argument
      constructs without a warning and `db.CurrentPersonId` is that person
      (`VariableTests/personComesFromTheLoginOnTheServer`). With an unmapped
      login it warns `CarasLabDB:noCurrentPerson`.
- [ ] **Schema check.** Against a version-4 database the constructor errors
      with `CarasLabDB:schemaVersionMismatch`; with `AllowSchemaMismatch=true`
      it warns instead.
- [ ] **Variables.** `db.setVariable("session", id, "Probe Depth", 1200,
      Units="um", Label="Probe Depth")`, then `db.setVariable(..., 1350.5)`,
      then `db.getVariables("session", id)` shows 1350.5 and
      `History=true` shows both. `setVariable(..., 71.9)` stores the text
      `71.9` (`VariableTests/setUpdateUnsetAndHistory`). A value in other
      units is refused by the database.
- [ ] **`normalizeVariableName`.** `"  Probe   Depth "` becomes
      `"probe depth"`; `"Bad!Name"` is refused locally.
- [ ] **Retraction.** `db.retractEvent(id, "entered twice")` removes the event
      from `getEvents()`; `getEvents(ActiveOnly=false)` shows it with
      `is_retracted` true. A blank reason raises `CarasLabDB:reasonRequired`.
- [ ] **`addHusbandryBatch`.** A table of three animals writes three events in
      one transaction; a table with one unknown subject writes none, and
      `AutoCommit` is back on afterwards. String, cellstr and categorical
      `subject_id` columns all work.
- [ ] **Corrections.** `supersedeEvent` moving an event to another session
      moves its files with it; `add*Event(..., Supersedes=old)` carries inputs
      and files; `CarryInputs=false` does not copy inputs. Variables on the old
      row appear on the new one (the database copies them).
- [ ] **Edits.** `updateSubject(id, Clear="notes")` sets notes to NULL;
      setting and clearing the same column raises `CarasLabDB:clearAndSet`.
- [ ] **Tag filters.** `getArtifacts(NotTags="qc:fial")` raises
      `CarasLabDB:tagFilterProblem`.
- [ ] **Demo.** `examples/carasLabDB_demo.m` runs end to end with no warning
      (`TagTests/demoScriptRunsEndToEnd`).

## 2. GUI (`@CarasLabDBApp`)

- [ ] `runtests("tests/matlab/TagGuiTests.m")` passes.
- [ ] **Every form opens:** Add Subject, Add Session, Add Event (type picker,
      then form), and Edit on a subject, a session and an event.
- [ ] **Change preview.** Edit a subject's strain and clear its notes, then
      OK: one confirmation lists the old and new strain and "Notes … (cleared)"
      on separate lines, over the still-open form. "Go back" returns with the
      edits intact; "Save" writes and closes. Same for a session and an event
      correction.
- [ ] **Errors keep the form.** Add a subject whose id exists: the database
      error is shown and the form stays open. Pressing OK or Enter twice
      quickly creates one row, not two.
- [ ] **No-op correction.** Supersede an event without touching the form:
      "No changes to save", and no new event row.
- [ ] **Sorted tables — the important one.** Sort a browse table by a column,
      click a row, then press Ctrl+D, Ctrl+T, Ctrl+L and Ctrl+Delete: each
      window must name the row that was clicked. If instead the app says the
      row "could not be identified", that is the fail-safe; press Refresh to
      clear the sort. It must never open a different row.
- [ ] **Shortcuts reach the window.** Ctrl+L, Ctrl+H, Ctrl+I and Ctrl+Delete
      work when no text box has the focus; Ctrl+? lists them.
- [ ] **History view.** Untick "Active only" on Events and Artifacts: the
      columns `superseded_by`, `is_current`, `is_retracted` appear, superseded
      and retracted rows are grey, and filters still work.
- [ ] **Variables editor (Ctrl+L).** Selecting a variable fills the value box;
      type and units show as e.g. "number · um"; saving `7,5` on a number
      variable is refused; saving the current value again writes nothing;
      History lists every earlier value; New… defines and sets in one step.
      Typing a value and then clicking Close, the list or the Note box writes
      nothing.
- [ ] **Retract (Ctrl+Delete).** An empty reason is refused. After retracting,
      the row leaves the active view. Edit / Supersede on a retracted row
      offers to restore it.
- [ ] **Daily husbandry (Ctrl+H).** Typed cells keep their text: `71,9` stays
      `71,9` and turns red — it must not become 719 or NaN. With a cell still
      being edited, Save commits it before the summary. The summary lists
      every row; after Save there is exactly one husbandry event per filled
      row, with the chosen date and time in local time. With a subject's
      `baseline weight` variable at 80 and a weight of 60 at an 85% threshold,
      the cell turns amber and the summary says "BELOW 85%".
- [ ] **Integrity (Ctrl+I).** Opens non-modal, errors on top; a second Ctrl+I
      brings the same window forward; closing the main window closes it.
- [ ] **Login.** With a mapped login and a blank email there is no prompt and
      the status bar shows the person. With an unmapped login and a blank
      email the "No person set" confirmation appears, and "Go back" leaves no
      open connection.
- [ ] **Tag filter typos.** `-qc:fial` gives an "Invalid filter" alert and
      leaves the table unchanged.
- [ ] **Number entry.** Any number field refuses text containing a comma.
- [ ] **Date filters.** A Range of `2026-07-01` to `2026-07-02` on a
      timestamp column includes all of July 2.
- [ ] **Export.** With more than 5000 matching rows the status says the result
      is capped and Export warns; Cancel after editing the variable name
      exports nothing; an existing workspace variable is not overwritten
      without asking.
- [ ] **Dialogs render line breaks** as separate lines (shortcut list, change
      preview, husbandry summary).

## 3. Known limits to keep in mind

- `fileChecksum` needs the Java virtual machine (the normal desktop MATLAB).
- `normalizeVariableName` treats only ASCII whitespace as space; a name
  containing a non-breaking space is refused locally where the database would
  have accepted it.
- Moving an event that has no session to another subject fails, and rolls
  back, if one of its files is filed under a session of the old subject:
  correct the file first.
