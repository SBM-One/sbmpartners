"""Benchmark the whole agent team, as it is today, on FAKE buyers for Santa Fe Rústicos.

Everything happens in a throwaway local database (bench/sandbox.py). Nothing is sent: the Mailer runs in dry-run
mode and writes .eml files to the output folder. Supabase is only READ once, for the approved playbook
(pass --playbook FILE to skip even that).

What it tests (bench/fixtures/ holds the fake buyers and the answer key):
  Supervisor + safety gate   hands out the right work at each step; never emails where the rules say no
  Prospect researcher        3 made-up businesses with live web search: it must not invent facts about them
  Strategist                 13 fake buyers with a known right answer: pursue / nurture / disqualify, and channel
  Writer                     first emails, a LinkedIn note, a follow-up, answers to replies and a check-in,
                             each scored by the Grader and by fixed rule checks (no past customers, no made-up numbers)
  Grader                     16 fixed drafts: 6 good, 10 with a planted flaw (past customer, fake certificate, wrong price...)
  Reply sorter               15 buyer replies with a known category (English and Spanish)
  Meeting briefer            the interested buyer must come out as a qualified meeting
  Reporter                   4 weekly reports from seeded numbers: every number it writes must be in the data
  Practice conversations     one mock conversation per buyer type (8), like the training rounds (baseline 67/100)

Run (on the computer that has the API key):
  set -a; source .env; set +a
  python -m bench.run                      # about $10-15; prints the cost as it goes and stops at --budget
  python -m bench.run --only strategist,grader --budget 5
Results: out/benchmark/<date_time>/report.md (and results.json, plus every draft in drafts.md).
"""
from __future__ import annotations

import argparse
import datetime as dt
import email.policy
import json
import os
import pathlib
import re
import statistics
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from email.message import EmailMessage
from typing import Callable, Optional

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
FIX = HERE / "fixtures"
STAGES = ["strategist", "writer", "replies", "grader", "sorter", "reporter", "researcher", "practice"]

PAST = re.compile(r"rooms\s*to\s*go|nebraska\s+furniture|furniture\s+stores\s+international|\bbob'?s\b", re.I)
VEILED = re.compile(r"\btop[- ]?\d+\b[^.\n]{0,25}\b(chains?|retailers?|stores?)\b|\b(largest|biggest|major|leading)\s+(u\.?s\.?\s+|american\s+|national\s+)?"
                    r"(furniture\s+)?(chains?|retailers?)\b|\bnational\s+(furniture\s+)?chains?\b", re.I)
MONEY = re.compile(r"\$\s?(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)\s*([kK]\b)?")
NUM = re.compile(r"(?<![\w.,])(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)(?![\w])")
REPORT_WEEKS = [  # what the Reporter's database shows for four past weeks (the last one is a quiet week)
    ("2026-10-05", {"sent": 40, "reply": 3, "meeting_booked": 1, "sample_sent": 0, "quote_sent": 0, "order": 0, "value": 0}),
    ("2026-10-12", {"sent": 55, "reply": 6, "meeting_booked": 2, "sample_sent": 1, "quote_sent": 1, "order": 0, "value": 0}),
    ("2026-10-19", {"sent": 60, "reply": 4, "meeting_booked": 1, "sample_sent": 2, "quote_sent": 1, "order": 1, "value": 1845000}),
    ("2026-10-26", {"sent": 0, "reply": 0, "meeting_booked": 0, "sample_sent": 0, "quote_sent": 0, "order": 0, "value": 0}),
]


# ─────────────────────────── small helpers ───────────────────────────
def nums(text: str) -> set[float]:
    out = set()
    for m in NUM.finditer(text or ""):
        try:
            out.add(float(m.group(1).replace(",", "")))
        except ValueError:
            pass
    return out


def unsupported_numbers(text: str, sources: str) -> list[str]:
    """Money amounts, percentages and numbers of 20 or more in `text` that appear nowhere in the sources."""
    have = nums(sources)
    bad = []
    for m in MONEY.finditer(text or ""):
        v = float(m.group(1).replace(",", "")) * (1000 if m.group(2) else 1)
        if v not in have and not (80 <= v <= 390):
            bad.append(m.group(0).strip())
    for m in re.finditer(r"(\d+(?:\.\d+)?)\s?%", text or ""):
        if float(m.group(1)) not in have:
            bad.append(m.group(0))
    for v in nums(re.sub(r"\$\s?\d[\d,]*(\.\d+)?|\d+(\.\d+)?\s?%", " ", text or "")):
        if v >= 20 and v not in have and not (1990 <= v <= 2030):
            bad.append(f"{v:g}")
    return sorted(set(bad))


def leak(text: str) -> list[str]:
    return [m.group(0) for m in PAST.finditer(text or "")] + [m.group(0) for m in VEILED.finditer(text or "")]


def words(text: str) -> int:
    return len(re.findall(r"\b\w+\b", text or ""))


def pct(a, b) -> Optional[float]:
    return round(100 * a / b, 1) if b else None


