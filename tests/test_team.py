"""Offline test of the agent team with a fake AI: no key, no cost.

Needs a THROWAWAY Postgres database with the migrations applied (it adds test rows and keeps them):
  createdb sbm_test && psql -d sbm_test -f db/local/supabase_mock.sql
  DATABASE_URL=postgresql:///sbm_test scripts/db_setup.sh
  TEST_DATABASE_URL=postgresql:///sbm_test python -m tests.test_team
"""
import datetime as dt
import os
import sys
from types import SimpleNamespace as NS

from agents import supervisor, team, teamdb as db
from agents.practice import CriterionScore, Grade, WriterTurn

URL = os.environ.get("TEST_DATABASE_URL")
OPENED = "https://buyer.example/about"


def usage():
    return NS(input_tokens=3000, output_tokens=500, cache_creation_input_tokens=0, cache_read_input_tokens=0,
              server_tool_use=NS(web_search_requests=1))


def grade(s):
    return Grade(criteria=[CriterionScore(key=k, score=s, why="") for k in
                           ["relevance", "value", "clarity", "ask", "tone", "honesty"]]
             + [CriterionScore(key="handling", score=None, why="")],
             feedback="Feedback.", top_fix="Name a product.", playbook_notes="")


def fake_ai(calls):
    def stream(**kw):
        calls["stream"] += 1
        msg = NS(model=kw["model"], usage=usage(), stop_reason="end_turn", content=[
            NS(type="text", text="Notes: they carry oak furniture.", citations=None),
            NS(type="web_search_tool_result", content=[NS(type="web_search_result", url=OPENED, title="About")])])
        return NS(__enter__=lambda *a: NS(get_final_message=lambda: msg), __exit__=lambda *a: None)

    class Ctx:
        def __init__(self, **kw): self.kw = kw
        def __enter__(self): return stream(**self.kw).__enter__()
        def __exit__(self, *a): return False

    def parse(**kw):
        fmt = kw["output_format"]
        if fmt is team.ProspectBrief:
            out = team.ProspectBrief(summary="Oak-focused shop.", angle="Fits their oak range.", cautions="", fit=4, facts=[
                team.Fact(fact="Carries solid oak tables", source_url=OPENED),
                team.Fact(fact="Made-up fact", source_url="https://never-opened.example/x")])
        elif fmt is WriterTurn:
            calls["writer"] += 1
            out = WriterTurn(subject="Oak for your floor", message=f"Hi, draft {calls['writer']}.", playbook_used=[1, 99])
        elif fmt is Grade:
            calls["grader"] += 1
            out = grade(5 if calls["grader"] == 1 else 9)   # the very first draft is weak, so it gets a rewrite
        elif fmt is team.ReportText:
            out = team.ReportText(headline="A quiet first week.", summary="We researched buyers.",
                                  highlights=["2 drafts written"], next_week=["Send approved drafts"])
        else:
            raise AssertionError(fmt)
        return NS(model=kw["model"], usage=usage(), stop_reason="end_turn", parsed_output=out)

    return NS(beta=NS(messages=NS(parse=parse, stream=lambda **kw: Ctx(**kw))))


def setup(conn) -> dict:
    tag = dt.datetime.now().strftime("%H%M%S%f")
    cl = db.one(conn, "insert into clients (name, brief, daily_draft_limit) values (%s, %s, 2) returning id",
                (f"Team test {tag}", db.jsonb({"brand": "Oak Co", "what_they_make": "oak furniture"})))["id"]
    co = db.one(conn, "insert into companies (name, domain, type) values ('Buyer', %s, 'retailer') returning id",
                (f"buyer-{tag}.example",))["id"]
    contacts = [db.one(conn, "insert into contacts (company_id, first_name, email, do_not_contact) values (%s, %s, %s, %s) returning id",
                       (co, f"P{i}", f"p{i}-{tag}@buyer.example", i == 0))["id"] for i in range(4)]
    camp = db.one(conn, "insert into campaigns (client_id, name, status) values (%s, 'Test', 'live') returning id", (cl,))["id"]
    for i, ct in enumerate(contacts):
        db.all_rows(conn, "insert into campaign_targets (campaign_id, contact_id, company_id, fit_score) values (%s, %s, %s, %s)",
                    (camp, ct, co, 1 - i / 10))
    db.all_rows(conn, "insert into playbook_entries (title, body, status) values ('Keep it short', 'Under 100 words.', 'active')")
    return {"client": cl, "campaign": camp, "contacts": contacts}


