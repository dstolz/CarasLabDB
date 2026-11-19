"""A cache of file header results, so registered files are not opened on every scan.

Correctness must NEVER depend on this cache: it is an optimisation only. A
missing, unreadable or malformed cache file loads as an empty cache, an
entry that is malformed or carries an old reader tag is ignored, and every
file not in the cache is read exactly as without one.

Key: ``(root, path, size, mtime_ns)`` -- the storage root's name, the path
under it, and the size and ``st_mtime_ns`` as listed. A file whose size or
mtime differs from the cached key is simply another key (a miss).

Entry: a JSON object with a ``reader`` tag and either the reader's result or
a content problem that depends only on the bytes:

* ``{"reader": "mat5/2", "variables": [[name, class, dims or null, compressed], ...]}``
* ``{"reader": "rhd/2", "header": {... whole numbers ..., "sample_rate": "num/den"}}``
* ``{"reader": "ts/1", "packets": n}``
* ``{"reader": <tag>, "problem": [reason_code, sentence]}``

An entry is used only if every value is one a fresh read of a file of the
key's size could give (exact key set, the reader's own bounds and
arithmetic, a problem code that reader can raise); anything else -- a
hostile or damaged entry included -- is a miss and the file is read.

No floats anywhere. Transient outcomes (``unreadable_file``,
``changed_during_scan``) are never entries. The tags are the module
constants ``mat5.READER``, ``rhd.READER`` and ``content.TS_READER``; each
must be raised whenever its reader's result for the same bytes could change,
and an entry whose tag is not the current one is treated as absent.

``HeaderReader`` is what the layouts read through: it consults a read-only
mapping (a :class:`HeaderCache`, ``HeaderCache.restricted_to(keys)`` or any
dict), opens the file only on a miss, and collects the fresh entries in
``fresh`` for :attr:`.model.Interpretation.headers`.
"""

from __future__ import annotations

import json
import os
import tempfile
from collections.abc import Iterable, Iterator, Mapping

from . import content, mat5, rhd
from .content import ContentProblem
from .model import ListedFile

FORMAT = "caraslabdb-nas-header-cache/1"

Key = tuple  # (root: str, path: str, size: int, mtime_ns: int)

