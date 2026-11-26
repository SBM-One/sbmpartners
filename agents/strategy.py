"""Qualification & Strategy, answers to buyers, and the meeting handoff.

  Strategist       after the Prospect researcher, scores how well the buyer fits the client (0 to 100), decides
                   pursue / nurture / disqualify, and plans the pitch: what to lead with, which proof and offer,
                   the likely objections with answers from the fact sheet, the one thing to ask for, and the channel.
                   Only "pursue" buyers get a first message. You can overrule it on the Buyers page.
  Writer (answers) when a buyer is interested or asks a question, drafts our answer; when they said "not now",
                   drafts one check-in after the snooze. Graded like every draft, and it waits for your approval.
  Meeting briefer  when a buyer is interested, writes the handoff for you: what they want, which products fit,
                   whether it is a qualified meeting and what is still unclear, the full contact history (taken
                   straight from the log, not written by the AI), next steps and an agenda.

These run as tasks from the team runner (python -m agents.team run); the Supervisor hands them out.
"""
from __future__ import annotations

import json
import re
from typing import List, Literal, Optional

from pydantic import BaseModel, Field

from . import teamdb as db
from .common import Usage

# team.py imports this module, so team's helpers are used through the module at call time.
from . import team as T


# ─────────────────────────── Strategist ───────────────────────────
FIT_WEIGHTS = {"product_fit": 30, "buyer_type_fit": 20, "price_fit": 20, "authority": 15, "timing": 15}
FIT_HELP = {
    "product_fit": "Do they carry, or have projects for, what the client makes (category, material, style)?",
    "buyer_type_fit": "Is this the kind of buyer the client sells to best (see best_fit_buyers in the fact sheet)?",
    "price_fit": "Does the client's price level and minimum order suit their store or projects?",
    "authority": "Does this person choose or influence what they buy?",
    "timing": "Any sign they are buying now: new store, expansion, new project, season, a gap in their range?",
}


class Criterion(BaseModel):
    key: Literal["product_fit", "buyer_type_fit", "price_fit", "authority", "timing"]
    score: int = Field(description="0 (clearly no) to 5 (clearly yes); 2 when the research does not say")
    why: str = Field(description="One sentence, tied to a researched fact or the fact sheet")


class Objection(BaseModel):
    objection: str = Field(description="What this buyer is likely to push back on")
    answer: str = Field(description="How to answer it, using ONLY facts in the client's fact sheet")


class Strategy(BaseModel):
    criteria: List[Criterion] = Field(description="One score for each of the five criteria")
    decision: Literal["pursue", "nurture", "disqualify"] = Field(
        description="pursue = contact now; nurture = promising but not now (timing, missing info); disqualify = not a fit")
    reason: str = Field(description="2-3 plain sentences explaining the decision")
    pitch_angle: str = Field(description="The one reason THIS buyer should care about the client, in a sentence")
    lead_with: List[str] = Field(description="1-3 collections or products from the fact sheet to open with")
    proof_points: List[str] = Field(description="1-3 facts from the fact sheet that back the pitch for this buyer")
    offer: Optional[str] = Field(None, description="The offer from the fact sheet that fits this buyer best, or null")
    objections: List[Objection] = Field(description="1-3 likely objections with answers")
    first_ask: str = Field(description="The one low-effort next step to ask for (e.g. a sample kit, a line sheet)")
    channel_plan: Literal["email", "email_and_linkedin", "linkedin", "whatsapp"] = Field(
        description="The main way in: email; email_and_linkedin (email plus a short connection note); linkedin (note only, "
                    "no email); whatsapp (only when neither email nor LinkedIn is possible). The writer plans the full "
                    "sequence of channels from this.")
    channel_reason: str = Field(description="Why this channel, in a sentence")


