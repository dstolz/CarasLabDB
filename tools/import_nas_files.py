#!/usr/bin/env python3
"""Search the listed NAS directories for new files and register them.

The directories are the rows of lab.scan_directory (kept by the
administrator; design_docs/schema.sql). For each file under a real subject
folder the tool registers a session, the recording or behavior event that
produced it and one lab.artifact row with its SHA-256. Registration is
permanent, so anything uncertain is held and reported, never guessed, and an
unattended run only ever adds: it never supersedes, retracts or records a
disposition.

    python tools/import_nas_files.py run --root nas-rig3=S:\\RIG3_Backup_2025 \\
        --report-dir C:\\caraslabdb\\reports --cache-file C:\\caraslabdb\\headers.json \\
        --log-file C:\\caraslabdb\\import.log
    python tools/import_nas_files.py check --root nas-rig3=S:\\RIG3_Backup_2025

Commands
--------
``run``    The unattended search. Reads the directories that are due
           (``lab.fn_scan_due()``, the one longest due first), and for each:
           takes its lock (a directory another process is searching is
           skipped), lists it and the directory it is paired with completely,
           remembers what it saw in lab.scan_file, and -- in mode
           ``register`` -- registers every group of files that a complete
           listing at least ``min_age_min`` earlier showed exactly as this one
           does (nas_import/engine.py states the rule). The wait is counted
           from the START of the earlier run; its listing ended at most a
           listing's duration later. Mode ``report`` does everything but
           read files to their end and register.
``check``  Searches nothing and writes nothing. Exit 1 when a directory is
           overdue, when two listed directories overlap, when more than one
           directory that is not ``off`` pairs with the same one (none of them
           can be searched), or when a directory
           that is due lies on a storage root not given with ``--root`` (this
           third test is skipped, and said to be, when no ``--root`` is
           given). Prints the pending and held files of each directory, and
           how many groups wait for a recording whose directory is not in
           ``register`` mode (said, not a problem).
           Schedule it and alert on it, as ``backup_lab.py --check``.
``scan``   The reviewed path, first half. Reads the named directories (in any
           mode, each with the directory it is paired with) and the database
           and writes NOTHING to the NAS, the database or the cache file.
           Into ``--out`` it writes a plan (JSON lines; nas_import/reviewed.py
           documents it), a CSV and a text report: per group what would be
           done -- register, add files, correct an event, record a file as
           replaced, move a behavior session into its recording's session,
           attach a copy -- with the SHA-256 of every file that would be
           written, and everything that stays held for a person. Exit 1 when
           a named directory could not be listed completely (nothing is
           planned for it).
``apply``  The second half: writes exactly a plan that a person has read.
           Refused outright (exit 2, nothing written): a plan that was edited
           or truncated, of another plan format, made against another
           database, or naming a storage root not given. The directory and
           its partner are listed and interpreted again (headers only); an
           incomplete listing refuses all of the directory's groups. A group
           is refused, the others proceed, unless it is as the scan found it
           (files, sizes, modification times, subject, session, time, detail,
           pairing), the plan's listing is at least the directory's current
           ``min_age_min`` old, and the database is as the scan found it. The
           files are not read to their end again (``--reread`` does): the
           verification rows carry the time of the scan's read. One transaction per group,
           with its memory rows, so the next ``run`` finds nothing to do for
           it. ``--only GROUP_KEY`` (repeatable) applies only those groups;
           ``--dry-run`` makes every check and writes nothing. Exit 0 when
           every group the plan acts on (all of them, or those named) was
           applied; 1 when any was refused; groups the plan holds or lets
           wait are never applied and do not count.

Options of ``run``
------------------
--root NAME=PATH   where storage root NAME (lab.storage_root.name) is mounted;
                   repeatable. Refused: an unknown root, a path that is
                   missing or empty (an unmounted share), two paths one inside
                   the other, and a root whose ``.caraslabdb-root.json`` names
                   another root. A due directory whose root was not given is
                   skipped and counted.
                   Give each root its ``.caraslabdb-root.json`` marker (a JSON
                   object with the root's ``name``), so that one folder cannot
                   be searched under two root names.
--directory ID     only this scan_directory_id; repeatable.
--now              search the named directories (or all that are not ``off``)
                   whether due or not. Such a run is made by hand: it records
                   no ``due_at``, never moves the schedule, and does not ask
                   whether the directory's window is open.
--overrides FILE   the reviewed overrides CSV (root, relative_path,
                   subject_id or ``skip``, reason). A malformed file is
                   refused before anything is written.
--cache-file FILE  file headers of registered files, so that they are not
                   opened again. An optimisation only.
--report-dir DIR   one CSV and one text file per directory run in which
                   something happened (nas_import/report.py documents them).
--log-file FILE    append one line per process run (OK or ERROR).
--dry-run          write nothing to the database, the cache or a report; read
                   no file to its end; print what would be done.

``scan`` takes ``--root``, ``--directory ID`` (required, repeatable), ``--out
DIR`` (required), ``--overrides`` and ``--cache-file`` (read, never written).
``apply PLANFILE`` takes ``--root``, ``--only GROUP_KEY``, ``--dry-run``,
``--reread`` (read every file written again and require the plan's SHA-256),
``--cache-file`` (read, never written), ``--report-dir`` (a CSV and a text
file per directory applied to) and ``--log-file``.

Connection settings come from the standard libpq environment variables
(PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD or the password file). The
login must inherit ``lab_rw`` and hold INSERT on lab.scan_run,
lab.scan_run_result and lab.scan_file (the ``lab_scanner`` login of
design_docs/grants.sql), or be the schema's owner. Needs psycopg (v3):
``pip install "psycopg[binary]"``. Nothing on the NAS is ever written,
renamed or deleted.

Exit status of ``run``: 0 when every directory searched ended ``ok`` or
``partial``; 1 when any ended ``failed`` or ``unreachable``, or a report could
not be written to ``--report-dir`` (the run's rows stand, and the other
directories are searched; a cache file that cannot be written is only a
warning); 2 on a usage or
connection error, which includes a login that may not write the scan logs
(nothing was searched). Skipped directories do not change it. Of ``check``:
0 when there is nothing to report, 1 otherwise. Of ``scan``: 0 when a plan
was written for every named directory, 1 when one could not be listed. Of
``apply``: 0 when every group the plan acts on was applied, 1 when any was
refused, 2 (nothing written) for a plan that cannot be trusted. Every
command exits 2 on a usage or connection error; ``--help`` of each says so.
"""

