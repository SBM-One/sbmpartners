"""Offline test of the first real sends: the Mailer, replies, follow-ups and LinkedIn notes. No key, no email, no cost.

Needs a THROWAWAY Postgres database with the migrations applied (it adds test rows and keeps them):
  TEST_DATABASE_URL=postgresql:///sbm_test python -m tests.test_sends
"""
import datetime as dt
import email
import email.policy
import os
import smtplib
import sys
from email.message import EmailMessage
from types import SimpleNamespace as NS

from agents import mailer, supervisor, team, teamdb as db
from agents.practice import CriterionScore, Grade, WriterTurn

URL = os.environ.get("TEST_DATABASE_URL")
# A Tuesday at 10:00 in Madrid, inside the default sending window.
MON_10 = dt.datetime(2026, 11, 17, 9, 0, tzinfo=dt.timezone.utc)


def usage():
    return NS(input_tokens=1000, output_tokens=200, cache_creation_input_tokens=0, cache_read_input_tokens=0,
              server_tool_use=None)


class FakeSMTP:
    sent: list = []
    refuse: set = set()

    def __enter__(self): return self
    def __exit__(self, *a): return False
    def starttls(self): pass
    def login(self, u, p): pass

    def send_message(self, msg):
        if msg["To"].split("<")[-1].rstrip(">") in FakeSMTP.refuse:
            raise smtplib.SMTPRecipientsRefused({msg["To"]: (550, b"no such user")})
        FakeSMTP.sent.append(msg)


def fake_ai(calls):
    def parse(**kw):
        fmt = kw["output_format"]
        calls[fmt.__name__] = calls.get(fmt.__name__, 0) + 1
        if fmt is WriterTurn:
            text = kw["messages"][0]["content"]
            if "LinkedIn connection note" in text:
                out = WriterTurn(subject=None, message="Hi Ana, I saw your new Lisbon store. I work with Portuguese oak makers.",
                                 playbook_used=[])
            elif "follow-up" in text:
                assert "Oak for your floor" in text, "the follow-up must see the first email"
                out = WriterTurn(subject="ignored", message="One more thing: samples ship free.", playbook_used=[1])
            else:
                out = WriterTurn(subject="Oak for your floor", message="Hi Ana, short note.", playbook_used=[1])
        elif fmt is Grade:
            out = Grade(criteria=[CriterionScore(key=k, score=9, why="") for k in
                                  ["relevance", "value", "clarity", "ask", "tone", "honesty"]]
                        + [CriterionScore(key="handling", score=None, why="")], feedback="Good.", top_fix="-", playbook_notes="")
        elif fmt is mailer.ReplySort:
            out = mailer.ReplySort(category="interested", summary="Wants the price list and samples.")
        else:
            raise AssertionError(fmt)
        return NS(model=kw["model"], usage=usage(), stop_reason="end_turn", parsed_output=out)
    return NS(beta=NS(messages=NS(parse=parse)))