def main():
    if not URL:
        sys.exit("Set TEST_DATABASE_URL to a throwaway database (see this file's header).")
    conn = db.connect(URL)
    db.register_team(conn)
    db.all_rows(conn, "update agents set active = true, paused_reason = null, monthly_budget_cents = 10000 where name = any(%s)",
                (list(db.TEAM),))
    t = setup(conn)
    calls = {"stream": 0, "writer": 0, "grader": 0}
    ai = fake_ai(calls)

    ran = team.work_round(conn, ai, workers=2, url=URL, log=lambda m: None)
    drafts = db.all_rows(conn, "select * from outreach_drafts where client_id = %s order by created_at", (t["client"],))
    assert len(drafts) == 2, f"daily limit is 2, got {len(drafts)} drafts"
    assert all(d["status"] == "pending_review" for d in drafts), "drafts must wait for approval"
    dnc = t["contacts"][0]
    assert not db.one(conn, "select 1 from tasks where contact_id = %s", (dnc,)), "a do-not-contact buyer was researched"
    assert {d["contact_id"] for d in drafts} == set(t["contacts"][1:3]), "best-fit buyers should go first"
    assert sum(d["rewrites"] for d in drafts) == 1 and all(d["score"] == 90 for d in drafts), "weak draft must be rewritten"
    assert drafts[0]["playbook_used"] == ["Keep it short"], "only real playbook entries are recorded"
    facts = drafts[0]["research"]["facts"]
    assert [f["source_url"] for f in facts] == [OPENED], "facts from pages the agent never opened must be dropped"
    assert db.one(conn, "select count(*) as n from field_sources where entity_id = %s", (drafts[0]["contact_id"],))["n"] == 1
    rep = db.one(conn, "select * from reports where client_id = %s", (t["client"],))
    assert rep and rep["status"] == "draft" and "A quiet first week." in rep["body"], "weekly report must be a draft"
    spent = db.one(conn, "select spent_usd from v_agent_spend_month where name = 'writer'")["spent_usd"]
    assert spent > 0, "spending must be recorded"
    print(f"ok: {ran} tasks; 2 drafts within the daily limit, rewrite, sources checked, report drafted, spend ${spent}")

    # Same day again: the daily limit is used up, so no new research.
    team.work_round(conn, ai, workers=2, url=URL, log=lambda m: None)
    n = db.one(conn, "select count(*) as n from tasks where client_id = %s and kind = 'research_prospect'", (t["client"],))["n"]
    assert n == 2, f"daily limit ignored: {n} research tasks"
    print("ok: daily pacing holds on the next round")

    # Budget cap: the Grader runs out, so the Writer's tasks wait and you get an urgent alert.
    db.all_rows(conn, "update agents set monthly_budget_cents = 1 where name = 'grader'")
    db.all_rows(conn, "update outreach_drafts set created_at = created_at - interval '1 day' where client_id = %s", (t["client"],))
    before = calls["writer"]
    team.work_round(conn, ai, workers=2, url=URL, log=lambda m: None)
    assert db.one(conn, "select active from agents where name = 'grader'")["active"] is False, "over-budget agent not paused"
    assert db.one(conn, "select 1 from alerts where kind = 'budget_cap' and refs->>'agent' = 'grader'"), "no budget alert"
    assert calls["writer"] == before, "the Writer worked although its Grader was out of budget"
    queued = db.one(conn, "select count(*) as n from tasks where client_id = %s and kind = 'draft_outreach' and status = 'queued'",
                    (t["client"],))["n"]
    assert queued >= 1, "drafting work should wait in the queue"
    db.all_rows(conn, "update agents set monthly_budget_cents = 10000 where name = 'grader'")
    supervisor.tick(conn)
    assert db.one(conn, "select active from agents where name = 'grader'")["active"], "agent not resumed after budget raised"
    print("ok: budget cap pauses the team member, work waits, and it resumes when the budget is raised")

    # A failing task is retried, then reported.
    db.all_rows(conn, "update clients set brief = '{}' where id = %s", (t["client"],))
    task = db.claim(conn, ["draft_outreach"], "test", 1)[0]
    assert "will retry" in team.run_task(task, ai, URL)
    db.all_rows(conn, "update tasks set attempts = max_attempts, run_after = now() where id = %s", (task["id"],))
    task = db.claim(conn, ["draft_outreach"], "test", 1)[0]
    assert "failed" in team.run_task(task, ai, URL)
    supervisor.tick(conn)
    assert db.one(conn, "select 1 from alerts where kind = 'task_failed'"), "failed task not reported"
    assert db.one(conn, "select 1 from alerts where kind = 'client_brief_missing' and client_id = %s", (t["client"],))
    print("ok: failures are retried, then raised as alerts; a missing fact sheet is flagged")
    print("All team tests passed.")


if __name__ == "__main__":
    main()