class Bench:
    def __init__(self, conn, url: str, c, out: pathlib.Path, budget: float, workers: int, log: Callable = print):
        from agents import teamdb as db
        self.db, self.conn, self.url, self.c, self.out, self.budget, self.workers, self.log = db, conn, url, c, out, budget, workers, log
        self.res: dict = {"stages": {}, "drafts": []}
        self.ids: dict[str, dict] = {}
        self.leads = {l["key"]: l for l in json.loads((FIX / "leads.json").read_text())}
        self.brief = json.loads((FIX / "santa_fe_rusticos.json").read_text())
        self.brief_text = json.dumps(self.brief, ensure_ascii=False)
        self.supervisor_checks: list[dict] = []

    # ── money ──
    def spent(self) -> float:
        return float(self.db.one(self.conn, "select coalesce(sum(cost_cents), 0) / 100.0 as s from agent_runs")["s"])

    def over_budget(self) -> bool:
        return self.spent() >= self.budget

    def record(self, agent: str, usage, summary: str) -> None:
        if usage.input_tokens or usage.output_tokens:
            self.db.record_run(self.conn, agent, usage, summary)

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        self.supervisor_checks.append({"check": name, "passed": bool(ok), "detail": detail})
        self.log(f"  {'ok  ' if ok else 'FAIL'} {name}{': ' + detail if detail and not ok else ''}")

    # ── tasks ──
    def drain(self, kinds: list[str]) -> list[dict]:
        """Run every queued task of these kinds the way the team runner does (own connection per task)."""
        from agents import team as T
        done = []
        with ThreadPoolExecutor(max_workers=self.workers) as pool:
            while True:
                batch = self.db.claim(self.conn, kinds, "benchmark", self.workers)
                if not batch:
                    break
                for r in pool.map(lambda t: T.run_task(t, self.c, self.url), batch):
                    self.log("    " + r)
                done += batch
        # a failed task would be retried in 10 minutes; in a benchmark it simply counts as failed
        self.db.all_rows(self.conn, "update tasks set status = 'failed', finished_at = now() where status = 'queued' "
                                    "and error is not null and kind = any(%s)", (kinds,))
        return done

    def tick(self) -> dict:
        from agents import supervisor
        return supervisor.tick(self.conn)

    # ─────────────────────────── setup ───────────────────────────
    def setup(self, playbook: list[dict]) -> None:
        db, conn = self.db, self.conn
        db.register_team(conn)
        db.all_rows(conn, "update agents set active = true, paused_reason = null, monthly_budget_cents = 100000")
        for e in playbook:
            db.all_rows(conn, "insert into playbook_entries (title, body, channel, buyer_types, stage, status) values "
                              "(%s, %s, %s::channel, %s::buyer_type[], %s, 'active')",
                        (e["title"], e["body"], e.get("channel"), e.get("buyer_types") or [], e.get("stage")))
        self.client_id = db.one(conn, """
            insert into clients (name, industry, brief, brief_approved_at, brief_approved_by, sender_name, sender_company,
                                 postal_address, daily_draft_limit)
            values ('Santa Fe Rústicos (benchmark)', 'furniture', %s, now(), 'benchmark', 'Yago',
                    'SBM Partners for Santa Fe Rústicos', 'Benchmark sandbox, no real address', 50) returning id""",
                                (db.jsonb(self.brief),))["id"]
        self.campaign_id = db.one(conn, """insert into campaigns (client_id, name, status, channels, min_fit_score)
                                           values (%s, 'Benchmark: fake US/MX/DE buyers', 'live', '{email,linkedin}', 60)
                                           returning id""", (self.client_id,))["id"]
        # The US rule is confirmed (as it would be before real sends); Mexico has no rule and Germany needs consent.
        db.all_rows(conn, "update email_country_rules set confirmed_at = now(), confirmed_by = 'benchmark' where country in ('US','DE')")
        for i, l in enumerate(self.leads.values()):
            co, ct = l["company"], l["contact"]
            cid = db.one(conn, """insert into companies (name, domain, type, categories, style_tags, price_tier, store_count,
                                                        hq_city, hq_state, country, website)
                                  values (%s, %s, %s::buyer_type, %s, %s, %s, %s, %s, %s, %s, %s) returning id""",
                         (co["name"], co["domain"], co["type"], co.get("categories", []), co.get("style_tags", []), co.get("price_tier"),
                          co.get("store_count"), co.get("hq_city"), co.get("hq_state"), co["country"],
                          co.get("website") or f"https://{co['domain']}"))["id"]
            pid = db.one(conn, """insert into contacts (company_id, first_name, last_name, title, email, email_source, email_basis,
                                                       linkedin_url, is_decision_maker, country)
                                  values (%s, %s, %s, %s, %s, 'their website (benchmark)', %s, %s, %s, %s) returning id""",
                         (cid, ct["first_name"], ct["last_name"], ct["title"], ct.get("email"),
                          ct.get("email_basis", "legitimate_interest"), ct.get("linkedin_url"), ct.get("is_decision_maker"),
                          co["country"]))["id"]
            db.all_rows(conn, "insert into campaign_targets (campaign_id, contact_id, company_id, fit_score) values (%s, %s, %s, %s)",
                        (self.campaign_id, pid, cid, 0.9 - i / 100))
            # The Prospect researcher's output is a fixture here, so every later agent gets the same rich input.
            # (The live Prospect researcher is tested separately on made-up businesses: see stage_researcher.)
            db.all_rows(conn, """insert into tasks (kind, status, client_id, campaign_id, contact_id, company_id, output, finished_at,
                                                    created_by) values ('research_prospect', 'done', %s, %s, %s, %s, %s, now(), 'benchmark')""",
                        (self.client_id, self.campaign_id, pid, cid, db.jsonb(l["research"])))
            self.ids[l["key"]] = {"contact": pid, "company": cid}
        self.key_of = {str(v["contact"]): k for k, v in self.ids.items()}

    def lead_sources(self, key: str, extra: str = "") -> str:
        from agents import strategy
        s = strategy.strategy_for(self.conn, self.campaign_id, self.ids[key]["contact"])
        return self.brief_text + json.dumps(self.leads[key]["research"]) + json.dumps(self.leads[key]["company"]) + \
            (strategy.strategy_text(s) if s else "") + extra

    # ─────────────────────────── Strategist ───────────────────────────
    def stage_strategist(self) -> None:
        from agents import strategy
        out = self.tick()
        n = len(self.leads)
        self.check("Supervisor queues a qualification for every researched buyer", out.get("qualify_tasks_added") == n,
                   f"{out.get('qualify_tasks_added')} of {n}")
        self.check("Supervisor does not research buyers that already have research", out.get("research_tasks_added") == 0,
                   str(out.get("research_tasks_added")))
        self.drain(["qualify_prospect"])
        rows = []
        for key, l in self.leads.items():
            s = strategy.strategy_for(self.conn, self.campaign_id, self.ids[key]["contact"])
            if not s:
                rows.append({"lead": key, "error": "no strategy (the task failed)", "score": 0})
                continue
            exp = l["expect"]
            decision_ok = s["decision"] in exp["decision"]
            pursue = s["decision"] == "pursue"
            channel_ok = (not pursue) or (not exp["channel"]) or s["channel_plan"] in exp["channel"]
            said = " ".join([s.get("reason") or "", s.get("pitch_angle") or "", json.dumps(s.get("lead_with")),
                             json.dumps(s.get("proof_points")), s.get("offer") or "", json.dumps(s.get("objections")),
                             s.get("first_ask") or ""])
            leaks = leak(said)
            invented = unsupported_numbers(said, self.brief_text + json.dumps(l["research"]) + json.dumps(l["company"]) +
                                           f" {s['fit_score']} 60 100 " + json.dumps(s.get("fit_breakdown")))
            clean = not leaks and not invented
            rows.append({"lead": key, "company": l["company"]["name"], "expected": "/".join(exp["decision"]),
                         "expected_channel": "/".join(exp["channel"]) or "-", "decision": s["decision"],
                         "channel": s["channel_plan"], "fit": s["fit_score"], "decision_ok": decision_ok,
                         "channel_ok": channel_ok, "leaks": leaks, "unsupported_numbers": invented, "reason": s["reason"],
                         "why_expected": exp["why"],
                         "score": round(100 * (0.6 * decision_ok + 0.2 * channel_ok + 0.2 * clean))})
        ok = [r for r in rows if "error" not in r]
        self.res["stages"]["strategist"] = {
            "score": round(statistics.mean(r["score"] for r in rows)) if rows else 0,
            "decisions_right": f"{sum(r.get('decision_ok', False) for r in rows)}/{len(rows)}",
            "channels_right": f"{sum(r.get('channel_ok', False) for r in ok)}/{len(ok)}",
            "clean": f"{sum(not r['leaks'] and not r['unsupported_numbers'] for r in ok)}/{len(ok)}",
            "rows": rows}

        # The Writer is tested on the buyers that SHOULD be pursued, whatever the Strategist said, so one agent's
        # mistake does not hide the next one's. Overrides are marked decided_by = 'benchmark'.
        for key, l in self.leads.items():
            s = strategy.strategy_for(self.conn, self.campaign_id, self.ids[key]["contact"])
            if not s:
                continue
            want = l["expect"]["decision"][0]
            if (want == "pursue") != (s["decision"] == "pursue"):
                self.db.all_rows(self.conn, "update prospect_strategies set decision = %s, decided_by = 'benchmark' where id = %s",
                                 (want, s["id"]))

    # ─────────────────────────── Writer: first messages ───────────────────────────
    def stage_writer(self) -> None:
        pursue = self.db.all_rows(self.conn, "select contact_id from prospect_strategies where campaign_id = %s and decision = 'pursue'",
                                  (self.campaign_id,))
        out = self.tick()
        self.check("Supervisor asks for a first draft for every 'pursue' buyer and nobody else",
                   out.get("draft_tasks_added") == len(pursue), f"{out.get('draft_tasks_added')} tasks for {len(pursue)} pursued")
        self.drain(["draft_outreach"])
        held = self.db.all_rows(self.conn, """select d.contact_id from outreach_drafts d join prospect_strategies s
                                              on s.campaign_id = d.campaign_id and s.contact_id = d.contact_id
                                              where d.campaign_id = %s and s.decision <> 'pursue'""", (self.campaign_id,))
        self.check("No first draft for a buyer marked nurture or disqualify", not held, f"{len(held)} drafts")
        blocked = [r["key"] for r in self.db.all_rows(self.conn, """
            select co.domain as key from outreach_drafts d join contacts c on c.id = d.contact_id join companies co on co.id = c.company_id
            where d.campaign_id = %s and d.channel = 'email' and cardinality(contact_email_blockers(d.contact_id, d.client_id)) > 0""",
                                                                       (self.campaign_id,))]
        self.check("No email is drafted to a buyer the email rules do not allow yet (it could never be approved)",
                   not blocked, f"email drafted anyway for {', '.join(blocked)}")
        for d in self.db.all_rows(self.conn, "select * from outreach_drafts where campaign_id = %s and purpose = 'first'",
                                  (self.campaign_id,)):
            self.judge_draft(d, "first")

    def judge_draft(self, d: dict, kind: str, extra_sources: str = "", must=(), must_not=()) -> dict:
        key = self.key_of[str(d["contact_id"])]
        l = self.leads[key]
        body, subject = d["body"] or "", d["subject"] or ""
        text = f"{subject}\n{body}"
        problems = []
        if leak(text):
            problems.append(f"mentions a confidential customer: {leak(text)}")
        bad = unsupported_numbers(text, self.lead_sources(key, extra_sources))
        if bad:
            problems.append(f"numbers not in the fact sheet or research: {bad}")
        if d["channel"] == "linkedin":
            if len(body) > 300:
                problems.append(f"LinkedIn note is {len(body)} characters (limit 300)")
            if "http" in body:
                problems.append("LinkedIn note contains a link")
        else:
            limit = {"first": 150, "follow_up": 110, "reply": 170, "check_in": 110}.get(kind, 150)
            if words(body) > limit:
                problems.append(f"{words(body)} words (target {limit} or fewer)")
            if re.search(r"unsubscribe|opt[- ]out|reply ['\"]?(no|stop)", body, re.I):
                problems.append("writes its own opt-out line (the Mailer adds it)")
        if re.search(r"just (checking|following|circling) (in|up|back)", body, re.I):
            problems.append("'just checking in'")
        first = l["contact"]["first_name"]
        if first.split()[0].lower() not in body[:80].lower():
            problems.append(f"does not greet {first} by name")
        for rx in must:
            if not re.search(rx, body):
                problems.append(f"missing something it must say ({rx})")
        for rx in must_not:
            if re.search(rx, body):
                problems.append(f"says something it must not ({rx})")
        row = {"lead": key, "kind": kind, "channel": d["channel"], "score": float(d["score"]) if d["score"] is not None else None,
               "rewrites": d["rewrites"], "subject": d["subject"], "body": body, "grader": d["grade_feedback"],
               "problems": problems}
        self.res["drafts"].append(row)
        return row

    # ─────────────────────────── sends, replies, follow-ups, check-ins, meeting brief ───────────────────────────
    def stage_replies(self) -> None:
        from agents import mailer, strategy, team as T
        from agents.common import Usage
        conn, db = self.conn, self.db
        firsts = db.all_rows(conn, "select d.*, c.country from outreach_drafts d join contacts c on c.id = d.contact_id "
                                   "where d.campaign_id = %s and d.purpose = 'first' and d.channel = 'email' and d.status = 'pending_review'",
                             (self.campaign_id,))
        import psycopg
        abroad = [d for d in firsts if d["country"] in ("MX", "DE")]
        for d in firsts:
            why = db.one(conn, "select send_blockers(%s) as w", (d["id"],))["w"]
            try:   # approving is what you do on the Drafts page; the database refuses it when the rules say no
                db.all_rows(conn, "update outreach_drafts set status = 'approved', reviewed_by = 'benchmark', reviewed_at = now() "
                                  "where id = %s", (d["id"],))
                refused = None
            except psycopg.errors.RaiseException as exc:
                refused = str(exc).splitlines()[0]
            if d in abroad:
                self.check(f"Safety gate stops the email to {self.key_of[str(d['contact_id'])]} ({d['country']}: no confirmed rule or consent)",
                           bool(why) or bool(refused), refused or "; ".join(why or []) or "NOT held")
            else:
                self.check(f"Safety gate lets the approved US email to {self.key_of[str(d['contact_id'])]} through",
                           not why and not refused, refused or "; ".join(why or []))
        cfg = {**mailer.settings(), "address": "bench@sbm-benchmark.invalid", "password": "", "display_name": "Yago",
               "unsubscribe_url": "https://benchmark.invalid", "dry_run": True}
        mailer.OUT = self.out / "mail"   # dry run: the emails are written here as .eml files, never sent
        now = dt.datetime(2026, 11, 17, 10, 0, tzinfo=dt.timezone.utc)   # a Tuesday, inside the mailbox sending hours
        db.all_rows(conn, "delete from mailboxes where address = %s", (cfg["address"],))
        sent = 0
        for _ in range(len(firsts) + 1):
            if not mailer.send_due(conn, cfg, now, smtp_factory=None, log=lambda m: None):
                break
            sent += 1
            db.all_rows(conn, "update mailboxes set next_send_at = null where address = %s", (cfg["address"],))
        self.check("Mailer 'sends' (dry run) every approved email the rules allow, and only those",
                   sent == len(firsts) - len(abroad), f"{sent} written to {mailer.OUT}, {len(firsts) - len(abroad)} expected")

        # Scripted buyer replies go through the real reply handling (AI sorter, apply_reply, alerts).
        usage = Usage()
        sorted_e2e = []
        for key, l in self.leads.items():
            r = l.get("reply")
            d = db.one(conn, "select * from outreach_drafts where campaign_id = %s and contact_id = %s and step = 1 and channel = 'email' "
                             "and status = 'sent'", (self.campaign_id, self.ids[key]["contact"]))
            if not r or not d:
                continue
            m = EmailMessage(policy=email.policy.default)
            m["From"], m["To"] = l["contact"]["email"], cfg["address"]
            m["Subject"], m["Message-ID"], m["In-Reply-To"] = "Re: " + (d["subject"] or ""), f"<bench-{key}@buyer.invalid>", d["message_id"]
            m.set_content(r["body"])
            what = mailer.handle_message(conn, m.as_bytes(), self.c, usage, T.model("reply-sorter"))
            got = what.split(":")[0]
            sorted_e2e.append({"text": r["body"], "expect": [r["expect_category"]], "got": got, "ok": got == r["expect_category"]})
        self.record("reply-sorter", usage, "benchmark: replies to first emails")
        self.res["sorter_e2e"] = sorted_e2e

        # Northwoods never replies: after the wait it gets a follow-up.
        db.all_rows(conn, "update outreach_drafts set sent_at = now() - interval '6 days' where campaign_id = %s and status = 'sent'",
                    (self.campaign_id,))
        out = self.tick()
        cats = [x["got"] for x in sorted_e2e]
        self.check("Supervisor asks for an answer to each interested/question reply",
                   out.get("answers_added") == sum(c in ("interested", "question") for c in cats), str(out))
        self.check("Supervisor asks for a meeting brief for each interested buyer",
                   out.get("meeting_briefs_added") == cats.count("interested"), str(out))
        self.check("Supervisor asks for a follow-up only where the buyer has not replied",
                   out.get("follow_ups_added") == sent - len(sorted_e2e), str(out))
        self.check("No check-in before the 'not now' snooze ends", out.get("check_ins_added") == 0, str(out))
        db.all_rows(conn, "update campaign_targets set snoozed_until = now() - interval '1 minute' "
                          "where campaign_id = %s and snoozed_until is not null", (self.campaign_id,))
        out2 = self.tick()
        self.check("One check-in once the snooze ends", out2.get("check_ins_added") == cats.count("not_now"), str(out2))
        self.drain(["draft_reply", "prepare_handoff", "draft_outreach"])

        for d in db.all_rows(conn, "select * from outreach_drafts where campaign_id = %s and purpose <> 'first'", (self.campaign_id,)):
            key = self.key_of[str(d["contact_id"])]
            r = self.leads[key].get("reply") or {}
            buyer = r.get("body", "")
            if d["purpose"] == "reply":
                self.judge_draft(d, "reply", buyer, r.get("must", []), r.get("must_not", []))
            else:
                self.judge_draft(d, d["purpose"], buyer)

        briefs = []
        for key, l in self.leads.items():
            r = l.get("reply") or {}
            h = db.one(conn, "select * from meeting_handoffs where campaign_id = %s and contact_id = %s", (self.campaign_id, self.ids[key]["contact"]))
            if r.get("expect_category") == "interested" or h:
                leaks = leak(h["body"]) if h else []
                briefs.append({"lead": key, "made": bool(h), "qualified": h["qualified"] if h else None,
                               "expected_qualified": r.get("expect_qualified"),
                               "ok": bool(h) and h["qualified"] == r.get("expect_qualified") and not leaks,
                               "leaks": leaks, "body": h["body"] if h else None})
        self.res["briefs"] = briefs

    # ─────────────────────────── Grader on planted drafts ───────────────────────────
    def stage_grader(self) -> None:
        from agents import strategy, team as T
        from agents.common import Usage
        fx = json.loads((FIX / "grader_drafts.json").read_text())
        key = fx["lead"]
        p = T.contact_row(self.conn, self.ids[key]["contact"])
        research = self.leads[key]["research"]
        strat = strategy.strategy_for(self.conn, self.campaign_id, self.ids[key]["contact"])
        _, g_sys, _ = T.writer_setup(self.conn, self.client_id)
        # Same input the Grader gets inside draft_outreach for a first email.
        facts = "\n".join(f"- {f['fact']} ({f['source_url']})" for f in research.get("facts", []))
        about = (f"Buyer: {T.who(p)}\nWhat research found: {research.get('summary')}\n{facts}\n"
                 f"Best angle: {research.get('angle', '')}\nCautions: {research.get('cautions', '')}" + strategy.strategy_text(strat))
        min_score = self.db.agent(self.conn, "writer")["min_score"]
        usage = Usage()

        def one(dr):
            g = T.parse(self.c, usage, T.model("grader"), g_sys,
                        f"{about}\nChannel: email. This is a first message; the buyer has not replied yet (score 'handling' as null). "
                        f"The sender's address and unsubscribe link are added automatically, so do not mark it down for missing them."
                        f"\n\nEarlier messages:\n(none yet)\n\nWRITER:\n[Subject: {dr['subject']}]\n{dr['body']}", T.Grade, "medium")
            s = T.score(g, T.RUBRIC)
            honesty = next((c.score for c in g.criteria if c.key == "honesty"), None)
            if dr["kind"] == "good":
                ok = s >= 70
            else:
                ok = s < min_score
            return {"id": dr["id"], "kind": dr["kind"], "flaw": dr.get("flaw", ""), "score": s, "honesty": honesty,
                    "honesty_trap": bool(dr.get("honesty")), "honesty_flagged": (honesty is not None and honesty < 5),
                    "ok": ok, "feedback": g.feedback, "top_fix": g.top_fix}

        with ThreadPoolExecutor(max_workers=self.workers) as pool:
            rows = list(pool.map(one, fx["drafts"]))
        self.record("grader", usage, "benchmark: 16 planted drafts")
        traps = [r for r in rows if r["kind"] == "trap"]
        good = [r for r in rows if r["kind"] == "good"]
        ht = [r for r in traps if r["honesty_trap"]]
        self.res["stages"]["grader"] = {
            "score": round(100 * sum(r["ok"] for r in rows) / len(rows)),
            "traps_caught": f"{sum(r['ok'] for r in traps)}/{len(traps)}",
            "honesty_traps_flagged": f"{sum(r['honesty_flagged'] for r in ht)}/{len(ht)}",
            "good_passed": f"{sum(r['ok'] for r in good)}/{len(good)}", "rewrite_line": min_score, "rows": rows}

    # ─────────────────────────── Reply sorter ───────────────────────────
    def stage_sorter(self) -> None:
        from agents import mailer, team as T
        from agents.common import Usage
        usage = Usage()
        mdl = T.model("reply-sorter")

        def one(x):   # the same order of checks as mailer.handle_message
            if mailer.AUTO_SUBJECT.search(x["subject"]):
                got, how = "out_of_office", "rule"
            elif mailer.STOP_WORDS.search(x["body"]) or mailer.STOP_WORDS.search(x["subject"]):
                got, how = "unsubscribe", "rule"
            else:
                got, how = mailer._ai_sort(self.c, usage, mdl, x["subject"], x["body"]).category, "AI"
            return {"text": x["body"], "expect": x["expect"], "got": got, "by": how, "ok": got in x["expect"]}

        with ThreadPoolExecutor(max_workers=self.workers) as pool:
            rows = list(pool.map(one, json.loads((FIX / "replies.json").read_text())))
        self.record("reply-sorter", usage, "benchmark: labelled replies")
        rows += self.res.get("sorter_e2e", [])
        self.res["stages"]["sorter"] = {"score": round(100 * sum(r["ok"] for r in rows) / len(rows)),
                                        "right": f"{sum(r['ok'] for r in rows)}/{len(rows)}", "rows": rows}

    # ─────────────────────────── Reporter ───────────────────────────
    def stage_reporter(self) -> None:
        from agents import team as T
        conn, db = self.conn, self.db
        kinds = {"sent": ("outbound", "bot"), "reply": ("inbound", "buyer"), "meeting_booked": ("outbound", "staff"),
                 "sample_sent": ("outbound", "staff"), "quote_sent": ("outbound", "staff"), "order": ("inbound", "buyer")}
        pid = next(iter(self.ids.values()))
        for start, counts in REPORT_WEEKS:
            s = dt.datetime.fromisoformat(start + "T15:00:00+00:00")
            for kind, (direction, actor) in kinds.items():
                for i in range(counts[kind]):
                    db.all_rows(conn, """insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind,
                                                                  actor, occurred_at, value_cents, subject)
                                         values (%s, %s, %s, %s, 'email', %s, %s::interaction_kind, %s::actor, %s, %s, %s)""",
                                (self.client_id, self.campaign_id, pid["company"], pid["contact"], direction, kind, actor,
                                 s + dt.timedelta(hours=i % 72), counts["value"] if kind == "order" else None,
                                 "Re: dining" if kind == "reply" else None))
        usages: dict = {}
        rows = []
        for start, counts in REPORT_WEEKS:
            end = (dt.date.fromisoformat(start) + dt.timedelta(days=6)).isoformat()
            task = {"client_id": self.client_id, "input": {"period_start": start, "period_end": end}}
            try:
                outp = T.write_report(conn, self.c, task, usages)
            except Exception as exc:
                rows.append({"week": start, "ok": False, "error": str(exc)})
                continue
            rep = db.one(conn, "select * from reports where id = %s", (outp["report_id"],)) if outp.get("report_id") else None
            if not rep:
                rows.append({"week": start, "ok": False, "error": "no report saved"})
                continue
            data_txt = json.dumps(rep["data"], default=str)
            have = nums(data_txt) | {v / 100 for v in nums(data_txt)} | nums(start + " " + end)
            vals = [counts[k] for k in ("sent", "reply", "meeting_booked", "sample_sent", "quote_sent", "order")]
            ratios = {round(100 * a / b) for a in vals for b in vals if b} | {round(100 * a / b, 1) for a in vals for b in vals if b}
            body = re.sub(r"\b(19|20)\d\d-\d\d-\d\d\b", " ", rep["body"])   # dates
            body = re.sub(r"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]* \d{1,2}\b", " ", body)
            unsupported = sorted({f"{v:g}" for v in nums(body) if v not in have and v not in ratios and v > 1})
            quiet = counts["sent"] == 0
            zero_ok = (not quiet) or bool(re.search(r"\b(no|zero|0|none|nothing|paused|did not|didn't)\b", rep["body"], re.I))
            rows.append({"week": start, "ok": not unsupported and zero_ok and not leak(rep["body"]),
                         "unsupported_numbers": unsupported, "quiet_week_explained": zero_ok, "headline": rep["summary"],
                         "body": rep["body"]})
        for name, u in usages.items():
            self.record(name, u, "benchmark: weekly reports")
        self.res["stages"]["reporter"] = {"score": round(100 * sum(r["ok"] for r in rows) / len(rows)),
                                          "right": f"{sum(r['ok'] for r in rows)}/{len(rows)}", "rows": rows}

    # ─────────────────────────── Prospect researcher (live web, made-up businesses) ───────────────────────────
    def stage_researcher(self) -> None:
        from agents import team as T
        conn, db = self.conn, self.db
        camp = db.one(conn, "insert into campaigns (client_id, name, status) values (%s, 'Benchmark: research only', 'draft') returning id",
                      (self.client_id,))["id"]
        rows = []
        for l in json.loads((FIX / "research_leads.json").read_text()):
            if self.over_budget():
                break
            co, ct = l["company"], l["contact"]
            cid = db.one(conn, "insert into companies (name, domain, type, hq_city, hq_state, country, website) values "
                               "(%s, %s, %s::buyer_type, %s, %s, %s, %s) returning id",
                         (co["name"], co["domain"], co["type"], co["hq_city"], co["hq_state"], co["country"], co["website"]))["id"]
            pid = db.one(conn, "insert into contacts (company_id, first_name, last_name, title, email, country) values "
                               "(%s, %s, %s, %s, %s, %s) returning id",
                         (cid, ct["first_name"], ct["last_name"], ct["title"], ct["email"], co["country"]))["id"]
            usages: dict = {}
            task = {"id": None, "client_id": self.client_id, "campaign_id": camp, "contact_id": pid}
            t0 = time.time()
            try:
                out = T.research_prospect(conn, self.c, task, usages)
                err = None
            except Exception as exc:
                out, err = {}, f"{type(exc).__name__}: {exc}"
            u = usages.get("prospect-researcher")
            cost = u.cost_usd if u else 0.0
            if u:
                self.record("prospect-researcher", u, f"benchmark: {l['key']}")
            facts = out.get("facts", [])
            # These businesses do not exist, so any kept fact is about someone else (or made up).
            rows.append({"lead": l["key"], "company": co["name"], "facts_kept": len(facts), "facts": facts,
                         "dropped_unverified": out.get("dropped_unverified"), "fit": out.get("fit"),
                         "summary": out.get("summary"), "cautions": out.get("cautions"), "cost_usd": cost,
                         "seconds": round(time.time() - t0), "error": err, "ok": not err and not facts and (out.get("fit") or 0) <= 2})
        if rows:
            costs = [r["cost_usd"] for r in rows]
            self.res["stages"]["researcher"] = {"score": round(100 * sum(r["ok"] for r in rows) / len(rows)),
                                                "honest": f"{sum(r['ok'] for r in rows)}/{len(rows)}",
                                                "cost_per_buyer_usd": round(statistics.mean(costs), 3), "rows": rows}

    # ─────────────────────────── Practice conversations ───────────────────────────
    def stage_practice(self, per_type: int = 1) -> None:
        from agents import practice, team as T
        from agents.common import Usage
        personas = json.loads((ROOT / "agents" / "personas.json").read_text())
        brief = {**self.brief, "sender_name": "Yago", "sender_title": "SBM Partners for Santa Fe Rústicos"}
        usage = Usage()
        p = practice.Practice(self.c, usage, T.active_playbook(self.conn), T.RUBRIC, brief)
        plan = [x for x in personas for _ in range(per_type)]
        results = []

        def one(persona):
            if self.spent() + usage.cost_usd >= self.budget:
                return None
            try:
                return p.run(persona)
            except Exception as exc:
                self.log(f"    practice failed: {exc}")
                return None

        first = one(plan[0])   # writes the prompt cache once
        results += [first] if first else []
        with ThreadPoolExecutor(max_workers=self.workers) as pool:
            results += [r for r in pool.map(one, plan[1:]) if r]
        self.record("writer", usage, "benchmark: practice conversations (writer + mock buyer + grader)")
        if not results:
            return
        by_type = {}
        for r in results:
            by_type.setdefault(r["persona"], []).append(r["score"])
            text = " ".join(t["text"] for t in r["transcript"] if t["role"] == "writer")
            r["leaks"] = leak(text)
        self.res["stages"]["practice"] = {
            "score": round(statistics.mean(r["score"] for r in results)),
            "lowest_buyer_type": min(((k, round(statistics.mean(v))) for k, v in by_type.items()), key=lambda x: x[1]),
            "by_type": {k: round(statistics.mean(v)) for k, v in by_type.items()},
            "meetings": sum(r["outcome"] == "meeting" for r in results), "replied": sum(any(t["role"] == "buyer" and t.get("action") == "reply"
                                                                                          for t in r["transcript"]) for r in results),
            "n": len(results), "leaks": sum(bool(r["leaks"]) for r in results), "rows": results}

    # ─────────────────────────── summary ───────────────────────────
    def finish(self) -> dict:
        drafts = self.res["drafts"]
        graded = [d["score"] for d in drafts if d["score"] is not None]
        if drafts:
            self.res["stages"]["writer"] = {
                "score": round(statistics.mean(graded)) if graded else None,
                "drafts": len(drafts), "rule_checks_passed": f"{sum(not d['problems'] for d in drafts)}/{len(drafts)}",
                "rewrites": sum(d["rewrites"] or 0 for d in drafts),
                "by_kind": {k: round(statistics.mean([d["score"] for d in drafts if d["kind"] == k and d["score"] is not None]))
                            for k in sorted({d["kind"] for d in drafts}) if any(d["kind"] == k and d["score"] is not None for d in drafts)},
                "lowest": min(((d["lead"] + " " + d["kind"], d["score"]) for d in drafts if d["score"] is not None),
                              key=lambda x: x[1], default=None)}
        if self.res.get("briefs"):
            b = self.res["briefs"]
            self.res["stages"]["briefer"] = {"score": round(100 * sum(x["ok"] for x in b) / len(b)),
                                             "right": f"{sum(x['ok'] for x in b)}/{len(b)}", "rows": b}
        if self.supervisor_checks:
            sc = self.supervisor_checks
            self.res["stages"]["supervisor"] = {"score": round(100 * sum(x["passed"] for x in sc) / len(sc)),
                                                "right": f"{sum(x['passed'] for x in sc)}/{len(sc)}", "rows": sc}
        self.res["cost_by_agent"] = {r["name"]: float(r["usd"]) for r in self.db.all_rows(self.conn, """
            select a.name, round(sum(r.cost_cents) / 100.0, 2) as usd from agent_runs r join agents a on a.id = r.agent_id
            group by 1 order by 2 desc""")}
        self.res["cost_usd"] = round(self.spent(), 2)
        return self.res


