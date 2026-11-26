"""The Supervisor: keeps the team moving, safe and within budget. It follows fixed rules, so it costs nothing to run.

Each round (a "tick") it:
  1. puts stuck tasks back in the queue,
  2. pauses any agent that reached its monthly budget (and un-pauses it when a new month starts),
  3. hands out work for live campaigns: research each new buyer, then qualification & strategy for each
     researched buyer, then a first draft for each buyer the Strategist (or you) marked "pursue", paced by
     each client's daily draft limit; a follow-up draft when a sent email got no answer after the campaign's
     followup_days (up to its max_steps);
  4. follows each conversation: an answer draft when a buyer is interested or asks a question, a meeting
     brief when they are interested, and one check-in when a "not now" snooze ends,
  5. asks the Reporter for last week's report for each active client,
  6. raises alerts for you: failed tasks, a missing brand fact sheet, drafts waiting over a day for
     approval, an agent whose scores are slipping, and a booked meeting whose outcome you have not recorded.

Run one round by hand:  python -m agents.supervisor
(The team runner, python -m agents.team run, does this automatically every few minutes.)
"""
from __future__ import annotations

import datetime as dt

from . import teamdb as db


def tick(conn, today: dt.date | None = None) -> dict:
    today = today or dt.date.today()
    done: dict = {}
    done["stuck_tasks_requeued"] = db.one(conn, "select release_stale_tasks(30) as n")["n"]
    done.update(_budgets(conn))
    done.update(_campaign_work(conn))
    done["follow_ups_added"] = _follow_ups(conn)
    done.update(_conversations(conn))
    done["reports_requested"] = _weekly_reports(conn, today)
    done["alerts"] = _watch(conn, today)
    return done


# ─────────────────────────── budgets ───────────────────────────
def _budgets(conn) -> dict:
    paused, resumed = [], []
    for a in db.all_rows(conn, "select * from v_agent_spend_month where budget_usd > 0"):
        over = a["spent_usd"] >= a["budget_usd"]
        if over and a["active"]:
            db.all_rows(conn, "update agents set active = false, paused_reason = %s where id = %s",
                        (f"budget: spent ${a['spent_usd']} of ${a['budget_usd']} this month", a["agent_id"]))
            db.alert(conn, "budget_cap", f"{a['name']} reached its monthly budget (${a['budget_usd']}) and is paused. "
                     "Raise monthly_budget_cents in the agents table to resume it this month.",
                     severity="urgent", refs={"agent": a["name"]}, dedupe_key=f"cap:{a['name']}:{dt.date.today():%Y-%m}")
            paused.append(a["name"])
        elif not over and not a["active"] and (a["paused_reason"] or "").startswith("budget"):
            db.all_rows(conn, "update agents set active = true, paused_reason = null where id = %s", (a["agent_id"],))
            db.all_rows(conn, "update alerts set status = 'resolved' where kind = 'budget_cap' and status <> 'resolved' "
                              "and refs->>'agent' = %s", (a["name"],))
            resumed.append(a["name"])
        elif not over and a["pct_used"] is not None and a["pct_used"] >= 80:
            db.alert(conn, "budget_warning", f"{a['name']} has used {a['pct_used']}% of its ${a['budget_usd']} monthly budget.",
                     refs={"agent": a["name"]}, dedupe_key=f"warn:{a['name']}:{dt.date.today():%Y-%m}")
    return {"agents_paused": paused, "agents_resumed": resumed}


