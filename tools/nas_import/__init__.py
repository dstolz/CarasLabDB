"""Database-free half of the NAS importer (plans/nas-file-registration.md, Part 2).

Turns a listed directory tree into *groups* (one session and one event each,
with their files), held items, reported items and ignored entries. Standard
library only; Python 3.10 or later; Windows and Linux. Nothing here opens a
database, keeps global state or writes to the scanned tree.

Typical use (the database side supplies root paths, subjects, overrides)::

    from nas_import import walk, interpret, ids
    listing = walk.walk(r"\\\\nas\\share\\RIG3_Backup_2025", spec)
    result = interpret.interpret([listing], {"nas-rig3": mount}, subjects, overrides)
    for g in result.groups:
        if g.status == "ready":
            ids.group_event_id(g), ids.client_digest(g), ids.signature(g)

Modules: :mod:`.model` (data classes, reason codes), :mod:`.walk`,
:mod:`.content` (checked opening, MPEG-TS), :mod:`.mat5`, :mod:`.rhd`,
:mod:`.names`, :mod:`.layouts`, :mod:`.subjects`, :mod:`.pairing`,
:mod:`.ids`, :mod:`.interpret`.
"""
