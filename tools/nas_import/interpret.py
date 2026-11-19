"""The whole database-free interpretation of a scan.

``interpret(listings, root_paths, known_subjects, overrides)`` takes the
walker's listings and returns an :class:`Interpretation`. It is a pure
function of its arguments and of the header bytes it reads (the layouts
read the start of ``.mat``, ``.rhd`` and ``.ts`` files): two listings of an
unchanged tree give equal results, the same keys and signatures. It never
opens a database, writes nothing, and keeps no state between calls.

Stages:

1. Per listing, links, special entries and paths that cannot be stored are
   held (``symbolic_link``, ``not_a_regular_file``, ``path_not_storable``);
   the rest goes to the directory's layout (:mod:`.layouts`).
2. Loose held items in a test folder become reported items
   (:func:`.subjects.reclassify_loose`).
3. Subjects and overrides (:func:`.subjects.resolve_subjects`).
4. Pairing (:func:`.pairing.apply_pairing`).
5. Two ready groups of one subject that would give two sessions the same
   label are held (``session_label_conflict``; ``lab.session`` has
   ``UNIQUE (subject_id, label)``).
6. Accounting: every listed file (and link and special entry) must be in
   exactly one place -- a group's files or held files, a loose held item or
   a reported item; otherwise RuntimeError (a bug, never data).

It does not decide whether a group is old or stable enough: the database
side registers a group only when two complete listings at least the
directory's ``min_age_min`` apart give the same :func:`.ids.signature`.
Nor does it refuse an incomplete listing: ``Interpretation.complete`` says
so and the caller must then register nothing.
"""

from __future__ import annotations

import dataclasses
from collections import defaultdict
from collections.abc import Collection, Mapping, Sequence

from .cache import HeaderReader
from .layouts import get_layout
from .model import Group, HeldItem, Hold, Interpretation, Listing, Override, ReportedItem
from .pairing import apply_pairing
from .subjects import reclassify_loose, resolve_subjects


def _storable(path: str) -> str | None:
    """Why PATH cannot be stored as lab.*.relative_path, or None."""
    try:
        path.encode("utf-8")
    except UnicodeEncodeError:
        return "the path is not valid UTF-8 text"
    if "\\" in path:
        return "the path holds a backslash"
    if path != path.strip(" "):
        return "the path has a space at an end"
    return None


def _check_directories(listings: Sequence[Listing]) -> None:
    seen: list[tuple[str, str]] = []
    for listing in listings:
        s = listing.spec
        for root, path in seen:
            a, b = path.casefold() + "/", s.path.casefold() + "/"
            if root == s.root and (a.startswith(b) or b.startswith(a)):
                raise ValueError("directories %s:%s and %s:%s are equal or nested"
                                 % (root, path, s.root, s.path))
        seen.append((s.root, s.path))


def _label_conflicts(groups: Sequence[Group]) -> tuple[Group, ...]:
    paths: dict[tuple[str, str], set[str]] = defaultdict(set)
    for g in groups:
        if g.status == "ready":
            paths[(g.subject_id, g.label)].add(g.session_path)
    out = []
    for g in groups:
        p = paths.get((g.subject_id, g.label))
        if g.status == "ready" and p is not None and len(p) > 1:
            g = dataclasses.replace(g, status="held", hold=Hold(
                "session_label_conflict", "sessions %s of subject %s would all be labelled %s"
                % (", ".join(sorted(p)), g.subject_id, g.label)))
        out.append(g)
    return tuple(out)


def _account(listings, groups, held, reported) -> None:
    listed: list[str] = []
    for listing in listings:
        listed += [f.path for f in listing.files] + list(listing.links) + list(listing.special)
    placed: list[str] = []
    for g in groups:
        placed += list(g.all_paths())
    placed += [h.path for h in held]
    placed += [r.path for r in reported if not r.is_dir]
    if sorted(listed) != sorted(placed):
        missing = sorted(set(listed) - set(placed))
        extra = sorted(set(placed) - set(listed))
        dup = sorted({p for p in placed if placed.count(p) > 1})
        raise RuntimeError("file accounting failed: missing %s, unknown %s, twice %s"
                           % (missing[:5], extra[:5], dup[:5]))


def interpret(listings: Sequence[Listing], root_paths: Mapping[str, str],
              known_subjects: Collection[str], overrides: Sequence[Override] = (),
              header_cache: Mapping | None = None) -> Interpretation:
    """Interpret LISTINGS (see the module docstring).

    root_paths      storage root name -> its mount path on this computer
    known_subjects  every lab.subject.subject_id
    overrides       parsed with subjects.parse_overrides / read_overrides
    header_cache    optional read-only mapping (root, path, size, mtime_ns) ->
                    header entry (cache.py); a hit is used exactly as a fresh
                    read and the file is not opened. The fresh entries of this
                    pass are returned in ``Interpretation.headers``.
    """
    _check_directories(listings)
    known = frozenset(known_subjects)
    groups: list[Group] = []
    held: list[HeldItem] = []
    reported: list[ReportedItem] = []
    fresh: dict = {}
    for listing in listings:
        spec = listing.spec
        pre: list[HeldItem] = []
        pre += [HeldItem(p, "symbolic_link", "a symbolic link (or reparse point); links are "
                         "not followed") for p in listing.links]
        pre += [HeldItem(p, "not_a_regular_file", "neither a regular file nor a folder")
                for p in listing.special]
        files = []
        for f in listing.files:
            why = _storable(f.path)
            if why is None:
                files.append(f)
            else:
                pre.append(HeldItem(f.path, "path_not_storable", why, f.size, f.mtime_ns))
        reader = HeaderReader(spec.root, root_paths[spec.root], header_cache)
        result = get_layout(spec.layout)(dataclasses.replace(listing, files=tuple(files)), reader)
        fresh.update(reader.fresh)
        keep, rep = reclassify_loose(spec.path, pre + list(result.held), known)
        held += keep
        reported += list(rep) + list(result.reported)
        groups += result.groups

    resolved, unused = resolve_subjects(groups, known, overrides)
    paired = apply_pairing(resolved, [listing.spec for listing in listings])
    final = _label_conflicts(paired)
    _account(listings, final, held, reported)
    return Interpretation(
        groups=tuple(sorted(final, key=lambda g: g.key)),
        held=tuple(sorted(held, key=lambda h: h.path)),
        reported=tuple(sorted(reported, key=lambda r: r.path)),
        ignored=tuple(i for listing in listings for i in listing.ignored),
        unreadable=tuple(u for listing in listings for u in listing.unreadable),
        unused_overrides=tuple(unused),
        complete=all(listing.complete for listing in listings),
        headers=fresh,
    )

