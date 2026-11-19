"""The importer's engine: one search of one listed directory.

Used by ``tools/import_nas_files.py run``; ``scan`` and ``apply`` are meant to
reuse the same four steps:

1. :func:`sight` -- list the directory and the directory it is paired with
   (``walk.walk``), load the scan memory and what the database knows of the
   files and events, and interpret (``interpret.interpret``). Nothing is
   written.
2. :func:`plan` -- decide, for every listed file of the directory, what the
   scan memory should say (``pending``, ``held``, unchanged, nothing), and for
   every group whether it is registered, held, waiting or ready to be
   registered now. Nothing is written.
3. :func:`read_group` -- read a ready group's unregistered files to their end
   (SHA-256 in 4 MiB chunks, ``lstat`` before and after, the structural check
   of ``.mat`` files).
4. :func:`register_group` -- write the group in ONE transaction: the session,
   the event and its detail row, one artifact and one ``ok`` verification per
   file, and the group's memory rows.

:func:`run_directory` strings them together for an unattended run and always
appends the ``lab.scan_run_result`` row.

**An unattended run only adds.** It never supersedes, retracts or records a
disposition. Whatever would need one of those is held with a reason code
(:data:`RUN_REASON_CODES`) and left for a person.

**The stability rule** (:func:`stability`). A group may be registered by a run
R only when every file listed in it now (registrable or held one by one)

* has a latest memory row that was written by an EARLIER run, and
* that row gives the same size, the same ``mtime_ns``, the same group and the
  same state the file would be given now (so this run appends no row for any
  file of the group), and
* no file that belonged to the group is gone but not yet recorded ``cleared``,

and ``W + min_age_min <= started_at(R)``, where W is the latest
``scan_run.started_at`` among the runs that wrote those rows and the runs
that wrote a ``cleared`` row for a file of the group. Both times are the
database's clock. A memory row is appended whenever what is seen of a file
differs from its latest row, and only by a run whose listing was complete, so
"the latest row equals what is listed now" means: a complete listing made at
W showed exactly these files with these sizes and modification times, and no
complete listing since showed anything else. A file added, changed or gone
appends a row (``pending`` / ``cleared``) and so moves W to the run that saw
it: the wait starts again for the whole group. The first sighting of a group
never registers it (its rows are written by that run itself), also with
``min_age_min = 0``; the second can.

The wait is counted from the START of the earlier run: its listing ended at
most a listing's duration later, so the true interval between the two
listings can be shorter than ``min_age_min`` by that duration. Choose
``min_age_min`` with that in mind.

**One folder, one root.** A storage root should carry its
``.caraslabdb-root.json`` marker (naming the root): the tool then refuses the
folder under any other root name. Without the marker nothing stops two
invocations from searching one folder under two root names, and its files
would be registered under both.

**What is not read again.** A file whose latest row is ``registered`` or
``known`` with the size and ``mtime_ns`` listed now, and whose artifact's
current version still describes that file and is in ``lab.artifact_present``,
is not opened (its header comes from the cache, restricted to exactly those
files). A file held after it was read to its end -- the reason then ends with
``[read: sha256=...]`` -- is not read again while its size and ``mtime_ns``
stay the same: the hold stands until a person acts (``scan`` / ``apply``).
Holds decided without reading (``would_correct``, ``late_recording``,
``path_case_conflict``, the session and time checks) are decided anew at
every run and end by themselves when their cause is gone.
"""

from __future__ import annotations

import dataclasses
import hashlib
import os
import stat as stat_module
import traceback
from contextlib import contextmanager
from dataclasses import dataclass, field

from . import content, ids, mat5, walk
from .names import ascii_fold
from .cache import HeaderCache
from .database import (ArtifactFact, Database, Directory, EventFact, MemoryRow, MemoryWrite)
from .interpret import interpret
from .model import TOOL_NAME, DirectorySpec, Group, GroupFile, Interpretation, Listing

VERSION = "1.0"
CHUNK = 4 * 1024 * 1024
READ_MARK = "[read: sha256="

# Reason codes of holds decided against the database (the interpretation's own
# are model.REASON_CODES). Stored in lab.scan_file.reason_code: never rename.
RUN_REASON_CODES: dict[str, str] = {
    "would_correct": "the group's event is in the database with another digest: registering "
                     "it would be a correction",
    "content_changed": "other bytes at a registered path: registering them would record the "
                       "registered file as replaced",
    "late_recording": "a recording that arrives for a behavior session already registered in "
                      "a session of its own",
    "path_case_conflict": "a path that differs only in case from a registered or another "
                          "listed path",
    "registered_but_withdrawn": "the file's artifact, or the group's event, was retracted, or "
                                "the file was recorded as moved, replaced or deleted",
    "copy_ambiguous": "the group's files are, by path or by their bytes, files of more than "
                      "one event already in the database",
    "copy_event_mismatch": "the event the group's files already belong to is another "
                           "subject's or of another type",
    "duplicate_content": "the group's raw files hold the bytes this tool registered already "
                         "under another name",
    "session_conflict": "the session the group needs cannot be used: another session holds "
                        "its label or path, or it belongs to another subject",
    "local_time_nonexistent": "the wall-clock time of the name does not exist in the "
                              "directory's time zone (the clocks went forward)",
    "local_time_ambiguous": "the wall-clock time of the name occurs twice in the directory's "
                            "time zone (the clocks went back)",
    "paired_recording_held": "the recording it pairs with is held",
}


class Unreachable(Exception):
    """The directory is missing or empty: nothing is concluded, nothing else written."""


class ListingFailed(Exception):
    """A listing is not complete or cannot be made: the run fails and writes nothing else."""


class FileChanged(Exception):
    """A file is not what the listing said when it is read."""

    def __init__(self, path: str, seen: tuple[int, int] | None):
        super().__init__(path)
        self.path = path
        self.seen = seen            # (size, mtime_ns) now, or None when the file is gone


@dataclass
class ReadStats:
    files_opened: int = 0           # files opened for their header
    header_bytes: int = 0
    files_read: int = 0             # files read to their end
    read_bytes: int = 0

    @property
    def bytes_read(self) -> int:
        return self.header_bytes + self.read_bytes


class _CountingFile:
    """A binary file whose reads are counted."""

    def __init__(self, fh, stats: ReadStats):
        self._fh = fh
        self._stats = stats

    def read(self, n: int = -1):
        data = self._fh.read(n)
        self._stats.header_bytes += len(data)
        return data

    def __getattr__(self, name):
        return getattr(self._fh, name)


@contextmanager
def count_header_reads(stats: ReadStats):
    """Count the files the interpretation opens and the bytes it asks of them.

    ``cache.HeaderReader`` opens files through the module attribute
    ``content.open_listed`` (the seam its own test uses); it is replaced for
    the duration by one that counts and restored afterwards.
    """
    real = content.open_listed

    @contextmanager
    def counting(root_path, listed):
        stats.files_opened += 1
        with real(root_path, listed) as fh:
            yield _CountingFile(fh, stats)

    content.open_listed = counting
    try:
        yield
    finally:
        content.open_listed = real


