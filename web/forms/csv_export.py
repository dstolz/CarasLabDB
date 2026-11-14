"""The per-subject, per-project CSV files the forms server writes.

One CSV per subject per project, under the CSV root:

    <csv-root>/<project name>/<subject id>.csv

One row per active entry on any of the subject's forms in that project (an
entry corrected since is its current version; a withdrawn one is left out),
ordered by when the session happened. The columns are fixed metadata, then
one column per variable of the subject's forms in that project, in the order
lab.fn_subject_project_columns gives (form by form, then in the order the
fields first appear across the form's versions). A variable on two forms is
one column. A value is written exactly as the database stores it: the text
the user typed, numbers included (1.50 stays 1.50). A cell is empty when the
entry has no value for that variable, which includes a field its form version
did not have (the Form version column says which version each row was made on).

The file is regenerated from the database after every change, never
appended to, so it always matches the database, corrections and withdrawals
included. It is a derived copy: the database is the record. The file is
written to a temporary file in the same folder and moved into place
(os.replace), so a reader never sees half a file. UTF-8 with a byte-order
mark (so that Excel reads it as UTF-8) and CRLF line endings.

Nothing a person put there is overwritten. _manifest.json in the CSV root
holds the SHA-256 of every file this module wrote. A file whose bytes are not
the ones it wrote -- edited in Excel and saved, or not written by this
module at all -- is renamed to <name>.edited-<UTC stamp>.csv before the new
file is written. When a subject's file moves (its project was renamed), the
old one is moved into _moved/<UTC stamp>/.

When the file cannot be replaced (on Windows, Excel holds an open CSV
locked), write_subject_csv reports "pending" and changes nothing; the caller
tries again later. The database commit it follows stands either way.

Standard library only; the database is reached through the connection the
caller passes (psycopg 3).
"""

import csv
import datetime as _dt
import hashlib
import io
import json
import os
import re
import secrets
import threading

MANIFEST = "_manifest.json"
MOVED_DIR = "_moved"

# Metadata columns, before the variables. Variable names are lower case
# (lab.variable's name rule), so a header with a capital letter is always one
# of these and can never collide with a variable's column.
META_COLUMNS = (
    "Entry ID", "Event ID", "Subject", "Project", "Form", "Form version",
    "Session label", "Session time", "Recorded at", "Entered by", "Login",
    "Corrected", "Note",
)

_WINDOWS_RESERVED = re.compile(r"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$", re.IGNORECASE)
_BAD_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
MAX_COMPONENT = 80

_manifest_lock = threading.Lock()
_key_locks = {}
_key_locks_guard = threading.Lock()


def sanitize_component(name):
    """A file or folder name for NAME that is legal on Windows and Linux.

    Characters Windows forbids become '_', trailing dots and spaces go, a
    reserved device name (CON, NUL, COM1, ...) gets a leading '_', and the
    result is at most MAX_COMPONENT characters. When anything had to change,
    '~' and the first 8 hex digits of NAME's SHA-256 are appended, so two
    different names never sanitise to the same one.
    """
    out = _BAD_CHARS.sub("_", name).strip().rstrip(". ")
    if not out:
        out = "_"
    if _WINDOWS_RESERVED.match(out):
        out = "_" + out
    if len(out) > MAX_COMPONENT:
        out = out[:MAX_COMPONENT].rstrip(". ")
    if out != name:
        out = out + "~" + hashlib.sha256(name.encode("utf-8")).hexdigest()[:8]
    return out


def relative_path(project_name, subject_id):
    """The file's path under the CSV root, with '/' separators."""
    return "%s/%s.csv" % (sanitize_component(project_name), sanitize_component(subject_id))


def _iso(value):
    if value is None:
        return ""
    if isinstance(value, _dt.datetime):
        return value.isoformat()
    return str(value)


def render_csv(columns, rows):
    """The CSV file's bytes.

    COLUMNS is a list of (variable, units). ROWS is a list of dicts with the
    META_COLUMNS keys plus "values", a {variable: text} dict. Values are
    written as given; nothing is converted.
    """
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\r\n")
    w.writerow(list(META_COLUMNS) + [v if not u else "%s (%s)" % (v, u) for v, u in columns])
    for r in rows:
        vals = r.get("values") or {}
        w.writerow([_iso(r.get(c)) for c in META_COLUMNS]
                   + [vals.get(v, "") for v, _ in columns])
    return b"\xef\xbb\xbf" + buf.getvalue().encode("utf-8")


