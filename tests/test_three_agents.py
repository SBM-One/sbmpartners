"""Offline test of the three-agent team (researcher, writer, reviewer) and the send-by-hand channels. Fake AI, no cost.

  TEST_DATABASE_URL=postgresql:///sbm_test python -m tests.test_three_agents   (a throwaway database with the migrations)
"""
import datetime as dt
import os
import sys
from types import SimpleNamespace as NS

from agents import review, strategy, supervisor, team, teamdb as db
from agents.practice import CriterionScore, Grade, WriterTurn

OPENED = "https://maison.example/about"


def usage():
    return NS(input_tokens=1000, output_tokens=200, cache_creation_input_tokens=0, cache_read_input_tokens=0, server_tool_use=None)


def fake_ai(calls):
    class Ctx:
        def __init__(self, **kw): self.kw = kw
        def __enter__(self):
            msg = NS(model=self.kw["model"], usage=usage(), stop_reason="end_turn", content=[
                NS(type="text", text="Notes: they sell oak dining.", citations=None),
                NS(type="web_search_tool_result", content=[NS(type="web_search_result", url=OPENED, title="About")])])
            return NS(get_final_message=lambda: msg)
        def __exit__(self, *a): return False

    def parse(**kw):
        fmt, text = kw["output_format"], kw["messages"][0]["content"]
        if fmt is team.ProspectBrief:
            out = team.ProspectBrief(summary="Oak shop.", angle="Oak dining.", cautions="", fit=4,
                                     facts=[team.Fact(fact="Sells oak dining tables", source_url=OPENED)])
        elif fmt is strategy.Strategy:
            calls["score"] += 1
            out = strategy.Strategy(criteria=[strategy.Criterion(key=k, score=4, why="Fits.") for k in strategy.FIT_WEIGHTS],
                                    decision="pursue", reason="Fits.", pitch_angle="Oak.", lead_with=["Dining"], proof_points=["FSC"],
                                    offer=None, objections=[], first_ask="A catalog?", channel_plan="email_and_linkedin",
                                    channel_reason="Allowed.")
        elif fmt is team.ChannelPlan:
            calls["plan"] += 1
            out = team.ChannelPlan(steps=[team.PlanStep(day=0, channel="email", purpose="first email"),
                                          team.PlanStep(day=3, channel="linkedin", purpose="connection note"),
                                          team.PlanStep(day=7, channel="whatsapp", purpose="WhatsApp"),
                                          team.PlanStep(day=10, channel="email", purpose="follow-up")], why="Email first.")
        elif fmt is WriterTurn:
            calls["writer"] += 1
            if "WhatsApp" in text:
                calls["whatsapp_ask"] += 1
                # the first WhatsApp try leaks a confidential customer; the reviewer must catch it and get a rewrite
                body = "Hola Ana, we also make for Rooms To Go." if calls["whatsapp_ask"] == 1 else "Hola Ana, I saw your oak dining range."
                out = WriterTurn(subject=None, message=body, playbook_used=[1])
            elif "LinkedIn connection note" in text:
                out = WriterTurn(subject=None, message="Ana, I liked your oak dining range.", playbook_used=[])
            else:
                out = WriterTurn(subject="Oak dining", message="Hi Ana, a short note about oak dining.\n\nAna R.", playbook_used=[1])
        elif fmt is Grade:
            out = Grade(criteria=[CriterionScore(key=k, score=9, why="") for k in
                                  ["relevance", "value", "clarity", "ask", "tone", "honesty", "handling"]],
                        feedback="Good.", top_fix="-", playbook_notes="")
        elif fmt is team.ReportText:
            out = team.ReportText(headline="Quiet week.", summary="-", highlights=["-"], next_week=["-"])
        else:
            raise AssertionError(fmt)
        return NS(model=kw["model"], usage=usage(), stop_reason="end_turn", parsed_output=out)

    return NS(beta=NS(messages=NS(parse=parse, stream=lambda **kw: Ctx(**kw))))