def verify_mat(fh, size: int) -> None:
    """The full structural pass of a ``.mat`` file about to be registered.

    ``mat5.verify_file`` inflates every compressed variable to its end and
    raises ``MatProblem`` on damage (a seam for tests).
    """
    mat5.verify_file(fh, size)


def us_text(us: int) -> str:
    """Microseconds since 1970 as UTC text, by integer arithmetic."""
    return ids.mtime_text(us * 1000)[:19] + "Z"


# --------------------------------------------------------------------------- sighting
@dataclass
class Sighting:
    """Everything a run knows before it decides anything (see :func:`sight`)."""
    directory: Directory
    partners: list[Directory]
    root_path: str
    listing: Listing                          # the directory's own
    interp: Interpretation
    memory: dict[str, MemoryRow]              # own and paired directories
    artifacts: dict[str, ArtifactFact]        # by the artifact id a memory row names
    events: dict[str, EventFact]              # by the event id asked for
    stat_of: dict[str, tuple[int, int]]       # own listed entry -> (size, mtime_ns)
    settled: dict[str, ArtifactFact]          # own and paired: files not opened
    stats: ReadStats
    cache_keys: set = field(default_factory=set)
    local_time: dict = field(default_factory=dict)

    def own(self, path: str) -> bool:
        return path.startswith(self.directory.path + "/")

    def groups(self) -> list[Group]:
        d = self.directory
        return sorted((g for g in self.interp.groups if g.root == d.root and g.directory == d.path),
                      key=lambda g: g.key)


def _spec(d: Directory, pair_with: str | None, paired_by: str | None) -> DirectorySpec:
    kw = dict(root=d.root, path=d.path, layout=d.layout, time_zone=d.time_zone,
              min_age_min=d.min_age_min, rig=d.rig, pair_with=pair_with)
    if any(f.name == "paired_by" for f in dataclasses.fields(DirectorySpec)):
        kw["paired_by"] = paired_by
    return DirectorySpec(**kw)


def pair_specs(directory: Directory, every: list[Directory]
               ) -> tuple[DirectorySpec, list[tuple[Directory, DirectorySpec]]]:
    """The directory's spec and that of the directory judged with it.

    The partner is the directory it names in ``pair_with``, or the directory
    that names it: the one that is not ``off`` or, when there is none, the
    most recent ``off`` one. A partner is listed and judged whatever its
    mode -- a session that pairs with a recording visible on disk must not be
    registered on its own because the recordings' directory is ``off`` or in
    ``report`` mode; it waits. More than one directory that is not ``off``
    naming the same one is refused (:class:`ListingFailed`): the
    interpretation names one partner.
    """
    same_root = {d.id: d for d in every if d.root_id == directory.root_id}
    same_root[directory.id] = directory
    target = same_root.get(directory.pair_with) if directory.pair_with is not None else directory
    if target is None:
        return _spec(directory, None, None), []
    namers = [d for d in same_root.values() if d.pair_with == target.id]
    on = [d for d in namers if d.mode != "off" or d.id == directory.id]
    if directory.pair_with is not None:
        if len(on) > 1:
            raise ListingFailed("directories %s all pair with %s; one directory may be paired "
                                "with one other" % (", ".join(d.name for d in on), target.name))
        namer = directory
    elif len(on) > 1:
        raise ListingFailed("directories %s all pair with %s; one directory may be paired "
                            "with one other" % (", ".join(d.name for d in on), target.name))
    elif on:
        namer = on[0]
    elif namers:
        namer = max(namers, key=lambda d: d.id)        # the most recent one that is off
    else:
        return _spec(directory, None, None), []
    specs = {namer.id: _spec(namer, target.path, None), target.id: _spec(target, None, namer.path)}
    partner = target if namer.id == directory.id else namer
    return specs[directory.id], [(partner, specs[partner.id])]


def _is_empty(listing: Listing) -> bool:
    return not (listing.files or listing.dirs or listing.links or listing.special
                or listing.ignored or listing.unreadable)


def _incomplete(listing: Listing) -> str:
    first = listing.unreadable[0]
    more = len(listing.unreadable) - 1
    return "%s:%s could not be listed completely: %s: %s%s" % (
        listing.spec.root, listing.spec.path, first.path, first.error,
        " (and %d more)" % more if more else "")


def settled_fact(m: MemoryRow | None, size: int, mtime_ns: int,
                 artifacts: dict[str, ArtifactFact]) -> ArtifactFact | None:
    """The live artifact of a file that need not be opened, else None."""
    if (m is not None and m.status in ("registered", "known") and m.size == size
            and m.mtime_ns == mtime_ns):
        a = artifacts.get(m.artifact_id)
        if a is not None and a.live:
            return a
    return None


def sight(db: Database, directory: Directory, root_path: str, overrides=(),
          cache: HeaderCache | None = None, stats: ReadStats | None = None) -> Sighting:
    """List DIRECTORY and its pair partner, load what is known, interpret.

    Raises :class:`Unreachable` when the directory is missing or empty and
    :class:`ListingFailed` when a listing (its own or the partner's) cannot
    be made or is not complete. Writes nothing.
    """
    stats = stats if stats is not None else ReadStats()
    spec, partner_specs = pair_specs(directory, db.directories())
    try:
        listing = walk.walk(root_path, spec)
    except walk.DirectoryMissing as exc:
        raise Unreachable(str(exc)) from exc
    except (walk.WalkError, ValueError) as exc:
        raise ListingFailed(str(exc)) from exc
    if _is_empty(listing):
        raise Unreachable("%s:%s is empty" % (directory.root, directory.path))
    listings = [listing]
    for partner, pspec in partner_specs:
        try:
            other = walk.walk(root_path, pspec)
        except (walk.WalkError, ValueError) as exc:
            raise ListingFailed("the paired directory %s cannot be listed: %s"
                                % (partner.name, exc)) from exc
        if _is_empty(other):
            raise ListingFailed("the paired directory %s is empty: nothing is concluded from "
                                "what is absent" % partner.name)
        listings.append(other)
    for one in listings:
        if not one.complete:
            raise ListingFailed(_incomplete(one))

    stat_of = {f.path: (f.size, f.mtime_ns) for f in listing.files}
    for path in list(listing.links) + list(listing.special):
        try:
            st = os.lstat(content.absolute_path(root_path, path))
        except OSError as exc:
            raise ListingFailed("%s:%s: cannot stat %s: %s"
                                % (directory.root, directory.path, path, exc)) from exc
        stat_of[path] = (int(st.st_size), int(st.st_mtime_ns))

    memory: dict[str, MemoryRow] = {}
    for d in [directory] + [p for p, _s in partner_specs]:
        memory.update(db.memory(d.root_id, d.path))
    artifacts = db.artifact_facts(m.artifact_id for m in memory.values() if m.artifact_id)
    settled: dict[str, ArtifactFact] = {}
    keys = set()
    for one in listings:
        for f in one.files:
            a = settled_fact(memory.get(f.path), f.size, f.mtime_ns, artifacts)
            if a is not None:
                settled[f.path] = a
                keys.add((directory.root, f.path, f.size, f.mtime_ns))
    restricted = cache.restricted_to(keys) if cache is not None else None
    subjects = db.subjects()
    try:
        with count_header_reads(stats):
            interp = interpret(listings, {directory.root: root_path}, subjects,
                               [o for o in overrides if o.root == directory.root],
                               header_cache=restricted)
    except ValueError as exc:            # a pairing the layouts do not define, a bad override
        raise ListingFailed(str(exc)) from exc
    if not interp.complete:
        raise ListingFailed("the listing is not complete")

    wanted = {ids.group_event_id(g) for g in interp.groups}
    wanted |= {a.event_id for a in artifacts.values()}
    events = db.event_facts(wanted)
    return Sighting(directory, [p for p, _s in partner_specs], root_path, listing, interp, memory,
                    artifacts, events, stat_of, settled, stats, keys)


