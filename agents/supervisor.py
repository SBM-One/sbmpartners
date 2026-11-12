"""The Supervisor: keeps the team moving, safe and within budget. It follows fixed rules, so it costs nothing to run.

Each round (a "tick") it:
  1. puts stuck tasks back in the queue,
  2. pauses any agent that reached its monthly budget (and un-pauses it when a new month starts),
  3. hands out work for live campaigns: research each new buyer, then a draft for each researched buyer,
     paced by each client's daily draft limit,
  4. asks the Reporter for last week's report for each active client,
  5. raises alerts for you: failed tasks, a missing brand fact sheet, drafts waiting over a day for
     approval, and an agent whose scores are slipping.

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
    researched = drafted = 0
    for c in db.all_rows(conn, """
            select cl.id as client_id, cl.name, cl.brief, cl.daily_draft_limit,
                   array_agg(ca.id) as campaign_ids
            from clients cl join campaigns ca on ca.client_id = cl.id
            where ca.status = 'live' and cl.status = 'active'
            group by cl.id"""):
        if not c["brief"]:
            db.alert(conn, "client_brief_missing",
                     f"{c['name']} has a live campaign but no brand fact sheet (clients.brief), so no drafts are written.",
                     severity="urgent", client_id=c["client_id"], dedupe_key=f"brief:{c['client_id']}")
            continue

        # Step 2: every researched buyer gets a draft (these were already counted against the daily limit).
        for t in db.all_rows(conn, """
                select r.id, r.client_id, r.campaign_id, r.contact_id, r.company_id
                from tasks r
                where r.kind = 'research_prospect' and r.status = 'done' and r.client_id = %s
                  and not exists (select 1 from tasks d where d.kind = 'draft_outreach'
                                  and d.campaign_id = r.campaign_id and d.contact_id = r.contact_id)""",
                             (c["client_id"],)):
            if db.enqueue(conn, "draft_outreach", client_id=t["client_id"], campaign_id=t["campaign_id"],
                          contact_id=t["contact_id"], company_id=t["company_id"], parent_id=t["id"],
                          input={"research_task_id": str(t["id"])}, priority=50):
                drafted += 1

        # Step 1: research new buyers, up to today's limit. Today's drafts and all work in progress count.
        used = db.one(conn, """
            select (select count(*) from outreach_drafts where client_id = %(c)s and created_at::date = current_date)
                 + (select count(*) from tasks where client_id = %(c)s and status in ('queued','running')
                    and kind in ('research_prospect','draft_outreach')) as n""", {"c": c["client_id"]})["n"]
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
    return {"research_tasks_added": researched, "draft_tasks_added": drafted}


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
                           f"{waiting} draft(s) have waited more than a day for your approval (see v_approval_queue).",
                           severity="info", dedupe_key=f"queue:{today}")

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
