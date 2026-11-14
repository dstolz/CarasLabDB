# MATLAB checklist: what CI runs, and what still needs a person

The MATLAB class (`@CarasLabDB`) and GUI (`@CarasLabDBApp`) were extended for
pre-launch schema versions 4 and 5 in an environment that had no MATLAB. Since then the
test suite in `tests/matlab` has been run **in MATLAB, in CI**: R2024b, R2025a
and R2026b on Linux, against PostgreSQL 16, all tests passing
(`.github/workflows/tests.yml`, job `matlab`). That first execution found and
fixed problems in the test fixture, in the GUI tests, and in how the class
uses transactions
([matlab-database-toolbox-notes.md](matlab-database-toolbox-notes.md)).

What this does **not** establish:

- **Nothing has been run on Windows**, which is what the lab uses. The suite
  and the fixture are written for both, but only the Linux half has been
  exercised.
- **Most of the GUI is not covered by automated tests.** `TagGuiTests` drives
  the browse filters, the tag editor and the variables editor. The forms, the
  change preview, the retract dialog, the daily husbandry grid, the integrity
  window, the login dialog and export are untested by any machine.
- **Real keys are not pressed.** `matlab.uitest` has no key-press gesture, so
  shortcuts are tested by calling the window's `KeyPressFcn`.

So: run the suite once on a lab workstation, then work through the manual
items below against a scratch database before anyone relies on the GUI.

```matlab
addpath(pwd)                       % repository root
results = runtests("tests/matlab") % see testing-locally.md section 2.7
```

A failure in any item below is a bug to report, not something to work around.

(GNU Octave cannot run this code. `python tests/check_matlab_syntax.py`, also
in CI, only parses every MATLAB file with it, which catches syntax errors and
nothing else.)

## 1. Class (`@CarasLabDB`)

Covered by the tests that pass in CI on Linux; the test is named where one
item maps to one test:

- The class loads; constructor checks (`TagTests/constructionChecks`).
- `fileChecksum` for `'abc'`, an empty file and an 8 MiB + 5 byte file
  (`VariableTests/fileChecksumMatchesKnownHashes`).
- `addArtifactFromFile`: relative path, size, checksum, and a file outside
  the root (`VariableTests/artifactFromFileWorksOutPathSizeAndChecksum`,
  `artifactFromFileIsRegistered`).
- The person comes from the login (`VariableTests/personComesFromTheLogin`,
  `personComesFromTheLoginOnTheServer`).
- Variables: set, update, unset, history, units mismatch, definitions, name
  canonicalisation (`VariableTests`).
- Retraction, including the required reason (`VariableTests`).
- `addHusbandryBatch`: all-or-none, validation before writing.
- Corrections: files move with the event, inputs and tags are carried,
  variables are carried once, a failure leaves nothing behind (`TagTests`,
  `VariableTests/correctionCarriesVariablesOnce`).
- `Clear=` on updates, and setting and clearing the same column.
- Tag filters, including a mistyped token.
- Transactions: atomic on failure, refused inside a caller's transaction, and
  not half-committed when the driver retries a statement
  (`TagTests/retriedStatementCannotHalfCommit`).
- `runReadOnlyQuery` refuses a write.
- `examples/carasLabDB_demo.m` runs end to end with no warning.

Still to do by hand, on Windows:

- [ ] **Run the suite** on a workstation, with and without
      `CARASLABDB_MTEST_ADMIN`. It has never run on Windows.
- [ ] **`fileChecksum` on a real recording.** Hash one and compare with
      `certutil -hashfile <file> SHA256`. A wrong hash here would register
      wrong checksums, so do not skip it.
- [ ] **Windows path case.** Register a file typed in the wrong case
      (`z:\DATA\...\raw.dat`) and check `info.relative_path` has the on-disk
      spelling. A mapped drive against a UNC `RootPath` should raise
      `fileNotUnderRoot`.
- [ ] **Schema check against a real older database.** Against a version-4
      database the constructor errors with
      `CarasLabDB:schemaVersionMismatch`; with `AllowSchemaMismatch=true` it
      warns instead. (CI checks this with a fake connection only.)
- [ ] **`addHusbandryBatch` input types.** String, cellstr and categorical
      `subject_id` columns all work.

## 2. GUI (`@CarasLabDBApp`)

`TagGuiTests` passes in CI: the Tags filter on each browse tab, a malformed
or unknown token, Clear, the remembered filter, the tag editor (add, set,
remove, policy refusals, its shortcuts through `KeyPressFcn`), the toolbar and
shortcut list, row actions without a selection, quick search, the Exact date
filter, the events tab's `recorded_login` column, `parseNumber`, and the
variables editor writing only on Save. Everything else below has been checked
by nobody:

- [ ] `runtests("tests/matlab/TagGuiTests.m")` passes on Windows.
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
