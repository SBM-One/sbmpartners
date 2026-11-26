"""Run the real agent team on the 29 Mexican buyers for Santa Fe Rústicos, and show the trail behind every draft.

This is not a test with an answer key: it is the team doing its normal job on real accounts, end to end.
  Supervisor           hands out the work (research, then qualification, then a first draft for each "pursue")
  Prospect researcher  researches each account on the live web, with a source for every fact
  Strategist           scores fit 0-100, decides pursue / nurture / disqualify, plans the pitch
  Writer + Grader      writes the first email in Spanish; the Grader scores it and asks for one rewrite if weak
  Safety gate          says, for each draft, what still stops it from being sent

DRAFTS ONLY. It runs in a throwaway local database (bench/sandbox.py) that is deleted at the end; the live
Supabase database is never written to. The Mailer is not run at all, and every mailbox setting is removed.

No named buyers were collected for these accounts, so each account gets one role-based contact ("purchasing /
furniture buyer, to be identified"). Except for the two real supplier inboxes (Home Depot, Walmart), the email
address is a placeholder ending in .invalid, only so the team treats email as the channel; it can never receive mail.
Mexico has no confirmed email rule yet, so the safety gate holds every draft; the report says so per draft.

Run (on the computer that has the API key):
  set -a; source .env; set +a
  python -m bench.mexico --playbook path/to/playbook_used.json          # about $8-15, stops at --budget (default 25)
  python -m bench.mexico --playbook ... --only "Costco,Dico" --budget 3  # a few accounts first
Results: out/mexico-run/<date_time>/drafts_es.md (every draft with its trail), report.md, results.json.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor

from .run import FIX, ROOT, leak, load_playbook, unsupported_numbers, words

SPANISH = re.compile(r"\b(de|que|para|con|los|las|una|sus|nuestra|nuestro|muebles|usted|le|su|por)\b", re.I)
ENGLISH = re.compile(r"\b(the|and|with|your|our|we|you|for|furniture|would)\b", re.I)

# Added to the fact sheet for this campaign only (the Writer, Strategist and Grader all read the fact sheet).
MX_RULES = {
    "outreach_language": "Every message to a buyer in Mexico is written in Spanish (Mexico), formal 'usted', "
                         "warm and direct. Subject line in Spanish too.",
    "pitch_focus": "Lead with the modern and contemporary line (dining, bedroom, living and storage case goods in "
                   "solid pine and poplar, private label and own designs). Mention the rustic line only as a "
                   "secondary option, and only where the research shows the buyer sells rustic pieces.",
    "unknown_contact": "For most accounts the buyer's name is not known yet. Then address the furniture purchasing "
                       "team politely (e.g. 'Estimado equipo de Compras de Muebles') and never invent a name.",
}


def lang(text: str) -> str:
    es, en = len(SPANISH.findall(text or "")), len(ENGLISH.findall(text or ""))
    return "es" if es >= 2 * max(en, 1) else ("en" if en > es else "mixed")


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40]


def setup(conn, db, playbook: list[dict], buyers: list, inboxes: dict) -> tuple:
    db.register_team(conn)
    db.all_rows(conn, "update agents set active = true, paused_reason = null, monthly_budget_cents = 100000")
    for e in playbook:
        db.all_rows(conn, "insert into playbook_entries (title, body, channel, buyer_types, stage, status) values "
                          "(%s, %s, %s::channel, %s::buyer_type[], %s, 'active')",
                    (e["title"], e["body"], e.get("channel"), e.get("buyer_types") or [], e.get("stage")))
    brief = {k: v for k, v in json.loads((FIX / "santa_fe_rusticos.json").read_text()).items() if not k.startswith("_")}
    brief.pop("questions_for_client", None)
    brief.update(MX_RULES)
    client_id = db.one(conn, """
        insert into clients (name, industry, brief, brief_approved_at, brief_approved_by, sender_name, sender_company,
                             postal_address, daily_draft_limit)
        values ('Santa Fe Rústicos', 'furniture', %s, now(), 'sandbox run', 'Santiago', 'SBM Partners',
                'Dirección postal pendiente (sandbox)', 100) returning id""", (db.jsonb(brief),))["id"]
    campaign_id = db.one(conn, """insert into campaigns (client_id, name, status, channels, min_fit_score)
                                  values (%s, 'México: compradores de muebles (29 cuentas)', 'live', '{email}', 60)
                                  returning id""", (client_id,))["id"]
    ids = {}
    for name, domain, btype, cats, tier, city, state, website in buyers:
        cid = db.one(conn, """insert into companies (name, domain, type, categories, price_tier, hq_city, hq_state, country, website)
                              values (%s, %s, %s::buyer_type, %s, %s, %s, %s, 'MX', %s) returning id""",
                     (name, domain, btype, cats, tier, city, state, website))["id"]
        box = inboxes.get(domain or "")
        email = box["email"] if box else f"comprador-por-identificar@{slug(name)}.invalid"
        source = box["source"] if box else "PLACEHOLDER: buyer not identified yet (sandbox only, cannot receive mail)"
        title = box["title"] if box else "Compras / comprador(a) de muebles (persona por identificar)"
        pid = db.one(conn, """insert into contacts (company_id, title, email, email_source, email_basis, country)
                              values (%s, %s, %s, %s, 'legitimate_interest', 'MX') returning id""",
                     (cid, title, email, source))["id"]
        db.all_rows(conn, "insert into campaign_targets (campaign_id, contact_id, company_id) values (%s, %s, %s)",
                    (campaign_id, pid, cid))
        ids[str(pid)] = {"company": name, "company_id": cid, "placeholder_email": not box, "email": email}
    return client_id, campaign_id, brief, ids


def spent(conn, db) -> float:
    return float(db.one(conn, "select coalesce(sum(cost_cents), 0) / 100.0 as s from agent_runs")["s"])


def work(conn, db, url, c, workers: int, budget: float, log) -> None:
    """Supervisor rounds and the tasks they create, exactly as `agents.team run` does, until nothing is left."""
    from agents import supervisor, team as T
    kinds = ["research_prospect", "qualify_prospect", "draft_outreach"]
    with ThreadPoolExecutor(max_workers=workers) as pool:
        while True:
            out = supervisor.tick(conn)
            log("Supervisor: " + ", ".join(f"{k.replace('_', ' ')} {v}" for k, v in out.items() if v and k != "alerts"))
            ran = 0
            while True:
                if spent(conn, db) >= budget:
                    log(f"Budget of ${budget} reached; stopping. Unfinished work stays in the queue.")
                    return
                batch = db.claim(conn, kinds, "mexico-run", workers)
                if not batch:
                    break
                for r in pool.map(lambda t: T.run_task(t, c, url), batch):
                    log(f"  {r}   (spent ${spent(conn, db):.2f})")
                ran += len(batch)
                if any(t["kind"] != "draft_outreach" for t in batch):
                    break   # let the Supervisor turn finished research/qualification into the next step
            # A failed task is retried in 10 minutes in real life; here it counts as failed.
            db.all_rows(conn, "update tasks set status = 'failed', finished_at = now() where status = 'queued' "
                              "and error is not null and kind = any(%s)", (kinds,))
            if not ran and not db.one(conn, "select 1 from tasks where status in ('queued','running') and kind = any(%s)",
                                      (kinds,)):
                return


def collect(conn, db, campaign_id, ids: dict) -> list[dict]:
    rows = []
    runs = db.all_rows(conn, """select split_part(r.summary, ':', 1) as label, a.name as agent, sum(r.cost_cents) / 100.0 as usd
                                from agent_runs r join agents a on a.id = r.agent_id group by 1, 2""")
    for pid, info in ids.items():
        tasks = db.all_rows(conn, "select id, kind, status::text, output, error from tasks where contact_id = %s order by created_at",
                            (pid,))
        research = next((t["output"] for t in tasks if t["kind"] == "research_prospect" and t["status"] == "done"), None)
        strat = db.one(conn, "select * from prospect_strategies where campaign_id = %s and contact_id = %s", (campaign_id, pid))
        drafts = db.all_rows(conn, "select d.*, send_blockers(d.id) as blockers from outreach_drafts d where contact_id = %s "
                                   "order by created_at", (pid,))
        cost = {}
        for t in tasks:
            label = f"{t['kind']} {str(t['id'])[:8]}"
            for r in runs:
                if r["label"] == label:
                    cost[r["agent"]] = round(cost.get(r["agent"], 0) + float(r["usd"]), 4)
        row = {"company": info["company"], "contact_email": info["email"], "placeholder_email": info["placeholder_email"],
               "tasks": [{"kind": t["kind"], "status": t["status"], "error": t["error"]} for t in tasks],
               "research": research, "strategy": strat, "cost_usd": cost, "drafts": []}
        sources = json.dumps(research or {}, ensure_ascii=False) + json.dumps(strat or {}, default=str, ensure_ascii=False)
        for d in drafts:
            text = f"{d['subject'] or ''}\n{d['body'] or ''}"
            checks = {"language": lang(d["body"]), "words": words(d["body"]),
                      "past_customer_or_hint": leak(text),
                      "numbers_not_in_sources": unsupported_numbers(text, sources + json.dumps(MX_RULES) +
                                                                    (FIX / "santa_fe_rusticos.json").read_text())}
            row["drafts"].append({"channel": d["channel"], "subject": d["subject"], "body": d["body"],
                                  "score": float(d["score"]) if d["score"] is not None else None,
                                  "rewrites": d["rewrites"], "grader": d["grade_feedback"],
                                  "playbook_used": d["playbook_used"], "status": d["status"],
                                  "send_blockers": d["blockers"], "checks": checks})
        rows.append(row)
    order = {"pursue": 0, "nurture": 1, "disqualify": 2}
    rows.sort(key=lambda r: (order.get((r["strategy"] or {}).get("decision"), 3), -((r["strategy"] or {}).get("fit_score") or 0)))
    return rows


# ─────────────────────────── outputs ───────────────────────────
def trail_md(r: dict) -> list[str]:
    s, res = r["strategy"] or {}, r["research"] or {}
    L = [f"## {r['company']}", ""]
    cost = sum(r["cost_usd"].values())
    L.append(f"**Decision: {s.get('decision', 'not reached')}**, fit {s.get('fit_score', '-')}/100. Cost for this account: ${cost:.2f} "
             f"({', '.join(f'{k} ${v:.2f}' for k, v in r['cost_usd'].items()) or 'nothing spent'}).")
    L.append("")
    L.append("### 1. Prospect researcher (live web)")
    if res:
        L += [res.get("summary", ""), ""]
        for f in res.get("facts", []):
            L.append(f"- {f['fact']} ([source]({f['source_url']}))")
        if res.get("dropped_unverified"):
            L.append(f"- ({res['dropped_unverified']} more facts dropped: their source page was never actually opened)")
        L += ["", f"Researcher's angle: {res.get('angle', '')}", "", f"Cautions: {res.get('cautions', '')}",
              f"Researcher's fit rating: {res.get('fit', '-')}/5", ""]
    else:
        err = next((t["error"] for t in r["tasks"] if t["kind"] == "research_prospect"), None)
        L += [f"No research ({err or 'not reached'}).", ""]
    L.append("### 2. Strategist")
    if s:
        L.append("| Criterion | Score | Why |")
        L.append("|---|---|---|")
        for b in s.get("fit_breakdown") or []:
            L.append(f"| {b['key'].replace('_', ' ')} ({b['weight']}%) | {b['score']}/5 | {b['why']} |")
        L += ["", f"Why: {s.get('reason', '')}", ""]
        if s.get("decision") == "pursue":
            L += [f"- Pitch angle: {s.get('pitch_angle')}",
                  f"- Lead with: {', '.join(s.get('lead_with') or [])}",
                  f"- Proof points (from the fact sheet): {'; '.join(s.get('proof_points') or [])}",
                  f"- Offer: {s.get('offer') or '-'}",
                  f"- First ask: {s.get('first_ask')}",
                  f"- Channel: {s.get('channel_plan')} ({s.get('channel_reason')})"]
            for o in s.get("objections") or []:
                L.append(f"- Likely objection: {o['objection']} → {o['answer']}")
            L.append("")
    else:
        L += ["Not qualified.", ""]
    for d in r["drafts"]:
        L.append(f"### 3. Writer → Grader: {d['channel']} draft, score {d['score']}/100"
                 f"{', rewritten once after the Grader' if d['rewrites'] else ''}")
        L.append("")
        if d["subject"]:
            L += [f"**Asunto:** {d['subject']}", ""]
        L += ["```text", d["body"] or "", "```", ""]
        L += [f"Grader: {d['grader']}", ""]
        if d["playbook_used"]:
            L += [f"Playbook entries used: {'; '.join(d['playbook_used'])}", ""]
        c = d["checks"]
        L.append(f"Rule checks: language {c['language']}, {c['words']} words, "
                 f"past customers {'NONE' if not c['past_customer_or_hint'] else 'FOUND: ' + ', '.join(c['past_customer_or_hint'])}, "
                 f"numbers not in the sources: {', '.join(c['numbers_not_in_sources']) or 'none'}.")
        L += ["", f"### 4. Safety gate: {'HELD' if d['send_blockers'] else 'would allow'}"]
        for b in d["send_blockers"] or []:
            L.append(f"- {b}")
        if r["placeholder_email"]:
            L.append(f"- (Sandbox: the address {r['contact_email']} is a placeholder; the buyer still has to be found.)")
        L.append("")
    return L


def report(res: dict) -> str:
    rows = res["rows"]
    dec = {}
    for r in rows:
        k = (r["strategy"] or {}).get("decision", "not reached")
        dec[k] = dec.get(k, 0) + 1
    drafts = [d for r in rows for d in r["drafts"]]
    L = [f"# Agent team on the 29 Mexican buyers ({res['started']})", "",
         f"Cost: **${res['cost_usd']:.2f}** ({', '.join(f'{k} ${v:.2f}' for k, v in res['cost_by_agent'].items())}). "
         f"Time: {res['minutes']} min. Models: {res['models']}.", "",
         "Decisions: " + ", ".join(f"{v} {k}" for k, v in dec.items()) + ".",
         f"Drafts: {len(drafts)}, average Grader score "
         f"{round(sum(d['score'] for d in drafts if d['score'] is not None) / max(1, sum(d['score'] is not None for d in drafts)))}"
         f", {sum(bool(d['rewrites']) for d in drafts)} rewritten, "
         f"{sum(d['checks']['language'] == 'es' for d in drafts)} in Spanish, "
         f"{sum(bool(d['checks']['past_customer_or_hint']) for d in drafts)} mention a past customer, "
         f"{sum(bool(d['send_blockers']) for d in drafts)} held by the safety gate. Nothing was sent.", "",
         "| Account | Decision | Fit | Draft score | Cost |", "|---|---|---|---|---|"]
    for r in rows:
        s = r["strategy"] or {}
        sc = ", ".join(str(d["score"]) for d in r["drafts"]) or "-"
        L.append(f"| {r['company']} | {s.get('decision', '-')} | {s.get('fit_score', '-')} | {sc} | ${sum(r['cost_usd'].values()):.2f} |")
    if res.get("errors"):
        L += ["", "Errors:", *[f"- {e}" for e in res["errors"]]]
    return "\n".join(L)


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--playbook", help="JSON list of approved playbook entries (default: read from Supabase, read-only)")
    ap.add_argument("--db", help="a LOCAL throwaway database instead of starting one")
    ap.add_argument("--only", default="", help="comma-separated parts of account names to run (default: all 29)")
    ap.add_argument("--budget", type=float, default=25.0)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--out")
    args = ap.parse_args(argv)
    for k in ("MAIL_ADDRESS", "MAIL_PASSWORD", "SMTP_HOST", "IMAP_HOST"):   # drafts only: no mailbox at all
        os.environ.pop(k, None)
    playbook, source = load_playbook(args.playbook)
    os.environ.pop("DATABASE_URL", None)   # from here on, nothing can reach Supabase
    fx = json.loads((FIX / "mexico_buyers.json").read_text())
    buyers = fx["buyers"]
    if args.only:
        want = [w.strip().lower() for w in args.only.split(",") if w.strip()]
        buyers = [b for b in buyers if any(w in b[0].lower() for w in want)]
    out = pathlib.Path(args.out) if args.out else ROOT / "out" / "mexico-run" / dt.datetime.now().strftime("%Y-%m-%d_%H%M")
    out.mkdir(parents=True, exist_ok=True)
    log_f = open(out / "run.log", "w")

    def log(m: str) -> None:
        line = f"{dt.datetime.now():%H:%M:%S} {m}"
        print(line, flush=True)
        log_f.write(line + "\n")
        log_f.flush()

    log(f"Playbook: {len(playbook)} approved entries from {source}. Accounts: {len(buyers)}. Budget ${args.budget}.")
    from agents import teamdb as db
    from agents.common import client
    from .sandbox import Sandbox
    c = client()
    t0 = time.time()
    res = {"started": dt.datetime.now().strftime("%Y-%m-%d %H:%M"), "errors": [],
           "models": ", ".join(f"{n} {db.TEAM[n][1]}" for n in ("prospect-researcher", "strategist", "writer", "grader"))}
    with Sandbox(args.db) as url:
        conn = db.connect(url)
        client_id, campaign_id, brief, ids = setup(conn, db, playbook, buyers, fx["inboxes"])
        (out / "fact_sheet_used.json").write_text(json.dumps(brief, indent=1, ensure_ascii=False))
        try:
            work(conn, db, url, c, args.workers, args.budget, log)
        except Exception as exc:
            traceback.print_exc()
            res["errors"].append(f"{type(exc).__name__}: {exc}")
        res["rows"] = collect(conn, db, campaign_id, ids)
        res["cost_by_agent"] = {r["name"]: float(r["usd"]) for r in db.all_rows(conn, """
            select a.name, round(sum(r.cost_cents) / 100.0, 2) as usd from agent_runs r join agents a on a.id = r.agent_id
            group by 1 order by 2 desc""")}
        res["cost_usd"] = round(spent(conn, db), 2)
        res["errors"] += [f"{t['kind']} for {ids[str(t['contact_id'])]['company']}: {t['error']}" for t in db.all_rows(
            conn, "select kind, contact_id, error from tasks where status = 'failed'")]
        conn.close()
    res["minutes"] = round((time.time() - t0) / 60, 1)
    (out / "results.json").write_text(json.dumps(res, indent=1, default=str, ensure_ascii=False))
    (out / "report.md").write_text(report(res))
    md = [report(res), "", "---", ""]
    for r in res["rows"]:
        md += trail_md(r) + ["---", ""]
    (out / "drafts_es.md").write_text("\n".join(md))
    log(f"Done. Cost ${res['cost_usd']:.2f}. Read {out / 'drafts_es.md'}")


if __name__ == "__main__":
    main()
