#!/usr/bin/env python3
"""Logical backup of the CarasLabDB database and its roles.

Writes three files to BACKUP_DIR, all named <db>_<YYYYmmdd_HHMMSS>:

    .dump         pg_dump, custom format, of the database
    .globals.sql  pg_dumpall --globals-only: every role, its password hash and
                  its group memberships. Without it a restore on a new server
                  has data but no logins and no privileges.
    .manifest     schema version and row count of every lab table, read just
                  before the dump; restore_lab.py compares against it.

The set is written to a hidden work directory first and moved into place only
after the dump has been read back with `pg_restore --list` and is seen to hold
the lab schema, so a failed run never leaves an empty or partial file that
looks like a backup. Older sets are pruned only after a new one is in place
(and copied, with --copy-to). Any failure exits non-zero with a message on
stderr, and on the last line of --log-file if one is given.

    python tools/backup_lab.py [options] BACKUP_DIR
    python tools/backup_lab.py --check HOURS [options] BACKUP_DIR

Run it as a PostgreSQL superuser, because only a superuser can read the role
password hashes (a login that is not one can pass --no-role-passwords and set
passwords again after a restore). It never prompts: the password comes from
the password file of the account that runs it (~/.pgpass, or
%APPDATA%\\postgresql\\pgpass.conf on Windows) or from peer authentication.

Standard library only. The PostgreSQL client programs (psql, pg_dump,
pg_dumpall, pg_restore) are taken from --pg-bin or the PATH. --pg-exec puts a
command in front of each of them, for a server that runs in a container; the
files still land on the host:

    python tools/backup_lab.py \\
        --pg-exec "docker exec -i -e PGUSER=postgres caraslabdb-postgres-1" \\
        /volume1/docker/caraslabdb/backups

Exit status: 0 success; 1 failure; 2 usage error.
"""

import argparse
import datetime
import filecmp
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

PROG = "backup_lab"
# The .dump is moved into place last: its presence marks a complete set.
SET_EXTENSIONS = ("manifest", "globals.sql", "dump")

# Schema version and exact row counts of every lab table, in one snapshot.
# restore_lab.py runs the same statement against the restored database.
MANIFEST_SQL = """\
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT 'schema_version|' || max(version) FROM lab.schema_version;
SELECT format('SELECT %L || count(*) FROM %I.%I',
              'rows.' || c.relname || '|', n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'lab' AND c.relkind = 'r'
ORDER BY c.relname \\gexec
COMMIT;
"""


class Fail(Exception):
    """A failure to report and exit 1 on."""


class Pg:
    """Runs the PostgreSQL client programs, directly or through a prefix."""

    def __init__(self, args):
        self.prefix = shlex.split(args.pg_exec) if args.pg_exec else []
        self.pg_bin = args.pg_bin
        self.env = dict(os.environ)
        self.env["PGCLIENTENCODING"] = "UTF8"
        for name, value in (("PGUSER", args.username), ("PGHOST", args.host),
                            ("PGPORT", args.port)):
            if value:
                self.env[name] = str(value)

    def tool(self, name):
        if self.prefix:
            return name           # resolved inside the container
        if self.pg_bin:
            exe = os.path.join(self.pg_bin, name + (".exe" if os.name == "nt" else ""))
            if not os.path.isfile(exe):
                raise Fail("%s not found in --pg-bin %s" % (name, self.pg_bin))
            return exe
        found = shutil.which(name)
        if not found:
            raise Fail("%s is not on the PATH; pass --pg-bin" % name)
        return found

    def run(self, name, args, **kwargs):
        kwargs.setdefault("stderr", subprocess.PIPE)
        return subprocess.run(self.prefix + [self.tool(name)] + list(args),
                              env=self.env, **kwargs)

    def write_archive(self, name, args, path):
        """Run a dump program, with its output in `path`."""
        if self.prefix:           # the container cannot see host paths
            with open(path, "wb") as out:
                return self.run(name, args, stdout=out)
        return self.run(name, list(args) + ["--file=" + path], stdout=subprocess.PIPE)

    def read_archive(self, args, path):
        """Run pg_restore on the archive `path`; stdout is captured."""
        if self.prefix:
            with open(path, "rb") as src:
                return self.run("pg_restore", args, stdin=src, stdout=subprocess.PIPE)
        return self.run("pg_restore", list(args) + [path], stdout=subprocess.PIPE)


def stderr_of(result):
    return result.stderr.decode("utf-8", "replace").strip() if result.stderr else ""


