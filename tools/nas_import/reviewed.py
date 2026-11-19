"""The reviewed path of the importer: ``scan`` writes a plan, ``apply`` writes exactly it.

An unattended ``run`` only adds. Whatever needs a correction, a disposition
or a second look is done here, by a person: ``scan`` reads the NAS and the
database, writes nothing to either, and puts what it would do into a plan
file; the person reads the plan and its report; ``apply`` carries the plan
out and refuses whatever is no longer as the scan found it.

The plan file
-------------
JSON lines (UTF-8, ``\\n``, each line canonical JSON: sorted keys, no floats):

``{"type": "plan", "format": FORMAT, "tool": ...}``
    the first line.
``{"type": "directory", "id", "root", "root_id", "path", "layout", "rig", "pair_with", "time_zone", "min_age_min", "mode", "partner"}``
    a directory's settings as read. Its lines follow it.
``{"type": "time", "directory", "listed_us", "listed"}``
    when its listing was complete, by the database's clock (microseconds
    since 1970, and as UTC text). ``apply`` measures ``min_age_min`` from it.
``{"type": "failed", "directory", "reason"}``
    the directory could not be listed completely: nothing is planned for it.
``{"type": "held", "directory", "path", "code", "sentence"}``
    a file outside any group that is held.
``{"type": "group", "directory", "key", "kind", "action", ...}``
    one group. ``action`` is

    ``register``      a new session (unless ``session.create`` is null), a new
                      event and its detail row, one artifact per ``new`` file;
    ``add_files``     new files on the group's event, which is there;
    ``attach_copy``   the group's files are another client's event's: they
                      are added to that event (``event.id``); no event or
                      session is made;
    ``correct``       the event is there with another digest: a new event
                      supersedes it (``event.supersedes`` -> ``event.id``,
                      ``changes`` lists old and new values), each active
                      artifact of the old event is superseded by a row of the
                      new one (``supersede``: old and new id, the storage
                      root's id and name, and the path; this includes files
                      other clients added to the event on other roots). Tags,
                      input edges and variables are carried at apply time
                      (``carried`` says so);
    ``move_session``  a ``correct`` whose only change is the session: a
                      recording arrived for a behavior session registered on
                      its own. The session it leaves stays and gets a note;
    ``none``          nothing to do;
    ``wait``, ``held`` not carried out: ``reason_code`` and ``reason`` say why.

    ``files`` lists every listed file of the group with its size and
    ``mtime_ns``; a file the action writes also has its ``sha256`` (it was
    read to its end by the scan, a ``.mat`` checked structurally) and a
    ``state``: ``new``, ``replace`` (other bytes at a registered path: a new
    artifact, and ``replaces`` is recorded as ``replaced`` by it), ``known``
    (registered already with these bytes: a memory row and a verification),
    ``registered`` (unchanged; nothing written) or ``held``. ``expect`` is
    what the scan found in the database for this group; ``apply`` compares.
``{"type": "time", "group", "read_us"}``
    when the group's files had been read (the ``verified_at`` of the
    verification rows ``apply`` writes).
``{"type": "end", "lines", "sha256", "content_sha256", "version", "database", "overrides_sha256"}``
    the last line. ``sha256`` is over every preceding line and the other
    members of this one; ``apply`` refuses a plan in which it does not match. ``content_sha256`` is over the
    preceding lines that are not of type ``time``: two scans of an unchanged
    tree and database give the same lines but for the ``time`` lines and
    this one, and the same ``content_sha256``.

Ids in a plan are deterministic (``uuid5`` under ``ids.NAMESPACE``): a new
artifact's from its root, path and SHA-256, a correction's from the event it
supersedes and the new digest, a superseding artifact row's from the row it
supersedes and the new event. A plan applied twice therefore cannot write
twice.

Corrections
-----------
As ``@CarasLabDB/supersedeEvent.m``: every column is carried forward except
those that change (the values stay inside the database; none passes through
a float), the input edges are copied, each active artifact of the old event
is superseded by a row for the same file produced by the new event and filed
under its subject and session, the current tags of the event and of each
artifact are copied through ``lab.fn_tag`` (a retired tag cannot be assigned
and is skipped; ``apply`` reports it), variables are carried by the
database's trigger, and no ``*_login`` column is sent.

A correction to another subject cannot use the session the event is in: a
session belongs to one subject for good (the events in it say so and cannot
change), and a path has one session. The old session is therefore moved
aside -- its ``relative_path`` gets the suffix ``#superseded-by-<new session
id>`` and a note -- and a session of the new subject is made at the path.
The event's ``client_digest`` keeps naming the session by the path's
deterministic id, as an unattended ``run`` computes it.
"""

from __future__ import annotations

import csv
import hashlib
import io
import os
import uuid

from . import engine, ids
from .database import ConnectionLost, Database, Directory, MemoryWrite
from .engine import FileWrite, GroupWrite, ListingFailed, Unreachable
from .model import TOOL_NAME, Group
from .report import COLUMNS

FORMAT = "caraslabdb-nas-plan/1"
ACTIONS = ("register", "add_files", "attach_copy", "correct", "move_session")
ASIDE = "#superseded-by-"
CARRIED = ("the tags of the event and of each superseded artifact, the event's input edges "
           "and its variables are carried at apply time, as they are then")


class PlanError(Exception):
    """The plan file cannot be used at all (edited, truncated, another format)."""


class Refused(Exception):
    """A group is not as the scan found it: nothing is written for it."""


def _uuid(text: str) -> str:
    return str(uuid.uuid5(ids.NAMESPACE, text))