STRATEGIST_SYSTEM = """You are the qualification and strategy lead at SBM Partners, a sales agency that finds
wholesale buyers for furniture and home brands. Before anyone writes to a buyer, you decide whether they are
worth contacting for this client, and if so, how.

Score each criterion from 0 to 5, strictly, from the research and the fact sheet only:
{criteria}
Use 2 when the research simply does not say. Never assume facts that are not there.

Decide:
- pursue: a real fit and we have something specific to say. Contact now.
- nurture: could fit, but timing is wrong or something important is unknown. Do not contact yet.
- disqualify: not a fit (wrong category, wrong price level, wrong kind of buyer, closed, a competitor).

For a pursue, plan the pitch: the one angle that matters to THIS buyer, what to lead with, which proof
and which offer, the objections they will likely raise with honest answers, and one easy thing to ask for.
Everything you recommend saying must come from the client's fact sheet; never invent products, numbers or
customers.

Choose the channel from what is allowed (you are told which channels the campaign uses and whether the
rules allow email to this person). Prefer email when it is allowed; add a LinkedIn connection note when the
campaign uses LinkedIn and we know their profile; use LinkedIn only when email is not allowed or not possible; WhatsApp only when neither is possible
(the writer may still add a WhatsApp step to the sequence when we have their number).

<client_fact_sheet>
{brief}
</client_fact_sheet>"""

def wa_number(phone: Optional[str]) -> Optional[str]:
    """A phone number as WhatsApp wants it in a wa.me link: digits only, with the country code. None if unusable."""
    digits = re.sub(r"\D", "", phone or "")
    return digits if 10 <= len(digits) <= 15 else None


# Email blockers that are about the person or their country, not a setup step you can fix in a minute.
HARD_EMAIL = re.compile(r"No email address|invalid or bounced|needs the buyer's prior consent|is switched off|do-not-contact|asked us not", re.I)


def fit_score(s: Strategy) -> tuple[int, list[dict]]:
    got = {c.key: c for c in s.criteria}
    rows, total = [], 0.0
    for key, w in FIT_WEIGHTS.items():
        c = got.get(key)
        v = min(max(c.score, 0), 5) if c else 0
        total += w * v / 5
        rows.append({"key": key, "score": v, "weight": w, "why": c.why if c else "Not scored."})
    return round(total), rows


def reachability(conn, task: dict, p: dict) -> dict:
    camp = db.one(conn, "select channels::text[] as channels, min_fit_score from campaigns where id = %s", (task["campaign_id"],))
    channels = (camp or {}).get("channels") or ["email"]
    blockers = db.one(conn, "select contact_email_blockers(%s, %s) as b", (task["contact_id"], task["client_id"]))["b"] or []
    hard = [b for b in blockers if HARD_EMAIL.search(b)]
    return {"channels": channels, "min_fit_score": (camp or {}).get("min_fit_score") or 60,
            "email_possible": "email" in channels and not hard, "email_blockers": blockers, "email_hard_blockers": hard,
            "linkedin_possible": "linkedin" in channels and bool(p.get("linkedin_url")),
            "whatsapp_possible": "whatsapp" in channels and bool(wa_number(p.get("phone")))}


def settle(s: Strategy, score: int, reach: dict, product_fit: int) -> tuple[str, str, str]:
    """The rules the AI cannot get around: the minimum fit score, product fit, and a channel the rules allow."""
    decision, reason, plan = s.decision, s.reason, s.channel_plan
    if decision == "pursue" and (score < reach["min_fit_score"] or product_fit < 3):
        decision = "nurture"
        reason += (f" (Held back: fit {score} is below the campaign's minimum of {reach['min_fit_score']}.)"
                   if score < reach["min_fit_score"] else " (Held back: product fit is too weak to pitch.)")
    if plan in ("email", "email_and_linkedin") and not reach["email_possible"]:
        plan = "linkedin"
    if plan == "email_and_linkedin" and not reach["linkedin_possible"]:
        plan = "email"
    if plan == "linkedin" and not reach["linkedin_possible"]:
        plan = "email" if reach["email_possible"] else "whatsapp" if reach.get("whatsapp_possible") else "linkedin"
    if plan == "whatsapp" and not reach.get("whatsapp_possible"):
        plan = "email" if reach["email_possible"] else "linkedin"
    if decision == "pursue" and not (reach["email_possible"] or reach["linkedin_possible"] or reach.get("whatsapp_possible")):
        decision = "nurture"
        reason += (" (Held back: no channel the rules allow. "
                   + (" ".join(reach["email_hard_blockers"]) or "No email, LinkedIn profile or WhatsApp number on file.") + ")")
    return decision, reason, plan