# --------------------------------------------------------------------------
# Reading from the database
# --------------------------------------------------------------------------
SQL_PROJECT = "SELECT name FROM lab.project WHERE project_id = %s"
SQL_COLUMNS = ("SELECT variable, units FROM lab.fn_subject_project_columns(%s, %s) "
               "ORDER BY column_no")
SQL_ENTRIES = """
SELECT oa.entry_id, oa.event_id, oa.subject_id, oa.form_name, oa.form_version,
       oa.session_label, oa.occurred_at, oa.recorded_at, per.full_name AS entered_by,
       oa.recorded_login, oa.supersedes IS NOT NULL AS corrected, oa.note,
       oa.field_values::text AS field_values
FROM lab.observation_active oa
LEFT JOIN lab.person per ON per.person_id = oa.recorded_by
WHERE oa.subject_id = %s AND oa.project_id = %s
ORDER BY oa.occurred_at, oa.entry_id
"""


def read_subject_project(conn, subject_id, project_id, time_zone):
    """(project name, columns, rows) for one subject in one project, read in
    one transaction with timestamps in TIME_ZONE (None: the database
    default). Values come back as the text stored: field_values is read as
    JSON text whose values are all JSON strings."""
    with conn.transaction():
        cur = conn.cursor()
        if time_zone:
            cur.execute("SELECT set_config('TimeZone', %s, true)", [time_zone])
        else:
            cur.execute("SELECT set_config('TimeZone', reset_val, true) FROM pg_settings "
                        "WHERE name = 'TimeZone'")
        cur.execute(SQL_PROJECT, [project_id])
        row = cur.fetchone()
        if row is None:
            raise LookupError("project %s does not exist" % project_id)
        project_name = row[0]
        cur.execute(SQL_COLUMNS, [subject_id, project_id])
        columns = [(r[0], r[1]) for r in cur.fetchall()]
        cur.execute(SQL_ENTRIES, [subject_id, project_id])
        rows = []
        for r in cur.fetchall():
            rows.append({
                "Entry ID": str(r[0]), "Event ID": str(r[1]), "Subject": r[2],
                "Project": project_name, "Form": r[3], "Form version": str(r[4]),
                "Session label": r[5], "Session time": r[6], "Recorded at": r[7],
                "Entered by": r[8] or "", "Login": r[9] or "",
                "Corrected": "yes" if r[10] else "no", "Note": r[11] or "",
                "values": json.loads(r[12]),
            })
    return project_name, columns, rows


# --------------------------------------------------------------------------
# Writing the file
# --------------------------------------------------------------------------
def _key_lock(key):
    with _key_locks_guard:
        lock = _key_locks.get(key)
        if lock is None:
            lock = _key_locks[key] = threading.Lock()
        return lock


def _stamp():
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def load_manifest(root):
    path = os.path.join(root, MANIFEST)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {"files": {}}
    if not isinstance(data, dict) or not isinstance(data.get("files"), dict):
        raise ValueError("%s is not a forms CSV manifest" % path)
    return data


def _save_manifest(root, manifest):
    _atomic_write(os.path.join(root, MANIFEST),
                  json.dumps(manifest, indent=1, sort_keys=True).encode("utf-8"))