def new_artifact_id(root: str, path: str, sha256: str) -> str:
    return _uuid("artifact:%s:%s:%s" % (root, path, sha256))


def correction_event_id(old_event: str, digest: str) -> str:
    return _uuid("correction:%s:%s" % (old_event, digest))


def successor_artifact_id(old_artifact: str, new_event: str) -> str:
    return _uuid("artifact-correction:%s:%s" % (old_artifact, new_event))


def subject_session_id(root: str, path: str, subject: str) -> str:
    return _uuid("session:%s:%s:subject:%s" % (root, path, subject))


# --------------------------------------------------------------------------- scan
def _fingerprint(rows) -> list:
    """The artifact rows at a path, as ``apply`` must find them again."""
    return sorted([r.artifact_id, r.current_id, r.checksum, bool(r.live)] for r in rows)


def _entry(f, state: str, **more) -> dict:
    out = {"path": f.path, "size": f.size, "mtime_ns": f.mtime_ns, "state": state}
    out.update({k: v for k, v in more.items() if v is not None})
    return out


def _group_record(s, g: Group, action: str, files: list, **more) -> dict:
    rec = {"type": "group", "directory": s.directory.id, "key": g.key, "kind": g.kind,
           "action": action, "source_path": g.source_path, "subject_id": g.subject_id,
           "files": sorted(files, key=lambda e: e["path"])}
    rec.update({k: v for k, v in more.items() if v is not None})
    return rec


def _held_record(s, g: Group, files: list, code: str, reason: str, action: str = "held",
                 **more) -> dict:
    return _group_record(s, g, action, files, reason_code=code, reason=reason, **more)


def _session_block(db: Database, s, g: Group, session_id, paired: bool, planned: dict,
                   correcting: bool):
    """(the plan's ``session`` block, a hold) for the session G's event goes into."""
    root_id = s.directory.root_id
    expect: dict = {}
    if paired:
        row = db.session(session_id) if session_id is not None else None
        if row is None:
            partner = g.pairing.partner_key
            if session_id is None or planned.get(partner) != session_id:
                return None, ("session_conflict", "the session of its recording does not exist")
            return {"id": session_id, "create": None, "needs_group": partner,
                    "expect": {session_id: None}}, None
        if row[0] != g.subject_id:
            return None, ("session_conflict", "session %s of its recording is subject %s's, "
                          "not %s's" % (session_id, row[0], g.subject_id))
        return {"id": session_id, "create": None, "expect": {session_id: row[0]}}, None
    row = db.session(session_id)
    expect[session_id] = None if row is None else row[0]
    aside = None
    target = session_id
    if row is not None and row[0] != g.subject_id:
        if not correcting:
            return None, ("session_conflict", "session %s is subject %s's, not %s's"
                          % (session_id, row[0], g.subject_id))
        # A session belongs to one subject for good: a session of the right
        # subject takes the path, and the old one is moved aside.
        target = subject_session_id(g.root, g.session_path, g.subject_id)
        other = db.session(target)
        expect[target] = None if other is None else other[0]
        if other is not None:
            if other[0] != g.subject_id:
                return None, ("session_conflict", "session %s is subject %s's" % (target, other[0]))
            return {"id": target, "create": None, "expect": expect}, None
        aside = {"id": session_id, "path": g.session_path + ASIDE + target,
                 "note": "Superseded by session %s: the files at %s are subject %s's, not %s's. "
                         "The path of this session was %s." % (target, g.session_path,
                                                              g.subject_id, row[0],
                                                              g.session_path)}
        row = None
    if row is not None:
        return {"id": target, "create": None, "expect": expect}, None
    for other, subject, label, path in db.session_clashes(target, g.subject_id, g.label,
                                                          root_id, g.session_path):
        if aside is not None and other == aside["id"]:
            continue                 # it holds the path until it is moved aside
        code = ("path_case_conflict" if path != g.session_path
                and engine.ascii_fold(path) == engine.ascii_fold(g.session_path)
                else "session_conflict")
        return None, (code, "session %s (subject %s, label %s, path %s) stands in the way"
                      % (other, subject, label, path))
    values = engine.session_values(g, target, root_id)
    return {"id": target, "create": values, "aside": aside, "expect": expect}, None