def qualify_prospect(conn, c, task: dict, usages: dict) -> dict:
    """A separate scoring task (older queue entries; new research tasks score the buyer themselves)."""
    research_id = task["input"].get("research_task_id") or task["parent_id"]
    research = ((db.one(conn, "select output from tasks where id = %s", (research_id,)) or {}).get("output") or {}
                if research_id else {})
    return score_prospect(conn, c, task, research, research_id, usages.setdefault("researcher", Usage()))


def score_prospect(conn, c, task: dict, research: dict, research_id, usage: Usage) -> dict:
    """The researcher's second half: score the fit, decide pursue / nurture / disqualify, and plan the pitch."""
    cl = db.one(conn, "select brief, brief_approved_at from clients where id = %s", (task["client_id"],))
    if not cl["brief"] or cl["brief_approved_at"] is None:
        raise RuntimeError("The client has no approved fact sheet (approve it on the Clients page).")
    p = T.contact_row(conn, task["contact_id"])
    reach = reachability(conn, task, p)
    brief_txt = json.dumps({k: v for k, v in cl["brief"].items() if not k.startswith("_")}, indent=1)
    system = [{"type": "text", "cache_control": {"type": "ephemeral"},
               "text": STRATEGIST_SYSTEM.format(brief=brief_txt,
                                                criteria="\n".join(f"- {k}: {v}" for k, v in FIT_HELP.items()))}]
    facts = "\n".join(f"- {f['fact']} ({f['source_url']})" for f in research.get("facts", [])) or "- (no verified facts)"
    company = ", ".join(f"{k.replace('_', ' ')}: {v}" for k, v in
                        [("categories", ", ".join(p.get("categories") or [])), ("style", ", ".join(p.get("style_tags") or [])),
                         ("price tier", p.get("price_tier")), ("stores", p.get("store_count"))] if v)
    content = (f"Buyer: {T.who(p)}\nDecision maker on file: {p.get('is_decision_maker')}\n"
               f"Company data: {company or '(none)'}\n\n"
               f"Research summary: {research.get('summary', '(no research)')}\n{facts}\n"
               f"Researcher's angle: {research.get('angle', '')}\nResearcher's cautions: {research.get('cautions', '')}\n\n"
               f"Campaign channels: {', '.join(reach['channels'])}\n"
               f"Email to this person allowed by the rules: {'yes' if reach['email_possible'] else 'no'}"
               f"{' (' + ' '.join(reach['email_hard_blockers']) + ')' if reach['email_hard_blockers'] else ''}\n"
               f"LinkedIn profile on file: {'yes' if p.get('linkedin_url') else 'no'}\n"
               f"WhatsApp number on file (and the campaign uses WhatsApp): {'yes' if reach['whatsapp_possible'] else 'no'}\n"
               f"Minimum fit score for this campaign: {reach['min_fit_score']} of 100")
    s = T.parse(c, usage, T.model("researcher"), system, content, Strategy, "medium")
    score, breakdown = fit_score(s)
    product_fit = next(r["score"] for r in breakdown if r["key"] == "product_fit")
    decision, reason, plan = settle(s, score, reach, product_fit)

    row = db.one(conn, """
        insert into prospect_strategies (client_id, campaign_id, contact_id, company_id, task_id, research_task_id, fit_score,
                                         fit_breakdown, decision, reason, pitch_angle, lead_with, proof_points, offer, objections,
                                         first_ask, channel_plan, channel_reason)
        values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        on conflict (campaign_id, contact_id) do update set
          task_id = excluded.task_id, research_task_id = excluded.research_task_id, fit_score = excluded.fit_score,
          fit_breakdown = excluded.fit_breakdown, decision = excluded.decision, reason = excluded.reason,
          pitch_angle = excluded.pitch_angle, lead_with = excluded.lead_with, proof_points = excluded.proof_points,
          offer = excluded.offer, objections = excluded.objections, first_ask = excluded.first_ask,
          channel_plan = excluded.channel_plan, channel_reason = excluded.channel_reason, decided_at = now()
        where prospect_strategies.decided_by = 'strategist'     -- never overwrite your own decision
        returning id, decision""",
                 (task["client_id"], task["campaign_id"], task["contact_id"], task["company_id"], task["id"], research_id,
                  score, db.jsonb(breakdown), decision, reason, s.pitch_angle, db.jsonb(s.lead_with), db.jsonb(s.proof_points),
                  s.offer, db.jsonb([o.model_dump() for o in s.objections]), s.first_ask, plan, s.channel_reason))
    if row is None:   # you had already decided for this buyer
        row = db.one(conn, "select id, decision from prospect_strategies where campaign_id = %s and contact_id = %s",
                     (task["campaign_id"], task["contact_id"]))
    db.all_rows(conn, "update campaign_targets set fit_score = %s, updated_at = now() where campaign_id = %s and contact_id = %s",
                (score / 100, task["campaign_id"], task["contact_id"]))
    return {"strategy_id": str(row["id"]), "fit_score": score, "decision": row["decision"], "channel_plan": plan}


