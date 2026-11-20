"""Read tools for the NAS auto-scan: the directory list, its runs and the scan memory."""

from typing import Optional

from .. import db
from . import OptText
from .artifacts import _path

SCAN_MODES = ("off", "report", "register")
SCAN_COMMANDS = ("run", "apply")
SCAN_OUTCOMES = ("ok", "partial", "failed", "unreachable")
SCAN_STATUSES = ("pending", "registered", "known", "held", "cleared")


def _one_of(value, allowed, name):
    """`value` if it is one of `allowed` (or None); else the error every tool gives."""
    if value is not None and value not in allowed:
        listed = ", ".join(repr(a) for a in allowed)
        raise ValueError(f"{name} must be one of {listed}, got {value!r}.")
    return value


# One run with its result, if it has one. The columns are spelled out so that
# scan_run_id is not there twice; the outer SELECT lets the keyset predicate
# name plain columns. Fixed text: every caller-derived value is bound.
_RUNS_SQL = (
    "SELECT * FROM ("
    "SELECT r.scan_run_id, r.scan_directory_id, r.command, r.mode, r.due_at, "
    "r.started_at, r.tool_version, r.host, r.run_login, "
    "x.finished_at, x.outcome, x.files_listed, x.files_unchanged, x.files_pending, "
    "x.files_registered, x.files_known, x.files_held, x.files_ignored, x.files_cleared, "
    "x.groups_registered, x.groups_waiting, x.groups_held, x.bytes_read, "
    "x.message, x.details "
    "FROM lab.scan_run r LEFT JOIN lab.scan_run_result x ON x.scan_run_id = r.scan_run_id"
    ") q"
)


