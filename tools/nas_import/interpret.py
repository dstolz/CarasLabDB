"""The whole database-free interpretation of a scan.

``interpret(listings, root_paths, known_subjects, overrides, header_cache)``
takes the walker's listings and returns an :class:`Interpretation`. It is a
pure function of its arguments and of the header bytes it reads (the layouts
read the start of ``.mat``, ``.rhd`` and ``.ts`` files): two listings of an
unchanged tree give equal results, the same keys and signatures. It never
opens a database, writes nothing, and keeps no state between calls.

Checks before anything is read (ValueError): directories that are equal or
nested; a spec with ``pair_with`` or ``paired_by`` whose partner's listing
is not passed, or whose partner does not name it back -- interpreting an
ePsych directory without the recordings it pairs with would register its
sessions unpaired.

Stages:

1. Per listing, the directory's layout (:mod:`.layouts`). Links, special
   entries and unstorable paths are placed by the layout: inside a group's
   folder they hold the group and are part of its signature, elsewhere they
   are loose held items (``symbolic_link``, ``not_a_regular_file``,
   ``path_not_storable``; a component with white space at an end makes
   everything under it ``path_not_storable``).
2. Names in one folder that differ only in ASCII case: every group holding
   such an entry, or an entry under such a folder, is held
   (``name_case_conflict``). No override releases it (an override cannot say
   which spelling is meant): the remedy is to rename on the NAS.
3. Subjects and overrides (:func:`.subjects.resolve_subjects`); loose items
   in an unknown level-1 folder are held ``unknown_subject``, those under a
   folder an override skips are reported.
4. Pairing (:func:`.pairing.apply_pairing`).
5. Two ready groups of one subject that would give two sessions the same
   label are held (``session_label_conflict``; ``lab.session`` has
   ``UNIQUE (subject_id, label)``).
6. When any listing is incomplete, every ready group is held
   (``listing_incomplete``).
7. Accounting: every listed file (and link and special entry) must be in
   exactly one place -- a group's files or held files, a loose held item or
   a reported item; otherwise RuntimeError (a bug, never data).

It does not decide whether a group is old or stable enough: the database
side registers a group only when two complete listings at least the
directory's ``min_age_min`` apart give the same :func:`.ids.signature`.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Collection, Mapping, Sequence

from .cache import HeaderReader
from .layouts import get_layout
from .model import (Group, HeldItem, Hold, Interpretation, Listing, Override, ReportedItem,
                    with_hold)
from .names import ascii_fold
from .pairing import apply_pairing
from .subjects import resolve_subjects


def _check_directories(listings: Sequence[Listing]) -> None:
    seen: list[tuple[str, str]] = []
    for listing in listings:
        s = listing.spec
        for root, path in seen:
            a, b = ascii_fold(path) + "/", ascii_fold(s.path) + "/"
            if root == s.root and (a.startswith(b) or b.startswith(a)):
                raise ValueError("directories %s:%s and %s:%s are equal or nested"
                                 % (root, path, s.root, s.path))
        seen.append((s.root, s.path))
    by_dir = {(listing.spec.root, listing.spec.path): listing.spec for listing in listings}
    for s in by_dir.values():
        if s.pair_with is not None:
            other = by_dir.get((s.root, s.pair_with))
            if other is None:
                raise ValueError("%s:%s pairs with %s, whose listing was not given"
                                 % (s.root, s.path, s.pair_with))
            if other.paired_by != s.path:
                raise ValueError("%s:%s pairs with %s, but that directory's paired_by is %r"
                                 % (s.root, s.path, s.pair_with, other.paired_by))
        if s.paired_by is not None:
            other = by_dir.get((s.root, s.paired_by))
            if other is None:
                raise ValueError("%s:%s is paired by %s, whose listing was not given"
                                 % (s.root, s.path, s.paired_by))
            if other.pair_with != s.path:
                raise ValueError("%s:%s is paired by %s, but that directory's pair_with is %r"
                                 % (s.root, s.path, s.paired_by, other.pair_with))


def _case_conflicts(listing: Listing) -> set[str]:
    """Paths of entries whose name differs from a sibling's only in ASCII case, and
    of everything under such a folder."""
    names: dict[tuple[str, str], set[str]] = defaultdict(set)
    entries = ([f.path for f in listing.files] + list(listing.links) + list(listing.special)
               + list(listing.dirs))
    for p in entries:
        parent, _, name = p.rpartition("/")
        names[(parent, ascii_fold(name))].add(name)
    bad_prefixes = set()
    for (parent, _folded), spelled in names.items():
        if len(spelled) > 1:
            bad_prefixes.update(parent + "/" + n for n in spelled)
    if not bad_prefixes:
        return set()
    out = set()
    for p in entries:
        q = p
        while True:
            if q in bad_prefixes:
                out.add(p)
                break
            if "/" not in q:
                break
            q = q.rsplit("/", 1)[0]
    return out


def _label_conflicts(groups: Sequence[Group]) -> tuple[Group, ...]:
    paths: dict[tuple[str, str], set[str]] = defaultdict(set)
    for g in groups:
        if g.status == "ready":
            paths[(g.subject_id, g.label)].add(g.session_path)
    out = []
    for g in groups:
        p = paths.get((g.subject_id, g.label))
        if g.status == "ready" and p is not None and len(p) > 1:
            g = with_hold(g, Hold("session_label_conflict", "sessions %s of subject %s would all "
                                  "be labelled %s" % (", ".join(sorted(p)), g.subject_id, g.label)))
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
              header_cache: Mapping | None = None, stats=None) -> Interpretation:
    """Interpret LISTINGS (see the module docstring).

    root_paths      storage root name -> its mount path on this computer
    known_subjects  every lab.subject.subject_id
    overrides       parsed with subjects.parse_overrides / read_overrides
    header_cache    optional read-only mapping (root, path, size, mtime_ns) ->
                    header entry (cache.py); a hit is used exactly as a fresh
                    read and the file is not opened. The fresh entries of this
                    pass are returned in ``Interpretation.headers``.
    stats           optional dict or object counting header reads: ``files_opened``
                    and ``bytes_read`` are increased (cache.HeaderReader)
    """
    _check_directories(listings)
    known = frozenset(known_subjects)
    groups: list[Group] = []
    loose: list[tuple[str, str, HeldItem]] = []
    reported: list[ReportedItem] = []
    fresh: dict = {}
    for listing in listings:
        spec = listing.spec
        reader = HeaderReader(spec.root, root_paths[spec.root], header_cache, stats)
        result = get_layout(spec.layout)(listing, reader)
        fresh.update(reader.fresh)
        conflicted = _case_conflicts(listing)
        for g in result.groups:
            clash = sorted(p for p in g.all_paths() if p in conflicted)
            if clash:
                g = with_hold(g, Hold("name_case_conflict", "%s differs from another name in "
                                      "its folder only in case" % clash[0]))
            groups.append(g)
        for h in result.held:
            loose.append((spec.root, spec.path, h))
        reported += list(result.reported)

    resolved, held, skipped_items, unused = resolve_subjects(groups, known, overrides, loose)
    reported += list(skipped_items)
    paired = apply_pairing(resolved, [listing.spec for listing in listings])
    final = _label_conflicts(paired)
    complete = all(listing.complete for listing in listings)
    if not complete:
        final = tuple(with_hold(g, Hold("listing_incomplete", "part of the listing could not be "
                                        "read; nothing is registered from it"))
                      if g.status == "ready" else g for g in final)
    _account(listings, final, held, reported)
    return Interpretation(
        groups=tuple(sorted(final, key=lambda g: g.key)),
        held=tuple(sorted(held, key=lambda h: h.path)),
        reported=tuple(sorted(reported, key=lambda r: r.path)),
        ignored=tuple(i for listing in listings for i in listing.ignored),
        unreadable=tuple(u for listing in listings for u in listing.unreadable),
        unused_overrides=tuple(unused),
        complete=complete,
        headers=fresh,
    )