def scan_group(db: Database, s, g: Group, by_key: dict, conflicts: set, planned: dict,
               version: str) -> tuple[dict, int | None]:
    """Decide what the reviewed path would do with G; (its plan record, when it was read).

    Reads every file an action would write to its end. Writes nothing.
    """
    d = s.directory
    root_id = d.root_id
    files: list[dict] = [_entry(h, "held", code=h.reason_code, sentence=h.sentence)
                         for h in g.held_files]
    listed = [_entry(f, "listed") for f in g.files]
    if g.status == "skipped":
        return _group_record(s, g, "none", files + listed, note="skipped by an override"), None
    if g.status != "ready":
        for e in listed:
            if e["path"] in s.settled:
                e.update(state="registered", artifact_id=s.settled[e["path"]].current_id)
        return _held_record(s, g, files + listed, g.hold.reason_code, g.hold.sentence), None

    todo, file_holds = [], {}
    for f in g.files:
        m = s.memory.get(f.path)
        if f.path in s.settled:
            files.append(_entry(f, "registered", artifact_id=s.settled[f.path].current_id))
        elif (m is not None and m.status in ("registered", "known")
                and (m.size, m.mtime_ns) == (f.size, f.mtime_ns)):
            file_holds[f.path] = ("registered_but_withdrawn", "artifact %s of this file was "
                                  "retracted, or the file was recorded as moved, replaced or "
                                  "deleted" % m.artifact_id)
        elif f.path in conflicts:
            file_holds[f.path] = ("path_case_conflict", "another listed path differs from this "
                                  "one only in case")
        else:
            todo.append(f)
    at = db.artifacts_at(root_id, [f.path for f in todo])
    for f in list(todo):
        variants = sorted({r.path for r in at.get(f.path, []) if r.path != f.path})
        if variants:
            file_holds[f.path] = ("path_case_conflict", "registered as %s, which differs only "
                                  "in case" % variants[0])
            todo.remove(f)

    def held_files():
        return [_entry(f, "held", code=file_holds[f.path][0], sentence=file_holds[f.path][1])
                for f in g.files if f.path in file_holds]

    def unread():
        return [_entry(f, "listed") for f in todo]

    # The group as the database has it.
    own = s.events.get(ids.group_event_id(g))
    session_id = ids.group_session_id(g)
    paired = g.kind == "behavior" and g.pairing is not None and g.pairing.status == "paired"
    partner = by_key.get(g.pairing.partner_key) if paired else None
    if paired:
        rec = engine.registered_event(partner, s) if partner is not None else None
        if rec is not None:
            session_id = rec.session_id
        elif partner is not None and partner.key in planned:
            session_id = planned[partner.key]
        else:
            return _held_record(
                s, g, files + held_files() + unread(), None,
                "its recording %s is neither registered nor planned here (it is held, or its "
                "directory was not scanned with this one)"
                % (partner.source_path if partner is not None else g.pairing.partner_key),
                action="wait"), None
    if own is not None and own.retracted:
        return _held_record(s, g, files + held_files() + unread(), "registered_but_withdrawn",
                            "its event %s was retracted" % own.event_id), None
    digest = ids.client_digest(g, session_id) if session_id is not None else None
    correcting = own is not None and own.digest != digest
    hosts = sorted({s.events[s.settled[f.path].event_id].event_id for f in g.files
                    if f.path in s.settled})

    # Read what an action would write.
    readings = {}
    try:
        for f in todo:
            verify = g.layout == "epsych" and f.role == "raw" and f.format == "mat"
            reading, problem = engine.read_file(s.root_path, f, verify, s.stats)
            if problem is not None:
                return _held_record(s, g, files + held_files() + unread(), problem[0],
                                    "%s: %s" % (f.path.rsplit("/", 1)[1], problem[1])), None
            readings[f.path] = reading.checksum
    except engine.FileChanged as exc:
        return _held_record(s, g, files + held_files() + unread(), "changed_during_scan",
                            "%s changed while it was read" % exc.path), None
    except OSError as exc:
        return _held_record(s, g, files + held_files() + unread(), "unreadable_file",
                            "a file could not be read: %s" % exc), None
    read_us = db.now_us() if todo else None

    new, known = [], {}
    paths: dict[str, list] = {}
    for f in todo:
        c = readings[f.path]
        rows = at.get(f.path, [])
        paths[f.path] = _fingerprint(rows)
        live = [r for r in rows if r.live]
        same = [r for r in live if r.checksum_algo == "sha256" and r.checksum == c]
        if same:
            known[f.path] = same[0]
            files.append(_entry(f, "known", sha256=c, artifact_id=same[0].current_id))
        elif len(live) == 1:
            new.append((f, "replace", live[0].current_id))
        elif len(live) > 1:
            file_holds[f.path] = ("content_changed", "several registered files at this path "
                                  "hold other bytes: %s" % ", ".join(r.artifact_id for r in live))
        elif any(r.checksum == c for r in rows):
            file_holds[f.path] = ("registered_but_withdrawn", "these bytes were registered at "
                                  "this path and then retracted or recorded as moved, replaced "
                                  "or deleted")
        else:
            new.append((f, "new", None))
    held = held_files()
    expect: dict = {"event": {"id": ids.group_event_id(g),
                              "current": own.event_id if own is not None else None,
                              "digest": own.digest if own is not None else None},
                    "paths": paths}

    def written(attributes_of=None):
        out = []
        for f, state, replaces in new:
            attributes = attributes_of(f) if attributes_of is not None else dict(f.attributes)
            out.append(_entry(f, state, sha256=readings[f.path], role=f.role, format=f.format,
                              attributes=attributes, replaces=replaces,
                              artifact_id=new_artifact_id(g.root, f.path, readings[f.path])))
        return out

    def block(event_id, subject_id, session):
        return {"id": event_id, "subject_id": subject_id, "session_id": session}

    # The event is there and says the same: files are added to it.
    if own is not None and not correcting:
        expect["host"] = block(own.event_id, own.subject_id, own.session_id)
        action = "add_files" if new or known else "none"
        return _group_record(s, g, action, files + held + written(), expect=expect,
                             event=block(own.event_id, own.subject_id, own.session_id)), read_us

    # The event is there and says something else: a correction.
    if own is not None:
        hold = engine.time_hold(db, s, g)
        session, problem = (None, hold) if hold else _session_block(
            db, s, g, session_id, paired, planned, True)
        if problem is not None:
            return _held_record(s, g, files + held + written(), problem[0], problem[1]), read_us
        old = db.event_text(own.event_id, g.time_zone)
        changes = {}
        for name, value in (("subject_id", g.subject_id), ("session_id", session["id"]),
                            ("occurred_local", g.occurred_local)):
            if old[name] != value:
                changes[name] = [old[name], value]
        for name, value in sorted(g.detail.items()):
            if old["detail"].get(name) != str(value):
                changes["detail." + name] = [old["detail"].get(name), str(value)]
        was = old["attributes"].get("import", {})
        now = ids.import_block(g)
        if was != now:
            changes["import"] = [was, now]
        new_id = correction_event_id(own.event_id, digest)
        active = db.active_artifacts(own.event_id)
        names = {root_id: name for name, root_id in db.storage_roots().items()}
        supersede = [{"old": a, "new": successor_artifact_id(a, new_id), "storage_root_id": r,
                      "root": names[r], "path": p} for a, r, p, _c in active]
        move = (g.kind == "behavior" and paired and set(changes) == {"session_id"}
                and old["session_id"] is not None)
        note = None
        if move:
            note = {"session_id": old["session_id"],
                    "note": "The behavior event %s of this session was corrected to %s, which "
                            "is in session %s: its recording %s was registered later."
                            % (own.event_id, new_id, session["id"], partner.source_path)}
        expect["active"] = [a for a, _r, _p, _c in active]
        expect["sessions"] = session.pop("expect")
        event = block(new_id, g.subject_id, session["id"])
        event.update({"supersedes": own.event_id, "occurred_local": g.occurred_local,
                      "time_zone": g.time_zone, "detail": dict(g.detail),
                      "attributes": engine.event_attributes(g, session_id, version),
                      "drop_attributes": ["occurred_precision"]})
        return _group_record(s, g, "move_session" if move else "correct", files + held + written(),
                             expect=expect, event=event, session=session, supersede=supersede,
                             changes=changes, session_note=note, carried=CARRIED), read_us

    # No event of its own: another client's, a copy, or new.
    facts = db.event_facts([a.event_id for a in known.values()])
    hosts = sorted(set(hosts) | {facts[a.event_id].event_id for a in known.values()})
    hold = None
    host = None
    raw = sorted({readings[f.path] for f in g.files if f.role == "raw" and f.path in readings})
    if len(hosts) > 1:
        hold = ("copy_ambiguous", "its files at these paths belong to events %s" % ", ".join(hosts))
    elif len(hosts) == 1:
        host = db.event_facts(hosts)[hosts[0]]
    elif held:
        hold = (held[0]["code"], "a file of the group is held: %s" % held[0]["sentence"])
    else:
        copies = db.raw_copies(raw)
        sets = [{e for e, _a, _w in copies.get(c, [])} for c in raw]
        common = sorted(set.intersection(*sets)) if sets else []
        also = sorted(set().union(*sets)) if sets else []
        expect["copies"] = {"checksums": raw, "common": common}
        if len(common) > 1:
            hold = ("copy_ambiguous", "its raw files are, by their SHA-256, the files of each "
                    "of events %s" % ", ".join(common))
        elif len(common) == 1 and db.written_by(common[0], TOOL_NAME):
            where = sorted({w for c in raw for e, _a, w in copies[c] if e == common[0]})
            hold = ("duplicate_content", "its raw files hold the bytes this tool registered "
                    "already as %s (event %s)" % (", ".join(where[:3]), common[0]))
        elif len(common) == 1:
            host = db.event_facts(common)[common[0]]
    if host is not None and hold is None:
        hold = engine.host_hold(g, host)
    if hold is not None:
        return _held_record(s, g, files + held + written(), hold[0], hold[1]), read_us
    if host is not None:
        theirs = db.event_artifacts(host.event_id)
        expect["host"] = block(host.event_id, host.subject_id, host.session_id)
        return _group_record(
            s, g, "attach_copy" if new or known else "none",
            files + held + written(lambda f: engine.copy_attributes(
                g, f.attributes, host.event_id, theirs.get(readings[f.path]), version)),
            expect=expect, event=block(host.event_id, host.subject_id, host.session_id)), read_us

    hold = engine.time_hold(db, s, g)
    session, problem = (None, hold) if hold else _session_block(
        db, s, g, session_id, paired, planned, False)
    if problem is not None:
        return _held_record(s, g, files + held + written(), problem[0], problem[1]), read_us
    expect["sessions"] = session.pop("expect")
    values = engine.event_values(g, session["id"], version, also)
    event = block(values["event_id"], g.subject_id, session["id"])
    event.update({"event_type": g.kind, "occurred_local": g.occurred_local,
                  "time_zone": g.time_zone, "detail": values["detail"],
                  "attributes": engine.event_attributes(g, session["id"], version, also)})
    return _group_record(s, g, "register", files + held + written(), expect=expect, event=event,
                         session=session), read_us


