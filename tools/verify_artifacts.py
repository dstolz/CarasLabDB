#!/usr/bin/env python3
"""Verify the files behind lab.artifact against their registered checksums.

For every active artifact whose storage root is mounted on this machine, read
the file, compute its checksum with the algorithm the artifact was registered
with, and append one row to lab.artifact_verification:

    ok        the file is there and its checksum matches
    mismatch  the file is there and its checksum differs (the observed
              checksum is recorded)
    missing   there is no file at the registered path

Nothing else is written, and the files are only read. lab.fn_check_integrity()
then reports 'mismatch' and 'missing' as artifact_verification_failed, and
stops reporting verified files as artifact_never_verified. Run it on a
schedule (nightly or weekly) on a machine that mounts the NAS.

Storage roots are named in lab.storage_root; say where each is mounted here:

    python tools/verify_artifacts.py --root nas-main=/mnt/nas-main

    # Windows
    python tools\\verify_artifacts.py --root nas-main=Z:\\

An artifact under a root that was not given is skipped, not reported missing.
A root whose directory does not exist or is empty is refused outright: that
is what an unmounted share looks like, and recording every file on it as
'missing' would bury the report.

Database connection settings come from the standard libpq environment
variables (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD or ~/.pgpass). The
login must be able to INSERT into lab.artifact_verification, i.e. inherit
lab_rw. Needs psycopg (v3) or psycopg2:  pip install "psycopg[binary]"

Exit status: 0 when every file checked is ok, 1 when any is missing or
mismatched, 2 on a usage or connection error. With --dry-run nothing is
written.
"""

import argparse
import hashlib
import os
import sys

CHUNK = 4 * 1024 * 1024

# Latest check of each active artifact's *file* (lab.artifact_verification_latest
# looks across every artifact row describing the same file, so a corrected
# artifact is not treated as never verified). Never-verified files first, then
# the ones checked longest ago.
SELECT_SQL = """
SELECT a.artifact_id::text, r.name, a.relative_path, a.checksum, a.checksum_algo,
       a.size_bytes
FROM lab.artifact_active a
JOIN lab.storage_root r ON r.root_id = a.storage_root_id
LEFT JOIN lab.artifact_verification_latest v ON v.artifact_id = a.artifact_id
WHERE (%(older)s::interval IS NULL
       OR v.verified_at IS NULL
       OR v.verified_at < now() - %(older)s::interval)
ORDER BY v.verified_at ASC NULLS FIRST, a.artifact_id
"""

INSERT_SQL = """
INSERT INTO lab.artifact_verification (artifact_id, status, observed_checksum, verified_by)
VALUES (%s::uuid, %s, %s, %s::uuid)
"""


def die(msg):
    print("verify_artifacts: " + msg, file=sys.stderr)
    sys.exit(2)


def connect():
    try:
        import psycopg
        return psycopg.connect(autocommit=True)
    except ImportError:
        pass
    try:
        import psycopg2
    except ImportError:
        die('needs psycopg or psycopg2: pip install "psycopg[binary]"')
    conn = psycopg2.connect("")
    conn.autocommit = True
    return conn


def parse_roots(pairs):
    """{'nas-main': '/mnt/nas-main', ...}, refusing roots that look unmounted."""
    roots = {}
    for pair in pairs:
        name, sep, path = pair.partition("=")
        if not sep or not name or not path:
            die("--root expects NAME=PATH, got %r" % pair)
        if name in roots:
            die("storage root %r given twice" % name)
        if not os.path.isdir(path):
            die("storage root %r: %s is not a directory (is the share mounted?)" % (name, path))
        with os.scandir(path) as entries:
            if next(entries, None) is None:
                die("storage root %r: %s is empty (is the share mounted?)" % (name, path))
        roots[name] = os.path.realpath(path)
    return roots


def new_hash(algo):
    """A hashlib-style object for a lab.artifact.checksum_algo, or None."""
    if algo in ("sha256", "md5"):
        return hashlib.new(algo)
    if algo == "blake3":
        try:
            import blake3
        except ImportError:
            return None
        return blake3.blake3()
    return None


def checksum_of(path, algo):
    h = new_hash(algo)
    if h is None:
        return None
    with open(path, "rb") as fh:
        while True:
            block = fh.read(CHUNK)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def resolve(root, relative_path):
    """The file's path under ROOT, or None if it would fall outside it."""
    path = os.path.realpath(os.path.join(root, *relative_path.split("/")))
    if path != root and not path.startswith(root.rstrip(os.sep) + os.sep):
        return None
    return path


