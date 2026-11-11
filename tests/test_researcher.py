"""Offline test of the Researcher: a fake AI client stands in for the real one, so no key or
money is needed. Checks that made-up sources are dropped and the outputs are written.
Run: python -m tests.test_researcher   (set TEST_DATABASE_URL to also load the SQL into Postgres)
"""
import json
import os
import pathlib
import subprocess
import tempfile
from types import SimpleNamespace as NS
from unittest import mock

from agents import researcher
from agents.researcher import Entry, Source, TopicDraft

REAL = "https://example.org/study-2021"
FAKE = "https://made-up.example.com/never-opened"


def usage():
    return NS(input_tokens=1000, output_tokens=500, cache_creation_input_tokens=0,
              cache_read_input_tokens=0, server_tool_use=NS(web_search_requests=3))


class FakeStream:
    def __init__(self, msg): self.msg = msg
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def get_final_message(self): return self.msg


def fake_client():
    search_msg = NS(model="claude-opus-5-5", stop_reason="end_turn", usage=usage(), content=[
        NS(type="web_search_tool_result", content=[NS(url=REAL, title="A study")]),
        NS(type="text", text="Notes: short emails got more replies (n=10,000). Source: " + REAL, citations=None),
    ])
    draft = TopicDraft(summary="Short emails do better.", open_questions=["Does it hold for hotels?"], entries=[
        Entry(title="Keep it under 100 words", body="Short first emails get more replies.",
              example="Hi Ana, we make oak side tables. Worth a sample?", channel="email",
              buyer_types=["retailer"], stage="conversation", evidence_strength="moderate",
              caveats="O'Brien's caveat: 'one' study.",
              sources=[Source(title="A study", url=REAL + "/", finding="Shorter wins", kind="large_dataset", year=2021),
                       Source(title="Ghost", url=FAKE, finding="x", kind="other")]),
        Entry(title="Only fake sources", body="b", example="e", channel=None, buyer_types=[], stage=None,
              evidence_strength="weak", caveats="c", sources=[Source(title="Ghost", url=FAKE, finding="x", kind="other")]),
    ])
    parse_msg = NS(model="claude-opus-5-5", stop_reason="end_turn", usage=usage(), parsed_output=draft)
    beta = NS(messages=NS(stream=lambda **kw: FakeStream(search_msg), parse=lambda **kw: parse_msg))
    return NS(beta=beta)


def main():
    out = pathlib.Path(tempfile.mkdtemp())
    with mock.patch.object(researcher, "client", fake_client):
        researcher.main(["--only", "cold-email-first-touch", "--out", str(out)])

    data = json.loads((out / "playbook_draft.json").read_text())
    entries = data[0]["draft"]["entries"]
    assert len(entries) == 1, "entry with only made-up sources must be dropped"
    assert [s["url"] for s in entries[0]["sources"]] == [REAL + "/"], "made-up source must be dropped"
    md = (out / "playbook_draft.md").read_text()
    assert "Keep it under 100 words" in md and FAKE not in md
    sql = (out / "playbook_draft.sql").read_text()
    assert "'draft'" in sql and "O''Brien" in sql

    db = os.environ.get("TEST_DATABASE_URL")
    if db:
        subprocess.run(["psql", db, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(out / "playbook_draft.sql")], check=True)
        res = subprocess.run(["psql", db, "-X", "-At", "-c",
                              "select count(*) || ' ' || min(status::text) from playbook_entries where created_by='researcher'"],
                             check=True, capture_output=True, text=True).stdout.strip()
        assert res == "1 draft", res
        print("SQL loaded into Postgres OK:", res)
    print("All Researcher checks passed.")


if __name__ == "__main__":
    main()
