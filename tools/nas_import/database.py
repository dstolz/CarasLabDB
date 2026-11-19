"""Database access of the NAS importer: every statement it sends is here.

Needs psycopg (v3); the connection comes from the ``PG*`` environment, as for
``tools/verify_artifacts.py``. The connection is in autocommit mode: a
statement outside :meth:`Database.transaction` is its own transaction, and a
group is registered inside one ``transaction()`` block, so it is written
whole or not at all.

**Locks.** One process searches a directory at a time. The lock is a
*session-level* advisory lock on the two-integer key ``(LOCK_CLASS,
scan_directory_id)``. PostgreSQL keeps the two-integer keys apart from the
single-``bigint`` keys, and every lock of ``design_docs/schema.sql`` is a
single ``bigint`` (``hashtextextended('lab.scan_directory:..')`` and the
like), so this key cannot collide with one of the schema's. A session-level
lock ends with its connection: :meth:`Database.reconnect` takes every lock
the old connection held again, and says so when it cannot.

**Clock.** Times that are compared (when a run started) are read from the
database as whole microseconds since 1970 (``started_us``); the tool's own
clock is never compared with them.

Never sent: a ``*_login`` column, ``recorded_by`` / ``created_by`` /
``verified_by`` of the append-only tables (the database's stamp triggers
fill them from the login). ``lab.session`` has no such trigger, so its
``created_by`` is sent as ``lab.fn_current_person()``, evaluated by the
database.
"""

from __future__ import annotations

import json
from contextlib import contextmanager
from dataclasses import dataclass

LOCK_CLASS = 0x4E415349          # "NASI"; first key of the two-integer advisory lock

SCAN_LOGS = ("lab.scan_run", "lab.scan_run_result", "lab.scan_file")

RESULT_COUNTERS = ("files_listed", "files_unchanged", "files_pending", "files_registered",
                   "files_known", "files_held", "files_ignored", "files_cleared",
                   "groups_registered", "groups_waiting", "groups_held", "bytes_read")


class DatabaseError(Exception):
    """A database problem the caller reports (not a lost connection)."""


class ConnectionLost(Exception):
    """The connection is gone; nothing more may be written on it."""


@dataclass(frozen=True)
class Directory:
    """One row of lab.scan_directory, with its storage root's name."""
    id: int
    root_id: int
    root: str
    path: str
    layout: str
    rig: str | None
    pair_with: int | None
    time_zone: str
    min_age_min: int
    mode: str

    @property
    def name(self) -> str:
        return "%d %s:%s" % (self.id, self.root, self.path)


@dataclass(frozen=True)
class MemoryRow:
    """The latest lab.scan_file row of one path, with when its run started."""
    path: str
    size: int | None
    mtime_ns: int | None
    group_key: str | None
    status: str
    reason_code: str | None
    reason: str | None
    artifact_id: str | None
    run_id: int
    run_us: int                  # scan_run.started_at, microseconds since 1970


@dataclass(frozen=True)
class ArtifactFact:
    """An artifact row and the row that describes its file now.

    ``live``: the current version of the row describes the same file (root,
    path, checksum) and is in lab.artifact_present -- not retracted, and not
    recorded as replaced, moved or deleted.
    """
    artifact_id: str
    path: str
    checksum: str
    checksum_algo: str
    current_id: str
    live: bool
    event_id: str                # produced_by_event_id of the current row


@dataclass(frozen=True)
class EventFact:
    """An event as asked for (``asked_id``) and its current version."""
    asked_id: str
    event_id: str
    event_type: str
    subject_id: str | None
    session_id: str | None
    digest: str | None           # attributes.client_digest of the current version
    retracted: bool


@dataclass(frozen=True)
class MemoryWrite:
    """One row to append to lab.scan_file."""
    path: str
    status: str
    size: int | None = None
    mtime_ns: int | None = None
    group_key: str | None = None
    reason_code: str | None = None
    reason: str | None = None
    artifact_id: str | None = None