def directory_record(d: Directory, partners: list[Directory]) -> dict:
    return {"type": "directory", "id": d.id, "root": d.root, "root_id": d.root_id, "path": d.path,
            "layout": d.layout, "rig": d.rig, "pair_with": d.pair_with, "time_zone": d.time_zone,
            "min_age_min": d.min_age_min, "mode": d.mode,
            "partner": partners[0].id if partners else None}


def scan_directory(db: Database, d: Directory, root_path: str, overrides, cache, planned: dict,
                   version: str = engine.VERSION) -> list[dict]:
    """The plan records of one directory. Writes nothing."""
    records: list[dict] = []
    try:
        s = engine.sight(db, d, root_path, overrides, cache)
    except (Unreachable, ListingFailed) as exc:
        return [directory_record(d, []), {"type": "failed", "directory": d.id,
                                          "reason": str(exc)}]
    listed_us = db.now_us()
    records.append(directory_record(d, s.partners))
    records.append({"type": "time", "directory": d.id, "listed_us": listed_us,
                    "listed": engine.us_text(listed_us)})
    for h in s.interp.held:
        if h.path in s.stat_of:
            records.append({"type": "held", "directory": d.id, "path": h.path,
                            "code": h.reason_code, "sentence": h.sentence})
    conflicts = engine.case_conflicts(s.stat_of)
    by_key = {g.key: g for g in s.interp.groups}
    for g in s.groups():
        rec, read_us = scan_group(db, s, g, by_key, conflicts, planned, version)
        records.append(rec)
        if rec["action"] in ACTIONS or rec["action"] == "none":
            session = rec.get("event", {}).get("session_id")
            if g.kind == "recording" and session is not None:
                planned[g.key] = session
        if read_us is not None and rec["action"] in ACTIONS:
            records.append({"type": "time", "group": g.key, "read_us": read_us})
    return records


