#!/usr/bin/env python3
"""Restore a backup_lab.py set into a NEW database, and report what arrived.

    python tools/restore_lab.py [options] DUMP_FILE TARGET_DB

    DUMP_FILE   <db>_<stamp>.dump; the .globals.sql and .manifest of the same
                set are expected next to it
    TARGET_DB   name of the database to create, e.g. lab_restored

What it does, in order:

1. Roles, from <set>.globals.sql. A role that already exists on this server
   is left exactly as it is (password, LOGIN flag and memberships are not
   touched), so a restore drill on the live server cannot re-enable a login
   that was disabled after the backup was taken. Only missing roles are
   created.
2. A new database TARGET_DB with the owner, settings and database-level
   privileges the original had. An existing database is never overwritten.
3. The dump, in one transaction, stopping on the first error: either the
   whole database is restored or TARGET_DB is removed again.
4. A report: schema version, row counts compared with <set>.manifest, object
   owners, grants per role, and lab.fn_check_integrity().

Options: --no-roles (roles are managed elsewhere, or you are not a superuser;
every role the dump names must already exist) and --use-existing (restore
into TARGET_DB, which exists and has no lab schema -- a database created for
you by IT).

Run it as a PostgreSQL superuser. It never prompts for a password (password
file or peer authentication, as for backup_lab.py). Restore to the PostgreSQL
major version the dump came from, or a newer one. Standard library only;
--pg-bin and --pg-exec work as in backup_lab.py.

To bring a restored copy into service under the original name, stop the
clients and rename it; see "Restore runbook" in the deployment guides.

Exit status: 0 restored and the row counts match the manifest; 1 failure
(nothing usable was restored); 2 usage error; 3 restored, but the row counts
differ from the manifest or there is no manifest.
"""

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys

PROG = "restore_lab"

# Must stay identical to MANIFEST_SQL in backup_lab.py.
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

REPORT_QUERIES = (
    ("owners of the lab schema's tables",
     "SELECT string_agg(DISTINCT pg_get_userbyid(c.relowner), ', ') FROM pg_class c "
     "JOIN pg_namespace n ON n.oid = c.relnamespace "
     "WHERE n.nspname = 'lab' AND c.relkind = 'r';"),
    ("triggers in schema lab",
     "SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid "
     "JOIN pg_namespace n ON n.oid = c.relnamespace "
     "WHERE n.nspname = 'lab' AND NOT t.tgisinternal;"),
    ("table privileges granted (role|privilege|tables and views)",
     "SELECT g || '|' || p || '|' || n FROM ("
     "SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END AS g, "
     "a.privilege_type AS p, count(DISTINCT c.oid) AS n "
     "FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace "
     "CROSS JOIN LATERAL aclexplode(c.relacl) a "
     "WHERE ns.nspname = 'lab' AND c.relkind IN ('r', 'v') AND a.grantee <> c.relowner "
     "GROUP BY 1, 2) s ORDER BY g, p;"),
    ("lab.fn_check_integrity() (severity|check|rows)",
     "SELECT severity || '|' || check_name || '|' || count(*) FROM lab.fn_check_integrity() "
     "GROUP BY severity, check_name ORDER BY severity, check_name;"),
)


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

    def read_archive(self, args, path):
        """Run pg_restore on the archive `path`; stdout is captured."""
        if self.prefix:           # the container cannot see host paths
            with open(path, "rb") as src:
                return self.run("pg_restore", args, stdin=src, stdout=subprocess.PIPE)
        return self.run("pg_restore", list(args) + [path], stdout=subprocess.PIPE)

    def sql(self, database, text, variables=(), what="a query"):
        """Run SQL through psql, stopping on the first error; return its output."""
        args = ["-X", "-At", "-q", "-w", "-v", "ON_ERROR_STOP=1", "-d", database]
        for name, value in variables:
            args += ["-v", "%s=%s" % (name, value)]
        result = self.run("psql", args, input=text.encode("utf-8", "surrogateescape"),
                          stdout=subprocess.PIPE)
        if result.returncode != 0:
            raise Fail("%s failed: %s" % (what, stderr_of(result)))
        return result.stdout.decode("utf-8", "replace").replace("\r\n", "\n").strip()


def stderr_of(result):
    return result.stderr.decode("utf-8", "replace").strip() if result.stderr else ""


def leading_ident(text):
    """The SQL identifier at the start of `text`, exactly as written."""
    if not text.startswith('"'):
        match = re.match(r"[^ ;]+", text)
        return match.group(0) if match else ""
    i = 1
    while i < len(text):
        if text[i] == '"':
            if text[i + 1:i + 2] == '"':
                i += 2
                continue
            return text[:i + 1]
        i += 1
    return text