_DIRECTORY_SQL = """
SELECT d.scan_directory_id, d.storage_root_id, sr.name, d.relative_path, d.layout, d.rig,
       d.pair_with, d.time_zone, d.min_age_min, d.mode
FROM lab.scan_directory d JOIN lab.storage_root sr ON sr.root_id = d.storage_root_id
"""

# The current version of a row is the row itself unless something supersedes
# it (the index on supersedes answers that), so lab.fn_artifact_current /
# lab.fn_event_current walk a chain only for the few rows that have one.
_ARTIFACT_COLUMNS = """
       a.artifact_id::text, a.relative_path, a.checksum, a.checksum_algo, c.artifact_id::text,
       (    c.storage_root_id = a.storage_root_id AND c.relative_path = a.relative_path
        AND c.checksum = a.checksum
        AND EXISTS (SELECT 1 FROM lab.artifact_present p WHERE p.artifact_id = c.artifact_id)),
       c.produced_by_event_id::text
"""

_ARTIFACT_CURRENT = """
JOIN lab.artifact c ON c.artifact_id = CASE
         WHEN EXISTS (SELECT 1 FROM lab.artifact n WHERE n.supersedes = a.artifact_id)
         THEN lab.fn_artifact_current(a.artifact_id) ELSE a.artifact_id END
"""

_EVENT_FACT = """
SELECT e.event_id::text, c.event_id::text, c.event_type, c.subject_id, c.session_id::text,
       c.attributes->>'client_digest',
       EXISTS (SELECT 1 FROM lab.retraction r WHERE r.event_id = c.event_id)
FROM lab.event e
JOIN lab.event c ON c.event_id = CASE
         WHEN EXISTS (SELECT 1 FROM lab.event n WHERE n.supersedes = e.event_id)
         THEN lab.fn_event_current(e.event_id) ELSE e.event_id END
WHERE e.event_id = ANY(%s::uuid[])
"""

_DETAIL_SQL = {
    "recording": ("INSERT INTO lab.recording_event (event_id, acquisition_system_code, modality, "
                  "sample_rate_hz, n_channels, duration_s) VALUES (%s::uuid, %s, %s, %s::numeric, "
                  "%s, %s::numeric)",
                  ("acquisition_system_code", "modality", "sample_rate_hz", "n_channels",
                   "duration_s")),
    "behavior": ("INSERT INTO lab.behavior_event (event_id, trials_completed) "
                 "VALUES (%s::uuid, %s)", ("trials_completed",)),
}


def _chunks(items, n=5000):
    items = list(items)
    for k in range(0, len(items), n):
        yield items[k:k + n]