# --------------------------------------------------------------------------- planning
@dataclass
class GroupPlan:
    """What a run concluded about one group of its directory.

    state  ``done`` (nothing to do), ``register`` (stable: registered now, or
           in ``report`` mode would be), ``waiting``, ``held``, ``reported``
           (not registered by rule: an override said skip, a test folder).
    """
    group: Group
    state: str
    code: str | None = None
    reason: str = ""
    until_us: int | None = None
    open: tuple[GroupFile, ...] = ()
    own: EventFact | None = None
    hosts: frozenset = frozenset()
    session_id: str | None = None
    digest: str | None = None
    would_correct: bool = False
    paired: bool = False


@dataclass
class Plan:
    targets: dict[str, MemoryWrite | None]     # own listed path -> what memory should say
    writes: list[MemoryWrite]                  # rows this run appends before registering
    groups: list[GroupPlan]
    missing: list[str]                         # registered files not in the listing
    reported: int                              # listed files with nothing to remember

    def queue(self) -> list[GroupPlan]:
        return [g for g in self.groups if g.state == "register"]


def differs(m: MemoryRow | None, w: MemoryWrite) -> bool:
    """Whether W says something the latest row M does not (so a row is appended)."""
    if m is None:
        return True
    return ((m.status, m.size, m.mtime_ns, m.reason_code, m.group_key, m.artifact_id)
            != (w.status, w.size, w.mtime_ns, w.reason_code, w.group_key, w.artifact_id))


def case_conflicts(paths) -> set[str]:
    """The paths that have a folder or a name differing only in case from another's.

    Case is folded with ``names.ascii_fold`` (A-Z only), as everywhere in the
    interpretation. The database's ``lower()`` (used where a listed path is
    compared with registered ones) folds the same letters in a C-locale
    database and more of them in another: there it can also call two paths
    equal that differ in the case of a non-ASCII letter, which only holds
    more.
    """
    spellings: dict[str, set[str]] = {}
    prefixes: dict[str, list[str]] = {}
    for p in paths:
        parts = p.split("/")
        mine = ["/".join(parts[:k]) for k in range(1, len(parts) + 1)]
        prefixes[p] = mine
        for pre in mine:
            spellings.setdefault(ascii_fold(pre), set()).add(pre)
    bad = {s for v in spellings.values() if len(v) > 1 for s in v}
    return {p for p, mine in prefixes.items() if any(pre in bad for pre in mine)}


def digest_of(group: Group, session_id: str) -> str:
    """``ids.client_digest`` of GROUP in session SESSION_ID.

    The session is the group's deterministic one except for a behavior
    session paired with a recording whose event lies in another session (a
    recording registered from a copy by another client): the behavior event
    then goes where the recording's event is.
    """
    source = ids.digest_source(group)
    source["session_id"] = session_id
    return ids.sha256_text(ids.canonical_json(source))


def registered_event(group: Group, s: Sighting) -> EventFact | None:
    """The event GROUP is registered under: its own, or the one event its files hang from."""
    own = s.events.get(ids.group_event_id(group))
    if own is not None:
        return None if own.retracted else own
    found: dict[str, EventFact] = {}
    for f in group.files:
        a = s.settled.get(f.path)
        e = s.events.get(a.event_id) if a is not None else None
        if e is None or e.retracted:
            return None
        found[e.event_id] = e
    return next(iter(found.values())) if len(found) == 1 else None


def _memory_held(group: Group, s: Sighting) -> MemoryRow | None:
    for f in group.files:
        m = s.memory.get(f.path)
        if m is not None and m.status == "held":
            return m
    return None


def stability(group: Group, targets: dict, s: Sighting, vanished: dict, cleared: dict,
              now_us: int) -> tuple[bool, int]:
    """(stable, the time from which the group may be registered). See the module docstring."""
    min_age_us = s.directory.min_age_min * 60 * 1_000_000
    w = 0
    for path in group.all_paths():
        t, m = targets.get(path), s.memory.get(path)
        if t is None or m is None or differs(m, t):
            return False, now_us + min_age_us
        w = max(w, m.run_us)
    if vanished.get(group.key):
        return False, now_us + min_age_us
    for m in cleared.get(group.key, ()):
        w = max(w, m.run_us)
    return w + min_age_us <= now_us, w + min_age_us


def _held(path: str, st: tuple[int, int], code: str, reason: str, key: str | None) -> MemoryWrite:
    return MemoryWrite(path, "held", st[0], st[1], key, code, reason)


def session_hold(db: Database, s: Sighting, g: Group, session_id: str | None, paired: bool
                  ) -> tuple[str, str] | None:
    if session_id is None:
        return ("session_conflict", "the recording it pairs with is registered under an event "
                "that has no session")
    row = db.session(session_id)
    if row is not None:
        if row[0] != g.subject_id:
            return ("session_conflict", "session %s is subject %s's, not %s's"
                    % (session_id, row[0], g.subject_id))
        return None
    if paired:
        return ("session_conflict", "the session %s of its recording does not exist" % session_id)
    for other, subject, label, path in db.session_clashes(session_id, g.subject_id, g.label,
                                                          s.directory.root_id, g.session_path):
        if path != g.session_path and ascii_fold(path) == ascii_fold(g.session_path):
            return ("path_case_conflict", "session %s has the path %s, which differs from %s "
                    "only in case" % (other, path, g.session_path))
        if path == g.session_path:
            return ("session_conflict", "session %s (subject %s, label %s) already has the "
                    "path %s" % (other, subject, label, path))
        return ("session_conflict", "session %s at %s already has the label %s of subject %s"
                % (other, path, label, subject))
    return None


def time_hold(db: Database, s: Sighting, g: Group) -> tuple[str, str] | None:
    """Why G's wall-clock time cannot be converted (a daylight-saving change), if so."""
    key = (g.occurred_local, g.time_zone)
    if key not in s.local_time:
        s.local_time[key] = db.local_time_problem(*key)
    problem = s.local_time[key]
    if problem is None:
        return None
    return ("local_time_" + problem, "%s %s in %s (a daylight-saving change): the time is "
            "not converted by guessing" % (g.occurred_local,
                                           "does not exist" if problem == "nonexistent"
                                           else "occurs twice", g.time_zone))


def _new_event_hold(db: Database, s: Sighting, g: Group, session_id: str | None, paired: bool,
                    by_key: dict) -> tuple[str, str] | None:
    """Why a NEW event for G may not be written (decided without reading a file)."""
    if g.kind == "recording" and g.pairing is not None and g.pairing.status == "paired":
        partner = by_key.get(g.pairing.partner_key)
        e = registered_event(partner, s) if partner is not None else None
        if e is not None and e.session_id != ids.group_session_id(g):
            return ("late_recording", "the behavior session %s it pairs with is registered "
                    "already (event %s) in a session of its own: joining them is a correction"
                    % (partner.source_path, e.event_id))
    return time_hold(db, s, g) or session_hold(db, s, g, session_id, paired)


