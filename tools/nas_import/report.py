"""The importer's reports: one CSV and one text file per directory run, and the log line.

A report is written for a run in which something happened: a file seen for
the first time or changed (``pending``), a registration, a hold that began,
changed or ended, a file ``cleared``, a registered file that is missing, a
group that would be a correction, or an error -- and for a failed or
unreachable run unless the run before it failed in the same way. Both files
are named ``<run start, UTC>_dir<scan_directory_id>_run<scan_run_id>``
(``_dryrun`` for ``--dry-run``), ``.csv`` and ``.txt``.

CSV columns (:data:`COLUMNS`), UTF-8 with a header row:

``what``         ``file``, ``group`` or ``directory``
``action``       file: the memory row written (``pending``, ``held``,
                 ``cleared``, ``registered``, ``known``) or ``missing`` (a
                 registered file that is not in the listing; nothing is
                 recorded). group: ``registered``, ``would_register`` (stable;
                 ``report`` mode or ``--dry-run``), ``waiting``, ``held``,
                 ``would_correct``, ``changed`` (a file changed while it was
                 read) or ``error``. directory: ``failed`` / ``unreachable``
``root``         the storage root's name
``path``         the file's path under the root; a group's folder or base path
``group_key``    the group the file belongs to
``reason_code``  why it is held (``lab.scan_file.reason_code``)
``detail``       the sentence for people
``size_bytes``, ``mtime_ns``  as listed
``artifact_id``  of a ``registered`` or ``known`` file
``event_id``     the event a file was registered under
``until``        for a waiting group: from when it may be registered (UTC)
"""

from __future__ import annotations

import csv
import datetime
import io
import os

COLUMNS = ("what", "action", "root", "path", "group_key", "reason_code", "detail", "size_bytes",
           "mtime_ns", "artifact_id", "event_id", "until")

_GROUP_TITLES = (
    ("registered", "Registered"),
    ("would_register", "Would be registered now"),
    ("waiting", "Waiting"),
    ("held", "Held"),
    ("would_correct", "Held: would be a correction"),
    ("changed", "Changed while read (the wait starts again)"),
    ("error", "Errors"),
)


def csv_text(res) -> str:
    """The CSV of a directory run (``engine.DirectoryResult``)."""
    out = io.StringIO(newline="")
    writer = csv.DictWriter(out, COLUMNS, lineterminator="\n")
    writer.writeheader()
    for line in res.lines:
        writer.writerow(dict(line, root=res.directory.root))
    return out.getvalue()


def summary(res) -> str:
    """One line on a directory run."""
    c = res.counters
    text = "directory %s: %s (%s)" % (res.directory.name, res.outcome, res.mode)
    if res.outcome in ("failed", "unreachable") and not c.get("files_listed"):
        return text + ": " + (res.message or "")
    text += (": %d file(s) listed, %d unchanged; written: %d pending, %d held, %d cleared, "
             "%d registered, %d known; groups: %d registered, %d waiting, %d held; %d byte(s) read"
             % (c.get("files_listed", 0), c.get("files_unchanged", 0), c.get("files_pending", 0),
                c.get("files_held", 0), c.get("files_cleared", 0), c.get("files_registered", 0),
                c.get("files_known", 0), c.get("groups_registered", 0),
                c.get("groups_waiting", 0), c.get("groups_held", 0), c.get("bytes_read", 0)))
    if res.message:
        text += "; " + res.message
    for warning in getattr(res, "warnings", ()):
        text += "; warning: " + warning
    return text


def text_of(res) -> str:
    """The text report of a directory run."""
    out = [summary(res), ""]
    totals = res.details.get("totals")
    if totals:
        out.append("Files now: " + ", ".join("%d %s" % (totals[k], k) for k in
                                             ("registered", "known", "pending", "held",
                                              "reported", "ignored")))
        out.append("")
    groups = [x for x in res.lines if x["what"] == "group"]
    for action, title in _GROUP_TITLES:
        mine = [x for x in groups if x["action"] == action]
        if not mine:
            continue
        out.append("%s (%d group(s))" % (title, len(mine)))
        for x in mine:
            extra = "; ".join(v for v in (x["reason_code"], x["detail"],
                                          "from " + x["until"] if x["until"] else "") if v)
            out.append("  %s%s" % (x["path"], ": " + extra if extra else ""))
        out.append("")
    files = [x for x in res.lines if x["what"] == "file"]
    for action, title in (("pending", "Seen new or changed"), ("held", "Held files"),
                          ("cleared", "No longer there or no longer held"),
                          ("registered", "Registered files"),
                          ("known", "Registered already with the same bytes"),
                          ("missing", "Registered files missing from the listing")):
        mine = [x for x in files if x["action"] == action]
        if not mine:
            continue
        out.append("%s (%d file(s))" % (title, len(mine)))
        for x in mine[:200]:
            extra = "; ".join(v for v in (x["reason_code"], x["detail"]) if v)
            out.append("  %s%s" % (x["path"], ": " + extra if extra else ""))
        if len(mine) > 200:
            out.append("  ... and %d more (see the CSV)" % (len(mine) - 200))
        out.append("")
    for item in res.details.get("unused_overrides", []):
        out.append("Override that matched nothing: %s" % item)
    return "\n".join(out).rstrip("\n") + "\n"


def write(report_dir: str, res) -> tuple[str, str]:
    """Write the CSV and the text report into REPORT_DIR; returns their paths."""
    os.makedirs(report_dir, exist_ok=True)
    stem = "%s_dir%d_%s" % (res.started, res.directory.id,
                            "run%d" % res.run_id if res.run_id is not None else "dryrun")
    paths = (os.path.join(report_dir, stem + ".csv"), os.path.join(report_dir, stem + ".txt"))
    with open(paths[0], "w", encoding="utf-8", newline="") as fh:
        fh.write(csv_text(res))
    with open(paths[1], "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text_of(res))
    return paths


def log_line(path: str | None, text: str) -> None:
    """Append one line (local time, then TEXT) to the log file, as tools/backup_lab.py does."""
    if not path:
        return
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(path, "a", encoding="utf-8") as out:
        out.write("%s %s\n" % (stamp, text))