def setup(conn) -> dict:
    tag = dt.datetime.now().strftime("%H%M%S%f")
    cl = db.one(conn, """insert into clients (name, brief, brief_approved_at, sender_name, sender_company, postal_address)
                         values (%s, %s, now(), 'Ana Ruiz', 'SBM Partners for Oak Co', 'Calle Mayor 1, 28013 Madrid')
                         returning id""", (f"Sends test {tag}", db.jsonb({"brand": "Oak Co"})))["id"]
    co = db.one(conn, "insert into companies (name, domain, type, country) values ('Maison', %s, 'retailer', 'FR') returning id",
                (f"maison-{tag}.example",))["id"]
    people = []
    for i in range(3):
        people.append(db.one(conn, """insert into contacts (company_id, first_name, email, email_source, email_basis, linkedin_url)
                                      values (%s, %s, %s, 'their website', 'legitimate_interest', %s) returning *""",
                             (co, f"Ana{i}", f"ana{i}-{tag}@maison.example", f"https://www.linkedin.com/in/ana{i}-{tag}")))
    camp = db.one(conn, "insert into campaigns (client_id, name, status, channels, followup_days) "
                        "values (%s, 'Test', 'live', '{email,linkedin}', 3) returning id", (cl,))["id"]
    research = []
    for p in people:
        db.all_rows(conn, "insert into campaign_targets (campaign_id, contact_id, company_id) values (%s, %s, %s)", (camp, p["id"], co))
        research.append(db.one(conn, """insert into tasks (kind, status, client_id, campaign_id, contact_id, company_id, output, finished_at)
                                        values ('research_prospect', 'done', %s, %s, %s, %s, %s, now()) returning id""",
                               (cl, camp, p["id"], co, db.jsonb({"summary": "Shop in Lisbon.", "facts": []})))["id"])
    db.all_rows(conn, "update email_country_rules set confirmed_at = now(), confirmed_by = 'test' where country = 'FR'")
    if not db.one(conn, "select 1 from playbook_entries where status = 'active'"):
        db.all_rows(conn, "insert into playbook_entries (title, body, status) values ('Keep it short', 'Short.', 'active')")
    db.all_rows(conn, "delete from mailboxes where address = 'ana@sbm-test.example'")
    # earlier test runs may have left approved emails behind in this throwaway database
    db.all_rows(conn, "update outreach_drafts set status = 'cancelled' where status in ('pending_review','approved')")
    return {"client": cl, "campaign": camp, "people": people, "research": research, "tag": tag}


def msg(**h) -> bytes:
    m = EmailMessage(policy=email.policy.default)
    for k, v in h.items():
        if k != "body":
            m[k.replace("_", "-")] = v
    m.set_content(h.get("body", ""))
    return m.as_bytes()