def strategy_for(conn, campaign_id, contact_id) -> Optional[dict]:
    if not campaign_id:
        return None
    return db.one(conn, "select * from prospect_strategies where campaign_id = %s and contact_id = %s", (campaign_id, contact_id))


def strategy_text(s: Optional[dict]) -> str:
    """The plan, for the Writer and the Grader."""
    if not s:
        return ""
    objections = "\n".join(f"  - {o['objection']} -> {o['answer']}" for o in s.get("objections") or [])
    return ("\n\nStrategy for this buyer (follow it):\n"
            f"- Fit: {s['fit_score']} of 100. {s['reason']}\n"
            f"- Angle: {s.get('pitch_angle') or ''}\n"
            f"- Lead with: {', '.join(s.get('lead_with') or []) or '(your choice)'}\n"
            f"- Proof: {'; '.join(s.get('proof_points') or []) or '(your choice)'}\n"
            f"- Offer: {s.get('offer') or '(none)'}\n"
            f"- Ask for: {s.get('first_ask') or ''}\n"
            + (f"- Likely objections:\n{objections}\n" if objections else ""))


# ─────────────────────────── the conversation so far ───────────────────────────
def _clean(body: Optional[str]) -> str:
    return re.split(r"\n\n--\n", body or "", maxsplit=1)[0].strip()   # our footer is added by the Mailer


def history(conn, client_id, contact_id) -> list[dict]:
    """Every message and meeting with this buyer for this client, oldest first. Taken straight from the log."""
    rows = db.all_rows(conn, """
        select i.occurred_at, i.channel::text as channel, i.direction::text as direction, i.kind::text as kind,
               i.actor::text as actor, i.subject, i.body, i.metadata
        from interactions i
        where i.client_id = %s and i.contact_id = %s and i.kind <> 'opened' and i.kind <> 'clicked'
        order by i.occurred_at""", (client_id, contact_id))
    out = []
    for r in rows:
        meta = r["metadata"] or {}
        out.append({"at": r["occurred_at"].isoformat(timespec="minutes"), "channel": r["channel"], "direction": r["direction"],
                    "kind": r["kind"], "from": "buyer" if r["direction"] == "inbound" else ("us" if r["actor"] != "system" else "system"),
                    "subject": r["subject"], "text": _clean(r["body"])[:1500],
                    **({"category": meta["category"]} if meta.get("category") else {}),
                    **({"summary": meta["summary"]} if meta.get("summary") else {})})
    return out


def history_text(h: list[dict]) -> str:
    lines = []
    for m in h:
        who = "Buyer" if m["from"] == "buyer" else "You"
        what = m["kind"].replace("_", " ")
        head = f"[{who}, {m['at'][:10]}, {m['channel']}{'' if m['kind'] in ('sent', 'reply') else ', ' + what}]"
        lines.append(f"{head} " + (f"Subject: {m['subject']}\n" if m.get("subject") else "") + (m["text"] or m.get("summary") or ""))
    return "\n\n".join(lines) or "(no messages yet)"


# ─────────────────────────── Writer: answers and check-ins ───────────────────────────
REPLY_ASK = """The buyer replied ({category}): {summary}
Write our answer to their latest message, as a reply in the same thread.
- Answer every question they asked, using ONLY facts in the client brief. Where the brief does not have the
  answer, say plainly that you will confirm it and by when; never guess prices, dates or stock.
- If they are interested, make the next step a short call or meeting with {sender}: ask which day this week
  or next suits them. Do not invent available times.
- Do not repeat the pitch they already read. Short, warm and specific to what they wrote."""