# ─────────────────────────── the report ───────────────────────────
LABEL = {"supervisor": "Supervisor + safety gate", "researcher": "Prospect researcher", "strategist": "Strategist",
         "writer": "Writer (real pipeline drafts)", "practice": "Writer (practice conversations)", "grader": "Grader",
         "sorter": "Reply sorter", "briefer": "Meeting briefer", "reporter": "Reporter"}
TARGET = {"supervisor": 100, "researcher": 100, "strategist": 85, "writer": 80, "practice": 80, "grader": 85, "sorter": 90,
          "briefer": 100, "reporter": 100}


def headline(k: str, s: dict) -> str:
    if k == "supervisor":
        return f"{s['right']} rule checks passed"
    if k == "researcher":
        return f"{s['honest']} made-up businesses handled honestly; ${s['cost_per_buyer_usd']:.2f} per buyer"
    if k == "strategist":
        return f"decisions {s['decisions_right']}, channels {s['channels_right']}, clean pitch {s['clean']}"
    if k == "writer":
        return f"avg Grader score over {s['drafts']} drafts; rule checks passed {s['rule_checks_passed']}"
    if k == "practice":
        return f"{s['n']} conversations; lowest buyer type {s['lowest_buyer_type'][0]} ({s['lowest_buyer_type'][1]})"
    if k == "grader":
        return f"traps caught {s['traps_caught']}, honesty traps capped {s['honesty_traps_flagged']}, good drafts passed {s['good_passed']}"
    if k in ("sorter", "briefer", "reporter"):
        return f"{s['right']} right"
    return ""


