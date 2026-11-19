"""List one directory of a storage root: names, sizes, modification times.

``walk(root_path, spec)`` lists ``spec.path`` under the mounted root
``root_path`` with ``os.scandir``. No file is opened; each regular file is
stat'ed (``st_size``, ``st_mtime_ns``) without following links. Nothing is
ever written, renamed or deleted.

* Symbolic links (and, on Windows, junctions and other reparse points) are
  never followed; they are returned in ``Listing.links``.
* Entries other than regular files and folders are in ``Listing.special``.
* Ignored by name, anywhere in the tree (:data:`IGNORED_NAMES`,
  :data:`IGNORED_PREFIXES`) and the root marker :data:`MARKER_NAME`: returned
  in ``Listing.ignored``; an ignored folder is not interpreted, only its files
  are counted (for the reconciliation against an independent listing); one
  that cannot be listed is also unreadable.
* A folder that cannot be listed, or a file that cannot be stat'ed, is in
  ``Listing.unreadable`` and makes ``Listing.complete`` False. The caller then
  fails the run: nothing may be concluded from what is absent.

Refused before anything is listed (:class:`WalkError` subclasses): a
``spec.path`` that is not a clean relative path, a component that is missing
(:class:`DirectoryMissing`), spelled differently on disk
(:class:`SpellingMismatch`) or a link, and a directory that resolves outside
the root (:class:`OutsideRoot`).
"""

from __future__ import annotations

import os
import stat as stat_module

from .model import DirectorySpec, IgnoredItem, ListedFile, Listing, UnreadableItem

IGNORED_NAMES = frozenset({".DS_Store", "Thumbs.db", "@eaDir", "#recycle", "_gsdata_"})
IGNORED_PREFIXES = ("~$",)
MARKER_NAME = ".caraslabdb-root.json"

_REPARSE = getattr(stat_module, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)


class WalkError(Exception):
    """The directory cannot be listed at all; nothing was listed."""


class DirectoryMissing(WalkError):
    """A component of the directory's path does not exist."""


class SpellingMismatch(WalkError):
    """A component exists only with another spelling (case) on disk."""


class OutsideRoot(WalkError):
    """The directory resolves outside the storage root, or is reached through a link."""


def check_relative_path(path: str) -> None:
    """Raise ValueError unless PATH is a clean relative path with '/' separators."""
    if not isinstance(path, str) or path == "":
        raise ValueError("the path is empty")
    if path != path.strip():
        raise ValueError("the path %r has white space at an end" % path)
    if "\\" in path:
        raise ValueError("the path %r holds a backslash; use '/'" % path)
    if path.startswith("/") or (len(path) >= 2 and path[1] == ":"):
        raise ValueError("the path %r is absolute" % path)
    if path.endswith("/") or "//" in path:
        raise ValueError("the path %r has an empty segment" % path)
    for part in path.split("/"):
        if part in (".", ".."):
            raise ValueError("the path %r holds a '.' or '..' segment" % path)


def is_ignored_name(name: str) -> bool:
    """True for a name the walker ignores (the marker file excluded)."""
    return name in IGNORED_NAMES or name.startswith(IGNORED_PREFIXES)


def _lstat(entry: os.DirEntry) -> os.stat_result:
    """The entry's stat, not following links (a seam for tests)."""
    return entry.stat(follow_symlinks=False)


def _is_link(entry: os.DirEntry) -> bool:
    if entry.is_symlink():
        return True
    is_junction = getattr(entry, "is_junction", None)
    if is_junction is not None and is_junction():
        return True
    if os.name == "nt":
        attrs = getattr(entry.stat(follow_symlinks=False), "st_file_attributes", 0)
        return bool(attrs & _REPARSE)
    return False


def _sorted_entries(path: str) -> list[os.DirEntry]:
    with os.scandir(path) as it:
        return sorted(it, key=lambda e: e.name)