CHECK_IN_ASK = """On {date} the buyer said "not now": {summary}
Their snooze has ended. Write ONE short check-in, as a reply in the same thread: remind them in a few words
who you are, add one new useful thing from the brief (a new collection, an offer, a fact that answers why
they said not now) and ask one easy question. No pressure, no fake urgency, no "just checking in"."""


def draft_reply(conn, c, task: dict, usages: dict) -> dict:
    w_usage = usages.setdefault("writer", Usage())
    g_usage = usages.setdefault("reviewer", Usage())
    purpose = task["input"].get("purpose") or "reply"
    rep = db.one(conn, "select * from interactions where id = %s", (task["input"].get("reply_interaction_id"),))
    if not rep:
        raise RuntimeError("The buyer's reply is missing.")
    newer = db.one(conn, """select 1 from interactions where client_id = %s and contact_id = %s and direction = 'inbound'
                            and kind = 'reply' and occurred_at > %s""", (task["client_id"], task["contact_id"], rep["occurred_at"]))
    if newer:   # they wrote again: the Supervisor drafts an answer to the newer message instead
        return {"skipped": "the buyer wrote again since"}
    w_sys, g_sys, brief = T.writer_setup(conn, task["client_id"])
    p = T.contact_row(conn, task["contact_id"])
    strat = strategy_for(conn, task["campaign_id"], task["contact_id"])
    research_id = (strat or {}).get("research_task_id") or db.one(conn, """
        select id from tasks where kind = 'research_prospect' and status = 'done' and campaign_id = %s and contact_id = %s
        order by finished_at desc limit 1""", (task["campaign_id"], task["contact_id"]))
    if isinstance(research_id, dict):
        research_id = research_id["id"]
    research = ((db.one(conn, "select output from tasks where id = %s", (research_id,)) or {}).get("output") or {}
                if research_id else {})

    if rep["channel"] == "whatsapp" and wa_number(p.get("phone")):   # they wrote on WhatsApp: answer there (sent by hand)
        channel = "whatsapp"
    else:
        channel = rep["channel"] if rep["channel"] in ("email", "linkedin") else ("email" if p.get("email") else "linkedin")
    if channel == "email" and not p.get("email"):
        channel = "linkedin"
    if channel == "linkedin" and not p.get("linkedin_url") and p.get("email"):
        channel = "email"
    threaded = channel == "email" and rep["channel"] == "email" and bool(rep["external_id"])

    meta = rep["metadata"] or {}
    convo = history_text(history(conn, task["client_id"], task["contact_id"]))
    if purpose == "check_in":
        ask = CHECK_IN_ASK.format(date=f"{rep['occurred_at']:%d %b}", summary=meta.get("summary") or "")
    else:
        ask = REPLY_ASK.format(category=(meta.get("category") or "other").replace("_", " "), summary=meta.get("summary") or "",
                               sender=brief.get("sender_name") or "our team")
    ask += ("\nLeave subject empty: it goes out as a reply." if threaded else
            "\nWrite a short subject line." if channel == "email" else
            "\nLeave subject empty (WhatsApp message, at most 600 characters, no link)." if channel == "whatsapp" else
            "\nLeave subject empty (LinkedIn message).")
    if channel == "email":
        ask += T.FOOTER_NOTE
    facts = "\n".join(f"- {f['fact']} ({f['source_url']})" for f in research.get("facts", [])) or "- (no verified facts)"
    about = f"Buyer: {T.who(p)}\nWhat research found: {research.get('summary', '(no research)')}\n{facts}" + strategy_text(strat)
    min_score = db.agent(conn, "writer")["min_score"]

    def write(extra: str = ""):
        return T.parse(c, w_usage, T.model("writer"), w_sys, f"{about}\n\nConversation so far:\n{convo}\n\n{ask}{extra}",
                       T.WriterTurn, "medium")

    def grade(w):
        stage = ("The buyer said not now earlier; this is the one check-in after the wait (score 'handling' on how it "
                 "addresses their reason)" if purpose == "check_in" else
                 "The buyer replied; this is our answer (score 'handling' on how well it answers what they wrote)")
        g = T.parse(c, g_usage, T.model("reviewer"), g_sys,
                    f"{about}\nChannel: {channel}. {stage}. The sender's address and unsubscribe link are added "
                    f"automatically.\n\nConversation so far:\n{convo}\n\nWRITER:\n"
                    f"{f'[Subject: {w.subject}]' + chr(10) if w.subject and not threaded else ''}{w.message}", T.Grade, "medium")
        return g, T.score(g, T.RUBRIC)

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

    step = (db.one(conn, "select coalesce(max(step), 0) as s from outreach_drafts where contact_id = %s and campaign_id "
                         "is not distinct from %s and status = 'sent'", (task["contact_id"], task["campaign_id"]))["s"] or 0) + 1
    playbook = T.active_playbook(conn)
    used = [playbook[i - 1]["title"] for i in best.playbook_used if 0 < i <= len(playbook)]
    row = db.one(conn, """
        insert into outreach_drafts (client_id, campaign_id, contact_id, company_id, task_id, writer_agent_id, channel, step, purpose,
                                     reply_to_interaction_id, strategy_id, subject, body, playbook_used, research, score,
                                     grade_feedback, rewrites)
        values (%s, %s, %s, %s, %s, %s, %s::channel, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) returning id""",
                 (task["client_id"], task["campaign_id"], task["contact_id"], task["company_id"] or p.get("company_id"), task["id"],
                  db.agent(conn, "writer")["id"], channel, step, purpose, rep["id"], (strat or {}).get("id"),
                  None if (threaded or channel != "email") else best.subject, best.message, db.jsonb(used), db.jsonb(research),
                  best_s, f"{best_g.feedback}\nTop fix: {best_g.top_fix}", rewrites))
    return {"draft_id": str(row["id"]), "purpose": purpose, "channel": channel, "score": best_s, "rewrites": rewrites}


