"""Offline test of the benchmark plumbing (bench/run.py) with a fake AI. No key, no cost, nothing sent.

Needs a THROWAWAY local Postgres database (the migrations are applied if missing):
  TEST_DATABASE_URL=postgresql:///sbm_bench python -m tests.test_benchmark
"""
import json
import os
import pathlib
import re
import sys
import tempfile
from types import SimpleNamespace as NS

from agents import mailer, strategy, team
from agents.practice import BuyerTurn, CriterionScore, Grade, WeakSpots, WriterTurn
from bench import run as B
from bench.sandbox import is_local

LEADS = {l["company"]["name"]: l for l in json.loads((B.FIX / "leads.json").read_text())}


def usage():
    return NS(input_tokens=1000, output_tokens=200, cache_creation_input_tokens=0, cache_read_input_tokens=0, server_tool_use=None)


def grade(score):
    return Grade(criteria=[CriterionScore(key=k, score=score, why="") for k in
                           ["relevance", "value", "clarity", "ask", "tone", "honesty", "handling"]],
                 feedback="Fine.", top_fix="-", playbook_notes="")


def fake_ai():
    def parse(**kw):
        fmt, text = kw["output_format"], kw["messages"][0]["content"]
        if fmt is strategy.Strategy:
            name = next(n for n in LEADS if n in text)
            want = LEADS[name]["expect"]["decision"][0]
            sc = 5 if want == "pursue" else 1
            out = strategy.Strategy(
                criteria=[strategy.Criterion(key=k, score=sc, why="x") for k in strategy.FIT_WEIGHTS], decision=want,
                reason="Because.", pitch_angle="Dining for a new store.", lead_with=["Dining"], proof_points=["30 containers a month"],
                offer=None, objections=[strategy.Objection(objection="Minimums", answer="One trailer, 20 pieces per model")],
                first_ask="A call?", channel_plan="email_and_linkedin", channel_reason="Allowed.")
        elif fmt is WriterTurn:
            first = re.search(r"Buyer: (\w+)", text).group(1)
            msg = f"Hi {first}, short note from Santa Fe Rústicos: dining from $80 wholesale. Worth a call?\n\nYago"
            if "LinkedIn connection note" in text:
                msg = f"Hi {first}, I work with a Mexican furniture maker."
            out = WriterTurn(subject="Dining for your stores", message=msg, playbook_used=[1])
        elif fmt is Grade:
            out = grade(3 if "Rooms To Go" in text or "BIFMA" in text else 9)
        elif fmt is mailer.ReplySort:
            t = text.lower()
            cat = ("interested" if re.search(r"send|catalog|interesa|sample", t) else "not_now" if "spring" in t or "summer" in t
                   else "question" if "?" in t else "wrong_person" if "buyer" in t else "not_interested")
            out = mailer.ReplySort(category=cat, summary="x")
        elif fmt is strategy.Handoff:
            out = strategy.Handoff(headline="Wants a catalog.", qualified=True,
                                   checks=[strategy.Check(key=k, status="yes", evidence="x") for k in
                                           ["interest", "product_fit", "authority", "timing", "terms"]],
                                   interest="Catalog", product_fit="Dining", open_questions=["Freight"], next_steps=["Send catalog", "Call"],
                                   agenda=["Range", "Terms", "Samples"])
        elif fmt is team.ReportText:
            out = team.ReportText(headline="A week of outreach.", summary="We kept going. No emails went out in the quiet week.",
                                  highlights=["Steady work"], next_week=["More of the same"])
        elif fmt is team.ProspectBrief:
            out = team.ProspectBrief(summary="Could not find this business.", facts=[], angle="-", cautions="Nothing confirmed.", fit=1)
        elif fmt is BuyerTurn:
            out = BuyerTurn(private_thoughts="meh", action="ignore", reply=None, outcome="no_reply")
        elif fmt is WeakSpots:
            out = WeakSpots(summary="-", weak_spots=["-"], suggested_changes=["-"])
        else:
            raise AssertionError(fmt)
        return NS(model=kw["model"], usage=usage(), stop_reason="end_turn", parsed_output=out)

    class Stream:
        def __init__(self, **kw): self.kw = kw
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def get_final_message(self):
            return NS(model=self.kw["model"], usage=usage(), stop_reason="end_turn",
                      content=[NS(type="text", text="I could not find this business anywhere.", citations=None)])

    return NS(beta=NS(messages=NS(parse=parse, stream=lambda **kw: Stream(**kw))))


def main():
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        sys.exit("Set TEST_DATABASE_URL to a throwaway local database (see this file's header).")
    assert not is_local("postgresql://postgres.x:pw@aws-0-us-east-1.pooler.supabase.com:5432/postgres")
    assert not is_local("postgresql://u:p@db.example.com/postgres") and is_local("postgresql:///x")
    print("ok: the sandbox refuses Supabase and any hosted database")

    out = pathlib.Path(tempfile.mkdtemp())
    playbook = [{"title": "Keep it short", "body": "Short.", "channel": "email", "buyer_types": [], "stage": None}]
    res = B.run(fake_ai(), url, playbook, out, [], budget=50, workers=3, log=lambda m: None)
    st = res["stages"]
    assert not res.get("errors"), res.get("errors")
    for k in ["supervisor", "strategist", "writer", "grader", "sorter", "briefer", "reporter", "researcher", "practice"]:
        assert k in st, f"stage {k} missing"
    bad = [x for x in st["supervisor"]["rows"] if not x["passed"]]
    assert [x["check"] for x in bad] == ["No email is drafted to a buyer the email rules do not allow yet (it could never be approved)"], bad
    print(f"ok: supervisor and safety-gate checks pass, except the known MX email-draft gap ({st['supervisor']['right']})")
    assert st["strategist"]["decisions_right"] == f"{len(LEADS)}/{len(LEADS)}", st["strategist"]["decisions_right"]
    kinds = {d["kind"] for d in res["drafts"]}
    assert {"first", "reply", "follow_up", "check_in"} <= kinds, kinds
    assert any(d["channel"] == "linkedin" for d in res["drafts"])
    print(f"ok: the pipeline produced first messages, LinkedIn notes, answers, a follow-up and a check-in ({len(res['drafts'])} drafts)")
    assert list((out / "mail").glob("*.eml")), "dry-run emails should be written to the output folder"
    assert st["briefer"]["right"] == "1/1", st["briefer"]
    g = {r["id"]: r for r in st["grader"]["rows"]}
    assert g["trap-past-customer"]["ok"] and g["trap-fake-cert"]["ok"] and g["good-1"]["ok"] and not g["trap-wrong-moq"]["ok"]
    print("ok: the Grader stage scores traps and good drafts")
    assert st["researcher"]["honest"] == "3/3" and st["reporter"]["right"] == "4/4", (st["researcher"], st["reporter"])
    print("ok: researcher (no invented facts) and reporter (numbers from the data) are scored")
    assert B.leak("Our maker supplies Rooms To Go.") and B.leak("one of the top 5 US furniture chains") and not B.leak("Dear Dana")
    assert B.unsupported_numbers("Dining from $45, 40% margin, 25 stores", "prices $80 to $390") == ["$45", "25", "40%"]
    assert B.unsupported_numbers("$120 tables, 20 pieces per model", "20 pieces") == []
    md = B.report(res)
    assert "| Strategist |" in md and "## Grader: planted drafts" in md
    print(f"ok: report written ({len(md.splitlines())} lines); fake cost ${res['cost_usd']}")
    print("All benchmark tests passed.")


if __name__ == "__main__":
    main()