def dump_is_readable(pg, path):
    """The archive lists the lab schema's event table: it is a CarasLabDB dump,
    complete enough to be read, and not a dump of some other database."""
    result = pg.read_archive(["--list"], path)
    return result.returncode == 0 and b" TABLE DATA lab event " in result.stdout


def set_files(directory, db):
    """Backup-set files of `db` in `directory`, as (path, extension) pairs."""
    pattern = re.compile(r"^%s_\d{8}_\d{6}\.(dump|globals\.sql|manifest)$" % re.escape(db))
    found = []
    for name in sorted(os.listdir(directory)):
        match = pattern.match(name)
        if match:
            found.append((os.path.join(directory, name), match.group(1)))
    return found


def check(pg, args):
    newest = None
    cutoff = time.time() - args.check * 3600
    for path, ext in set_files(args.backup_dir, args.dbname):
        if ext == "dump" and os.path.getmtime(path) >= cutoff:
            newest = path                      # names sort by time stamp
    if newest is None:
        raise Fail("no %s_*.dump newer than %d h in %s"
                   % (args.dbname, args.check, args.backup_dir))
    if not dump_is_readable(pg, newest):
        raise Fail("%s is not a readable CarasLabDB dump" % newest)
    globals_file = newest[:-len("dump")] + "globals.sql"
    if not os.path.isfile(globals_file) or os.path.getsize(globals_file) == 0:
        raise Fail("%s is missing or empty" % globals_file)
    return "%s is recent and readable" % newest


def prune(directory, db, keep_days):
    """Remove backup sets older than keep_days, and abandoned work directories."""
    removed = []
    cutoff = time.time() - keep_days * 86400
    for path, _ext in set_files(directory, db):
        if os.path.getmtime(path) < cutoff:
            os.remove(path)
            removed.append(os.path.basename(path))
    for name in os.listdir(directory):
        path = os.path.join(directory, name)
        if (name.startswith(".backup_lab.") and os.path.isdir(path)
                and os.path.getmtime(path) < time.time() - 86400):
            shutil.rmtree(path, ignore_errors=True)
    return removed