# ─────────────────────────── Meeting briefer ───────────────────────────
class Check(BaseModel):
    key: Literal["interest", "product_fit", "authority", "timing", "terms"]
    status: Literal["yes", "unclear", "no"]
    evidence: str = Field(description="What in the conversation or research shows it; quote the buyer where you can")


class Handoff(BaseModel):
    headline: str = Field(description="One sentence: who they are and what they want")
    qualified: bool = Field(description="True only if interest and product fit are both clearly yes and nothing is a clear no")
    checks: List[Check] = Field(description="One for each: interest, product_fit, authority, timing, terms")
    interest: str = Field(description="What the buyer wants, in plain words, from what they actually wrote")
    product_fit: str = Field(description="Which of the client's collections or products fit them, and why, from the fact sheet")
    open_questions: List[str] = Field(description="What we still need to learn in the meeting")
    next_steps: List[str] = Field(description="2-4 concrete next steps for the person taking the meeting, first one first")
    agenda: List[str] = Field(description="3-5 points for a 20-minute first meeting")


BRIEFER_SYSTEM = """You prepare the handoff when a wholesale buyer shows interest, so the person taking the
meeting walks in ready. Be strict and honest: the meeting is "qualified" only if the buyer clearly showed
interest AND the client's products clearly fit them. Authority, timing and terms (minimums, lead times,
prices) can be unclear, but say so. Use only what the conversation, the research and the fact sheet say;
never invent. Quote the buyer's own words as evidence where you can.

<client_fact_sheet>
{brief}
</client_fact_sheet>"""

CHECK_LABEL = {"interest": "Interest", "product_fit": "Product fit", "authority": "Decision maker", "timing": "Timing",
               "terms": "Terms (price, minimums, lead times)"}


