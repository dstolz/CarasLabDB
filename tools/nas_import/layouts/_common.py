"""Helpers shared by the layouts."""

from __future__ import annotations

from ..ids import mtime_text
from ..model import GroupFile, HeldItem, ListedFile, Listing, ReportedItem


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
    return base.rsplit(".", 1)[1].lower()


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
