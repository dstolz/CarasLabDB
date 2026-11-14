#!/usr/bin/env python3
"""End-to-end check of web/forms/server.py against a scratch database.

Run as a superuser (it creates two throw-away logins) against a database
that has schema.sql and grants.sql applied and that this check may write to
(it commits rows; use a throw-away database):

    createdb lab_forms
    psql -X -q -d lab_forms -f design_docs/schema.sql -f design_docs/grants.sql
    PGDATABASE=lab_forms python tests/check_forms_server.py

Starts the server in this process on a free port with a temporary CSV root
and drives its HTTP API as a browser would: sign-in (and its refusals),
the request checks, publishing templates, putting them to use for a subject
in two projects, entries, a replay and a conflicting replay, a correction, a
note change and a withdrawal. After each change it compares the subject's
CSV with the file expected from the database, byte for byte, and it checks
what happens when the file is locked (as Excel locks it) and when someone
has edited it. Exits non-zero on the first problem.
"""
import csv
import http.cookiejar
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
FORMS = os.path.join(HERE, "..", "web", "forms")
sys.path.insert(0, FORMS)

import psycopg  # noqa: E402

import csv_export  # noqa: E402
import server  # noqa: E402

TZ = "America/New_York"


def fail(msg):
    sys.exit("check_forms_server: " + msg)


def check(ok, msg):
    if not ok:
        fail(msg)


tag = uuid.uuid4().hex[:8]
member, reader = "fc_member_" + tag, "fc_reader_" + tag
password = "pw-" + uuid.uuid4().hex
admin = psycopg.connect(autocommit=True)
admin.execute("SET TimeZone = '%s'" % TZ)


def sql(q, params=()):
    cur = admin.execute(q, params)
    return cur.fetchall() if cur.description else None


# --------------------------------------------------------------------------
# Fixtures: two projects, a subject, its weight, baseline and a tag; a member
# login mapped to a person, and a read-only login.
# --------------------------------------------------------------------------
sql("CREATE ROLE %s LOGIN PASSWORD '%s' IN ROLE lab_rw" % (member, password))
sql("CREATE ROLE %s LOGIN PASSWORD '%s' IN ROLE lab_ro" % (reader, password))
person = sql("INSERT INTO lab.person (full_name, db_login) VALUES (%s, %s) RETURNING person_id",
             ("Forms Checker " + tag, member))[0][0]
p1 = sql("INSERT INTO lab.project (name, description) VALUES (%s, 'first') RETURNING project_id",
         ("Forms check " + tag,))[0][0]
p2 = sql("INSERT INTO lab.project (name) VALUES (%s) RETURNING project_id",
         ("Forms/check: other " + tag,))[0][0]
subject = "FC-" + tag
sql("INSERT INTO lab.subject (subject_id, project_id, species_code, sex, strain, date_of_birth) "
    "VALUES (%s, %s, 'meriones_unguiculatus', 'F', 'wild type', '2026-01-02')", (subject, p1))
ev = sql("INSERT INTO lab.event (event_type, subject_id, occurred_at) "
         "VALUES ('husbandry', %s, '2026-11-13 08:00-05') RETURNING event_id", (subject,))[0][0]
sql("INSERT INTO lab.husbandry_event (event_id, measure, weight_g) VALUES (%s, 'weight', 61.5)",
    (ev,))
sql("SELECT lab.fn_set_variable('subject', %s, 'baseline weight', 70.0, p_units => 'g')",
    (subject,))
sql("SELECT lab.fn_tag('subject', %s, 'topic:forms_check')", (subject,))

csv_root = tempfile.mkdtemp(prefix="forms-check-")


def start(secure):
    app = server.App(csv_root, [], secure, 30.0, 12.0, TZ)
    httpd = server.make_server(app, "127.0.0.1", 0)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return app, httpd, "http://127.0.0.1:%d" % httpd.server_address[1]