def main():
    if not URL:
        sys.exit("Set TEST_DATABASE_URL to a throwaway database (see this file's header).")
    conn = db.connect(URL)
    db.register_team(conn)
    db.all_rows(conn, "update agents set active = true, paused_reason = null, monthly_budget_cents = 100000")
    t = setup(conn)
    calls: dict = {}
    ai = fake_ai(calls)
    cfg = {**mailer.settings(), "address": "ana@sbm-test.example", "password": "x", "display_name": "Ana Ruiz",
           "unsubscribe_url": "https://app.example", "dry_run": False, "smtp_port": 465}
    smtp = lambda: FakeSMTP()

    # 1) The Writer drafts an email and a LinkedIn note for the first buyer.
    for p, r in zip(t["people"], t["research"]):
        task = db.one(conn, """insert into tasks (kind, status, client_id, campaign_id, contact_id, input, claimed_at, attempts)
                               values ('draft_outreach', 'running', %s, %s, %s, %s, now(), 1) returning *""",
                      (t["client"], t["campaign"], p["id"], db.jsonb({"research_task_id": str(r)})))
        out = team.draft_outreach(conn, ai, task, {})
        db.finish(conn, task["id"], out)
        assert out["channel"] == "email" and out.get("linkedin_draft_id"), out
    li = db.one(conn, "select * from outreach_drafts where id = %s", (out["linkedin_draft_id"],))
    assert li["channel"] == "linkedin" and len(li["body"]) <= 300 and li["status"] == "pending_review"
    print("ok: each buyer gets an email draft and a short LinkedIn note, both waiting for approval")

    drafts = db.all_rows(conn, "select * from outreach_drafts where client_id = %s and channel = 'email' order by created_at",
                         (t["client"],))
    # 2) Nothing is sent before approval.
    assert mailer.send_due(conn, cfg, MON_10, smtp, log=lambda m: None) == 0 and not FakeSMTP.sent
    for d in drafts:
        db.all_rows(conn, "update outreach_drafts set status = 'approved', reviewed_by = 'yago@test' where id = %s", (d["id"],))

    # 3) Outside the window nothing goes; inside it one email goes, then the gap holds the next one.
    saturday = dt.datetime(2026, 11, 21, 10, 0, tzinfo=dt.timezone.utc)
    assert mailer.send_due(conn, cfg, saturday, smtp, log=lambda m: None) == 0, "sent on a Saturday"
    assert mailer.send_due(conn, cfg, MON_10, smtp, log=lambda m: None) == 1
    assert mailer.send_due(conn, cfg, MON_10, smtp, log=lambda m: None) == 0, "the gap between emails was ignored"
    m = FakeSMTP.sent[-1]
    body = m.get_content()
    assert "Calle Mayor 1" in body and "https://app.example/u/" in body, "footer with address and unsubscribe link missing"
    assert m["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click" and "/one-click>" in m["List-Unsubscribe"]
    first = db.one(conn, "select * from outreach_drafts where id = %s", (drafts[0]["id"],))
    assert first["status"] == "sent" and first["message_id"] == m["Message-ID"]
    assert db.one(conn, "select 1 from interactions where external_id = %s and kind = 'sent'", (m["Message-ID"],))
    print("ok: sends only approved emails, inside the window, one at a time, with address, unsubscribe link and headers")

    # 4) Daily cap.
    db.all_rows(conn, "update mailboxes set next_send_at = null, daily_cap = 2 where address = %s", (cfg["address"],))
    assert mailer.send_due(conn, cfg, MON_10, smtp, log=lambda m: None) == 1
    db.all_rows(conn, "update mailboxes set next_send_at = null where address = %s", (cfg["address"],))
    assert mailer.send_due(conn, cfg, MON_10, smtp, log=lambda m: None) == 0, "daily cap ignored"
    print("ok: the daily cap holds")

    # 5) A blocker that appears after approval holds the email and raises an alert.
    third = drafts[2]
    db.all_rows(conn, "insert into suppressions (value, reason) values (%s, 'test')", (t["people"][2]["email"],))
    db.all_rows(conn, "update mailboxes set next_send_at = null, daily_cap = 10 where address = %s", (cfg["address"],))
    assert mailer.send_due(conn, cfg, MON_10, smtp, log=lambda m: None) == 0
    held = db.one(conn, "select * from outreach_drafts where id = %s", (third["id"],))
    assert held["status"] == "approved" and "do-not-contact list" in held["send_error"]
    assert db.one(conn, "select 1 from alerts where kind = 'send_held' and refs->>'draft_id' = %s", (str(third["id"]),))
    db.all_rows(conn, "delete from suppressions where value = %s", (t["people"][2]["email"],))
    print("ok: an email blocked after approval is held, with the reason and an alert")

    # 6) Follow-up: after followup_days with no reply, the Supervisor asks for one; it threads under the first email.
    db.all_rows(conn, "update outreach_drafts set sent_at = now() - interval '4 days' where client_id = %s and status = 'sent'",
                (t["client"],))
    added = supervisor._follow_ups(conn)
    assert added == 2, f"expected 2 follow-ups, got {added}"
    task = db.claim(conn, ["draft_outreach"], "test", 5)
    task = [x for x in task if x["contact_id"] == t["people"][0]["id"]][0]
    out = team.draft_outreach(conn, ai, task, {})
    fu = db.one(conn, "select * from outreach_drafts where id = %s", (out["draft_id"],))
    assert fu["step"] == 2 and fu["subject"] is None and "linkedin_draft_id" not in out
    db.all_rows(conn, "update outreach_drafts set status = 'approved' where id = %s", (fu["id"],))
    db.all_rows(conn, "update mailboxes set next_send_at = null where address = %s", (cfg["address"],))
    assert mailer.send_due(conn, cfg, MON_10, smtp, log=lambda m: None) == 1
    f = FakeSMTP.sent[-1]
    assert f["Subject"] == "Re: Oak for your floor" and f["In-Reply-To"] == first["message_id"], "follow-up not threaded"
    assert supervisor._follow_ups(conn) == 0, "follow-ups must not repeat"
    print("ok: follow-ups are drafted after the wait, approved by a person, and sent as a reply in the same thread")

    # 7) Replies. An interested reply raises an urgent alert and stops that buyer's follow-ups.
    second = db.one(conn, "select * from outreach_drafts where contact_id = %s and step = 1 and channel = 'email'",
                    (t["people"][1]["id"],))
    pending_fu = db.one(conn, "select id from outreach_drafts where contact_id = %s and step = 2", (t["people"][1]["id"],))
    if not pending_fu:   # its follow-up task is still queued: make the draft by hand
        db.all_rows(conn, """insert into outreach_drafts (client_id, campaign_id, contact_id, step, body)
                             values (%s, %s, %s, 2, 'fu')""", (t["client"], t["campaign"], t["people"][1]["id"]))
    usage_ = mailer.Usage()
    r = mailer.handle_message(conn, msg(From=t["people"][1]["email"], To=cfg["address"], Subject="Re: Oak for your floor",
                                        Message_ID=f"<r1-{t['tag']}@maison>", In_Reply_To=second["message_id"],
                                        body="Yes please, send prices and samples.\n\nOn Tue, Ana wrote:\n> Hi"),
                              ai, usage_, "claude-opus-5-5")
    assert r.startswith("interested"), r
    assert db.one(conn, "select 1 from alerts where kind = 'buyer_replied' and severity = 'urgent' and refs->>'contact_id' = %s",
                  (str(t["people"][1]["id"]),))
    assert not db.one(conn, "select 1 from outreach_drafts where contact_id = %s and step = 2 and status in ('pending_review','approved')",
                      (t["people"][1]["id"],)), "follow-up not cancelled after a reply"
    again = mailer.handle_message(conn, msg(From=t["people"][1]["email"], Subject="Re", Message_ID=f"<r1-{t['tag']}@maison>",
                                            body="Yes"), ai, usage_, "m")
    assert again == "already filed"
    print("ok: an interested reply is sorted, alerts you, stops follow-ups, and is filed only once")

    # 8) "Please remove me" stops everything, without needing the AI.
    r = mailer.handle_message(conn, msg(From=t["people"][0]["email"], Subject="Re: Oak", Message_ID=f"<r2-{t['tag']}@maison>",
                                        body="Please remove me from your list."), None)
    assert r.startswith("unsubscribe"), r
    assert db.one(conn, "select do_not_contact from contacts where id = %s", (t["people"][0]["id"],))["do_not_contact"]
    assert db.one(conn, "select 1 from suppressions where value = %s", (t["people"][0]["email"].lower(),))
    li0 = db.one(conn, "select status from outreach_drafts where contact_id = %s and channel = 'linkedin'", (t["people"][0]["id"],))
    assert li0["status"] == "cancelled", "the LinkedIn note was not cancelled after an unsubscribe"
    print("ok: an unsubscribe reply stops all outreach on every channel")

    # 9) Out of office changes nothing; a bounce marks the address invalid.
    r = mailer.handle_message(conn, msg(From=t["people"][2]["email"], Subject="Automatic reply: away", Auto_Submitted="auto-replied",
                                        Message_ID=f"<r3-{t['tag']}@maison>", body="Away"), None)
    assert r.startswith("out of office") or r.startswith("not a reply"), r
    bounce = msg(From="MAILER-DAEMON@mail.example", Subject="Undelivered", X_Failed_Recipients=t["people"][2]["email"],
                 Message_ID=f"<b1-{t['tag']}@mail>", body="550 no such user")
    assert mailer.handle_message(conn, bounce, None).startswith("bounce")
    assert db.one(conn, "select email_status from contacts where id = %s", (t["people"][2]["id"],))["email_status"] == "invalid"
    assert mailer.handle_message(conn, msg(From="stranger@else.example", Subject="Hi", Message_ID="<x@y>", body="?"), None) \
        .startswith("not a reply")
    print("ok: out-of-office is ignored, bounces mark the address invalid, unrelated mail is left alone")

    # 10) A refused address is cancelled, never retried.
    p = t["people"][2]
    db.all_rows(conn, "update contacts set email_status = 'unknown' where id = %s", (p["id"],))
    db.all_rows(conn, "update outreach_drafts set send_error = null where id = %s", (third["id"],))
    FakeSMTP.refuse = {p["email"]}
    db.all_rows(conn, "update mailboxes set next_send_at = null where address = %s", (cfg["address"],))
    assert mailer.send_due(conn, cfg, MON_10, smtp, log=lambda m: None) == 0
    assert db.one(conn, "select status from outreach_drafts where id = %s", (third["id"],))["status"] == "cancelled"
    print("ok: an address the server refuses is marked invalid and never retried")
    print("All sending tests passed.")


if __name__ == "__main__":
    main()