# ─────────────────────────── campaign work ───────────────────────────
def _campaign_work(conn) -> dict:
    researched = qualified = drafted = 0
    for c in db.all_rows(conn, """
            select cl.id as client_id, cl.name, cl.brief, cl.daily_draft_limit, cl.brief_approved_at,
                   cl.brief_draft is not null as has_brief_draft, array_agg(ca.id) as campaign_ids
            from clients cl join campaigns ca on ca.client_id = cl.id
            where ca.status = 'live' and cl.status = 'active'
            group by cl.id"""):
        if not c["brief"] or c["brief_approved_at"] is None:
            msg = (f"{c['name']}'s fact sheet is drafted and waiting for your approval (Clients page). No drafts are "
                   "written until you approve it." if c["has_brief_draft"] else
                   f"{c['name']} has a live campaign but no approved fact sheet, so no drafts are written. "
                   "Draft one from their catalog: python -m agents.onboard --client \"" + c["name"] + "\" --file catalog.pdf")
            db.alert(conn, "client_brief_missing", msg, severity="urgent", client_id=c["client_id"],
                     dedupe_key=f"brief:{c['client_id']}")
            continue

        # Step 2: every researched buyer is qualified (already counted against the daily limit).
        for t in db.all_rows(conn, """
                select r.id, r.client_id, r.campaign_id, r.contact_id, r.company_id
                from tasks r
                join contacts co on co.id = r.contact_id
                where r.kind = 'research_prospect' and r.status = 'done' and r.client_id = %s and not co.do_not_contact
                  and not exists (select 1 from tasks q where q.kind in ('qualify_prospect','draft_outreach')
                                  and q.campaign_id = r.campaign_id and q.contact_id = r.contact_id)
                  and not exists (select 1 from prospect_strategies s
                                  where s.campaign_id = r.campaign_id and s.contact_id = r.contact_id)""",
                             (c["client_id"],)):
            if db.enqueue(conn, "qualify_prospect", client_id=t["client_id"], campaign_id=t["campaign_id"],
                          contact_id=t["contact_id"], company_id=t["company_id"], parent_id=t["id"],
                          input={"research_task_id": str(t["id"])}, priority=45):
                qualified += 1

        # Step 3: every buyer marked "pursue" (by the Strategist or by you) gets a first draft.
        for t in db.all_rows(conn, """
                select s.id, s.client_id, s.campaign_id, s.contact_id, s.company_id, s.research_task_id, s.task_id
                from prospect_strategies s
                join contacts co on co.id = s.contact_id
                where s.decision = 'pursue' and s.client_id = %s and s.campaign_id = any(%s) and not co.do_not_contact
                  and not exists (select 1 from tasks d where d.kind = 'draft_outreach'
                                  and d.campaign_id = s.campaign_id and d.contact_id = s.contact_id)
                  and not exists (select 1 from outreach_drafts o where o.campaign_id = s.campaign_id
                                  and o.contact_id = s.contact_id and o.step = 1)""",
                             (c["client_id"], c["campaign_ids"])):
            if db.enqueue(conn, "draft_outreach", client_id=t["client_id"], campaign_id=t["campaign_id"],
                          contact_id=t["contact_id"], company_id=t["company_id"], parent_id=t["task_id"],
                          input={"research_task_id": str(t["research_task_id"]) if t["research_task_id"] else None,
                                 "strategy_id": str(t["id"])}, priority=50):
                drafted += 1

        # Step 1: research new buyers, up to today's limit. Today's drafts and all work in progress count.
        used = db.one(conn, """
            select (select count(*) from outreach_drafts where client_id = %(c)s and created_at::date = current_date)
                 + (select count(*) from tasks where client_id = %(c)s and status in ('queued','running')
                    and kind in ('research_prospect','qualify_prospect','draft_outreach')) as n""", {"c": c["client_id"]})["n"]
        room = max(0, c["daily_draft_limit"] - used)
        if room == 0:
            continue
        for t in db.all_rows(conn, """
                select ct.campaign_id, ct.contact_id, coalesce(ct.company_id, co.company_id) as company_id
                from campaign_targets ct
                join contacts co on co.id = ct.contact_id
                where ct.campaign_id = any(%s) and ct.status = 'queued' and not co.do_not_contact
                  and not exists (select 1 from tasks t where t.kind = 'research_prospect'
                                  and t.campaign_id = ct.campaign_id and t.contact_id = ct.contact_id)
                order by ct.fit_score desc nulls last, ct.updated_at
                limit %s""", (c["campaign_ids"], room)):
            if db.enqueue(conn, "research_prospect", client_id=c["client_id"], campaign_id=t["campaign_id"],
                          contact_id=t["contact_id"], company_id=t["company_id"]):
                researched += 1
    return {"research_tasks_added": researched, "qualify_tasks_added": qualified, "draft_tasks_added": drafted}


