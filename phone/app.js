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
  const state = { today: null, queue: null, inbox: null, loadedAt: null, editing: new Set(), done: new Map(), armed: null,
    briefs: {}, findQ: "", found: null };
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
      if (k === "linkedin") {
        const p = parts(d);
        h += p.profile ? `<button class="btn" data-copy="${d.id}" data-part="0" data-open="${esc(p.profile)}">Copy note + open profile</button>`
          : `<button class="btn line" data-copy="${d.id}" data-part="0">Copy note</button><span class="sub alarm">No profile link on file</span>`;
      } else if (k === "whatsapp") {
        const wa = waLink(d);
        h += wa ? `<a class="btn" href="${esc(wa)}" target="_blank" rel="noopener noreferrer">Open WhatsApp</a>` : `<span class="sub alarm">No WhatsApp number on file</span>`;
      } else if (k === "call") {
        const tel = telLink(d);
        h += tel ? `<a class="btn" href="${esc(tel)}">Call ${esc(prettyNumber(d.number))}</a>` : `<span class="sub alarm">No number on file</span>`;
      }
      h += `<button class="btn line" data-sent="${d.id}" ${blockers.length ? "disabled" : ""}>${k === "call" ? "Called" : "Sent"}</button>`
        + `<button class="link quiet" data-skip="${d.id}">Skip</button>`;
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
    h += `<p class="acts"><a class="btn line" href="#brief">Prepare for a call</a></p>`;

    if (ib.meetings.length) {
      h += `<section class="section"><div class="sh"><h2>Meetings<span class="n">${ib.meetings.length}</span></h2><span class="aside">${num(booked.length)} booked</span></div>`;
      for (const m of ib.meetings) {
        const who = [m.contact, m.company].filter(Boolean).join(", ");
        h += `<div class="row reply"><span class="lead">${m.status === "booked" ? esc(m.meeting_at ? shortDay(m.meeting_at) + "\n" + clock(m.meeting_at) : "Booked") : "Ready"}</span><div>`
          + `<div class="name">${esc(who)}</div><div class="sub">${esc([m.contact_title, m.client ? "for " + m.client : null].filter(Boolean).join(", "))}</div>`
          + (m.interest ? `<p class="summary">${esc(m.interest)}</p>` : "")
          + `<details><summary>Read the meeting brief</summary><p class="text" style="white-space:pre-wrap">${esc(m.body)}</p></details>`
          + `<div class="acts" style="margin-top:6px">${m.contact_id ? `<a class="link" href="#brief/${esc(m.contact_id)}">Call brief</a>` : ""}${m.email ? `<a class="link" href="mailto:${esc(m.email)}">Email</a>` : ""}`
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
        + `<div class="acts" style="margin-top:6px">${r.answer_waiting ? `<a class="link" href="#send/email">Our answer is waiting</a>` : ""}`
        + `${r.contact_id ? `<a class="link quiet" href="#brief/${esc(r.contact_id)}">Call brief</a>` : ""}</div>`
        + `</div></div>`;
    }
    return h + `</section>` + foot();
  }

  // ─────────────────────────── call brief ───────────────────────────
  // One page per buyer for a booked call: who they are, what we sent and what they said, then the client's call kit
  // (cheat sheet, hard questions, script). Opened from a meeting or reply, or by searching for the buyer.
  const txt = (v) => v == null ? "" : Array.isArray(v) ? v.map(txt).filter(Boolean).join("; ")
    : typeof v === "object" ? Object.values(v).map(txt).filter(Boolean).join(": ") : String(v);
  const fullName = (c) => [c?.first_name, c?.last_name].filter(Boolean).join(" ");
  const fact = (label, value, html) => (value == null || value === "" || (Array.isArray(value) && !value.length)) ? ""
    : `<div class="row"><span class="lead">${esc(label)}</span><div class="text">${html ? value : esc(txt(value))}</div></div>`;
  const ext = (url) => /^https?:\/\//i.test(url) ? url : "https://" + url;
  const SAID = { sent: "We sent", reply: "They replied", call: "Call", voicemail: "Voicemail", meeting_booked: "Meeting booked",
    meeting_held: "Meeting held", sample_sent: "Samples sent", quote_sent: "Quote sent", order: "Order", reorder: "Reorder", note: "Note",
    opened: "Opened", clicked: "Clicked", bounce: "Bounced", unsubscribe: "Unsubscribed" };

  async function openBrief(id) {
    if (state.briefs[id]?.loading) return;
    state.briefs[id] = { loading: true };
    try { state.briefs[id] = { data: await rpc("phone_brief", { p_contact: id }) }; }
    catch (e) { state.briefs[id] = { error: e.message }; }
    if (route().tab === "brief" && route().filter === id) draw(true);
  }

  function renderBrief(id) {
    const got = state.briefs[id];
    if (!got || got.loading) { if (!got) openBrief(id); return top("Call brief") + `<p class="empty">Loading the brief…</p>`; }
    if (got.error) return top("Call brief") + `<p class="empty">Couldn't load it: ${esc(got.error)}</p><p class="acts"><a class="link" href="#brief">Search for a buyer</a></p>`;
    const b = got.data, co = b.company || {}, c = b.contact || {}, m = b.meeting, s = b.strategy, kit = b.kit;
    const person = fullName(c) || "the buyer";
    const fill = (line) => String(line).replace(/\{contacto\}/g, fullName(c) ? c.first_name || fullName(c) : "").replace(/\{empresa\}/g, co.name || "su empresa")
      .replace(/ ,/g, ",").replace(/,\s*\./g, ".");
    const phone = c.phone || co.phone;
    const wa = (c.whatsapp || c.phone || "").replace(/\D/g, "");

    let h = top(b.client ? `Call brief · ${b.client}` : "Call brief");
    h += `<p class="acts" style="margin-top:12px"><a class="link quiet" href="#inbox">Back to replies</a><a class="link quiet" href="#brief">Another buyer</a></p>`;
    h += `<h1 class="statement" style="margin-top:14px">${esc(fullName(c) ? `Call with ${person}${co.name ? ", " + co.name : ""}.` : `Call with ${co.name || "the buyer"}.`)}</h1>`;
    const when = m?.meeting_at ? `Booked for ${dayName(m.meeting_at)}, ${clock(m.meeting_at)}.` : m?.status === "ready" ? "Ready for a meeting; no time booked yet." : "";
    const where = [co.hq_city, co.hq_state].filter(Boolean).join(", ");
    h += `<p class="standfirst">${esc([c.title, where, when, m?.meeting_note].filter(Boolean).join(". ").replace(/\.\./g, "."))}</p>`;
    h += `<div class="acts">${phone ? `<a class="btn" href="tel:${esc(phone.replace(/[^\d+]/g, ""))}">Call</a>` : ""}`
      + `${wa.length >= 10 ? `<a class="btn line" href="https://wa.me/${esc(wa)}" target="_blank" rel="noopener noreferrer">WhatsApp</a>` : ""}`
      + `${c.email ? `<a class="link" href="mailto:${esc(c.email)}">Email</a>` : ""}`
      + `${c.linkedin_url ? `<a class="link" href="${esc(c.linkedin_url)}" target="_blank" rel="noopener noreferrer">LinkedIn</a>` : ""}</div>`;

    if (kit?.rules?.length) {
      h += `<section class="section"><div class="sh"><h2>Never on this call</h2></div><ul class="rules">${kit.rules.map((r) => `<li>${esc(r)}</li>`).join("")}</ul></section>`;
    }

    // 1. the buyer
    const stores = co.store_count ?? co.denue_branches;
    h += `<section class="section"><div class="sh"><h2>The buyer</h2><span class="aside">${esc(co.name || "")}</span></div>`
      + fact("Company", co.name) + fact("Type", co.type && co.type !== "other" ? co.type.replace(/_/g, " ") : null)
      + fact("Stores", stores != null ? `${num(stores)}${co.store_count == null ? " branches (INEGI)" : ""}` : null)
      + fact("Where", where || null) + fact("States", co.denue_states) + fact("Staff", co.denue_people_est)
      + fact("Sells", co.categories) + fact("Style", co.style_tags) + fact("Price tier", co.price_tier) + fact("Segment", co.segment)
      + fact("Website", co.website ? `<a class="link" href="${esc(ext(co.website))}" target="_blank" rel="noopener noreferrer">${esc(co.website.replace(/^https?:\/\//, ""))}</a>` : null, true)
      + fact("Lead score", co.lead_score != null ? `${co.lead_score}${co.score_rationale ? ". " + co.score_rationale : ""}` : null)
      + fact("Notes", co.notes)
      + `</section>`;
    h += `<section class="section"><div class="sh"><h2>The person</h2><span class="aside">${esc(c.is_decision_maker ? "Decision maker" : "")}</span></div>`
      + fact("Name", fullName(c) || null) + fact("Role", c.title) + fact("Email", c.email) + fact("Phone", c.phone) + fact("WhatsApp", c.whatsapp)
      + fact("Research", c.research_notes) + fact("Why them", c.score_rationale)
      + (b.colleagues?.length ? fact("Also there", b.colleagues.map((o) => [o.name, o.title].filter(Boolean).join(", ")).filter(Boolean)) : "")
      + `</section>`;

    if (s) {
      h += `<section class="section"><div class="sh"><h2>Our angle</h2><span class="aside">Fit ${esc(s.fit_score)} of 100</span></div>`
        + fact("Pitch", s.pitch_angle) + fact("Lead with", s.lead_with) + fact("Proof", s.proof_points) + fact("Offer", s.offer)
        + fact("Ask for", s.first_ask) + `</section>`;
    }
    if (m) {
      h += `<section class="section"><div class="sh"><h2>Meeting brief</h2><span class="aside">${esc(m.status)}</span></div>`
        + fact("Interest", m.interest) + fact("Fit", m.product_fit) + fact("Open questions", m.open_questions) + fact("Next steps", m.next_steps)
        + (m.body ? `<details><summary>Read the full brief</summary><p class="text" style="white-space:pre-wrap">${esc(m.body)}</p></details>` : "")
        + `</section>`;
    }

    // 2. what we sent and what they said
    const hist = b.history || [];
    h += `<section class="section"><div class="sh"><h2>What we sent, what they said<span class="n">${hist.length}</span></h2><span class="aside">Oldest first</span></div>`;
    if (!hist.length) h += `<p class="empty">Nothing logged with this buyer yet.</p>`;
    for (const x of hist) {
      const them = x.direction === "inbound";
      h += `<div class="row reply"><span class="lead" style="white-space:pre-line">${esc(shortDay(x.at))}\n${esc(KIND[x.channel] || x.channel.charAt(0).toUpperCase() + x.channel.slice(1))}</span><div>`
        + `<div class="name" style="font-size:15px${them ? ";color:var(--aegean)" : ""}">${esc(SAID[x.kind] || x.kind)}${x.subject ? ": " + esc(x.subject) : ""}</div>`
        + (x.summary ? `<p class="summary">${esc(x.summary)}</p>` : "")
        + (x.body ? (them && !x.summary ? `<p class="text" style="white-space:pre-wrap">${esc(x.body)}</p>`
          : `<details><summary>${them ? "Their words" : ["sent", "reply"].includes(x.kind) ? "What we wrote" : "Details"}</summary><p class="text" style="white-space:pre-wrap">${esc(x.body)}</p></details>`) : "")
        + `</div></div>`;
    }
    for (const d of b.waiting || []) {
      h += `<div class="row reply"><span class="lead">Waiting\n${esc(KIND[d.kind] || d.kind)}</span><div><div class="name" style="font-size:15px">Not sent yet${d.subject ? ": " + esc(d.subject) : ""}</div>`
        + `<details><summary>The draft</summary><p class="text" style="white-space:pre-wrap">${esc(d.body)}</p></details></div></div>`;
    }
    h += `</section>`;

    if (!kit) return h + `<p class="empty" style="margin-top:28px">No call kit for ${esc(b.client || "this client")} yet.</p>` + foot();

    // 3. the client's cheat sheet
    h += `<section class="section"><div class="sh"><h2>${esc(kit.title || b.client)}, at a glance</h2><span class="aside">${esc(kit.updated ? "Updated " + kit.updated : "")}</span></div>`;
    for (const g of kit.facts || []) {
      h += `<h3 class="kit-h">${esc(g.heading)}</h3>` + (g.items || []).map(([k, v]) => fact(k, v)).join("");
    }
    h += `</section>`;

    // 4. hard questions
    h += `<section class="section"><div class="sh"><h2>Hard questions<span class="n">${(kit.objections || []).length}</span></h2><span class="aside">Tap to open</span></div>`;
    for (const o of kit.objections || []) {
      h += `<details class="qa"><summary>“${esc(o.q)}”</summary><p class="text">${esc(fill(o.a))}</p>${o.proof ? `<p class="sub">${esc(o.proof)}</p>` : ""}</details>`;
    }
    h += `</section>`;

    // 5. the script
    h += `<section class="section"><div class="sh"><h2>Call script</h2><span class="aside">Español</span></div>`;
    for (const st of kit.script || []) {
      h += `<div class="stage"><h3 class="kit-h">${esc(st.stage)}</h3>${st.goal ? `<p class="sub">${esc(st.goal)}</p>` : ""}`
        + `<ol>${(st.lines || []).map((l) => `<li>${esc(fill(l))}</li>`).join("")}</ol></div>`;
    }
    h += `</section>`;
    if (kit.pending?.length) {
      h += `<section class="section"><div class="sh"><h2>Still missing</h2></div><ul class="rules quiet">${kit.pending.map((p) => `<li>${esc(p)}</li>`).join("")}</ul></section>`;
    }
    return h + foot();
  }

  function renderFind() {
    let h = top("Call brief");
    h += `<h1 class="statement">Who is the call with?</h1>`
      + `<p class="standfirst">Type a person or a company. The brief has the buyer, everything we sent and they said, the cheat sheet and the script.</p>`
      + `<div class="find"><input id="find" type="search" placeholder="Name or company" autocomplete="off" value="${esc(state.findQ || "")}"></div>`
      + `<div id="found">${renderFound()}</div>`;
    const soon = (state.inbox?.meetings || []);
    if (soon.length && !state.findQ) {
      h += `<section class="section"><div class="sh"><h2>Meetings</h2></div>`
        + soon.map((m) => `<a class="row" href="#brief/${esc(m.contact_id)}"><span class="lead" style="white-space:pre-line">${esc(m.meeting_at ? shortDay(m.meeting_at) + "\n" + clock(m.meeting_at) : "Ready")}</span>`
          + `<div><div class="name">${esc([m.contact, m.company].filter(Boolean).join(", "))}</div><div class="sub">Open the brief</div></div></a>`).join("")
        + `</section>`;
    }
    return h + foot();
  }
  function renderFound() {
    const r = state.found;
    if (!state.findQ || state.findQ.trim().length < 2) return "";
    if (!r) return `<p class="empty">Looking…</p>`;
    if (!r.length) return `<p class="empty">No buyer matches “${esc(state.findQ)}”.</p>`;
    return r.map((x) => `<a class="row" href="#brief/${esc(x.id)}"><span class="lead">${x.meeting ? "Meeting" : ""}</span><div>`
      + `<div class="name">${esc(x.contact || x.company || "(no name)")}</div><div class="sub">${esc([x.contact ? x.company : null, x.title, x.city].filter(Boolean).join(", "))}</div></div></a>`).join("");
  }
  let findTimer;
  document.addEventListener("input", (ev) => {
    if (ev.target.id !== "find") return;
    state.findQ = ev.target.value;
    state.found = null;
    clearTimeout(findTimer);
    const q = state.findQ;
    document.getElementById("found").innerHTML = renderFound();
    if (q.trim().length < 2) return;
    findTimer = setTimeout(async () => {
      try { const r = await rpc("phone_find", { p_q: q }); if (state.findQ === q) { state.found = r; document.getElementById("found").innerHTML = renderFound(); } }
      catch (e) { toast(e.message, true); }
    }, 250);
  });

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
    return { tab: ["today", "send", "inbox", "brief"].includes(tab) ? tab : "today", filter };
  };
  function draw(force) {
    if (!state.today) return;
    // Never redraw under your thumb while you are editing a draft.
    if (!force && state.editing.size && document.activeElement?.matches("textarea, input")) return;
    const { tab, filter } = route();
    // A brief is read during a call: the 30-second refresh must not close what you opened or move the page.
    if (!force && tab === "brief" && $app.dataset.tab === "brief") return;
    $tabs.hidden = false;
    const c = waitingCounts();
    const total = c.linkedin + c.whatsapp + c.call + c.email + c.other;
    const replies = (state.inbox?.replies || []).filter((r) => Date.now() - new Date(r.occurred_at) < 86400000 * 2).length
      + (state.inbox?.meetings || []).filter((m) => m.status === "ready").length;
    for (const a of $tabs.querySelectorAll("a")) {
      a.classList.toggle("on", a.dataset.tab === (tab === "brief" ? "inbox" : tab));
      const n = a.dataset.tab === "send" ? total : a.dataset.tab === "inbox" ? replies : 0;
      a.innerHTML = esc(a.textContent.replace(/\d+$/, "")) + (n ? `<sup>${n}</sup>` : "");
    }
    $app.dataset.tab = tab;
    $app.innerHTML = tab === "send" ? renderSend(filter) : tab === "inbox" ? renderInbox()
      : tab === "brief" ? (filter ? renderBrief(filter) : renderFind()) : renderToday();
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
    if (ds.copy) {
      const d = find(ds.copy);
      const text = d.kind === "linkedin" ? parts(d).parts[Number(ds.part)]?.text : d.body;
      try { await navigator.clipboard.writeText(text || ""); toast("Copied. Paste it in the note."); } catch { toast("Couldn't copy. Press and hold the text to copy it.", true); }
      if (ds.open) window.open(ds.open, "_blank", "noopener");
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
    if (ds.sent) { b.disabled = true; return act("phone_mark", { p_id: ds.sent, p_op: "sent", p_body: null }, ds.sent, "Logged as sent.").finally(() => { b.disabled = false; }); }
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

  window.addEventListener("hashchange", () => {
    if (!state.today) return;
    const { tab, filter } = route();
    if (tab === "brief" && filter && state.briefs[filter]?.data) { delete state.briefs[filter]; }  // fresh each time you open it
    draw(true); scrollTo(0, 0);
  });
  document.addEventListener("visibilitychange", () => { if (!document.hidden && state.today) sync(); });
  setInterval(() => { if (!document.hidden && state.today) sync(); }, REFRESH_SECONDS * 1000);

  // ─────────────────────────── start ───────────────────────────
  takeLinkTokens();
  if (!CFG.dev && !auth.get()) renderSignIn("email");
  else { $app.innerHTML = top("Loading…"); sync(true); }
})();