def plan(db: Database, s: Sighting, now_us: int) -> Plan:
    """Decide what the memory should say of every listed file and what each group is.

    Reads the database (artifacts at the paths of unregistered files, the
    session and time checks of new groups); writes nothing. ``now_us`` is
    when this run started, by the database's clock.
    """
    d = s.directory
    root_id = d.root_id
    targets: dict[str, MemoryWrite | None] = {}
    conflicts = case_conflicts(s.stat_of)
    by_key = {g.key: g for g in s.interp.groups}

    for h in s.interp.held:
        if h.path in s.stat_of:
            targets[h.path] = _held(h.path, s.stat_of[h.path], h.reason_code, h.sentence,
                                    h.group_key)
    for r in s.interp.reported:
        if not r.is_dir and s.own(r.path):
            targets[r.path] = None

    # Files of ready groups that are neither settled nor held one by one.
    pending: list[tuple[Group, list[GroupFile], dict[str, tuple[str, str]]]] = []
    plans: list[GroupPlan] = []
    for g in s.groups():
        if g.status in ("reported", "skipped"):
            for path in g.all_paths():
                targets[path] = None
            plans.append(GroupPlan(g, "reported", g.hold.reason_code if g.hold else None,
                                   g.hold.sentence if g.hold else ""))
            continue
        for h in g.held_files:
            targets[h.path] = _held(h.path, s.stat_of[h.path], h.reason_code, h.sentence, g.key)
        if g.status != "ready":
            for f in g.files:
                targets[f.path] = _held(f.path, (f.size, f.mtime_ns), g.hold.reason_code,
                                        g.hold.sentence, g.key)
            plans.append(GroupPlan(g, "held", g.hold.reason_code, g.hold.sentence))
            continue
        todo: list[GroupFile] = []
        file_holds: dict[str, tuple[str, str]] = {}
        for f in g.files:
            m = s.memory.get(f.path)
            st = (f.size, f.mtime_ns)
            a = s.settled.get(f.path)
            if a is not None:
                targets[f.path] = MemoryWrite(f.path, m.status, m.size, m.mtime_ns, m.group_key,
                                              artifact_id=a.current_id)
            elif (m is not None and m.status in ("registered", "known")
                    and (m.size, m.mtime_ns) == st):
                file_holds[f.path] = ("registered_but_withdrawn", "artifact %s of this file was "
                                      "retracted, or the file was recorded as moved, replaced "
                                      "or deleted" % m.artifact_id)
            elif (m is not None and m.status == "held" and (m.size, m.mtime_ns) == st
                    and READ_MARK in (m.reason or "") and m.group_key == g.key):
                file_holds[f.path] = (m.reason_code, m.reason)       # read once; the hold stands
            elif f.path in conflicts:
                file_holds[f.path] = ("path_case_conflict", "another listed path differs from "
                                      "this one only in case")
            else:
                todo.append(f)
        pending.append((g, todo, file_holds))

    at = db.artifacts_at(root_id, [f.path for _g, todo, _h in pending for f in todo])
    vanished: dict[str, list[MemoryRow]] = {}
    cleared: dict[str, list[MemoryRow]] = {}
    writes: list[MemoryWrite] = []
    for path, m in sorted(s.memory.items()):
        if not s.own(path) or path in s.stat_of:
            continue
        if m.status in ("pending", "held"):
            vanished.setdefault(m.group_key, []).append(m)
            writes.append(MemoryWrite(path, "cleared", group_key=m.group_key,
                                      reason="no longer listed"))
        elif m.status == "cleared":
            cleared.setdefault(m.group_key, []).append(m)

    for g, todo, file_holds in pending:
        still: list[GroupFile] = []
        for f in todo:
            rows = at.get(f.path, [])
            variants = sorted({r.path for r in rows if r.path != f.path})
            if variants:
                file_holds[f.path] = ("path_case_conflict", "registered as %s, which differs "
                                      "only in case" % variants[0])
            elif rows and not any(r.live for r in rows):
                file_holds[f.path] = ("registered_but_withdrawn", "the file registered at this "
                                      "path (artifact %s) was retracted or recorded as moved, "
                                      "replaced or deleted" % rows[0].artifact_id)
            else:
                still.append(f)
        own = s.events.get(ids.group_event_id(g))
        hosts = frozenset(s.events[s.settled[f.path].event_id].event_id for f in g.files
                          if f.path in s.settled and s.settled[f.path].event_id in s.events)
        session_id = ids.group_session_id(g)
        paired = g.kind == "behavior" and g.pairing is not None and g.pairing.status == "paired"
        hold: tuple[str, str] | None = None
        wait: str | None = None
        if paired:
            partner = by_key.get(g.pairing.partner_key)
            rec = registered_event(partner, s) if partner is not None else None
            if rec is not None:
                session_id = rec.session_id
            elif own is None:
                blocked = _memory_held(partner, s) if partner is not None else None
                if blocked is not None:
                    hold = ("paired_recording_held", "its recording %s is held (%s)"
                            % (partner.source_path, blocked.reason_code))
                else:
                    wait = "its recording %s is not registered yet" % (
                        partner.source_path if partner is not None else g.pairing.partner_key)
        digest = digest_of(g, session_id) if session_id is not None else None
        would_correct = False
        if own is not None:
            if own.retracted:
                hold = ("registered_but_withdrawn", "its event %s was retracted" % own.event_id)
            elif own.digest != digest:
                would_correct = True
                hold = ("would_correct", "event %s is in the database with another digest: "
                        "what is read now differs from what was registered" % own.event_id)
        elif hold is None and wait is None:
            if len(hosts) > 1:
                hold = ("copy_ambiguous", "its registered files belong to events %s"
                        % ", ".join(sorted(hosts)))
            elif len(hosts) == 1:
                host = next(e for e in s.events.values() if e.event_id in hosts)
                hold = host_hold(g, host)
            elif still:
                hold = _new_event_hold(db, s, g, session_id, paired, by_key)

        gp = GroupPlan(g, "done", own=own, hosts=hosts, session_id=session_id, digest=digest,
                       would_correct=would_correct, paired=paired)
        for path, (code, reason) in file_holds.items():
            targets[path] = _held(path, s.stat_of[path], code, reason, g.key)
        first_file_hold = sorted(file_holds.items())[0][1] if file_holds else None
        if hold is not None:
            # Held as a group: every file not yet registered carries the reason.
            for f in still:
                targets[f.path] = _held(f.path, (f.size, f.mtime_ns), hold[0], hold[1], g.key)
            if still or would_correct or file_holds:
                gp.state, gp.code, gp.reason = "held", hold[0], hold[1]
        else:
            for f in still:
                targets[f.path] = MemoryWrite(f.path, "pending", f.size, f.mtime_ns, g.key)
            if not still:
                if file_holds:
                    gp.state, gp.code, gp.reason = "held", first_file_hold[0], first_file_hold[1]
            elif wait is not None:
                gp.state, gp.reason = "waiting", wait
            elif file_holds and own is None and not hosts:
                # Nothing of a group that has no event yet is written beside a held file.
                gp.state = "waiting"
                gp.reason = "a file of the group is held (%s)" % first_file_hold[0]
            else:
                stable, gp.until_us = stability(g, targets, s, vanished, cleared, now_us)
                if stable:
                    gp.state, gp.open = "register", tuple(still)
                else:
                    gp.state = "waiting"
                    gp.reason = "not yet seen unchanged for %d min" % d.min_age_min
        plans.append(gp)

    # A file that is registered and unchanged stays so in the memory, whatever is now
    # said of its group: a hold concerns what is not registered yet.
    for path, a in s.settled.items():
        if path in s.stat_of:
            m = s.memory[path]
            targets[path] = MemoryWrite(path, m.status, m.size, m.mtime_ns, m.group_key,
                                        artifact_id=a.current_id)

    reported = 0
    for path in sorted(s.stat_of):
        if path not in targets:
            raise RuntimeError("no decision for the listed file %s" % path)
        t, m = targets[path], s.memory.get(path)
        if t is None:
            reported += 1
            if m is not None and m.status in ("pending", "held"):
                writes.append(MemoryWrite(path, "cleared", group_key=m.group_key,
                                          reason="no longer pending or held: not registered "
                                                 "by rule"))
        elif differs(m, t):
            writes.append(t)

    listed = set(s.stat_of) | {i.path for i in s.listing.ignored}
    ignored_dirs = tuple(i.path + "/" for i in s.listing.ignored if i.is_dir)
    missing = [p for p in db.present_under(root_id, d.path)
               if p not in listed and not p.startswith(ignored_dirs)]
    return Plan(targets, writes, sorted(plans, key=lambda p: p.group.key), missing, reported)


