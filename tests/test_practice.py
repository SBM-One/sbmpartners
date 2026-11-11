"""Offline test of the practice round with a fake AI: no key, no cost.
Checks the exchange flow, scoring rules, report, and that practice.sql loads into Postgres
(set TEST_DATABASE_URL; the playbook is then read from the database's active entries).
Run: python -m tests.test_practice
"""
import json
import os
import pathlib
import subprocess
import tempfile
from types import SimpleNamespace as NS
from unittest import mock

from agents import practice
from agents.practice import BuyerTurn, CriterionScore, Grade, WeakSpots, WriterTurn


def usage():
    return NS(input_tokens=2000, output_tokens=300, cache_creation_input_tokens=0,
              cache_read_input_tokens=0, server_tool_use=None)


def fake_client():
    calls = {"buyer": 0, "broke_once": False}

    def parse(**kw):
        fmt = kw["output_format"]
        if fmt is BuyerTurn and not calls["broke_once"]:
            calls["broke_once"] = True  # a cut-off answer must be retried, not lose the exchange
            raise ValueError("1 validation error for BuyerTurn: Invalid JSON: EOF while parsing a string")
        if fmt is WriterTurn:
            out = WriterTurn(subject="Oak side tables for O'Neill's shop", message="Hi, short note. Not relevant? Reply no.", playbook_used=[1])
        elif fmt is BuyerTurn:
            calls["buyer"] += 1
            # every other exchange the buyer ignores twice; otherwise replies then books a meeting
            if calls["buyer"] % 3 == 1:
                out = BuyerTurn(private_thoughts="meh", action="ignore", reply=None, outcome="no_reply")
            elif calls["buyer"] % 3 == 2:
                out = BuyerTurn(private_thoughts="ok, curious", action="reply", reply="What are the minimums?", outcome="neutral")
            else:
                out = BuyerTurn(private_thoughts="good answer", action="reply", reply="Send samples.", outcome="meeting")
        elif fmt is Grade:
            out = Grade(criteria=[CriterionScore(key=k, score=8, why="fine") for k in
                                  ["relevance", "value", "clarity", "ask", "tone", "honesty"]] +
                        [CriterionScore(key="handling", score=None, why="n/a")],
                        feedback="Solid.", top_fix="Name a specific product.", playbook_notes="Used [1] well.")
        else:
            out = WeakSpots(summary="Mostly good.", weak_spots=["Too generic"], suggested_changes=["Name a product"])
        return NS(model=kw["model"], usage=usage(), stop_reason="end_turn", parsed_output=out)

    return NS(beta=NS(messages=NS(parse=parse)))


def test_score_rules():
    rubric = json.loads((pathlib.Path(practice.__file__).parent / "rubric.json").read_text())
    g = Grade(criteria=[CriterionScore(key=k, score=10, why="") for k in ["relevance", "value", "clarity", "ask", "tone"]]
              + [CriterionScore(key="handling", score=None, why=""), CriterionScore(key="honesty", score=3, why="")],
              feedback="", top_fix="", playbook_notes="")
    assert practice.score(g, rubric) == 40, "dishonesty must cap the score at 40"
    g.criteria[-1].score = 10
    assert practice.score(g, rubric) == 100, "a not-applicable criterion must not lower the score"


def main():
    test_score_rules()
    out = pathlib.Path(tempfile.mkdtemp())
    db = os.environ.get("TEST_DATABASE_URL")
    pb = out / "playbook_draft.json"
    pb.write_text(json.dumps([{"topic": {"id": "t"}, "draft": {"entries": [
        {"title": "Keep it short", "body": "Under 100 words.", "example": "e", "caveats": "c",
         "channel": "email", "buyer_types": [], "stage": None}]}}]))
    env = {"ANTHROPIC_API_KEY": "x"}
    args = ["--n", "6", "--workers", "2", "--seed", "1", "--out", str(out)]
    if db:
        env["DATABASE_URL"] = db
    else:
        args += ["--playbook", str(pb)]
    def count():
        if not db:
            return 0
        return int(subprocess.run(["psql", db, "-X", "-At", "-c", "select count(*) from simulations"],
                                  check=True, capture_output=True, text=True).stdout.strip())
    before = count()
    with mock.patch.dict(os.environ, env), mock.patch.object(practice, "client", fake_client):
        practice.main(args)

    results = json.loads((out / "results.json").read_text())
    assert len(results) == 6
    assert all(r["score"] == 80 for r in results), [r["score"] for r in results]
    assert any(r["outcome"] == "meeting" for r in results)
    for r in results:
        assert sum(t["role"] == "writer" for t in r["transcript"]) <= practice.MAX_WRITER_TURNS
    report = (out / "report.md").read_text()
    assert "Average score: 80 / 100" in report and "Weakest exchanges" in report
    if db:
        assert count() - before == 6
        print("Saved 6 exchanges to Postgres OK")

    # Budget: with a tiny budget, no exchange may start once the next one would not fit.
    out2 = pathlib.Path(tempfile.mkdtemp())
    with mock.patch.dict(os.environ, {"ANTHROPIC_API_KEY": "x"}), mock.patch.object(practice, "client", fake_client):
        practice.main(["--n", "20", "--workers", "4", "--budget", "0.5", "--playbook", str(pb), "--out", str(out2)])
    spent = json.loads((out2 / "results.json").read_text())
    assert 0 < len(spent) < 20, len(spent)
    print("All practice checks passed.")


if __name__ == "__main__":
    main()