class Database:
    """The importer's connection. See the module docstring."""

    def __init__(self, application_name: str = "import_nas_files"):
        self.application_name = application_name
        self.conn = None
        self._psycopg = None
        self.locks: set[int] = set()

    # ------------------------------------------------------------ connection
    def connect(self) -> None:
        """Open the connection (PG* environment). ImportError without psycopg."""
        import psycopg
        self._psycopg = psycopg
        self.conn = psycopg.connect(autocommit=True, application_name=self.application_name)

    def close(self) -> None:
        if self.conn is not None:
            try:
                self.conn.close()
            except Exception:           # closing a broken connection
                pass
        self.conn = None
        self.locks.clear()

    def lost(self, exc: BaseException | None = None) -> bool:
        """Whether the connection is gone (EXC, if given, says so too)."""
        if self.conn is None or self.conn.closed or self.conn.broken:
            return True
        return exc is not None and isinstance(exc, self._psycopg.OperationalError) and (
            self.conn.closed or self.conn.broken)

    def reconnect(self) -> bool:
        """Open a new connection and take the old one's locks again.

        Returns False -- and holds no lock -- when the database cannot be
        reached or a lock has been taken by another process meanwhile. The
        caller then stops: it must not go on writing a directory's rows
        without that directory's lock.
        """
        wanted = sorted(self.locks)
        try:
            if self.conn is not None:
                self.conn.close()
        except Exception:
            pass
        self.conn = None
        self.locks = set()
        try:
            self.connect()
            for directory_id in wanted:
                if not self.lock(directory_id):
                    for held in sorted(self.locks):
                        self.unlock(held)
                    return False
        except Exception:
            self.conn = None
            self.locks = set()
            return False
        return True

    def error_types(self):
        """The driver's exception base class (for ``except``)."""
        return self._psycopg.Error

    @contextmanager
    def transaction(self):
        """One transaction: committed when the block ends, rolled back when it raises."""
        with self.conn.transaction():
            yield self

    def all(self, sql: str, params=()) -> list[tuple]:
        return self.conn.execute(sql, params).fetchall()

    def one(self, sql: str, params=()) -> tuple | None:
        return self.conn.execute(sql, params).fetchone()

    def run(self, sql: str, params=()) -> None:
        self.conn.execute(sql, params)

    # ----------------------------------------------------------------- locks
    def lock(self, directory_id: int) -> bool:
        """Take the directory's lock for this session; False when another process has it."""
        got = self.one("SELECT pg_try_advisory_lock(%s::integer, %s::integer)",
                       (LOCK_CLASS, directory_id))[0]
        if got:
            self.locks.add(directory_id)
        return bool(got)

    def unlock(self, directory_id: int) -> None:
        self.locks.discard(directory_id)
        self.run("SELECT pg_advisory_unlock(%s::integer, %s::integer)", (LOCK_CLASS, directory_id))

    # ------------------------------------------------------------- reference
    def storage_roots(self) -> dict[str, int]:
        return {name: root_id for name, root_id in
                self.all("SELECT name, root_id FROM lab.storage_root")}

    def subjects(self) -> frozenset[str]:
        return frozenset(r[0] for r in self.all("SELECT subject_id FROM lab.subject"))

    def missing_log_privileges(self) -> list[str]:
        """The scan logs the current role may not INSERT into."""
        return [t for t in SCAN_LOGS
                if not self.one("SELECT has_table_privilege(current_user, %s, 'INSERT')", (t,))[0]]

    def login(self) -> str:
        return "%s (session %s)" % self.one("SELECT current_user::text, session_user::text")

    def now_us(self) -> int:
        """The database's clock, microseconds since 1970."""
        return self.one("SELECT (extract(epoch FROM clock_timestamp()) * 1000000)::bigint")[0]

    # ------------------------------------------------------------ directories
    def due(self) -> list[tuple[int, str]]:
        """``lab.fn_scan_due()`` in its order: (scan_directory_id, due_at as text)."""
        return self.all("SELECT scan_directory_id, due_at::text FROM lab.fn_scan_due()")

    def still_due(self, directory_id: int) -> str | None:
        """The directory's due_at (text) if ``lab.fn_scan_due()`` still lists it."""
        row = self.one("SELECT due_at::text FROM lab.fn_scan_due() WHERE scan_directory_id = %s",
                       (directory_id,))
        return None if row is None else row[0]

    def directories(self) -> list[Directory]:
        """Every row of lab.scan_directory, ordered by root name, path and id."""
        return [Directory(*r) for r in self.all(
            _DIRECTORY_SQL + " ORDER BY sr.name, d.relative_path, d.scan_directory_id")]

    def directory(self, directory_id: int) -> Directory | None:
        row = self.one(_DIRECTORY_SQL + " WHERE d.scan_directory_id = %s", (directory_id,))
        return None if row is None else Directory(*row)

    def status(self) -> list[dict]:
        """lab.scan_directory_status, the columns ``check`` reads."""
        cols = ("scan_directory_id", "storage_root", "relative_path", "mode", "due_at",
                "is_due", "is_overdue", "is_running", "n_pending", "n_held", "last_run_outcome")
        rows = self.all("SELECT scan_directory_id, storage_root, relative_path, mode, "
                        "due_at::text, is_due, is_overdue, is_running, n_pending, n_held, "
                        "last_run_outcome FROM lab.scan_directory_status "
                        "ORDER BY storage_root, relative_path, scan_directory_id")
        return [dict(zip(cols, r)) for r in rows]

    def overlaps(self) -> list[tuple[str, str]]:
        return self.all("SELECT subject, detail FROM lab.fn_check_integrity() "
                        "WHERE check_name = 'scan_directory_overlap' ORDER BY subject, detail")

    def window_open(self, directory_id: int) -> bool:
        return bool(self.one("SELECT lab.fn_scan_window_open(%s)", (directory_id,))[0])

    # ------------------------------------------------------------------ runs
    def insert_run(self, directory_id: int, command: str, mode: str, due_at: str | None,
                   tool_version: str, host: str) -> tuple[int, int, str]:
        """Append the lab.scan_run row: (scan_run_id, started_us, started as UTC text)."""
        return self.one(
            "INSERT INTO lab.scan_run (scan_directory_id, command, mode, due_at, tool_version, "
            "host) VALUES (%s, %s, %s, %s::timestamptz, %s, %s) RETURNING scan_run_id, "
            "(extract(epoch FROM started_at) * 1000000)::bigint, "
            "to_char(started_at AT TIME ZONE 'UTC', 'YYYYMMDD\"T\"HH24MISS\"Z\"')",
            (directory_id, command, mode, due_at, tool_version, host))

    def insert_result(self, run_id: int, outcome: str, counters: dict, message: str | None,
                      details: dict) -> None:
        cols = [c for c in RESULT_COUNTERS if c in counters]
        self.run(
            "INSERT INTO lab.scan_run_result (scan_run_id, outcome, message, details%s) "
            "VALUES (%%s, %%s, %%s, %%s::jsonb%s)"
            % ("".join(", " + c for c in cols), ", %s" * len(cols)),
            [run_id, outcome, message, json.dumps(details, sort_keys=True, ensure_ascii=False)]
            + [int(counters[c]) for c in cols])

    def previous_result(self, directory_id: int, before_run: int | None) -> tuple | None:
        """(outcome, message, details) of the directory's latest earlier run that has a result."""
        return self.one(
            "SELECT x.outcome, x.message, x.details FROM lab.scan_run r "
            "JOIN lab.scan_run_result x ON x.scan_run_id = r.scan_run_id "
            "WHERE r.scan_directory_id = %s AND (%s::bigint IS NULL OR r.scan_run_id < %s::bigint) "
            "ORDER BY r.scan_run_id DESC LIMIT 1", (directory_id, before_run, before_run))

    # ---------------------------------------------------------------- memory
    def memory(self, root_id: int, directory_path: str) -> dict[str, MemoryRow]:
        """The latest scan-memory row of every path under DIRECTORY_PATH, by path."""
        rows = self.all(
            "SELECT l.relative_path, l.size_bytes, l.mtime_ns, l.group_key, l.status, "
            "l.reason_code, l.reason, l.artifact_id::text, l.scan_run_id, "
            "(extract(epoch FROM r.started_at) * 1000000)::bigint "
            "FROM lab.scan_file_latest l JOIN lab.scan_run r ON r.scan_run_id = l.scan_run_id "
            "WHERE l.storage_root_id = %s AND starts_with(l.relative_path, %s)",
            (root_id, directory_path + "/"))
        return {r[0]: MemoryRow(*r) for r in rows}

    def write_memory(self, run_id: int, root_id: int, rows: list[MemoryWrite]) -> None:
        """Append ROWS to lab.scan_file (inside the caller's transaction, if any)."""
        if not rows:
            return
        with self.conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, "
                "size_bytes, mtime_ns, group_key, status, reason_code, reason, artifact_id) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s::uuid)",
                [(run_id, root_id, r.path, r.size, r.mtime_ns, r.group_key, r.status,
                  r.reason_code, r.reason, r.artifact_id) for r in rows])

    # ------------------------------------------------------------- artifacts
    def artifact_facts(self, artifact_ids) -> dict[str, ArtifactFact]:
        """ArtifactFact of each of ARTIFACT_IDS, by id."""
        out: dict[str, ArtifactFact] = {}
        for chunk in _chunks(sorted(set(artifact_ids))):
            for r in self.all("SELECT" + _ARTIFACT_COLUMNS + "FROM lab.artifact a"
                              + _ARTIFACT_CURRENT + "WHERE a.artifact_id = ANY(%s::uuid[])",
                              (chunk,)):
                out[r[0]] = ArtifactFact(*r)
        return out

    def artifacts_at(self, root_id: int, paths) -> dict[str, list[ArtifactFact]]:
        """Every artifact row at one of PATHS on the root, compared WITHOUT case.

        By the path asked for; a row whose ``path`` is spelled differently
        from the key differs from it in case only.
        """
        out: dict[str, list[ArtifactFact]] = {}
        for chunk in _chunks(sorted(set(paths))):
            rows = self.all(
                "SELECT q.p," + _ARTIFACT_COLUMNS + "FROM unnest(%s::text[]) AS q(p) "
                "JOIN lab.artifact a ON a.storage_root_id = %s "
                "AND lower(a.relative_path) = lower(q.p)" + _ARTIFACT_CURRENT,
                (chunk, root_id))
            for r in rows:
                out.setdefault(r[0], []).append(ArtifactFact(*r[1:]))
        return out

    def present_under(self, root_id: int, directory_path: str) -> list[str]:
        """Paths of lab.artifact_present under the directory (compared without case)."""
        return [r[0] for r in self.all(
            "SELECT DISTINCT relative_path FROM lab.artifact_present WHERE storage_root_id = %s "
            "AND starts_with(lower(relative_path), lower(%s)) ORDER BY 1",
            (root_id, directory_path + "/"))]

    def raw_copies(self, checksums) -> dict[str, list[tuple[str, str]]]:
        """checksum -> [(event_id, artifact_id)] of active ``raw`` artifacts of active events."""
        out: dict[str, list[tuple[str, str]]] = {}
        for chunk in _chunks(sorted(set(checksums))):
            for c, e, a in self.all(
                    "SELECT a.checksum, a.produced_by_event_id::text, a.artifact_id::text "
                    "FROM lab.artifact_active a "
                    "JOIN lab.event_active e ON e.event_id = a.produced_by_event_id "
                    "WHERE a.role = 'raw' AND a.checksum_algo = 'sha256' AND a.checksum = ANY(%s) "
                    "ORDER BY 1, 2, 3", (chunk,)):
                out.setdefault(c, []).append((e, a))
        return out

    def event_artifacts(self, event_id: str) -> dict[str, str]:
        """checksum -> artifact_id of the active artifacts of EVENT_ID (the first by id)."""
        out: dict[str, str] = {}
        for c, a in self.all("SELECT checksum, artifact_id::text FROM lab.artifact_active "
                             "WHERE produced_by_event_id = %s::uuid ORDER BY 2", (event_id,)):
            out.setdefault(c, a)
        return out

    # ---------------------------------------------------------------- events
    def event_facts(self, event_ids) -> dict[str, EventFact]:
        """EventFact of each of EVENT_IDS that exists, by the id asked for."""
        out: dict[str, EventFact] = {}
        for chunk in _chunks(sorted(set(event_ids))):
            for r in self.all(_EVENT_FACT, (chunk,)):
                out[r[0]] = EventFact(*r)
        return out

    def local_time_problem(self, local: str, zone: str) -> str | None:
        """``nonexistent`` / ``ambiguous`` when wall-clock LOCAL is not one instant in ZONE.

        Decided by PostgreSQL, which has the zone's rules: a wall-clock time
        that does not survive the round trip through the zone was skipped (the
        clocks went forward); one that another instant within three hours
        also shows was repeated (the clocks went back). Offsets and their
        changes are multiples of 15 minutes.
        """
        row = self.one(
            "SELECT (t.at AT TIME ZONE %(z)s) <> t.wall, "
            "       EXISTS (SELECT 1 FROM generate_series(-12, 12) AS k "
            "               WHERE k <> 0 AND ((t.at + make_interval(mins => 15 * k)) "
            "                                 AT TIME ZONE %(z)s) = t.wall) "
            "FROM (SELECT %(t)s::timestamp AS wall, %(t)s::timestamp AT TIME ZONE %(z)s AS at) t",
            {"t": local, "z": zone})
        if row[0]:
            return "nonexistent"
        return "ambiguous" if row[1] else None

    # -------------------------------------------------------------- sessions
    def session(self, session_id: str) -> tuple | None:
        """(subject_id, label, storage_root_id, relative_path) of the session, if it exists."""
        return self.one("SELECT subject_id, label, storage_root_id, relative_path "
                        "FROM lab.session WHERE session_id = %s::uuid", (session_id,))

    def session_clashes(self, session_id: str, subject_id: str, label: str, root_id: int,
                        path: str) -> list[tuple]:
        """Other sessions holding this subject's label or this path (compared without case)."""
        return self.all(
            "SELECT session_id::text, subject_id, label, relative_path FROM lab.session "
            "WHERE session_id <> %s::uuid AND ((subject_id = %s AND label = %s) "
            "   OR (storage_root_id = %s AND lower(relative_path) = lower(%s))) ORDER BY 1",
            (session_id, subject_id, label, root_id, path))

    def insert_session(self, session_id: str, subject_id: str, label: str, root_id: int,
                       path: str, start_local: str | None, zone: str, duration: str | None,
                       rig: str | None) -> None:
        """A new lab.session row; the times are converted by PostgreSQL."""
        self.run(
            "INSERT INTO lab.session (session_id, subject_id, label, storage_root_id, "
            "relative_path, started_at, ended_at, rig, created_by) "
            "SELECT %(id)s::uuid, %(subject)s, %(label)s, %(root)s, %(path)s, t.at, "
            "       t.at + %(duration)s::numeric * interval '1 second', %(rig)s, "
            "       lab.fn_current_person() "
            "FROM (SELECT %(start)s::timestamp AT TIME ZONE %(zone)s AS at) t",
            {"id": session_id, "subject": subject_id, "label": label, "root": root_id,
             "path": path, "start": start_local, "zone": zone, "duration": duration, "rig": rig})

    def insert_event(self, event_id: str, event_type: str, subject_id: str, session_id: str,
                     occurred_local: str, zone: str, attributes: str, detail: dict) -> None:
        """The event and its detail row. ATTRIBUTES is JSON text."""
        self.run(
            "INSERT INTO lab.event (event_id, event_type, subject_id, session_id, occurred_at, "
            "attributes) VALUES (%s::uuid, %s, %s, %s::uuid, %s::timestamp AT TIME ZONE %s, "
            "%s::jsonb)",
            (event_id, event_type, subject_id, session_id, occurred_local, zone, attributes))
        sql, columns = _DETAIL_SQL[event_type]
        unknown = sorted(set(detail) - set(columns))
        if unknown:
            raise DatabaseError("the %s detail has no column %s" % (event_type, ", ".join(unknown)))
        self.run(sql, [event_id] + [detail.get(c) for c in columns])

    def insert_artifact(self, event_id: str, root_id: int, path: str, checksum: str, size: int,
                        role: str, file_format: str | None, subject_id: str | None,
                        session_id: str | None, attributes: str) -> str:
        """A new lab.artifact row and its ``ok`` verification; returns the artifact id."""
        artifact_id = self.one(
            "INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, relative_path, "
            "checksum, checksum_algo, size_bytes, role, format, subject_id, session_id, "
            "attributes) VALUES (%s::uuid, %s, %s, %s, 'sha256', %s, %s, %s, %s, %s::uuid, "
            "%s::jsonb) RETURNING artifact_id::text",
            (event_id, root_id, path, checksum, size, role, file_format, subject_id, session_id,
             attributes))[0]
        self.insert_verification(artifact_id, checksum)
        return artifact_id

    def insert_verification(self, artifact_id: str, checksum: str) -> None:
        self.run("INSERT INTO lab.artifact_verification (artifact_id, status, observed_checksum) "
                 "VALUES (%s::uuid, 'ok', %s)", (artifact_id, checksum))
