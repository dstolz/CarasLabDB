"""Helpers shared by the layouts."""

from __future__ import annotations

from ..ids import mtime_text
from ..model import GroupFile, HeldItem, ListedFile, Listing, ReportedItem


def unstorable_reason(path: str) -> str | None:
    """Why PATH cannot be stored as a relative_path, checking EVERY component; or None.

    A component that is not UTF-8 text, holds a backslash or a control
    character, or has white space at either end (``SUBJ-ID-1255 ``) makes the
    whole path unstorable.
    """
    for part in path.split("/"):
        try:
            part.encode("utf-8")
        except UnicodeEncodeError:
            return "%r is not valid UTF-8 text" % part
        if "\\" in part:
            return "%r holds a backslash" % part
        if part != part.strip():
            return "%r has white space at an end" % part
        if any(ord(c) < 32 or ord(c) == 127 for c in part):
            return "%r holds a control character" % part
    return None


def split_listing(listing: Listing) -> tuple[list[ListedFile], list[HeldItem]]:
    """The listing's storable regular files, and its odd entries as held items.

    Odd entries: symbolic links (``symbolic_link``), special entries
    (``not_a_regular_file``) and files whose path has an unstorable
    component (``path_not_storable``). A layout places each odd entry in the
    group it would belong to (which holds the group) or leaves it loose.
    """
    files: list[ListedFile] = []
    odd: list[HeldItem] = []
    for p in listing.links:
        odd.append(HeldItem(p, "symbolic_link", "a symbolic link (or reparse point); links are "
                            "not followed"))
    for p in listing.special:
        odd.append(HeldItem(p, "not_a_regular_file", "neither a regular file nor a folder"))
    for f in listing.files:
        why = unstorable_reason(f.path)
        if why is None:
            files.append(f)
        else:
            odd.append(HeldItem(f.path, "path_not_storable", "the path cannot be stored: " + why,
                                f.size, f.mtime_ns))
    return files, sorted(odd, key=lambda h: h.path)


def odd_hold_sentence(h: HeldItem) -> str:
    return "%s: %s" % (h.path.rsplit("/", 1)[-1], h.sentence)


def parts_under(listing: Listing, path: str) -> list[str]:
    """PATH's segments below the listed directory."""
    prefix = listing.spec.path + "/"
    if not path.startswith(prefix):
        raise ValueError("%s is not under %s" % (path, listing.spec.path))
    return path[len(prefix):].split("/")


def file_format(name: str) -> str | None:
    """Lower-case extension without the dot; None for a name without one."""
    base = name.rsplit("/", 1)[-1]
    if "." not in base.lstrip("."):
        return None
    ext = base.rsplit(".", 1)[1].lower()
    return ext or None


def group_file(f: ListedFile, role: str, attributes: dict) -> GroupFile:
    attrs = dict(attributes)
    attrs["source_mtime"] = mtime_text(f.mtime_ns)
    return GroupFile(f.path, f.size, f.mtime_ns, role, file_format(f.path), attrs)


def held(f: ListedFile, code: str, sentence: str, group_key: str | None = None) -> HeldItem:
    return HeldItem(f.path, code, sentence, f.size, f.mtime_ns, group_key)


def empty_folders(listing: Listing) -> list[ReportedItem]:
    """Folders with nothing beneath them (no file, link, ignored or unreadable entry)."""
    occupied: set[str] = set()
    for p in ([f.path for f in listing.files] + list(listing.links) + list(listing.special)
              + [i.path for i in listing.ignored] + [u.path for u in listing.unreadable]):
        while "/" in p:
            p = p.rsplit("/", 1)[0]
            occupied.add(p)
    return [ReportedItem(d, "empty_folder", "an empty folder; nothing to register", is_dir=True)
            for d in listing.dirs if d not in occupied]