def scan_order(directories: list[Directory]) -> list[Directory]:
    """Directories that name a partner (the recordings) before the others, then by id."""
    return sorted(directories, key=lambda d: (d.pair_with is None, d.id))


def plan_text(records: list[dict], version: str, database: dict, overrides_sha256: str | None
              ) -> str:
    """The plan file's text: one canonical JSON line per record, and the end line."""
    lines = [ids.canonical_json(r) for r in records]
    content = [line for line, r in zip(lines, records) if r["type"] != "time"]
    end = {"type": "end", "lines": len(lines),
           "content_sha256": ids.sha256_text("".join(line + "\n" for line in content)),
           "version": version, "database": database, "overrides_sha256": overrides_sha256}
    end["sha256"] = plan_digest(lines, end)
    return "".join(line + "\n" for line in lines) + ids.canonical_json(end) + "\n"


def plan_digest(lines: list[str], end: dict) -> str:
    """SHA-256 over every line before the end line and over the end line's other members."""
    rest = {k: v for k, v in end.items() if k != "sha256"}
    return ids.sha256_text("".join(line + "\n" for line in lines) + ids.canonical_json(rest))


# --------------------------------------------------------------------------- the plan, read
class PlanFile:
    """A plan as ``apply`` reads it. :class:`PlanError` when it cannot be trusted."""

    def __init__(self, path: str):
        import json
        try:
            with open(path, "rb") as fh:
                raw = fh.read()
            text = raw.decode("utf-8")
        except (OSError, UnicodeError) as exc:
            raise PlanError("the plan %s cannot be read: %s" % (path, exc)) from None
        lines = text.split("\n")
        if len(lines) < 3 or lines[-1] != "":
            raise PlanError("the plan %s is truncated: it does not end with its end line" % path)
        lines = lines[:-1]
        try:
            records = [json.loads(line) for line in lines]
        except ValueError as exc:
            raise PlanError("the plan %s is not JSON lines: %s" % (path, exc)) from None
        if any(not isinstance(r, dict) or "type" not in r for r in records):
            raise PlanError("the plan %s holds a line that is not a plan record" % path)
        self.end = records[-1]
        if self.end["type"] != "end":
            raise PlanError("the plan %s is truncated: its last line is not the end line" % path)
        if (self.end.get("sha256") != plan_digest(lines[:-1], self.end)
                or self.end.get("lines") != len(lines) - 1):
            raise PlanError("the plan %s was changed after it was written: its digest does not "
                            "match (edited or truncated). Scan again." % path)
        head = records[0]
        if head.get("type") != "plan" or head.get("format") != FORMAT:
            raise PlanError("the plan %s has the format %r; this tool applies %r. Scan again "
                            "with this version." % (path, head.get("format"), FORMAT))
        self.path = path
        self.records = records[1:-1]
        self.directories = [r for r in self.records if r["type"] == "directory"]
        self.listed = {r["directory"]: r["listed_us"] for r in self.records
                       if r["type"] == "time" and "directory" in r}
        self.read = {r["group"]: r["read_us"] for r in self.records
                     if r["type"] == "time" and "group" in r}
        self.groups = [r for r in self.records if r["type"] == "group"]


# --------------------------------------------------------------------------- apply
def _check(condition: bool, reason: str) -> None:
    if not condition:
        raise Refused(reason)


def check_files(root_path: str, rec: dict) -> None:
    """Every listed file of the group has the size and ``mtime_ns`` of the plan."""
    for f in rec["files"]:
        seen = engine._lstat(os.path.join(root_path, *f["path"].split("/")))
        if f["state"] == "held" and seen is None:
            continue                       # a link or special entry held by the scan
        _check(seen == (f["size"], f["mtime_ns"]),
               "%s is not as the scan saw it (%s bytes, mtime_ns %s then; %s now)"
               % (f["path"], f["size"], f["mtime_ns"],
                  "gone" if seen is None else "%d bytes, mtime_ns %d" % seen))


