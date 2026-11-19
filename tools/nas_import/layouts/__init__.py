"""Layout registry: layout name -> ``interpret_listing(listing, reader) -> LayoutResult``.

``reader`` is a :class:`..cache.HeaderReader`: every header a layout needs
is read through it, so a cached result is used without opening the file.

A layout turns one directory listing into groups (one session and one event
each, with its files), held items and reported items. It reads only the
headers of files whose names it recognises; it never resolves subjects or
pairs (``subjects`` and ``pairing`` do, over every layout's groups).
"""

from __future__ import annotations

from typing import Callable

from ..cache import HeaderReader
from ..model import LayoutResult, Listing
from . import epsych, intan

LayoutFn = Callable[[Listing, HeaderReader], LayoutResult]

LAYOUTS: dict[str, LayoutFn] = {
    epsych.NAME: epsych.interpret_listing,
    intan.NAME: intan.interpret_listing,
}


def get_layout(name: str) -> LayoutFn:
    """The layout called NAME; KeyError naming the known ones otherwise."""
    try:
        return LAYOUTS[name]
    except KeyError:
        raise KeyError("no layout %r (known: %s)" % (name, ", ".join(sorted(LAYOUTS)))) from None