def main():
    ap = argparse.ArgumentParser(
        description="Verify lab.artifact files against their registered checksums.",
        epilog="Connection settings come from the PG* environment variables.")
    ap.add_argument("--root", action="append", default=[], metavar="NAME=PATH",
                    help="where storage root NAME (lab.storage_root.name) is mounted; repeatable")
    ap.add_argument("--older-than-days", type=float, default=None, metavar="N",
                    help="only files never verified or last verified more than N days ago")
    ap.add_argument("--limit", type=int, default=None, metavar="N",
                    help="check at most N files this run (oldest verification first)")
    ap.add_argument("--verified-by-email", default=None, metavar="EMAIL",
                    help="lab.person email to record as verified_by (default: none; "
                         "the database records the login either way)")
    ap.add_argument("--dry-run", action="store_true",
                    help="check and report, but write nothing")
    args = ap.parse_args()
    if not args.root:
        ap.error("give at least one --root NAME=PATH")
    if args.limit is not None and args.limit < 1:
        ap.error("--limit must be at least 1")
    roots = parse_roots(args.root)

    try:
        conn = connect()
    except Exception as exc:  # driver-specific connection errors
        die("cannot connect to the database: %s" % exc)
    cur = conn.cursor()

    cur.execute("SELECT name FROM lab.storage_root")
    known = {row[0] for row in cur.fetchall()}
    unknown = sorted(set(roots) - known)
    if unknown:
        die("no such storage root in lab.storage_root: %s (known: %s)"
            % (", ".join(unknown), ", ".join(sorted(known)) or "none"))

    verified_by = None
    if args.verified_by_email:
        cur.execute("SELECT person_id::text FROM lab.person WHERE lower(email) = lower(%s)",
                    (args.verified_by_email,))
        row = cur.fetchone()
        if row is None:
            die("no lab.person with email %s" % args.verified_by_email)
        verified_by = row[0]

    older = None if args.older_than_days is None else "%s days" % args.older_than_days
    cur.execute(SELECT_SQL, {"older": older})
    artifacts = cur.fetchall()

    counts = {"ok": 0, "mismatch": 0, "missing": 0}
    skipped_root = 0
    skipped_algo = 0
    skipped_error = 0
    checked = 0
    for artifact_id, root_name, relative_path, checksum, algo, _size in artifacts:
        if args.limit is not None and checked >= args.limit:
            break
        root = roots.get(root_name)
        if root is None:
            skipped_root += 1
            continue
        path = resolve(root, relative_path)
        if path is None:
            print("SKIP     %s  %s:%s resolves outside its storage root"
                  % (artifact_id, root_name, relative_path), file=sys.stderr)
            skipped_error += 1
            continue
        observed = None
        if not os.path.isfile(path):
            status = "missing"
        else:
            try:
                observed = checksum_of(path, algo)
            except OSError as exc:
                # Unreadable is not the same as missing or corrupt: say so and
                # record nothing rather than a wrong status.
                print("SKIP     %s  %s:%s cannot be read: %s"
                      % (artifact_id, root_name, relative_path, exc), file=sys.stderr)
                skipped_error += 1
                continue
            if observed is None:
                skipped_algo += 1
                continue
            status = "ok" if observed == checksum else "mismatch"
        checked += 1
        counts[status] += 1
        if status != "ok":
            print("%-8s %s  %s:%s" % (status.upper(), artifact_id, root_name, relative_path))
        if not args.dry_run:
            cur.execute(INSERT_SQL, (artifact_id, status, observed, verified_by))

    conn.close()
    print("checked %d file(s): %d ok, %d mismatch, %d missing%s"
          % (checked, counts["ok"], counts["mismatch"], counts["missing"],
             " (dry run, nothing recorded)" if args.dry_run else ""))
    if skipped_root:
        print("skipped %d artifact(s) on storage roots not given with --root" % skipped_root)
    if skipped_algo:
        print("skipped %d artifact(s) whose checksum algorithm is unavailable here "
              "(blake3 needs: pip install blake3)" % skipped_algo)
    if skipped_error:
        print("skipped %d artifact(s) that could not be read (see above)" % skipped_error)
    sys.exit(1 if counts["mismatch"] or counts["missing"] else 0)


if __name__ == "__main__":
    main()