def _atomic_write(path, data):
    folder = os.path.dirname(path)
    tmp = os.path.join(folder, ".%s.%s.tmp" % (os.path.basename(path), secrets.token_hex(4)))
    try:
        with open(tmp, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def _set_aside(path, suffix):
    """Rename PATH to <stem><suffix>.csv next to it; return the new name."""
    stem = path[:-4] if path.lower().endswith(".csv") else path
    target = "%s%s.csv" % (stem, suffix)
    n = 1
    while os.path.exists(target):
        n += 1
        target = "%s%s-%d.csv" % (stem, suffix, n)
    os.replace(path, target)
    return target


def write_subject_csv(root, subject_id, project_id, project_name, columns, rows):
    """Write one subject's CSV for one project. Returns a status dict:
    {"status": "written" | "unchanged" | "pending" | "conflict", "path": relative path,
     "set_aside": [names of files moved out of the way], "message": text}.
    """
    rel = relative_path(project_name, subject_id)
    key = "%s\x1f%s" % (subject_id, project_id)
    data = render_csv(columns, rows)
    digest = hashlib.sha256(data).hexdigest()
    path = os.path.join(root, *rel.split("/"))
    set_aside = []
    with _key_lock(key), _manifest_lock:
        manifest = load_manifest(root)
        files = manifest["files"]
        # The same path already belongs to another subject or project: two
        # names that differ only in letter case, which are one file on Windows.
        for other_rel, info in files.items():
            if other_rel.lower() == rel.lower() and \
                    (info.get("subject_id"), info.get("project_id")) != (subject_id, str(project_id)):
                return {"status": "conflict", "path": rel, "set_aside": [],
                        "message": "%s is already the CSV of subject %s in project %s; names "
                                   "that differ only in letter case cannot both have a file"
                                   % (other_rel, info.get("subject_id"), info.get("project_id"))}
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            # This subject and project had a file at another path (the project
            # was renamed): move it into _moved/.
            for old_rel, info in list(files.items()):
                if old_rel != rel and (info.get("subject_id"), info.get("project_id")) \
                        == (subject_id, str(project_id)):
                    old_path = os.path.join(root, *old_rel.split("/"))
                    if os.path.exists(old_path):
                        dest = os.path.join(root, MOVED_DIR, _stamp(), *old_rel.split("/"))
                        os.makedirs(os.path.dirname(dest), exist_ok=True)
                        os.replace(old_path, dest)
                        set_aside.append(os.path.relpath(dest, root).replace(os.sep, "/"))
                    del files[old_rel]
            if os.path.exists(path):
                current = _sha256_file(path)
                known = files.get(rel, {}).get("sha256")
                if current == digest:
                    if known != digest or set_aside:
                        files[rel] = {"subject_id": subject_id, "project_id": str(project_id),
                                      "sha256": digest,
                                      "written_at": files.get(rel, {}).get("written_at")}
                        _save_manifest(root, manifest)
                    return {"status": "unchanged", "path": rel, "set_aside": set_aside,
                            "message": ""}
                if current != known:
                    # Edited since it was written, or not written by us.
                    moved = _set_aside(path, ".edited-" + _stamp())
                    set_aside.append(os.path.relpath(moved, root).replace(os.sep, "/"))
            _atomic_write(path, data)
        except OSError as exc:
            if set_aside:
                _save_manifest(root, manifest)
            return {"status": "pending", "path": rel, "set_aside": set_aside,
                    "message": "the file could not be written (%s); it is retried later"
                               % (exc.strerror or exc.__class__.__name__)}
        files[rel] = {"subject_id": subject_id, "project_id": str(project_id), "sha256": digest,
                      "written_at": _dt.datetime.now(_dt.timezone.utc).isoformat()}
        _save_manifest(root, manifest)
    return {"status": "written", "path": rel, "set_aside": set_aside, "message": ""}


def export_subject(conn, root, subject_id, project_id, time_zone=None):
    """Read one subject's entries in one project and write its CSV."""
    project_name, columns, rows = read_subject_project(conn, subject_id, project_id, time_zone)
    return write_subject_csv(root, subject_id, project_id, project_name, columns, rows)


def stale_entries(conn, root):
    """Manifest paths whose subject no longer has a form in that project (the
    subject was renamed, or the project removed)."""
    with _manifest_lock:
        files = load_manifest(root)["files"]
    with conn.transaction():
        cur = conn.cursor()
        cur.execute("SELECT DISTINCT subject_id, project_id::text FROM lab.subject_form")
        live = {(r[0], r[1]) for r in cur.fetchall()}
    return [rel for rel, info in files.items()
            if (info.get("subject_id"), info.get("project_id")) not in live]


def move_stale(root, rels):
    """Move the files at manifest paths RELS into _moved/ and forget them."""
    moved = []
    with _manifest_lock:
        manifest = load_manifest(root)
        stamp = _stamp()
        for rel in rels:
            path = os.path.join(root, *rel.split("/"))
            if os.path.exists(path):
                dest = os.path.join(root, MOVED_DIR, stamp, *rel.split("/"))
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                os.replace(path, dest)
                moved.append(os.path.relpath(dest, root).replace(os.sep, "/"))
            manifest["files"].pop(rel, None)
        _save_manifest(root, manifest)
    return moved
