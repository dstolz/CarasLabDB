# Variables — User-Defined Named Values on Lab Entities

A variable is a named value that a lab member attaches to an event, artifact,
subject, session or project for something the schema has no column for:
`probe depth` = 1200 µm on a recording session, `housing` = `pair` on an
animal, `stimulus level` = 70 dB SPL on a recording. Each variable holds one
number or one piece of text, has units if it is a number, and keeps its whole
history: setting it again is an update, and every earlier value stays on
record with who set it and when.

This is the user-facing guide. The DDL is in [schema.sql](schema.sql) (search
for "User-defined variables"), the table rationale in
[database-design.md](database-design.md) §3.8, and the client interfaces are
summarised in [§9](#9-using-variables-from-each-client). Variables follow the
same pattern as [tags](tagging.md): mutable definitions, an append-only log
of values, and current values derived by a view.

Every SQL example below was run against a scratch database (schema version 5,
PostgreSQL 16) as a login in `lab_rw`; outputs are shown where they help
(with the test login renamed `jdoe` and long ids shortened).

---

## 1. Variable, tag or column?

| Use | When | Example |
|---|---|---|
| A **fixed column** | The schema already has it, or every row of that kind needs it and the lab wants it enforced | `recording_event.sample_rate_hz`, `husbandry_event.weight_g` |
| A **tag** | A category: a label from a vocabulary that you filter by (`stage:sorted`, `cohort:a`, `qc:fail`) | "is this file spike-sorted?" |
| A **variable** | A *value*: a measurement or setting, usually with units, that you read, compare or compute with | probe depth 1250 µm, reference electrode "skull screw" |

Rules of thumb. If you would write `> 1000` or an average over it, it is a
variable. If you would only ever ask "has it or not", it is a tag. If a
value belongs on every row of a kind and the lab would want it required, ask
for a column (a schema change with a migration). The `attributes jsonb`
column on `event` and `artifact` still exists for ad-hoc structured data, but
it has no definitions, no units, no history and no client support; prefer a
variable.

## 2. Names

A variable's **name** is how it is stored and queried; its **label** is how it
is shown to people.

| Part | Rule |
|---|---|
| name | `^[a-z][a-z0-9_-]*( [a-z0-9_-]+)*$`, at most 63 characters: words of lower-case letters, digits, `_` or `-`, separated by single spaces, starting with a letter |
| label | any non-blank text; defaults to the name |

**Only case and whitespace are normalised** (`lab.fn_canonical_variable`):
`'Probe  Depth '` and `'probe depth'` are one variable everywhere. Anything
else malformed is rejected, never repaired:

```sql
SELECT lab.fn_set_variable('session', 'cccccccc-0000-0000-0000-000000000001', 'probe.depth', 1);
-- ERROR:  "probe.depth" is not a valid variable name
-- HINT:  Use words of letters, digits, _ or -, separated by single spaces and
--        starting with a letter, at most 63 characters: probe depth
```

A name never changes (the value log refers to it); to rename, retire the old
variable and define a new one (§5).

## 3. Defining and setting

`lab.fn_set_variable` is the one write entry point; every client uses it.

```sql
lab.fn_set_variable(p_kind text, p_id text, p_name text,
                    p_number numeric DEFAULT NULL, p_text text DEFAULT NULL,
                    p_units text DEFAULT NULL, p_label text DEFAULT NULL,
                    p_description text DEFAULT NULL, p_note text DEFAULT NULL,
                    p_by uuid DEFAULT NULL) RETURNS bigint
-- returns the value_id of the log row written
```

`p_kind` is `event`, `artifact`, `subject`, `session` or `project`; `p_id` is
that entity's id as text (a uuid, or the `subject_id`). Give exactly one of
`p_number` and `p_text`.

**The first use defines the variable**, as a number or as text according to
the value given, with the units, label and description supplied:

```sql
SELECT lab.fn_set_variable('session', 'cccccccc-0000-0000-0000-000000000001', 'Probe Depth', 1200,
                           p_units => 'um', p_label => 'Probe Depth',
                           p_description => 'Depth of the probe tip below the pia');

SELECT name, label, units, value_type, applies_to FROM lab.variable;
--     name     |    label    | units | value_type |                applies_to
-- -------------+-------------+-------+------------+------------------------------------------
--  probe depth | Probe Depth | um    | number     | {event,artifact,subject,session,project}
```

**Later uses just set a value.** Units may be omitted (the variable's own
apply); label and description are not changed by this call (edit the
definition, §5):

```sql
SELECT lab.fn_set_variable('session', 'cccccccc-0000-0000-0000-000000000002', 'probe depth', 1350);
SELECT lab.fn_set_variable('subject', 'G-0421', 'housing', p_text => 'pair');
```

**Defining ahead of use**, for instance to restrict where a variable may be
set, is `lab.fn_define_variable(name, value_type, units, label, description,
applies_to)`; it returns the canonical name, and returns an existing
definition unchanged if it agrees on type and units:

```sql
SELECT lab.fn_define_variable('target frequency', 'number', 'kHz', 'Target Frequency',
                              'Best frequency targeted for the penetration', ARRAY['session','event']);
SELECT lab.fn_set_variable('subject', 'G-0421', 'target frequency', 8);
-- ERROR:  variable target frequency applies to session, event only, not to subject
```

Who: the database records the connected login in `set_login` whatever the
client sends, and `set_by` is the person given in `p_by` or, by default, the
person mapped to the login (`lab.fn_current_person()`, see
[database-design.md](database-design.md) §4).

## 4. Units and types freeze

A variable's **value type** (`number` or `text`) and its **units** are part of
what every stored value means. 1250 recorded as micrometres must not become
1250 millimetres because someone edited the definition, so once a variable
has any value both are fixed:

```sql
SELECT lab.fn_set_variable('session', 'cccccccc-0000-0000-0000-000000000001', 'probe depth', 1.25,
                           p_units => 'mm');
-- ERROR:  variable probe depth is recorded in um, not in mm
-- HINT:  Convert the value, or define a separate variable for the other units.

SELECT lab.fn_set_variable('session', 'cccccccc-0000-0000-0000-000000000001', 'probe depth',
                           p_text => 'deep');
-- ERROR:  variable probe depth holds a number; pass p_number

UPDATE lab.variable SET units = 'mm' WHERE name = 'probe depth';
-- ERROR:  variable probe depth has values, so its value type and units are frozen
--         and applies_to may only grow
```

Write units as plain text (`um`, `g`, `ml`, `dB SPL`, `kHz`). For different
units, define another variable (`probe depth mm`) and set converted values.
Numbers are stored as `numeric`, so the digits you type are the digits
stored; NaN and infinities are refused.

## 5. Updating, unsetting, editing and retiring

**Update** by setting again. It appends a row; nothing is overwritten:

```sql
SELECT lab.fn_set_variable('session', 'cccccccc-0000-0000-0000-000000000001', 'probe depth', 1250,
                           p_note => 'advanced 50 um after the first set');
```

**Unset** clears the current value, again by appending a row (`op =
'unset'`); unsetting something that has no value is an error:

```sql
SELECT lab.fn_unset_variable('session', 'cccccccc-0000-0000-0000-000000000003', 'probe depth',
                             p_note => 'depth not measured');
```

**Edit a definition** in place: `label`, `description` and `retired_at` are
editable by any `lab_rw` member, `applies_to` may only grow once there are
values, and every edit is kept in `lab.row_history`:

```sql
UPDATE lab.variable
SET description = 'Depth of the probe tip below the pial surface, read from the micromanipulator'
WHERE name = 'probe depth';
```

**Retire** a variable that should take no new values; rows keep the values
they have, and a correction still carries them forward. Setting
`retired_at` back to `NULL` un-retires it:

```sql
UPDATE lab.variable SET retired_at = now() WHERE name = 'reference electrode';
SELECT lab.fn_set_variable('session', 'cccccccc-0000-0000-0000-000000000002', 'reference electrode',
                           p_text => 'ground wire');
-- ERROR:  variable reference electrode was retired at ... and takes no new values
```

A variable is never deleted, and its name is never changed.

## 6. History and "latest value"

`lab.variable_value` is the **append-only log**: one row per value set or
unset, never updated or deleted (like `event`). An entity's current value of
a variable is the **latest row** for that (entity, variable) in insertion
order (`value_id`), kept when it is a `set`.

| View / table | Rows |
|---|---|
| `lab.variable_current` | One per current value: `entity_kind`, `entity_id` (text), the typed id columns, `variable`, `label`, `units`, `value_type`, `value_num`, `value_text`, `value` (as text, either kind), `note`, `set_at` (when this value was set: the "last updated" time), `set_by`, `set_login` |
| `lab.entity_variables` | One per entity with at least one current value: `entity_kind`, `entity_id`, and `variables`, a JSON object `{name: value}` with numbers as JSON numbers |
| `lab.variable_value` | The full log |
| `lab.variable` | The definitions |

```sql
-- the history of one value
SELECT value_id, op, value_num, note, set_login
FROM lab.variable_value
WHERE entity_kind = 'session' AND session_id = 'cccccccc-0000-0000-0000-000000000001'
  AND variable = 'probe depth'
ORDER BY value_id;
--  value_id | op  | value_num |                note                | set_login
-- ----------+-----+-----------+------------------------------------+-----------
--         1 | set |      1200 |                                    | jdoe
--         4 | set |      1250 | advanced 50 um after the first set | jdoe
```

## 7. Queries

**One variable as a column of an ordinary query**: `lab.fn_variable_number`
returns the current number (NULL when there is none, or for a text
variable), `lab.fn_variable_text` the current value as text, either kind:

```sql
SELECT s.subject_id, s.label,
       lab.fn_variable_number('session', s.session_id::text, 'probe depth') AS probe_depth_um
FROM lab.session s
ORDER BY s.subject_id, s.label;
--  subject_id |      label      | probe_depth_um
-- ------------+-----------------+----------------
--  G-0421     | 2026-07-02_pen1 |           1250
--  G-0421     | 2026-07-03_pen2 |           1350
--  G-0422     | 2026-07-03_pen1 |          980.5

SELECT lab.fn_variable_text('subject', 'G-0421', 'housing');   -- pair

-- and in a WHERE clause
SELECT s.label FROM lab.session s
WHERE lab.fn_variable_number('session', s.session_id::text, 'probe depth') > 1000;
```

**All of an entity's variables** as one JSON column:

```sql
SELECT s.label, ev.variables
FROM lab.session s
LEFT JOIN lab.entity_variables ev
       ON ev.entity_kind = 'session' AND ev.entity_id = s.session_id::text
ORDER BY s.label;
--       label      |                          variables
-- -----------------+-------------------------------------------------------------
--  2026-07-02_pen1 | {"probe depth": 1250, "reference electrode": "skull screw"}
--  2026-07-03_pen1 | {"probe depth": 980.5}
--  2026-07-03_pen2 | {"probe depth": 1350}
```

**One variable across every session**, with when each value was set:

```sql
SELECT c.entity_id AS session_id, s.label, c.value_num AS probe_depth_um, c.set_at
FROM lab.variable_current c
JOIN lab.session s ON s.session_id = c.session_id
WHERE c.variable = 'probe depth'
ORDER BY s.label;
```

For events and artifacts, join `lab.event_active` / `lab.artifact_active`
when only current rows should count: the views above list the values of
every row, superseded and retracted ones included.

## 8. Corrections

A correction (a superseding event or artifact) is a new row, so without help
it would start with none of its predecessor's variables. The database copies
them: `trg_event_carry_variables` / `trg_artifact_carry_variables` run when
the superseding row is inserted and append each current value of the
predecessor to the successor, keeping its `set_at` and `set_by` (the value
did not change) with the note `carried forward from <old id>`. Every client,
and a correction typed into psql, behaves the same; unlike tags, nothing has
to be carried by hand.

```sql
-- event 1111... has stimulus level = 70 dB SPL; insert 2222... with
-- supersedes = 1111... (and its detail row), then:
SELECT entity_id, variable, value, units, note
FROM lab.variable_current WHERE entity_kind = 'event' ORDER BY value_id;
--               entity_id               |    variable    | value | units  |  note
-- --------------------------------------+----------------+-------+--------+-------------------------
--  11111111-1111-1111-1111-111111111111 | stimulus level | 70    | dB SPL |
--  22222222-2222-2222-2222-222222222222 | stimulus level | 70    | dB SPL | carried forward from 1111...
```

To change a value as part of a correction, set it on the successor after the
insert. Subject, session and project variables are unaffected by
corrections (those rows are edited in place), and follow a renamed subject.

## 9. Using variables from each client

**SQL.** `lab.fn_set_variable`, `lab.fn_unset_variable`,
`lab.fn_define_variable`, `lab.fn_variable_number`, `lab.fn_variable_text`,
the views of §6, and `UPDATE lab.variable` for definitions. `lab_ro` may read
everything; its writes are refused at the `INSERT`.

**MATLAB (`@CarasLabDB`).** All writes go through the functions above;
`kind` is `"event"`, `"artifact"`, `"subject"`, `"session"` or `"project"`,
and the value's MATLAB type decides number or text.

```matlab
db.setVariable("session", sid, "Probe Depth", 1200, Units="um", ...
               Label="Probe Depth", Description="Depth of the probe tip below the pia");
db.setVariable("session", sid, "probe depth", 1250, Note="advanced 50 um");   % an update
db.setVariable("subject", "G-0421", "housing", "pair");
T = db.getVariables("session", sid);                  % current values
H = db.getVariables("session", sid, History=true);    % the log
V = db.getVariableValues("probe depth", Kind="session");   % one variable across rows
db.unsetVariable("session", sid, "probe depth");
```

| Method | Purpose |
|---|---|
| `setVariable(kind, id, name, value, Units=, Label=, Description=, Note=)` | Set (and on first use define) a value; returns the `value_id`. |
| `unsetVariable(kind, id, name)` | Clear the current value. |
| `getVariables(kind, id, History=false)` | `variable_current` rows of one entity, or its log. |
| `getVariableValues(name, Kind=)` | Current values of one variable across entities. |
| `defineVariable(name, ...)` | Define ahead of use (value type, units, label, description, applies-to). |
| `getVariableDefinitions(...)` | Read the definitions. |
| `updateVariableDefinition(name, Label=, Description=)` | Edit a definition (the database enforces the freeze). |
| `retireVariable(name)` | Retire (or un-retire) a variable. |

**GUI (`@CarasLabDBApp`).** **Ctrl+L** opens the variables editor for the
selected row: its current values, set and clear them, and the history.
**Ctrl+?** lists the shortcuts.

**Dashboards.** The dashboards show each entity's current variables (label,
value, units) and have a Variables view of the definitions.

