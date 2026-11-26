"""Offline test of bench/mexico.py with a fake AI. No key, no cost, nothing sent.

  TEST_DATABASE_URL=postgresql:///sbm_mx python -m tests.test_mexico_run
"""
import json
import os
import pathlib
import sys
import tempfile
from types import SimpleNamespace as NS
from unittest import mock

from agents import strategy, team
from agents.practice import CriterionScore, Grade, WriterTurn
from bench import mexico as M


def usage():
    return NS(input_tokens=1000, output_tokens=200, cache_creation_input_tokens=0, cache_read_input_tokens=0, server_tool_use=None)


def fake_ai():
    def parse(**kw):
        fmt, text = kw["output_format"], kw["messages"][0]["content"]
        if fmt is team.ProspectBrief:
            out = team.ProspectBrief(summary="Big retailer.", facts=[], angle="Dining.", cautions="-", fit=4)
        elif fmt is strategy.Strategy:
            sc = 1 if ("Fibra" in text or "Galerías" in text) else 4
            out = strategy.Strategy(criteria=[strategy.Criterion(key=k, score=sc, why="x") for k in strategy.FIT_WEIGHTS],
                                    decision="pursue" if sc > 2 else "disqualify", reason="Because.", pitch_angle="Dining.",
                                    lead_with=["Dining"], proof_points=["FSC"], offer=None, objections=[], first_ask="Una llamada",
                                    channel_plan="email", channel_reason="Allowed.")
        elif fmt is team.ChannelPlan:
            out = team.ChannelPlan(steps=[team.PlanStep(day=0, channel="email", purpose="first email"),
                                          team.PlanStep(day=4, channel="whatsapp", purpose="WhatsApp")], why="x")
        elif fmt is WriterTurn:
            assert "Spanish (Mexico)" in kw["system"][0]["text"], "the Writer must see the Spanish rule"
            out = WriterTurn(subject="Comedores para sus tiendas",
                             message="Estimado equipo de Compras de Muebles: le escribo de parte de Santa Fe Rústicos, que fabrica "
                                     "muebles de madera para sus tiendas. ¿Le interesa una llamada?\n\nSantiago", playbook_used=[1])
        elif fmt is Grade:
            out = Grade(criteria=[CriterionScore(key=k, score=9, why="") for k in
                                  ["relevance", "value", "clarity", "ask", "tone", "honesty", "handling"]],
                        feedback="Bien.", top_fix="-", playbook_notes="")
        else:
            raise AssertionError(fmt)
        return NS(model=kw["model"], usage=usage(), stop_reason="end_turn", parsed_output=out)

    class Stream:
        def __init__(self, **kw): self.kw = kw
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def get_final_message(self):
            return NS(model=self.kw["model"], usage=usage(), stop_reason="end_turn",
                      content=[NS(type="text", text="Notes.", citations=None)])

    return NS(beta=NS(messages=NS(parse=parse, stream=lambda **kw: Stream(**kw))))


def main():
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        sys.exit("Set TEST_DATABASE_URL to a throwaway local database.")
    tmp = pathlib.Path(tempfile.mkdtemp())
    pb = tmp / "pb.json"
    pb.write_text(json.dumps([{"title": "Keep it short", "body": "Short.", "channel": "email", "buyer_types": [], "stage": None}]))
    with mock.patch("agents.common.client", fake_ai):
        M.main(["--playbook", str(pb), "--db", url, "--out", str(tmp / "out")])
    res = json.loads((tmp / "out" / "results.json").read_text())
    rows = res["rows"]
    assert len(rows) == 29 and not res["errors"], res["errors"]
    pursued = [r for r in rows if (r["strategy"] or {}).get("decision") == "pursue"]
    assert pursued and all(r["drafts"] for r in pursued)
    assert not any(r["drafts"] for r in rows if r not in pursued), "no draft for a buyer not marked pursue"
    d = pursued[0]["drafts"][0]
    assert d["checks"]["language"] == "es" and d["send_blockers"], d
    assert any("MX" in b for b in d["send_blockers"]), d["send_blockers"]
    assert all(sum(r["cost_usd"].values()) > 0 for r in rows), "every account has its cost"
    md = (tmp / "out" / "drafts_es.md").read_text()
    assert "Safety gate: HELD" in md and "fit score and pitch plan" in md and "channel plan" in md
    print(f"ok: {len(pursued)} pursued, {len(rows) - len(pursued)} not; drafts in Spanish, all held by the gate. Fake cost ${res['cost_usd']}")


if __name__ == "__main__":
    main()
