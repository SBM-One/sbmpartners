/* SBM phone app.
 *
 * One small page with no server of its own. It signs in with Supabase's email code (or link) and reads and writes
 * only through the database's phone_* functions (db/migrations/0009_phone_app.sql), which turn away anyone who is
 * not on the staff list. Three tabs: Today, To send, Replies. Everything refreshes every 30 seconds while the app
 * is open, and the moment you come back to it.
 */
(() => {
  "use strict";

  const CFG = window.SBM || {};
  const TZ = CFG.timeZone || "America/Mexico_City";
  const REFRESH_SECONDS = 30;
  const STORE = "sbm.session";
  const $app = document.getElementById("app");
  const $tabs = document.getElementById("tabs");
  const $toast = document.getElementById("toast");

  // ─────────────────────────── small helpers ───────────────────────────
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const num = (n) => Number(n || 0).toLocaleString("en-US");
  const usd = (n) => "$" + Number(n || 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const WORDS = ["Nothing", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve"];
  const spell = (n, lower) => { const w = WORDS[n] ?? num(n); return lower ? w.toLowerCase() : w; };
  const plural = (n, one, many) => `${spell(n, true)} ${n === 1 ? one : many}`;
  const clock = (d) => new Date(d).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone: TZ });
  const dayName = (d) => new Date(d).toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", timeZone: TZ });
  const shortDay = (d) => new Date(d).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", timeZone: TZ });
  const sameDay = (a, b) => shortDay(a) === shortDay(b);
  function ago(d) {
    if (!d) return "";
    const s = (Date.now() - new Date(d).getTime()) / 1000;
    if (s < 90) return "just now";
    if (s < 3600) return `${Math.round(s / 60)} min ago`;
    if (s < 86400) return `${Math.round(s / 3600)} h ago`;
    const days = Math.round(s / 86400);
    return days === 1 ? "yesterday" : `${days} days ago`;
  }
  function join(list) {
    if (list.length <= 1) return list.join("");
    return list.slice(0, -1).join(", ") + " and " + list[list.length - 1];
  }
  let toastTimer;
  function toast(msg, bad) {
    $toast.textContent = msg;
    $toast.className = bad ? "alarm" : "";
    $toast.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { $toast.hidden = true; }, bad ? 6000 : 2600);
  }

  // ─────────────────────────── sign-in (Supabase Auth over plain HTTP) ───────────────────────────
  const auth = {
    get() { try { return JSON.parse(localStorage.getItem(STORE) || "null"); } catch { return null; } },
    set(s) { localStorage.setItem(STORE, JSON.stringify(s)); },
    clear() { localStorage.removeItem(STORE); },
  };
  const headers = (token) => ({ apikey: CFG.anonKey, "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) });
  const keep = (j) => ({ access_token: j.access_token, refresh_token: j.refresh_token,
    expires_at: j.expires_at || Math.floor(Date.now() / 1000) + (j.expires_in || 3600), email: j.user?.email });

  async function authPost(path, body) {
    const r = await fetch(`${CFG.supabaseUrl}/auth/v1/${path}`, { method: "POST", headers: headers(), body: JSON.stringify(body) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(j.msg || j.error_description || j.message || `Sign-in failed (${r.status})`);
    return j;
  }
  const sendCode = (email) => authPost("otp", { email, create_user: true });
  async function verifyCode(email, token) { auth.set(keep(await authPost("verify", { type: "email", email, token }))); }
  async function refresh() {
    const s = auth.get();
    if (!s?.refresh_token) throw new Error("signed out");
    auth.set(keep(await authPost("token?grant_type=refresh_token", { refresh_token: s.refresh_token })));
  }
  // A sign-in link opened on this device arrives with the tokens in the address.
  function takeLinkTokens() {
    const h = new URLSearchParams(location.hash.replace(/^#/, ""));
    if (!h.get("access_token")) return;
    auth.set({ access_token: h.get("access_token"), refresh_token: h.get("refresh_token"),
      expires_at: Number(h.get("expires_at")) || Math.floor(Date.now() / 1000) + Number(h.get("expires_in") || 3600) });
    history.replaceState(null, "", location.pathname + "#today");
  }

  async function rpc(fn, args = {}, retried = false) {
    let s = auth.get();
    if (!CFG.dev) {
      if (!s) throw Object.assign(new Error("Sign in first."), { signedOut: true });
      if (s.expires_at - 60 < Date.now() / 1000) { await refresh().catch(() => {}); s = auth.get(); }
    }
    const r = await fetch(`${CFG.supabaseUrl}/rest/v1/rpc/${fn}`, {
      method: "POST", headers: headers(CFG.dev ? "dev" : s?.access_token), body: JSON.stringify(args) });
    if (r.status === 401 && !retried && !CFG.dev) {
      try { await refresh(); return rpc(fn, args, true); } catch { auth.clear(); throw Object.assign(new Error("Signed out."), { signedOut: true }); }
    }
    const text = await r.text();
    const j = text ? JSON.parse(text) : null;
    if (!r.ok) {
      const e = new Error(j?.message || `Something went wrong (${r.status})`);
      if (/not on the team/i.test(e.message)) e.notStaff = true;
      throw e;
    }
    return j;
  }

  // ─────────────────────────── state ───────────────────────────
  const state = { today: null, queue: null, inbox: null, loadedAt: null, editing: new Set(), logging: new Set(), done: new Map(), armed: null };
  async function load() {
    const [today, queue, inbox] = await Promise.all([rpc("phone_today"), rpc("phone_queue"), rpc("phone_inbox")]);
    Object.assign(state, { today, queue, inbox, loadedAt: new Date() });
  }

  // ─────────────────────────── what each draft is ───────────────────────────
  const KIND = { email: "Email", linkedin: "LinkedIn", whatsapp: "WhatsApp", call: "Call" };
  const kindOf = (d) => (KIND[d.kind] ? d.kind : "other");

  // LinkedIn drafts hold two parts ("NOTA DE CONEXIÓN:" and "MENSAJE TRAS ACEPTAR:") and sometimes a profile line.
  function parts(d) {
    let profile = d.linkedin_url || null;
    const lines = String(d.body || "").split("\n").filter((l) => {
      const m = l.match(/^\s*(perfil|profile)\s*:\s*(https?:\/\/\S+)/i);
      if (m) { profile = profile || m[2]; return false; }
      return true;
    });
    const out = [];
    let cur = { title: null, lines: [] };
    for (const l of lines) {
      const h = l.match(/^\s*([A-ZÁÉÍÓÚÑÜ][A-ZÁÉÍÓÚÑÜ0-9 ,+/()-]{3,})\s*:\s*$/);
      if (h) { if (cur.lines.join("").trim()) out.push(cur); cur = { title: h[1], lines: [] }; } else cur.lines.push(l);
    }
    if (cur.lines.join("").trim()) out.push(cur);
    const titled = out.map((p) => ({ title: p.title ? p.title.charAt(0) + p.title.slice(1).toLowerCase() : null, text: p.lines.join("\n").trim() }));
    return { profile, parts: titled.length ? titled : [{ title: null, text: String(d.body || "").trim() }] };
  }
  const waLink = (d) => d.number ? `https://wa.me/${d.number}?text=${encodeURIComponent(String(d.body || "").trim())}` : null;
  const telLink = (d) => d.number ? `tel:+${d.number}` : null;
  const prettyNumber = (n) => n ? "+" + n.replace(/^(52)(\d{2,3})(\d{3,4})(\d{4})$/, "$1 $2 $3 $4") : "";

  // ─────────────────────────── screens ───────────────────────────
  const top = (meta) => `<header class="top"><span class="wordmark">SBM<i>Partners</i></span><span class="meta">${esc(meta || "")}</span></header>`;

  function waitingCounts() {
    const q = state.queue || [];
    const c = { email: 0, linkedin: 0, whatsapp: 0, call: 0, other: 0 };
    for (const d of q) if (!state.done.has(d.id)) c[kindOf(d)]++;
    return c;
  }

  const TASKS = {
    research_prospect: ["Researcher", "buyer looked up", "buyers looked up", "Looked up"],
    qualify_prospect: ["Researcher", "buyer scored", "buyers scored", "Scored"],
    draft_outreach: ["Writer", "first message drafted", "first messages drafted", "Drafted a first message to"],
    draft_reply: ["Writer", "answer drafted", "answers drafted", "Drafted an answer to"],
    prepare_handoff: ["Writer", "meeting brief", "meeting briefs", "Wrote a meeting brief on"],
    write_report: ["Writer", "weekly letter", "weekly letters", "Wrote the weekly letter"],
  };
  const task = (k) => TASKS[k] || [k.replace(/_/g, " "), "task", "tasks", k.replace(/_/g, " ")];

  function renderToday() {
    const t = state.today;
    const c = waitingCounts();
    const parts = [];
    if (c.linkedin) parts.push(plural(c.linkedin, "LinkedIn note", "LinkedIn notes"));
    if (c.whatsapp) parts.push(plural(c.whatsapp, "WhatsApp", "WhatsApps"));
    if (c.call) parts.push(plural(c.call, "call", "calls"));
    if (c.email) parts.push(plural(c.email, "email to approve", "emails to approve"));
    const total = c.linkedin + c.whatsapp + c.call + c.email + c.other;
    const urgent = (t.alerts || []).filter((a) => a.severity === "urgent").length;
    let sentence = total === 0 ? "Nothing is waiting for you." : `${join(parts) || plural(total, "message", "messages")} ${total === 1 ? "is" : "are"} waiting for you.`;
    sentence = sentence.charAt(0).toUpperCase() + sentence.slice(1);

    const sent = t.sent_today || {};
    const q = t.quota;
    const work = (t.work || []).filter((w) => w.done || w.running || w.queued || w.failed);

    let h = top(dayName(new Date()));
    h += `<h1 class="statement">${esc(sentence)}${urgent ? ` <span class="alarm">${spell(urgent)} alert${urgent === 1 ? " needs" : "s need"} you now.</span>` : ""}</h1>`;
    h += `<p class="standfirst">Today: <b>${num(sent.email)}</b> email${sent.email === 1 ? "" : "s"} and <b>${num(sent.by_hand)}</b> by hand sent, `
      + `<b>${num(t.replies_today)}</b> repl${t.replies_today === 1 ? "y" : "ies"}`
      + `${t.meetings_ready ? `, and <b>${num(t.meetings_ready)}</b> meeting brief${t.meetings_ready === 1 ? "" : "s"} ready` : ""}. `
      + `The agents have spent ${usd(t.spend?.spent)} of this month's ${usd(t.spend?.budget)}.</p>`;
    if (total) h += `<p class="acts"><a class="btn" href="#send">Start sending</a></p>`;

    if (q) {
      const meter = (label, n, of) => `<div class="meter"><span>${esc(label)}</span><span class="val">${num(n)} of ${esc(of)}</span>`
        + `<span class="bar"><i style="width:${Math.min(100, Math.round((Number(n) / Math.max(1, parseInt(of, 10))) * 100))}%"></i></span></div>`;
      h += `<section class="section"><div class="sh"><h2>Research today</h2><span class="aside">${num(q.waiting)} businesses in line</span></div>`
        + meter("Businesses screened", q.screened, q.screen_per_day)
        + meter("Buyers researched and passed", q.passed, q.research_per_day)
        + meter("First messages drafted", q.drafted, `${q.drafts_min}–${q.drafts_max}`)
        + (q.failed_attempts ? `<p class="sub" style="margin-top:8px">${num(q.failed_attempts)} research attempt${q.failed_attempts === 1 ? "" : "s"} sent back for more sources.</p>` : "")
        + `</section>`;
    }

    h += `<section class="section"><div class="sh"><h2>Done today<span class="n">${num(work.reduce((n, w) => n + w.done, 0))}</span></h2><span class="aside">Since midnight</span></div>`;
    if (!work.length) h += `<p class="empty">The agents haven't started today. Their work shows here as it finishes.</p>`;
    for (const w of work) {
      const [agent, one, many] = task(w.kind);
      h += `<div class="row"><span class="lead">${esc(agent)}</span><div><div class="name">${w.done ? esc(`${num(w.done)} ${w.done === 1 ? one : many}`) : `<span class="muted">Nothing finished yet</span>`}</div>`
        + `<div class="figs"><div><span>Working now</span>${w.running ? num(w.running) : "–"}</div><div><span>In line</span>${w.queued ? num(w.queued) : "–"}</div>`
        + `<div><span>Failed</span>${w.failed ? `<b class="alarm">${num(w.failed)}</b>` : "–"}</div></div></div></div>`;
    }
    for (const l of (t.latest || []).slice(0, 6)) {
      const [agent, , , did] = task(l.kind);
      const when = clock(l.finished_at) + (sameDay(l.finished_at, new Date()) ? "" : "\nYesterday");
      h += `<div class="row"><span class="lead" style="white-space:pre-line">${esc(when)}</span><div>`
        + `<div class="${l.status === "failed" ? "alarm" : ""}">${l.status === "failed" ? "Failed: " : ""}${esc(l.company ? `${did} ${l.company}` : did.replace(/ (to|on|for)$/, ""))}.</div>`
        + `<div class="sub">${esc(agent)}${l.error ? ". " + esc(l.error) : ""}</div></div></div>`;
    }
    h += `</section>`;

    if ((t.alerts || []).length) {
      h += `<section class="section"><div class="sh"><h2>Alerts<span class="n">${t.alerts.length}</span></h2></div>`;
      for (const a of t.alerts) {
        h += `<div class="row"><span class="lead ${a.severity === "urgent" ? "alarm" : ""}">${a.severity === "urgent" ? "Urgent" : "Alert"}</span><div>`
          + `<div>${esc(a.message)}</div><div class="sub">${esc(ago(a.created_at))}${a.status === "acknowledged" ? ", seen" : ""}</div>`
          + `<div class="acts" style="margin-top:6px">${a.status === "open" ? `<button class="link quiet" data-alert="${a.id}" data-status="acknowledged">Seen</button>` : ""}`
          + `<button class="link" data-alert="${a.id}" data-status="resolved">Resolve</button></div></div></div>`;
      }
      h += `</section>`;
    }
    h += foot();
    return h;
  }

  function foot() {
    return `<p class="foot"><span>${esc(state.today?.me || "")}${state.loadedAt ? " · updated " + esc(clock(state.loadedAt)) : ""}</span>`
      + `${CFG.dev ? "<span>Local preview</span>" : `<button class="link quiet" data-signout>Sign out</button>`}</p>`;
  }

  function renderSend(filter) {
    const all = (state.queue || []).filter((d) => !state.done.has(d.id) || state.done.get(d.id).show);
    const c = waitingCounts();
    const shown = filter && filter !== "all" ? all.filter((d) => kindOf(d) === filter) : all;
    const tab = (key, label, n) => `<a href="#send/${key}" class="${(filter || "all") === key ? "on" : ""}">${label}${n ? `<sup>${n}</sup>` : ""}</a>`;
    const total = c.linkedin + c.whatsapp + c.call + c.email + c.other;

    let h = top(total ? `${num(total)} waiting` : "All clear");
    h += `<nav class="filters">${tab("all", "All", total)}${tab("linkedin", "LinkedIn", c.linkedin)}${tab("whatsapp", "WhatsApp", c.whatsapp)}`
      + `${tab("call", "Calls", c.call)}${tab("email", "Email", c.email)}</nav>`;
    if (!shown.length) return h + `<p class="empty" style="margin-top:18px">Nothing here. New messages appear as the agents write them.</p>` + foot();
    if (filter === "linkedin") h += `<p class="standfirst">Tap Copy note, then on their profile: Connect, Add a note, paste. Keep it to about 5 a day while the account is new.</p>`;
    if (filter === "whatsapp") h += `<p class="standfirst">Opens WhatsApp with the message typed. Read it, then press send. No more than 3 cold messages a day on a new number.</p>`;
    for (const d of shown) h += renderItem(d);
    return h + foot();
  }

  function renderItem(d) {
    const k = kindOf(d);
    const done = state.done.get(d.id);
    const who = [d.contact, d.company].filter(Boolean).join(", ") || "(no name)";
    const role = [d.title, d.client ? `for ${d.client}` : null].filter(Boolean).join(", ");
    let label = KIND[k] || "Message";
    if (d.purpose === "reply") label += ", answer to their reply";
    else if (d.step > 1) label += `, follow-up ${d.step - 1}`;
    let h = `<article class="item" id="d-${d.id}"><div class="kind"><span>${esc(label)}</span><span>${esc(ago(d.created_at))}</span></div>`
      + `<div class="name">${esc(who)}</div>${role ? `<div class="sub">${esc(role)}</div>` : ""}`;
    if (done) return h + `<p class="done-note">${esc(done.note)}</p></article>`;

    const blockers = (d.blockers || []).filter(Boolean);
    const editing = state.editing.has(d.id);

    if (k === "email") {
      if (editing) {
        h += `<div class="part"><h4>Subject</h4><input class="subject" data-subject value="${esc(d.subject || "")}"></div>`
          + `<div class="part"><h4>Message</h4><textarea data-body rows="10">${esc(d.body)}</textarea></div>`;
      } else {
        h += `${d.subject ? `<div class="part"><h4>Subject</h4><p class="text subject">${esc(d.subject)}</p></div>` : ""}`
          + `<div class="part"><h4>To ${esc(d.email || "no address")}</h4><p class="text">${esc(d.body)}</p></div>`;
      }
      if (d.score != null) h += `<p class="count">Reviewer's grade: ${Math.round(d.score)} of 100${d.grade_feedback ? ". " + esc(d.grade_feedback) : ""}</p>`;
    } else {
      const p = k === "linkedin" ? parts(d) : { parts: [{ title: null, text: String(d.body || "").trim() }] };
      p.parts.forEach((part, i) => {
        const limit = k === "linkedin" && i === 0 && p.parts.length > 1 ? 200 : null;
        h += `<div class="part">${part.title ? `<h4>${esc(part.title)}</h4>` : k === "call" ? "<h4>What to say</h4>" : ""}`
          + `<p class="text">${esc(part.text)}</p>`
          + (limit ? `<p class="count ${part.text.length > limit ? "over" : ""}">${part.text.length} of ${limit} characters</p>` : "")
          + (k === "linkedin" && i > 0 ? `<div class="acts" style="margin-top:8px"><button class="link" data-copy="${d.id}" data-part="${i}">Copy this message</button></div>` : "")
          + `</div>`;
      });
    }
    if (blockers.length) h += `<div class="blockers">Not allowed yet:<ul>${blockers.map((b) => `<li>${esc(b)}</li>`).join("")}</ul></div>`;

    h += `<div class="acts">`;
    if (k === "email") {
      if (editing) h += `<button class="btn" data-approve="${d.id}">Save and approve</button><button class="link quiet" data-edit="${d.id}">Cancel</button>`;
      else h += `<button class="btn" data-approve="${d.id}" ${blockers.length ? "disabled" : ""}>Approve</button><button class="link" data-edit="${d.id}">Edit</button>`;
      h += `<button class="link alarm" data-reject="${d.id}">${state.armed === d.id ? "Tap again to reject" : "Reject"}</button>`;
    } else {
      const off = blockers.length ? "disabled" : "";
      if (k === "linkedin") {
        const p = parts(d);
        h += p.profile ? `<button class="btn" data-copy="${d.id}" data-part="0" data-open="${esc(p.profile)}" data-log="${d.id}" ${off}>Copy note, open profile</button>`
          : `<button class="btn" data-copy="${d.id}" data-part="0" data-log="${d.id}" ${off}>Copy note</button><span class="sub alarm">No profile link on file</span>`;
      } else if (k === "whatsapp") {
        const wa = waLink(d);
        h += wa && !off ? `<a class="btn" href="${esc(wa)}" target="_blank" rel="noopener noreferrer" data-log="${d.id}">Open WhatsApp</a>`
          : wa ? `<button class="btn" disabled>Open WhatsApp</button>` : `<span class="sub alarm">No WhatsApp number on file</span>`;
      } else if (k === "call") {
        const tel = telLink(d);
        h += tel ? `<a class="btn" href="${esc(tel)}" data-log="${d.id}">Call ${esc(prettyNumber(d.number))}</a>` : `<span class="sub alarm">No number on file</span>`;
      }
      if (!off) h += `<button class="link" data-log="${d.id}">${k === "call" ? "Already called" : "Already sent it"}</button>`;
      h += `<button class="link quiet" data-skip="${d.id}">Skip</button>`;
      if (!off) h += `<p class="count" style="flex-basis:100%">Tapping ${k === "call" ? "Call" : "it"} logs ${k === "call" ? "the call" : "it as sent"}, so nobody gets it twice.</p>`;
    }
    return h + `</div></article>`;
  }

  function renderInbox() {
    const ib = state.inbox || { replies: [], meetings: [] };
    let h = top(`${num(ib.replies.length)} in the last 30 days`);
    const ready = ib.meetings.filter((m) => m.status === "ready");
    const booked = ib.meetings.filter((m) => m.status === "booked");
    const fresh = ib.replies.filter((r) => Date.now() - new Date(r.occurred_at) < 86400000 * 2).length;
    const said = [];
    if (fresh) said.push(`${plural(fresh, "buyer", "buyers")} wrote back in the last two days`);
    if (ready.length) said.push(`${spell(ready.length, true)} ${ready.length === 1 ? "is" : "are"} ready for a meeting`);
    let s = said.length ? join(said) + "." : ib.replies.length ? "No new replies in the last two days." : "No replies yet.";
    s = s.charAt(0).toUpperCase() + s.slice(1);
    h += `<h1 class="statement">${esc(s)}</h1>`;

    if (ib.meetings.length) {
      h += `<section class="section"><div class="sh"><h2>Meetings<span class="n">${ib.meetings.length}</span></h2><span class="aside">${num(booked.length)} booked</span></div>`;
      for (const m of ib.meetings) {
        const who = [m.contact, m.company].filter(Boolean).join(", ");
        h += `<div class="row reply"><span class="lead">${m.status === "booked" ? esc(m.meeting_at ? shortDay(m.meeting_at) + "\n" + clock(m.meeting_at) : "Booked") : "Ready"}</span><div>`
          + `<div class="name">${esc(who)}</div><div class="sub">${esc([m.contact_title, m.client ? "for " + m.client : null].filter(Boolean).join(", "))}</div>`
          + (m.interest ? `<p class="summary">${esc(m.interest)}</p>` : "")
          + `<details><summary>Read the brief</summary><p class="text" style="white-space:pre-wrap">${esc(m.body)}</p></details>`
          + `<div class="acts" style="margin-top:6px">${m.email ? `<a class="link" href="mailto:${esc(m.email)}">Email</a>` : ""}`
          + `${m.phone ? `<a class="link" href="tel:${esc(m.phone.replace(/[^\d+]/g, ""))}">Call</a>` : ""}`
          + `${m.linkedin_url ? `<a class="link" href="${esc(m.linkedin_url)}" target="_blank" rel="noopener noreferrer">LinkedIn</a>` : ""}</div>`
          + `</div></div>`;
      }
      h += `</section>`;
    }

    h += `<section class="section"><div class="sh"><h2>Replies<span class="n">${ib.replies.length}</span></h2><span class="aside">Newest first</span></div>`;
    if (!ib.replies.length) h += `<p class="empty">When a buyer answers, it shows here, and the Writer's answer waits in To send.</p>`;
    for (const r of ib.replies) {
      const who = [r.contact, r.company].filter(Boolean).join(", ") || "Unknown sender";
      h += `<div class="row reply"><span class="lead" style="white-space:pre-line">${esc(sameDay(r.occurred_at, new Date()) ? clock(r.occurred_at) : shortDay(r.occurred_at))}\n${esc(KIND[r.channel] || r.channel)}</span><div>`
        + `<div class="name">${esc(who)}</div>`
        + (r.category ? `<div class="sub">${esc(r.category.replace(/_/g, " "))}${r.client ? ", for " + esc(r.client) : ""}</div>` : "")
        + (r.summary ? `<p class="summary">${esc(r.summary)}</p>` : "")
        + (r.body ? `<details><summary>${r.subject ? esc(r.subject) : "Their message"}</summary><p class="text" style="white-space:pre-wrap">${esc(r.body)}</p></details>` : "")
        + (r.answer_waiting ? `<div class="acts" style="margin-top:6px"><a class="link" href="#send/email">Our answer is waiting</a></div>` : "")
        + `</div></div>`;
    }
    return h + `</section>` + foot();
  }

  function renderSignIn(step, email, err) {
    $tabs.hidden = true;
    let h = `<div class="signin">${top("")}<h1 class="statement">Sign in to see what your agents are doing.</h1>`;
    if (step === "code") {
      h += `<form data-form="code"><p class="note">We emailed a 6-digit code to <b>${esc(email)}</b>. Type it here. (If you tap the link in the email instead, open it on this phone.)</p>`
        + `<label for="code">Code</label><input id="code" class="code" name="code" inputmode="numeric" autocomplete="one-time-code" maxlength="10" required>`
        + `<button class="btn">Sign in</button><button type="button" class="link quiet" data-restart>Use a different email</button></form>`;
    } else {
      h += `<form data-form="email"><label for="email">Your work email</label>`
        + `<input id="email" name="email" type="email" autocomplete="email" inputmode="email" value="${esc(email || "")}" required>`
        + `<button class="btn">Email me a code</button><p class="note">No password. Only people on the team get in.</p></form>`;
    }
    if (err) h += `<p class="blockers" style="margin-top:16px">${esc(err)}</p>`;
    $app.innerHTML = h + `</div>`;
    $app.querySelector("input")?.focus();
  }

  // ─────────────────────────── routing and drawing ───────────────────────────
  const route = () => {
    const [tab, filter] = (location.hash.replace(/^#/, "") || "today").split("/");
    return { tab: ["today", "send", "inbox"].includes(tab) ? tab : "today", filter };
  };
  function draw(force) {
    if (!state.today) return;
    // Never redraw under your thumb while you are editing a draft.
    if (!force && state.editing.size && document.activeElement?.matches("textarea, input")) return;
    const { tab, filter } = route();
    $tabs.hidden = false;
    const c = waitingCounts();
    const total = c.linkedin + c.whatsapp + c.call + c.email + c.other;
    const replies = (state.inbox?.replies || []).filter((r) => Date.now() - new Date(r.occurred_at) < 86400000 * 2).length
      + (state.inbox?.meetings || []).filter((m) => m.status === "ready").length;
    for (const a of $tabs.querySelectorAll("a")) {
      a.classList.toggle("on", a.dataset.tab === tab);
      const n = a.dataset.tab === "send" ? total : a.dataset.tab === "inbox" ? replies : 0;
      a.innerHTML = esc(a.textContent.replace(/\d+$/, "")) + (n ? `<sup>${n}</sup>` : "");
    }
    $app.innerHTML = tab === "send" ? renderSend(filter) : tab === "inbox" ? renderInbox() : renderToday();
  }

  async function sync(force) {
    try {
      await load();
      draw(force);
    } catch (e) {
      if (e.signedOut) return renderSignIn("email");
      if (e.notStaff) { auth.clear(); return renderSignIn("email", "", "This email is not on the team. Ask Santiago to add it."); }
      if (!state.today) $app.innerHTML = top("") + `<p class="empty">Couldn't load: ${esc(e.message)}. Pull down or reopen to try again.</p>`;
      else toast("Couldn't refresh: " + e.message, true);
    }
  }

  // ─────────────────────────── taps ───────────────────────────
  const find = (id) => (state.queue || []).find((d) => d.id === id);
  function finish(id, note) {
    state.done.set(id, { note, show: true });
    state.editing.delete(id);
    draw(true);
    // Let the note show for a moment, then drop the row.
    setTimeout(() => { const x = state.done.get(id); if (x) x.show = false; draw(); }, 2500);
  }
  async function act(fn, args, id, note) {
    try {
      await rpc(fn, args);
      finish(id, note);
      sync();
    } catch (e) {
      toast(e.message.replace(/^Not allowed yet: /, "Not allowed yet. "), true);
    }
  }

  document.addEventListener("click", async (ev) => {
    const b = ev.target.closest("button, a");
    if (!b) return;
    const ds = b.dataset;
    if (ds.signout !== undefined) { auth.clear(); state.today = null; return renderSignIn("email"); }
    if (ds.restart !== undefined) return renderSignIn("email");
    if (ds.alert) return act("phone_alert", { p_id: ds.alert, p_status: ds.status }, null, "").then(() => sync(true));
    if (ds.copy || ds.log) {
      // Open the profile / WhatsApp / call right away, inside the tap: Safari blocks windows opened after an await.
      if (ds.copy) {
        const d = find(ds.copy);
        const text = d.kind === "linkedin" ? parts(d).parts[Number(ds.part)]?.text : d.body;
        const copied = navigator.clipboard?.writeText(text || "");
        if (ds.open) window.open(ds.open, "_blank", "noopener");
        try { await copied; if (!ds.log) toast("Copied. Paste it in the note."); }
        catch { toast("Couldn't copy. Press and hold the text to copy it.", true); }
      }
      if (ds.log && !state.logging.has(ds.log)) {
        const d = find(ds.log);
        state.logging.add(ds.log);
        const note = d?.kind === "call" ? "Logged as called." : d?.kind === "linkedin" ? "Copied and logged as sent. Paste it in the note." : "Logged as sent.";
        act("phone_mark", { p_id: ds.log, p_op: "sent", p_body: null }, ds.log, note).finally(() => state.logging.delete(ds.log));
      }
      return;
    }
    if (ds.edit) { state.editing.has(ds.edit) ? state.editing.delete(ds.edit) : state.editing.add(ds.edit); return draw(true); }
    if (ds.approve) {
      const el = document.getElementById("d-" + ds.approve);
      const body = el.querySelector("[data-body]")?.value;
      const subject = el.querySelector("[data-subject]")?.value;
      b.disabled = true;
      return act("phone_review", { p_id: ds.approve, p_decision: "approved", p_subject: subject ?? null, p_body: body ?? null, p_note: null },
        ds.approve, "Approved. It goes out from the mailbox within its daily limit.").finally(() => { b.disabled = false; });
    }
    if (ds.reject) {
      if (state.armed !== ds.reject) { state.armed = ds.reject; draw(true); setTimeout(() => { if (state.armed === ds.reject) { state.armed = null; draw(); } }, 4000); return; }
      state.armed = null;
      return act("phone_review", { p_id: ds.reject, p_decision: "rejected", p_subject: null, p_body: null, p_note: null }, ds.reject, "Rejected.");
    }
    if (ds.skip) return act("phone_mark", { p_id: ds.skip, p_op: "skip", p_body: null }, ds.skip, "Skipped.");
  });

  document.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const f = ev.target;
    const btn = f.querySelector(".btn");
    btn.disabled = true;
    try {
      if (f.dataset.form === "email") {
        const email = f.email.value.trim().toLowerCase();
        await sendCode(email);
        sessionStorage.setItem("sbm.email", email);
        renderSignIn("code", email);
      } else {
        const email = sessionStorage.getItem("sbm.email");
        await verifyCode(email, f.code.value.replace(/\s/g, ""));
        location.hash = "#today";
        await sync(true);
      }
    } catch (e) {
      renderSignIn(f.dataset.form === "email" ? "email" : "code", sessionStorage.getItem("sbm.email"), e.message);
    } finally { btn.disabled = false; }
  });

  window.addEventListener("hashchange", () => { if (state.today) { draw(true); scrollTo(0, 0); } });
  document.addEventListener("visibilitychange", () => { if (!document.hidden && state.today) sync(); });
  setInterval(() => { if (!document.hidden && state.today) sync(); }, REFRESH_SECONDS * 1000);

  // ─────────────────────────── start ───────────────────────────
  takeLinkTokens();
  if (!CFG.dev && !auth.get()) renderSignIn("email");
  else { $app.innerHTML = top("Loading…"); sync(true); }
})();
