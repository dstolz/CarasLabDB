#!/usr/bin/env python3
"""Generate lab-dashboard-live.html from the offline demo.

The live page reuses the offline demo's markup, CSS and render/drill-down logic
verbatim; only the data source differs. Rather than maintaining a second 1500-
line copy by hand, this script derives the live page from
`web/lab-dashboard.html` by:

  * replacing the synthetic-data `<script>` with a loader that fetches
    `/api/data` and assigns the result to `window.LAB_DATA`;
  * wrapping the app IIFE as `window.__initDashboard` so it boots only after
    the data has arrived;
  * swapping the "synthetic sample data" chrome for live-mode chrome (status
    badge, banner, how-it-works panel, loading/error overlay).

The offline demo (`web/lab-dashboard.html`) is left untouched. Re-run this
whenever the demo's app logic changes:

    python web/live/build_live_page.py
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "lab-dashboard.html"))
DST = os.path.join(HERE, "lab-dashboard-live.html")

with io.open(SRC, "r", encoding="utf-8", newline="") as fh:
    t = fh.read().replace("\r\n", "\n")

orig_len = len(t)


def must_replace(text, old, new, what):
    if text.count(old) < 1:
        sys.exit("ANCHOR NOT FOUND: %s" % what)
    return text.replace(old, new, 1)


# ---- 1. app IIFE open -> named init function -----------------------------
t = must_replace(
    t,
    '(function(){\n  "use strict";\n  const D = window.LAB_DATA;',
    'window.__initDashboard = function(){\n  "use strict";\n  const D = window.LAB_DATA;',
    "app-open",
)

# ---- 2. replace the whole synthetic generator <script> with the loader ----
gen_marker = "Synthetic data generator"
gi = t.find(gen_marker)
if gi < 0:
    sys.exit("ANCHOR NOT FOUND: synthetic marker")
s_open = t.rfind("<script>", 0, gi)
wld = t.find("window.LAB_DATA = {", gi)
end = t.find("})();\n</script>", wld)
if s_open < 0 or wld < 0 or end < 0:
    sys.exit("ANCHOR NOT FOUND: synthetic bounds")
end += len("})();\n</script>")

LOADER = '''<script>
/* ============================================================================
   Live data loader — fetches the LAB_DATA payload from /api/data (which runs
   web/live/lab_data.sql against the live Postgres database), then boots the
   dashboard. This replaces the synthetic generator used by the offline demo;
   the render code below is otherwise identical.
   ============================================================================ */
(function(){
  "use strict";
  const overlay = document.getElementById('boot-overlay');
  const badge = document.getElementById('live-status');
  const badgeText = document.getElementById('live-status-text');

  function setBadge(state, text){
    if(badge){ badge.classList.remove('ok','err','loading'); badge.classList.add(state); }
    if(badgeText) badgeText.textContent = text;
  }
  function showOverlay(html){ if(overlay){ overlay.innerHTML = html; overlay.style.display = 'flex'; } }
  function hideOverlay(){ if(overlay) overlay.style.display = 'none'; }

  function boot(){
    setBadge('loading', 'Connecting\\u2026');
    showOverlay('<div class="boot-card"><div class="boot-spin"></div>' +
                '<div>Loading data from the database\\u2026</div></div>');
    fetch('api/data', {headers:{'Accept':'application/json'}})
      .then(r => r.json().then(j => ({ok:r.ok, status:r.status, body:j})))
      .then(res => {
        if(!res.ok || (res.body && res.body.error)){
          const msg = (res.body && res.body.detail) || (res.body && res.body.error) || ('HTTP ' + res.status);
          throw new Error(msg);
        }
        window.LAB_DATA = res.body;
        hideOverlay();
        setBadge('ok', 'Live database');
        window.__initDashboard();
      })
      .catch(err => {
        setBadge('err', 'Database unavailable');
        showOverlay('<div class="boot-card err">' +
          '<div class="boot-title">Could not load data</div>' +
          '<div class="boot-msg"></div>' +
          '<button class="boot-retry">Retry</button>' +
          '<div class="boot-hint">The server could not read the database. Check that Postgres is ' +
          'running, the <code>lab</code> schema is applied, and the <code>PG*</code> connection ' +
          'environment variables are set. See <code>web/live/README.md</code>.</div>' +
          '</div>');
        const m = overlay.querySelector('.boot-msg'); if(m) m.textContent = String(err.message || err);
        const b = overlay.querySelector('.boot-retry'); if(b) b.onclick = boot;
      });
  }

  const rb = document.getElementById('btn-refresh');
  if(rb) rb.onclick = () => location.reload();

  boot();
})();
</script>'''

t = t[:s_open] + LOADER + t[end:]

# ---- 3. app IIFE close -> end the init function assignment ----------------
ci = t.rfind("})();\n</script>")
if ci < 0:
    sys.exit("ANCHOR NOT FOUND: app-close")
t = t[:ci] + "};\n</script>" + t[ci + len("})();\n</script>"):]

# ---- 4. as-of label derives from the live NOW ----------------------------
t = must_replace(
    t,
    "  const asof=new Date(NOW).toLocaleString(undefined,{day:'numeric',month:'short',year:'numeric',hour:'numeric',minute:'2-digit'});",
    "  const asof=new Date(D.NOW).toLocaleString(undefined,{day:'numeric',month:'short',year:'numeric',hour:'numeric',minute:'2-digit'});",
    "asof",
)

# ---- 5. header badge: synthetic -> live status ---------------------------
t = must_replace(
    t,
    '<div class="sample-badge"><span class="dot"></span> Synthetic sample data</div>',
    '<div class="sample-badge live loading" id="live-status"><span class="dot"></span> '
    '<span id="live-status-text">Connecting…</span></div>',
    "badge",
)

# ---- 6. banner -----------------------------------------------------------
old_banner = t[t.find('  <div class="banner">'): t.find('</div>', t.find('  <div class="banner">')) + len('</div>')]
NEW_BANNER = ('  <div class="banner">\n'
    '    <span><b>Live view:</b> reading the <code style="background:rgba(0,0,0,.05);padding:1px 5px;border-radius:4px">lab</code> '
    'schema through <code style="background:rgba(0,0,0,.05);padding:1px 5px;border-radius:4px">/api/data</code>. '
    'Full history is loaded; use <b>Active only</b> to hide superseded rows.</span>\n'
    '    <span><span class="link" id="btn-refresh">↻ Refresh</span> &nbsp;·&nbsp; '
    '<span class="link" id="open-howto">How does this work? →</span></span>\n'
    '  </div>')
t = must_replace(t, old_banner, NEW_BANNER, "banner")

# ---- 7. howto details block ----------------------------------------------
hi = t.find('  <details class="howto" id="howto">')
he = t.find('</details>', hi) + len('</details>')
if hi < 0 or he < len('</details>'):
    sys.exit("ANCHOR NOT FOUND: howto")
NEW_HOWTO = '''  <details class="howto" id="howto">
    <summary><span class="chev">▶</span> How the live dashboard works</summary>
    <div class="howto-body">
      <p>This page is served by <code>web/live/server.py</code>. On load it fetches
      <code>/api/data</code>, which runs <code>web/live/lab_data.sql</code> against the live
      PostgreSQL database and returns every table as one JSON object (the same
      <code>window.LAB_DATA</code> shape the offline demo builds synthetically). The
      rendering, filtering and drill-down code is identical to the offline demo.</p>
      <p>Full history is returned — superseded rows included — and active vs.
      superseded state is derived client-side from the <code>supersedes</code> links,
      exactly like the <code>lab.event_active</code> / <code>lab.artifact_active</code> views.
      Hit <b>↻ Refresh</b> to re-query the database.</p>
      <p>Run it from the repo root (with the schema applied to database <code>lab</code>):</p>
      <pre>PGDATABASE=lab python web/live/server.py --port 8778
# then open http://127.0.0.1:8778/</pre>
      <p>Connection settings come from the standard libpq environment variables
      (<code>PGHOST</code>, <code>PGPORT</code>, <code>PGDATABASE</code>,
      <code>PGUSER</code>, <code>PGPASSWORD</code>). Data access uses
      <code>psycopg</code>/<code>psycopg2</code> if installed, otherwise the
      <code>psql</code> CLI. See <code>web/live/README.md</code> for details.</p>
    </div>
  </details>'''
t = t[:hi] + NEW_HOWTO + t[he:]

# ---- 8. title + footer wording -------------------------------------------
t = must_replace(t,
    "<title>Lab Metadata Explorer — Caras Lab</title>",
    "<title>Lab Metadata Explorer (Live) — Caras Lab</title>", "title")
t = must_replace(t, "· self-contained &amp; offline ·",
    "· live database view ·", "footer")

# ---- 9. CSS additions before </style> ------------------------------------
CSS = '''
  /* -------- live-mode additions -------- */
  .sample-badge.live{color:#8ee6a8;background:rgba(31,157,85,.14);border-color:rgba(31,157,85,.4);}
  .sample-badge.live.loading{color:#ffd479;background:rgba(217,140,0,.14);border-color:rgba(217,140,0,.35);}
  .sample-badge.live.err{color:#ff9b9b;background:rgba(220,53,69,.16);border-color:rgba(220,53,69,.4);}
  .sample-badge.live .dot{background:#3ddc84;box-shadow:0 0 0 3px rgba(61,220,132,.18);}
  .sample-badge.live.loading .dot{background:#ffbb33;box-shadow:0 0 0 3px rgba(255,187,51,.18);}
  .sample-badge.live.err .dot{background:#ff5b5b;box-shadow:0 0 0 3px rgba(255,91,91,.18);}
  #boot-overlay{position:fixed;inset:0;background:rgba(238,241,246,.92);backdrop-filter:blur(2px);display:none;align-items:center;justify-content:center;z-index:200;}
  .boot-card{background:var(--bg-card);border:1px solid var(--border);border-radius:14px;box-shadow:0 24px 60px rgba(0,0,0,.18);padding:26px 30px;max-width:460px;text-align:center;font-size:14px;color:var(--text-primary);}
  .boot-card .boot-title{font-size:16px;font-weight:680;margin-bottom:8px;}
  .boot-card.err .boot-title{color:var(--negative);}
  .boot-msg{font-family:ui-monospace,monospace;font-size:12px;color:var(--negative);background:rgba(220,53,69,.08);border-radius:8px;padding:8px 10px;margin:8px 0;word-break:break-word;text-align:left;}
  .boot-hint{font-size:12px;color:var(--text-secondary);margin-top:10px;line-height:1.6;}
  .boot-hint code{background:#f0f3f8;padding:1px 5px;border-radius:5px;}
  .boot-retry{margin-top:12px;padding:8px 18px;border-radius:8px;border:none;background:var(--bg-header);color:#fff;font-size:13px;font-weight:600;cursor:pointer;font-family:inherit;}
  .boot-spin{width:34px;height:34px;border:3px solid var(--border-strong);border-top-color:var(--accent);border-radius:50%;margin:0 auto 14px;animation:boot-rot .8s linear infinite;}
  @keyframes boot-rot{to{transform:rotate(360deg)}}
</style>'''
t = must_replace(t, "</style>", CSS, "css")

# ---- 10. boot overlay element right after <body> -------------------------
t = must_replace(t, "<body>\n", '<body>\n<div id="boot-overlay"></div>\n', "overlay")

with io.open(DST, "w", encoding="utf-8", newline="") as fh:
    fh.write(t.replace("\n", "\r\n"))

# sanity checks
checks = {
    "single initDashboard def": t.count("window.__initDashboard = function(){") == 1,
    "initDashboard call": "window.__initDashboard();" in t,
    "app ends as function assignment": t.count("};\n</script>") >= 1,
    "no synthetic generator": "Synthetic data generator" not in t,
    "no mulberry PRNG": "mulberry32" not in t,
    "loader fetches api/data": "fetch('api/data'" in t,
    "one boot overlay": t.count('id="boot-overlay"') == 1,
    "open-howto kept (used by app js)": 'id="open-howto"' in t,
    "refresh button": 'id="btn-refresh"' in t,
    "live status badge": 'id="live-status"' in t,
}
print("wrote %s (%d -> %d bytes)" % (DST, orig_len, len(t)))
for k, v in checks.items():
    print(("  OK   " if v else "  FAIL ") + k)
if not all(checks.values()):
    sys.exit(1)