def filter_roles(globals_sql, have):
    """Drop every statement about a role in `have` (roles that already exist).

    Covers CREATE ROLE, ALTER ROLE (attributes, password and settings),
    COMMENT ON ROLE, and the membership GRANTs whose member already exists.
    Returns (sql, number of roles it creates, names left alone).
    """
    kept, skipped, created = [], set(), 0
    for line in globals_sql.splitlines():
        match = re.match(r"(CREATE|ALTER) ROLE ", line)
        if match:
            role = leading_ident(line[match.end():])
            if role in have:
                skipped.add(role)
                continue
            if match.group(1) == "CREATE":
                created += 1
        elif line.startswith("COMMENT ON ROLE "):
            if leading_ident(line[len("COMMENT ON ROLE "):]) in have:
                continue
        elif line.startswith("GRANT "):
            group = leading_ident(line[len("GRANT "):])
            rest = line[len("GRANT ") + len(group):]
            if rest.startswith(" TO ") and leading_ident(rest[len(" TO "):]) in have:
                continue
        kept.append(line)
    return "\n".join(kept) + "\n", created, sorted(skipped)


def database_statements(script, target_q):
    """CREATE DATABASE, ALTER DATABASE and database-level GRANT/REVOKE from a
    `pg_restore --create` script, renamed to the target database.

    pg_restore applies these only with --create, which would also force the
    original database name."""
    orig_q = None
    for line in script.splitlines():
        if line.startswith("CREATE DATABASE "):
            orig_q = leading_ident(line[len("CREATE DATABASE "):])
            break
    if not orig_q:
        raise Fail("could not find the original database name in the dump")

    def renamed(line):
        return line.replace("DATABASE " + orig_q, "DATABASE " + target_q, 1)

    create, after = None, []
    for line in script.splitlines():
        if create is None and line.startswith("CREATE DATABASE " + orig_q + " "):
            create = renamed(line)
        elif line.startswith("ALTER DATABASE " + orig_q + " "):
            after.append(renamed(line))
        elif re.match(r"(GRANT|REVOKE) ", line) and (" ON DATABASE " + orig_q + " ") in line:
            after.append(renamed(line))
    return create, after


def parse_manifest(text):
    return dict(line.split("|", 1) for line in text.splitlines() if "|" in line)