# ─────────────────────────── follow-ups ───────────────────────────
def _follow_ups(conn) -> int:
    """A sent email with no reply after the campaign's followup_days gets one follow-up draft, up to max_steps.
    The follow-up still waits for your approval, and the safety gate checks again that nobody replied."""
    n = 0
    for f in db.all_rows(conn, """
            select d.client_id, d.campaign_id, d.contact_id, d.company_id, d.step, d.id as previous_draft_id,
                   (select t.id from tasks t where t.kind = 'research_prospect' and t.campaign_id = d.campaign_id
                     and t.contact_id = d.contact_id and t.status = 'done' order by t.finished_at desc limit 1) as research_id
            from outreach_drafts d
            join campaigns ca on ca.id = d.campaign_id
            join clients cl on cl.id = d.client_id
            join contacts c on c.id = d.contact_id
            where d.channel = 'email' and d.status = 'sent' and ca.status = 'live' and cl.status = 'active'
              and d.purpose in ('first','follow_up')
              and d.step < ca.max_steps and d.sent_at < now() - make_interval(days => ca.followup_days)
              and not c.do_not_contact
              and not exists (select 1 from meeting_handoffs h where h.client_id = d.client_id and h.contact_id = d.contact_id)
              and not exists (select 1 from interactions i where i.contact_id = d.contact_id and i.client_id = d.client_id
                              and i.direction = 'inbound' and i.kind in ('reply','unsubscribe','bounce'))
              and not exists (select 1 from outreach_drafts n where n.contact_id = d.contact_id and n.campaign_id = d.campaign_id
                              and n.channel = 'email' and n.step > d.step)
              and not exists (select 1 from tasks t where t.kind = 'draft_outreach' and t.campaign_id = d.campaign_id
                              and t.contact_id = d.contact_id and t.status in ('queued','running'))"""):
        if db.enqueue(conn, "draft_outreach", client_id=f["client_id"], campaign_id=f["campaign_id"],
                      contact_id=f["contact_id"], company_id=f["company_id"], priority=40,
                      input={"step": f["step"] + 1, "previous_draft_id": str(f["previous_draft_id"]),
                             "research_task_id": str(f["research_id"]) if f["research_id"] else None}):
            n += 1
    return n


# ─────────────────────────── conversations ───────────────────────────
REPLY_WINDOW_DAYS = 14   # older replies are not answered automatically (you have probably answered them yourself)


def _conversations(conn) -> dict:
    """Each buyer's latest reply decides the next step. Everything drafted here still waits for your approval."""
    answers = briefs = check_ins = 0
    for r in db.all_rows(conn, """
            select distinct on (i.client_id, i.contact_id)
                   i.id, i.client_id, i.campaign_id, i.contact_id, coalesce(i.company_id, c.company_id) as company_id,
                   i.occurred_at, i.metadata->>'category' as category
            from interactions i
            join contacts c on c.id = i.contact_id
            join clients cl on cl.id = i.client_id
            left join campaigns ca on ca.id = i.campaign_id
            where i.direction = 'inbound' and i.kind = 'reply' and not c.do_not_contact and cl.status = 'active'
              and (ca.id is null or ca.status = 'live')
            order by i.client_id, i.contact_id, i.occurred_at desc"""):
        cat = r["category"] or "other"
        recent = db.one(conn, "select %s > now() - make_interval(days => %s) as ok", (r["occurred_at"], REPLY_WINDOW_DAYS))["ok"]
        open_handoff = db.one(conn, "select 1 from meeting_handoffs where client_id = %s and contact_id = %s",
                              (r["client_id"], r["contact_id"]))
        # An answer to an interested buyer or a question, once per reply.
        if cat in ("interested", "question") and recent and r["campaign_id"] and not db.one(conn, """
                select 1 from outreach_drafts where reply_to_interaction_id = %(id)s
                union all select 1 from tasks where kind = 'draft_reply' and input->>'reply_interaction_id' = %(sid)s""",
                {"id": r["id"], "sid": str(r["id"])}):
            if db.enqueue(conn, "draft_reply", client_id=r["client_id"], campaign_id=r["campaign_id"], contact_id=r["contact_id"],
                          company_id=r["company_id"], priority=20,
                          input={"purpose": "reply", "reply_interaction_id": str(r["id"])}):
                answers += 1
        # An interested buyer becomes a meeting brief for you, once.
        if cat == "interested" and not open_handoff and not db.one(conn, """
                select 1 from tasks where kind = 'prepare_handoff' and client_id = %s and contact_id = %s
                and status in ('queued','running','done')""", (r["client_id"], r["contact_id"])):
            if db.enqueue(conn, "prepare_handoff", client_id=r["client_id"], campaign_id=r["campaign_id"],
                          contact_id=r["contact_id"], company_id=r["company_id"], priority=10,
                          input={"reply_interaction_id": str(r["id"])}):
                briefs += 1
        # "Not now": one check-in once the snooze ends.
        if cat == "not_now" and r["campaign_id"] and not open_handoff and db.one(conn, """
                select 1 from campaign_targets where campaign_id = %s and contact_id = %s
                and snoozed_until is not null and snoozed_until <= now()""", (r["campaign_id"], r["contact_id"])) \
                and not db.one(conn, """select 1 from outreach_drafts where campaign_id = %s and contact_id = %s and purpose = 'check_in'
                                        union all select 1 from tasks where kind = 'draft_reply' and campaign_id = %s
                                        and contact_id = %s and input->>'purpose' = 'check_in'""",
                               (r["campaign_id"], r["contact_id"], r["campaign_id"], r["contact_id"])):
            if db.enqueue(conn, "draft_reply", client_id=r["client_id"], campaign_id=r["campaign_id"], contact_id=r["contact_id"],
                          company_id=r["company_id"], priority=60,
                          input={"purpose": "check_in", "reply_interaction_id": str(r["id"])}):
                check_ins += 1
    return {"answers_added": answers, "meeting_briefs_added": briefs, "check_ins_added": check_ins}