app, httpd, base = start(False)
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def call(method, path, body=None, headers=None, raw=None, client=opener, origin=None):
    """(status, decoded JSON or text, response headers)."""
    h = {"X-CarasLab-Forms": "1", "Origin": origin or base, "Content-Type": "application/json"}
    if headers is not None:
        h = headers
    data = raw if raw is not None else (None if body is None else json.dumps(body).encode())
    req = urllib.request.Request(base + path, data=data, method=method, headers=h)
    try:
        with client.open(req, timeout=30) as resp:
            status, text, hdrs = resp.status, resp.read().decode("utf-8"), resp.headers
    except urllib.error.HTTPError as exc:
        status, text, hdrs = exc.code, exc.read().decode("utf-8"), exc.headers
    try:
        return status, json.loads(text), hdrs
    except ValueError:
        return status, text, hdrs


def ok(method, path, body=None):
    status, out, _ = call(method, path, body)
    check(status == 200, "%s %s answered %s: %r" % (method, path, status, out))
    return out


# --------------------------------------------------------------------------
# The page, sign-in and the request checks.
# --------------------------------------------------------------------------
status, page, hdrs = call("GET", "/", headers={})
check(status == 200 and "<title>" in page, "GET / did not serve the page")
check("default-src 'self'" in hdrs.get("Content-Security-Policy", "")
      and hdrs.get("X-Frame-Options") == "DENY", "the page lacks its security headers")
status, _, _ = call("GET", "/server.py", headers={})
check(status == 404, "a source file is served")
status, out, _ = call("GET", "/api/forms", headers={})
check(status == 401 and out.get("signed_out"), "an API read without a session is not 401")

status, out, _ = call("POST", "/api/login", {"login": member, "password": "wrong"})
check(status == 401, "a wrong password is not refused with 401: %s %r" % (status, out))
status, out, _ = call("POST", "/api/login", {"login": member, "password": ""})
check(status == 400, "an empty password is not refused")
status, out, _ = call("POST", "/api/login", {"login": reader, "password": password})
check(status == 403 and "lab_rw" in out["error"], "a read-only login may sign in: %r" % out)
status, out, hdrs = call("POST", "/api/login", {"login": member, "password": password},
                         headers={"Content-Type": "application/json", "Origin": base})
check(status == 403, "a POST without X-CarasLab-Forms is accepted")
status, out, hdrs = call("POST", "/api/login", {"login": member, "password": password},
                         origin="https://elsewhere.example")
check(status == 403, "a POST from another origin is accepted")
status, out, hdrs = call("POST", "/api/login", {"login": member, "password": password})
check(status == 200 and out["login"] == member and str(out["person_id"]) == str(person),
      "the member cannot sign in: %s %r" % (status, out))
cookie = hdrs.get("Set-Cookie", "")
check("HttpOnly" in cookie and "SameSite=Strict" in cookie and "Path=/" in cookie,
      "the session cookie lacks its flags: %s" % cookie)
check(password not in json.dumps(out), "the password is echoed")
status, out, _ = call("POST", "/api/login", raw=b'{"login": "x", "password": 1.5}')
check(status == 400 and "send values as text" in out["error"],
      "a JSON number with a fraction is not refused")