def host_hold(g: Group, host: EventFact) -> tuple[str, str] | None:
    if host.retracted:
        return ("registered_but_withdrawn", "event %s, which its files belong to, was retracted"
                % host.event_id)
    if host.event_type != g.kind or host.subject_id != g.subject_id:
        return ("copy_event_mismatch", "its files belong to %s event %s of subject %s, not to "
                "a %s event of subject %s" % (host.event_type, host.event_id, host.subject_id,
                                              g.kind, g.subject_id))
    return None


# --------------------------------------------------------------------------- reading
@dataclass(frozen=True)
class Reading:
    checksum: str
    size: int
    mtime_ns: int


def _lstat(path: str) -> tuple[int, int] | None:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat_module.S_ISREG(st.st_mode):
        return None
    return int(st.st_size), int(st.st_mtime_ns)


def read_file(root_path: str, f: GroupFile, verify: bool, stats: ReadStats
              ) -> tuple[Reading, tuple[str, str] | None]:
    """Read F to its end: its SHA-256, and a structural problem of a ``.mat`` file if any.

    ``lstat`` before and after, and ``fstat`` of the open file, must give a
    regular file with the size and ``mtime_ns`` of the listing, else
    :class:`FileChanged`. An ``OSError`` is the caller's.
    """
    path = content.absolute_path(root_path, f.path)
    want = (f.size, f.mtime_ns)
    seen = _lstat(path)
    if seen != want:
        raise FileChanged(f.path, seen)
    problem = None
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        st = os.fstat(fh.fileno())
        if (int(st.st_size), int(st.st_mtime_ns)) != want or not stat_module.S_ISREG(st.st_mode):
            raise FileChanged(f.path, _lstat(path))
        while True:
            block = fh.read(CHUNK)
            if not block:
                break
            h.update(block)
            stats.read_bytes += len(block)
        if verify:
            fh.seek(0)
            stats.read_bytes += f.size
            try:
                verify_mat(fh, f.size)
            except content.ContentProblem as exc:
                if exc.code in content.TRANSIENT:
                    raise OSError(exc.sentence) from exc
                problem = (exc.code, exc.sentence)
    stats.files_read += 1
    seen = _lstat(path)
    if seen != want:
        raise FileChanged(f.path, seen)
    return Reading(h.hexdigest(), f.size, f.mtime_ns), problem


def read_group(s: Sighting, gp: GroupPlan) -> tuple[dict[str, Reading], dict[str, tuple[str, str]]]:
    """Read every unregistered file of the group; (readings, structural problems) by path."""
    readings: dict[str, Reading] = {}
    problems: dict[str, tuple[str, str]] = {}
    for f in gp.open:
        verify = gp.group.layout == "epsych" and f.role == "raw" and f.format == "mat"
        readings[f.path], problem = read_file(s.root_path, f, verify, s.stats)
        if problem is not None:
            problems[f.path] = problem
    return readings, problems


# --------------------------------------------------------------------------- registering
@dataclass
class GroupOutcome:
    """What :func:`register_group` wrote for one group."""
    key: str
    state: str                    # registered | held
    rows: list[MemoryWrite]
    event_id: str | None = None
    session_id: str | None = None
    created_event: bool = False
    created_session: bool = False
    copy_of: str | None = None    # the event of another client the files were added to
    code: str | None = None
    reason: str = ""


def _mark(reason: str, checksum: str) -> str:
    return "%s %s%s]" % (reason, READ_MARK, checksum)