# ─────────────────────────── weekly reports ───────────────────────────
def _weekly_reports(conn, today: dt.date) -> int:
    start = today - dt.timedelta(days=today.weekday() + 7)    # last week's Monday
    end = start + dt.timedelta(days=6)
    n = 0
    for c in db.all_rows(conn, """
            select cl.id from clients cl
            where cl.status = 'active' and exists (select 1 from campaigns ca where ca.client_id = cl.id and ca.status in ('live','done'))
              and not exists (select 1 from reports r where r.client_id = cl.id and r.kind = 'weekly' and r.period_start = %s)
              and not exists (select 1 from tasks t where t.kind = 'write_report' and t.client_id = cl.id
                              and t.input->>'period_start' = %s and t.status <> 'cancelled')""",
                         (start, start.isoformat())):
        if db.enqueue(conn, "write_report", client_id=c["id"], priority=80,
                      input={"kind": "weekly", "period_start": start.isoformat(), "period_end": end.isoformat()}):
            n += 1
    return n


# ─────────────────────────── watching ───────────────────────────
def _watch(conn, today: dt.date) -> int:
    raised = 0
    for f in db.all_rows(conn, """
            select kind, count(*) as n, (array_agg(error order by finished_at desc))[1] as last_error
            from tasks where status = 'failed' and finished_at > now() - interval '1 day' group by kind"""):
        raised += db.alert(conn, "task_failed",
                           f"{f['n']} {f['kind'].replace('_', ' ')} task(s) failed in the last day. Latest error: {f['last_error']}",
                           refs={"task_kind": f["kind"]}, dedupe_key=f"failed:{f['kind']}:{today}")

    waiting = db.one(conn, "select count(*) as n from outreach_drafts where status = 'pending_review' "
                           "and created_at < now() - interval '1 day'")["n"]
    if waiting:
        raised += db.alert(conn, "approval_waiting",
                           f"{waiting} draft(s) have waited more than a day for your approval (Approvals page).",
                           severity="info", dedupe_key=f"queue:{today}")

    stuck = db.all_rows(conn, """select d.id, c.email from outreach_drafts d join contacts c on c.id = d.contact_id
                               where d.status = 'approved' and d.send_claimed_at < now() - interval '30 minutes'""")
    for d in stuck:
        raised += db.alert(conn, "send_unconfirmed",
                           f"An email to {d['email']} was handed to the mailbox but never confirmed as sent. Check the "
                           "mailbox's Sent folder before doing anything: it is not retried, so nobody gets it twice.",
                           severity="urgent", refs={"draft_id": str(d["id"])}, dedupe_key=f"stuck:{d['id']}")

    for m in db.all_rows(conn, """
            select h.id, h.meeting_at, trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')) as name,
                   co.name as company, h.client_id
            from meeting_handoffs h join contacts c on c.id = h.contact_id left join companies co on co.id = h.company_id
            where h.status = 'booked' and h.meeting_at < now() - interval '1 day'"""):
        raised += db.alert(conn, "meeting_outcome",
                           f"The meeting with {m['name'] or 'a buyer'}{', ' + m['company'] if m['company'] else ''} was on "
                           f"{m['meeting_at']:%b %d}. Record how it went on the Meetings page.",
                           severity="info", client_id=m["client_id"], refs={"handoff_id": str(m["id"])},
                           dedupe_key=f"outcome:{m['id']}")

    for s in db.all_rows(conn, """
            select a.name, a.min_score, count(*) as n, round(avg(d.score)::numeric, 1) as avg
            from outreach_drafts d join agents a on a.id = d.writer_agent_id
            where d.created_at > now() - interval '7 days' and d.score is not null
            group by a.name, a.min_score having count(*) >= 5 and avg(d.score) < a.min_score - 10"""):
        raised += db.alert(conn, "bot_underperforming",
                           f"{s['name']} averaged {s['avg']}/100 over its last {s['n']} drafts (target {s['min_score']}). "
                           "Check the playbook and the client fact sheet.",
                           refs={"agent": s["name"]}, dedupe_key=f"score:{s['name']}:{today:%G-W%V}")
    return raised


def main() -> None:
    conn = db.connect()
    db.register_team(conn)
    for k, v in tick(conn).items():
        print(f"{k.replace('_', ' ')}: {v}")


if __name__ == "__main__":
    main()