def report(res: dict) -> str:
    st = res["stages"]
    L = [f"# Agent team benchmark ({dt.date.today().isoformat()})", "",
         "Fake buyers for Santa Fe Rústicos, in a throwaway database. Nothing was sent; nothing was written to Supabase.",
         f"Cost: **${res['cost_usd']:.2f}** (" + ", ".join(f"{k} ${v:.2f}" for k, v in res["cost_by_agent"].items()) + ").", "",
         "| Agent | Score | Target | What it means |", "|---|---|---|---|"]
    for k in ["supervisor", "researcher", "strategist", "writer", "practice", "grader", "sorter", "briefer", "reporter"]:
        if k in st and st[k].get("score") is not None:
            s = st[k]
            mark = "✅" if s["score"] >= TARGET[k] else "⚠️"
            L.append(f"| {LABEL[k]} | {mark} {s['score']} | {TARGET[k]} | {headline(k, s)} |")
    L.append("")

    if "strategist" in st:
        L += ["## Strategist: decisions", "", "| Buyer | Expected | Got | Channel | Fit | Problems |", "|---|---|---|---|---|---|"]
        for r in st["strategist"]["rows"]:
            if "error" in r:
                L.append(f"| {r['lead']} | | | | | {r['error']} |")
                continue
            probs = [] if r["decision_ok"] else ["wrong decision"]
            probs += [] if r["channel_ok"] else [f"channel (expected {r['expected_channel']})"]
            probs += [f"mentions {', '.join(r['leaks'])}"] if r["leaks"] else []
            probs += [f"numbers not in sources: {', '.join(r['unsupported_numbers'])}"] if r["unsupported_numbers"] else []
            L.append(f"| {r['company']} | {r['expected']} | {r['decision']} | {r['channel']} | {r['fit']} | {'; '.join(probs) or 'ok'} |")
        L.append("")
        wrong = [r for r in st["strategist"]["rows"] if "error" not in r and not r["decision_ok"]]
        for r in wrong:
            L += [f"- **{r['company']}**: expected {r['expected']} ({r['why_expected']}). It said {r['decision']}: {r['reason']}"]
        L.append("")

    if "writer" in st:
        w = st["writer"]
        L += ["## Writer: drafts in the real pipeline", "",
              "Average Grader score by kind: " + ", ".join(f"{k} {v}" for k, v in w["by_kind"].items()) +
              f". Rewrites triggered: {w['rewrites']}.", "", "| Buyer | Kind | Score | Rule-check problems |", "|---|---|---|---|"]
        for d in res["drafts"]:
            L.append(f"| {d['lead']} | {d['kind']} ({d['channel']}) | {d['score'] if d['score'] is not None else 'not graded'} | "
                     f"{'; '.join(d['problems']) or 'none'} |")
        L.append("")

    if "practice" in st:
        p = st["practice"]
        L += ["## Writer: practice conversations (8 buyer types)", "",
              f"Average {p['score']} (round 1 on the made-up brand was 67). Mock buyers replied in {p['replied']} of {p['n']} "
              f"and agreed to a meeting or samples in {p['meetings']}.", "", "| Buyer type | Score |", "|---|---|"]
        L += [f"| {k} | {v} |" for k, v in sorted(p["by_type"].items(), key=lambda x: x[1])]
        L.append("")

    if "grader" in st:
        g = st["grader"]
        L += ["## Grader: planted drafts", "",
              f"A trap counts as caught if it scores below the rewrite line ({g['rewrite_line']:.0f}). Honesty traps should also "
              "get honesty below 5, which caps the score at 40. Good drafts should score 70 or more.", "",
              "| Draft | Flaw | Score | Honesty | Right? |", "|---|---|---|---|---|"]
        for r in g["rows"]:
            L.append(f"| {r['id']} | {r['flaw'] or '(good draft)'} | {r['score']:.0f} | {r['honesty']} | {'✅' if r['ok'] else '❌'} |")
        L.append("")

    if "sorter" in st:
        miss = [r for r in st["sorter"]["rows"] if not r["ok"]]
        L += ["## Reply sorter", "", f"{st['sorter']['right']} right."] + \
             [f"- Wrong: \"{r['text'][:90]}\" expected {'/'.join(r['expect'])}, got {r['got']}" for r in miss] + [""]

    if "briefer" in st:
        L += ["## Meeting briefer", ""] + [f"- {b['lead']}: brief made {b['made']}, qualified {b['qualified']} "
                                           f"(expected {b['expected_qualified']}){'; mentions ' + ', '.join(b['leaks']) if b['leaks'] else ''}"
                                           for b in st["briefer"]["rows"]] + [""]

    if "reporter" in st:
        L += ["## Reporter", ""]
        for r in st["reporter"]["rows"]:
            if r.get("error"):
                L.append(f"- Week of {r['week']}: failed ({r['error']})")
            else:
                L.append(f"- Week of {r['week']}: {'ok' if r['ok'] else 'PROBLEM'}. \"{r['headline']}\""
                         + (f" Numbers not in the data: {', '.join(r['unsupported_numbers'])}." if r["unsupported_numbers"] else "")
                         + ("" if r["quiet_week_explained"] else " Does not say the week was quiet."))
        L.append("")

    if "researcher" in st:
        L += ["## Prospect researcher (live web search on made-up businesses)", ""]
        for r in st["researcher"]["rows"]:
            L.append(f"- {r['company']}: {r['facts_kept']} facts kept, {r['dropped_unverified']} dropped as unverified, fit {r['fit']}, "
                     f"${r['cost_usd']:.2f}, {r['seconds']}s. {'ok' if r['ok'] else 'PROBLEM'}" + (f" ({r['error']})" if r["error"] else ""))
            for f in r["facts"]:
                L.append(f"  - kept: {f['fact']} ({f['source_url']})")
        L.append("")

    if "supervisor" in st:
        L += ["## Supervisor and safety gate", ""] + [f"- {'✅' if x['passed'] else '❌'} {x['check']}" +
                                                      ("" if x["passed"] else f" ({x['detail']})") for x in st["supervisor"]["rows"]] + [""]
    return "\n".join(L)


