/* Caras Lab session forms (design_docs/forms.md).
 *
 * One page: sign in, pick a subject, pick (or add) one of its forms, fill it
 * in for a session, save. Templates are built on the Templates tab. Every
 * entry is first put in an outbox kept in this browser (IndexedDB) and then
 * sent; it leaves the outbox only when the server has confirmed it, so an
 * unreachable server or a lost reply loses nothing. Sending again is safe:
 * the entry's id is minted here, and the database recognises an entry it
 * already has.
 *
 * Values are kept as the text typed and sent as JSON strings, never as JSON
 * numbers: the database stores that text. Everything typed by a person --
 * here or in a template -- is put on the page with textContent, never as
 * HTML. All URLs are relative, so the page works under a proxy prefix.
 */
(function () {
  "use strict";

  // ---------------------------------------------------------------- helpers
  const $ = (id) => document.getElementById(id);

  function el(tag, attrs, ...children) {
    const e = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v === null || v === undefined || v === false) continue;
        if (k === "class") e.className = v;
        else if (k === "text") e.textContent = v;
        else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
        else if (k === "dataset") Object.assign(e.dataset, v);
        else if (v === true) e.setAttribute(k, "");
        else e.setAttribute(k, String(v));
      }
    }
    for (const c of children.flat()) {
      if (c === null || c === undefined || c === false) continue;
      e.appendChild(typeof c === "string" || typeof c === "number" ? document.createTextNode(String(c)) : c);
    }
    return e;
  }

  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); return node; }

  const pad2 = (n) => String(n).padStart(2, "0");
  const ZONE = (() => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone || ""; } catch (e) { return ""; } })();

  function parseTs(s) { if (!s) return null; const d = new Date(s); return isNaN(d) ? null : d; }
  function fmtDateTime(s) {
    const d = typeof s === "string" ? parseTs(s) : s;
    if (!d) return s ? String(s) : "—";
    return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  }
  function fmtDate(s) {
    if (!s) return "—";
    if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
    const d = parseTs(s);
    return d ? `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}` : String(s);
  }
  // datetime-local value for a Date, in the browser's zone
  function localInputValue(d) {
    return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}T${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  }
  // "2026-11-14T09:30" (local) -> "2026-11-14T09:30-05:00", the offset of that local time
  function withOffset(localValue) {
    const d = new Date(localValue);
    if (isNaN(d)) return null;
    const off = -d.getTimezoneOffset();
    const sign = off >= 0 ? "+" : "-";
    const a = Math.abs(off);
    return `${localValue.length === 16 ? localValue : localValue.slice(0, 16)}${sign}${pad2(Math.floor(a / 60))}:${pad2(a % 60)}`;
  }
  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    const b = crypto.getRandomValues(new Uint8Array(16));
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
    const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  }
  function lsGet(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : v; } catch (e) { return d; } }
  function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* not kept */ } }
  function download(name, type, text) {
    const url = URL.createObjectURL(new Blob([text], { type }));
    const a = el("a", { href: url, download: name });
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 5000);
  }
  function debounce(fn, ms) { let t = null; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }

  // The value rules of lab.fn_form_value_problem, checked here first so that
  // a mistake is shown at once; the database checks them again.
  const NUM_RE = /^-?(0|[1-9][0-9]*)(\.[0-9]+)?$/;
  const INT_RE = /^-?(0|[1-9][0-9]*)$/;
  function numberOk(v) { return NUM_RE.test(v) && !/^-0(\.0+)?$/.test(v); }
  function cmpDecimal(a, b) { // exact comparison of two plain decimals
    const sa = a.startsWith("-") ? -1 : 1, sb = b.startsWith("-") ? -1 : 1;
    const ua = a.replace(/^-/, ""), ub = b.replace(/^-/, "");
    const isZero = (u) => /^0(\.0+)?$/.test(u);
    if (isZero(ua) && isZero(ub)) return 0;
    if (sa !== sb) return sa < sb ? -1 : 1;
    const [ia, fa = ""] = ua.split("."), [ib, fb = ""] = ub.split(".");
    let c = ia.length !== ib.length ? (ia.length < ib.length ? -1 : 1) : (ia < ib ? -1 : ia > ib ? 1 : 0);
    if (c === 0) { const n = Math.max(fa.length, fb.length); const x = fa.padEnd(n, "0"), y = fb.padEnd(n, "0"); c = x < y ? -1 : x > y ? 1 : 0; }
    return c * sa;
  }
  function valueProblem(f, v) {
    switch (f.widget) {
      case "number":
      case "integer":
        if (f.widget === "number" && !numberOk(v)) return `"${v}" is not a plain decimal number: write it like 12, -3 or 0.25 (no exponent, leading zeros, "+", spaces or thousands separators)`;
        if (f.widget === "integer" && (!INT_RE.test(v) || v === "-0")) return `"${v}" is not a whole number: write it like 12 or -3`;
        if (f.min != null && cmpDecimal(v, f.min) < 0) return `${v} is below the minimum, ${f.min}`;
        if (f.max != null && cmpDecimal(v, f.max) > 0) return `${v} is above the maximum, ${f.max}`;
        return null;
      case "text":
      case "longtext":
        if (f.widget === "text" && /[\r\n]/.test(v)) return "must be a single line";
        if (/^[=@]/.test(v)) return 'starts with "=" or "@", which a spreadsheet opening the CSV would run as a formula: start it with another character';
        return null;
      case "choice":
        return (f.options || []).some((o) => o.value === v) ? null : `"${v}" is not one of the choices`;
      case "yesno":
        return v === "yes" || v === "no" ? null : `"${v}" is not yes or no`;
      case "date":
        return /^\d{4}-\d{2}-\d{2}$/.test(v) && !isNaN(new Date(v + "T00:00:00")) ? null : `"${v}" is not a date written YYYY-MM-DD`;
      case "time":
        return /^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/.test(v) ? null : `"${v}" is not a time written HH:MM`;
      case "datetime":
        return /^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d(:[0-5]\d(\.\d{1,6})?)?(Z|[+-]([01]\d|2[0-3]):[0-5]\d)$/.test(v) ? null : `"${v}" is not a date and time with its UTC offset`;
      default:
        return null;
    }
  }
  const DATA_WIDGETS = ["number", "integer", "text", "longtext", "choice", "yesno", "date", "time", "datetime"];
  const WIDGET_LABELS = {
    number: "Number", integer: "Whole number", text: "Text (one line)", longtext: "Text (several lines)",
    choice: "Choice", yesno: "Yes / no", date: "Date", time: "Time", datetime: "Date and time",
    heading: "Heading", instruction: "Instruction",
  };
  const INFO_ITEMS = {
    project: "Project", members: "Project members", species: "Species", sex: "Sex", strain: "Strain",
    genotype: "Genotype", date_of_birth: "Date of birth", age: "Age at the session", source: "Source",
    subject_notes: "Subject notes", tags: "Subject tags", latest_weight: "Latest weight (and % of baseline)",
    endpoint: "Endpoint status", last_surgery: "Last surgery", last_entry: "Previous entry on this form",
  };
  const DEFAULT_HEADER = ["project", "species", "sex", "age", "latest_weight", "last_entry"].map((i) => ({ item: i }));

  // ------------------------------------------------------------------ state
  const S = {
    session: null,       // {login, person_name, can_write, csv}
    online: null,
    view: "enter",
    subject: null,       // {subject, subject_forms}
    sfId: null,          // selected subject form
    ctx: null,           // /api/context result for it
    edit: null,          // {mode: 'new'|'correct', entry, formBundle}
    entries: [],
    templates: [],
    builder: null,
    projects: null,
  };

  // ---------------------------------------------------------------- toasts
  let toastTimer = null;
  function toast(msg, kind) {
    const t = $("toast");
    t.textContent = msg; t.className = "toast" + (kind ? " " + kind : ""); t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, kind === "error" ? 9000 : 4500);
  }
  function banner(msg, kind) {
    const b = $("banner");
    if (!msg) { b.hidden = true; return; }
    b.textContent = msg; b.className = "banner" + (kind ? " " + kind : ""); b.hidden = false;
  }

  // ------------------------------------------------------------------- API
  class NetError extends Error {}
  class ApiError extends Error {
    constructor(status, data) { super((data && data.error) || ("The server answered " + status)); this.status = status; this.data = data || {}; }
  }
  function setOnline(on) {
    if (S.online === on) return;
    S.online = on;
    const n = $("net");
    n.textContent = on ? "Server reachable" : "Server unreachable";
    n.className = "net " + (on ? "online" : "offline");
    if (!on) banner("The forms server cannot be reached. Entries you save are kept in this browser and sent when it answers again.", "error");
    else if ($("banner").classList.contains("error")) banner(null);
  }
  async function api(method, path, body) {
    const opts = { method, credentials: "same-origin", cache: "no-store", headers: { Accept: "application/json" } };
    if (method === "POST") {
      opts.headers["Content-Type"] = "application/json";
      opts.headers["X-CarasLab-Forms"] = "1";
      opts.body = JSON.stringify(body || {});
    }
    let resp;
    try { resp = await fetch(path, opts); } catch (e) { setOnline(false); throw new NetError("unreachable"); }
    let data = null;
    try { data = await resp.json(); } catch (e) { data = null; }
    if (data === null) { // a proxy's error page: the forms server is not answering
      setOnline(false);
      throw new NetError("no answer");
    }
    setOnline(true);
    if (resp.status === 401 && data.signed_out) signedOut();
    if (resp.status === 503 && data.signed_out) signedOut();
    if (!resp.ok) throw new ApiError(resp.status, data);
    return data;
  }
  const q = (params) => "?" + new URLSearchParams(params).toString();

  // ---------------------------------------------------------------- outbox
  // IndexedDB store "outbox" (keyPath id). Falls back to memory, with a
  // warning, where the browser refuses storage.
  const OB = { db: null, mem: null };
  function obOpen() {
    return new Promise((resolve) => {
      let req;
      try { req = indexedDB.open("caraslab-forms", 1); } catch (e) { resolve(null); return; }
      req.onupgradeneeded = () => { req.result.createObjectStore("outbox", { keyPath: "id" }); };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(null);
      req.onblocked = () => resolve(null);
    });
  }
  function obTx(mode, fn) {
    return new Promise((resolve, reject) => {
      const tx = OB.db.transaction("outbox", mode);
      const store = tx.objectStore("outbox");
      let result;
      Promise.resolve(fn(store)).then((r) => { result = r; });
      tx.oncomplete = () => resolve(result);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    });
  }
  async function obAll() {
    if (!OB.db) return [...OB.mem.values()].sort((a, b) => a.seq - b.seq);
    const items = await obTx("readonly", (st) => new Promise((res) => { const r = st.getAll(); r.onsuccess = () => res(r.result); }));
    return items.sort((a, b) => a.seq - b.seq);
  }
  async function obPut(item) { if (!OB.db) { OB.mem.set(item.id, item); return; } await obTx("readwrite", (st) => { st.put(item); }); }
  async function obDelete(id) { if (!OB.db) { OB.mem.delete(id); return; } await obTx("readwrite", (st) => { st.delete(id); }); }
  async function obInit() {
    OB.db = await obOpen();
    if (!OB.db) {
      OB.mem = new Map();
      $("storage-note").textContent = "This browser does not keep data for this page (private window, or storage blocked). An unsent entry is lost if this page is closed: keep it open until the Unsent tab is empty.";
      $("storage-note").hidden = false;
    } else if (navigator.storage && navigator.storage.persist) {
      try {
        const persisted = await navigator.storage.persist();
        if (!persisted) {
          $("storage-note").textContent = "The browser may clear this page's data under storage pressure or when browsing data is cleared. Unsent entries are kept here until then; download a copy if one is waiting long.";
          $("storage-note").hidden = false;
        }
      } catch (e) { /* not available */ }
    }
  }
  let seqCounter = Date.now() * 1000;
  async function enqueue(kind, payload, summary) {
    const item = {
      id: kind === "entry" ? payload.event_id : `${kind}:${payload.event_id}:${Date.now()}`,
      seq: ++seqCounter, kind, login: S.session.login, created_at: new Date().toISOString(),
      state: "waiting", attempts: 0, last_error: null, problems: null, payload, summary,
    };
    await obPut(item);
    await refreshOutboxCount();
    return item;
  }
  let flushing = false, retryTimer = null, retryDelay = 15000;
  // Send what is waiting, oldest first. QUIET is the id of an item whose
  // result the caller reports itself; every other result is reported here.
  async function flush(quiet) {
    if (flushing || !S.session) return { sent: 0, waiting: 0, results: {} };
    flushing = true;
    const results = {};
    const run = async () => {
      let sent = 0, waiting = 0;
      for (const item of await obAll()) {
        if (item.login !== S.session.login || item.state === "attention") continue;
        const path = item.kind === "entry" ? "api/entry/submit" : "api/entry/note";
        try {
          const out = await api("POST", path, item.payload);
          await obDelete(item.id);
          sent++;
          results[item.id] = out;
          if (item.id !== quiet) noteCsv(out.csv);
        } catch (e) {
          if (e instanceof NetError || (e instanceof ApiError && (e.status === 401 || e.status >= 500))) {
            item.state = "waiting"; item.attempts++; item.last_error = e.message;
            await obPut(item);
            waiting++;
            break; // keep the order: later items wait for this one
          }
          item.state = "attention"; item.attempts++; item.last_error = e.message;
          item.problems = (e.data && e.data.problems) || null;
          await obPut(item);
        }
      }
      return { sent, waiting, results };
    };
    try {
      return navigator.locks ? await navigator.locks.request("caraslab-forms-outbox", run) : await run();
    } finally {
      flushing = false;
      await refreshOutboxCount();
      scheduleRetry();
    }
  }
  async function scheduleRetry() {
    clearTimeout(retryTimer);
    const items = (await obAll()).filter((i) => i.state === "waiting");
    if (!items.length) { retryDelay = 15000; return; }
    retryTimer = setTimeout(() => { flush(); }, retryDelay);
    retryDelay = Math.min(retryDelay * 2, 120000);
  }
  async function refreshOutboxCount() {
    const items = await obAll();
    OB.pendingCount = items.length;
    const c = $("outbox-count");
    c.textContent = String(items.length);
    c.classList.toggle("has", items.length > 0);
    if (S.view === "outbox") renderOutbox(items);
    return items;
  }
  function noteCsv(csv) {
    if (!csv) return;
    if (csv.status === "pending") toast("Saved. The subject's CSV file could not be updated (it may be open in Excel); the server will try again.", "warn");
    else if (csv.status === "conflict") toast("Saved. The CSV file could not be written: " + csv.message, "warn");
  }

  // --------------------------------------------------------------- sign-in
  function signedOut() {
    if (!S.session) return;
    S.session = null;
    showSignedOut("You were signed out. Sign in again; anything not yet sent is kept in this browser.");
  }
  function showSignedOut(msg) {
    $("tabs").hidden = true; $("btn-logout").hidden = true; $("who").textContent = "";
    for (const v of ["enter", "templates", "outbox"]) $("view-" + v).hidden = true;
    $("view-login").hidden = false;
    const e = $("login-error");
    e.hidden = !msg; e.textContent = msg || "";
    $("login-name").value = lsGet("caraslab-forms-login", "");
    ($("login-name").value ? $("login-pass") : $("login-name")).focus();
  }
  async function signedIn(sess) {
    S.session = sess;
    lsSet("caraslab-forms-login", sess.login);
    $("view-login").hidden = true; $("tabs").hidden = false; $("btn-logout").hidden = false;
    $("who").textContent = sess.person_name ? `${sess.person_name} (${sess.login})` : sess.login;
    if (sess.warning) banner(sess.warning);
    if (!sess.csv) banner("This server writes no CSV files (started with --no-csv); entries go to the database only.");
    showView(S.view || "enter");
    const items = await refreshOutboxCount();
    if (items.some((i) => i.login === sess.login)) flush();
  }
  async function doLogin(ev) {
    ev.preventDefault();
    const err = $("login-error");
    err.hidden = true;
    try {
      const sess = await api("POST", "api/login", { login: $("login-name").value.trim(), password: $("login-pass").value });
      $("login-pass").value = "";
      await signedIn(sess);
    } catch (e) {
      err.textContent = e instanceof NetError ? "The forms server cannot be reached." : e.message;
      err.hidden = false;
    }
  }
  async function doLogout() {
    const mine = (await obAll()).filter((i) => S.session && i.login === S.session.login);
    if (mine.length && !(await confirmDialog("Sign out?", `${mine.length} entr${mine.length === 1 ? "y has" : "ies have"} not been sent yet. They stay in this browser and are sent the next time you sign in here.`, "Sign out"))) return;
    try { await api("POST", "api/logout", {}); } catch (e) { /* signed out anyway */ }
    S.session = null; S.subject = null; S.ctx = null; S.sfId = null;
    showSignedOut("");
  }

  // ----------------------------------------------------------------- views
  function showView(v) {
    S.view = v;
    for (const name of ["enter", "templates", "outbox"]) {
      $("view-" + name).hidden = name !== v;
      const t = document.querySelector(`.tab[data-view="${name}"]`);
      if (t) t.classList.toggle("active", name === v);
    }
    if (v === "templates") loadTemplates();
    if (v === "outbox") refreshOutboxCount();
    if (v === "enter" && !S.subject) $("subject-search").focus();
  }

  // ------------------------------------------------------- subject search
  let searchSeq = 0, activeResult = -1;
  async function searchSubjects() {
    const box = $("subject-search"), list = $("subject-results");
    const text = box.value.trim();
    const my = ++searchSeq;
    if (!text) { list.hidden = true; return; }
    let rows;
    try { rows = (await api("GET", "api/subjects" + q({ q: text }))).subjects; } catch (e) { return; }
    if (my !== searchSeq) return;
    clear(list);
    activeResult = rows.length ? 0 : -1;
    rows.forEach((r, i) => {
      list.appendChild(el("li", { class: i === 0 ? "active" : null, onmousedown: (e) => { e.preventDefault(); pickSubject(r.subject_id); } },
        el("strong", { text: r.subject_id }), " ",
        el("span", { class: "muted", text: [r.project, r.species, r.sex].filter(Boolean).join(" · ") }),
        r.is_endpointed ? el("span", { class: "chip warn", text: "endpoint" }) : null));
    });
    if (!rows.length) list.appendChild(el("li", { class: "muted", text: "No subject matches." }));
    list.hidden = false;
    list._rows = rows;
  }
  function searchKeys(e) {
    const list = $("subject-results");
    const rows = list._rows || [];
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      if (!rows.length) return;
      e.preventDefault();
      activeResult = (activeResult + (e.key === "ArrowDown" ? 1 : rows.length - 1)) % rows.length;
      [...list.children].forEach((li, i) => li.classList.toggle("active", i === activeResult));
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (rows[activeResult]) pickSubject(rows[activeResult].subject_id);
    } else if (e.key === "Escape") {
      list.hidden = true;
    }
  }

  async function pickSubject(id) {
    $("subject-results").hidden = true;
    $("subject-search").value = id;
    try {
      S.subject = await api("GET", "api/subject" + q({ subject: id }));
    } catch (e) { toast(e.message, "error"); return; }
    lsSet("caraslab-forms-subject", id);
    S.sfId = null; S.ctx = null; S.edit = null;
    renderSubject();
    $("entry-panel").hidden = true; $("history-panel").hidden = true;
    // Open the form used last for this subject, or its only one.
    const open = S.subject.subject_forms.filter((f) => !f.retired_at);
    const last = lsGet("caraslab-forms-sf:" + id, "");
    const pick = open.find((f) => String(f.subject_form_id) === last) || (open.length === 1 ? open[0] : null);
    if (pick) selectSubjectForm(String(pick.subject_form_id));
  }

  async function reloadSubject() {
    if (!S.subject) return;
    try { S.subject = await api("GET", "api/subject" + q({ subject: S.subject.subject.subject_id })); renderSubject(); } catch (e) { /* keep */ }
  }

  function renderSubject() {
    const p = clear($("subject-panel"));
    p.hidden = false;
    const s = S.subject.subject;
    const card = el("div", { class: "card" });
    card.appendChild(el("div", { class: "row between gap" },
      el("h2", { text: s.subject_id }),
      el("span", { class: "muted", text: [s.species, s.sex !== "U" ? (s.sex === "F" ? "female" : "male") : "sex unknown", "project " + s.project].filter(Boolean).join(" · ") })));
    if (s.is_endpointed) card.appendChild(el("div", { class: "alert error", text: `This subject has an endpoint event (${fmtDateTime(s.endpoint_at)}). Check that you have the right animal.` }));
    const forms = S.subject.subject_forms;
    if (forms.length) {
      const list = el("div", { class: "sf-list" });
      for (const f of forms) {
        const id = String(f.subject_form_id);
        const upgrade = f.latest_version > f.form_version && !f.retired_at;
        list.appendChild(el("div", { class: "sf" + (id === S.sfId ? " selected" : "") },
          el("div", { class: "title", text: f.form_label }),
          el("div", { class: "small muted", text: `${f.form_name} · v${f.form_version} · project ${f.project}` }),
          el("div", { class: "small", text: `${f.n_entries} entr${f.n_entries === 1 ? "y" : "ies"}${f.last_entry_at ? ", last " + fmtDateTime(f.last_entry_at) : ""}` }),
          f.retired_at ? el("div", { class: "chip", text: "retired" }) : null,
          f.form_retired_at ? el("div", { class: "chip warn", text: "template retired" }) : null,
          el("div", { class: "actions" },
            !f.retired_at ? el("button", { type: "button", class: id === S.sfId ? "primary" : null, onclick: () => selectSubjectForm(id), text: "Fill in" }) : null,
            upgrade ? el("button", { type: "button", onclick: () => upgradeSubjectForm(f), text: `Use v${f.latest_version}` }) : null,
            el("button", { type: "button", class: "link", onclick: () => setSubjectFormRetired(f, !f.retired_at), text: f.retired_at ? "Use again" : "Retire" }))));
      }
      card.appendChild(list);
    } else {
      card.appendChild(el("p", { class: "muted", text: "This subject has no forms yet. Add one from a template." }));
    }
    card.appendChild(addFormRow());
    p.appendChild(card);
  }

  function addFormRow() {
    const wrap = el("div", { class: "row gap" });
    const tplSel = el("select", { "aria-label": "Template" }, el("option", { value: "", text: "Add a form from a template…" }));
    const projSel = el("select", { "aria-label": "Project" });
    const btn = el("button", { type: "button", text: "Add", disabled: true });
    const fill = async () => {
      try {
        const [forms, projects] = await Promise.all([api("GET", "api/forms"), S.projects ? { projects: S.projects } : api("GET", "api/projects")]);
        S.projects = projects.projects;
        for (const f of forms.forms.filter((x) => !x.retired_at && x.latest_version)) tplSel.appendChild(el("option", { value: f.name, text: `${f.label} (${f.name})` }));
        const home = String(S.subject.subject.project_id);
        for (const pr of S.projects) projSel.appendChild(el("option", { value: String(pr.project_id), selected: String(pr.project_id) === home, text: pr.name + (String(pr.project_id) === home ? " (the subject's project)" : "") + (pr.is_active ? "" : " (inactive)") }));
      } catch (e) { /* offline: nothing to add */ }
    };
    fill();
    tplSel.addEventListener("change", () => { btn.disabled = !tplSel.value; });
    btn.addEventListener("click", async () => {
      try {
        const out = await api("POST", "api/subject-form/add", { subject_id: S.subject.subject.subject_id, form_name: tplSel.value, project_id: projSel.value || null });
        await reloadSubject();
        selectSubjectForm(String(out.subject_form_id));
      } catch (e) { toast(e.message, "error"); }
    });
    wrap.appendChild(tplSel); wrap.appendChild(el("span", { class: "muted", text: "for project" })); wrap.appendChild(projSel); wrap.appendChild(btn);
    return el("div", { class: "actions" }, wrap);
  }

  async function upgradeSubjectForm(f) {
    if (!(await confirmDialog(`Use version ${f.latest_version}?`, `New entries on this subject's "${f.form_label}" will use version ${f.latest_version} of the template. Entries already made keep the version they were made on.`, "Use it"))) return;
    try {
      await api("POST", "api/subject-form/update", { subject_form_id: String(f.subject_form_id), form_version: f.latest_version });
      await reloadSubject();
      if (S.sfId === String(f.subject_form_id)) selectSubjectForm(S.sfId);
    } catch (e) { toast(e.message, "error"); }
  }
  async function setSubjectFormRetired(f, retired) {
    try {
      await api("POST", "api/subject-form/update", { subject_form_id: String(f.subject_form_id), retired });
      if (retired && S.sfId === String(f.subject_form_id)) { S.sfId = null; $("entry-panel").hidden = true; $("history-panel").hidden = true; }
      await reloadSubject();
    } catch (e) { toast(e.message, "error"); }
  }

  // ----------------------------------------------------- the entry form
  async function selectSubjectForm(id) {
    S.sfId = id;
    if (S.subject) lsSet("caraslab-forms-sf:" + S.subject.subject.subject_id, id);
    renderSubject();
    try {
      S.ctx = await api("GET", "api/context" + q({ subject_form: id }));
    } catch (e) {
      if (!(e instanceof NetError)) toast(e.message, "error");
      if (!S.ctx || String(S.ctx.subject_form.subject_form_id) !== id) return;
    }
    S.edit = { mode: "new", entry: null, bundle: S.ctx.form };
    renderEntry();
    await loadHistory();
  }

  function headerValue(item) {
    const c = S.ctx, s = c.subject, sf = c.subject_form;
    const occurred = currentOccurredDate();
    if (item.variable) {
      let v = null;
      if (item.source === "subject") v = c.subject_variables[item.variable];
      else if (item.source === "project") v = c.project_variables[item.variable];
      else if (item.source === "previous_entry" && c.previous_entry) {
        const pv = item.variable === "entry note" ? c.previous_entry.note : c.previous_entry.field_values[item.variable];
        if (pv != null) v = { value: pv, units: (c.form.variables[item.variable] || {}).units, set_at: c.previous_entry.occurred_at };
      }
      const def = c.form.variables[item.variable] || {};
      const label = item.label || def.label || item.variable;
      const where = item.source === "previous_entry" ? " (previous entry)" : item.source === "project" ? " (project)" : "";
      return [label + where, v ? `${v.value}${v.units ? " " + v.units : ""}` : "not set", v && v.set_at ? fmtDate(v.set_at) : null];
    }
    switch (item.item) {
      case "project": return ["Project", sf.project + (String(sf.project_id) !== String(s.project_id) ? ` (subject's own: ${s.project})` : ""), sf.project_description || null];
      case "members": return ["Project members", c.members.map((m) => m.full_name + (m.role ? ` (${m.role})` : "")).join(", ") || "none listed"];
      case "species": return ["Species", s.species || s.species_code || "—"];
      case "sex": return ["Sex", { F: "Female", M: "Male", U: "Unknown" }[s.sex] || s.sex];
      case "strain": return ["Strain", s.strain || "—"];
      case "genotype": return ["Genotype", s.genotype || "—"];
      case "date_of_birth": return ["Date of birth", s.date_of_birth || "unknown"];
      case "age": {
        if (!s.date_of_birth || !occurred) return ["Age at the session", "unknown"];
        const days = Math.floor((occurred - new Date(s.date_of_birth + "T00:00:00")) / 86400000);
        return ["Age at the session", `${days} days (${(days / 7).toFixed(1)} weeks)`];
      }
      case "source": return ["Source", s.source || "—"];
      case "subject_notes": return ["Subject notes", s.notes || "—"];
      case "tags": return ["Subject tags", c.subject_tags.join(", ") || "none"];
      case "latest_weight": {
        if (s.latest_weight_g == null) return ["Latest weight", "none recorded"];
        let extra = "";
        const b = c.subject_variables["baseline weight"];
        if (b && (b.units === "g" || b.units === "kg")) {
          const base = parseFloat(b.value) * (b.units === "kg" ? 1000 : 1);
          if (base > 0) extra = ` · ${Math.round(100 * parseFloat(s.latest_weight_g) / base)}% of baseline ${b.value} ${b.units}`;
        }
        return ["Latest weight", `${s.latest_weight_g} g${extra}`, fmtDateTime(s.latest_weight_at)];
      }
      case "endpoint": return ["Endpoint", s.is_endpointed ? "endpointed " + fmtDateTime(s.endpoint_at) : "none"];
      case "last_surgery": {
        const g = c.last_surgery;
        if (!g) return ["Last surgery", "none recorded"];
        return ["Last surgery", [g.procedure, g.target_region, g.hemisphere].filter(Boolean).join(" · ") || "surgery", fmtDateTime(g.occurred_at)];
      }
      case "last_entry": {
        const pe = c.previous_entry;
        return ["Previous entry on this form", pe ? `${pe.session_label}` : "none", pe ? fmtDateTime(pe.occurred_at) : null];
      }
      default: return [item.item, "—"];
    }
  }

  function currentOccurredDate() {
    const inp = document.getElementById("f-occurred");
    if (inp && inp.value) { const d = new Date(inp.value); if (!isNaN(d)) return d; }
    return new Date();
  }

  function renderHeaderCard(def) {
    const grid = el("div", { class: "header-card" });
    const items = def.header && def.header.length ? def.header : DEFAULT_HEADER;
    for (const item of items) {
      const [k, v, sub] = headerValue(item);
      grid.appendChild(el("div", { class: "header-item" }, el("div", { class: "k", text: k }), el("div", { class: "v", text: v }), sub ? el("div", { class: "small muted", text: sub }) : null));
    }
    return grid;
  }

  function fieldsOf(def) {
    const out = [];
    for (const sec of def.sections || []) for (const f of sec.fields || []) if (DATA_WIDGETS.includes(f.widget)) out.push(f);
    return out;
  }

  // Build one field's input. Returns {node, get(), set(v), focus(), input}
  function fieldControl(f, idBase, variables) {
    const def = variables[f.variable] || {};
    const units = f.units || def.units;
    let input, get, set;
    if (f.widget === "number" || f.widget === "integer") {
      input = el("input", { type: "text", id: idBase, inputmode: f.widget === "integer" ? "numeric" : "decimal", autocomplete: "off", spellcheck: "false" });
      get = () => input.value.trim(); set = (v) => { input.value = v || ""; };
    } else if (f.widget === "text") {
      input = el("input", { type: "text", id: idBase, autocomplete: "off" });
      get = () => input.value; set = (v) => { input.value = v || ""; };
    } else if (f.widget === "longtext") {
      input = el("textarea", { id: idBase, rows: 3 });
      get = () => input.value; set = (v) => { input.value = v || ""; };
    } else if (f.widget === "date" || f.widget === "time") {
      input = el("input", { type: f.widget, id: idBase });
      get = () => input.value; set = (v) => { input.value = v || ""; };
    } else if (f.widget === "datetime") {
      input = el("input", { type: "datetime-local", id: idBase });
      get = () => (input.value ? withOffset(input.value) : "");
      set = (v) => { const d = v ? new Date(v) : null; input.value = d && !isNaN(d) ? localInputValue(d) : ""; };
    } else if (f.widget === "choice" && (f.options || []).length > 5) {
      input = el("select", { id: idBase }, el("option", { value: "", text: "—" }), ...(f.options || []).map((o) => el("option", { value: o.value, text: o.label || o.value })));
      get = () => input.value; set = (v) => { input.value = v || ""; };
    } else { // choice with few options, or yes/no: radio buttons, one click
      const opts = f.widget === "yesno" ? [{ value: "yes", label: "Yes" }, { value: "no", label: "No" }] : (f.options || []);
      input = el("div", { class: "choices", id: idBase, role: "radiogroup" });
      const name = idBase + "-r";
      for (const o of opts) {
        const r = el("input", { type: "radio", name, value: o.value });
        // a second click on the chosen option clears an optional field
        r.addEventListener("click", () => { if (r.dataset.was === "1" && !f.required) { r.checked = false; } r.dataset.was = r.checked ? "1" : "0"; [...input.querySelectorAll("input")].forEach((x) => { if (x !== r) x.dataset.was = "0"; }); });
        input.appendChild(el("label", null, r, o.label || o.value));
      }
      get = () => { const c = input.querySelector("input:checked"); return c ? c.value : ""; };
      set = (v) => { for (const r of input.querySelectorAll("input")) { r.checked = r.value === v; r.dataset.was = r.checked ? "1" : "0"; } };
    }
    return { input, get, set, units };
  }

  function renderEntry() {
    const p = clear($("entry-panel"));
    p.hidden = false;
    const c = S.ctx, sf = c.subject_form, ed = S.edit, bundle = ed.bundle, def = bundle.definition;
    const card = el("div", { class: "card" });
    const title = ed.mode === "correct" ? `Correct the entry of ${ed.entry.session_label}` : `${sf.form_label}`;
    card.appendChild(el("div", { class: "row between gap" },
      el("h2", { text: title }),
      el("span", { class: "muted small", text: `${sf.form_name} · version ${bundle.version} · project ${sf.project}` })));
    if (c.subject.is_endpointed) card.appendChild(el("div", { class: "alert error", text: "This subject has an endpoint event. Check the animal before entering data." }));
    if (sf.form_description) card.appendChild(el("p", { class: "muted", text: sf.form_description }));
    card.appendChild(renderHeaderCard(def));
    if (c.csv && c.csv.status) card.appendChild(el("div", { class: "alert", text: `This subject's CSV file is waiting to be rewritten (${c.csv.message || c.csv.status}).` }));

    // session date/time and label
    const occurred = el("input", { type: "datetime-local", id: "f-occurred", required: true });
    const label = el("input", { type: "text", id: "f-label", required: true, autocomplete: "off" });
    let labelEdited = false;
    const now = ed.mode === "correct" ? new Date(ed.entry.occurred_at) : new Date();
    occurred.value = localInputValue(now);
    label.value = ed.mode === "correct" ? ed.entry.session_label : defaultLabel(occurred.value);
    labelEdited = ed.mode === "correct";
    const dupMsg = el("div", { class: "msg warn" });
    const checkDup = () => {
      const v = label.value.trim();
      const dup = v && c.labels.includes(v) && !(ed.mode === "correct" && ed.entry.session_label === v);
      dupMsg.textContent = dup ? "This subject form already has an entry with this session label." : "";
    };
    occurred.addEventListener("input", () => { if (!labelEdited) label.value = defaultLabel(occurred.value); checkDup(); refreshHeader(); });
    label.addEventListener("input", () => { labelEdited = true; checkDup(); });
    checkDup();
    card.appendChild(el("div", { class: "session-row" },
      el("div", { class: "field" }, el("label", { class: "flabel", for: "f-occurred", text: "Session date and time" }), occurred, el("div", { class: "help", text: ZONE ? "In your time zone, " + ZONE + "." : "In your time zone." })),
      el("div", { class: "field" }, el("label", { class: "flabel", for: "f-label", text: "Session label" }), label, el("div", { class: "help", text: "Free text; follows the date and time until you change it." }), dupMsg)));

    // the fields
    const controls = [];
    const prev = c.previous_entry && c.previous_entry.form_name === sf.form_name ? c.previous_entry : null;
    let n = 0;
    for (const sec of def.sections || []) {
      if (sec.title) card.appendChild(el("h3", { text: sec.title }));
      for (const f of sec.fields || []) {
        if (f.widget === "heading") { card.appendChild(el("h3", { text: f.text })); continue; }
        if (f.widget === "instruction") { card.appendChild(el("div", { class: "instruction", text: f.text })); continue; }
        const id = "f-" + (n++);
        const ctl = fieldControl(f, id, bundle.variables);
        const vdef = bundle.variables[f.variable] || {};
        const msg = el("div", { class: "msg" });
        const wrap = el("div", { class: "field" },
          el(ctl.input.tagName === "DIV" ? "span" : "label", { class: "flabel", for: ctl.input.tagName === "DIV" ? null : id },
            (f.label || vdef.label || f.variable) + (ctl.units ? ` (${ctl.units})` : ""), f.required ? el("span", { class: "req", text: "*", title: "required" }) : null),
          ctl.input,
          f.help ? el("div", { class: "help", text: f.help }) : null,
          f.show_previous && prev && prev.field_values[f.variable] != null ? el("div", { class: "prev", text: `Previous: ${prev.field_values[f.variable]}${ctl.units ? " " + ctl.units : ""} (${prev.session_label})` }) : null,
          msg);
        if (ed.mode === "correct") ctl.set(ed.entry.field_values[f.variable]);
        const onChange = () => { const v = ctl.get(); msg.textContent = v && v.trim() ? (valueProblem(f, v) || "") : ""; markInvalid(ctl.input, !!msg.textContent); };
        ctl.input.addEventListener("change", onChange);
        ctl.input.addEventListener("blur", onChange, true);
        controls.push({ f, ctl, msg });
        card.appendChild(wrap);
      }
    }

    // note
    const note = el("textarea", { id: "f-note", rows: 3 });
    if (ed.mode === "correct") note.value = ed.entry.note || "";
    card.appendChild(el("div", { class: "field" }, el("label", { class: "flabel", for: "f-note", text: "Note" }), note, el("div", { class: "help", text: "Anything else about this session. It can be changed later without correcting the entry." })));

    const saveBtn = el("button", { type: "button", class: "primary", text: ed.mode === "correct" ? "Save correction (Ctrl+S)" : "Save (Ctrl+S)" });
    const status = el("span", { class: "small muted" });
    saveBtn.addEventListener("click", () => saveEntry(controls, occurred, label, note, saveBtn, status));
    card.appendChild(el("div", { class: "actions" }, saveBtn,
      ed.mode === "correct" ? el("button", { type: "button", onclick: () => { S.edit = { mode: "new", entry: null, bundle: S.ctx.form }; renderEntry(); }, text: "Cancel correction" }) : el("button", { type: "button", onclick: () => renderEntry(), text: "Clear" }),
      status));
    p.appendChild(card);
    S.saveAction = () => saveBtn.click();

    function refreshHeader() {
      const old = card.querySelector(".header-card");
      if (old) old.replaceWith(renderHeaderCard(def));
    }
    const first = controls[0];
    if (first && ed.mode === "new") setTimeout(() => (first.ctl.input.querySelector ? (first.ctl.input.querySelector("input") || first.ctl.input) : first.ctl.input).focus(), 0);
  }

  function defaultLabel(localValue) { return localValue ? localValue.replace("T", " ").slice(0, 16) : ""; }
  function markInvalid(node, bad) { node.classList.toggle("invalid", !!bad); }

  async function saveEntry(controls, occurred, label, note, saveBtn, status) {
    if (!S.session) { toast("Sign in first.", "error"); return; }
    const ed = S.edit, bundle = ed.bundle;
    let firstBad = null;
    const values = {};
    for (const { f, ctl, msg } of controls) {
      const v = ctl.get();
      let problem = null;
      if (!v || !v.trim()) { if (f.required) problem = "is required"; }
      else { problem = valueProblem(f, v); values[f.variable] = v; }
      msg.textContent = problem || "";
      markInvalid(ctl.input, !!problem);
      if (problem && !firstBad) firstBad = ctl.input;
    }
    const occ = occurred.value ? withOffset(occurred.value) : null;
    if (!occ) { markInvalid(occurred, true); firstBad = firstBad || occurred; } else markInvalid(occurred, false);
    const lab = label.value;
    if (!lab.trim() || lab !== lab.trim()) { markInvalid(label, true); firstBad = firstBad || label; } else markInvalid(label, false);
    const noteText = note.value;
    if (/^[=@]/.test(noteText)) { markInvalid(note, true); firstBad = firstBad || note; toast('The note starts with "=" or "@", which a spreadsheet would run as a formula.', "error"); }
    if (firstBad) { (firstBad.querySelector ? (firstBad.querySelector("input") || firstBad) : firstBad).focus(); status.textContent = "Fix the marked fields."; return; }

    const sf = S.ctx.subject_form;
    const payload = {
      event_id: uuid(), subject_form_id: String(sf.subject_form_id), occurred_at: new Date(occurred.value).toISOString(),
      session_label: lab, values, note: noteText.trim() ? noteText : null,
      supersedes: ed.mode === "correct" ? String(ed.entry.event_id) : null,
      entered_at: new Date().toISOString(),
    };
    // occurred_at is sent in UTC ("Z"); the minute the user picked is that instant.
    saveBtn.disabled = true;
    status.textContent = "Saving…";
    try {
      await enqueue("entry", payload, { subject_id: S.ctx.subject.subject_id, form: sf.form_label, project: sf.project, session_label: lab, version: bundle.version });
    } catch (e) {
      saveBtn.disabled = false; status.textContent = "";
      toast("The entry could not be kept in this browser (" + e.message + "); it was not saved.", "error");
      return;
    }
    const res = await flush(payload.event_id);
    saveBtn.disabled = false;
    const left = (await obAll()).find((i) => i.id === payload.event_id);
    if (!left) {
      status.textContent = "";
      const out = (res && res.results[payload.event_id]) || {};
      const saved = ed.mode === "correct" ? "Correction saved" : "Saved";
      if (out.outcome === "existing") toast(saved + " (the database already had it).");
      else if (out.csv && (out.csv.status === "pending" || out.csv.status === "conflict")) toast(saved + ". The subject's CSV file could not be updated (" + (out.csv.message || out.csv.status) + "); the server will try again.", "warn");
      else toast(saved + ".");
      await selectSubjectForm(S.sfId);
      reloadSubject();
    } else if (left.state === "attention") {
      status.textContent = "";
      showServerProblems(left, controls);
    } else {
      // Kept for later: clear the form for the next entry (a correction is
      // not offered twice), and say where the entry is.
      toast("The server could not be reached. The entry is kept in this browser and will be sent automatically.", "warn");
      S.edit = { mode: "new", entry: null, bundle: S.ctx.form };
      renderEntry();
    }
  }

  async function showServerProblems(item, controls) {
    const problems = item.problems || [];
    for (const { f, ctl, msg } of controls) {
      const p = problems.find((x) => x.field === f.variable);
      if (p) { msg.textContent = p.problem; markInvalid(ctl.input, true); }
    }
    // The database refused it: nothing was stored; keep the form as filled
    // in and take the item out of the outbox, so it is not sent again.
    await obDelete(item.id);
    await refreshOutboxCount();
    toast("Not saved: " + item.last_error, "error");
  }

  // ---------------------------------------------------------- history
  async function loadHistory() {
    const p = $("history-panel");
    if (!S.sfId) { p.hidden = true; return; }
    try {
      S.entries = (await api("GET", "api/entries" + q({ subject_form: S.sfId }))).entries;
    } catch (e) { return; }
    renderHistory();
  }

  function renderHistory() {
    const p = clear($("history-panel"));
    p.hidden = false;
    const card = el("div", { class: "card" });
    card.appendChild(el("h2", { text: `Entries on this form (${S.entries.length})` }));
    if (!S.entries.length) { card.appendChild(el("p", { class: "muted", text: "None yet." })); p.appendChild(card); return; }
    const fields = fieldsOf(S.ctx.form.definition).slice(0, 4);
    const thead = el("tr", null, el("th", { text: "Session" }), el("th", { text: "Label" }), ...fields.map((f) => el("th", { text: f.label || (S.ctx.form.variables[f.variable] || {}).label || f.variable })), el("th", { text: "Note" }), el("th", { text: "Entered by" }), el("th", { text: "" }));
    const tbody = el("tbody");
    for (const e of S.entries) {
      const tr = el("tr", { class: "focusable", tabindex: 0 });
      tr._entry = e;
      tr.appendChild(el("td", { text: fmtDateTime(e.occurred_at) }));
      tr.appendChild(el("td", { text: e.session_label }, e.supersedes ? el("span", { class: "chip", title: "corrected", text: "corrected" }) : null, e.form_version !== S.ctx.subject_form.form_version ? el("span", { class: "chip", text: "v" + e.form_version }) : null));
      for (const f of fields) tr.appendChild(el("td", { text: e.field_values[f.variable] != null ? e.field_values[f.variable] : "" }));
      tr.appendChild(el("td", { class: "note-cell", text: e.note || "" }));
      tr.appendChild(el("td", { class: "small", text: e.entered_by || e.recorded_login || "" }));
      tr.appendChild(el("td", null, el("div", { class: "row gap" },
        el("button", { type: "button", onclick: () => startCorrection(e), text: "Correct" }),
        el("button", { type: "button", onclick: () => editNote(e), text: "Note", title: "Change the note (Ctrl+E)" }),
        el("button", { type: "button", onclick: () => noteHistory(e), class: "link", text: "history" }),
        el("button", { type: "button", class: "danger", onclick: () => withdraw(e), text: "Withdraw" }))));
      tbody.appendChild(tr);
    }
    card.appendChild(el("div", { class: "table-wrap" }, el("table", null, el("thead", null, thead), tbody)));
    p.appendChild(card);
  }

  async function startCorrection(entry) {
    let bundle = S.ctx.form;
    if (entry.form_version !== bundle.version) {
      try { bundle = await api("GET", "api/form" + q({ name: entry.form_name, version: entry.form_version })); } catch (e) { toast(e.message, "error"); return; }
    }
    S.edit = { mode: "correct", entry, bundle };
    renderEntry();
    $("entry-panel").scrollIntoView({ behavior: "smooth", block: "start" });
  }

  async function editNote(entry) {
    const text = await inputDialog("Note", `Entry of ${entry.session_label}. The earlier note is kept in the entry's history.`, entry.note || "", true);
    if (text === null) return;
    if (/^[=@]/.test(text)) { toast('The note starts with "=" or "@", which a spreadsheet would run as a formula.', "error"); return; }
    await enqueue("note", { event_id: String(entry.event_id), note: text.trim() ? text : null }, { subject_id: S.ctx.subject.subject_id, form: S.ctx.subject_form.form_label, session_label: entry.session_label, what: "note" });
    await flush();
    const left = (await obAll()).filter((i) => i.kind === "note" && i.payload.event_id === String(entry.event_id));
    if (left.some((i) => i.state === "attention")) {
      const bad = left.find((i) => i.state === "attention");
      await obDelete(bad.id); await refreshOutboxCount();
      toast("The note was not changed: " + bad.last_error, "error");
    } else if (left.length) toast("The server could not be reached; the note change will be sent automatically.", "warn");
    else { toast("Note saved."); loadHistory(); }
  }

  async function noteHistory(entry) {
    let hist;
    try { hist = (await api("GET", "api/note-history" + q({ event_id: String(entry.event_id) }))).history; } catch (e) { toast(e.message, "error"); return; }
    const body = el("div", null, hist.length ? el("table", null,
      el("thead", null, el("tr", null, el("th", { text: "When" }), el("th", { text: "Note" }), el("th", { text: "By" }))),
      el("tbody", null, hist.map((h) => el("tr", null, el("td", { class: "small", text: fmtDateTime(h.set_at) }), el("td", { class: "note-cell", text: h.op === "unset" ? "(cleared)" : h.value_text }), el("td", { class: "small", text: h.set_by || h.set_login || "" }))))) : el("p", { class: "muted", text: "This entry has never had a note." }));
    await infoDialog("Note history", body);
  }

  async function withdraw(entry) {
    const reason = await inputDialog("Withdraw this entry?", `The entry of ${entry.session_label} leaves the form's entries and the CSV file. It stays in the database with the reason. Use this for an entry made in error (twice, or on the wrong subject), not to change a value -- use Correct for that.`, "", false, "Withdraw");
    if (reason === null) return;
    if (!reason.trim()) { toast("Say why the entry is withdrawn.", "error"); return; }
    try {
      const out = await api("POST", "api/entry/withdraw", { event_id: String(entry.event_id), reason });
      noteCsv(out.csv);
      toast("Entry withdrawn.");
      await selectSubjectForm(S.sfId);
      reloadSubject();
    } catch (e) { toast(e instanceof NetError ? "The server cannot be reached; withdraw the entry when it answers again." : e.message, "error"); }
  }

  // ------------------------------------------------------------- outbox UI
  function renderOutbox(items) {
    const list = clear($("outbox-list"));
    if (!items.length) { list.appendChild(el("p", { class: "ok", text: "Nothing is waiting: every entry made in this browser has been saved." })); return; }
    const tbody = el("tbody");
    for (const it of items) {
      const p = it.payload;
      const mine = S.session && it.login === S.session.login;
      tbody.appendChild(el("tr", null,
        el("td", { class: "small", text: fmtDateTime(it.created_at) }),
        el("td", { text: it.kind === "entry" ? (p.supersedes ? "correction" : "entry") : "note" }),
        el("td", { text: [it.summary.subject_id, it.summary.form, it.summary.session_label].filter(Boolean).join(" · ") }),
        el("td", { class: "small", text: it.login + (mine ? "" : " (sent when this login signs in)") }),
        el("td", { class: it.state === "attention" ? "error small" : "small", text: it.state === "attention" ? "refused: " + (it.last_error || "") : (it.attempts ? "waiting (" + (it.last_error || "") + ")" : "waiting") }),
        el("td", null, el("button", { type: "button", class: "danger", onclick: async () => { if (await confirmDialog("Discard this unsent item?", "It has not reached the database. Download a copy first if you may need it.", "Discard")) { await obDelete(it.id); refreshOutboxCount(); } }, text: "Discard" }))));
    }
    list.appendChild(el("div", { class: "table-wrap" }, el("table", null,
      el("thead", null, el("tr", null, el("th", { text: "Made" }), el("th", { text: "What" }), el("th", { text: "Subject · form · session" }), el("th", { text: "Login" }), el("th", { text: "State" }), el("th", { text: "" }))), tbody)));
  }
  async function downloadOutbox(kind) {
    const items = await obAll();
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    if (kind === "json") { download(`unsent-entries-${stamp}.json`, "application/json", JSON.stringify({ format: "caraslab-forms-outbox/1", items }, null, 1)); return; }
    const cell = (v) => { const s = v == null ? "" : String(v); return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
    const lines = [["made", "login", "state", "kind", "subject", "form", "session label", "session time", "note", "values", "event id", "corrects"].join(",")];
    for (const it of items) {
      const p = it.payload;
      lines.push([it.created_at, it.login, it.state, it.kind, it.summary.subject_id, it.summary.form, it.summary.session_label, p.occurred_at || "", p.note || "",
        p.values ? Object.entries(p.values).map(([k, v]) => `${k}=${v}`).join("; ") : "", p.event_id, p.supersedes || ""].map(cell).join(","));
    }
    download(`unsent-entries-${stamp}.csv`, "text/csv", "﻿" + lines.join("\r\n") + "\r\n");
  }

  // ------------------------------------------------------------- templates
  async function loadTemplates() {
    const p = clear($("template-list"));
    if (S.builder) return;
    let forms;
    try { forms = (await api("GET", "api/forms")).forms; } catch (e) { p.appendChild(el("div", { class: "card", text: e.message })); return; }
    S.templates = forms;
    const card = el("div", { class: "card" });
    card.appendChild(el("div", { class: "row between gap" }, el("h2", { text: "Form templates" }), el("button", { type: "button", class: "primary", onclick: () => openBuilder(null), text: "New template" })));
    card.appendChild(el("p", { class: "muted", text: "A template is used for any subject in any project. Editing one publishes a new version; subjects keep the version they use until you switch them." }));
    if (!forms.length) card.appendChild(el("p", { text: "There are no templates yet." }));
    else {
      const tbody = el("tbody");
      for (const f of forms) tbody.appendChild(el("tr", null,
        el("td", null, el("strong", { text: f.label }), el("div", { class: "small muted", text: f.name })),
        el("td", { text: f.latest_version ? "v" + f.latest_version : "—" }),
        el("td", { text: String(f.n_subject_forms) }), el("td", { text: String(f.n_entries) }),
        el("td", null, f.retired_at ? el("span", { class: "chip", text: "retired" }) : null),
        el("td", null, el("div", { class: "row gap" },
          !f.retired_at ? el("button", { type: "button", onclick: () => openBuilder(f.name), text: "Edit" }) : null,
          el("button", { type: "button", onclick: () => openBuilder(f.name, true), text: "Copy" }),
          el("button", { type: "button", class: "link", onclick: () => retireTemplate(f), text: f.retired_at ? "Use again" : "Retire" })))));
      card.appendChild(el("div", { class: "table-wrap" }, el("table", null, el("thead", null, el("tr", null, el("th", { text: "Template" }), el("th", { text: "Version" }), el("th", { text: "Subjects" }), el("th", { text: "Entries" }), el("th", { text: "" }), el("th", { text: "" }))), tbody)));
    }
    p.appendChild(card);
  }
  async function retireTemplate(f) {
    try { await api("POST", "api/form/retire", { name: f.name, retired: !f.retired_at }); loadTemplates(); } catch (e) { toast(e.message, "error"); }
  }

  async function openBuilder(name, copy) {
    let b = { isNew: true, name: "", label: "", description: "", note: "", def: { format: 1, header: DEFAULT_HEADER.map((h) => ({ ...h })), sections: [{ title: "", fields: [{ widget: "number", variable: "", label: "", required: false }] }] }, variables: {}, version: null };
    if (name) {
      try {
        const bundle = await api("GET", "api/form" + q({ name }));
        b = { isNew: !!copy, name: copy ? "" : bundle.form.name, label: copy ? bundle.form.label + " (copy)" : bundle.form.label, description: bundle.form.description || "", note: "", def: JSON.parse(JSON.stringify(bundle.definition)), variables: bundle.variables, version: copy ? null : bundle.version };
      } catch (e) { toast(e.message, "error"); return; }
    }
    if (!b.def.header) b.def.header = [];
    S.builder = b;
    $("template-list").hidden = true;
    renderBuilder();
  }
  function closeBuilder() { S.builder = null; $("builder").hidden = true; $("template-list").hidden = false; loadTemplates(); }

  const validateLater = debounce(validateBuilder, 450);
  async function validateBuilder() {
    const b = S.builder;
    if (!b) return;
    const box = document.getElementById("builder-problems");
    if (!box) return;
    let problems = localBuilderProblems(b);
    if (!problems.length) {
      try { problems = (await api("POST", "api/form/validate", { definition: cleanDefinition(b.def) })).problems.map((p) => `${p.path}: ${p.problem}`); }
      catch (e) { if (e instanceof NetError) problems = ["(the server cannot be reached to check the template)"]; else problems = [e.message]; }
    }
    clear(box);
    if (!problems.length) box.appendChild(el("p", { class: "ok", text: "No problems: the template can be published." }));
    else box.appendChild(el("ul", { class: "problems" }, problems.map((p) => el("li", { text: p }))));
    const pub = document.getElementById("btn-publish");
    if (pub) pub.disabled = problems.length > 0;
  }
  function canonicalName(s) { return (s || "").toLowerCase().replace(/\s+/g, " ").trim(); }
  function localBuilderProblems(b) {
    const out = [];
    if (b.isNew) {
      const n = canonicalName(b.name);
      if (!/^[a-z][a-z0-9_-]*( [a-z0-9_-]+)*$/.test(n) || n.length > 63) out.push("Name: words of letters, digits, _ or -, separated by single spaces, starting with a letter (e.g. daily check)");
      if (S.templates.some((t) => t.name === n)) out.push(`Name: a template named "${n}" already exists; edit it instead`);
    }
    return out;
  }
  // The definition as stored: empty optional keys left out, names canonical.
  function cleanDefinition(def) {
    const out = { format: 1 };
    if (def.header && def.header.length) out.header = def.header.map((h) => {
      if (h.item) return { item: h.item };
      const x = { variable: canonicalName(h.variable), source: h.source || "subject" };
      if (h.label && h.label.trim()) x.label = h.label.trim();
      return x;
    });
    out.sections = def.sections.map((s) => {
      const sec = {};
      if (s.title && s.title.trim()) sec.title = s.title.trim();
      sec.fields = s.fields.map((f) => {
        if (f.widget === "heading" || f.widget === "instruction") return { widget: f.widget, text: f.text || "" };
        const x = { widget: f.widget, variable: canonicalName(f.variable) };
        if (f.label && f.label.trim()) x.label = f.label.trim();
        if ((f.widget === "number" || f.widget === "integer") && f.units && f.units.trim()) x.units = f.units.trim();
        if (f.required) x.required = true;
        if ((f.widget === "number" || f.widget === "integer") && f.min != null && String(f.min).trim() !== "") x.min = String(f.min).trim();
        if ((f.widget === "number" || f.widget === "integer") && f.max != null && String(f.max).trim() !== "") x.max = String(f.max).trim();
        if (f.widget === "choice") x.options = (f.options || []).map((o) => (o.label && o.label.trim() && o.label.trim() !== o.value ? { value: o.value, label: o.label.trim() } : { value: o.value }));
        if (f.help && f.help.trim()) x.help = f.help.trim();
        if (f.show_previous) x.show_previous = true;
        return x;
      });
      return sec;
    });
    return out;
  }

  function renderBuilder() {
    const b = S.builder, root = clear($("builder"));
    root.hidden = false;
    const changed = () => { validateLater(); renderPreview(); };
    const meta = el("div", { class: "card" });
    meta.appendChild(el("div", { class: "row between gap" },
      el("h2", { text: b.isNew ? "New template" : `Edit template: ${b.label} (v${b.version} → v${b.version + 1})` }),
      el("button", { type: "button", onclick: closeBuilder, text: "Close" })));
    const nameIn = el("input", { value: b.name, disabled: !b.isNew, placeholder: "daily check", spellcheck: "false" });
    nameIn.addEventListener("input", () => { b.name = nameIn.value; changed(); });
    const labelIn = el("input", { value: b.label, placeholder: "Daily check" });
    labelIn.addEventListener("input", () => { b.label = labelIn.value; renderPreview(); });
    const descIn = el("textarea", { rows: 2 });
    descIn.value = b.description;
    descIn.addEventListener("input", () => { b.description = descIn.value; });
    meta.appendChild(el("div", { class: "two-col" },
      el("label", null, "Name (never changes)", nameIn, el("span", { class: "small muted", text: "Lower case words, e.g. post-op check" })),
      el("label", null, "Label (what people see)", labelIn)));
    meta.appendChild(el("label", null, "Description", descIn));
    root.appendChild(meta);

    const cols = el("div", { class: "two-col" });
    const editor = el("div");
    editor.appendChild(headerEditor(b, changed));
    b.def.sections.forEach((sec, si) => editor.appendChild(sectionEditor(b, sec, si, changed)));
    editor.appendChild(el("button", { type: "button", onclick: () => { b.def.sections.push({ title: "", fields: [] }); renderBuilder(); }, text: "+ Section" }));
    const side = el("div");
    side.appendChild(el("div", { class: "card" }, el("h2", { text: "Checks" }), el("div", { id: "builder-problems" }, el("p", { class: "muted", text: "Checking…" }))));
    const noteIn = el("input", { placeholder: "What changed (optional)", value: b.note });
    noteIn.addEventListener("input", () => { b.note = noteIn.value; });
    const pub = el("button", { type: "button", class: "primary", id: "btn-publish", text: "Publish (Ctrl+S)", disabled: true });
    pub.addEventListener("click", publishTemplate);
    side.appendChild(el("div", { class: "card" }, el("label", null, "Version note", noteIn), el("div", { class: "actions" }, pub)));
    side.appendChild(el("div", { class: "card" }, el("h2", { text: "Preview" }), el("div", { id: "builder-preview", class: "preview" })));
    cols.appendChild(editor); cols.appendChild(side);
    root.appendChild(cols);
    S.saveAction = () => { if (!pub.disabled) publishTemplate(); };
    renderPreview();
    validateBuilder();
  }

  function moveItem(arr, i, d) { const j = i + d; if (j < 0 || j >= arr.length) return false; [arr[i], arr[j]] = [arr[j], arr[i]]; return true; }

  function headerEditor(b, changed) {
    const card = el("div", { class: "card" });
    card.appendChild(el("h2", { text: "Top of the form" }));
    card.appendChild(el("p", { class: "small muted", text: "What the person filling in the form sees first. A variable is shown with its current value on the subject or the project, or its value in the subject's previous entry on this form." }));
    b.def.header.forEach((h, i) => {
      const row = el("div", { class: "row gap builder-field" });
      if (h.item) {
        const sel = el("select", null, Object.entries(INFO_ITEMS).map(([k, v]) => el("option", { value: k, selected: k === h.item, text: v })));
        sel.addEventListener("change", () => { h.item = sel.value; changed(); });
        row.appendChild(el("span", { class: "chip", text: "info" })); row.appendChild(sel);
      } else {
        const src = el("select", null, [["subject", "on the subject"], ["project", "on the project"], ["previous_entry", "in the previous entry"]].map(([k, v]) => el("option", { value: k, selected: k === h.source, text: v })));
        src.addEventListener("change", () => { h.source = src.value; changed(); });
        const lab = el("input", { placeholder: "label (optional)", value: h.label || "" });
        lab.addEventListener("input", () => { h.label = lab.value; changed(); });
        row.appendChild(el("span", { class: "chip", text: "variable" }));
        row.appendChild(variableInput(h, b, changed, null));
        row.appendChild(src); row.appendChild(lab);
      }
      row.appendChild(el("button", { type: "button", class: "icon-btn", title: "Up", onclick: () => { if (moveItem(b.def.header, i, -1)) { renderBuilder(); } }, text: "↑" }));
      row.appendChild(el("button", { type: "button", class: "icon-btn", title: "Down", onclick: () => { if (moveItem(b.def.header, i, 1)) { renderBuilder(); } }, text: "↓" }));
      row.appendChild(el("button", { type: "button", class: "icon-btn danger", title: "Remove", onclick: () => { b.def.header.splice(i, 1); renderBuilder(); }, text: "✕" }));
      card.appendChild(row);
    });
    card.appendChild(el("div", { class: "actions" },
      el("button", { type: "button", onclick: () => { const used = new Set(b.def.header.map((h) => h.item)); const next = Object.keys(INFO_ITEMS).find((k) => !used.has(k)) || "project"; b.def.header.push({ item: next }); renderBuilder(); }, text: "+ Info item" }),
      el("button", { type: "button", onclick: () => { b.def.header.push({ variable: "", source: "subject" }); renderBuilder(); }, text: "+ Variable" })));
    return card;
  }

  function sectionEditor(b, sec, si, changed) {
    const card = el("div", { class: "card builder-section" });
    const title = el("input", { value: sec.title || "", placeholder: `Section ${si + 1} title (optional)` });
    title.addEventListener("input", () => { sec.title = title.value; changed(); });
    card.appendChild(el("div", { class: "row gap" }, el("strong", { text: `Section ${si + 1}` }), el("div", { class: "grow" }, title),
      el("button", { type: "button", class: "icon-btn", title: "Up", onclick: () => { if (moveItem(b.def.sections, si, -1)) renderBuilder(); }, text: "↑" }),
      el("button", { type: "button", class: "icon-btn", title: "Down", onclick: () => { if (moveItem(b.def.sections, si, 1)) renderBuilder(); }, text: "↓" }),
      el("button", { type: "button", class: "icon-btn danger", title: "Remove section", onclick: () => { if (b.def.sections.length > 1) { b.def.sections.splice(si, 1); renderBuilder(); } }, text: "✕" })));
    sec.fields.forEach((f, fi) => card.appendChild(fieldEditor(b, sec, f, fi, changed)));
    card.appendChild(el("div", { class: "actions" },
      el("button", { type: "button", onclick: () => { sec.fields.push({ widget: "number", variable: "", label: "" }); renderBuilder(); }, text: "+ Field" }),
      el("button", { type: "button", onclick: () => { sec.fields.push({ widget: "instruction", text: "" }); renderBuilder(); }, text: "+ Instruction" })));
    return card;
  }

  function fieldEditor(b, sec, f, fi, changed) {
    const box = el("div", { class: "builder-field" });
    const widget = el("select", null, Object.entries(WIDGET_LABELS).map(([k, v]) => el("option", { value: k, selected: k === f.widget, text: v })));
    widget.addEventListener("change", () => { f.widget = widget.value; if (f.widget === "choice" && !f.options) f.options = [{ value: "" }]; renderBuilder(); });
    const ctrls = el("div", { class: "row gap" }, widget, el("span", { class: "grow" }),
      el("button", { type: "button", class: "icon-btn", title: "Up", onclick: () => { if (moveItem(sec.fields, fi, -1)) renderBuilder(); }, text: "↑" }),
      el("button", { type: "button", class: "icon-btn", title: "Down", onclick: () => { if (moveItem(sec.fields, fi, 1)) renderBuilder(); }, text: "↓" }),
      el("button", { type: "button", class: "icon-btn danger", title: "Remove field", onclick: () => { sec.fields.splice(fi, 1); renderBuilder(); }, text: "✕" }));
    box.appendChild(ctrls);
    if (f.widget === "heading" || f.widget === "instruction") {
      const t = el(f.widget === "heading" ? "input" : "textarea", { placeholder: f.widget === "heading" ? "Heading" : "Instruction shown to the person filling in the form" });
      t.value = f.text || "";
      t.addEventListener("input", () => { f.text = t.value; changed(); });
      box.appendChild(t);
      return box;
    }
    const grid = el("div", { class: "grid" });
    const info = el("div", { class: "var-info" });
    const showInfo = () => {
      const v = b.variables[canonicalName(f.variable)];
      info.textContent = !f.variable ? "" : v ? `existing variable: ${v.value_type}${v.units ? ", " + v.units : ""}${v.retired_at ? " (retired)" : ""}` : "new variable: defined when the template is published";
    };
    grid.appendChild(el("label", null, "Variable (stored under)", variableInput(f, b, () => { showInfo(); changed(); }, f)));
    const lab = el("input", { value: f.label || "", placeholder: "label (optional)" });
    lab.addEventListener("input", () => { f.label = lab.value; changed(); });
    grid.appendChild(el("label", null, "Label", lab));
    if (f.widget === "number" || f.widget === "integer") {
      for (const [key, ph] of [["units", "e.g. um, g"], ["min", "minimum"], ["max", "maximum"]]) {
        const inp = el("input", { value: f[key] || "", placeholder: ph, spellcheck: "false" });
        inp.addEventListener("input", () => { f[key] = inp.value; changed(); });
        grid.appendChild(el("label", null, key === "units" ? "Units" : key === "min" ? "Min" : "Max", inp));
      }
    }
    box.appendChild(grid);
    box.appendChild(info); showInfo();
    if (f.widget === "choice") {
      const ta = el("textarea", { rows: 3, placeholder: "One option per line: value, or value | label" });
      ta.value = (f.options || []).map((o) => (o.label && o.label !== o.value ? `${o.value} | ${o.label}` : o.value)).join("\n");
      ta.addEventListener("input", () => {
        f.options = ta.value.split("\n").map((l) => l.trim()).filter(Boolean).map((l) => { const i = l.indexOf("|"); return i < 0 ? { value: l } : { value: l.slice(0, i).trim(), label: l.slice(i + 1).trim() }; });
        changed();
      });
      box.appendChild(el("label", null, "Options", ta));
    }
    const help = el("input", { value: f.help || "", placeholder: "help text (optional)" });
    help.addEventListener("input", () => { f.help = help.value; changed(); });
    box.appendChild(el("label", null, "Help", help));
    const req = el("input", { type: "checkbox", checked: !!f.required });
    req.addEventListener("change", () => { f.required = req.checked; changed(); });
    const prev = el("input", { type: "checkbox", checked: !!f.show_previous });
    prev.addEventListener("change", () => { f.show_previous = prev.checked; changed(); });
    box.appendChild(el("div", { class: "row gap" }, el("label", { class: "row gap" }, req, "Required"), el("label", { class: "row gap" }, prev, "Show the previous entry's value")));
    return box;
  }

  // A variable name input with suggestions from the database.
  function variableInput(target, b, changed, field) {
    const wrap = el("div", { class: "suggest grow" });
    const inp = el("input", { value: target.variable || "", placeholder: "variable name, e.g. probe depth", spellcheck: "false", autocomplete: "off" });
    const list = el("ul", { class: "results", hidden: true });
    let seq = 0;
    const lookup = debounce(async () => {
      const my = ++seq;
      let rows = [];
      try { rows = (await api("GET", "api/variables" + q({ q: inp.value.trim() }))).variables; } catch (e) { return; }
      if (my !== seq) return;
      for (const r of rows) b.variables[r.name] = r;
      clear(list);
      for (const r of rows.slice(0, 12)) list.appendChild(el("li", { onmousedown: (e) => {
        e.preventDefault(); inp.value = r.name; target.variable = r.name;
        if (field && r.units && (field.widget === "number" || field.widget === "integer")) field.units = r.units;
        if (field && !field.label) field.label = r.label !== r.name ? r.label : "";
        if (field && r.value_type === "text" && (field.widget === "number" || field.widget === "integer")) field.widget = "text";
        list.hidden = true; renderBuilder();
      } }, el("strong", { text: r.name }), " ", el("span", { class: "muted small", text: `${r.value_type}${r.units ? ", " + r.units : ""}${r.retired_at ? ", retired" : ""} · ${r.label}` })));
      list.hidden = !rows.length || document.activeElement !== inp;
    }, 250);
    inp.addEventListener("input", () => { target.variable = inp.value; changed(); lookup(); });
    inp.addEventListener("focus", lookup);
    inp.addEventListener("blur", () => { setTimeout(() => { list.hidden = true; }, 150); });
    wrap.appendChild(inp); wrap.appendChild(list);
    return wrap;
  }

  function renderPreview() {
    const box = document.getElementById("builder-preview");
    if (!box) return;
    clear(box);
    const b = S.builder, def = cleanDefinition(b.def);
    box.appendChild(el("h3", { text: b.label || "(no label)" }));
    if (def.header) box.appendChild(el("div", { class: "header-card" }, def.header.map((h) => el("div", { class: "header-item" },
      el("div", { class: "k", text: h.item ? INFO_ITEMS[h.item] || h.item : (h.label || h.variable || "(variable)") + (h.source === "previous_entry" ? " (previous entry)" : h.source === "project" ? " (project)" : "") }),
      el("div", { class: "v muted", text: "…" })))));
    box.appendChild(el("div", { class: "session-row" }, el("div", { class: "field" }, el("span", { class: "flabel", text: "Session date and time" }), el("input", { type: "datetime-local" })), el("div", { class: "field" }, el("span", { class: "flabel", text: "Session label" }), el("input", { type: "text" }))));
    let n = 0;
    for (const sec of def.sections) {
      if (sec.title) box.appendChild(el("h3", { text: sec.title }));
      for (const f of sec.fields) {
        if (f.widget === "heading") { box.appendChild(el("h3", { text: f.text })); continue; }
        if (f.widget === "instruction") { box.appendChild(el("div", { class: "instruction", text: f.text })); continue; }
        const ctl = fieldControl(f, "pv-" + (n++), b.variables);
        const v = b.variables[f.variable] || {};
        box.appendChild(el("div", { class: "field" }, el("span", { class: "flabel" }, (f.label || v.label || f.variable || "(field)") + (ctl.units ? ` (${ctl.units})` : ""), f.required ? el("span", { class: "req", text: "*" }) : null), ctl.input, f.help ? el("div", { class: "help", text: f.help }) : null));
      }
    }
    box.appendChild(el("div", { class: "field" }, el("span", { class: "flabel", text: "Note" }), el("textarea", { rows: 2 })));
  }

  async function publishTemplate() {
    const b = S.builder;
    const name = b.isNew ? canonicalName(b.name) : b.name;
    const def = cleanDefinition(b.def);
    try {
      const out = await api("POST", "api/form/publish", { name, label: b.label.trim() || null, description: b.description, definition: def, note: b.note.trim() || null });
      toast(out.is_new ? `Published ${out.name} version ${out.version}.` : `Nothing changed: ${out.name} stays at version ${out.version}.`);
      closeBuilder();
      if (S.subject) reloadSubject();
    } catch (e) {
      if (e.data && e.data.code === "CLB02") toast("The template has problems; see Checks.", "error");
      else toast(e instanceof NetError ? "The server cannot be reached; publish when it answers again." : e.message, "error");
      validateBuilder();
    }
  }

  // ---------------------------------------------------------------- dialogs
  function openDialog(build) {
    return new Promise((resolve) => {
      const d = clear($("dialog"));
      const done = (v) => { d.close(); resolve(v); };
      build(d, done);
      d.onclose = () => resolve(null);
      d.oncancel = (e) => { e.preventDefault(); done(null); };
      d.showModal();
    });
  }
  function confirmDialog(title, text, okText) {
    return openDialog((d, done) => {
      d.appendChild(el("h2", { text: title }));
      d.appendChild(el("p", { text }));
      const ok = el("button", { type: "button", class: "primary", text: okText || "OK", onclick: () => done(true) });
      d.appendChild(el("div", { class: "actions" }, ok, el("button", { type: "button", text: "Cancel", onclick: () => done(false) })));
      setTimeout(() => ok.focus(), 0);
    }).then((v) => v === true);
  }
  function inputDialog(title, text, value, multiline, okText) {
    return openDialog((d, done) => {
      d.appendChild(el("h2", { text: title }));
      d.appendChild(el("p", { class: "muted", text }));
      const inp = el(multiline ? "textarea" : "input", { rows: multiline ? 4 : null });
      inp.value = value || "";
      inp.className = "wide";
      const ok = el("button", { type: "button", class: "primary", text: okText || "Save", onclick: () => done(inp.value) });
      inp.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey || !multiline)) { e.preventDefault(); done(inp.value); } });
      d.appendChild(inp);
      d.appendChild(el("div", { class: "actions" }, ok, el("button", { type: "button", text: "Cancel", onclick: () => done(null) }), multiline ? el("span", { class: "small muted", text: "Ctrl+Enter saves" }) : null));
      setTimeout(() => inp.focus(), 0);
    });
  }
  function infoDialog(title, body) {
    return openDialog((d, done) => {
      d.appendChild(el("h2", { text: title }));
      d.appendChild(body);
      const ok = el("button", { type: "button", class: "primary", text: "Close", onclick: () => done(true) });
      d.appendChild(el("div", { class: "actions" }, ok));
      setTimeout(() => ok.focus(), 0);
    });
  }
  function showHelp() {
    const rows = [["Ctrl+S", "Save the entry, or publish the template being edited"], ["Ctrl+K", "Go to the subject search"], ["Ctrl+E", "Change the note of the entry row that has focus (Tab to a row)"],
      ["Alt+1 / Alt+2 / Alt+3", "Enter data / Templates / Unsent"], ["↑ ↓ Enter", "Choose a subject in the search results"], ["Esc", "Close a dialog or the search results"], ["Ctrl+?", "This list"]];
    infoDialog("Keyboard shortcuts", el("table", null, el("tbody", null, rows.map(([k, v]) => el("tr", null, el("td", null, el("kbd", { text: k })), el("td", { text: v }))))));
  }

  // ------------------------------------------------------------- keyboard
  function onKey(e) {
    const ctrl = e.ctrlKey || e.metaKey;
    if (ctrl && (e.key === "?" || (e.shiftKey && e.key === "/"))) { e.preventDefault(); showHelp(); return; }
    if (!S.session) return;
    if (ctrl && (e.key === "s" || e.key === "S")) {
      e.preventDefault();
      if ($("dialog").open) return;
      if (S.view === "templates" && S.builder && S.saveAction) S.saveAction();
      else if (S.view === "enter" && !$("entry-panel").hidden && S.saveAction) S.saveAction();
      return;
    }
    if (ctrl && (e.key === "k" || e.key === "K")) { e.preventDefault(); showView("enter"); $("subject-search").focus(); $("subject-search").select(); return; }
    if (ctrl && (e.key === "e" || e.key === "E")) {
      const tr = document.activeElement && document.activeElement.closest && document.activeElement.closest("tr.focusable");
      if (tr && tr._entry) { e.preventDefault(); editNote(tr._entry); }
      return;
    }
    if (e.altKey && ["1", "2", "3"].includes(e.key)) { e.preventDefault(); showView(["enter", "templates", "outbox"][+e.key - 1]); }
  }

  // ------------------------------------------------------------------ boot
  function applyTheme(t) {
    if (t === "light" || t === "dark") document.documentElement.dataset.theme = t;
    else delete document.documentElement.dataset.theme;
  }
  async function boot() {
    applyTheme(lsGet("caraslab-forms-theme", ""));
    $("btn-theme").addEventListener("click", () => {
      const cur = document.documentElement.dataset.theme || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
      const next = cur === "dark" ? "light" : "dark";
      applyTheme(next); lsSet("caraslab-forms-theme", next);
    });
    $("btn-help").addEventListener("click", showHelp);
    $("btn-logout").addEventListener("click", doLogout);
    $("login-form").addEventListener("submit", doLogin);
    for (const t of document.querySelectorAll(".tab")) t.addEventListener("click", () => showView(t.dataset.view));
    const search = $("subject-search");
    search.addEventListener("input", debounce(searchSubjects, 200));
    search.addEventListener("keydown", searchKeys);
    search.addEventListener("blur", () => setTimeout(() => { $("subject-results").hidden = true; }, 150));
    $("btn-send-now").addEventListener("click", async () => { const r = await flush(); toast(r && r.sent ? `${r.sent} sent.` : "Nothing could be sent now."); });
    $("btn-download-json").addEventListener("click", () => downloadOutbox("json"));
    $("btn-download-csv").addEventListener("click", () => downloadOutbox("csv"));
    document.addEventListener("keydown", onKey);
    window.addEventListener("online", () => flush());
    document.addEventListener("visibilitychange", () => { if (!document.hidden) flush(); });
    window.addEventListener("beforeunload", (e) => {
      if (OB.pendingCount) { e.preventDefault(); e.returnValue = ""; }
    });
    await obInit();
    await refreshOutboxCount();
    let sess = null;
    try { sess = await api("GET", "api/session"); } catch (e) { sess = null; }
    if (sess && sess.signed_in) {
      await signedIn(sess);
      const last = lsGet("caraslab-forms-subject", "");
      if (last) pickSubject(last);
    } else showSignedOut(S.online === false ? "The forms server cannot be reached. Entries already in this browser are kept." : "");
  }

  document.addEventListener("DOMContentLoaded", boot);
})();
