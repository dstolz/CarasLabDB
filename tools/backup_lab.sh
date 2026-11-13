#!/usr/bin/env bash
# ============================================================================
# backup_lab.sh -- logical backup of the CarasLabDB database and its roles
# ============================================================================
# Writes three files to BACKUP_DIR, all named <db>_<YYYYmmdd_HHMMSS>:
#
#   .dump         pg_dump, custom format, of the database
#   .globals.sql  pg_dumpall --globals-only: every role, its password hash
#                 and its group memberships. Without it a restore on a new
#                 server has data but no logins and no privileges.
#   .manifest     schema version and row count of every lab table, read just
#                 before the dump; restore_lab.sh compares against it.
#
# The set is written to a hidden work directory first and moved into place
# only after the dump has been read back with `pg_restore --list` and is seen
# to contain the lab schema, so a failed run never leaves an empty or partial
# file that looks like a backup. Older sets are pruned only after a new one
# is in place (and copied, with --copy-to). Any failure exits non-zero with a
# message on stderr.
#
# Usage:
#   backup_lab.sh [options] BACKUP_DIR
#   backup_lab.sh --check HOURS [-d DBNAME] BACKUP_DIR
#
# Options:
#   -d, --dbname NAME      database to dump (default: $PGDATABASE, else lab)
#   -k, --keep-days N      prune sets older than N days (default 30)
#   -c, --copy-to DIR      also copy the new set to DIR (a mount of other
#                          storage) and verify the copy; the same pruning
#                          applies there
#       --no-role-passwords
#                          dump roles without password hashes, for a login
#                          that is not a superuser (passwords must then be
#                          set again after a restore)
#       --check HOURS      take no backup: succeed only if BACKUP_DIR holds a
#                          readable dump newer than HOURS hours. For a
#                          monitoring job.
#
# Connection settings are the usual libpq ones (PGHOST, PGPORT, PGUSER,
# ~/.pgpass). Run it as a superuser (on the server: the postgres OS user),
# because only a superuser can read the role password hashes.
#
# PG_EXEC, if set, is put in front of every PostgreSQL command, for a server
# that runs in a container; the files still land on the host:
#
#   PG_EXEC="docker exec -i -e PGUSER=postgres caraslabdb-postgres-1" \
#       backup_lab.sh /volume1/docker/caraslabdb/backups
#
# Exit status: 0 success; 1 failure; 2 usage error.
# ============================================================================
set -euo pipefail
umask 077

prog=$(basename "$0")
die()   { echo "$prog: ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,/^# Exit status/p' "$0" | sed 's/^# \{0,1\}//'; }

DB=${PGDATABASE:-lab}
KEEP_DAYS=30
COPY_TO=""
CHECK_HOURS=""
ROLE_PASSWORDS=1

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dbname)      [ $# -ge 2 ] || die "$1 needs a value"; DB=$2; shift 2 ;;
        -k|--keep-days)   [ $# -ge 2 ] || die "$1 needs a value"; KEEP_DAYS=$2; shift 2 ;;
        -c|--copy-to)     [ $# -ge 2 ] || die "$1 needs a value"; COPY_TO=$2; shift 2 ;;
        --check)          [ $# -ge 2 ] || die "$1 needs a value"; CHECK_HOURS=$2; shift 2 ;;
        --no-role-passwords) ROLE_PASSWORDS=0; shift ;;
        -h|--help)        usage; exit 0 ;;
        --)               shift; break ;;
        -*)               echo "$prog: unknown option $1" >&2; exit 2 ;;
        *)                break ;;
    esac