def restore(pg, args):
    dump, target = args.dump_file, args.target_db
    stem = dump[:-len(".dump")] if dump.endswith(".dump") else dump
    globals_file, manifest_file = stem + ".globals.sql", stem + ".manifest"

    if not os.path.isfile(dump) or os.path.getsize(dump) == 0:
        raise Fail("dump file %s is missing or empty" % dump)
    if not args.no_roles and not (os.path.isfile(globals_file) and os.path.getsize(globals_file)):
        raise Fail("roles file %s is missing or empty (use --no-roles if the roles "
                   "already exist)" % globals_file)

    # 0. The dump is readable, and the target is free.
    listing = pg.read_archive(["--list"], dump)
    if listing.returncode != 0:
        raise Fail("pg_restore cannot read %s: %s" % (dump, stderr_of(listing)))
    if b" TABLE DATA lab event " not in listing.stdout:
        raise Fail("%s holds no lab.event table: not a CarasLabDB dump" % dump)

    exists = pg.sql("postgres", "SELECT count(*) FROM pg_database WHERE datname = :'t';",
                    [("t", target)], "looking up the target database") == "1"
    if args.use_existing:
        if not exists:
            raise Fail("database %s does not exist (drop --use-existing to have it created)"
                       % target)
        if pg.sql(target, "SELECT count(*) FROM pg_namespace WHERE nspname = 'lab';") != "0":
            raise Fail("database %s already has a lab schema; refusing to restore over it"
                       % target)
    elif exists:
        raise Fail("database %s already exists; choose a new name (nothing is ever "
                   "overwritten)" % target)
    target_q = pg.sql("postgres", "SELECT quote_ident(:'t');", [("t", target)])

    # 1. Roles: create the missing ones, leave existing ones alone.
    if args.no_roles:
        print("%s: roles: not restored (--no-roles)" % PROG)
    else:
        have = set(pg.sql("postgres", "SELECT quote_ident(rolname) FROM pg_roles;").splitlines())
        with open(globals_file, encoding="utf-8", errors="surrogateescape") as src:
            roles_sql, created, skipped = filter_roles(src.read(), have)
        pg.sql("postgres", roles_sql, what="restoring roles from %s" % globals_file)
        print("%s: roles: %d created; already here and left as they are: %s"
              % (PROG, created, " ".join(skipped) or "(none)"))

    # 2. The database, with its original owner, settings and privileges.
    script = pg.read_archive(["--create", "--schema-only", "--file=-"], dump)
    if script.returncode != 0:
        raise Fail("pg_restore could not script %s: %s" % (dump, stderr_of(script)))
    create, after = database_statements(script.stdout.decode("utf-8", "surrogateescape"),
                                        target_q)
    if not args.use_existing:
        if not create:
            raise Fail("could not build CREATE DATABASE for %s" % target)
        try:
            pg.sql("postgres", create, what="creating database %s" % target)
        except Fail as failure:
            raise Fail("%s (if its locale does not exist on this server, create the database "
                       "yourself from template0 and use --use-existing)" % failure)

    loaded = pg.read_archive(["--single-transaction", "--exit-on-error", "--no-password",
                              "--dbname=" + target], dump)
    if loaded.returncode != 0:
        if args.use_existing:
            raise Fail("pg_restore failed; database %s was left as it was (the restore is one "
                       "transaction): %s" % (target, stderr_of(loaded)))
        pg.sql("postgres", "DROP DATABASE %s;" % target_q, what="removing the failed restore")
        raise Fail("pg_restore failed; database %s was removed again. If a role is missing, "
                   "restore roles (omit --no-roles) or create it first: %s"
                   % (target, stderr_of(loaded)))
    if stderr_of(loaded):
        print("%s: pg_restore succeeded but printed:\n%s" % (PROG, stderr_of(loaded)),
              file=sys.stderr)
    if after and not args.use_existing:
        pg.sql("postgres", "\n".join(after) + "\n",
               what="restoring the owner and privileges of database %s" % target)

    # 3. Report.
    now = pg.sql(target, MANIFEST_SQL, what="counting rows in %s" % target)
    counts = parse_manifest(now)
    print("== restored %s into database %s" % (dump, target))
    print("== schema version: %s" % counts.get("schema_version", "?"))
    print("== row counts (table|rows):")
    for key in sorted(counts):
        if key.startswith("rows."):
            print("%s|%s" % (key[len("rows."):], counts[key]))
    print("== database owner: %s" % pg.sql(
        "postgres", "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = :'t';",
        [("t", target)]))
    for title, query in REPORT_QUERIES:
        answer = pg.sql(target, query, what=title)
        print("== %s:%s" % (title, ("\n" + answer) if "\n" in answer or "|" in answer
                            else " " + answer))

    if not os.path.isfile(manifest_file):
        print("%s: WARNING: no manifest %s; the row counts above were not compared"
              % (PROG, manifest_file), file=sys.stderr)
        return 3
    with open(manifest_file, encoding="utf-8") as src:
        expected = parse_manifest(src.read())
    if expected == counts:
        print("== manifest: schema version and every row count match %s" % manifest_file)
        print("%s: OK" % PROG)
        return 0
    print("== manifest: DIFFERENCES (item: backup manifest -> restored database):",
          file=sys.stderr)
    for key in sorted(set(expected) | set(counts)):
        if expected.get(key) != counts.get(key):
            print("%s: %s -> %s" % (key, expected.get(key, "absent"), counts.get(key, "absent")),
                  file=sys.stderr)
    print("%s: WARNING: the restored database does not match the manifest. Rows written "
          "between the manifest and the dump explain a small surplus; anything else needs "
          "investigating." % PROG, file=sys.stderr)
    return 3


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog=PROG, description="Restore a backup_lab.py set into a new database.",
        epilog="See the module docstring (top of this file) for details.")
    parser.add_argument("dump_file", metavar="DUMP_FILE")
    parser.add_argument("target_db", metavar="TARGET_DB")
    parser.add_argument("--no-roles", action="store_true",
                        help="do not restore roles; every role the dump names must exist")
    parser.add_argument("--use-existing", action="store_true",
                        help="restore into TARGET_DB, which exists and has no lab schema")
    parser.add_argument("--pg-bin", metavar="DIR", help="directory holding psql and pg_restore")
    parser.add_argument("--pg-exec", metavar="CMD",
                        help="command put in front of every PostgreSQL program")
    parser.add_argument("-U", "--username", help="database login (default: $PGUSER)")
    parser.add_argument("--host", help="database host (default: $PGHOST)")
    parser.add_argument("--port", help="database port (default: $PGPORT)")
    args = parser.parse_args(argv)
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_$]*$", args.target_db):
        parser.error("target database name %r: use letters, digits and underscores"
                     % args.target_db)

    try:
        return restore(Pg(args), args)
    except (Fail, OSError) as failure:
        print("%s: ERROR: %s" % (PROG, failure), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
