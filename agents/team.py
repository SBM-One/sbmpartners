"""The agent team: the Supervisor hands out work, and each agent picks up its own tasks from the database.

  Prospect researcher  looks up each real buyer on the web (with sources) before anyone writes to them
  Writer               drafts the first message using the client's fact sheet, the approved playbook
                       and the research; the Grader scores it and the Writer gets one rewrite if it is weak
  Grader               scores every draft from 0 to 100 against agents/rubric.json
  Reporter             writes each client's weekly report from the numbers in the database

Nothing is ever sent from here. Drafts wait in outreach_drafts (view: v_approval_queue) until a
person approves them, and reports wait as 'draft' until a person approves them.

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
from typing import List, Optional

from pydantic import BaseModel, Field

from . import supervisor, teamdb as db
from .common import FALLBACK_BETA, Usage, client
from .practice import GRADER_SYSTEM, WRITER_SYSTEM, Grade, WriterTurn, playbook_text, score
from .researcher import _collect_urls, _norm

HERE = pathlib.Path(__file__).resolve().parent
RUBRIC = json.loads((HERE / "rubric.json").read_text())


def model(name: str) -> str:
    return db.TEAM[name][1]


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
    usage = usages.setdefault("prospect-researcher", Usage())
    p = contact_row(conn, task["contact_id"])
    brief = db.one(conn, "select brief from clients where id = %s", (task["client_id"],))["brief"]
    tools = [{"type": "web_search_20260209", "name": "web_search", "max_uses": 5},
             {"type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 4}]
    messages = [{"role": "user", "content": f"Buyer to research: {who(p)}\n"
                                            f"Client brand (for judging fit): {brief.get('what_they_make', '')}"}]
    seen: set[str] = set()
    notes: list[str] = []
    for _ in range(4):
        with c.beta.messages.stream(model=model("prospect-researcher"), max_tokens=16000, system=PROSPECT_SYSTEM,
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

    out = parse(c, usage, model("prospect-researcher"),
                "Turn research notes about one buyer into a short brief. Use only facts and URLs in the notes.",
                f"Buyer: {who(p)}\n\n<notes>\n{chr(10).join(notes)}\n</notes>", ProspectBrief, "low")
    opened = {_norm(u) for u in seen}
    facts = [f.model_dump() for f in out.facts if _norm(f.source_url) in opened]   # drop any unopened source
    result = {**out.model_dump(), "facts": facts, "dropped_unverified": len(out.facts) - len(facts)}
    for f in facts:   # remember where each fact came from; rented/public data, not verified by us
        db.all_rows(conn, "insert into field_sources (entity, entity_id, field, value, source, owned, confidence) "
                          "values ('contact', %s, 'research_note', %s, %s, false, 0.6)",
                    (task["contact_id"], f["fact"][:1000], "web:" + f["source_url"][:500]))
    return result


# ─────────────────────────── Writer (+ Grader) ───────────────────────────
def active_playbook(conn) -> list[dict]:
    return db.all_rows(conn, "select id, title, body, channel::text as channel, "
                             "coalesce(buyer_types::text[], '{}') as buyer_types, stage::text as stage "
                             "from playbook_entries where status = 'active' order by created_at, title")


def draft_outreach(conn, c, task: dict, usages: dict) -> dict:
    w_usage = usages.setdefault("writer", Usage())
    g_usage = usages.setdefault("grader", Usage())
    brief = db.one(conn, "select brief from clients where id = %s", (task["client_id"],))["brief"]
    if not brief:
        raise RuntimeError("The client has no brand fact sheet (clients.brief).")
    playbook = active_playbook(conn)
    if not playbook:
        raise RuntimeError("No approved playbook entries (status 'active'); the Writer only uses approved entries.")
    research_id = task["input"].get("research_task_id") or task["parent_id"]
    research = (db.one(conn, "select output from tasks where id = %s", (research_id,)) or {}).get("output") or {}
    p = contact_row(conn, task["contact_id"])
    camp = db.one(conn, "select channels::text[] as channels from campaigns where id = %s", (task["campaign_id"],))
    channels = (camp or {}).get("channels") or ["email"]
    channel = "email" if "email" in channels else channels[0]

    brief_txt = json.dumps({k: v for k, v in brief.items() if not k.startswith("_")}, indent=1)
    w_sys = [{"type": "text", "cache_control": {"type": "ephemeral"},
              "text": WRITER_SYSTEM.format(brief=brief_txt, playbook=playbook_text(playbook))}]
    g_sys = [{"type": "text", "cache_control": {"type": "ephemeral"},
              "text": GRADER_SYSTEM.format(rubric=json.dumps(RUBRIC, indent=1), brief=brief_txt,
                                           titles="\n".join(f"[{i}] {e['title']}" for i, e in enumerate(playbook, 1)))}]
    facts = "\n".join(f"- {f['fact']} ({f['source_url']})" for f in research.get("facts", [])) or "- (no verified facts)"
    about = (f"Buyer: {who(p)}\nWhat research found: {research.get('summary', '(no research)')}\n{facts}\n"
             f"Best angle: {research.get('angle', '')}\nCautions: {research.get('cautions', '')}")
    min_score = db.agent(conn, "writer")["min_score"]

    def write(extra: str = "") -> WriterTurn:
        return parse(c, w_usage, model("writer"), w_sys,
                     f"{about}\n\nConversation so far:\n(none yet)\n\nWrite your first {channel} message to this buyer.{extra}",
                     WriterTurn, "medium")

    def grade(w: WriterTurn) -> tuple[Grade, float]:
        subj = f"[Subject: {w.subject}]\n" if w.subject else ""
        g = parse(c, g_usage, model("grader"), g_sys,
                  f"{about}\nChannel: {channel}. This is a first message; the buyer has not replied yet "
                  f"(score 'handling' as null).\n\nWRITER:\n{subj}{w.message}", Grade, "medium")
        return g, score(g, RUBRIC)

    best = write()
    best_g, best_s = grade(best)
    rewrites = 0
    if best_s < min_score:
        rewrites = 1
        w2 = write(f"\n\nA previous draft scored {best_s:.0f}/100. Coach's feedback: {best_g.feedback} "
                   f"Most important fix: {best_g.top_fix}\nWrite a better message.")
        g2, s2 = grade(w2)
        if s2 > best_s:
            best, best_g, best_s = w2, g2, s2

    used = [playbook[i - 1]["title"] for i in best.playbook_used if 0 < i <= len(playbook)]
    writer_id = db.agent(conn, "writer")["id"]
    row = db.one(conn, """
        insert into outreach_drafts (client_id, campaign_id, contact_id, company_id, task_id, writer_agent_id, channel,
                                     subject, body, playbook_used, research, score, grade_feedback, rewrites)
        values (%s, %s, %s, %s, %s, %s, %s::channel, %s, %s, %s, %s, %s, %s, %s) returning id""",
                 (task["client_id"], task["campaign_id"], task["contact_id"], task["company_id"], task["id"], writer_id,
                  channel, best.subject, best.message, db.jsonb(used), db.jsonb(research), best_s,
                  f"{best_g.feedback}\nTop fix: {best_g.top_fix}", rewrites))
    return {"draft_id": str(row["id"]), "score": best_s, "rewrites": rewrites, "channel": channel}


# ─────────────────────────── Reporter ───────────────────────────
REPORTER_SYSTEM = """You write a short weekly report for a brand owner whose wholesale outreach SBM
Partners runs. Use ONLY the numbers and facts given; never invent or estimate. If a number is zero,
say so plainly and explain what we are doing about it. Warm, professional, no hype, no jargon."""


def write_report(conn, c, task: dict, usages: dict) -> dict:
    usage = usages.setdefault("reporter", Usage())
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
    out = parse(c, usage, model("reporter"), REPORTER_SYSTEM,
                f"Week: {start} to {end}\nData:\n{db.dumps(data)}", ReportText, "low")
    body = "\n".join([f"# {client_name}: week of {start:%b %d}", "", f"**{out.headline}**", "", out.summary, "",
                      "## Highlights", *[f"- {h}" for h in out.highlights], "", "## Next week",
                      *[f"- {n}" for n in out.next_week]])
    row = db.one(conn, """insert into reports (client_id, kind, period_start, period_end, data, summary, body, status)
                          values (%s, 'weekly', %s, %s, %s, %s, %s, 'draft')
                          on conflict (client_id, kind, period_start) do nothing returning id""",
                 (cid, start, end, db.jsonb(data), out.headline, body))
    return {"report_id": str(row["id"]) if row else None, "headline": out.headline}


HANDLERS = {"research_prospect": research_prospect, "draft_outreach": draft_outreach, "write_report": write_report}
# Agents a task needs within budget before it starts.
NEEDS = {"research_prospect": ["prospect-researcher"], "draft_outreach": ["writer", "grader"], "write_report": ["reporter"]}


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
            if any(t["kind"] == "research_prospect" for t in batch):
                supervisor.tick(conn)   # finished research becomes drafting work right away
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
    while not stop.is_set():
        try:
            work_round(conn, c, args.workers, stop=stop, log=log)
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