def register_group(db: Database, run_id: int, s: Sighting, gp: GroupPlan,
                   readings: dict[str, Reading], problems: dict[str, tuple[str, str]],
                   version: str = VERSION) -> GroupOutcome:
    """Write one group in ONE transaction; only ever adds.

    Reproduces ``@CarasLabDB/recordEvent.m``: an event with the group's
    deterministic id and the same digest is this group, registered before
    (its new files are added to it, the event untouched); a file registered
    already with the same bytes at the same path is reused (``known``). It
    also reproduces ``labclient.Sync.copyOf``: a group with no event of its
    own whose every ``raw`` file is, by checksum, a ``raw`` file of exactly
    one active event is a copy of that event's files -- its files are added
    to that event and no event or session is made. Whatever would need a
    correction, a disposition or a guess is held instead: the transaction
    then writes ``held`` rows only.
    """
    g = gp.group
    root_id = s.directory.root_id
    det = ids.group_event_id(g)
    with db.transaction():
        own = db.event_facts([det]).get(det)
        at = db.artifacts_at(root_id, [f.path for f in gp.open])
        file_holds: dict[str, tuple[str, str]] = {}
        known: dict[str, ArtifactFact] = {}
        new: list[GroupFile] = []
        for f in gp.open:
            c = readings[f.path].checksum
            rows = at.get(f.path, [])
            same = [r for r in rows if r.live and r.checksum_algo == "sha256" and r.checksum == c]
            if any(r.path != f.path for r in rows):
                file_holds[f.path] = ("path_case_conflict", "registered under a path that "
                                      "differs only in case")
            elif same:
                known[f.path] = same[0]
            elif rows and any(r.live for r in rows):
                file_holds[f.path] = ("content_changed", _mark(
                    "artifact %s registers other bytes at this path" %
                    next(r.artifact_id for r in rows if r.live), c))
            elif rows:
                file_holds[f.path] = ("registered_but_withdrawn", "the file registered at this "
                                      "path was retracted or recorded as moved, replaced or "
                                      "deleted")
            else:
                new.append(f)

        hold: tuple[str, str] | None = None
        by_bytes = False
        host: EventFact | None = None
        copy = False
        also: list[str] = []
        if problems:
            path, (code, sentence) = sorted(problems.items())[0]
            hold, by_bytes = (code, "%s: %s" % (path.rsplit("/", 1)[1], sentence)), True
        elif own is not None:
            if own.retracted:
                hold = ("registered_but_withdrawn", "its event %s was retracted" % own.event_id)
            elif own.digest != gp.digest:
                hold = ("would_correct", "event %s is in the database with another digest"
                        % own.event_id)
            else:
                host = own
        else:
            facts = db.event_facts([a.event_id for a in known.values()])
            host_ids = set(gp.hosts) | {facts[a.event_id].event_id for a in known.values()}
            if len(host_ids) > 1:
                hold = ("copy_ambiguous", "its files at these paths belong to events %s"
                        % ", ".join(sorted(host_ids)))
            elif len(host_ids) == 1:
                host, copy = db.event_facts(host_ids)[next(iter(host_ids))], True
            elif file_holds:
                pass                       # nothing of a new group is written beside a held file
            else:
                raw = [readings[f.path].checksum for f in g.files
                       if f.role == "raw" and f.path in readings]
                copies = db.raw_copies(raw)
                sets = [{e for e, _a, _w in copies.get(c, [])} for c in raw]
                common = set.intersection(*sets) if sets else set()
                also = sorted(set().union(*sets)) if sets else []
                if len(common) > 1:
                    hold, by_bytes = ("copy_ambiguous", "its raw files are, by their SHA-256, "
                                      "the files of each of events %s"
                                      % ", ".join(sorted(common))), True
                elif len(common) == 1:
                    one = next(iter(common))
                    if db.written_by(one, TOOL_NAME):
                        # The same bytes under two names on the NAS: a question for a person.
                        where = sorted({w for c in raw for e, _a, w in copies[c] if e == one})
                        hold, by_bytes = ("duplicate_content", "its raw files hold the bytes "
                                          "this tool registered already as %s (event %s)"
                                          % (", ".join(where[:3]), one)), True
                    else:
                        host, copy, by_bytes = db.event_facts(common)[one], True, True
            if host is not None:
                hold = host_hold(g, host)

        rows_out: list[MemoryWrite] = []
        for path, (code, reason) in sorted(file_holds.items()):
            f = next(x for x in gp.open if x.path == path)
            rows_out.append(MemoryWrite(path, "held", f.size, f.mtime_ns, g.key, code, reason))
        if hold is None and host is None and not file_holds:
            hold = session_hold(db, s, g, gp.session_id, gp.paired)
        if hold is not None or (host is None and file_holds):
            for f in gp.open:
                if f.path not in file_holds and hold is not None:
                    reason = _mark(hold[1], readings[f.path].checksum) if by_bytes else hold[1]
                    rows_out.append(MemoryWrite(f.path, "held", f.size, f.mtime_ns, g.key,
                                                hold[0], reason))
            db.write_memory(run_id, root_id, rows_out)
            code, reason = hold if hold is not None else sorted(file_holds.items())[0][1]
            return GroupOutcome(g.key, "held", rows_out, code=code, reason=reason)

        out = GroupOutcome(g.key, "registered", rows_out)
        w = GroupWrite(g.key, det, g.subject_id, gp.session_id)
        if host is None:
            if db.session(gp.session_id) is None:
                w.session = session_values(g, gp.session_id, root_id)
                out.created_session = True
            w.event = event_values(g, gp.session_id, gp.digest, version, also)
            out.created_event = True
        else:
            w.event_id, w.subject_id, w.session_id = host.event_id, host.subject_id, host.session_id
            if copy:
                out.copy_of = host.event_id
        out.event_id, out.session_id = w.event_id, w.session_id
        theirs = db.event_artifacts(w.event_id) if copy else {}
        for f in new:
            c = readings[f.path].checksum
            attributes = (copy_attributes(g, f.attributes, w.event_id, theirs.get(c), version)
                          if copy else dict(f.attributes))
            w.files.append(FileWrite(f.path, f.size, f.mtime_ns, c, "new", f.role, f.format,
                                     attributes))
        for path, a in sorted(known.items()):
            f = next(x for x in gp.open if x.path == path)
            w.files.append(FileWrite(path, f.size, f.mtime_ns, readings[path].checksum, "known",
                                     artifact_id=a.current_id))
        rows_out += write_group(db, root_id, w)
        db.write_memory(run_id, root_id, rows_out)
        return out


@dataclass
class FileWrite:
    """One file of a group as it is written: a new artifact, or a row that is there."""
    path: str
    size: int
    mtime_ns: int
    sha256: str
    state: str                        # new | known | replace
    role: str | None = None
    format: str | None = None
    attributes: dict | None = None
    artifact_id: str | None = None    # new, replace: the id to give (None: the database's);
    #                                   known: the row that registers these bytes
    replaces: str | None = None       # replace: the row whose file these bytes took the place of


@dataclass
class GroupWrite:
    """Everything decided about what to write for one group (see :func:`write_group`)."""
    key: str
    event_id: str                     # the event the files hang from
    subject_id: str | None
    session_id: str | None
    session: dict | None = None       # Database.insert_session arguments, when it is new
    event: dict | None = None         # Database.insert_event arguments, when it is new
    files: list = field(default_factory=list)
    read_us: int | None = None        # when the bytes were read; None: now


def session_values(g: Group, session_id: str, root_id: int, subject_id: str | None = None
                   ) -> dict:
    """The arguments of ``Database.insert_session`` for G's session."""
    return {"session_id": session_id, "subject_id": subject_id or g.subject_id, "label": g.label,
            "root_id": root_id, "path": g.session_path, "start_local": g.start_local,
            "zone": g.time_zone,
            "duration": g.detail.get("duration_s") if g.kind == "recording" else None,
            "rig": g.rig}


def event_attributes(g: Group, digest: str, version: str, also=()) -> dict:
    """The attributes of G's event: ``ids.event_attributes`` with the digest of its session."""
    attributes = ids.event_attributes(g, version)
    attributes["client_digest"] = digest
    if also:
        attributes["raw_files_also_in_events"] = sorted(also)
    return attributes


def event_values(g: Group, session_id: str, digest: str, version: str, also=()) -> dict:
    """The arguments of ``Database.insert_event`` for G's own, new event."""
    return {"event_id": ids.group_event_id(g), "event_type": g.kind, "subject_id": g.subject_id,
            "session_id": session_id, "occurred_local": g.occurred_local, "zone": g.time_zone,
            "attributes": ids.canonical_json(event_attributes(g, digest, version, also)),
            "detail": dict(g.detail)}


def copy_attributes(g: Group, attributes: dict, host_event: str, copied_from: str | None,
                    version: str) -> dict:
    """A file's attributes when it is added to an event that is not the group's own.

    As ``labclient.Sync.sendCopy`` marks a copy (``copied_from`` when the
    event has a file with the same bytes, ``copy_of_event``,
    ``copy_recorded_as``), plus what the event of the group would have said
    of where the file came from.
    """
    out = dict(attributes)
    if copied_from is not None:
        out["copied_from"] = copied_from
    out["copy_of_event"] = host_event
    out["copy_recorded_as"] = ids.group_event_id(g)
    out["import"] = ids.import_block(g)
    out["captured_by_tool"] = TOOL_NAME
    out["code_version"] = version
    return out