**MCP server (read-only).** Tools to read the definitions, an entity's
variables and the entities with a given value (`get_variable_definitions`,
`get_variables`, `find_by_variable`); there is no write tool. See
[mcp-server.md](mcp-server.md) for the current list and arguments.

## 10. Worked example: probe depth on a session

A recording session `2026-07-02_pen1` (session id
`cccccccc-0000-0000-0000-000000000001`) of gerbil `G-0421`. The probe went in
to 1200 µm, then was advanced 50 µm.

```sql
-- Day of recording: the first use defines the variable.
SELECT lab.fn_set_variable('session', 'cccccccc-0000-0000-0000-000000000001', 'Probe Depth', 1200,
                           p_units => 'um', p_label => 'Probe Depth',
                           p_description => 'Depth of the probe tip below the pia');

-- Advanced: set it again.
SELECT lab.fn_set_variable('session', 'cccccccc-0000-0000-0000-000000000001', 'probe depth', 1250,
                           p_note => 'advanced 50 um after the first set');

-- What is it now, and since when?
SELECT label, value, units, set_at, set_login
FROM lab.variable_current
WHERE entity_kind = 'session' AND entity_id = 'cccccccc-0000-0000-0000-000000000001'
  AND variable = 'probe depth';
--     label    | value | units | set_at | set_login
-- -------------+-------+-------+--------+-----------
--  Probe Depth | 1250  | um    | ...    | jdoe

-- Every session's depth, for the paper's methods table.
SELECT s.subject_id, s.label,
       lab.fn_variable_number('session', s.session_id::text, 'probe depth') AS probe_depth_um
FROM lab.session s ORDER BY s.subject_id, s.label;
```

The same in MATLAB:

```matlab
db.setVariable("session", sid, "Probe Depth", 1200, Units="um", Label="Probe Depth", ...
               Description="Depth of the probe tip below the pia");
db.setVariable("session", sid, "probe depth", 1250, Note="advanced 50 um after the first set");
T = db.getVariables("session", sid)
```
