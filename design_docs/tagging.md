# Tagging — Hashtag-Style Labels on Lab Entities

Tags label events, artifacts, subjects, sessions and projects with the ad-hoc
categories that neither `artifact.role` nor free-text `notes` can be queried
by: pipeline stage, cohort, QC outcome, topic. "Every raw artifact of cohort A
that failed QC" becomes a filter instead of hand-written SQL.

This is the user-facing guide. The table-by-table rationale is in
[database-design.md](database-design.md) §3.7, the DDL in
[schema.sql](schema.sql) (search for "Tags"), and the client interfaces are
summarised in [§10](#10-using-tags-from-each-client) below. The syntax rules,
policy flags and filter grammar are defined here once; the MATLAB class, the
GUI, the dashboards and the MCP server all follow them.

---

## 1. Syntax

A tag is `namespace:value`, lower case:

| Part | Rule |
|---|---|
| namespace | `^[a-z][a-z0-9_]{0,31}$` — a letter, then up to 31 of `a-z 0-9 _` |
| value | `^[a-z0-9][a-z0-9_.-]{0,63}$` — up to 64 of `a-z 0-9 _ . -`, not starting with `_ . -` |

The tag is split at its **first** colon, so a second colon lands in the value
and fails its pattern (`a:b:c` is rejected).

**Only case and surrounding spaces are normalised** — the same policy as
checksums and paths. `lab.fn_canonical_tag` lower-cases and trims the ends
(`btrim`, which strips spaces), and prefixes `tag:` when there is no colon
(§2). Nothing else is rewritten. Anything else malformed is **rejected, never
repaired**:

| You write | Stored as |
|---|---|
| `' Stage:Raw '` | `stage:raw` |
| `Auditory_Cortex` | `tag:auditory_cortex` |
| `my tag` | rejected (`tag_value_ck`): a space is not allowed |
| `stage:` | rejected: empty value |
| `a:b:c` | rejected: the value would be `b:c`, which is not a valid value (and `a` is not a namespace) |
| `Probe_Site` as a *namespace name* | rejected (`tag_namespace_name_ck`): namespace names are not normalised |

The regexes are enforced by `CHECK` constraints on `lab.tag` and
`lab.tag_namespace`, so they hold for every client. The MATLAB class
(`CarasLabDB.normalizeTag`) and the GUI repeat them locally only to give a
clearer error before the database would.

`.` and `-` are legal after the first character, so `stage:v2.1` and
`topic:inferior-colliculus` are fine.

## 2. Bare tags and the reserved `tag` namespace

A tag written **with no colon** is a *bare* tag: `auditory_cortex` is stored as
`tag:auditory_cortex`, in the seeded, reserved namespace `tag`. This is the
only convenience beyond case and whitespace, and it lives in one place
(`lab.fn_canonical_tag`), so `Auditory_Cortex`, `auditory_cortex` and
`tag:auditory_cortex` are one tag everywhere.

The `tag` namespace is mutable, multi-valued, open-vocabulary and applies to all
five entity kinds. Its policy is **frozen from the start**
(`trg_tag_namespace_guard` rejects any change to `mutability`, `cardinality`,
`open_vocabulary` or `applies_to`; only the description is editable), because
every bare tag lands there. Displays and filters show bare tags bare: the
`display_tag` column of `lab.tag_current` strips the `tag:` prefix, and the
dashboards, the GUI and `CarasLabDB.displayTag` do the same.

## 3. Namespaces and policy flags

A namespace (`lab.tag_namespace`) carries the policy every tag in it obeys:

| Flag | Values | Meaning |
|---|---|---|
| `mutability` | `mutable` / `immutable` | `immutable`: once a tag of the namespace is on an entity it can never be removed or replaced. `mutable`: it can; the log keeps the history. |
| `cardinality` | `single` / `multi` | `single`: at most one current tag of the namespace per entity (`stage:raw` XOR `stage:sorted`). `multi`: any number. |
| `open_vocabulary` | boolean, default `true` | Whether `lab.fn_tag` / `lab.fn_register_tag` may create a new value on first use. In a *closed* namespace only registered values can be applied; a genuinely new value is registered deliberately (§5). This stops a typo (`stage:currated`) silently becoming vocabulary. |
| `applies_to` | non-empty subset of `event`, `artifact`, `subject`, `session`, `project` | The entity kinds its tags may be put on. |

**Freeze-once-in-use.** There is no admin gate: any `lab_rw` member may create
a namespace. Drift is prevented instead by freezing the policy that gives
existing assignments their meaning. Once **any** tag of a namespace has been
assigned (even if since removed — the log still holds it), `mutability` and
`cardinality` can no longer change and `applies_to` may only grow. Turning
`cohort` mutable, or `stage` multi-valued, would retroactively change what the
log says; the update is rejected with *"tag namespace cohort is in use, so its
policy is frozen"*. Choose the policy before the first assignment; for a
different policy, create a new namespace. A namespace is never renamed, and its
`description` and (outside `tag`) `open_vocabulary` stay editable.

**Tags themselves** (`lab.tag`) are never renamed or deleted, because the
assignment log refers to them by name. To retire one, set `retired_at`: no
*new* assignments are accepted, rows that already carry it keep it until it is
removed, and a `remove` is still allowed. Un-retire by setting `retired_at`
back to `NULL`.

## 4. Seeded vocabulary

`schema.sql` seeds these namespaces (editable by any member within the freeze
rule above, except `tag`):

| Namespace | mutability | cardinality | vocabulary | applies_to | Seeded values |
|---|---|---|---|---|---|
| `tag` (bare tags) | mutable | multi | open | all five | — (registered on first use) |
| `stage` | mutable | single | closed | artifact | `raw`, `preprocessed`, `sorted`, `curated`, `analyzed` |
| `qc` | mutable | single | closed | artifact, event, session | `pending`, `pass`, `fail` |
| `cohort` | immutable | single | open | subject, session | — |
| `condition` | immutable | single | open | subject, session, event | — |
| `topic` | mutable | multi | open | all five | — |

**`stage` vs `artifact.role`.** The two answer different questions. `role` is
what the file *is* (`raw`, `spikes`, `lfp`, `figure`, …) and is fixed at
registration, like everything on an immutable `artifact` row. `stage` is where
the file is in the processing *pipeline* and changes as it moves on:
`stage:raw` → `stage:preprocessed` → `stage:sorted`. A `role=raw` file can be
`stage:analyzed`; the shared word is a coincidence.

## 5. Writing tags: `lab.fn_tag`

`lab.fn_tag` is the one write entry point; every client (MATLAB, the GUI, psql)
uses it, so they share one semantics.

```sql
lab.fn_tag(p_kind text, p_id text, p_tag text, p_op text DEFAULT 'add',
           p_note text DEFAULT NULL, p_by uuid DEFAULT NULL) RETURNS bigint
-- returns the assignment_id of the row written for p_tag

SELECT lab.fn_tag('artifact', '<artifact_id>', 'stage:sorted');
SELECT lab.fn_tag('subject', 'G-0421', 'cohort:a');
SELECT lab.fn_tag('event', '<event_id>', 'qc:fail', 'remove', 're-checked: fine');
```

`p_kind` is `event`, `artifact`, `subject`, `session` or `project`; `p_id` is
that entity's id as text (a uuid, or the `subject_id`); `p_op` is `'add'` or
`'remove'`. The tag is canonicalised first.

* **`add` auto-registers** a new value if its namespace is open
  (`lab.fn_register_tag`). In a closed namespace an unregistered value raises,
  listing the registered ones. An unknown namespace raises as well.
* **Replace in a mutable single-valued namespace.** `add` of `stage:sorted` to
  an artifact that has `stage:raw` writes a `remove` of the old tag
  (note `replaced by stage:sorted`) and then the `add` — two log rows from one
  call, so "move the stage on" is a single call.
* Everything else is left to the policy trigger `trg_tag_assignment_policy`,
  which every insert passes through, however it is written. It rejects a tag
  that is not registered or is retired (for `add`); a kind outside the
  namespace's `applies_to`; `add` of a tag the entity already has; `remove` of a
  tag it does not have, or any `remove` in an immutable namespace; and an `add`
  in a single-valued namespace while another of its tags is current. A raw
  `INSERT INTO lab.tag_assignment` is policed identically but never replaces:
  a second value in a single-valued namespace is refused with *"… allows one
  current tag"* and a hint to use `lab.fn_tag`.
* In an **immutable single-valued** namespace (`cohort`) a second, different
  value is refused outright: *"subject G1 already has cohort:a, and namespace
  cohort is immutable and single-valued"*.

Adding vocabulary and namespaces is plain SQL (or the MATLAB equivalents in
§10); `lab_rw` may `INSERT` into both tables and `UPDATE` them:

```sql
-- a new value in a closed namespace (fn_tag would refuse to invent it)
INSERT INTO lab.tag (tag, description) VALUES ('stage:denoised', 'after artefact removal');

-- a new namespace; the policy freezes at its first use (§3)
INSERT INTO lab.tag_namespace (namespace, description, mutability, cardinality,
                               open_vocabulary, applies_to)
VALUES ('probe_site', 'Recording site of the probe', 'immutable', 'single', true,
        ARRAY['session','event']);

-- retire a tag (no new assignments; existing ones stay)
UPDATE lab.tag SET retired_at = now() WHERE tag = 'stage:curated';
```

`lab.fn_register_tag(tag, description, by)` registers a tag without applying
it and returns the canonical spelling, under the same open/closed rule as
`fn_tag`. Raw `INSERT`s do not fill `created_by` / `applied_by`; pass `p_by`
(or let the MATLAB class do it) if you want the person recorded.

## 6. How current tags are derived

`lab.tag_assignment` is an **append-only log**: one row per tag `add`ed or
`remove`d, never updated or deleted (like `event`). There is no "current tags"
column anywhere. An entity's current tags are the **latest row per
(entity, tag)**, ordered by `applied_at DESC, assignment_id DESC`, kept when
that row is an `add`. Ties on `applied_at` are real — `now()` is the
transaction start, so the `remove` and `add` of a replace share a timestamp —
which is why the tiebreak is the insertion order, `assignment_id`.

Two views expose this:

| View | Rows |
|---|---|
| `lab.tag_current` | One per current tag: `entity_kind`, `entity_id` (text), the typed id columns, `tag`, `namespace`, `value`, `display_tag`, `note`, `applied_at`, `applied_by`. |
| `lab.entity_tags` | One per entity that has at least one current tag: `entity_kind`, `entity_id`, and parallel sorted arrays `tags` and `display_tags`. |

The history of an entity is `SELECT … FROM lab.tag_assignment WHERE …` — every
add and remove, who and when, with the note.

## 7. Filtering

`lab.fn_tag_match(kind, id, all_of, any_of, none_of)` is the single definition
of filter semantics; the MATLAB getters, the GUI and the MCP server all call it
rather than re-implementing it. An entity matches when it currently has:

* **every** tag in `all_of`,
* **at least one** tag in `any_of` (when `any_of` has tokens),
* **none** of `none_of`.

Token rules:

* Each token is canonicalised like a stored tag: case and spaces are
  normalised and a bare token means `tag:<token>`.
* `ns:*` is a **wildcard**: any current tag in namespace `ns`. So
  `none_of => ['qc:*']` means "never QC'd" and `any_of => ['topic:*']` "has a
  topic".
* **Empty is no constraint.** A `NULL` or empty array, and `NULL` or blank
  elements, are ignored. In particular an empty `any_of` does **not** mean
  "matches nothing". A filter with no tokens at all matches every entity.
* Only **current** tags count (`lab.tag_current`). A tag that was removed, or
  replaced by another value, does not match.

`lab.fn_find_by_tags(kind, all_of, any_of, none_of, active_only := true)`
returns the matching `entity_id`s (text, id order). Untagged entities are
candidates too, so a `none_of`-only query finds them. For events and artifacts
`active_only` skips superseded rows, like the `*_active` views; it has no
effect on the other kinds. An unknown `kind` raises.

```sql
-- sorted artifacts about tonotopy that are not marked failed
SELECT a.*
FROM lab.artifact_active a
WHERE lab.fn_tag_match('artifact', a.artifact_id::text,
                       ARRAY['stage:sorted', 'topic:tonotopy'], NULL, ARRAY['qc:fail']);

SELECT * FROM lab.fn_find_by_tags('subject', ARRAY['cohort:a']);
```

**String grammar (dashboards and GUI).** The dashboards' *Tags* field and the
GUI's *Tags* field take one string, for example:

```
stage:raw -qc:fail topic:*
```

Space-separated tokens must **all** hold; a leading `-` negates a token; `ns:*`
is the wildcard; a bare word is a bare tag. That is `all_of` plus `none_of`
only — there is no "any of" in the string grammar (use the MATLAB `AnyTags=`,
the MCP `any_tags`, or SQL for that). Case does not matter. The dashboards
apply it to events, artifacts, subjects, sessions and projects; the GUI to the
Subjects, Sessions, Events and Artifacts tabs.

## 8. Corrections and carry-forward

Tags belong to a specific **row**. A superseded event or artifact keeps the
tags it had, and its correction is a new row that starts with none, so it would
drop out of every tag filter the original matched (filters read the active
rows by default). The correction must therefore be tagged too.

* **The MATLAB class does it for you.** `supersedeEvent`, `supersedeArtifact`,
  and the add methods when called with `Supersedes=` copy the predecessor's
  current tags onto the successor with new `add` rows (note
  `carried forward from <old id>`), in the **same transaction** as the insert;
  `supersedeEvent` also carries the tags of each file it re-points.
* **Retired tags are skipped.** The policy trigger refuses to assign a retired
  tag, so carrying one would make the whole correction fail — a weight could
  not be fixed because a `stage` value was retired. The class skips it with a
  `CarasLabDB:retiredTagsNotCarried` warning naming the tags; the integrity
  check below keeps reporting the gap until someone re-tags the successor.
* **`tag_not_carried_forward`** (a `warning` from `lab.fn_check_integrity()`)
  flags an active event or artifact whose superseded predecessor has current
  tags the successor lacks: *"supersedes artifact `<old id>`, whose current
  tags were not carried forward: `<tags>`"*, reported against the successor's
  id, one row listing the missing tags. A tag counts as carried if the
  successor has *any* assignment row for it (it may since have been removed on
  purpose) or, in a single-valued namespace, any row in that namespace (it has
  since been given another value).
* **A correction made with raw SQL must carry the tags itself.** Run this in
  the same transaction as the superseding insert (for an event use
  `entity_kind = 'event'` and `event_id`):

```sql
INSERT INTO lab.tag_assignment (entity_kind, artifact_id, tag, op, note)
SELECT 'artifact', :new_artifact_id, c.tag, 'add', 'carried forward from ' || :old_artifact_id
FROM lab.tag_current c
JOIN lab.tag t ON t.tag = c.tag
WHERE c.entity_kind = 'artifact' AND c.artifact_id = :old_artifact_id
  AND t.retired_at IS NULL;
```

The same applies to re-pointing an artifact at a corrected event (the example
in [database-design.md](database-design.md) §4.2): each superseding artifact
needs its own carry.

## 9. Concurrency caveat

The single-cardinality check is a **trigger, not a constraint** — the same class
of limitation as `trg_artifact_unique_active`. Two concurrent transactions can
each find no current tag in a `single` namespace for the same entity, each
insert one, and both commit, leaving two current values. Clients tag
interactively, one entity at a time, so this is documented rather than
guarded with a lock. `lab.tag_current` shows both rows if it happens; fix it by
`remove`ing the wrong one. A concurrent duplicate `add` of the *same* tag is
harmless: the latest row wins and the entity still has one current row for it.

## 10. Using tags from each client

**SQL.** `lab.fn_tag`, `lab.fn_tag_match`, `lab.fn_find_by_tags`, the views
`lab.tag_current` / `lab.entity_tags`, and plain `INSERT` / `UPDATE` for
vocabulary, as above. `lab_ro` may read everything but cannot call `fn_tag`
(its `INSERT` is refused).

**MATLAB (`@CarasLabDB`).** All writes go through `lab.fn_tag`; `kind` is
`"event"`, `"artifact"`, `"subject"`, `"session"` or `"project"`, tags are
validated locally first (`CarasLabDB:invalidTag`), and the current person is
recorded in `applied_by`.

```matlab
db.setTag("artifact", aid, "stage:raw");                 % single-valued: set / replace
db.setTag("artifact", aid, "stage:preprocessed");        % replaces stage:raw
[~, changed] = db.setTag("artifact", aid, "stage:preprocessed");   % changed = false
db.addTag("artifact", aid, ["topic:tonotopy", "pilot"], Note="first penetration");
db.removeTag("artifact", aid, "qc:fail", Note="re-checked: fine");

T   = db.getEntityTags("artifact", aid);                 % current tags
H   = db.getEntityTags("artifact", aid, History=true);   % the log, oldest first
ids = db.findByTags("artifact", Tags="stage:sorted", NotTags="qc:fail");
A   = db.getArtifacts(Tags="stage:sorted", AnyTags=["topic:*", "pilot"]);
```

| Method | Purpose |
|---|---|
| `addTag(kind, id, tags, Note=, AppliedBy=)` | Add one or more tags (one transaction: all or none); returns the assignment ids. |
| `removeTag(kind, id, tags, Note=, AppliedBy=)` | Remove tags the entity currently has. |
| `setTag(kind, id, tag, Note=, AppliedBy=)` | Single-valued namespaces only (`CarasLabDB:notSingleValued` otherwise); idempotent, returns `[assignmentId, changed]`. |
| `getEntityTags(kind, id, History=false)` | `tag_current` rows, or the full log (oldest first). |
| `findByTags(kind, Tags=, AnyTags=, NotTags=, ActiveOnly=)` | Matching ids as a string column; `ActiveOnly` defaults to `UseActiveViews`. |
| `getEvents` / `getArtifacts` / `getSubjects` / `getSessions` / `getProjects` | Take the same `Tags=`, `AnyTags=`, `NotTags=` (string arrays). |
| `getTagNamespaces(Namespace=, AppliesTo=)`, `getTags(Namespace=, IncludeRetired=)` | Read the vocabulary (`applies_to` comes back as comma-separated text). |
| `addTagNamespace(Namespace=, Mutability=, Cardinality=, AppliesTo=, OpenVocabulary=, Description=)` | Create a namespace — choose the policy carefully (§3). |
| `registerTag(tag, Description=)` | Add a value deliberately, e.g. to a closed namespace. |
| `updateTagNamespace(namespace, Description=, OpenVocabulary=, AppliesTo=, Mutability=, Cardinality=)` | Edit a namespace in place (the database enforces the freeze). |
| `retireTag(tag, Unretire=false)` | Retire or un-retire a tag. |

**MCP server (read-only).** `get_tag_namespaces`, `get_tags`,
`get_entity_tags(entity_kind, entity_id, include_history)` and
`find_by_tags(entity_kind, all_of, any_of, none_of, active_only)`; the five list
tools `get_events`, `get_artifacts`, `get_subjects`, `get_sessions` and
`get_projects` also take `tags` / `any_tags` / `none_tags`. There is no write
tool; tag through MATLAB or SQL. See [mcp-server.md](mcp-server.md) §3.

**Dashboards.** Current tags are derived client-side from the exported log
(`tagAssignments`) the same way `lab.tag_current` derives them. Tags show as
chips in the tables, and a Tags panel on the overview counts them per tag.
Click a chip to add it to the *Tags* filter; press `#` to focus the field;
*Reset filters* (`f`) clears it.

**GUI (`@CarasLabDBApp`).** The *Tags* field under the quick search takes the
string grammar of §7 and applies with Enter; it is remembered between sessions.
**Ctrl+T** (or the toolbar *Tags…* button) opens the tag editor for the
selected row: current tags, and Add (Ctrl+Enter), Set (Ctrl+S) and Remove
(Delete) through the class methods above, with the database's policy errors
shown as alerts. **Ctrl+?** lists the shortcuts.
