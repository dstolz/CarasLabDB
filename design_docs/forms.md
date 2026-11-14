# Forms: entering session data in the browser

A form is a page for entering what happened in one session of one subject
(a daily check, a post-operative check, a recording checklist). Lab
members fill forms in in a browser. They build the forms themselves from
**templates** that any subject in any project can use. Every entry goes to
the database. For each subject in each project, a CSV file of all its
entries is kept up to date automatically.

- Server and page: `web/forms/` (`server.py`, `forms.html`, `forms.js`,
  `forms.css`, `csv_export.py`)
- Data model: [database-design.md](database-design.md) §3.9
- Deployment: [deployment-windows.md](deployment-windows.md) §3.6

## 1. Concepts

| Concept | What it is | Where it lives |
|---|---|---|
| **Template** | A named, reusable form: its fields, and what is shown at the top. Any subject in any project can use it. Editing it publishes a new **version**. Old versions never change. | `lab.form`, `lab.form_version` |
| **Subject form** | A template put to use for one subject in one project. By default the project is the subject's own, but a subject used in another project gets its forms there. It is pinned to the template version that new entries use. | `lab.subject_form` |
| **Entry** | One session's data on a subject form. It holds when the session happened, a free-text session label, the field values and a note. | an `observation` event (`lab.observation_event`), with its values as variables on the event |
| **Note** | One free-text note per entry. It can be changed after the entry is made, and every earlier text is kept. | the reserved variable `entry note` on the entry's event |
| **CSV file** | One file per subject per project. It has one row per entry, from all of that subject's forms in that project. | `<CSV root>/<project>/<subject>.csv` |

A session here is a label and a date and time. It does not need to be a
`lab.session` row, because those stand for a recording folder on the NAS.

An entry is an ordinary event:

- a correction supersedes it and keeps the old version;
- a withdrawal (`lab.fn_retract`) takes it out of use and keeps the reason;
- the dashboard, the MCP server and MATLAB see it like any other event.

Its values are ordinary variables ([variables.md](variables.md)), so each
field has one type and one set of units, and its history is kept.

## 2. Filling in a form

Open the page (`https://<server>/forms/` in the lab) and sign in with your
own database login, the one you use from MATLAB. Everything you enter is
recorded under that login.

1. **Subject.** Type part of its id in the subject box (Ctrl+K), then choose
   it with the arrow keys and Enter. The subject's forms appear, grouped by
   project. The page opens the one you used last, or the only one.