import argparse
import json
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from nas_import import engine, report, reviewed, subjects, walk  # noqa: E402
from nas_import.cache import HeaderCache  # noqa: E402
from nas_import.database import ConnectionLost, Database  # noqa: E402

PROG = "import_nas_files"


class Usage(Exception):
    """A usage or connection error: message on stderr, exit status 2."""


def parse_roots(pairs):
    """{'nas-rig3': path, ...}; refuses what tools/verify_artifacts.py refuses, and more."""
    roots = {}
    for pair in pairs:
        name, sep, path = pair.partition("=")
        if not sep or not name or not path:
            raise Usage("--root expects NAME=PATH, got %r" % pair)
        if name in roots:
            raise Usage("storage root %r given twice" % name)
        if not os.path.isdir(path):
            raise Usage("storage root %r: %s is not a directory (is the share mounted?)"
                        % (name, path))
        with os.scandir(path) as entries:
            if next(entries, None) is None:
                raise Usage("storage root %r: %s is empty (is the share mounted?)" % (name, path))
        roots[name] = path
    real = {name: os.path.normcase(os.path.realpath(path)) for name, path in roots.items()}
    names = sorted(real)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if os.path.commonpath([real[a], real[b]]) in (real[a], real[b]):
                raise Usage("storage roots %r (%s) and %r (%s) contain each other"
                            % (a, roots[a], b, roots[b]))
    for name, path in roots.items():
        marker = os.path.join(path, walk.MARKER_NAME)
        if not os.path.lexists(marker):
            continue
        try:
            with open(marker, encoding="utf-8") as fh:
                said = json.load(fh)["name"]
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise Usage("storage root %r: the marker %s cannot be read (%s)"
                        % (name, marker, exc)) from None
        if said != name:
            raise Usage("storage root %r: %s is storage root %r (its %s says so); check the "
                        "mount" % (name, path, said, walk.MARKER_NAME))
    return roots