def main():
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        sys.exit("Set TEST_DATABASE_URL to a throwaway local database.")
    assert review.leaks("Hacemos muebles para Rooms To Go") and review.leaks("for Bob's stores")
    assert review.leaks("una de las cadenas más grandes de Estados Unidos") and not review.leaks("Estimado equipo de Compras")
    assert review.check("Hello Ana, our oak tables", None, "whatsapp", "first", {"outreach_language": "Spanish for Mexico"}, "", "MX")
    print("ok: the reviewer's fixed checks catch confidential customers (also hinted, also in Spanish) and the wrong language")

    conn = db.connect(url)
    db.register_team(conn)
    names = {r["name"] for r in db.all_rows(conn, "select name from agents where active")}
    assert {"researcher", "writer", "reviewer"} <= names, names
    db.all_rows(conn, "update agents set active = true, paused_reason = null, monthly_budget_cents = 100000 where name = any(%s)",
                (list(db.TEAM),))
    tag = dt.datetime.now().strftime("%H%M%S%f")
    cl = db.one(conn, """insert into clients (name, brief, brief_approved_at, sender_name, sender_company, postal_address, daily_draft_limit)
                         values (%s, %s, now(), 'Ana Ruiz', 'SBM Partners', 'Calle Mayor 1, Madrid', 10) returning id""",
                (f"Three test {tag}", db.jsonb({"brand": "Oak Co", "what_they_make": "oak furniture",
                                                "confidential_never_mention": "Customers (Rooms To Go, Bob's Discount Furniture) are confidential."})))["id"]
    co = db.one(conn, "insert into companies (name, domain, type, country) values ('Maison', %s, 'retailer', 'FR') returning id",
                (f"maison-{tag}.example",))["id"]
    people = [db.one(conn, """insert into contacts (company_id, first_name, email, email_source, email_basis, linkedin_url, phone, country)
                              values (%s, %s, %s, 'their website', 'legitimate_interest', %s, %s, 'FR') returning *""",
                     (co, f"Ana{i}", f"ana{i}-{tag}@maison.example", f"https://www.linkedin.com/in/ana{i}-{tag}",
                      "+33 6 12 34 56 78" if i == 0 else None)) for i in range(2)]
    camp = db.one(conn, "insert into campaigns (client_id, name, status, channels) values (%s, 'Test', 'live', '{email,linkedin,whatsapp}') "
                        "returning id", (cl,))["id"]
    for p in people:
        db.all_rows(conn, "insert into campaign_targets (campaign_id, contact_id, company_id) values (%s, %s, %s)", (camp, p["id"], co))
    db.all_rows(conn, "update email_country_rules set confirmed_at = now(), confirmed_by = 'test' where country = 'FR'")
    if not db.one(conn, "select 1 from playbook_entries where status = 'active'"):
        db.all_rows(conn, "insert into playbook_entries (title, body, status) values ('Keep it short', 'Short.', 'active')")

    calls = {"score": 0, "plan": 0, "writer": 0, "whatsapp_ask": 0}
    ai = fake_ai(calls)
    team.work_round(conn, ai, workers=1, url=url, log=lambda m: None)
    assert not db.one(conn, "select 1 from tasks where campaign_id = %s and kind = 'qualify_prospect'", (camp,)), \
        "the researcher scores in the same task; no separate qualification task"
    s = db.one(conn, "select * from prospect_strategies where campaign_id = %s and contact_id = %s", (camp, people[0]["id"]))
    rt = db.one(conn, "select id from tasks where kind = 'research_prospect' and contact_id = %s", (people[0]["id"],))
    assert s and s["research_task_id"] == rt["id"] and s["task_id"] == rt["id"], "the strategy points back at the research task"
    assert [x["channel"] for x in s["channel_sequence"]["steps"]] == ["email", "linkedin", "whatsapp", "email"]
    runs = {r["name"] for r in db.all_rows(conn, "select distinct a.name from agent_runs r join agents a on a.id = r.agent_id")}
    assert runs <= {"researcher", "writer", "reviewer"}, runs
    print(f"ok: research + scoring in one researcher task; spend recorded only under the three agents ({', '.join(sorted(runs))})")

    d0 = {d["channel"]: d for d in db.all_rows(conn, "select * from outreach_drafts where contact_id = %s", (people[0]["id"],))}
    d1 = {d["channel"]: d for d in db.all_rows(conn, "select * from outreach_drafts where contact_id = %s", (people[1]["id"],))}
    assert set(d0) == {"email", "linkedin", "whatsapp"}, d0.keys()
    assert set(d1) == {"email", "linkedin"}, "no WhatsApp message without a number"
    assert d0["linkedin"]["planned_day"] == 3 and d0["whatsapp"]["planned_day"] == 7 and d0["email"]["planned_day"] == 0
    wa = d0["whatsapp"]
    assert "Rooms To Go" not in wa["body"] and wa["rewrites"] == 1 and wa["review_checks"]["passed"], wa
    assert all(d["review_checks"] is not None and d["score"] is not None for d in d0.values()), "the reviewer checks every message"
    print("ok: the writer plans email -> LinkedIn (day 3) -> WhatsApp (day 7) and drafts each; the reviewer caught a leak and forced a rewrite")

    for d in d0.values():
        db.all_rows(conn, "update outreach_drafts set status = 'approved', reviewed_by = 'test' where id = %s", (d["id"],))
    todo = {r["channel"]: r for r in db.all_rows(conn, "select * from v_manual_sends where client = %s", (f"Three test {tag}",))}
    assert set(todo) == {"linkedin", "whatsapp"} and todo["whatsapp"]["wa_number"] == "33612345678", todo
    assert todo["linkedin"]["linkedin_url"].startswith("https://www.linkedin.com/in/")
    db.all_rows(conn, "update contacts set phone = null where id = %s", (people[0]["id"],))
    why = db.one(conn, "select send_blockers(%s) as w", (wa["id"],))["w"]
    assert any("WhatsApp number" in w for w in why), why
    print("ok: approved LinkedIn and WhatsApp messages wait on the send-by-hand list with their links; no number, no WhatsApp")
    print("All three-agent tests passed.")


if __name__ == "__main__":
    main()