def register(app):
    @app.tool()
    def get_scan_directories(
        scan_directory_id: Optional[int] = None,
        storage_root_id: Optional[int] = None,
        mode: OptText = None,
        due_only: bool = False,
        overdue_only: bool = False,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List the NAS directories the scheduled scan searches, with their schedule state.

        The administrator's list of directories (lab.scan_directory) that
        tools/import_nas_files.py searches for files not yet registered,
        read through lab.scan_directory_status, which adds the schedule as
        of now. Use it to answer "which directories are searched, how
        often, and is the search keeping up?". Ordered by storage_root,
        relative_path, scan_directory_id.

        Each row: scan_directory_id; storage_root_id / storage_root (name)
        and relative_path (the directory under that root, forward slashes);
        layout (how its files are laid out); rig; pair_with (the
        scan_directory_id of a directory whose files belong with this
        one's); time_zone (the zone of the window and of the times in file
        names); scan_interval_min (minutes between searches); min_age_min
        (how long a group of files must have been seen unchanged before it
        is registered); notes; and created_*.

        mode is what a search may do: "off" (not searched), "report"
        (writes what it saw to the scan memory, see get_scan_files, but
        registers nothing) or "register" (registers new, unambiguous
        files). Anything else is an error. mode_changed_at is when it last
        changed.

        window_start_text and window_end_text are text "HH:MM" (24 hour,
        in the directory's time_zone, not UTC), both null when the
        directory may be searched at any hour; start after end means the
        window wraps midnight. window_open says whether the window is open
        now.

        Schedule state, as the database computes it: due_at is when the
        next search is owed; is_due is true when it is owed now (mode is
        not "off", due_at has come and the window is open), so the
        scheduled tool will pick it up at its next start; is_overdue is
        true when the last successful scheduled search is more than one
        interval plus 26 hours old (an alarm: the scheduler is stopped or
        every search fails); is_running is true while the latest run has no
        result and began within the last 24 hours. last_run_* describe the
        latest run of any kind (id, command, mode, started_at, outcome --
        null while it runs or if it was interrupted -- finished_at) and
        last_ok_* the latest scheduled run that ended "ok". n_pending is
        the number of files under the directory waiting to be seen
        unchanged; n_held the number left for a person to decide (see
        get_scan_files with status="held").

        due_only=True keeps rows with is_due, overdue_only=True rows with
        is_overdue; false means "do not filter", not "not due". A filter
        left out (or null) is not applied. Returns {"row_count", "limit",
        "truncated", "rows"}; `limit` (max 1000) caps the rows.
        """
        _one_of(mode, SCAN_MODES, "mode")
        return db.select_from("lab.scan_directory_status", {
            "scan_directory_id": scan_directory_id, "storage_root_id": storage_root_id,
            "mode": mode,
            "is_due": True if due_only else None,
            "is_overdue": True if overdue_only else None,
        }, limit=limit)

    @app.tool()
    def get_scan_runs(
        scan_directory_id: Optional[int] = None,
        outcome: OptText = None,
        command: OptText = None,
        started_from: OptText = None,
        started_before: OptText = None,
        limit: int = db.DEFAULT_LIMIT,
        cursor: OptText = None,
    ) -> dict:
        """List searches of the scanned NAS directories (runs), newest first, with their result.

        One row per run (lab.scan_run) joined to its result
        (lab.scan_run_result) when it has one. A run with no result is
        running or was interrupted: its `outcome`, `finished_at`, counts and
        `message` are null (the latest run's is_running in
        get_scan_directories says which). Ordered by scan_run_id, newest
        first.

        Run columns: scan_run_id, scan_directory_id (see
        get_scan_directories), command ("run" = the scheduled unattended
        search, "apply" = a reviewed plan applied by a person), mode
        ("report" or "register", the mode it was made in), due_at (the
        scheduled time a "run" answers; null for a run made by hand),
        started_at, tool_version, host, run_login.

        Result columns: finished_at; outcome -- "ok" (listed completely),
        "partial" (stopped early when the window closed; the rest is done
        later), "failed" (a folder could not be listed or the run broke
        off; nothing was concluded from what was absent) or "unreachable"
        (the directory was missing or empty); files_listed,
        files_unchanged, files_pending, files_registered, files_known,
        files_held, files_ignored, files_cleared and groups_registered /
        groups_waiting / groups_held (counts for this run), bytes_read,
        message and details (a JSON object).

        outcome must be "ok", "partial", "failed" or "unreachable";
        command "run" or "apply" (anything else is an error). started_from
        (inclusive) and started_before (exclusive) bound started_at, each
        an ISO-8601 date or timestamp; a value without a UTC offset is read
        in the database session's time zone. A filter left out (or null) is
        not applied (outcome cannot be used to find runs without a result:
        page through and look for outcome null).

        Returns {"row_count", "limit", "truncated", "next_cursor", "rows"};
        when `truncated` is true call again with the same arguments and
        cursor=<next_cursor> (`limit`, max 1000, caps each page).
        """
        _one_of(outcome, SCAN_OUTCOMES, "outcome")
        _one_of(command, SCAN_COMMANDS, "command")
        order = db.ORDER_BY_SCAN_RUN
        clauses, params = [], []
        for column, value in (("scan_directory_id", scan_directory_id),
                              ("outcome", outcome), ("command", command)):
            if value is not None:
                clauses.append(f"{column} = %s")
                params.append(value)
        if started_from is not None:
            clauses.append("started_at >= %s::timestamptz")
            params.append(started_from)
        if started_before is not None:
            clauses.append("started_at < %s::timestamptz")
            params.append(started_before)
        if cursor is not None:
            clause, keyset_params = db.keyset_clause(order, db.decode_cursor(order, cursor))
            clauses.append(clause)
            params.extend(keyset_params)
        sql = _RUNS_SQL
        if clauses:
            sql += " WHERE " + " AND ".join(clauses)
        sql += f" ORDER BY {order}"
        return db.fetch_limited(sql, params, limit, page_order=order)

    @app.tool()
    def get_scan_files(
        storage_root_id: Optional[int] = None,
        relative_path: OptText = None,
        relative_path_prefix: OptText = None,
        status: OptText = None,
        reason_code: OptText = None,
        scan_run_id: Optional[int] = None,
        group_key: OptText = None,
        latest_per_file: bool = True,
        limit: int = db.DEFAULT_LIMIT,
        cursor: OptText = None,
    ) -> dict:
        """List the scan memory: what the NAS scan last saw of each file and concluded.

        By default (latest_per_file=True) one row per file, its current
        state (lab.scan_file_latest: the latest row per storage root and
        path). With latest_per_file=False the whole append-only log
        (lab.scan_file): a row is added only when what the scan sees of a
        file changes, so a file has a few rows however often it is
        searched. Newest first by scan_file_id.

        status is one of: "pending" (seen, waiting to be seen unchanged
        for the directory's min_age_min before it is registered);
        "registered" (the scan registered it; artifact_id names the row);
        "known" (another client had already registered these bytes at this
        path, confirmed by reading them; artifact_id names the row);
        "held" (not registered; reason_code and reason say why -- the
        unattended search never registers a held file. Some holds end by
        themselves when their cause goes, e.g. the subject's row is added
        or the recording is registered; the rest need a person); "cleared"
        (a pending or held file is no longer there). Anything else is an
        error. A directory in "report" mode registers nothing: its rows
        are pending, held and cleared, and a registered or known row only
        where a person corrected an artifact that was already registered
        and the memory follows it.

        Columns: scan_file_id, scan_run_id (the run that wrote the row, see
        get_scan_runs), storage_root_id, relative_path, size_bytes,
        mtime_ns (modification time as whole nanoseconds since 1970),
        group_key (the session's files it belongs to), status, reason_code,
        reason, artifact_id.

        Files are identified by storage_root_id (see get_storage_roots) plus
        relative_path, matched as get_artifacts matches them: exactly, case
        included, after backslashes become forward slashes and surrounding
        whitespace is removed. relative_path_prefix lists everything under
        a folder ("G-0421/sess01/"), normalised the same way and matched
        literally ("_" and "%" are ordinary characters, not wildcards).
        reason_code, group_key are matched exactly. A filter left out (or
        null) is not applied.

        Returns {"row_count", "limit", "truncated", "next_cursor", "rows"};
        when `truncated` is true call again with the same arguments and
        cursor=<next_cursor> (`limit`, max 1000, caps each page).
        """
        _one_of(status, SCAN_STATUSES, "status")
        relative_path = _path(relative_path, "relative_path")
        relative_path_prefix = _path(relative_path_prefix, "relative_path_prefix")
        table = "lab.scan_file_latest" if latest_per_file else "lab.scan_file"
        return db.select_from(table, {
            "storage_root_id": storage_root_id, "relative_path": relative_path,
            "status": status, "reason_code": reason_code,
            "scan_run_id": scan_run_id, "group_key": group_key,
        }, limit=limit, order_by=db.ORDER_BY_SCAN_FILE,
            prefix_filters={"relative_path": relative_path_prefix},
            paged=True, cursor=cursor)