2. **No form yet?** Pick a template under *Add a form from a template*. Pick
   the project (the subject's own is preselected), then press *Add*.
3. **The top of the form** shows what the template's designer chose: the
   project, the subject's species, sex, age at the session, latest weight
   and % of its baseline, chosen variables, the previous entry, and so on.
   A subject with an endpoint event is flagged in red whatever the template
   says.
4. **Session date and time** starts at *now*, in your time zone. The
   **session label** follows it (`2026-11-14 09:30`) until you type your own.
   A label already used on this form is pointed out.
5. Fill in the fields. Required fields are marked `*`. A field can show
   the previous entry's value under it. Mistakes are shown when you leave
   the field: a number must be written plainly, see §5.
6. Write a **note** if you want one. It can be changed later.
7. **Save** (Ctrl+S). The entry goes to the database. If the server cannot
   be reached, the page keeps it (§7) and says so.

Under the form, **Entries on this form** lists the entries, newest first.
Each has these actions:

- **Correct** loads the entry back into the form. Saving it records a
  correction: the old version stays in the database, and the new one
  replaces it in the list and the CSV. A correction keeps the form version
  the entry was made on.
- **Note** (or Ctrl+E on a row that has focus) changes the note without a
  correction. **history** lists every earlier note, who wrote it and when.
- **Withdraw** removes an entry made in error, for example entered twice or
  on the wrong animal. It asks for the reason. The entry leaves the list and
  the CSV, and stays in the database with the reason. To change a value,
  use Correct instead.

Keyboard: Ctrl+S save (or publish, in the builder), Ctrl+K subject search,
Ctrl+E change the note of the focused entry, Alt+1/2/3 the three tabs, Esc
close, and Ctrl+? to list them all.

## 3. Building a template

*Templates → New template* (or *Edit*, or *Copy*).

- **Name**: lower-case words, such as `post-op check`. It never changes.
  **Label**: what people see. **Description**: optional.
- **Top of the form**: an ordered list of *info items* and *variables*.
  - Info items: project, project members, species, sex, strain, genotype,
    date of birth, age at the session, source, subject notes, subject tags,
    latest weight with % of baseline, endpoint status, last surgery, and the
    previous entry on this form.
  - Variables: any variable, shown from one of three places. `on the subject`
    and `on the project` show its current value there (for example a
    subject's `baseline weight`). `in the previous entry` shows the value of
    one of this form's fields in the subject's last entry on this form.
- **Sections** hold **fields**. Each field that takes a value has these
  settings:

  | Setting | Meaning |
  |---|---|
  | Widget | how it is entered (table below) |
  | Variable | the name the value is stored under (§4) |
  | Label | what the person filling in sees (default: the variable's label) |
  | Units | number fields only; fixed for the variable once it has a value |
  | Min / Max | number fields only, written as plain numbers |
  | Options | choice fields: one per line, `value` or `value \| label` |
  | Help | a line of help under the field |
  | Required | the entry cannot be saved without it |
  | Show the previous entry's value | under the field, while filling in |

  *+ Instruction* adds a paragraph of instructions, and a *Heading* widget
  adds a heading. Neither stores anything.

| Widget | Entered as | Stored as |
|---|---|---|
| Number | text box (`12`, `-3`, `0.25`) | number, exactly as typed |
| Whole number | text box (`12`) | number |
| Text (one line), Text (several lines) | text box | text, as typed |
| Choice | buttons (up to 5 options) or a list | the option's value, as text |
| Yes / no | two buttons | `yes` or `no` |
| Date | date picker | `YYYY-MM-DD` |
| Time | time picker | `HH:MM` |
| Date and time | date and time picker | `YYYY-MM-DDTHH:MM±hh:mm`, with the offset of the time chosen |

**Checks** lists every problem as you build; the server checks too. When
there are none, **Publish** (Ctrl+S) stores version 1, or the next version
of an existing template. Publishing an unchanged template stores nothing.
Publishing defines any new variables (§4).

**Versions.** A subject form keeps the version it was added with. When a
newer one exists, the subject's form shows *Use vN*. Entries already made
keep the version they were made on. A template or a subject form that is no
longer used can be **retired**: it leaves the pickers, and nothing is
deleted.

## 4. Fields are variables

Every field is stored under a **variable**: a named value with a fixed type
and fixed units ([variables.md](variables.md)).

- Typing a variable name that already exists reuses it. The builder shows
  its type and units, and they must match the field: a number widget for a
  number variable, the same units.
- A new name defines a new variable when the template is published. It
  holds numbers for number widgets and text for the others, in the field's
  units, and applies to events.
- Two templates that use the same variable fill the same column of the CSV,
  and their values can be compared. Use the same variable only for the same
  measurement in the same units.
- `entry note` is reserved for the note.

## 5. Values are kept exactly as typed

Each value travels from the page to the database as the text that was
typed, and is stored as that text. A number is stored as the decimal you
wrote, never converted to a floating-point number. So that this is possible
without changing what you typed, a number must be written in the one way
PostgreSQL gives back unchanged:

| Accepted | Refused, with the reason | Why |
|---|---|---|
| `12`, `-3`, `0.25`, `1350.50`, `0.000100` | `1e3`, `.5`, `+1`, `007`, `-0`, `1,5`, ` 12` | each refused form would come back written differently from how you typed it |

Trailing zeros are kept: `1350.50` is stored, shown and exported as
`1350.50`. Other rules:

- A value must be one of a choice's options.
- A whole number has no decimal point.
- A number must lie within the field's min and max.
- A date or time must exist, and a date and time carries its UTC offset.
- One-line text has no line breaks.
- A blank value is no value; a required field must have one.
- Text, and the note, may not start with `=` or `@`. A spreadsheet that
  opens the CSV would run such text as a formula. It is refused, not
  altered.

The page checks these as you type. The database checks them again
(`lab.fn_observation_problems`), so no client can store a value that breaks
them.

## 6. The CSV files

The server keeps one file per subject per project:

```
<CSV root>/<project name>/<subject id>.csv
```

| Columns | |
|---|---|
| `Entry ID` | the id of the entry's first version; it stays the same through corrections |
| `Event ID` | the current version's event id |
| `Subject`, `Project` | |
| `Form`, `Form version` | the template and the version the entry was made on |
| `Session label`, `Session time` | the time with its UTC offset, in the server's CSV time zone |
| `Recorded at`, `Entered by`, `Login` | when the current version was recorded, by whom, under which login |
| `Corrected` | `yes` when the entry has been corrected |
| `Note` | the current note |
| one column per variable | `name` or `name (units)`, in the order the subject's forms were added, then field order; a variable on two forms is one column |

There is one row per entry, ordered by session time. A cell is empty when
the entry has no value for that variable, including a field its form
version did not have. Values are exactly the text stored. The file is UTF-8
with a byte-order mark, so Excel reads it as UTF-8, and has CRLF line
endings.

**The file is rewritten from the database after every change**: an entry, a
correction, a note, a withdrawal. It always shows the current state; the
database keeps the history. A file is written to a temporary file in the
same folder and then moved into place, so a reader never sees half a file.

- **Open in Excel?** On Windows, Excel locks an open CSV. The entry is saved
  in the database anyway, the page says the file is waiting, and the server
  retries every minute until the file is closed (reading as the login in its
  `PG*` settings, `lab_forms` in the deployment; without one, at the next
  change to that subject).
- **Edited by hand?** The server remembers the SHA-256 of every file it
  wrote (`_manifest.json`). A file that differs is renamed
  `<subject>.edited-<UTC time>.csv`, never overwritten, before the new one
  is written. Copy a file before editing it.
- **Project renamed?** The old file moves to `_moved/<UTC time>/`.
- **Names that are not valid file names** are made valid: characters Windows
  forbids become `_`, reserved names such as `CON` get a leading `_`, and
  long names are cut. A name that had to change gets `~` and 8 hex digits of
  its hash added, so two names never share a file.
- **Rebuild everything** (for example after corrections made from MATLAB):
  `python web/forms/server.py --csv-root <root> --rebuild-csv` regenerates
  every file and leaves an up-to-date file untouched. The deployment runs it
  nightly.

A CSV file is a copy for analysis, not a record. It is not registered as an
artifact, because it is rewritten. MATLAB reads it with `readtable(file,
"VariableNamingRule", "preserve")`, which keeps the column names.

## 7. When the server cannot be reached

Every entry is first put in an **outbox** in the browser (IndexedDB), and
then sent. It leaves the outbox only once the server has confirmed it is in
the database:

- If the server cannot be reached, or the reply is lost, the entry stays in
  the outbox. The page says so, and resends it every 15 seconds to 2
  minutes, when the network comes back, when the page is shown again, and
  on *Send now*.
- Sending again is safe. The page gives the entry its id before the first
  send, and the database recognises an entry it already has (§9).
- An entry is sent only while its author is signed in. Entries of another
  login wait for that login.
- The **Unsent** tab lists what is waiting. *Download (JSON)* and *Download
  (CSV)* save a copy.
- The page warns before you close it while anything is unsent.
- Note changes go through the outbox too. Withdrawing an entry needs the
  server.

The outbox lives in that browser on that computer. Clearing the browser's
site data deletes it. In a private window, the page warns that nothing
survives closing it.

**Not yet:** while the server is down, the page cannot be *opened* (a
service worker would allow that), and entries cannot be imported from a
downloaded file. Both are planned.

## 8. Security

- **Each member signs in with their own database login.** The server
  connects as that login and keeps the connection, in memory, for that
  browser session. The password is used to connect and then dropped. The
  database's own privileges (`lab_rw`) decide what a member may do. There is
  no shared writing login. Logins that are not in `lab_rw`, and superusers,
  cannot sign in.
- The session cookie is `HttpOnly`, `SameSite=Strict` and, when deployed,
  `Secure` with the `__Host-` prefix. A session ends at sign-out, after 30
  minutes without a request, after 12 hours, or when its connection is lost.
  Repeated wrong passwords for one login are slowed down.
- Every request that changes something must carry `X-CarasLab-Forms: 1` and
  come from the page's own origin.
- The page loads nothing from elsewhere and runs no inline script, under a
  strict Content-Security-Policy. Everything a person typed, including a
  template's labels, is put on the page as text, never as HTML.
- Run the server on 127.0.0.1 behind the HTTPS proxy. The sign-in password
  crosses the network only inside HTTPS.

## 9. Reference

### 9.1 Template definition (format 1)

```json
{"format": 1,
 "header": [{"item": "species"}, {"item": "latest_weight"},
            {"variable": "baseline weight", "source": "subject", "label": "Baseline"},
            {"variable": "probe depth", "source": "previous_entry"}],
 "sections": [{"title": "Recording",
               "fields": [{"widget": "number", "variable": "probe depth", "label": "Probe depth",
                           "units": "um", "required": true, "min": "0", "max": "6000",
                           "help": "Below the pia", "show_previous": true},
                          {"widget": "choice", "variable": "hemisphere",
                           "options": [{"value": "L", "label": "Left"}, {"value": "R", "label": "Right"}]},
                          {"widget": "instruction", "text": "Check the headcap before connecting."}]}]}
```

- `header` items are `{"item": ...}` or `{"variable", "source", "label"?}`.
  Source is `subject`, `project` or `previous_entry`.
- Field keys are `widget`, `variable`, `label`, `units`, `required`, `min`,
  `max`, `options`, `help`, `show_previous`, and `text` (headings and
  instructions only).
- `min` and `max` are strings, so they keep their exact digits.
- Unknown keys are refused. `lab.fn_form_definition_problems(definition,
  strict)` lists every problem.

### 9.2 SQL

| Function / view | Does |
|---|---|
| `lab.fn_publish_form(name, definition, p_label, p_description, p_note)` | defines the fields' variables, creates the template on first use, appends a version unless the definition is unchanged; returns `(version_number, is_new)` |
| `lab.fn_add_subject_form(subject_id, form_name, project_id, form_version)` | returns the subject form for (subject, project, template), creating it if needed |
| `lab.fn_record_observation(event_id, subject_form_id, occurred_at, session_label, values, note, p_supersedes, p_session_id, p_attributes)` | records an entry or its correction in one transaction; returns `inserted` or `existing` |
| `lab.fn_set_entry_note(event_id, note)` | changes an entry's note; returns `set`, `unset` or `unchanged` |
| `lab.fn_retract('event', event_id, reason)` | withdraws an entry |
| `lab.observation_active` | active entries with `field_values` (values as stored text) and `note` |
| `lab.fn_subject_project_columns(subject_id, project_id)` | a subject's CSV columns for a project |
| `lab.fn_form_definition_problems(definition, strict)`, `lab.fn_observation_problems(form, version, values)` | the checks, for clients to run first |

`values` is `{"variable": "text as typed"}`. A JSON number is refused.

`lab.fn_record_observation` stores a SHA-256 digest of the entry in
`event.attributes.client_digest`, computed over the subject form, time,
label, session, predecessor, note and non-blank values:

- An existing event with the same id and digest is `existing`, and nothing
  is written. This is checked before anything else.
- The same id with anything else is SQLSTATE `CLB01`.
- Value problems are `CLB02`, with `[{field, problem}]` as JSON in `DETAIL`.
- Correcting an entry that was already corrected is `CLB03`.

`lab.fn_check_integrity()` reports `observation_invalid` when a stored entry
breaks its version's rules, for example after a value is unset from MATLAB.

### 9.3 HTTP

The page uses these JSON endpoints, under the page's own path.

| Method | Endpoints |
|---|---|
| `GET` | `api/session`, `api/forms`, `api/form?name=&version=`, `api/variables?q=`, `api/subjects?q=`, `api/projects`, `api/subject?subject=`, `api/context?subject_form=`, `api/entries?subject_form=`, `api/note-history?event_id=` |
| `POST` | `api/login`, `api/logout`, `api/form/validate`, `api/form/publish`, `api/form/retire`, `api/subject-form/add`, `api/subject-form/update`, `api/entry/check`, `api/entry/submit`, `api/entry/note`, `api/entry/withdraw` |

The answers carry the database's own messages for refusals: `409` for
`CLB01` and `CLB03`, `422` for `CLB02` with its `problems`. Any other
failure is a fixed message, with the cause in the server's log.

## 10. Running it

```bash
# a scratch database with the schema and grants, and a member login
createdb lab_dev
psql -d lab_dev -f design_docs/schema.sql -f design_docs/grants.sql
psql -d lab_dev -c "CREATE ROLE dev_member LOGIN PASSWORD 'devpass' IN ROLE lab_rw"
psql -d lab_dev -c "INSERT INTO lab.person (full_name, db_login) VALUES ('Dev Member', 'dev_member')"

PGDATABASE=lab_dev python web/forms/server.py --csv-root /tmp/forms-csv --insecure-cookie
# open http://127.0.0.1:8779/ and sign in as dev_member
```

`--insecure-cookie` drops the cookie's `Secure` flag so that it works over
plain `http://localhost`. Never use it behind the proxy. The end-to-end
check that CI runs:

```bash
PGDATABASE=lab_forms python tests/check_forms_server.py
```

For the browser checklist, see [testing-locally.md](testing-locally.md)
§4.1.