def connect(roots):
    db = Database(PROG)
    try:
        db.connect()
    except ImportError:
        raise Usage('needs psycopg (v3): pip install "psycopg[binary]"') from None
    except Exception as exc:                 # driver-specific connection errors
        raise Usage("cannot connect to the database: %s" % str(exc).strip()) from None
    try:
        known = db.storage_roots()
    except Exception as exc:
        raise Usage("cannot read lab.storage_root: %s" % str(exc).strip()) from None
    unknown = sorted(set(roots) - set(known))
    if unknown:
        raise Usage("no such storage root in lab.storage_root: %s (known: %s)"
                    % (", ".join(unknown), ", ".join(sorted(known)) or "none"))
    return db


def cmd_run(args):
    if not args.root:
        raise Usage("give at least one --root NAME=PATH")
    roots = parse_roots(args.root)
    overrides = ()
    if args.overrides:
        try:
            overrides = subjects.read_overrides(args.overrides)
        except (subjects.OverrideError, OSError, UnicodeError) as exc:
            raise Usage("--overrides %s: %s" % (args.overrides, exc)) from None
    db = connect(roots)
    if not args.dry_run:
        lacking = db.missing_log_privileges()
        if lacking:
            raise Usage("the login %s may not INSERT into %s: nothing was searched. Run as the "
                        "scanner login (in lab_rw, with INSERT on lab.scan_run, "
                        "lab.scan_run_result and lab.scan_file; design_docs/grants.sql) or as "
                        "the schema's owner." % (db.login(), ", ".join(lacking)))
    every = {d.id: d for d in db.directories()}
    for wanted in args.directory:
        if wanted not in every:
            raise Usage("no scan directory %d in lab.scan_directory" % wanted)
    if args.now:
        chosen = args.directory or [d.id for d in every.values() if d.mode != "off"]
        for wanted in chosen:
            if every[wanted].mode == "off":
                raise Usage("scan directory %s is off" % every[wanted].name)
        todo = [(i, None) for i in chosen]
    else:
        todo = [(i, due) for i, due in db.due() if not args.directory or i in args.directory]

    options = engine.RunOptions(overrides=overrides, cache_path=args.cache_file,
                                dry_run=args.dry_run, ignore_window=args.now,
                                host=socket.gethostname())
    results = []
    unwritten = []                  # reports that could not be written
    skipped = {"locked": 0, "root not given": 0, "no longer due": 0}
    lost = None
    for directory_id, due_at in todo:
        directory = every[directory_id]
        if directory.root not in roots:
            skipped["root not given"] += 1
            print("directory %s: skipped, storage root %s was not given with --root"
                  % (directory.name, directory.root))
            continue
        try:
            if not db.lock(directory_id):
                skipped["locked"] += 1
                print("directory %s: skipped, another process is searching it" % directory.name)
                continue
            try:
                if not args.now:
                    due_at = db.still_due(directory_id)
                    if due_at is None:
                        skipped["no longer due"] += 1
                        print("directory %s: skipped, no longer due" % directory.name)
                        continue
                res = engine.run_directory(db, db.directory(directory_id), roots[directory.root],
                                           due_at, options)
            finally:
                if not db.lost():
                    db.unlock(directory_id)
        except Exception as exc:             # the connection: try once more, else stop
            if not db.lost(exc):
                raise
            if not db.reconnect():
                lost = str(exc).strip()
                break
            print("directory %s: the database connection was lost (%s); not searched"
                  % (directory.name, str(exc).strip()), file=sys.stderr)
            continue
        results.append(res)
        if args.dry_run:
            print(report.text_of(res))
        else:
            print(report.summary(res))
            if res.happened and args.report_dir:
                try:
                    print("  report: %s" % report.write(args.report_dir, res)[1])
                except OSError as exc:      # the run's rows stand; the next directory is searched
                    unwritten.append("the report of directory %s could not be written to %s: %s"
                                     % (directory.name, args.report_dir, exc))
                    print("directory %s: %s" % (directory.name, unwritten[-1]), file=sys.stderr)
        if db.lost():
            if not db.reconnect():
                lost = "the database connection was lost"
                break
    db.close()

    outcomes = [r.outcome for r in results]
    bad = [o for o in outcomes if o in ("failed", "unreachable")]
    text = "run%s: %d of %d searched (%s)" % (
        " (dry run)" if args.dry_run else "", len(results), len(todo),
        ", ".join("%d %s" % (outcomes.count(o), o) for o in ("ok", "partial", "failed",
                                                             "unreachable") if o in outcomes)
        or "none")
    if any(skipped.values()):
        text += "; skipped: " + ", ".join("%d %s" % (n, why) for why, n in skipped.items() if n)
    text += "; registered %d file(s) in %d group(s), %d known, %d pending, %d held, %d cleared" % (
        sum(r.counters.get("files_registered", 0) for r in results),
        sum(r.counters.get("groups_registered", 0) for r in results),
        sum(r.counters.get("files_known", 0) for r in results),
        sum(r.counters.get("files_pending", 0) for r in results),
        sum(r.counters.get("files_held", 0) for r in results),
        sum(r.counters.get("files_cleared", 0) for r in results))
    if lost is not None:
        raise Usage("%s; stopped: the database connection was lost (%s)" % (text, lost))
    for r in results:
        if r.outcome in ("failed", "unreachable"):
            text += "; %s %s: %s" % (r.directory.name, r.outcome, r.message)
        for warning in r.warnings:
            text += "; %s: warning: %s" % (r.directory.name, warning)
    for problem in unwritten:
        text += "; " + problem
    if bad or unwritten:
        print("%s: ERROR: %s" % (PROG, text), file=sys.stderr)
        report.log_line(args.log_file, "ERROR %s" % text)
        return 1
    print("%s: OK: %s" % (PROG, text))
    report.log_line(args.log_file, "OK %s" % text)
    return 0