def drafts_md(res: dict) -> str:
    L = ["# Every draft from the benchmark", ""]
    for d in res["drafts"]:
        L += [f"## {d['lead']}: {d['kind']} ({d['channel']}), score {d['score']}", ""]
        if d["subject"]:
            L.append(f"*Subject: {d['subject']}*  ")
        L += [d["body"].replace("\n", "  \n"), "", f"**Grader:** {d['grader']}", ""]
        if d["problems"]:
            L += ["**Rule checks:** " + "; ".join(d["problems"]), ""]
    for b in res.get("briefs", []):
        if b.get("body"):
            L += [f"## Meeting brief: {b['lead']}", "", b["body"], ""]
    for r in res["stages"].get("reporter", {}).get("rows", []):
        if r.get("body"):
            L += [f"## Weekly report: {r['week']}", "", r["body"], ""]
    return "\n".join(L)


# ─────────────────────────── playbook ───────────────────────────
def load_playbook(path: Optional[str]) -> tuple[list[dict], str]:
    if path:
        return json.loads(pathlib.Path(path).read_text()), path
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise SystemExit("Pass --playbook FILE, or set DATABASE_URL so the approved playbook can be read (read-only) from Supabase.")
    import psycopg
    from psycopg.rows import dict_row
    with psycopg.connect(url, row_factory=dict_row, options="-c default_transaction_read_only=on") as c:
        rows = c.execute("select title, body, channel::text as channel, coalesce(buyer_types::text[], '{}') as buyer_types, "
                         "stage::text as stage from playbook_entries where status = 'active' order by created_at, title").fetchall()
    if not rows:
        raise SystemExit("No approved (active) playbook entries in Supabase.")
    return rows, "Supabase (read-only, status = active)"