def check_database(db: Database, d: Directory, rec: dict, dry_sessions=frozenset()) -> None:
    """The database is as the scan found it for this group, else :class:`Refused`.

    DRY_SESSIONS: the sessions a dry run would have made by now.
    """
    expect = rec["expect"]
    want = expect["event"]
    own = db.event_facts([want["id"]]).get(want["id"])
    if want["current"] is None:
        _check(own is None, "event %s is in the database now" % want["id"])
    else:
        _check(own is not None and own.event_id == want["current"] and own.digest == want["digest"]
               and not own.retracted, "event %s was corrected or retracted since the scan"
               % want["id"])
    host = expect.get("host")
    if host is not None:
        fact = db.event_facts([host["id"]]).get(host["id"])
        _check(fact is not None and fact.event_id == host["id"] and not fact.retracted
               and (fact.subject_id, fact.session_id) == (host["subject_id"], host["session_id"]),
               "event %s is not as the scan found it" % host["id"])
    at = db.artifacts_at(d.root_id, list(expect["paths"]))
    for path, want_rows in expect["paths"].items():
        _check(_fingerprint(at.get(path, [])) == want_rows,
               "the artifacts registered at %s changed since the scan" % path)
    settled = {f["artifact_id"]: f["path"] for f in rec["files"] if f["state"] == "registered"}
    facts = db.artifact_facts(settled)
    for artifact_id, path in settled.items():
        fact = facts.get(artifact_id)
        _check(fact is not None and fact.live and fact.current_id == artifact_id,
               "artifact %s of %s is no longer current and present" % (artifact_id, path))
    if "active" in expect:
        now = [a for a, _r, _p, _c in db.active_artifacts(want["current"])]
        _check(now == expect["active"], "the active artifacts of event %s changed since the scan"
               % want["current"])
    for session_id, subject in expect.get("sessions", {}).items():
        row = db.session(session_id)
        if subject is None and rec.get("session", {}).get("needs_group"):
            _check(session_id in dry_sessions or row is not None and row[0] == rec["subject_id"],
                   "the session %s of its recording does not exist: apply the recording's "
                   "group %s first" % (session_id, rec["session"]["needs_group"]))
        else:
            _check((None if row is None else row[0]) == subject,
                   "session %s is not as the scan found it" % session_id)
    session = rec.get("session")
    if session is not None and session.get("create") is not None:
        v = session["create"]
        clashes = [c for c in db.session_clashes(v["session_id"], v["subject_id"], v["label"],
                                                 v["root_id"], v["path"])
                   if not (session.get("aside") and c[0] == session["aside"]["id"])]
        _check(not clashes, "session %s now stands in the way" % (clashes[0][0] if clashes else ""))
    copies = expect.get("copies")
    if copies is not None:
        found = db.raw_copies(copies["checksums"])
        sets = [{e for e, _a, _w in found.get(c, [])} for c in copies["checksums"]]
        common = sorted(set.intersection(*sets)) if sets else []
        _check(common == copies["common"], "the events that hold these raw bytes changed since "
               "the scan")


def apply_group(db: Database, run_id: int | None, d: Directory, rec: dict, read_us: int | None,
                dry_run: bool = False, dry_sessions: set | None = None) -> list[str]:
    """Carry out one planned group in ONE transaction; returns notes for the report.

    Raises :class:`Refused` (nothing written) when the database is not as the
    scan found it. With DRY_RUN the checks are made and nothing is written.
    """
    notes: list[str] = []
    with db.transaction():
        check_database(db, d, rec, dry_sessions or frozenset())
        if dry_run:
            if dry_sessions is not None and (rec.get("session") or {}).get("create"):
                dry_sessions.add(rec["session"]["id"])
            return notes
        event = rec["event"]
        session = rec.get("session") or {}
        w = GroupWrite(rec["key"], event["id"], event["subject_id"], event["session_id"],
                       read_us=read_us)
        if session.get("aside"):
            db.session_note(session["aside"]["id"], session["aside"]["note"],
                            session["aside"]["path"])
        if session.get("create"):
            w.session = dict(session["create"])
        rows: list[MemoryWrite] = []
        successor: dict[str, str] = {}
        if rec["action"] in ("correct", "move_session"):
            if w.session is not None:
                db.insert_session(**w.session)
                w.session = None
            old = event["supersedes"]
            db.supersede_event(old, event["id"], event["subject_id"], event["session_id"],
                               event["occurred_local"], event["time_zone"],
                               ids.canonical_json(event["attributes"]), event["drop_attributes"],
                               event["detail"])
            retired = [("event " + event["id"], t) for t in db.carry_tags("event", old,
                                                                         event["id"])]
            for item in rec["supersede"]:
                old_artifact, new_artifact = item["old"], item["new"]
                db.supersede_artifact(old_artifact, new_artifact, event["id"])
                retired += [("artifact " + new_artifact, t)
                            for t in db.carry_tags("artifact", old_artifact, new_artifact)]
                successor[old_artifact] = new_artifact
            for what, tag in retired:
                notes.append("the retired tag %s was not carried forward to %s" % (tag, what))
            if rec.get("session_note"):
                db.session_note(rec["session_note"]["session_id"], rec["session_note"]["note"])
        elif rec["action"] == "register":
            w.event = {"event_id": event["id"], "event_type": event["event_type"],
                       "subject_id": event["subject_id"], "session_id": event["session_id"],
                       "occurred_local": event["occurred_local"], "zone": event["time_zone"],
                       "attributes": ids.canonical_json(event["attributes"]),
                       "detail": event["detail"]}
        for f in rec["files"]:
            if f["state"] in ("new", "replace"):
                w.files.append(FileWrite(f["path"], f["size"], f["mtime_ns"], f["sha256"],
                                         f["state"], f.get("role"), f.get("format"),
                                         f["attributes"], f["artifact_id"],
                                         successor.get(f.get("replaces"), f.get("replaces"))))
            elif f["state"] == "known":
                w.files.append(FileWrite(f["path"], f["size"], f["mtime_ns"], f["sha256"], "known",
                                         artifact_id=successor.get(f["artifact_id"],
                                                                   f["artifact_id"])))
            elif f["state"] == "registered" and f["artifact_id"] in successor:
                rows.append(MemoryWrite(f["path"], "registered", f["size"], f["mtime_ns"],
                                        rec["key"], artifact_id=successor[f["artifact_id"]]))
        rows += engine.write_group(db, d.root_id, w)
        db.write_memory(run_id, d.root_id, rows)
    return notes