def prepare_handoff(conn, c, task: dict, usages: dict) -> dict:
    usage = usages.setdefault("writer", Usage())
    if db.one(conn, "select 1 from meeting_handoffs where client_id = %s and contact_id = %s and status in ('ready','booked')",
              (task["client_id"], task["contact_id"])):
        return {"skipped": "a meeting brief for this buyer is already open"}
    cl = db.one(conn, "select name, brief from clients where id = %s", (task["client_id"],))
    p = T.contact_row(conn, task["contact_id"])
    strat = strategy_for(conn, task["campaign_id"], task["contact_id"])
    research = {}
    rid = (strat or {}).get("research_task_id")
    if rid:
        research = (db.one(conn, "select output from tasks where id = %s", (rid,)) or {}).get("output") or {}
    hist = history(conn, task["client_id"], task["contact_id"])
    brief_txt = json.dumps({k: v for k, v in (cl["brief"] or {}).items() if not k.startswith("_")}, indent=1)
    facts = "\n".join(f"- {f['fact']} ({f['source_url']})" for f in research.get("facts", [])) or "- (no verified facts)"
    content = (f"Buyer: {T.who(p)}\nResearch: {research.get('summary', '(none)')}\n{facts}{strategy_text(strat)}\n\n"
               f"Conversation, oldest first:\n{history_text(hist)}")
    system = [{"type": "text", "cache_control": {"type": "ephemeral"}, "text": BRIEFER_SYSTEM.format(brief=brief_txt)}]
    h = T.parse(c, usage, T.model("writer"), system, content, Handoff, "medium")

    checks = {k.key: k for k in h.checks}
    qualified = bool(h.qualified and all(checks.get(k) and checks[k].status == "yes" for k in ("interest", "product_fit"))
                     and not any(k.status == "no" for k in h.checks))
    name = " ".join(x for x in [p.get("first_name"), p.get("last_name")] if x) or "The buyer"
    lines = [f"# {name}, {p.get('company') or 'unknown company'}", "", f"**{h.headline}**", "",
             ("Qualified meeting." if qualified else "Not yet a qualified meeting: see the checks below."), "",
             "## What they want", h.interest, "", "## Product fit", h.product_fit, "", "## Checks",
             *[f"- {CHECK_LABEL[k]}: {checks[k].status if k in checks else 'unclear'}. {checks[k].evidence if k in checks else ''}"
               for k in CHECK_LABEL], ""]
    if strat:
        lines += ["## Why we contacted them", f"Fit {strat['fit_score']} of 100. {strat.get('pitch_angle') or ''}", ""]
    lines += ["## Still to find out", *[f"- {q}" for q in h.open_questions], "", "## Next steps",
              *[f"{i}. {s}" for i, s in enumerate(h.next_steps, 1)], "", "## Agenda (20 minutes)", *[f"- {a}" for a in h.agenda],
              "", "## Contact history"]
    for m in hist:
        who = "Buyer" if m["from"] == "buyer" else "Us"
        lines.append(f"- {m['at'][:10]} · {m['channel']} · {who}: "
                     + (m.get("summary") or (m["subject"] or "") or m["text"][:140]).replace("\n", " "))
    contact = [x for x in [p.get("email"), p.get("phone"), p.get("linkedin_url")] if x]
    if contact:
        lines += ["", "## Contact", *[f"- {x}" for x in contact]]

    row = db.one(conn, """
        insert into meeting_handoffs (client_id, campaign_id, contact_id, company_id, task_id, reply_interaction_id, strategy_id,
                                      qualified, checks, interest, product_fit, contact_history, open_questions, next_steps, agenda, body)
        values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        on conflict do nothing returning id""",
                 (task["client_id"], task["campaign_id"], task["contact_id"], task["company_id"] or p.get("company_id"), task["id"],
                  task["input"].get("reply_interaction_id"), (strat or {}).get("id"), qualified,
                  db.jsonb([k.model_dump() for k in h.checks]), h.interest, h.product_fit, db.jsonb(hist),
                  db.jsonb(h.open_questions), db.jsonb(h.next_steps), db.jsonb(h.agenda), "\n".join(lines)))
    if not row:
        return {"skipped": "a meeting brief for this buyer is already open"}
    db.alert(conn, "meeting_ready",
             f"{'Qualified meeting' if qualified else 'Possible meeting'} for {cl['name']}: {name} at "
             f"{p.get('company') or 'unknown company'}. {h.headline} The brief is on the Meetings page.",
             severity="urgent" if qualified else "warning", client_id=task["client_id"],
             refs={"handoff_id": str(row["id"]), "contact_id": str(task["contact_id"])}, dedupe_key=f"meeting:{row['id']}")
    return {"handoff_id": str(row["id"]), "qualified": qualified}
