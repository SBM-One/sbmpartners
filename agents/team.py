"""The agent team: the Supervisor hands out work, and each agent picks up its own tasks from the database.

  Prospect researcher  looks up each real buyer on the web (with sources) before anyone writes to them
  Strategist           scores the buyer's fit (0-100), decides pursue / nurture / disqualify, and plans the
                       pitch and the channel (agents/strategy.py). Only "pursue" buyers get a first message
  Writer               drafts the first message using the client's fact sheet, the approved playbook,
                       the research and the strategy; the Grader scores it and the Writer gets one rewrite
                       if it is weak. Also drafts follow-ups, answers to buyers who reply, and one check-in
                       after a "not now"
  Grader               scores every draft from 0 to 100 against agents/rubric.json
  Meeting briefer      turns an interested buyer into a meeting brief for you (agents/strategy.py)
  Reporter             writes each client's weekly report from the numbers in the database

Drafts wait in outreach_drafts (view: v_approval_queue) until a person approves them, and reports wait as
'draft' until a person approves them. When MAIL_ADDRESS is set, the Mailer (agents/mailer.py) also runs each
round: it sends approved emails slowly within the mailbox's daily cap, and reads and sorts replies.

Run:
  python -m agents.team run            keep working: a Supervisor round every 5 minutes, then the tasks
  python -m agents.team run --once     one round and the tasks it creates, then stop
  python -m agents.team status         what the team is doing, spend, and the approval queue
  python -m agents.team set-brief --client "Brand name" --file brief.json   save a brand's fact sheet
Needs DATABASE_URL and ANTHROPIC_API_KEY (see .env.example).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import signal
import socket
import sys
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from typing import List, Literal, Optional

from pydantic import BaseModel, Field

from . import mailer, review as review_checks, strategy, supervisor, teamdb as db
from .common import FALLBACK_BETA, Usage, client
from .practice import GRADER_SYSTEM, WRITER_SYSTEM, Grade, WriterTurn, playbook_text, score  # noqa: F401 (used by strategy.py)
from .researcher import _collect_urls, _norm

HERE = pathlib.Path(__file__).resolve().parent
RUBRIC = json.loads((HERE / "rubric.json").read_text())


def model(name: str) -> str:
    return db.TEAM[db.name_of(name)][1]


# ─────────────────────────── structured outputs ───────────────────────────
class Fact(BaseModel):
    fact: str = Field(description="One specific, useful fact about this buyer, in your own words")
    source_url: str = Field(description="The page it came from (must be a page you actually opened)")


class ProspectBrief(BaseModel):
    summary: str = Field(description="2-3 sentences: who this buyer is and what they buy")
    facts: List[Fact] = Field(description="3-8 specific facts a seller could use, each with its source")
    angle: str = Field(description="The most relevant reason this buyer might care about the client's brand")
    cautions: str = Field(description="Anything that makes them a poor fit, or facts that could not be confirmed")
    fit: int = Field(description="Fit for the client's brand, 1 (poor) to 5 (excellent)")


class ReportText(BaseModel):
    headline: str = Field(description="One sentence: the most important result of the week")
    summary: str = Field(description="3-5 plain sentences for a busy brand owner")
    highlights: List[str] = Field(description="2-5 short bullet points, each tied to a number given")
    next_week: List[str] = Field(description="2-4 concrete things we will do next week")


# ─────────────────────────── shared AI call ───────────────────────────
def parse(c, usage: Usage, mdl: str, system, content: str, fmt, effort: str = "medium"):
    """One structured call. A cut-off or malformed answer is retried once."""
    last = None
    for _ in range(2):
        try:
            resp = c.beta.messages.parse(model=mdl, max_tokens=16000, system=system,
                                         messages=[{"role": "user", "content": content}],
                                         output_format=fmt, output_config={"effort": effort},
                                         betas=[FALLBACK_BETA], fallbacks="default")
        except ValueError as exc:
            last = exc
            continue
        usage.add(resp)
        if resp.parsed_output is not None:
            return resp.parsed_output
        last = RuntimeError(f"stop reason {resp.stop_reason}")
    raise RuntimeError(f"{fmt.__name__}: no usable answer after a retry ({last})")


def contact_row(conn, contact_id) -> dict:
    return db.one(conn, """
        select c.*, co.name as company, co.type::text as buyer_type, co.website, co.domain, co.hq_city, co.hq_state,
               co.categories, co.style_tags, co.price_tier, co.store_count, co.notes as company_notes
        from contacts c left join companies co on co.id = c.company_id where c.id = %s""", (contact_id,))


def who(p: dict) -> str:
    name = " ".join(x for x in [p.get("first_name"), p.get("last_name")] if x) or "(name unknown)"
    where = ", ".join(x for x in [p.get("hq_city"), p.get("hq_state")] if x)
    return (f"{name}, {p.get('title') or 'role unknown'} at {p.get('company') or 'unknown company'}"
            f"{f' ({where})' if where else ''}. Buyer type: {p.get('buyer_type') or 'unknown'}. "
            f"Website: {p.get('website') or p.get('domain') or 'unknown'}.")


# ─────────────────────────── Prospect researcher ───────────────────────────
PROSPECT_SYSTEM = """You research one wholesale buyer before SBM Partners contacts them on behalf of a
client brand. Search the web and open the buyer's own website and other credible pages (press, trade
directories, the person's professional profile if public). Find specific, current facts a seller
could use: what they carry, their style and price level, recent news, projects, locations, and what
this person is responsible for. Keep to business facts; nothing about private life.
Say plainly what you could not confirm. Finish with your notes, each fact tied to the URL it came from."""


def research_prospect(conn, c, task: dict, usages: dict) -> dict:
    usage = usages.setdefault("researcher", Usage())
    p = contact_row(conn, task["contact_id"])
    brief = db.one(conn, "select brief from clients where id = %s", (task["client_id"],))["brief"]
    tools = [{"type": "web_search_20250305", "name": "web_search", "max_uses": 5},
             {"type": "web_fetch_20250910", "name": "web_fetch", "max_uses": 4}]
    messages = [{"role": "user", "content": f"Buyer to research: {who(p)}\n"
                                            f"Client brand (for judging fit): {brief.get('what_they_make', '')}"}]
    seen: set[str] = set()
    notes: list[str] = []
    for _ in range(4):
        with c.beta.messages.stream(model=db.WEB_MODEL, max_tokens=16000, system=PROSPECT_SYSTEM,
                                    messages=messages, tools=tools, output_config={"effort": "medium"},
                                    betas=[FALLBACK_BETA], fallbacks="default") as stream:
            msg = stream.get_final_message()
        usage.add(msg)
        for block in msg.content:
            if block.type == "text":
                notes.append(block.text)
            if block.type not in ("text", "server_tool_use", "thinking") or getattr(block, "citations", None):
                _collect_urls(block, seen)
        if msg.stop_reason != "pause_turn":
            break
        messages.append({"role": "assistant", "content": msg.content})

    out = parse(c, usage, db.WEB_MODEL,
                "Turn research notes about one buyer into a short brief. Use only facts and URLs in the notes.",
                f"Buyer: {who(p)}\n\n<notes>\n{chr(10).join(notes)}\n</notes>", ProspectBrief, "low")
    opened = {_norm(u) for u in seen}
    facts = [f.model_dump() for f in out.facts if _norm(f.source_url) in opened]   # drop any unopened source
    result = {**out.model_dump(), "facts": facts, "dropped_unverified": len(out.facts) - len(facts)}
    for f in facts:   # remember where each fact came from; rented/public data, not verified by us
        db.all_rows(conn, "insert into field_sources (entity, entity_id, field, value, source, owned, confidence) "
                          "values ('contact', %s, 'research_note', %s, %s, false, 0.6)",
                    (task["contact_id"], f["fact"][:1000], "web:" + f["source_url"][:500]))
    # Second half of the same job: score the fit and plan the pitch (the strategy row points back at this task).
    if task.get("campaign_id"):
        scored = strategy.score_prospect(conn, c, task, result, task["id"], usage)
        result = {**result, "scored": scored}
    return result


# ─────────────────────────── Writer (+ Grader) ───────────────────────────
def active_playbook(conn) -> list[dict]:
    return db.all_rows(conn, "select id, title, body, channel::text as channel, "
                             "coalesce(buyer_types::text[], '{}') as buyer_types, stage::text as stage "
                             "from playbook_entries where status = 'active' order by created_at, title")


FOOTER_NOTE = ("\n\nThe sender's name, postal address and an unsubscribe link are added automatically under every "
               "email, so do not write your own opt-out line or signature block; end with your first name.")

LINKEDIN_ASK = ("Write a LinkedIn connection note to this buyer. At most 280 characters. No pitch, no product, no link, "
                "no ask for a meeting: say who you are in a few words and mention one specific, true thing from the "
                "research that made you want to connect. Leave subject empty.")


def writer_setup(conn, client_id) -> tuple[list, list, dict]:
    """The Writer's and Grader's instructions for one client: (writer system, grader system, fact sheet)."""
    cl = db.one(conn, "select brief, brief_approved_at, sender_name, sender_company from clients where id = %s", (client_id,))
    brief = cl["brief"]
    if not brief or cl["brief_approved_at"] is None:
        raise RuntimeError("The client has no approved fact sheet (approve it on the Clients page).")
    if cl["sender_name"]:   # who signs the emails
        brief = {**brief, "sender_name": cl["sender_name"],
                 **({"sender_title": cl["sender_company"]} if cl["sender_company"] else {})}
    playbook = active_playbook(conn)
    if not playbook:
        raise RuntimeError("No approved playbook entries (status 'active'); the Writer only uses approved entries.")
    brief_txt = json.dumps({k: v for k, v in brief.items() if not k.startswith("_")}, indent=1)
    w_sys = [{"type": "text", "cache_control": {"type": "ephemeral"},
              "text": WRITER_SYSTEM.format(brief=brief_txt, playbook=playbook_text(playbook))}]
    g_sys = [{"type": "text", "cache_control": {"type": "ephemeral"},
              "text": GRADER_SYSTEM.format(rubric=json.dumps(RUBRIC, indent=1), brief=brief_txt,
                                           titles="\n".join(f"[{i}] {e['title']}" for i, e in enumerate(playbook, 1)))}]
    return w_sys, g_sys, brief


class PlanStep(BaseModel):
    day: int = Field(description="Days after the first message (0 = first day)")
    channel: Literal["email", "linkedin", "whatsapp"]
    purpose: str = Field(description="What this touch does, in a few words (e.g. 'first email', 'connection note')")


class ChannelPlan(BaseModel):
    steps: List[PlanStep] = Field(description="2-5 touches over about three weeks, first one first, only on the channels allowed")
    why: str = Field(description="One sentence: why this sequence suits this buyer")


PLAN_ASK = """Plan how we reach this buyer over the next three weeks: 2-5 touches, on these channels only: {allowed}.
Start where the strategy says ({main}). Email follow-ups go on email; a LinkedIn connection note and a WhatsApp
message are each sent once, by hand, by a person, so use each at most once. WhatsApp is for a business number
only and comes after an email or LinkedIn touch unless it is the only channel. Space touches at least 3 days apart."""

ASKS = {
    "linkedin": LINKEDIN_ASK,
    "whatsapp": ("Write a WhatsApp message to this buyer's business number, which a person sends by hand. At most 500 "
                 "characters, no link, no attachment. Greet them, say who you are in one line, give one specific, true "
                 "reason you are writing to THEM (from the research), and ask one easy question. Leave subject empty."),
}


def channels_allowed(conn, task: dict, p: dict, strat: Optional[dict]) -> list[str]:
    reach = strategy.reachability(conn, task, p)
    allowed = [ch for ch, ok in (("email", reach["email_possible"]), ("linkedin", reach["linkedin_possible"]),
                                 ("whatsapp", reach.get("whatsapp_possible"))) if ok]
    # The researcher's channel decision says whether email and LinkedIn are in; WhatsApp is added whenever possible.
    wanted = {"email": {"email"}, "email_and_linkedin": {"email", "linkedin"}, "linkedin": {"linkedin"},
              "whatsapp": set()}.get((strat or {}).get("channel_plan"), {"email", "linkedin"}) | {"whatsapp"}
    return [ch for ch in allowed if ch in wanted] or allowed or ["email"]


def draft_outreach(conn, c, task: dict, usages: dict) -> dict:
    """The writer plans the channels (first message only) and writes; the reviewer grades and safety-checks each message."""
    w_usage = usages.setdefault("writer", Usage())
    g_usage = usages.setdefault("reviewer", Usage())
    w_sys, g_sys, brief = writer_setup(conn, task["client_id"])
    playbook = active_playbook(conn)
    step = int(task["input"].get("step") or 1)
    strat = strategy.strategy_for(conn, task["campaign_id"], task["contact_id"])
    if step == 1 and strat and strat["decision"] != "pursue":
        raise RuntimeError(f"This buyer was marked {strat['decision']!r}, so no first message (change it on the Buyers page).")
    research_id = task["input"].get("research_task_id") or task["parent_id"]
    research = ((db.one(conn, "select output from tasks where id = %s", (research_id,)) or {}).get("output") or {}
                if research_id else {})
    p = contact_row(conn, task["contact_id"])
    history = db.all_rows(conn, """select step, subject, body, sent_at from outreach_drafts
                                   where contact_id = %s and campaign_id = %s and channel = 'email' and status = 'sent'
                                   order by step""", (task["contact_id"], task["campaign_id"])) if step > 1 else []
    if step > 1 and not history:
        raise RuntimeError("A follow-up was requested but no earlier email to this buyer was sent.")

    facts = "\n".join(f"- {f['fact']} ({f['source_url']})" for f in research.get("facts", [])) or "- (no verified facts)"
    about = (f"Buyer: {who(p)}\nWhat research found: {research.get('summary', '(no research)')}\n{facts}\n"
             f"Best angle: {research.get('angle', '')}\nCautions: {research.get('cautions', '')}"
             + strategy.strategy_text(strat))
    sources = json.dumps(research, ensure_ascii=False) + strategy.strategy_text(strat)
    min_score = db.agent(conn, "writer")["min_score"]

    # What to write: a follow-up email, or the first message on each channel of the writer's plan.
    plan = None
    if step > 1:
        convo = "\n\n".join(f"[You, {h['sent_at']:%d %b}] " + (f"Subject: {h['subject']}\n" if h["subject"] else "") + h["body"]
                            for h in history) + "\n\n(The buyer has not replied.)"
        jobs = [("email", None,
                 f"Write follow-up {step - 1} to this buyer, as a reply in the same email thread. It must add something new "
                 "and useful (a fact from the brief, a sample, an answer); never 'just checking in'. Shorter than the first "
                 "email. Leave subject empty: it goes out as a reply.",
                 f"This is follow-up {step - 1}; the buyer has not replied to the earlier emails shown above")]
    else:
        convo = "(none yet)"
        allowed = channels_allowed(conn, task, p, strat)
        main = (strat or {}).get("channel_plan") or allowed[0]
        plan = parse(c, w_usage, model("writer"), w_sys,
                     f"{about}\n\n{PLAN_ASK.format(allowed=', '.join(allowed), main=main)}", ChannelPlan, "low")
        steps = [s for s in plan.steps if s.channel in allowed] or [PlanStep(day=0, channel=allowed[0], purpose="first message")]
        plan = ChannelPlan(steps=sorted(steps, key=lambda s: s.day), why=plan.why)
        firsts: dict[str, int] = {}
        for s in plan.steps:
            firsts.setdefault(s.channel, s.day)
        jobs = [(ch, day, ASKS.get(ch) or "Write your first email to this buyer.",
                 "This is a first message; the buyer has not replied yet") for ch, day in firsts.items()]
        if strat:
            db.all_rows(conn, "update prospect_strategies set channel_sequence = %s where id = %s",
                        (db.jsonb(plan.model_dump()), strat["id"]))

    writer_id = db.agent(conn, "writer")["id"]
    insert = """
        insert into outreach_drafts (client_id, campaign_id, contact_id, company_id, task_id, writer_agent_id, channel, step,
                                     subject, body, playbook_used, research, score, grade_feedback, rewrites, purpose, strategy_id,
                                     planned_day, review_checks)
        values (%s, %s, %s, %s, %s, %s, %s::channel, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) returning id"""
    out = {"step": step, "drafts": [], **({"plan": plan.model_dump()} if plan else {})}
    for channel, day, ask, stage in jobs:
        footer = FOOTER_NOTE if channel == "email" else ""
        subject_wanted = channel == "email" and step == 1

        def write(extra: str = "") -> WriterTurn:
            return parse(c, w_usage, model("writer"), w_sys,
                         f"{about}\n\nConversation so far:\n{convo}\n\n{ask}{footer}{extra}", WriterTurn, "medium")

        def review(w: WriterTurn) -> tuple[Grade, float, list[str]]:
            subj = f"[Subject: {w.subject}]\n" if w.subject and subject_wanted else ""
            g = parse(c, g_usage, model("reviewer"), g_sys,
                      f"{about}\nChannel: {channel}. {stage} (score 'handling' as null). The sender's address and "
                      f"unsubscribe link are added automatically, so do not mark it down for missing them."
                      f"\n\nEarlier messages:\n{convo}\n\nWRITER:\n{subj}{w.message}", Grade, "medium")
            problems = review_checks.check(w.message, w.subject if subject_wanted else None, channel,
                                           "first" if step == 1 else "follow_up", brief, sources, p.get("country"))
            s = score(g, RUBRIC)
            return g, (min(s, min_score - 1) if problems else s), problems

        best = write()
        best_g, best_s, best_p = review(best)
        rewrites = 0
        if best_s < min_score:
            rewrites = 1
            fixes = (" Safety checks failed: " + " ".join(best_p)) if best_p else ""
            w2 = write(f"\n\nA previous draft scored {best_s:.0f}/100. Coach's feedback: {best_g.feedback} "
                       f"Most important fix: {best_g.top_fix}{fixes}\nWrite a better message.")
            g2, s2, p2 = review(w2)
            if s2 > best_s or (best_p and not p2):
                best, best_g, best_s, best_p = w2, g2, s2, p2
        used = [playbook[i - 1]["title"] for i in best.playbook_used if 0 < i <= len(playbook)]
        feedback = f"{best_g.feedback}\nTop fix: {best_g.top_fix}" + (
            "\nSafety checks: " + " ".join(best_p) if best_p else "\nSafety checks: passed.")
        row = db.one(conn, insert, (task["client_id"], task["campaign_id"], task["contact_id"], task["company_id"], task["id"],
                                    writer_id, channel, step, best.subject if subject_wanted else None, best.message.strip(),
                                    db.jsonb(used), db.jsonb(research), best_s, feedback, rewrites,
                                    "first" if step == 1 else "follow_up", strat["id"] if strat else None, day,
                                    db.jsonb({"problems": best_p, "passed": not best_p})))
        out["drafts"].append({"draft_id": str(row["id"]), "channel": channel, "day": day, "score": best_s,
                              "rewrites": rewrites, "passed_checks": not best_p})
    main_draft = next((d for d in out["drafts"] if d["channel"] == "email"), out["drafts"][0])
    return {**out, "draft_id": main_draft["draft_id"], "channel": main_draft["channel"], "score": main_draft["score"]}


# ─────────────────────────── Reporter ───────────────────────────
REPORTER_SYSTEM = """You write a short weekly report for a brand owner whose wholesale outreach SBM
Partners runs. Use ONLY the numbers and facts given; never invent or estimate. If a number is zero,
say so plainly and explain what we are doing about it. Warm, professional, no hype, no jargon."""


def write_report(conn, c, task: dict, usages: dict) -> dict:
    usage = usages.setdefault("writer", Usage())
    start = dt.date.fromisoformat(task["input"]["period_start"])
    end = dt.date.fromisoformat(task["input"]["period_end"])
    cid = task["client_id"]
    nxt = end + dt.timedelta(days=1)
    client_name = db.one(conn, "select name from clients where id = %s", (cid,))["name"]
    week = db.one(conn, "select touches, replies, meetings, samples, quotes, orders, order_value_cents "
                        "from v_client_weekly where client_id = %s and week = %s", (cid, start)) or {}
    drafts = db.one(conn, """select count(*) as written,
                                    count(*) filter (where status in ('approved','sent')) as approved,
                                    count(*) filter (where status = 'sent') as sent,
                                    round(avg(score)::numeric, 0) as avg_quality
                             from outreach_drafts where client_id = %s and created_at >= %s and created_at < %s""",
                    (cid, start, nxt))
    replies = db.all_rows(conn, """select co.name as company, i.subject from interactions i
                                   left join companies co on co.id = i.company_id
                                   where i.client_id = %s and i.kind in ('reply','meeting_booked','order','reorder')
                                     and i.occurred_at >= %s and i.occurred_at < %s order by i.occurred_at limit 10""",
                          (cid, start, nxt))
    deals = db.one(conn, "select count(*) filter (where opened_at >= %s and opened_at < %s) as new_deals, "
                         "count(*) filter (where stage not in ('lost') and closed_at is null) as open_deals "
                         "from deals where client_id = %s", (start, nxt, cid))
    data = {"client": client_name, "period": f"{start} to {end}",
            "outreach": {k: int(v or 0) for k, v in week.items()} if week else {},
            "drafts": {k: (float(v) if v is not None else None) for k, v in drafts.items()},
            "deals": {k: int(v or 0) for k, v in deals.items()},
            "notable": replies}
    out = parse(c, usage, model("writer"), REPORTER_SYSTEM,
                f"Week: {start} to {end}\nData:\n{db.dumps(data)}", ReportText, "low")
    body = "\n".join([f"# {client_name}: week of {start:%b %d}", "", f"**{out.headline}**", "", out.summary, "",
                      "## Highlights", *[f"- {h}" for h in out.highlights], "", "## Next week",
                      *[f"- {n}" for n in out.next_week]])
    row = db.one(conn, """insert into reports (client_id, kind, period_start, period_end, data, summary, body, status)
                          values (%s, 'weekly', %s, %s, %s, %s, %s, 'draft')
                          on conflict (client_id, kind, period_start) do nothing returning id""",
                 (cid, start, end, db.jsonb(data), out.headline, body))
    return {"report_id": str(row["id"]) if row else None, "headline": out.headline}


HANDLERS = {"research_prospect": research_prospect,
            "qualify_prospect": lambda *a: strategy.qualify_prospect(*a),
            "draft_outreach": draft_outreach,
            "draft_reply": lambda *a: strategy.draft_reply(*a),
            "prepare_handoff": lambda *a: strategy.prepare_handoff(*a),
            "write_report": write_report}
# Agents a task needs within budget before it starts.
NEEDS = {"research_prospect": ["researcher"], "qualify_prospect": ["researcher"],
         "draft_outreach": ["writer", "reviewer"], "draft_reply": ["writer", "reviewer"],
         "prepare_handoff": ["writer"], "write_report": ["writer"]}


# ─────────────────────────── running a task ───────────────────────────
def run_task(task: dict, c, url: Optional[str] = None) -> str:
    conn = db.connect(url)
    usages: dict[str, Usage] = {}
    label = f"{task['kind']} {str(task['id'])[:8]}"
    try:
        output = HANDLERS[task["kind"]](conn, c, task, usages)
        run_ids = [db.record_run(conn, name, u, f"{label}: done") for name, u in usages.items()]
        db.finish(conn, task["id"], output, run_ids[0] if run_ids else None)
        return f"{label}: done"
    except Exception as exc:  # the task goes back in the queue (or fails after its last attempt)
        run_ids = [db.record_run(conn, name, u, f"{label}: failed", ok=False) for name, u in usages.items()]
        status = db.fail(conn, task["id"], f"{type(exc).__name__}: {exc}", run_ids[0] if run_ids else None)
        traceback.print_exc(file=sys.stderr)
        return f"{label}: {'will retry' if status == 'queued' else 'failed'} ({exc})"
    finally:
        conn.close()


def work_round(conn, c, workers: int, url: Optional[str] = None, stop: Optional[threading.Event] = None,
               log=print) -> int:
    """One Supervisor round, then every ready task until the queue is empty. Returns tasks run."""
    summary = supervisor.tick(conn)
    log("Supervisor: " + ", ".join(f"{k.replace('_', ' ')} {v}" for k, v in summary.items() if v))
    me = f"{socket.gethostname()}-{os.getpid()}"
    ran = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        while not (stop and stop.is_set()):
            kinds = [k for k, names in NEEDS.items() if all(db.can_work(conn, n) for n in names)]
            batch = db.claim(conn, kinds, me, workers)
            if not batch:
                break
            for result in pool.map(lambda t: run_task(t, c, url), batch):
                log("  " + result)
                ran += 1
            if any(t["kind"] in ("research_prospect", "qualify_prospect") for t in batch):
                supervisor.tick(conn)   # finished research and qualification become the next step right away
    return ran


def status(conn) -> None:
    print("Team (this month):")
    for a in db.all_rows(conn, "select * from v_agent_spend_month order by name"):
        state = "working" if a["active"] else f"paused ({a['paused_reason'] or 'by hand'})"
        print(f"  {a['name']:<22} ${a['spent_usd']} of ${a['budget_usd']}  {state}")
    print("\nTasks (last 7 days):")
    for t in db.all_rows(conn, "select * from v_team_status order by kind, status"):
        print(f"  {t['kind']:<18} {t['status']:<9} {t['tasks']}")
    n = db.one(conn, "select count(*) as n from v_approval_queue")["n"]
    print(f"\nDrafts waiting for your approval: {n}")
    alerts = db.all_rows(conn, "select severity::text, message from alerts where status = 'open' "
                               "and not notify_client order by created_at desc limit 10")
    print(f"\nOpen alerts: {len(alerts)}" if alerts else "\nNo open alerts.")
    for a in alerts:
        print(f"  [{a['severity']}] {a['message']}")


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="run the team")
    r.add_argument("--once", action="store_true", help="one round, then stop")
    r.add_argument("--interval", type=int, default=300, help="seconds between Supervisor rounds (default 300)")
    r.add_argument("--workers", type=int, default=3, help="tasks worked on at the same time (default 3)")
    sub.add_parser("status", help="show what the team is doing")
    b = sub.add_parser("set-brief", help="save a client's brand fact sheet (JSON, like agents/sample_client.json)")
    b.add_argument("--client", required=True, help="the client's name, exactly as in the clients table")
    b.add_argument("--file", required=True, help="the fact sheet .json file")
    args = ap.parse_args(argv)

    conn = db.connect()
    db.register_team(conn)
    if args.cmd == "status":
        status(conn)
        return
    if args.cmd == "set-brief":
        brief = json.loads(pathlib.Path(args.file).read_text())
        row = db.one(conn, "update clients set brief = %s where name = %s returning id", (db.jsonb(brief), args.client))
        print("Saved." if row else f"No client named {args.client!r}. Check the clients table.")
        return

    c = client()
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())   # hosting platforms send this before a restart
    log = lambda m: print(f"{dt.datetime.now():%H:%M:%S} {m}", flush=True)
    log("Team started.")
    mail = mailer.settings()
    if mail["address"]:
        log(f"Mailer on for {mail['address']}{' (dry run: emails are written to out/mail, not sent)' if mail['dry_run'] else ''}.")
    while not stop.is_set():
        try:
            work_round(conn, c, args.workers, stop=stop, log=log)
            if mail["address"]:
                while mailer.send_due(conn, mail, log=log):
                    pass
                mailer.read_replies(conn, mail, c, log=log)
        except Exception as exc:  # a lost connection should not stop the team for good
            log(f"Round failed: {exc}; reconnecting.")
            try:
                conn.close()
            except Exception:
                pass
            time.sleep(30)
            conn = db.connect()
        if args.once:
            break
        stop.wait(args.interval)
    log("Team stopped.")


if __name__ == "__main__":
    main()