def write_group(db: Database, root_id: int, w: GroupWrite) -> list[MemoryWrite]:
    """Insert what W says, inside the caller's transaction; returns the files' memory rows.

    The session and the event when they are new; one artifact with its
    ``ok`` verification per ``new`` or ``replace`` file (a ``replace`` also
    records the old file as ``replaced`` by it); an ``ok`` verification for
    each ``known`` file. The caller appends the returned rows to the memory.
    """
    if w.session is not None:
        db.insert_session(**w.session)
    if w.event is not None:
        db.insert_event(**w.event)
    rows: list[MemoryWrite] = []
    for f in w.files:
        if f.state == "known":
            db.insert_verification(f.artifact_id, f.sha256, w.read_us)
            rows.append(MemoryWrite(f.path, "known", f.size, f.mtime_ns, w.key,
                                    artifact_id=f.artifact_id))
            continue
        artifact_id = db.insert_artifact(w.event_id, root_id, f.path, f.sha256, f.size, f.role,
                                         f.format, w.subject_id, w.session_id,
                                         ids.canonical_json(f.attributes), f.artifact_id, w.read_us)
        if f.state == "replace":
            db.insert_disposition(
                f.replaces, artifact_id, w.read_us,
                "other bytes were found at this path; registered as artifact %s" % artifact_id,
                ids.canonical_json({"recorded_by_tool": TOOL_NAME,
                                    "source_mtime": ids.mtime_text(f.mtime_ns)}))
        rows.append(MemoryWrite(f.path, "registered", f.size, f.mtime_ns, w.key,
                                artifact_id=artifact_id))
    return rows


# --------------------------------------------------------------------------- one run
@dataclass
class RunOptions:
    overrides: tuple = ()
    cache_path: str | None = None
    dry_run: bool = False
    ignore_window: bool = False          # --now: a run made by hand
    host: str = ""
    version: str = VERSION


@dataclass
class DirectoryResult:
    """What one search of one directory did; the source of the result row and the report."""
    directory: Directory
    mode: str
    run_id: int | None = None
    started: str = ""
    outcome: str = "ok"
    message: str | None = None
    counters: dict = field(default_factory=dict)
    details: dict = field(default_factory=dict)
    lines: list[dict] = field(default_factory=list)      # the report's rows
    happened: bool = False
    result_written: bool = False


def _line(what: str, action: str, path: str = "", key: str | None = None, code: str | None = None,
          detail: str = "", size=None, mtime_ns=None, artifact_id=None, event_id=None,
          until: str = "") -> dict:
    return {"what": what, "action": action, "path": path, "group_key": key or "",
            "reason_code": code or "", "detail": detail or "",
            "size_bytes": "" if size is None else size,
            "mtime_ns": "" if mtime_ns is None else mtime_ns,
            "artifact_id": artifact_id or "", "event_id": event_id or "", "until": until}


def _row_line(w: MemoryWrite, event_id: str | None = None) -> dict:
    return _line("file", w.status, w.path, w.group_key, w.reason_code, w.reason or "", w.size,
                 w.mtime_ns, w.artifact_id, event_id)


def _summary_list(items: list[str]) -> dict:
    items = sorted(items)
    return {"count": len(items), "digest": ids.sha256_text("\n".join(items)), "first": items[:50]}


def _count(rows, status: str) -> int:
    return sum(1 for r in rows if r.status == status)


def run_directory(db: Database, directory: Directory, root_path: str, due_at: str | None,
                  options: RunOptions) -> DirectoryResult:
    """Search DIRECTORY once; the caller holds its lock.

    Appends ``lab.scan_run``, reads the directory's row again (root, path,
    layout and zone are then frozen), sights, plans, writes the sighting's
    memory rows, registers the stable groups in order of their keys (mode
    ``register``; the window is asked before each) and appends
    ``lab.scan_run_result`` -- also when the run fails. With
    ``options.dry_run`` nothing is written to the database or the cache and
    nothing is read to its end.
    """
    res = DirectoryResult(directory, directory.mode)
    stats = ReadStats()
    counters = dict.fromkeys(("files_listed", "files_unchanged", "files_pending",
                              "files_registered", "files_known", "files_held", "files_ignored",
                              "files_cleared", "groups_registered", "groups_waiting",
                              "groups_held", "bytes_read"), 0)
    res.counters = counters
    errors: list[str] = []
    try:
        if options.dry_run:
            now_us = db.now_us()
            res.started = us_text(now_us).replace("-", "").replace(":", "")
        else:
            res.run_id, now_us, res.started = db.insert_run(
                directory.id, "run", directory.mode, due_at, options.version, options.host)
            again = db.directory(directory.id)
            if again.mode != "register":
                res.mode = "report"
            directory = dataclasses.replace(again, mode=res.mode)
            res.directory = directory
        cache = HeaderCache.load(options.cache_path) if options.cache_path else None
        s = sight(db, directory, root_path, options.overrides, cache, stats)
        p = plan(db, s, now_us)
        _run_planned(db, s, p, res, options, counters, errors)
        if options.cache_path and not options.dry_run:
            _save_cache(options.cache_path, s)
    except Unreachable as exc:
        res.outcome, res.message = "unreachable", str(exc)
    except ListingFailed as exc:
        res.outcome, res.message = "failed", str(exc)
    except _Stop as exc:
        res.outcome, res.message = "failed", str(exc)
    except Exception as exc:            # recorded as the run's failure, then the next directory
        if db.lost(exc) and not db.reconnect():
            res.outcome = "failed"
            res.message = "the database connection was lost: %s" % exc
            res.happened = True
            return res
        res.outcome = "failed"
        res.message = "%s: %s" % (type(exc).__name__, str(exc).strip().splitlines()[0]
                                  if str(exc).strip() else traceback.format_exc(limit=1))
    counters["bytes_read"] = stats.bytes_read
    res.details.update({"files_opened": stats.files_opened, "files_read": stats.files_read,
                        "mode": res.mode})
    if errors:
        res.details["errors"] = errors[:50]
        if res.outcome in ("ok", "partial"):
            res.outcome = "failed"
            res.message = "%d group(s) could not be registered: %s" % (len(errors), errors[0])
    if res.outcome in ("failed", "unreachable"):
        res.lines.append(_line("directory", res.outcome, directory.path, detail=res.message or ""))
    _finish(db, res, options)
    return res


class _Stop(Exception):
    """The run cannot go on (the connection and the lock are gone)."""