def cmd_check(args):
    roots = parse_roots(args.root)
    db = connect(roots)
    try:
        rows = db.status()
        overlaps = db.overlaps()
        every = db.directories()
        waiting = db.waiting_for_recordings(engine.PAIRS_WITH + "recording:")
    except Exception as exc:
        raise Usage("cannot read the schedule: %s" % str(exc).strip()) from None
    db.close()
    names = {d.id: d.name for d in every}
    problems = []
    for r in rows:
        if r["mode"] == "off":
            continue
        name = "%d %s:%s" % (r["scan_directory_id"], r["storage_root"], r["relative_path"])
        print("directory %s (%s): %d pending, %d held file(s)%s"
              % (name, r["mode"], r["n_pending"], r["n_held"],
                 "; last run " + r["last_run_outcome"] if r["last_run_outcome"] else ""))
        if r["is_overdue"]:
            problems.append("directory %s is overdue: no search has succeeded for more than one "
                            "interval plus 26 hours after one was due" % name)
        if roots and r["is_due"] and r["storage_root"] not in roots:
            problems.append("directory %s is due, and its storage root %s was not given with "
                            "--root" % (name, r["storage_root"]))
    for subject, detail in overlaps:
        problems.append("scan directories overlap (scan directory %s): %s" % (subject, detail))
    problems += engine.pairing_problems(every)
    for epsych, recordings, mode, n in waiting:     # said, not a problem: the exit stays
        print("directory %s: %d group(s) wait for a recording of directory %s, which is %s: "
              "they are not registered until it is in register mode (or by scan / apply)"
              % (names[epsych], n, names[recordings], "off" if mode == "off" else
                 "in %s mode" % mode))
    if not roots:
        print("no --root given: not checked whether the due directories' storage roots are "
              "mounted here")
    for p in problems:
        print("PROBLEM %s" % p)
    held = sum(r["n_held"] for r in rows if r["mode"] != "off")
    pending = sum(r["n_pending"] for r in rows if r["mode"] != "off")
    if problems:
        text = "check: %d problem(s): %s" % (len(problems), "; ".join(problems))
        print("%s: ERROR: check: %d problem(s); %d held, %d pending file(s)"
              % (PROG, len(problems), held, pending), file=sys.stderr)
        report.log_line(args.log_file, "ERROR %s" % text)
        return 1
    text = "check: no directory overdue or overlapping; %d held, %d pending file(s)" % (held,
                                                                                         pending)
    print("%s: OK: %s" % (PROG, text))
    report.log_line(args.log_file, "OK %s" % text)
    return 0


