"""Offline test of qualification, answers, check-ins and the meeting handoff. No key, no email, no cost.

Needs a THROWAWAY Postgres database with the migrations applied (it adds test rows and keeps them):
  TEST_DATABASE_URL=postgresql:///sbm_test python -m tests.test_pipeline
"""
import datetime as dt
import os
import sys
from types import SimpleNamespace as NS

from agents import mailer, strategy, supervisor, team, teamdb as db
from agents.practice import CriterionScore, Grade, WriterTurn
from tests.test_sends import FakeSMTP, MON_10, msg

URL = os.environ.get("TEST_DATABASE_URL")


def usage():
    return NS(input_tokens=1000, output_tokens=200, cache_creation_input_tokens=0, cache_read_input_tokens=0,
              server_tool_use=None)


def strat(decision="pursue", score=4, plan="email_and_linkedin", product=None):
    crit = [strategy.Criterion(key=k, score=(product if (k == "product_fit" and product is not None) else score), why="x")
            for k in strategy.FIT_WEIGHTS]
    return strategy.Strategy(criteria=crit, decision=decision, reason="Because.", pitch_angle="Their new oak floor.",
                             lead_with=["Lounge chairs"], proof_points=["38 stores"], offer="Free sample kit",
                             objections=[strategy.Objection(objection="Minimums", answer="$1,500 opening order")],
                             first_ask="Send the sample kit?", channel_plan=plan, channel_reason="Allowed.")


def fake_ai(plan: dict, seen: dict):
    def parse(**kw):
        fmt = kw["output_format"]
        text = kw["messages"][0]["content"]
        seen.setdefault(fmt.__name__, []).append(text)
        if fmt is strategy.Strategy:
            name = text.split("Buyer: ")[1].split(",")[0]
            out = plan[name]
        elif fmt is WriterTurn:
            if "LinkedIn connection note" in text:
                out = WriterTurn(subject=None, message="Hi, I work with oak makers.", playbook_used=[])
            elif "The buyer replied" in text:
                assert "Yes please, send prices" in text, "the answer must see what the buyer wrote"
                out = WriterTurn(subject=None, message="Thank you! Prices attached. Would Tuesday or Thursday suit for a call?",
                                 playbook_used=[1])
            elif 'said "not now"' in text:
                out = WriterTurn(subject=None, message="A new walnut range is in: worth a look for spring?", playbook_used=[])
            else:
                assert "Strategy for this buyer" in text and "Their new oak floor." in text, "the Writer must get the strategy"
                out = WriterTurn(subject="Oak for your floor", message="Hi, short note.", playbook_used=[1])
        elif fmt is Grade:
            out = Grade(criteria=[CriterionScore(key=k, score=9, why="") for k in
                                  ["relevance", "value", "clarity", "ask", "tone", "honesty", "handling"]],
                        feedback="Good.", top_fix="-", playbook_notes="")
        elif fmt is strategy.Handoff:
            assert "Yes please, send prices" in text, "the brief must see the conversation"
            out = strategy.Handoff(
                headline="Wants prices and samples for a spring refresh.", qualified=True,
                checks=[strategy.Check(key="interest", status="yes", evidence='"Yes please, send prices"'),
                        strategy.Check(key="product_fit", status="yes", evidence="Carries oak"),
                        strategy.Check(key="authority", status="unclear", evidence="Title unknown"),
                        strategy.Check(key="timing", status="yes", evidence="Spring"),
                        strategy.Check(key="terms", status="unclear", evidence="Minimums not discussed")],
                interest="Prices and samples.", product_fit="Lounge chairs suit their floor.",
                open_questions=["Who signs off?"], next_steps=["Send the price list", "Book a 20-minute call"],
                agenda=["Their range", "Samples", "Terms"])
        elif fmt is mailer.ReplySort:
            out = mailer.ReplySort(category="interested", summary="Wants the price list and samples.")
        else:
            raise AssertionError(fmt)
        return NS(model=kw["model"], usage=usage(), stop_reason="end_turn", parsed_output=out)
    return NS(beta=NS(messages=NS(parse=parse)))


