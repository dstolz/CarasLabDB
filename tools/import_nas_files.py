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
           does (nas_import/engine.py states the rule). Mode ``report`` does
           everything but read files to their end and register.
``check``  Searches nothing and writes nothing. Exit 1 when a directory is
           overdue, when two listed directories overlap, or when a directory
           that is due lies on a storage root not given with ``--root`` (this
           third test is skipped, and said to be, when no ``--root`` is
           given). Prints the pending and held files of each directory.
           Schedule it and alert on it, as ``backup_lab.py --check``.
``scan``, ``apply``  The reviewed path; not implemented yet.

Options of ``run``
------------------
--root NAME=PATH   where storage root NAME (lab.storage_root.name) is mounted;
                   repeatable. Refused: an unknown root, a path that is
                   missing or empty (an unmounted share), two paths one inside
                   the other, and a root whose ``.caraslabdb-root.json`` names
                   another root. A due directory whose root was not given is
                   skipped and counted.
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

Connection settings come from the standard libpq environment variables
(PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD or the password file). The
login must inherit ``lab_rw`` and hold INSERT on lab.scan_run,
lab.scan_run_result and lab.scan_file (the ``lab_scanner`` login of
design_docs/grants.sql), or be the schema's owner. Needs psycopg (v3):
``pip install "psycopg[binary]"``. Nothing on the NAS is ever written,
renamed or deleted.

Exit status of ``run``: 0 when every directory searched ended ``ok`` or
``partial``; 1 when any ended ``failed`` or ``unreachable``; 2 on a usage or
connection error, which includes a login that may not write the scan logs
(nothing was searched). Skipped directories do not change it.
"""

import argparse
import json
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from nas_import import engine, report, subjects, walk  # noqa: E402
from nas_import.database import Database  # noqa: E402

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
                print("  report: %s" % report.write(args.report_dir, res)[1])
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
    if bad:
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
    except Exception as exc:
        raise Usage("cannot read the schedule: %s" % str(exc).strip()) from None
    db.close()
    problems = []
    for r in rows:
        if r["mode"] == "off":
            continue
        name = "%d %s:%s" % (r["scan_directory_id"], r["storage_root"], r["relative_path"])
        print("directory %s (%s): %d pending, %d held file(s)%s"
              % (name, r["mode"], r["n_pending"], r["n_held"],
                 "; last run " + r["last_run_outcome"] if r["last_run_outcome"] else ""))
        if r["is_overdue"]:
            problems.append("directory %s is overdue: no search has succeeded for more than its "
                            "interval plus 26 hours" % name)
        if roots and r["is_due"] and r["storage_root"] not in roots:
            problems.append("directory %s is due, and its storage root %s was not given with "
                            "--root" % (name, r["storage_root"]))
    for subject, detail in overlaps:
        problems.append("scan directories overlap (scan directory %s): %s" % (subject, detail))
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


def cmd_not_yet(args):
    raise Usage("%s is not implemented yet (the reviewed path follows); use run" % args.command)


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

    run = sub.add_parser("run", help="search the directories that are due (unattended)")
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

    check = sub.add_parser("check", help="exit 1 when a directory is overdue (searches nothing)")
    check.add_argument("--root", action="append", default=[], metavar="NAME=PATH", help=root_help)
    check.add_argument("--log-file", metavar="FILE",
                       help="append one line per run (OK or ERROR) to FILE")
    check.set_defaults(func=cmd_check)

    for name, text in (("scan", "write a plan file for review (not implemented yet)"),
                       ("apply", "write a reviewed plan (not implemented yet)")):
        sub.add_parser(name, help=text, add_help=False).set_defaults(func=cmd_not_yet)

    args, extra = parser.parse_known_args(argv)
    if extra and args.func is not cmd_not_yet:
        parser.error("unrecognized arguments: %s" % " ".join(extra))
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