def cmd_scan(args):
    if not args.root:
        raise Usage("give at least one --root NAME=PATH")
    if not args.directory:
        raise Usage("scan: name the directories with --directory ID")
    roots = parse_roots(args.root)
    overrides, overrides_digest = (), None
    if args.overrides:
        try:
            overrides = subjects.read_overrides(args.overrides)
            overrides_digest = reviewed.file_digest(args.overrides)
        except (subjects.OverrideError, OSError, UnicodeError) as exc:
            raise Usage("--overrides %s: %s" % (args.overrides, exc)) from None
    db = connect(roots)
    every = {d.id: d for d in db.directories()}
    for wanted in args.directory:
        if wanted not in every:
            raise Usage("no scan directory %d in lab.scan_directory" % wanted)
        if every[wanted].root not in roots:
            raise Usage("scan directory %s: its storage root was not given with --root"
                        % every[wanted].name)
    cache = HeaderCache.load(args.cache_file) if args.cache_file else None   # read, never written
    stamp = engine.us_text(db.now_us()).replace("-", "").replace(":", "")
    records = [{"type": "plan", "format": reviewed.FORMAT, "tool": PROG}]
    if args.overrides:
        records.append({"type": "overrides", "rows": [
            [o.root, o.path, o.subject_id, o.skip, o.reason, o.line] for o in overrides]})
    planned = {}
    try:
        for d in reviewed.scan_order([every[i] for i in sorted(set(args.directory))]):
            records += reviewed.scan_directory(db, d, roots[d.root], overrides, cache, planned)
        text = reviewed.plan_text(records, engine.VERSION, db.identity(), overrides_digest)
    except Exception as exc:
        if db.lost(exc):
            raise Usage("the database connection was lost: %s" % str(exc).strip()) from None
        raise
    db.close()
    os.makedirs(args.out, exist_ok=True)
    stem = os.path.join(args.out, "plan_%s" % stamp)
    table, summary = reviewed.scan_report(records)
    for suffix, content in ((".jsonl", text), (".csv", table), (".txt", summary)):
        try:            # "x": a plan of the same second is never overwritten
            with open(stem + suffix, "x", encoding="utf-8", newline="") as fh:
                fh.write(content)
        except FileExistsError:
            raise Usage("%s exists already: nothing was overwritten; scan again"
                        % (stem + suffix)) from None
    print(summary)
    print("plan: %s.jsonl" % stem)
    failed = [r for r in records if r["type"] == "failed"]
    for r in failed:
        print("%s: ERROR: directory %d could not be scanned: %s" % (PROG, r["directory"],
                                                                    r["reason"]), file=sys.stderr)
    return 1 if failed else 0