def run(conn, ai, kinds):
    """Run every queued task of these kinds, like the team runner does."""
    n = 0
    while True:
        batch = db.claim(conn, kinds, "test", 10)
        if not batch:
            return n
        for t in batch:
            out = team.HANDLERS[t["kind"]](conn, ai, t, {})
            db.finish(conn, t["id"], out)
            n += 1


def main():
    if not URL:
        sys.exit("Set TEST_DATABASE_URL to a throwaway database (see this file's header).")
    conn = db.connect(URL)
    db.register_team(conn)
    db.all_rows(conn, "update agents set active = true, paused_reason = null, monthly_budget_cents = 100000")
    db.all_rows(conn, "update outreach_drafts set status = 'cancelled' where status in ('pending_review','approved')")
    db.all_rows(conn, "update tasks set status = 'cancelled' where status in ('queued','running')")
    tag = dt.datetime.now().strftime("%H%M%S%f")
    cl = db.one(conn, """insert into clients (name, brief, brief_approved_at, sender_name, sender_company, postal_address, daily_draft_limit)
                         values (%s, %s, now(), 'Ana Ruiz', 'SBM Partners for Oak Co', 'Calle Mayor 1, Madrid', 10) returning id""",
                (f"Pipeline test {tag}", db.jsonb({"brand": "Oak Co", "what_they_make": "oak chairs"})))["id"]
    fr = db.one(conn, "insert into companies (name, domain, type, country) values ('Maison', %s, 'retailer', 'FR') returning id",
                (f"maison-{tag}.example",))["id"]
    de = db.one(conn, "insert into companies (name, domain, type, country) values ('Haus', %s, 'retailer', 'DE') returning id",
                (f"haus-{tag}.example",))["id"]
    names = {"Good": fr, "Weak": fr, "Wrong": fr, "German": de, "Later": fr}
    people = {}
    for n, co in names.items():
        people[n] = db.one(conn, """insert into contacts (company_id, first_name, email, email_source, email_basis, linkedin_url)
                                    values (%s, %s, %s, 'their website', 'legitimate_interest', %s) returning *""",
                           (co, n, f"{n.lower()}-{tag}@{'haus' if co == de else 'maison'}.example",
                            f"https://www.linkedin.com/in/{n.lower()}-{tag}"))
    camp = db.one(conn, "insert into campaigns (client_id, name, status, channels, min_fit_score) "
                        "values (%s, 'Test', 'live', '{email,linkedin}', 60) returning id", (cl,))["id"]
    for i, (n, p) in enumerate(people.items()):
        db.all_rows(conn, "insert into campaign_targets (campaign_id, contact_id, company_id, fit_score) values (%s, %s, %s, %s)",
                    (camp, p["id"], names[n], 1 - i / 10))
        db.all_rows(conn, """insert into tasks (kind, status, client_id, campaign_id, contact_id, company_id, output, finished_at)
                             values ('research_prospect', 'done', %s, %s, %s, %s, %s, now())""",
                    (cl, camp, p["id"], names[n], db.jsonb({"summary": "A shop.", "facts": []})))
    db.all_rows(conn, "update email_country_rules set confirmed_at = now(), confirmed_by = 'test' where country in ('FR','DE')")
    if not db.one(conn, "select 1 from playbook_entries where status = 'active'"):
        db.all_rows(conn, "insert into playbook_entries (title, body, status) values ('Keep it short', 'Short.', 'active')")
    cfg = {**mailer.settings(), "address": f"ana-{tag}@sbm-test.example", "password": "x", "display_name": "Ana Ruiz",
           "unsubscribe_url": "https://app.example", "dry_run": False, "smtp_port": 465}
    smtp = lambda: FakeSMTP()
    seen: dict = {}
    plan = {"Good": strat(), "Weak": strat(score=2), "Wrong": strat("disqualify", score=1),
            "German": strat(plan="email"), "Later": strat(plan="email")}
    ai = fake_ai(plan, seen)
    P = lambda n: people[n]["id"]

    # 1) Research is followed by qualification, and only "pursue" buyers get a first draft.
    supervisor.tick(conn)
    assert run(conn, ai, ["qualify_prospect"]) == 5
    S = {n: db.one(conn, "select * from prospect_strategies where campaign_id = %s and contact_id = %s", (camp, P(n)))
         for n in people}
    assert S["Good"]["decision"] == "pursue" and S["Good"]["fit_score"] == 80 and S["Good"]["channel_plan"] == "email_and_linkedin"
    assert S["Weak"]["decision"] == "nurture" and S["Weak"]["fit_score"] == 40, "below the minimum fit must not be pursued"
    assert S["Wrong"]["decision"] == "disqualify"
    assert S["German"]["channel_plan"] == "linkedin", "Germany needs consent, so the Strategist must switch to LinkedIn"
    assert "Germany needs" in seen["Strategy"][0] or any("Germany needs" in t for t in seen["Strategy"])
    assert db.one(conn, "select fit_score from campaign_targets where campaign_id = %s and contact_id = %s",
                  (camp, P("Good")))["fit_score"] == 0.8
    print("ok: every researched buyer is scored; low fit is held back, misfits are disqualified, the channel follows the rules")

    supervisor.tick(conn)
    run(conn, ai, ["draft_outreach"])
    drafts = db.all_rows(conn, "select * from outreach_drafts where client_id = %s order by created_at", (cl,))
    who = {(d["contact_id"], d["channel"]) for d in drafts}
    assert who == {(P("Good"), "email"), (P("Good"), "linkedin"), (P("German"), "linkedin"), (P("Later"), "email")}, who
    assert all(d["purpose"] == "first" and d["strategy_id"] for d in drafts)
    print("ok: only pursued buyers get drafts, through the channel the Strategist chose, with the strategy attached")

    # 2) The database refuses a first message to a buyer you or the Strategist held back.
    d = db.one(conn, """insert into outreach_drafts (client_id, campaign_id, contact_id, subject, body)
                        values (%s, %s, %s, 'Hi', 'Hello') returning id""", (cl, camp, P("Weak")))["id"]
    why = db.one(conn, "select send_blockers(%s) as w", (d,))["w"]
    assert any('marked "nurture"' in w for w in why), why
    db.all_rows(conn, "update prospect_strategies set decision = 'pursue', decided_by = 'yago@test' where id = %s", (S["Weak"]["id"],))
    assert db.one(conn, "select send_blockers(%s) as w", (d,))["w"] == []
    db.all_rows(conn, "update outreach_drafts set status = 'cancelled' where id = %s", (d,))
    # the Strategist never overwrites your decision
    t = db.one(conn, """insert into tasks (kind, status, client_id, campaign_id, contact_id, input, attempts)
                        values ('qualify_prospect', 'running', %s, %s, %s, '{}', 1) returning *""", (cl, camp, P("Weak")))
    strategy.qualify_prospect(conn, ai, t, {})
    assert db.one(conn, "select decision from prospect_strategies where id = %s", (S["Weak"]["id"],))["decision"] == "pursue"
    print("ok: the gate blocks first messages to held-back buyers; your override stands and is never overwritten")

    # 3) Send the first emails, then the Good buyer answers "yes please".
    for dd in drafts:
        if dd["channel"] == "email":
            db.all_rows(conn, "update outreach_drafts set status = 'approved', reviewed_by = 'yago@test' where id = %s", (dd["id"],))
    db.all_rows(conn, "delete from mailboxes where address = %s", (cfg["address"],))
    for _ in range(2):
        assert mailer.send_due(conn, cfg, MON_10, smtp, log=lambda m: None) == 1
        db.all_rows(conn, "update mailboxes set next_send_at = null where address = %s", (cfg["address"],))
    first = db.one(conn, "select * from outreach_drafts where contact_id = %s and channel = 'email' and step = 1", (P("Good"),))
    db.all_rows(conn, """insert into outreach_drafts (client_id, campaign_id, contact_id, step, body)
                         values (%s, %s, %s, 2, 'Follow-up waiting')""", (cl, camp, P("Good")))
    r = mailer.handle_message(conn, msg(From=people["Good"]["email"], Subject="Re: Oak for your floor",
                                        Message_ID=f"<yes-{tag}@maison>", In_Reply_To=first["message_id"],
                                        body="Yes please, send prices and samples."), ai, mailer.Usage(), "m")
    assert r.startswith("interested"), r
    assert not db.one(conn, "select 1 from outreach_drafts where contact_id = %s and purpose = 'follow_up' "
                            "and status in ('pending_review','approved')", (P("Good"),)), "follow-up not cancelled"
    conv = db.one(conn, "select * from v_conversations where campaign_id = %s and contact_id = %s", (camp, P("Good")))
    assert conv["stage"] == "replied" and conv["last_reply_category"] == "interested" and conv["replies"] == 1, conv
    print("ok: a reply stops follow-ups and shows up in the conversation tracker")

    # 4) The Supervisor asks for an answer and a meeting brief.
    out = supervisor._conversations(conn)
    assert out == {"answers_added": 1, "meeting_briefs_added": 1, "check_ins_added": 0}, out
    assert supervisor._conversations(conn) == {"answers_added": 0, "meeting_briefs_added": 0, "check_ins_added": 0}
    run(conn, ai, ["draft_reply", "prepare_handoff"])
    ans = db.one(conn, "select * from outreach_drafts where contact_id = %s and purpose = 'reply'", (P("Good"),))
    assert ans and ans["status"] == "pending_review" and ans["subject"] is None and ans["step"] == 2, ans
    conv = db.one(conn, "select * from v_conversations where campaign_id = %s and contact_id = %s", (camp, P("Good")))
    assert conv["stage"] == "meeting_ready" and conv["answers_waiting"] == 1, conv
    db.all_rows(conn, "update outreach_drafts set status = 'approved', reviewed_by = 'yago@test' where id = %s", (ans["id"],))
    db.all_rows(conn, "update mailboxes set next_send_at = null where address = %s", (cfg["address"],))
    assert mailer.send_due(conn, cfg, MON_10, smtp, log=lambda m: None) == 1
    m = FakeSMTP.sent[-1]
    assert m["In-Reply-To"] == f"<yes-{tag}@maison>" and first["message_id"] in m["References"], "answer not threaded"
    assert m["Subject"] == "Re: Oak for your floor"
    print("ok: the Writer drafts an answer, you approve it, and it goes out in the buyer's own thread")

    h = db.one(conn, "select * from meeting_handoffs where contact_id = %s", (P("Good"),))
    assert h and h["status"] == "ready" and h["qualified"], h
    assert [x["kind"] for x in h["contact_history"]] == ["sent", "reply"], h["contact_history"]
    assert "Yes please, send prices" in h["body"] and "## Next steps" in h["body"] and "## Contact history" in h["body"]
    assert db.one(conn, "select 1 from alerts where kind = 'meeting_ready' and refs->>'handoff_id' = %s", (str(h["id"]),))
    print("ok: the Meeting briefer hands you a qualified-meeting brief with the full contact history, and alerts you")

    # 5) You book it: the meeting is logged, the deal opens, automatic messages stop.
    deal = db.one(conn, "select book_meeting(%s, now() + interval '3 days', 'Zoom', 'yago@test') as d", (h["id"],))["d"]
    assert db.one(conn, "select stage from deals where id = %s", (deal,))["stage"] == "conversation"
    assert db.one(conn, "select 1 from interactions where contact_id = %s and kind = 'meeting_booked'", (P("Good"),))
    assert db.one(conn, "select status from campaign_targets where campaign_id = %s and contact_id = %s",
                  (camp, P("Good")))["status"] == "meeting"
    fu = db.one(conn, """insert into outreach_drafts (client_id, campaign_id, contact_id, step, purpose, body)
                         values (%s, %s, %s, 3, 'follow_up', 'x') returning id""", (cl, camp, P("Good")))["id"]
    assert any("handed to you for a meeting" in w for w in db.one(conn, "select send_blockers(%s) as w", (fu,))["w"])
    assert db.one(conn, "select stage from v_conversations where campaign_id = %s and contact_id = %s",
                  (camp, P("Good")))["stage"] == "meeting_booked"
    db.all_rows(conn, "select close_meeting(%s, 'held', 'Good call', 'yago@test')", (h["id"],))
    assert db.one(conn, "select 1 from interactions where contact_id = %s and kind = 'meeting_held'", (P("Good"),))
    print("ok: booking logs the meeting, opens the deal, moves the buyer to 'meeting' and blocks automatic messages")

    # 6) "Not now": snoozed, then exactly one check-in once the snooze ends.
    later = db.one(conn, "select * from outreach_drafts where contact_id = %s and step = 1 and channel = 'email'", (P("Later"),))
    ai_nn = fake_ai(plan, seen)
    ai_nn.beta.messages.parse = (lambda orig: (lambda **kw: NS(
        model="m", usage=usage(), stop_reason="end_turn",
        parsed_output=mailer.ReplySort(category="not_now", summary="Stocked until spring."))
        if kw["output_format"] is mailer.ReplySort else orig(**kw)))(ai_nn.beta.messages.parse)
    mailer.handle_message(conn, msg(From=people["Later"]["email"], Subject="Re: Oak", Message_ID=f"<later-{tag}@maison>",
                                    In_Reply_To=later["message_id"], body="We are stocked until spring."), ai_nn, mailer.Usage(), "m")
    ct = db.one(conn, "select * from campaign_targets where campaign_id = %s and contact_id = %s", (camp, P("Later")))
    assert ct["snoozed_until"] and ct["snoozed_until"] > dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=50)
    assert db.one(conn, "select stage from v_conversations where campaign_id = %s and contact_id = %s",
                  (camp, P("Later")))["stage"] == "snoozed"
    assert supervisor._conversations(conn)["check_ins_added"] == 0, "checked in before the snooze ended"
    db.all_rows(conn, "update campaign_targets set snoozed_until = now() - interval '1 minute' where campaign_id = %s and contact_id = %s",
                (camp, P("Later")))
    assert supervisor._conversations(conn)["check_ins_added"] == 1
    run(conn, ai, ["draft_reply"])
    ci = db.one(conn, "select * from outreach_drafts where contact_id = %s and purpose = 'check_in'", (P("Later"),))
    db.all_rows(conn, "update outreach_drafts set status = 'approved' where id = %s", (ci["id"],))
    db.all_rows(conn, "update mailboxes set next_send_at = null where address = %s", (cfg["address"],))
    assert mailer.send_due(conn, cfg, MON_10, smtp, log=lambda m: None) == 1
    assert supervisor._conversations(conn)["check_ins_added"] == 0, "a second check-in was planned"
    again = db.one(conn, """insert into outreach_drafts (client_id, campaign_id, contact_id, step, purpose, body)
                            values (%s, %s, %s, 4, 'check_in', 'x') returning id""", (cl, camp, P("Later")))["id"]
    assert any("already got their one check-in" in w for w in db.one(conn, "select send_blockers(%s) as w", (again,))["w"])
    print("ok: 'not now' snoozes the buyer; one check-in is drafted after the snooze, approved and sent; never a second")

    # 7) A reply you log by hand (LinkedIn) works the same way, and "unsubscribe" there stops email too.
    li = db.one(conn, """insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, body, metadata)
                         values (%s, %s, %s, 'linkedin', 'inbound', 'reply', 'buyer', 'Please stop messaging me',
                                 '{"category":"unsubscribe","summary":"Asked to stop","logged_by":"yago@test"}') returning id""",
                 (cl, camp, P("German")))["id"]
    assert db.one(conn, "select apply_reply(%s) as r", (li,))["r"] == "stopped"
    assert db.one(conn, "select do_not_contact from contacts where id = %s", (P("German"),))["do_not_contact"]
    assert db.one(conn, "select stage from v_conversations where campaign_id = %s and contact_id = %s",
                  (camp, P("German")))["stage"] == "stopped"
    print("ok: replies logged by hand use the same rules; an unsubscribe on LinkedIn stops every channel")
    print("All pipeline tests passed.")


if __name__ == "__main__":
    main()