# The Secure variant, as deployed behind HTTPS.
_, httpd2, base2 = start(True)
req = urllib.request.Request(base2 + "/api/login", method="POST",
                             data=json.dumps({"login": member, "password": password}).encode(),
                             headers={"X-CarasLab-Forms": "1", "Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=30) as resp:
    secure_cookie = resp.headers.get("Set-Cookie", "")
check(secure_cookie.startswith("__Host-caraslab-forms=") and "Secure" in secure_cookie,
      "the deployed cookie is not a Secure __Host- cookie: %s" % secure_cookie)
httpd2.shutdown()

# --------------------------------------------------------------------------
# Templates and subject forms.
# --------------------------------------------------------------------------
depth, side, ok_var, remark = ("fc depth " + tag, "fc side " + tag, "fc ok " + tag,
                               "fc remark " + tag)
form1 = "fc daily " + tag
definition = {"format": 1,
              "header": [{"item": "species"}, {"item": "latest_weight"},
                         {"variable": "baseline weight", "source": "subject"},
                         {"variable": depth, "source": "previous_entry"}],
              "sections": [{"title": "Recording", "fields": [
                  {"widget": "number", "variable": depth, "label": "Probe depth", "units": "um",
                   "required": True, "min": "0", "max": "6000", "show_previous": True},
                  {"widget": "choice", "variable": side,
                   "options": [{"value": "L", "label": "Left"}, {"value": "R", "label": "Right"}]},
                  {"widget": "yesno", "variable": ok_var, "required": True},
                  {"widget": "longtext", "variable": remark}]}]}
out = ok("POST", "/api/form/validate", {"definition": {"format": 1, "sections": []}})
check(out["problems"] and "at least one section" in out["problems"][0]["problem"],
      "validate does not report problems: %r" % out)
out = ok("POST", "/api/form/validate", {"definition": definition})
check(out["problems"] == [], "the template has problems: %r" % out)
out = ok("POST", "/api/form/publish", {"name": form1, "label": "FC daily", "definition": definition,
                                       "note": "first"})
check(out == {"name": form1, "version": 1, "is_new": True}, "publish answered %r" % out)
out = ok("POST", "/api/form/publish", {"name": form1, "definition": definition})
check(out["version"] == 1 and out["is_new"] is False, "a republish made a new version")
status, out, _ = call("POST", "/api/form/publish", {"name": form1, "definition": {"format": 1}})
check(status == 422, "an invalid template is not refused with 422: %s %r" % (status, out))
form2 = "fc second " + tag
ok("POST", "/api/form/publish", {"name": form2, "definition": {"format": 1, "sections": [
    {"fields": [{"widget": "text", "variable": side.replace("side", "booth")},
                {"widget": "number", "variable": depth, "units": "um"}]}]}})
forms = {f["name"]: f for f in ok("GET", "/api/forms")["forms"]}
check(forms[form1]["latest_version"] == 1 and forms[form1]["label"] == "FC daily",
      "the template list is wrong: %r" % forms.get(form1))
out = ok("GET", "/api/form?name=" + urllib.request.quote(form1))
check(out["version"] == 1 and out["definition"] == definition
      and out["variables"][depth]["units"] == "um",
      "the template does not come back as published: %r" % out)

found = ok("GET", "/api/subjects?q=" + subject)["subjects"]
check([s["subject_id"] for s in found] == [subject], "subject search: %r" % found)
sf1 = ok("POST", "/api/subject-form/add", {"subject_id": subject, "form_name": form1})
sf1 = sf1["subject_form_id"]
check(ok("POST", "/api/subject-form/add",
         {"subject_id": subject, "form_name": form1})["subject_form_id"] == sf1,
      "adding a template twice made a second subject form")
sf2 = ok("POST", "/api/subject-form/add", {"subject_id": subject, "form_name": form2})
sf2 = sf2["subject_form_id"]
sf3 = ok("POST", "/api/subject-form/add", {"subject_id": subject, "form_name": form1,
                                           "project_id": str(p2)})["subject_form_id"]
listed = ok("GET", "/api/subject?subject=" + subject)["subject_forms"]
check(sorted(str(f["subject_form_id"]) for f in listed) == sorted([sf1, sf2, sf3]),
      "the subject's forms are not listed: %r" % listed)

ctx = ok("GET", "/api/context?subject_form=" + sf1)
check(ctx["subject"]["species"] == "Mongolian gerbil" and ctx["subject"]["sex"] == "F"
      and ctx["subject"]["latest_weight_g"] == "61.5"
      and ctx["subject_variables"]["baseline weight"]["value"] == "70.0"
      and ctx["subject_tags"] == ["topic:forms_check"]
      and ctx["previous_entry"] is None and ctx["form"]["version"] == 1,
      "the subject context is wrong: %r" % {k: ctx[k] for k in ("subject", "subject_variables")})

# --------------------------------------------------------------------------
# Entries and the CSV.
# --------------------------------------------------------------------------
def expected_csv(project_id):
    """The CSV built independently from the database (as the superuser)."""
    pname = sql("SELECT name FROM lab.project WHERE project_id = %s", (project_id,))[0][0]
    cols = sql("SELECT variable, units FROM lab.fn_subject_project_columns(%s, %s) "
               "ORDER BY column_no", (subject, project_id))
    rows = sql("""SELECT oa.entry_id, oa.event_id, oa.form_name, oa.form_version, oa.session_label,
                         oa.occurred_at, oa.recorded_at, p.full_name, oa.recorded_login,
                         oa.supersedes IS NOT NULL, oa.note, oa.field_values::text
                  FROM lab.observation_active oa LEFT JOIN lab.person p ON p.person_id = oa.recorded_by
                  WHERE oa.subject_id = %s AND oa.project_id = %s
                  ORDER BY oa.occurred_at, oa.entry_id""", (subject, project_id))
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\r\n")
    w.writerow(list(csv_export.META_COLUMNS) + [v if not u else "%s (%s)" % (v, u) for v, u in cols])
    for r in rows:
        vals = json.loads(r[11])
        w.writerow([str(r[0]), str(r[1]), subject, pname, r[2], str(r[3]), r[4],
                    r[5].isoformat(), r[6].isoformat(), r[7] or "", r[8] or "",
                    "yes" if r[9] else "no", r[10] or ""] + [vals.get(v, "") for v, _ in cols])
    rel = "%s/%s.csv" % (csv_export.sanitize_component(pname), csv_export.sanitize_component(subject))
    return rel, b"\xef\xbb\xbf" + buf.getvalue().encode("utf-8")


def check_csv(project_id, what):
    rel, want = expected_csv(project_id)
    path = os.path.join(csv_root, *rel.split("/"))
    check(os.path.exists(path), "%s: %s was not written" % (what, rel))
    with open(path, "rb") as fh:
        got = fh.read()
    check(got == want, "%s: %s differs from the database:\n%s\n--- expected ---\n%s"
          % (what, rel, got.decode("utf-8", "replace"), want.decode("utf-8")))
    return rel, got


e1, e2, e3, e4 = (str(uuid.uuid4()) for _ in range(4))
entry1 = {"event_id": e1, "subject_form_id": sf1, "occurred_at": "2026-11-14T14:30:00.000Z",
          "session_label": "2026-11-14 09:30",
          "values": {depth: "1350.50", side: "L", ok_var: "yes", remark: "two\nlines, \"quoted\""},
          "note": "Bright and alert.", "entered_at": "2026-11-14T14:31:00.000Z"}
out = ok("POST", "/api/entry/submit", entry1)
check(out["outcome"] == "inserted" and out["csv"]["status"] == "written",
      "the entry was not stored and written: %r" % out)
rel1, _ = check_csv(p1, "after the first entry")
check(rel1 == "Forms check %s/%s.csv" % (tag, subject), "unexpected CSV path %s" % rel1)
check(sql("SELECT recorded_login, recorded_by, attributes->>'client', attributes->>'entered_at' "
          "FROM lab.event WHERE event_id = %s", (e1,))[0]
      == (member, person, "caraslabdb-forms", "2026-11-14T14:31:00.000Z"),
      "the entry does not carry the member's login and person")
check(sql("SELECT value_num::text FROM lab.variable_value WHERE event_id = %s AND variable = %s",
          (e1, depth))[0][0] == "1350.50", "the number was not stored as typed")

# The same entry again (a replay after a lost reply) is "existing"; changed, a conflict.
out = ok("POST", "/api/entry/submit", entry1)
check(out["outcome"] == "existing", "a replay is not 'existing': %r" % out)
status, out, _ = call("POST", "/api/entry/submit", dict(entry1, values={depth: "1351", ok_var: "yes"}))
check(status == 409 and out["code"] == "CLB01", "a changed replay is not a 409 conflict: %r" % out)
status, out, _ = call("POST", "/api/entry/submit",
                      dict(entry1, event_id=str(uuid.uuid4()), values={depth: 1350, ok_var: "yes"}))
check(status == 422 and any("must be sent as text" in p["problem"] for p in out["problems"]),
      "a JSON number value is not refused: %s %r" % (status, out))
status, out, _ = call("POST", "/api/entry/submit",
                      dict(entry1, event_id=str(uuid.uuid4()), values={depth: "1.35e3", ok_var: ""}))
check(status == 422 and {p["field"] for p in out["problems"]} == {depth, ok_var},
      "bad values are not reported field by field: %r" % out)
status, out, _ = call("POST", "/api/entry/submit",
                      dict(entry1, event_id=str(uuid.uuid4()), occurred_at="2026-11-14T09:30"))
check(status == 400 and "UTC offset" in out["error"], "an unzoned time is accepted")
status, out, _ = call("POST", "/api/entry/check",
                      {"form_name": form1, "form_version": 1, "values": {depth: "-1"}})
check(status == 200 and {p["field"] for p in out["problems"]} == {depth, ok_var},
      "entry/check: %r" % out)

# A second entry, the first corrected, the note changed, the second withdrawn.
ok("POST", "/api/entry/submit", {"event_id": e2, "subject_form_id": sf1,
                                 "occurred_at": "2026-11-15T14:30:00Z", "session_label": "day 2",
                                 "values": {depth: "1400", ok_var: "no"}})
check_csv(p1, "after the second entry")
out = ok("POST", "/api/entry/submit", dict(entry1, event_id=e3, supersedes=e1,
                                           values={depth: "1375", ok_var: "yes", remark: ""}))
check(out["outcome"] == "inserted", "the correction failed: %r" % out)
rel1, got = check_csv(p1, "after the correction")
rows = list(csv.DictReader(io.StringIO(got.decode("utf-8-sig"))))
check([(r["Entry ID"], r["Event ID"], r["Corrected"]) for r in rows]
      == [(e1, e3, "yes"), (e2, e2, "no")], "the corrected row is not the current version")
out = ok("POST", "/api/entry/note", {"event_id": e3, "note": "Bright; ate well."})
check(out["outcome"] == "set" and out["csv"]["status"] == "written", "note change: %r" % out)
check_csv(p1, "after the note change")
out = ok("POST", "/api/entry/note", {"event_id": e3, "note": "Bright; ate well."})
check(out["outcome"] == "unchanged", "the same note again wrote something")
hist = ok("GET", "/api/note-history?event_id=" + e1)["history"]
check([h["value_text"] for h in hist] == ["Bright and alert.", "Bright; ate well."],
      "the note history is wrong: %r" % hist)
status, out, _ = call("POST", "/api/entry/note", {"event_id": e1, "note": "late"})
check(status == 422 and "corrected" in out["error"], "the note of a corrected entry changed")
ok("POST", "/api/entry/withdraw", {"event_id": e2, "reason": "entered on the wrong subject"})
rel1, got = check_csv(p1, "after the withdrawal")
check(e2 not in got.decode("utf-8"), "the withdrawn entry is still in the CSV")
entries = ok("GET", "/api/entries?subject_form=" + sf1)["entries"]
check([str(e["event_id"]) for e in entries] == [e3] and entries[0]["note"] == "Bright; ate well.",
      "the entry list is wrong: %r" % entries)

# A second template in the same project shares the subject's CSV; the other
# project has its own (with a project name that has to be made file-safe).
ok("POST", "/api/entry/submit", {"event_id": e4, "subject_form_id": sf2,
                                 "occurred_at": "2026-11-16T14:30:00Z", "session_label": "day 3",
                                 "values": {side.replace("side", "booth"): "B2", depth: "1500"}})
rel1, got = check_csv(p1, "after an entry on the second template")
header = got.decode("utf-8-sig").splitlines()[0]
check(header.endswith(",%s (um),%s,%s,%s,%s" % (depth, side, ok_var, remark,
                                                side.replace("side", "booth"))),
      "the shared CSV's columns are not the union, in order: %s" % header)
ok("POST", "/api/entry/submit", {"event_id": str(uuid.uuid4()), "subject_form_id": sf3,
                                 "occurred_at": "2026-11-16T15:30:00Z", "session_label": "p2",
                                 "values": {depth: "10", ok_var: "yes"}})
rel2, _ = check_csv(p2, "the second project's CSV")
check(rel2.startswith("Forms_check_ other %s~" % tag), "unsafe project name not sanitised: %s" % rel2)

# --------------------------------------------------------------------------
# A locked file (Excel), an edited file, the rebuild.
# --------------------------------------------------------------------------
real_write = csv_export._atomic_write


def locked(path, data):
    if path.endswith(".csv"):
        raise PermissionError(13, "The process cannot access the file")
    return real_write(path, data)


csv_export._atomic_write = locked
try:
    out = ok("POST", "/api/entry/note", {"event_id": e3, "note": "While the file was open."})
finally:
    csv_export._atomic_write = real_write
check(out["outcome"] == "set" and out["csv"]["status"] == "pending",
      "a locked CSV did not leave the change stored and the file pending: %r" % out)
check((subject, str(p1)) in app.pending_csv(), "the locked file is not queued for a retry")
app.retry_pending()
check((subject, str(p1)) not in app.pending_csv(), "the retry did not clear the queue")
check_csv(p1, "after the retry")

path1 = os.path.join(csv_root, *rel1.split("/"))
with open(path1, "ab") as fh:
    fh.write(b"typed in by hand\r\n")
ok("POST", "/api/entry/note", {"event_id": e3, "note": "After the hand edit."})
check_csv(p1, "after a hand-edited file")
aside = [n for n in os.listdir(os.path.dirname(path1)) if ".edited-" in n]
check(len(aside) == 1, "the hand-edited file was not set aside: %r" % os.listdir(os.path.dirname(path1)))
with open(os.path.join(os.path.dirname(path1), aside[0]), "rb") as fh:
    check(fh.read().endswith(b"typed in by hand\r\n"), "the set-aside file lost the hand edit")

env = dict(os.environ)
proc = subprocess.run([sys.executable, os.path.join(FORMS, "server.py"), "--csv-root", csv_root,
                       "--csv-time-zone", TZ, "--rebuild-csv"],
                      capture_output=True, text=True, env=env)
check(proc.returncode == 0 and "unchanged" in proc.stdout and "written" not in proc.stdout,
      "--rebuild-csv rewrote up-to-date files or failed: %s%s" % (proc.stdout, proc.stderr))

# Sanitising names for Windows.
for raw, want in [("ok name", "ok name"), ("G-0421", "G-0421")]:
    check(csv_export.sanitize_component(raw) == want, "sanitize %r" % raw)
for raw, prefix in [("CON", "_CON~"), ("nul.txt", "_nul.txt~"), ("a/b", "a_b~"), ("end. ", "end~"),
                    ("x" * 100, "x" * 80 + "~")]:
    got = csv_export.sanitize_component(raw)
    check(got.startswith(prefix) and len(got) == len(prefix) + 8, "sanitize %r gave %r" % (raw, got))
check(csv_export.sanitize_component("a/b") != csv_export.sanitize_component("a\\b"),
      "two names sanitise to one")

# Sign-out ends the session.
ok("POST", "/api/logout", {})
status, _, _ = call("GET", "/api/forms")
check(status == 401, "the session survived sign-out")

httpd.shutdown()
shutil.rmtree(csv_root, ignore_errors=True)
# The logins own nothing and may go; their names stay in the rows they wrote.
sql("UPDATE lab.person SET db_login = NULL WHERE person_id = %s", (person,))
sql("DROP ROLE %s" % member)
sql("DROP ROLE %s" % reader)
print("check_forms_server: OK (sign-in, templates, subject forms, entries, corrections, notes, "
      "withdrawal and the CSV files)")
