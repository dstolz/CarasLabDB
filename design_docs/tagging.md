# Tags — hashtag-style labels with namespace policies

Every event, artifact, subject, session and project can carry tags. A tag is
a short label such as `stage:raw`, `cohort:a`, `qc:fail` or `auditory_cortex`,
used to find things quickly ("every raw file of cohort A that failed QC")
without hand-written SQL. This page is the one place the rules are stated;
the MATLAB class, the GUI, the MCP server and the dashboards all implement
exactly these. The tables themselves are described in
[database-design.md §3.7](database-design.md#37-tags).

## Syntax

A tag is `namespace:value`.

| Part | Rule |
|---|---|
| namespace | starts with a letter; `[a-z0-9_]`; 1–32 characters |
| value | starts with a letter or digit; `[a-z0-9_.-]`; 1–64 characters |
| whole tag | lower case, exactly one colon |

**Only case and surrounding whitespace are normalised** on the way in:
`' Stage:Raw '` is stored as `stage:raw`, the same tag. Anything else that
does not fit — a space, a slash, an empty value, a second colon — is
rejected, never rewritten. A tag written without a namespace
(`auditory_cortex`) is a *bare* tag: it belongs to the reserved `tag`
namespace, is stored as `tag:auditory_cortex`, and is displayed bare again
(`display_tag`). `auditory_cortex` and `tag:auditory_cortex` are one tag
everywhere. (`lab.fn_canonical_tag` is the normaliser; the clients mirror it
so a malformed tag fails with a clear message before it reaches the
database.)

## Namespaces and their policy

A namespace is created once (by any lab member) and declares how its tags
behave. Mutability, cardinality and the kinds it applies to are **frozen as
soon as the namespace is in use**, so a policy cannot drift after tags have
been applied under it (`applies_to` may still grow). Description and
`open_vocabulary` stay editable; every edit is in `lab.row_history`.

| Flag | Values | Meaning |
|---|---|---|
| `mutability` | `mutable` / `immutable` | *mutable*: a tag may later be removed from, or replaced on, an entity (the log keeps the history). *immutable*: once applied to an entity it is permanent there. |
| `cardinality` | `single` / `multi` | *single*: an entity carries at most one current tag of the namespace (`stage:raw` *or* `stage:sorted`). *multi*: any number (`topic:a` *and* `topic:b`). |
| `open_vocabulary` | boolean | *true*: a value never seen before is registered on first use. *false*: only values registered deliberately (`registerTag` / `lab.fn_register_tag`) may be applied; a typo such as `stage:currated` is refused instead of quietly becoming vocabulary. |
| `applies_to` | subset of `event, artifact, subject, session, project` | The kinds of entity the namespace may be applied to. |

The seed vocabulary, which any member may extend:

| namespace | mutability | cardinality | vocabulary | applies to | seeded values |
|---|---|---|---|---|---|
| `tag` (reserved: bare tags) | mutable | multi | open | all five | — |
| `stage` | mutable | single | closed | artifact | `raw`, `preprocessed`, `sorted`, `curated`, `analyzed` |
| `qc` | mutable | single | closed | artifact, event, session | `pending`, `pass`, `fail` |
| `cohort` | immutable | single | open | subject, session | — |
| `condition` | immutable | single | open | subject, session, event | — |
| `topic` | mutable | multi | open | all five | — |

`stage` is deliberately different from `artifact.role`: *role* says what a
file **is** (raw, spikes, lfp, …) and is fixed when the file is registered;
*stage* says where the file is in the pipeline, which changes over time —
which is exactly why it is a mutable, single-valued tag.

The `tag` namespace is the permissive fallback every bare tag lands in; its
policy is frozen from the start.

## Applying and removing tags

Assignments are an **append-only log** (`lab.tag_assignment`), never a
mutable column: each row is an `add` or a `remove` of one tag on one entity,
with who, when and an optional note. The current tags of an entity are
derived from it (`lab.tag_current`, `lab.entity_tags`): per (entity, tag),
the newest row decides. The full history of a tag that changed over time
(`stage:raw` → `stage:preprocessed` → `stage:sorted`) is therefore always
available.

The one write path is `lab.fn_tag(kind, id, tag, op, note, applied_by)`
(`op` is `'add'` or `'remove'`). In one call it canonicalises the tag,
registers an unknown value when the namespace is open, and for an `add` in
a *single-valued, mutable* namespace first records the removal of the value
the entity currently carries — so advancing a file from `stage:raw` to
`stage:preprocessed` is one call and two log rows. Adding a tag the entity
already carries writes nothing. A direct `INSERT` into `lab.tag_assignment`
is still policed by the same trigger, so other clients cannot bypass the
policy; a second single-valued tag inserted directly is refused with a hint
to use `fn_tag`.

What the policy refuses:

- a tag the namespace does not apply to (`stage:raw` on a subject);
- a second value in a single-valued **immutable** namespace, and any
  removal in an immutable namespace;
- removing a tag the entity does not currently carry;
- a retired tag (`tag.retired_at`), or an unregistered value in a closed
  namespace.

Known limitation: the single-cardinality check is a trigger, so, like the
artifact de-duplication trigger, it cannot see a row another transaction is
inserting at the same instant.

**Corrections keep their tags.** When `CarasLabDB.supersedeEvent` or
`supersedeArtifact` supersedes a row, the old row's current tags are copied
to the new one in the same transaction, as ordinary log rows whose note says
where they came from. A correction made by hand that forgot to do this shows
up in `lab.fn_check_integrity()` as `tag_not_carried_forward`.

## Filtering

A filter is three lists of *patterns*: **all of**, **any of**, **none of**.
A pattern is a tag matched exactly (`stage:raw`, or a bare `auditory_cortex`)
or `namespace:*`, which matches any current tag of that namespace. Input is
canonicalised like a tag. `lab.fn_tag_match(kind, id, all, any, none)` is
the single definition; `lab.fn_find_by_tags(kind, all, any, none)` returns
the matching *tagged* entities of a kind.

The same filter in each client:

| Client | How |
|---|---|
| SQL | `SELECT * FROM lab.artifact_active a WHERE lab.fn_tag_match('artifact', a.artifact_id::text, ARRAY['stage:raw'], NULL, ARRAY['qc:fail'])` |
| MATLAB | `db.getArtifacts(Tags="stage:raw", NotTags="qc:fail")`, likewise `getEvents`, `getSubjects`, `getSessions`, `getProjects`; `db.findByTags("artifact", Tags=["stage:*"])` |
| GUI | the **Tag filter** field: `stage:raw -qc:fail ?cohort:a ?cohort:b` — space-separated, `-` excludes, `?` marks the any-of set, `ns:*` wildcard, bare word = free-form tag |
| Web dashboards | the **Tags** box in the filter bar, same grammar; click a chip to add it |
| MCP server | `tags=`, `any_tags=`, `none_tags=` on `get_events`, `get_artifacts`, `get_subjects`, `get_sessions`, `get_projects`; `find_by_tags`, `get_entity_tags`, `get_tags`, `get_tag_namespaces` |

`find_by_tags` / `findByTags` consider only entities that carry at least one
tag; the per-table getters apply the filter to the whole table, so
`NotTags="qc:fail"` there also returns untagged rows.

## Quick reference (MATLAB)

```matlab
db.addTagNamespace("region", Mutability="immutable", Cardinality="multi", ...
                   AppliesTo=["event","artifact"], OpenVocabulary=true);
db.registerTag("stage:archived", Description="moved to cold storage");

db.addTag("artifact", aid, "stage:raw");
db.addTag("artifact", aid, "stage:preprocessed", Note="CAR + bandpass");  % replaces
db.addTag("subject", "G-0421", "cohort:a");           % permanent
db.addTag("event",   eid, "auditory_cortex");         % bare -> tag:auditory_cortex
db.removeTag("artifact", aid, "qc:fail", Note="re-checked");

db.getEntityTags("artifact", aid)                     % current
db.getEntityTags("artifact", aid, History=true)       % every add / remove
db.findByTags("artifact", Tags="stage:*", NotTags="qc:fail")
db.getArtifacts(SessionId=sid, Tags="stage:preprocessed")
db.getTags(Namespace="stage"); db.getTagNamespaces();
db.retireTag("topic:old");  db.updateTagNamespace("cohort", Description="...");
```