def backup(pg, args):
    directory, db = args.backup_dir, args.dbname
    if not os.access(directory, os.W_OK):
        raise Fail("backup directory %s is not writable by this account" % directory)
    if args.copy_to and not (os.path.isdir(args.copy_to) and os.access(args.copy_to, os.W_OK)):
        raise Fail("copy directory %s is missing or not writable" % args.copy_to)

    base = "%s_%s" % (db, datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
    work = tempfile.mkdtemp(prefix=".backup_lab.", dir=directory)
    copy_work = None
    try:
        staged = {ext: os.path.join(work, "%s.%s" % (base, ext)) for ext in SET_EXTENSIONS}

        # 1. Manifest.
        result = pg.run("psql", ["-X", "-At", "-q", "-w", "-v", "ON_ERROR_STOP=1", "-d", db],
                        input=MANIFEST_SQL.encode("utf-8"), stdout=subprocess.PIPE)
        if result.returncode != 0:
            raise Fail("could not read database %s (is it a CarasLabDB database, and may "
                       "this login read it?): %s" % (db, stderr_of(result)))
        manifest = result.stdout.decode("utf-8").replace("\r\n", "\n")
        if not re.match(r"schema_version\|\d+\n", manifest):
            raise Fail("manifest for %s has no schema version" % db)
        with open(staged["manifest"], "w", encoding="utf-8", newline="\n") as out:
            out.write(manifest)

        # 2. The database, custom format.
        result = pg.write_archive("pg_dump", ["--format=custom", "--no-password",
                                              "--dbname=" + db], staged["dump"])
        if result.returncode != 0:
            raise Fail("pg_dump of %s failed: %s" % (db, stderr_of(result)))
        if not os.path.isfile(staged["dump"]) or os.path.getsize(staged["dump"]) == 0:
            raise Fail("pg_dump of %s produced an empty file" % db)

        # 3. Read it back.
        if not dump_is_readable(pg, staged["dump"]):
            raise Fail("the new dump cannot be listed by pg_restore, or holds no lab.event table")

        # 4. Roles, password hashes and memberships (cluster-wide, not in pg_dump).
        globals_args = ["--globals-only", "--no-password"]
        if args.no_role_passwords:
            globals_args.append("--no-role-passwords")
        result = pg.write_archive("pg_dumpall", globals_args, staged["globals.sql"])
        if result.returncode != 0:
            raise Fail("pg_dumpall --globals-only failed (it needs a superuser; a login that "
                       "is not one can use --no-role-passwords): %s" % stderr_of(result))
        with open(staged["globals.sql"], "rb") as src:
            roles = src.read()
        if not re.search(rb"(?m)^CREATE ROLE ", roles):
            raise Fail("the roles dump lists no roles")
        if b"database cluster dump complete" not in roles:
            raise Fail("the roles dump is incomplete")

        # 5. In place.
        final = {ext: os.path.join(directory, "%s.%s" % (base, ext)) for ext in SET_EXTENSIONS}
        for ext in SET_EXTENSIONS:
            os.replace(staged[ext], final[ext])

        # 6. Second copy on other storage, verified byte for byte.
        if args.copy_to:
            copy_work = tempfile.mkdtemp(prefix=".backup_lab.", dir=args.copy_to)
            for ext in SET_EXTENSIONS:
                staged_copy = os.path.join(copy_work, os.path.basename(final[ext]))
                shutil.copyfile(final[ext], staged_copy)
                if not filecmp.cmp(final[ext], staged_copy, shallow=False):
                    raise Fail("copy of %s to %s does not match"
                               % (os.path.basename(final[ext]), args.copy_to))
            for ext in SET_EXTENSIONS:
                name = os.path.basename(final[ext])
                os.replace(os.path.join(copy_work, name), os.path.join(args.copy_to, name))
    finally:
        shutil.rmtree(work, ignore_errors=True)
        if copy_work:
            shutil.rmtree(copy_work, ignore_errors=True)

    # 7. Prune, only now that a verified new set exists.
    removed = prune(directory, db, args.keep_days)
    if args.copy_to:
        prune(args.copy_to, db, args.keep_days)
    message = "%s (%d bytes), with .globals.sql and .manifest" % (
        final["dump"], os.path.getsize(final["dump"]))
    if args.copy_to:
        message += "; copied to %s" % args.copy_to
    if removed:
        message += "; pruned %d old file(s)" % len(removed)
    return message


def log_line(path, text):
    if not path:
        return
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(path, "a", encoding="utf-8") as out:
        out.write("%s %s\n" % (stamp, text))


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog=PROG, description="Back up the CarasLabDB database and its roles.",
        epilog="See the module docstring (top of this file) for details.")
    parser.add_argument("backup_dir", metavar="BACKUP_DIR")
    parser.add_argument("-d", "--dbname", default=os.environ.get("PGDATABASE") or "lab",
                        help="database to dump (default: $PGDATABASE, else lab)")
    parser.add_argument("-k", "--keep-days", type=int, default=30,
                        help="prune sets older than this many days (default 30)")
    parser.add_argument("-c", "--copy-to", metavar="DIR",
                        help="also copy the new set to DIR (other storage) and verify it")
    parser.add_argument("--no-role-passwords", action="store_true",
                        help="dump roles without password hashes (for a non-superuser)")
    parser.add_argument("--check", type=int, metavar="HOURS",
                        help="take no backup; succeed only if BACKUP_DIR holds a readable "
                             "dump newer than HOURS hours")
    parser.add_argument("--pg-bin", metavar="DIR",
                        help="directory holding psql, pg_dump, pg_dumpall, pg_restore")
    parser.add_argument("--pg-exec", metavar="CMD",
                        help="command put in front of every PostgreSQL program, "
                             "e.g. 'docker exec -i -e PGUSER=postgres <container>'")
    parser.add_argument("-U", "--username", help="database login (default: $PGUSER)")
    parser.add_argument("--host", help="database host (default: $PGHOST)")
    parser.add_argument("--port", help="database port (default: $PGPORT)")
    parser.add_argument("--log-file", metavar="FILE",
                        help="append one line per run (OK or ERROR) to FILE")
    args = parser.parse_args(argv)

    if args.keep_days < 1:
        parser.error("--keep-days must be at least 1")
    if not re.match(r"^[A-Za-z0-9_.-]+$", args.dbname):
        parser.error("database name %r cannot be used in a file name" % args.dbname)
    if args.check is not None and args.check < 1:
        parser.error("--check needs a positive number of hours")

    os.umask(0o077)
    try:
        if not os.path.isdir(args.backup_dir):
            raise Fail("backup directory %s does not exist" % args.backup_dir)
        pg = Pg(args)
        message = check(pg, args) if args.check is not None else backup(pg, args)
    except (Fail, OSError) as failure:
        print("%s: ERROR: %s" % (PROG, failure), file=sys.stderr)
        log_line(args.log_file, "ERROR %s" % failure)
        return 1
    print("%s: OK: %s" % (PROG, message))
    log_line(args.log_file, "OK %s" % message)
    return 0


if __name__ == "__main__":
    sys.exit(main())
