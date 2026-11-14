# Forms (`web/forms/`)

This is the browser tool for entering one session of one subject on a form,
and for building the form templates. Entries are written to the database
under each member's own login. A CSV file per subject per project is kept up
to date beside them.

**Read [design_docs/forms.md](../../design_docs/forms.md) first.** It covers
the concepts, how to use the tool, the value rules, the CSV files, the
offline outbox, security and the reference. The deployment is in
[design_docs/deployment-windows.md](../../design_docs/deployment-windows.md)
§3.6.

| File | |
|---|---|
| `server.py` | Standard-library HTTP server: the page, and a JSON API over the SQL write paths (`lab.fn_publish_form`, `lab.fn_add_subject_form`, `lab.fn_record_observation`, `lab.fn_set_entry_note`, `lab.fn_retract`). It holds one database connection per signed-in browser session. Needs psycopg 3. |
| `csv_export.py` | Rewrites a subject's CSV for a project from the database: atomic replace, hand-edited files set aside, `_manifest.json`. |
| `forms.html`, `forms.js`, `forms.css` | The page. No external resources, no inline script, and the outbox kept in IndexedDB. |

```bash
PGDATABASE=lab_dev python web/forms/server.py --csv-root /tmp/forms-csv --insecure-cookie
# http://127.0.0.1:8779/
```

Without `--insecure-cookie`, the session cookie is `Secure` and only works
over HTTPS, which is how it is deployed behind the proxy.
`tests/check_forms_server.py` is the end-to-end check that CI runs.