def cmd_apply(args):
    try:
        plan = reviewed.PlanFile(args.plan)
    except reviewed.PlanError as exc:
        raise Usage(str(exc)) from None
    roots = parse_roots(args.root)
    missing = sorted({r["root"] for r in plan.directories} - set(roots))
    if missing:
        raise Usage("the plan names storage root(s) %s, not given with --root"
                    % ", ".join(missing))
    keys = {g["key"]: g for g in plan.groups}
    for key in args.only:
        if key not in keys:
            raise Usage("--only %s: the plan has no such group" % key)
        if keys[key]["action"] not in reviewed.ACTIONS:
            raise Usage("--only %s: the plan does not act on this group (%s)"
                        % (key, keys[key]["action"]))
    db = connect(roots)
    here = db.identity()
    if here != plan.end["database"]:
        raise Usage("the plan was made against database %s; this is %s. Scan this database."
                    % (plan.end["database"], here))
    if not args.dry_run:
        lacking = db.missing_log_privileges()
        if lacking:
            raise Usage("the login %s may not INSERT into %s: nothing was applied."
                        % (db.login(), ", ".join(lacking)))
    cache = HeaderCache.load(args.cache_file) if args.cache_file else None   # read, never written
    applied, refused, notes, unwritten = [], [], [], []
    dry_sessions = set()            # the sessions a dry run would have made so far
    host = socket.gethostname()
    for record in plan.directories:
        mine = [g for g in plan.groups if g["directory"] == record["id"]
                and g["action"] in reviewed.ACTIONS and (not args.only or g["key"] in args.only)]
        if not mine:
            continue
        try:
            if not db.lock(record["id"]):
                refused += [(g["key"], "the directory is being searched by another process")
                            for g in mine]
                continue
            try:
                out = reviewed.apply_directory(db, plan, record, roots[record["root"]],
                                               set(args.only), args.dry_run, engine.VERSION, host,
                                               dry_sessions, cache, args.reread)
            finally:
                if not db.lost():
                    db.unlock(record["id"])
        except Exception as exc:
            if isinstance(exc, ConnectionLost) or db.lost(exc):
                raise Usage("the database connection was lost while the plan was applied: %s. "
                            "Groups already applied stay applied; scan again for the rest."
                            % str(exc).strip()) from None
            raise
        applied += out["applied"]
        refused += out["refused"]
        notes += out["notes"]
        if args.report_dir and out["run_id"] is not None:
            try:
                print("report: %s" % reviewed.write_apply_report(args.report_dir, plan, out))
            except OSError as exc:          # what was applied stands
                unwritten.append("the report of directory %d could not be written to %s: %s"
                                 % (record["id"], args.report_dir, exc))
                print(unwritten[-1], file=sys.stderr)
    db.close()
    verb = "would be applied" if args.dry_run else "applied"
    for key in applied:
        print("%s  %s (%s)" % (verb, key, keys[key]["action"]))
    for key, why in refused:
        print("REFUSED  %s (%s): %s" % (key, keys[key]["action"], why))
    for note in notes:
        print("NOTE  %s" % note)
    skipped = sum(1 for g in plan.groups if g["action"] in ("held", "wait"))
    print(reviewed.REREAD if args.reread else reviewed.NOT_READ)
    if skipped:
        print("%d group(s) are held or waiting in the plan and were not touched." % skipped)
    text = "apply%s %s: %d group(s) %s, %d refused" % (
        " (dry run)" if args.dry_run else "", os.path.basename(args.plan), len(applied), verb,
        len(refused))
    if refused or unwritten:
        text += ": " + "; ".join(["%s: %s" % (k, why) for k, why in refused[:5]] + unwritten)
        print("%s: ERROR: %s" % (PROG, text), file=sys.stderr)
        report.log_line(args.log_file, "ERROR %s" % text)
        return 1
    print("%s: OK: %s" % (PROG, text))
    report.log_line(args.log_file, "OK %s" % text)
    return 0


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):      # a path the console cannot show is escaped
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")
    parser = argparse.ArgumentParser(
        prog=PROG, description="Search the listed NAS directories and register new files.",
        epilog="See the module docstring (top of this file) for details. Connection settings "
               "come from the PG* environment variables.")
    sub = parser.add_subparsers(dest="command", metavar="COMMAND")
    sub.required = True
    root_help = "where storage root NAME (lab.storage_root.name) is mounted; repeatable"

    run = sub.add_parser(
        "run", help="search the directories that are due (unattended)",
        description="Search the directories that are due and register what a complete listing "
                    "at least min_age_min earlier showed unchanged. The wait is counted from "
                    "the START of the earlier run (its listing ended at most a listing's "
                    "duration later). Give each storage root its .caraslabdb-root.json marker "
                    "(a JSON object with the root's name), so that one folder cannot be "
                    "searched under two root names.",
        epilog="Exit status: 0 when every directory searched ended ok or partial (skipped "
               "directories do not count; a cache file that cannot be written is a warning); 1 "
               "when any ended failed or unreachable, or a report could not be written (the "
               "run's rows stand and the other directories are searched); 2 on a usage or "
               "connection error, or a login that may not write the scan logs.")
    run.add_argument("--root", action="append", default=[], metavar="NAME=PATH", help=root_help)
    run.add_argument("--directory", action="append", default=[], type=int, metavar="ID",
                     help="only this scan_directory_id; repeatable")
    run.add_argument("--now", action="store_true",
                     help="search the named directories (or all not off) whether due or not")
    run.add_argument("--overrides", metavar="FILE", help="the reviewed overrides CSV")
    run.add_argument("--cache-file", metavar="FILE",
                     help="file headers of registered files (an optimisation only)")
    run.add_argument("--report-dir", metavar="DIR",
                     help="write a CSV and a text report per directory run in which something "
                          "happened")
    run.add_argument("--log-file", metavar="FILE",
                     help="append one line per run (OK or ERROR) to FILE")
    run.add_argument("--dry-run", action="store_true",
                     help="write nothing; print what would be done")
    run.set_defaults(func=cmd_run)

    check = sub.add_parser(
        "check", help="exit 1 when a directory is overdue (searches nothing)",
        description="Search nothing and write nothing: say whether the scheduled searches are "
                    "being made, and how many files are pending and held.",
        epilog="Exit status: 0 when no directory is overdue, none overlap, no directory is "
               "named by more than one that is not off as its pair_with, and (with --root) "
               "every due directory's storage root was given; 1 otherwise; 2 on a usage or "
               "connection error. Groups that wait for a recording whose directory is not in "
               "register mode are counted and do not change it.")
    check.add_argument("--root", action="append", default=[], metavar="NAME=PATH", help=root_help)
    check.add_argument("--log-file", metavar="FILE",
                       help="append one line per run (OK or ERROR) to FILE")
    check.set_defaults(func=cmd_check)

    scan = sub.add_parser(
        "scan", help="write a plan for review; writes nothing to the NAS or the database",
        description="Read the named directories (in any mode) and the database, and write a "
                    "plan file (JSON lines), a CSV and a text report into --out. Nothing is "
                    "written to the NAS, the database or the cache file.",
        epilog="Exit status: 0 when a plan was written for every named directory; 1 when a "
               "named directory could not be listed completely (the plan says so and plans "
               "nothing for it); 2 on a usage or connection error.")
    scan.add_argument("--root", action="append", default=[], metavar="NAME=PATH", help=root_help)
    scan.add_argument("--directory", action="append", default=[], type=int, metavar="ID",
                      help="a scan_directory_id to scan; required, repeatable. Name a directory "
                           "and the "
                           "one it is paired with together")
    scan.add_argument("--out", required=True, metavar="DIR", help="where the plan is written")
    scan.add_argument("--overrides", metavar="FILE", help="the reviewed overrides CSV")
    scan.add_argument("--cache-file", metavar="FILE",
                      help="file headers of registered files; read, never written by scan")
    scan.set_defaults(func=cmd_scan)

    apply = sub.add_parser(
        "apply", help="write exactly a reviewed plan",
        description="Carry out the plan a scan wrote. The directory and its partner are listed "
                    "completely again and interpreted again (file headers only; nothing is "
                    "hashed), with the overrides the plan carries; a listing that cannot be made "
                    "completely refuses every group of the directory. A group is refused, and "
                    "nothing written for it, unless it is as the scan found it (the same files "
                    "with the same sizes and modification times, the same subject, session, "
                    "time, detail and pairing), the plan's listing is at least the directory's "
                    "min_age_min old, and the database is as the scan found it. The files are "
                    "not read to their end again unless --reread is given. "
                    "What the plan's digest protects: its last line carries a SHA-256 over every "
                    "line, so a plan that was edited by accident or truncated is refused. It is "
                    "a plain SHA-256 with no key: whoever can write the plan can also compute a "
                    "new digest, and apply then takes every value from the plan -- the SHA-256 of "
                    "each file among them -- unless --reread reads the files again. Keep plans "
                    "where only the people who review them can write. The plan names the "
                    "database it was made against by its name, oid and the cluster's system "
                    "identifier; these do not tell a physical clone of the cluster (a restored "
                    "base backup, a promoted standby) from the original.",
        epilog="Exit status: 0 when every group the plan acts on (all, or those named with "
               "--only) was applied; 1 when any was refused, also because another process "
               "holds its directory's lock; 2, with nothing written, for a plan that was "
               "edited or truncated, has another plan format, was made against another "
               "database or names a storage root not given, and on a usage or connection "
               "error. Groups the plan holds or lets wait are never applied and do not count.")
    apply.add_argument("plan", metavar="PLANFILE")
    apply.add_argument("--root", action="append", default=[], metavar="NAME=PATH", help=root_help)
    apply.add_argument("--only", action="append", default=[], metavar="GROUP_KEY",
                       help="apply only this group of the plan; repeatable")
    apply.add_argument("--dry-run", action="store_true",
                       help="make every check and write nothing")
    apply.add_argument("--reread", action="store_true",
                       help="read every file an action writes to its end again (and check each "
                            ".mat file of an ePsych session structurally) and refuse the group "
                            "unless it has the plan's SHA-256; off by default")
    apply.add_argument("--cache-file", metavar="FILE",
                       help="file headers of registered files, for the listing made again; read, "
                            "never written by apply")
    apply.add_argument("--report-dir", metavar="DIR",
                       help="write a CSV and a text report per directory applied to: what was "
                            "applied, what was refused and why, the notes")
    apply.add_argument("--log-file", metavar="FILE",
                       help="append one line per run (OK or ERROR) to FILE")
    apply.set_defaults(func=cmd_apply)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Usage as failure:
        print("%s: %s" % (PROG, failure), file=sys.stderr)
        if getattr(args, "log_file", None):
            try:
                report.log_line(args.log_file, "ERROR %s" % failure)
            except OSError:
                pass
        return 2


if __name__ == "__main__":
    sys.exit(main())