def _ts_from_entry(entry: dict, size: int) -> int:
    if set(entry) != {"reader", "packets"}:
        raise ValueError("unexpected keys")
    n = entry["packets"]
    if type(n) is not int or n != min(content.TS_PACKETS_CHECKED, size // content.TS_PACKET) or n < 1:
        raise ValueError("packets")
    return n


_KINDS = {
    "mat5": (lambda: mat5.READER, lambda fh, size: mat5.to_entry(mat5.read_variables(fh, size)),
             mat5.from_entry),
    "rhd": (lambda: rhd.READER, lambda fh, size: rhd.to_entry(rhd.read_header(fh, size)),
            rhd.from_entry),
    "ts": (lambda: content.TS_READER,
           lambda fh, size: {"reader": content.TS_READER,
                             "packets": content.check_mpeg_ts(fh, size)},
           _ts_from_entry),
}

# The problem codes each reader can raise from the bytes alone.
_PROBLEMS = {
    "mat5": frozenset({"mat_v73", "mat_not_mat5", "mat_truncated", "mat_corrupt",
                       "mat_big_endian"}),
    "rhd": frozenset({"rhd_bad_magic", "rhd_truncated", "rhd_bad_header", "rhd_partial_block",
                      "rhd_unknown_version"}),
    "ts": frozenset({"video_not_mpeg_ts"}),
}


def file_key(root: str, f: ListedFile) -> Key:
    """The cache key of listed file F on storage root ROOT."""
    return (root, f.path, f.size, f.mtime_ns)


def _valid_key(key) -> bool:
    return (isinstance(key, tuple) and len(key) == 4 and isinstance(key[0], str)
            and isinstance(key[1], str) and type(key[2]) is int and type(key[3]) is int)


class HeaderCache(Mapping):
    """Header entries by key; load/save to a JSON file. An optimisation only."""

    def __init__(self, entries: Mapping | None = None):
        self._d: dict = {}
        for k, v in (entries or {}).items():
            self.put(k, v)

    def __getitem__(self, key):
        return self._d[key]

    def __iter__(self) -> Iterator:
        return iter(self._d)

    def __len__(self) -> int:
        return len(self._d)

    def get(self, key, default=None):
        return self._d.get(key, default)

    def put(self, key, entry: dict) -> None:
        """Store ENTRY under KEY; ValueError for a bad key or an entry without a reader tag."""
        key = tuple(key)
        if not _valid_key(key) or not isinstance(entry, dict) or not isinstance(entry.get("reader"), str):
            raise ValueError("a malformed cache key or entry")
        self._d[key] = entry

    def restricted_to(self, keys: Iterable) -> dict:
        """A mapping holding only those of KEYS that are in the cache."""
        return {tuple(k): self._d[tuple(k)] for k in keys if tuple(k) in self._d}

    @classmethod
    def load(cls, path: str) -> HeaderCache:
        """Read the cache at PATH; empty (never an error) when missing, unreadable or malformed."""
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
            if not isinstance(data, dict) or data.get("format") != FORMAT:
                return cls()
            out = cls()
            for row in data["entries"]:
                if not isinstance(row, list) or len(row) != 5:
                    return cls()
                out.put(tuple(row[:4]), row[4])
            return out
        except Exception:      # anything at all, RecursionError and MemoryError included
            return cls()

    def save(self, path: str) -> None:
        """Write the cache to PATH atomically (temp file in the same folder, fsync, os.replace)."""
        rows = [list(k) + [self._d[k]] for k in sorted(self._d)]
        text = json.dumps({"format": FORMAT, "entries": rows}, ensure_ascii=False,
                          sort_keys=True, separators=(",", ":"))
        folder = os.path.dirname(os.path.abspath(path))
        fd, tmp = tempfile.mkstemp(prefix=".header-cache-", suffix=".tmp", dir=folder)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise


def _check_no_float(v) -> None:
    if isinstance(v, float):
        raise TypeError("a float in a cache entry")
    if isinstance(v, dict):
        for x in v.values():
            _check_no_float(x)
    elif isinstance(v, (list, tuple)):
        for x in v:
            _check_no_float(x)


class HeaderReader:
    """Reads file headers for the layouts, through an optional read-only cache."""

    def __init__(self, root: str, root_path: str, cache: Mapping | None = None):
        self.root = root
        self.root_path = root_path
        self.cache = cache
        self.fresh: dict = {}

    def read(self, f: ListedFile, kind: str):
        """The decoded result of reader KIND (``mat5`` | ``rhd`` | ``ts``) for file F.

        Raises ContentProblem for a content problem, cached or fresh.
        """
        tag_fn, read_fn, decode = _KINDS[kind]
        tag = tag_fn()
        key = file_key(self.root, f)
        if self.cache is not None:
            try:
                entry = self.cache.get(key)
            except Exception:
                entry = None
            if isinstance(entry, dict) and entry.get("reader") == tag:
                try:
                    return self._decode(entry, decode, kind, f.size)
                except ContentProblem:
                    raise
                except Exception:
                    pass                                   # a malformed entry: read the file
        try:
            with content.open_listed(self.root_path, f) as fh:
                entry = read_fn(fh, f.size)
        except ContentProblem as exc:
            if exc.code in content.TRANSIENT:
                raise
            entry = {"reader": tag, "problem": [exc.code, exc.sentence]}
        _check_no_float(entry)
        self.fresh[key] = entry
        return self._decode(entry, decode, kind, f.size)

    @staticmethod
    def _decode(entry: dict, decode, kind: str, size: int):
        if "problem" in entry:
            if set(entry) != {"reader", "problem"}:
                raise ValueError("unexpected keys")
            problem = entry["problem"]
            if not isinstance(problem, list) or len(problem) != 2:
                raise ValueError("a malformed problem entry")
            code, sentence = problem
            if (not isinstance(code, str) or not isinstance(sentence, str)
                    or code not in _PROBLEMS[kind] or len(sentence) > 4096):
                raise ValueError("a malformed problem entry")
            raise ContentProblem(code, sentence)
        return decode(entry, size)