def _run_planned(db: Database, s: Sighting, p: Plan, res: DirectoryResult, options: RunOptions,
                 counters: dict, errors: list[str]) -> None:
    d = s.directory
    final: dict[str, str] = {}
    for path in s.stat_of:
        t, m = p.targets[path], s.memory.get(path)
        final[path] = "reported" if t is None else t.status
        if t is not None and not differs(m, t):
            final[path] = m.status
    written = list(p.writes)
    if not options.dry_run:
        with db.transaction():
            db.write_memory(res.run_id, d.root_id, p.writes)
    res.lines += [_row_line(w) for w in p.writes]

    registered_groups = 0
    stopped = False
    for gp in p.queue():
        g = gp.group
        if res.mode != "register" or options.dry_run:
            res.lines.append(_line("group", "would_register", g.source_path, g.key,
                                   detail="%d file(s), seen unchanged since %s"
                                   % (len(gp.open), us_text(gp.until_us
                                                            - d.min_age_min * 60_000_000))))
            continue
        try:
            if not options.ignore_window and not db.window_open(d.id):
                stopped = True
                break
            try:
                readings, problems = read_group(s, gp)
            except FileChanged as exc:
                # Not what the listing said: not registered now, and the wait starts again.
                rows = []
                if exc.seen is not None:
                    f = next(x for x in gp.open if x.path == exc.path)
                    rows = [MemoryWrite(f.path, "pending", exc.seen[0], exc.seen[1], g.key)]
                    db.write_memory(res.run_id, d.root_id, rows)
                written += rows
                res.lines += [_row_line(w) for w in rows]
                res.lines.append(_line("group", "changed", g.source_path, g.key,
                                       detail="%s changed while it was read" % exc.path))
                gp.state, gp.reason = "waiting", "%s changed while it was read" % exc.path
                continue
            out = register_group(db, res.run_id, s, gp, readings, problems, options.version)
        except OSError as exc:
            errors.append("%s: %s" % (g.key, exc))
            res.lines.append(_line("group", "error", g.source_path, g.key, detail=str(exc)))
            gp.state, gp.reason = "waiting", "could not be read: %s" % exc
            continue
        except db.error_types() as exc:
            if db.lost(exc):
                if not db.reconnect():
                    raise _Stop("the database connection was lost while %s was registered, and "
                                "the directory's lock could not be taken again" % g.key) from exc
            errors.append("%s: %s" % (g.key, str(exc).strip().splitlines()[0]))
            res.lines.append(_line("group", "error", g.source_path, g.key,
                                   detail=str(exc).strip().splitlines()[0]))
            gp.state, gp.reason = "waiting", "a database error; tried again at the next run"
            continue
        written += out.rows
        for w in out.rows:
            final[w.path] = w.status
            res.lines.append(_row_line(w, out.event_id))
        if out.state == "registered":
            registered_groups += 1
            gp.state = "registered"
            what = ("added to event %s of another client (a copy)" % out.copy_of if out.copy_of
                    else "a new event" if out.created_event else "added to its event")
            res.lines.append(_line("group", "registered", g.source_path, g.key, detail=what,
                                   event_id=out.event_id))
            for w in out.rows:
                if w.status in ("registered", "known"):
                    f = next(x for x in g.files if x.path == w.path)
                    s.settled[w.path] = ArtifactFact(w.artifact_id, w.path, "", "sha256",
                                                     w.artifact_id, True, out.event_id)
                    s.cache_keys.add((d.root, f.path, f.size, f.mtime_ns))
        else:
            gp.state, gp.code, gp.reason = "held", out.code, out.reason

    for gp in p.groups:
        g = gp.group
        if gp.state == "waiting":
            counters["groups_waiting"] += 1
            res.lines.append(_line("group", "waiting", g.source_path, g.key, detail=gp.reason,
                                   until=us_text(gp.until_us) if gp.until_us else ""))
        elif gp.state == "register":
            counters["groups_waiting"] += 1
        elif gp.state == "held":
            counters["groups_held"] += 1
            res.lines.append(_line("group", "would_correct" if gp.would_correct else "held",
                                   g.source_path, g.key, gp.code, gp.reason))
    for path in p.missing:
        res.lines.append(_line("file", "missing", path, detail="registered and present in the "
                               "database, not in the listing; nothing was recorded"))

    counters["files_listed"] = len(s.stat_of)
    counters["files_ignored"] = sum(i.file_count or 0 for i in s.listing.ignored)
    counters["files_pending"] = _count(written, "pending")
    counters["files_held"] = _count(written, "held")
    counters["files_cleared"] = _count(written, "cleared")
    counters["files_registered"] = _count(written, "registered")
    counters["files_known"] = _count(written, "known")
    touched = {w.path for w in written}
    counters["files_unchanged"] = sum(1 for path in s.stat_of
                                      if path not in touched and final[path] != "reported")
    counters["groups_registered"] = registered_groups
    totals = dict.fromkeys(("registered", "known", "pending", "held", "reported"), 0)
    for status in final.values():
        totals[status] += 1
    totals["ignored"] = counters["files_ignored"]
    res.details.update({
        "totals": totals,
        "missing": _summary_list(p.missing),
        "would_correct": _summary_list([gp.group.key for gp in p.groups if gp.would_correct]),
        "would_register": _summary_list([gp.group.key for gp in p.groups
                                         if gp.state == "register" and not stopped]),
        "partners": [x.id for x in s.partners],
        "unused_overrides": ["line %d: %s:%s" % (o.line, o.root, o.path)
                             for o in s.interp.unused_overrides
                             if o.path.startswith(tuple(x.path + "/" for x in
                                                        [d] + s.partners))],
    })
    if stopped:
        res.outcome = "partial"
        res.message = "the window closed; the rest is done at its next opening"
    res.happened = bool(written or registered_groups or errors)


def _save_cache(path: str, s: Sighting) -> None:
    """Add this run's fresh headers of registered files and save the cache atomically."""
    cache = HeaderCache.load(path)
    prefix = s.directory.path + "/"
    current = {k: v for k, v in cache.items()
               if not (k[0] == s.directory.root and k[1].startswith(prefix)) or k in s.cache_keys}
    fresh = {k: v for k, v in s.interp.headers.items() if k in s.cache_keys}
    if len(current) == len(cache) and all(k in cache for k in fresh):
        return
    merged = HeaderCache(current)
    for k, v in fresh.items():
        merged.put(k, v)
    merged.save(path)


def _finish(db: Database, res: DirectoryResult, options: RunOptions) -> None:
    """Decide whether the report is worth writing and append the result row."""
    if options.dry_run:
        res.happened = True
        return
    try:
        previous = db.previous_result(res.directory.id, res.run_id)
    except Exception:
        previous = None
    if res.outcome in ("failed", "unreachable"):
        res.happened = previous is None or (previous[0], previous[1]) != (res.outcome, res.message)
    elif not res.happened:
        before = previous[2] if previous is not None else {}
        for name in ("missing", "would_correct", "would_register"):
            now = res.details.get(name, {})
            then = before.get(name, {"count": 0, "digest": ids.sha256_text("")})
            if (now.get("count"), now.get("digest")) != (then.get("count"), then.get("digest")):
                res.happened = True
    if res.run_id is None:
        return
    try:
        db.insert_result(res.run_id, res.outcome, res.counters, res.message, res.details)
        res.result_written = True
    except Exception as exc:
        if db.lost(exc) and db.reconnect():
            try:
                db.insert_result(res.run_id, res.outcome, res.counters, res.message, res.details)
                res.result_written = True
                return
            except Exception as again:
                exc = again
        res.message = "%s; the result row could not be written: %s" % (res.message or res.outcome,
                                                                       exc)
        res.outcome = "failed"
        res.happened = True