def apply_directory(db: Database, plan: PlanFile, record: dict, root_path: str, only: set,
                    dry_run: bool, version: str, host: str, dry_sessions: set | None = None
                    ) -> dict:
    """Apply one directory's planned groups; the caller holds its lock.

    Appends ``lab.scan_run`` (command ``apply``, no ``due_at``) and, at the
    end, its result. Returns ``{"applied": [...], "refused": [(key, why)],
    "notes": [...], "run_id": ...}``.
    """
    out = {"applied": [], "refused": [], "notes": [], "run_id": None, "started": "",
           "directory": record}
    groups = [g for g in plan.groups if g["directory"] == record["id"] and g["action"] in ACTIONS
              and (not only or g["key"] in only)]
    d = db.directory(record["id"])
    same = d is not None and (d.root_id, d.path, d.layout, d.time_zone) == (
        record["root_id"], record["path"], record["layout"], record["time_zone"])
    if not same:
        out["refused"] = [(g["key"], "the directory is no longer listed as the plan says")
                          for g in groups]
        return out
    if not dry_run:
        out["run_id"], _started, out["started"] = db.insert_run(d.id, "apply", "register", None,
                                                                version, host)
        d = db.directory(record["id"])
    listed_us = plan.listed.get(record["id"])
    counters = dict.fromkeys(("files_registered", "files_known", "groups_registered"), 0)
    try:
        for rec in groups:
            try:
                age_us = db.now_us() - listed_us
                _check(age_us >= d.min_age_min * 60_000_000,
                       "the plan's listing is %d min old; the directory's min_age_min is %d"
                       % (age_us // 60_000_000, d.min_age_min))
                check_files(root_path, rec)
                notes = apply_group(db, out["run_id"], d, rec, plan.read.get(rec["key"]), dry_run,
                                    dry_sessions)
            except Refused as exc:
                out["refused"].append((rec["key"], str(exc)))
                continue
            except OSError as exc:
                out["refused"].append((rec["key"], "a file could not be examined: %s" % exc))
                continue
            except db.error_types() as exc:
                if db.lost(exc):
                    raise ConnectionLost(str(exc)) from exc
                out["refused"].append((rec["key"], "the database refused it: %s"
                                       % str(exc).strip().splitlines()[0]))
                continue
            out["applied"].append(rec["key"])
            out["notes"] += ["%s: %s" % (rec["key"], n) for n in notes]
            counters["groups_registered"] += 1
            counters["files_registered"] += sum(1 for f in rec["files"]
                                                if f["state"] in ("new", "replace"))
            counters["files_known"] += sum(1 for f in rec["files"] if f["state"] == "known")
    finally:
        if out["run_id"] is not None and not db.lost():
            refused = len(out["refused"])
            db.insert_result(
                out["run_id"], "failed" if refused else "ok", counters,
                "applied %d group(s) of plan %s%s" % (
                    len(out["applied"]), os.path.basename(plan.path),
                    "; %d refused" % refused if refused else ""),
                {"plan": {"file": os.path.basename(plan.path), "sha256": plan.end["sha256"]},
                 "applied": out["applied"][:200],
                 "refused": [{"group": k, "reason": why} for k, why in out["refused"][:200]]})
    return out


# --------------------------------------------------------------------------- the scan's report
def scan_report(records: list[dict]) -> tuple[str, str]:
    """(CSV, text) of a plan, for the person who reviews it."""
    out = io.StringIO(newline="")
    writer = csv.DictWriter(out, COLUMNS, lineterminator="\n")
    writer.writeheader()
    text: list[str] = []
    roots = {}
    for r in records:
        if r["type"] == "directory":
            roots[r["id"]] = r["root"]
            text += ["", "Directory %d %s:%s (%s, mode %s, min_age_min %d)"
                     % (r["id"], r["root"], r["path"], r["layout"], r["mode"], r["min_age_min"])]
        elif r["type"] == "time" and "directory" in r:
            text.append("  listed completely at %s" % r["listed"])
        elif r["type"] == "failed":
            text.append("  NOT PLANNED: %s" % r["reason"])
            writer.writerow(dict.fromkeys(COLUMNS, "") | {
                "what": "directory", "action": "failed", "root": roots[r["directory"]],
                "detail": r["reason"]})
        elif r["type"] == "held":
            writer.writerow(dict.fromkeys(COLUMNS, "") | {
                "what": "file", "action": "held", "root": roots[r["directory"]],
                "path": r["path"], "reason_code": r["code"], "detail": r["sentence"]})
        elif r["type"] == "group":
            detail = r.get("reason") or r.get("note") or ""
            if r.get("changes"):
                detail = "; ".join("%s: %s -> %s" % (k, ids.canonical_json(v[0]),
                                                      ids.canonical_json(v[1]))
                                   for k, v in sorted(r["changes"].items()))
            event = r.get("event", {})
            writer.writerow(dict.fromkeys(COLUMNS, "") | {
                "what": "group", "action": r["action"], "root": roots[r["directory"]],
                "path": r["source_path"], "group_key": r["key"],
                "reason_code": r.get("reason_code") or "", "detail": detail,
                "event_id": event.get("id", "")})
            for f in r["files"]:
                writer.writerow(dict.fromkeys(COLUMNS, "") | {
                    "what": "file", "action": f["state"], "root": roots[r["directory"]],
                    "path": f["path"], "group_key": r["key"], "reason_code": f.get("code", ""),
                    "detail": f.get("sentence", "") or f.get("sha256", ""),
                    "size_bytes": f["size"], "mtime_ns": f["mtime_ns"],
                    "artifact_id": f.get("artifact_id", ""), "event_id": event.get("id", "")})
    groups = [r for r in records if r["type"] == "group"]
    summary = ["%d %s" % (sum(1 for g in groups if g["action"] == a), a)
               for a in ACTIONS + ("none", "wait", "held")
               if any(g["action"] == a for g in groups)]
    head = ["Plan: " + (", ".join(summary) or "no group"),
            "%d file(s) outside any group are held."
            % sum(1 for r in records if r["type"] == "held")]
    for action in ACTIONS + ("wait", "held"):
        mine = [g for g in groups if g["action"] == action]
        if not mine:
            continue
        text += ["", "%s (%d group(s))" % (action, len(mine))]
        for g in mine:
            n = sum(1 for f in g["files"] if f["state"] in ("new", "replace", "known"))
            line = "  %s" % g["source_path"]
            if action in ACTIONS:
                line += ": %d file(s)" % n
            if g.get("reason"):
                line += ": %s%s" % (g["reason_code"] + "; " if g.get("reason_code") else "",
                                    g["reason"])
            text.append(line)
            for k, v in sorted(g.get("changes", {}).items()):
                text.append("      %s: %s -> %s" % (k, ids.canonical_json(v[0]),
                                                     ids.canonical_json(v[1])))
            for f in g["files"]:
                if f["state"] == "replace":
                    text.append("      %s: other bytes; artifact %s is recorded as replaced"
                                % (f["path"], f["replaces"]))
            if g.get("session", {}).get("aside"):
                text.append("      session %s is moved aside (%s)"
                            % (g["session"]["aside"]["id"], g["session"]["aside"]["path"]))
            for item in g.get("supersede", []):
                text.append("      supersedes artifact %s at %s:%s"
                            % (item["old"], item["root"], item["path"]))
            if g.get("carried"):
                text.append("      " + g["carried"])
    return out.getvalue(), "\n".join(head + text).rstrip("\n") + "\n"


def apply_report(plan: PlanFile, out: dict) -> tuple[str, str]:
    """(CSV, text) of what ``apply`` did in one directory: applied, refused and why, notes.

    The CSV has the columns of a run's report (``report.COLUMNS``): a
    ``group`` row per group with action ``applied`` or ``refused`` (the
    plan's action is the first word of ``detail``), a ``file`` row per file
    written for an applied group (``registered`` or ``known``), and a
    ``group`` row with action ``note`` per note.
    """
    record = out["directory"]
    groups = {g["key"]: g for g in plan.groups}
    table = io.StringIO(newline="")
    writer = csv.DictWriter(table, COLUMNS, lineterminator="\n")
    writer.writeheader()

    def row(**values):
        writer.writerow(dict.fromkeys(COLUMNS, "") | {"root": record["root"]} | values)

    text = ["apply of plan %s (sha256 %s) to directory %d %s:%s: %d group(s) applied, %d refused"
            % (os.path.basename(plan.path), plan.end["sha256"], record["id"], record["root"],
               record["path"], len(out["applied"]), len(out["refused"])), ""]
    if out["applied"]:
        text.append("Applied (%d group(s))" % len(out["applied"]))
    for key in out["applied"]:
        g = groups[key]
        event = g.get("event", {}).get("id", "")
        written = [f for f in g["files"] if f["state"] in ("new", "replace", "known")]
        row(what="group", action="applied", path=g["source_path"], group_key=key, event_id=event,
            detail="%s: %d file(s)" % (g["action"], len(written)))
        text.append("  %s: %s, %d file(s)" % (g["source_path"], g["action"], len(written)))
        for name, change in sorted(g.get("changes", {}).items()):
            text.append("      %s: %s -> %s" % (name, ids.canonical_json(change[0]),
                                                 ids.canonical_json(change[1])))
        for f in written:
            row(what="file", action="known" if f["state"] == "known" else "registered",
                path=f["path"], group_key=key, size_bytes=f["size"], mtime_ns=f["mtime_ns"],
                artifact_id=f["artifact_id"], event_id=event,
                detail="replaces artifact %s" % f["replaces"] if f["state"] == "replace" else "")
    if out["refused"]:
        text += ["", "Refused (%d group(s)); nothing was written for them"
                 % len(out["refused"])]
    for key, why in out["refused"]:
        g = groups[key]
        row(what="group", action="refused", path=g["source_path"], group_key=key,
            detail="%s: %s" % (g["action"], why))
        text.append("  %s (%s): %s" % (g["source_path"], g["action"], why))
    if out["notes"]:
        text += ["", "Notes"]
    for note in out["notes"]:
        key = note.split(": ", 1)[0]
        row(what="group", action="note", group_key=key if key in groups else "", detail=note)
        text.append("  " + note)
    text += ["", NOT_READ]
    return table.getvalue(), "\n".join(text) + "\n"


NOT_READ = ("The files were not read again: each had the size and modification time the scan "
            "recorded, and the verification rows carry the time of the scan's read.")


def write_apply_report(report_dir: str, plan: PlanFile, out: dict) -> str:
    """Write the CSV and the text report of one directory's apply; returns the text's path."""
    os.makedirs(report_dir, exist_ok=True)
    stem = os.path.join(report_dir, "%s_dir%d_run%d" % (out["started"], out["directory"]["id"],
                                                        out["run_id"]))
    table, text = apply_report(plan, out)
    with open(stem + ".csv", "w", encoding="utf-8", newline="") as fh:
        fh.write(table)
    with open(stem + ".txt", "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    return stem + ".txt"


def file_digest(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()