def _check_components(root_path: str, rel: str) -> str:
    """The directory's absolute path, each component checked for spelling and links."""
    current = root_path
    if not os.path.isdir(root_path):
        raise DirectoryMissing("the storage root %s is not a folder (is it mounted?)" % root_path)
    for part in rel.split("/"):
        try:
            entries = _sorted_entries(current)
        except OSError as exc:
            raise WalkError("cannot list %s: %s" % (current, exc)) from exc
        exact = [e for e in entries if e.name == part]
        if not exact:
            folded = [e.name for e in entries if e.name.casefold() == part.casefold()]
            if folded:
                raise SpellingMismatch("%r is spelled %r on disk under %s"
                                       % (part, folded[0], current))
            raise DirectoryMissing("no folder %r under %s" % (part, current))
        entry = exact[0]
        try:
            if _is_link(entry):
                raise OutsideRoot("%s is a link; links are not followed" % entry.path)
            if not entry.is_dir(follow_symlinks=False):
                raise DirectoryMissing("%s is not a folder" % entry.path)
        except OSError as exc:
            raise WalkError("cannot stat %s: %s" % (entry.path, exc)) from exc
        current = entry.path
    real_root = os.path.realpath(root_path)
    real = os.path.realpath(current)
    if os.path.commonpath([real_root, real]) != real_root:
        raise OutsideRoot("%s resolves to %s, outside the root %s" % (current, real, real_root))
    return current


def _count_files(path: str) -> tuple[int | None, str | None]:
    """Files beneath an ignored folder (links not followed); None and the error on failure."""
    count = 0
    stack = [path]
    while stack:
        here = stack.pop()
        try:
            for entry in _sorted_entries(here):
                if _is_link(entry):
                    count += 1
                elif entry.is_dir(follow_symlinks=False):
                    stack.append(entry.path)
                else:
                    count += 1
        except OSError as exc:
            return None, "%s: %s" % (here, exc)
    return count, None


def walk(root_path: str, spec: DirectorySpec) -> Listing:
    """List SPEC.path under ROOT_PATH completely; see the module docstring."""
    check_relative_path(spec.path)
    start = _check_components(root_path, spec.path)

    files: list[ListedFile] = []
    dirs: list[str] = []
    links: list[str] = []
    special: list[str] = []
    ignored: list[IgnoredItem] = []
    unreadable: list[UnreadableItem] = []

    stack = [(start, spec.path)]
    while stack:
        here, rel_here = stack.pop()
        try:
            entries = _sorted_entries(here)
        except OSError as exc:
            unreadable.append(UnreadableItem(rel_here, True, str(exc)))
            continue
        for entry in entries:
            rel = rel_here + "/" + entry.name
            try:
                if entry.name == MARKER_NAME:
                    ignored.append(IgnoredItem(rel, "root_marker", entry.is_dir(follow_symlinks=False),
                                               None if entry.is_dir(follow_symlinks=False) else 1))
                    continue
                if is_ignored_name(entry.name):
                    if entry.is_dir(follow_symlinks=False) and not _is_link(entry):
                        count, err = _count_files(entry.path)
                        ignored.append(IgnoredItem(rel, "ignored_name", True, count, err))
                        if err is not None:
                            # Any folder that cannot be listed makes the listing
                            # incomplete, an ignored one included.
                            unreadable.append(UnreadableItem(rel, True, err))
                    else:
                        ignored.append(IgnoredItem(rel, "ignored_name", False, 1))
                    continue
                if _is_link(entry):
                    links.append(rel)
                    continue
                if entry.is_dir(follow_symlinks=False):
                    dirs.append(rel)
                    stack.append((entry.path, rel))
                    continue
                if entry.is_file(follow_symlinks=False):
                    st = _lstat(entry)
                    if not stat_module.S_ISREG(st.st_mode):
                        special.append(rel)
                        continue
                    files.append(ListedFile(rel, int(st.st_size), int(st.st_mtime_ns)))
                    continue
                special.append(rel)
            except OSError as exc:
                unreadable.append(UnreadableItem(rel, False, str(exc)))

    return Listing(
        spec=spec,
        files=tuple(sorted(files, key=lambda f: f.path)),
        dirs=tuple(sorted(dirs)),
        links=tuple(sorted(links)),
        special=tuple(sorted(special)),
        ignored=tuple(sorted(ignored, key=lambda i: i.path)),
        unreadable=tuple(sorted(unreadable, key=lambda u: u.path)),
        complete=not unreadable,
    )