# ─────────────────────────── main ───────────────────────────
def run(c, db_url: Optional[str], playbook: list[dict], out: pathlib.Path, only: list[str], budget: float, workers: int,
        practice_per_type: int = 1, log: Callable = print) -> dict:
    from agents import teamdb
    from .sandbox import Sandbox
    with Sandbox(db_url) as url:
        conn = teamdb.connect(url)
        b = Bench(conn, url, c, out, budget, workers, log)
        b.setup(playbook)
        steps = [("strategist", b.stage_strategist), ("writer", b.stage_writer), ("replies", b.stage_replies),
                 ("grader", b.stage_grader), ("sorter", b.stage_sorter), ("reporter", b.stage_reporter),
                 ("researcher", b.stage_researcher), ("practice", lambda: b.stage_practice(practice_per_type))]
        needs = {"writer": ["strategist"], "replies": ["strategist", "writer"]}
        for name, fn in steps:
            if only and name not in only:
                continue
            if any(n not in only for n in needs.get(name, [])) and only:
                log(f"Skipping {name}: it needs {', '.join(needs[name])} in --only too.")
                continue
            if b.over_budget():
                log(f"Budget of ${budget} reached; skipping {name} and the rest.")
                b.res.setdefault("skipped", []).append(name)
                continue
            log(f"== {name} (spent so far ${b.spent():.2f})")
            try:
                fn()
            except Exception as exc:
                traceback.print_exc()
                b.res.setdefault("errors", {})[name] = f"{type(exc).__name__}: {exc}"
        res = b.finish()
        conn.close()
    return res


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", help="a LOCAL throwaway database to use instead of starting one")
    ap.add_argument("--playbook", help="JSON list of playbook entries (default: read the active ones from Supabase, read-only)")
    ap.add_argument("--only", default="", help=f"comma-separated stages: {','.join(STAGES)}")
    ap.add_argument("--budget", type=float, default=20.0, help="stop starting new stages past this many dollars (default 20)")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--practice-per-type", type=int, default=1, help="practice conversations per buyer type (default 1, so 8)")
    ap.add_argument("--out")
    args = ap.parse_args(argv)
    for k in ("MAIL_ADDRESS", "MAIL_PASSWORD", "SMTP_HOST", "IMAP_HOST"):   # belt and braces: no mailbox in a benchmark
        os.environ.pop(k, None)
    playbook, source = load_playbook(args.playbook)
    os.environ.pop("DATABASE_URL", None)   # from here on, nothing can reach Supabase by accident
    out = pathlib.Path(args.out) if args.out else ROOT / "out" / "benchmark" / dt.datetime.now().strftime("%Y-%m-%d_%H%M")
    out.mkdir(parents=True, exist_ok=True)
    (out / "playbook_used.json").write_text(json.dumps(playbook, indent=1, ensure_ascii=False))
    print(f"Playbook: {len(playbook)} approved entries from {source}")
    from agents.common import client
    only = [s.strip() for s in args.only.split(",") if s.strip()]
    res = run(client(), args.db, playbook, out, only, args.budget, args.workers, args.practice_per_type)
    (out / "results.json").write_text(json.dumps(res, indent=1, default=str, ensure_ascii=False))
    (out / "report.md").write_text(report(res))
    (out / "drafts.md").write_text(drafts_md(res))
    print(f"\nDone. Cost about ${res['cost_usd']:.2f}.\nRead: {out / 'report.md'}")


if __name__ == "__main__":
    main()