done
[ $# -eq 1 ] || { echo "$prog: exactly one BACKUP_DIR is required (try --help)" >&2; exit 2; }
DIR=$1

case "$KEEP_DAYS" in ''|*[!0-9]*) die "--keep-days must be a whole number of days" ;; esac
[ "$KEEP_DAYS" -ge 1 ] || die "--keep-days must be at least 1"
case "$DB" in ''|*/*) die "invalid database name '$DB'" ;; esac
[ -d "$DIR" ] || die "backup directory $DIR does not exist"

# PostgreSQL commands, optionally run through PG_EXEC (e.g. docker exec -i).
PG=()
if [ -n "${PG_EXEC:-}" ]; then
    read -r -a PG <<<"$PG_EXEC"
else
    for tool in psql pg_dump pg_dumpall pg_restore; do
        command -v "$tool" >/dev/null 2>&1 || die "$tool is not on the PATH"
    done
fi
pg() { ${PG[@]+"${PG[@]}"} "$@"; }

# The archive lists the lab schema's event table: it is a CarasLabDB dump,
# complete enough to be read, and not a dump of some other database.
dump_is_readable() {
    pg pg_restore --list <"$1" 2>/dev/null | grep -Eq ' TABLE DATA lab event '
}

# ---------------------------------------------------------------------------
# --check: is there a recent, readable dump?
# ---------------------------------------------------------------------------
if [ -n "$CHECK_HOURS" ]; then
    case "$CHECK_HOURS" in ''|*[!0-9]*) die "--check needs a whole number of hours" ;; esac
    newest=$(find "$DIR" -maxdepth 1 -type f -name "${DB}_*.dump" \
                 -mmin "-$((CHECK_HOURS * 60))" | sort | tail -n 1)
    [ -n "$newest" ] || die "no ${DB}_*.dump newer than $CHECK_HOURS h in $DIR"
    dump_is_readable "$newest" || die "$newest is not a readable CarasLabDB dump"
    [ -s "${newest%.dump}.globals.sql" ] || die "${newest%.dump}.globals.sql is missing or empty"
    echo "$prog: OK: $newest"
    exit 0
fi

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
[ -w "$DIR" ] || die "backup directory $DIR is not writable by $(id -un)"
if [ -n "$COPY_TO" ]; then
    [ -d "$COPY_TO" ] && [ -w "$COPY_TO" ] || die "copy directory $COPY_TO is missing or not writable"
fi

stamp=$(date +%Y%m%d_%H%M%S)
base="${DB}_${stamp}"
work=$(mktemp -d "$DIR/.backup_lab.XXXXXX")
copywork=""
cleanup() {
    rm -rf "$work"
    if [ -n "$copywork" ]; then rm -rf "$copywork"; fi
}
trap cleanup EXIT

# 1. Manifest: schema version and exact row counts, in one snapshot.
pg psql -X -At -q -v ON_ERROR_STOP=1 -d "$DB" >"$work/$base.manifest" <<'SQL' \
    || die "could not read database $DB (is it a CarasLabDB database, and may this login read it?)"
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT 'schema_version|' || max(version) FROM lab.schema_version;
SELECT format('SELECT %L || count(*) FROM %I.%I',
              'rows.' || c.relname || '|', n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'lab' AND c.relkind = 'r'
ORDER BY c.relname \gexec
COMMIT;
SQL
grep -q '^schema_version|[0-9]' "$work/$base.manifest" || die "manifest for $DB has no schema version"

# 2. The database, custom format.
pg pg_dump --format=custom --dbname="$DB" >"$work/$base.dump" || die "pg_dump of $DB failed"
[ -s "$work/$base.dump" ] || die "pg_dump of $DB produced an empty file"

# 3. Read it back.
dump_is_readable "$work/$base.dump" \
    || die "the new dump cannot be listed by pg_restore, or holds no lab.event table"

# 4. Roles, password hashes and memberships (cluster-wide, not in pg_dump).
globals_args=(--globals-only)
[ "$ROLE_PASSWORDS" -eq 1 ] || globals_args+=(--no-role-passwords)
pg pg_dumpall "${globals_args[@]}" >"$work/$base.globals.sql" \
    || die "pg_dumpall --globals-only failed (it needs a superuser; a login that is not one can use --no-role-passwords)"
grep -q '^CREATE ROLE ' "$work/$base.globals.sql" || die "the roles dump lists no roles"
grep -q 'database cluster dump complete' "$work/$base.globals.sql" || die "the roles dump is incomplete"

# 5. In place. The .dump goes last: its presence marks a complete set.
mv "$work/$base.manifest"    "$DIR/$base.manifest"
mv "$work/$base.globals.sql" "$DIR/$base.globals.sql"
mv "$work/$base.dump"        "$DIR/$base.dump"

# 6. Second copy on other storage, verified byte for byte.
if [ -n "$COPY_TO" ]; then
    copywork=$(mktemp -d "$COPY_TO/.backup_lab.XXXXXX")
    for ext in manifest globals.sql dump; do
        cp "$DIR/$base.$ext" "$copywork/$base.$ext"
        cmp -s "$DIR/$base.$ext" "$copywork/$base.$ext" || die "copy of $base.$ext to $COPY_TO does not match"
    done
    for ext in manifest globals.sql dump; do
        mv "$copywork/$base.$ext" "$COPY_TO/$base.$ext"
    done
fi

# 7. Prune, only now that a verified new set exists.
prune() {
    find "$1" -maxdepth 1 -type f \
        \( -name "${DB}_*.dump" -o -name "${DB}_*.globals.sql" -o -name "${DB}_*.manifest" \) \
        -mtime "+$KEEP_DAYS" -print -delete | sed "s/^/$prog: pruned /"
    # Work directories abandoned by a run that was killed.
    find "$1" -maxdepth 1 -type d -name '.backup_lab.*' -mtime +1 -exec rm -rf {} + 2>/dev/null || true
}
prune "$DIR"
if [ -n "$COPY_TO" ]; then prune "$COPY_TO"; fi

size=$(wc -c <"$DIR/$base.dump" | tr -d ' ')
echo "$prog: OK: $DIR/$base.dump ($size bytes), $base.globals.sql, $base.manifest${COPY_TO:+; copied to $COPY_TO}"
