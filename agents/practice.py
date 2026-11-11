"""Practice round: a sales Writer works against Mock buyers, and a strict Grader scores each exchange.

One exchange:
  1. the Writer sends a first message to a mock buyer (email, LinkedIn or a call opener),
  2. the Mock buyer reacts the way a real one would: ignores it, pushes back, asks, or says yes,
  3. if ignored, the Writer sends one follow-up; if answered, the Writer replies (up to 3 Writer turns),
  4. the Grader scores the Writer from 0 to 100 against rubric.json and says what to fix.

The Writer only uses APPROVED playbook entries: from the database (DATABASE_URL, status 'active') or,
without a database connection, from the latest playbook_draft.json the Researcher wrote.

Run:  python -m agents.practice                 (50 exchanges, stops early if it passes --budget)
      python -m agents.practice --n 10 --budget 5
Outputs land in out/practice/<time>/: report.md to read, results.json, and practice.sql to save the
exchanges and grades into Supabase (pasted in the SQL Editor, or loaded automatically with DATABASE_URL).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import random
import statistics
import sys
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Literal, Optional

from pydantic import BaseModel, Field

from .common import FALLBACK_BETA, MODEL, Usage, client

ROOT = pathlib.Path(__file__).resolve().parent.parent
HERE = pathlib.Path(__file__).resolve().parent

WRITER_MODEL = os.environ.get("SBM_WRITER_MODEL", MODEL)          # the agent being trained
GRADER_MODEL = os.environ.get("SBM_GRADER_MODEL", MODEL)          # judgment matters: best model
BUYER_MODEL = os.environ.get("SBM_BUYER_MODEL", "claude-sonnet-5-5")  # plays the buyer; cheaper is fine
MAX_WRITER_TURNS = 3


# ─────────────────────────── structured outputs ───────────────────────────
class WriterTurn(BaseModel):
    subject: Optional[str] = Field(description="Email subject line, or null for LinkedIn and calls")
    message: str = Field(description="Exactly what the buyer receives (or hears, for a call opener)")
    playbook_used: List[int] = Field(description="Numbers of the playbook entries this message applies")


class BuyerTurn(BaseModel):
    private_thoughts: str = Field(description="What you honestly think, which the seller never sees")
    action: Literal["ignore", "reply"]
    reply: Optional[str] = Field(description="Your reply to the seller, or null if you ignore it")
    outcome: Literal["no_reply", "negative", "neutral", "positive", "meeting"] = Field(
        description="Where things stand after this message")


class CriterionScore(BaseModel):
    key: str
    score: Optional[int] = Field(description="0-10, or null if it does not apply")
    why: str


class Grade(BaseModel):
    criteria: List[CriterionScore]
    feedback: str = Field(description="2-4 sentences on what worked and what did not")
    top_fix: str = Field(description="The single most important change for next time")
    playbook_notes: str = Field(description="Which playbook entries were applied well, misapplied, or should have been used")


class WeakSpots(BaseModel):
    summary: str
    weak_spots: List[str] = Field(description="3-6 recurring problems, most important first")
    suggested_changes: List[str] = Field(description="Concrete changes to the Writer's instructions or the playbook")


# ─────────────────────────── inputs ───────────────────────────
def load_playbook(path: Optional[str]) -> tuple[list[dict], str]:
    """Approved entries: from the database if DATABASE_URL is set, else from a playbook_draft.json."""
    if not path and os.environ.get("DATABASE_URL"):
        from .db import fetch_active_playbook
        rows = fetch_active_playbook()
        if rows:
            return rows, "database (status = active)"
        print("No active playbook entries in the database; falling back to the latest draft file.", file=sys.stderr)
    if path:
        f = pathlib.Path(path)
    else:
        files = sorted((ROOT / "out" / "research").glob("*/playbook_draft.json"), key=lambda p: p.stat().st_mtime)
        if not files:
            raise SystemExit("No playbook found. Run the Researcher first, or set DATABASE_URL.")
        f = files[-1]
    entries = []
    for topic in json.loads(f.read_text()):
        for e in topic["draft"]["entries"]:
            entries.append({"id": None, "title": e["title"], "body": e["body"], "example": e.get("example", ""),
                            "caveats": e.get("caveats", ""), "channel": e.get("channel"),
                            "buyer_types": e.get("buyer_types", []), "stage": e.get("stage")})
    return entries, str(f)


def playbook_text(entries: list[dict]) -> str:
    out = []
    for i, e in enumerate(entries, 1):
        tags = ", ".join(x for x in [e.get("channel") or "any channel", e.get("stage") or "any stage",
                                     "/".join(e.get("buyer_types") or []) or "all buyers"])
        body = e["body"]
        if e.get("example"):
            body += f"\nExample: {e['example']}"
        if e.get("caveats"):
            body += f"\nCaveats: {e['caveats']}"
        out.append(f"[{i}] {e['title']} ({tags})\n{body}")
    return "\n\n".join(out)


# ─────────────────────────── prompts ───────────────────────────
WRITER_SYSTEM = """You are a B2B sales representative at SBM Partners, reaching out to wholesale buyers on
behalf of a client brand. Your work is graded, so do it the way a top professional would.

Rules:
- Use ONLY facts in the client brief. Never invent customers, numbers, awards, scarcity or deadlines.
- Apply the approved playbook below. Pick the entries that fit this buyer, channel and stage, and list
  their numbers in playbook_used.
- Write for this specific buyer type: what they worry about, how they buy, what they need to say yes.
- Keep it short and human. One clear, low-effort next step.
- Emails identify the sender and end with the brief's opt-out line. A call opener is what you would
  say in the first 30 seconds.

<client_brief>
{brief}
</client_brief>

<approved_playbook>
{playbook}
</approved_playbook>"""

BUYER_SYSTEM = """You are role-playing a real wholesale buyer receiving sales outreach. Stay in character.

<who_you_are>
{name} ({buyer_type}).
{profile}
</who_you_are>

Be realistic, not kind. Real buyers ignore most cold outreach: reply only if THIS message would
genuinely earn a reply from someone like you today. Generic, long, pushy or irrelevant messages get
ignored or a short no. If you reply, write like a busy professional (often brief), and raise the
questions and objections you would really have. Agree to a meeting or samples only if earned.
Your private_thoughts are your honest reaction, which the seller never sees."""

GRADER_SYSTEM = """You are a strict sales coach grading a B2B sales representative's practice exchange
with a mock buyer. Grade only the representative (the "writer" turns), not the buyer.

<rubric>
{rubric}
</rubric>

Be demanding: 9-10 means excellent work a top professional would be proud of; 5 is mediocre. A buyer
ignoring a message is not automatically the writer's fault, and a reply is not automatically good
work; judge the messages themselves for this buyer. Check every fact against the client brief:
anything not in the brief is invented and lowers honesty.

<client_brief>
{brief}
</client_brief>

<playbook_titles>
{titles}
</playbook_titles>"""


# ─────────────────────────── one exchange ───────────────────────────
class Practice:
    def __init__(self, c, usage: Usage, playbook: list[dict], rubric: dict, brief: dict):
        self.c, self.usage, self.rubric, self.brief = c, usage, rubric, brief
        self.lock = threading.Lock()
        brief_txt = json.dumps({k: v for k, v in brief.items() if not k.startswith("_")}, indent=1)
        # Big, unchanging prompts are cached, so each call after the first pays ~10% for them.
        self.writer_system = [{"type": "text", "cache_control": {"type": "ephemeral"},
                               "text": WRITER_SYSTEM.format(brief=brief_txt, playbook=playbook_text(playbook))}]
        self.grader_system = [{"type": "text", "cache_control": {"type": "ephemeral"},
                               "text": GRADER_SYSTEM.format(
                                   rubric=json.dumps(rubric, indent=1), brief=brief_txt,
                                   titles="\n".join(f"[{i}] {e['title']}" for i, e in enumerate(playbook, 1)))}]

    def _parse(self, model, system, content, fmt, effort):
        resp = self.c.beta.messages.parse(
            model=model, max_tokens=16000, system=system,
            messages=[{"role": "user", "content": content}],
            output_format=fmt, output_config={"effort": effort},
            betas=[FALLBACK_BETA], fallbacks="default",
        )
        with self.lock:
            self.usage.add(resp)
        if resp.parsed_output is None:
            raise RuntimeError(f"{fmt.__name__}: no usable answer (stop reason {resp.stop_reason})")
        return resp.parsed_output

    @staticmethod
    def _transcript_text(transcript: list[dict]) -> str:
        lines = []
        for t in transcript:
            if t["role"] == "writer":
                subj = f"[Subject: {t['subject']}]\n" if t.get("subject") else ""
                lines.append(f"WRITER:\n{subj}{t['text']}")
            elif t.get("action") == "ignore":
                lines.append(f"BUYER: (no reply)  [private: {t['private']}]")
            else:
                lines.append(f"BUYER:\n{t['text']}\n[private: {t['private']}]")
        return "\n\n".join(lines)

    def run(self, persona: dict) -> dict:
        channel = persona["channel"]
        transcript: list[dict] = []
        outcome = "no_reply"
        for turn in range(MAX_WRITER_TURNS):
            if turn == 0:
                task = f"Write your first {channel} message to this buyer."
            elif transcript[-1].get("action") == "ignore":
                task = f"The buyer did not reply. Write one short follow-up ({channel})."
            else:
                task = f"Reply to the buyer's last message ({channel})."
            history = self._transcript_text([{**t, "private": "(hidden)"} for t in transcript]) or "(none yet)"
            w = self._parse(WRITER_MODEL, self.writer_system,
                            f"Buyer: {persona['name']} ({persona['buyer_type']}).\n\nConversation so far:\n"
                            f"{history}\n\n{task}", WriterTurn, "medium")
            transcript.append({"role": "writer", "subject": w.subject, "text": w.message,
                               "playbook_used": w.playbook_used})

            b = self._parse(BUYER_MODEL, BUYER_SYSTEM.format(**persona),
                            f"Conversation so far ({channel}):\n\n{self._transcript_text(transcript)}\n\n"
                            "React to the seller's latest message.", BuyerTurn, "low")
            transcript.append({"role": "buyer", "action": b.action, "text": b.reply or "",
                               "private": b.private_thoughts})
            outcome = b.outcome if b.action == "reply" else ("no_reply" if outcome == "no_reply" else outcome)
            if outcome in ("negative", "meeting"):
                break
            if b.action == "ignore" and turn >= 1:   # ignored twice: stop, like a real rep would
                break

        g = self._parse(GRADER_MODEL, self.grader_system,
                        f"Buyer: {persona['name']} ({persona['buyer_type']}), channel: {channel}.\n"
                        f"Buyer profile: {persona['profile']}\n\n{self._transcript_text(transcript)}",
                        Grade, "medium")
        return {"id": str(uuid.uuid4()), "persona": persona["name"], "buyer_type": persona["buyer_type"],
                "channel": channel, "transcript": transcript, "outcome": outcome,
                "grade": g.model_dump(), "score": score(g, self.rubric)}


def score(g: Grade, rubric: dict) -> float:
    """Weighted 0-100 over the criteria that apply; capped at 40 if honesty is below 5."""
    weights = {c["key"]: c["weight"] for c in rubric["criteria"]}
    got = {c.key: c.score for c in g.criteria if c.key in weights and c.score is not None}
    if not got:
        return 0.0
    total = sum(weights[k] * min(max(v, 0), 10) / 10 for k, v in got.items()) / sum(weights[k] for k in got) * 100
    if got.get("honesty") is not None and got["honesty"] < 5:
        total = min(total, 40)
    return round(total, 1)


# ─────────────────────────── outputs ───────────────────────────
def _sql(s) -> str:
    return "null" if s is None else "'" + str(s).replace("'", "''") + "'"


def to_sql(results: list[dict], personas: list[dict], rubric: dict, usage: Usage) -> str:
    L = ["-- Practice round results: mock exchanges and their grades. Run each file once.",
         "-- It only adds rows to the agent tables (agents, rubrics, personas, simulations, grades, agent_runs).",
         "begin;",
         "insert into agents (name, role, model, prompt_version) values "
         f"('writer', 'writer', {_sql(WRITER_MODEL)}, 'v1'), ('mock_buyer', 'mock_buyer', {_sql(BUYER_MODEL)}, 'v1'), "
         f"('grader', 'grader', {_sql(GRADER_MODEL)}, 'v1') on conflict (name) do nothing;",
         f"insert into rubrics (name, version, criteria) values ({_sql(rubric['name'])}, {rubric['version']}, "
         f"{_sql(json.dumps(rubric['criteria']))}::jsonb) on conflict (name, version) do nothing;"]
    for p in personas:
        L.append(f"insert into personas (name, buyer_type, profile) values ({_sql(p['name'])}, "
                 f"{_sql(p['buyer_type'])}::buyer_type, {_sql(p['profile'])}) on conflict (name) do update set profile = excluded.profile;")
    for r in results:
        L.append("insert into simulations (id, persona_id, writer_agent_id, channel, transcript, outcome) select "
                 f"{_sql(r['id'])}, (select id from personas where name = {_sql(r['persona'])}), "
                 f"(select id from agents where name = 'writer'), {_sql(r['channel'])}::channel, "
                 f"{_sql(json.dumps(r['transcript']))}::jsonb, {_sql(r['outcome'])};")
        crit = {c["key"]: c["score"] for c in r["grade"]["criteria"]}
        fb = f"{r['grade']['feedback']}\nTop fix: {r['grade']['top_fix']}"
        L.append("insert into grades (subject, subject_id, rubric_id, grader_agent_id, score, criteria_scores, feedback) select "
                 f"'simulation', {_sql(r['id'])}, (select id from rubrics where name = {_sql(rubric['name'])} and version = {rubric['version']}), "
                 f"(select id from agents where name = 'grader'), {r['score']}, {_sql(json.dumps(crit))}::jsonb, {_sql(fb)};")
    avg = round(statistics.mean(r["score"] for r in results), 1) if results else 0
    L.append("insert into agent_runs (agent_id, finished_at, status, input_tokens, output_tokens, cost_cents, summary) "
             f"select id, now(), 'ok', {usage.input_tokens}, {usage.output_tokens}, {round(usage.cost_usd * 100, 2)}, "
             f"{_sql(f'Practice round: {len(results)} exchanges, average score {avg}')} from agents where name = 'writer';")
    L.append("commit;")
    return "\n".join(L) + "\n"


def to_report(results: list[dict], weak: Optional[WeakSpots], rubric: dict, usage: Usage, source: str, failed: int) -> str:
    if not results:
        return "# Practice round\n\nNo exchanges finished.\n"
    scores = [r["score"] for r in results]
    n = len(results)
    replies = sum(1 for r in results if any(t["role"] == "buyer" and t.get("action") == "reply" for t in r["transcript"]))
    meetings = sum(1 for r in results if r["outcome"] == "meeting")
    positive = sum(1 for r in results if r["outcome"] in ("positive", "meeting"))
    out = [f"# Practice round report ({dt.date.today().isoformat()})", "",
           f"**Average score: {statistics.mean(scores):.0f} / 100** across {n} practice exchanges "
           f"(lowest {min(scores):.0f}, highest {max(scores):.0f}).", "",
           f"- Mock buyers replied in {replies} of {n} ({100 * replies / n:.0f}%), were positive in {positive}, "
           f"and agreed to a meeting or samples in {meetings}.",
           f"- Cost: about ${usage.cost_usd}." + (f" {failed} exchanges failed and were skipped." if failed else ""),
           f"- Playbook used: {source}", ""]
    if weak:
        out += ["## What to improve", "", weak.summary, "", "**Weak spots:**"] + [f"- {w}" for w in weak.weak_spots]
        out += ["", "**Suggested changes (nothing changes until you approve):**"] + [f"- {s}" for s in weak.suggested_changes] + [""]
    out += ["## Scores by buyer type", "", "| Buyer | Exchanges | Average |", "|---|---|---|"]
    for name in sorted({r["persona"] for r in results}):
        s = [r["score"] for r in results if r["persona"] == name]
        out.append(f"| {name} | {len(s)} | {statistics.mean(s):.0f} |")
    out += ["", "## Scores by skill (0-10)", "", "| Skill | Average |", "|---|---|"]
    for c in rubric["criteria"]:
        vals = [x["score"] for r in results for x in r["grade"]["criteria"] if x["key"] == c["key"] and x["score"] is not None]
        if vals:
            out.append(f"| {c['key']}: {c['description']} | {statistics.mean(vals):.1f} |")
    ranked = sorted(results, key=lambda r: r["score"])

    def show(r):
        lines = [f"### {r['persona']} ({r['channel']}): {r['score']:.0f}/100, outcome: {r['outcome']}", ""]
        for t in r["transcript"]:
            if t["role"] == "writer":
                subj = f"*Subject: {t['subject']}*  \n" if t.get("subject") else ""
                lines += ["**Writer:**  ", subj + t["text"].replace("\n", "  \n"), ""]
            elif t.get("action") == "ignore":
                lines += [f"**Buyer:** *(no reply; thinking: {t['private']})*", ""]
            else:
                lines += [f"**Buyer:** {t['text']}  ", f"*(thinking: {t['private']})*", ""]
        lines += [f"**Grader:** {r['grade']['feedback']}", "", f"**Top fix:** {r['grade']['top_fix']}", ""]
        return lines

    out += ["", "## Best exchanges", ""]
    for r in ranked[::-1][:3]:
        out += show(r)
    out += ["## Weakest exchanges", ""]
    for r in ranked[:3]:
        out += show(r)
    return "\n".join(out)


def summarize(c, usage: Usage, results: list[dict]) -> Optional[WeakSpots]:
    if not results:
        return None
    notes = "\n".join(f"- ({r['persona']}, {r['score']:.0f}) {r['grade']['top_fix']} | {r['grade']['playbook_notes']}"
                      for r in results)
    resp = c.beta.messages.parse(
        model=GRADER_MODEL, max_tokens=16000,
        system="You are a sales coach. From many graders' notes on practice exchanges, find the recurring "
               "problems and propose concrete fixes. Be specific and brief; plain language for a business owner.",
        messages=[{"role": "user", "content": f"Grader notes, one per exchange:\n{notes}"}],
        output_format=WeakSpots, output_config={"effort": "medium"},
        betas=[FALLBACK_BETA], fallbacks="default",
    )
    usage.add(resp)
    return resp.parsed_output


# ─────────────────────────── main ───────────────────────────
def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=50, help="number of practice exchanges (default 50)")
    ap.add_argument("--budget", type=float, default=15.0, help="stop starting new exchanges past this many dollars (default 15)")
    ap.add_argument("--playbook", help="playbook_draft.json to use instead of the database")
    ap.add_argument("--client", default=str(HERE / "sample_client.json"), help="client brief (default: made-up sample)")
    ap.add_argument("--workers", type=int, default=4, help="exchanges run at the same time (default 4)")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args(argv)

    playbook, source = load_playbook(args.playbook)
    personas = json.loads((HERE / "personas.json").read_text())
    rubric = json.loads((HERE / "rubric.json").read_text())
    brief = json.loads(pathlib.Path(args.client).read_text())
    rng = random.Random(args.seed)
    # Spread exchanges evenly across buyer types.
    plan = [personas[i % len(personas)] for i in range(args.n)]
    rng.shuffle(plan)

    out_dir = pathlib.Path(args.out) if args.out else ROOT / "out" / "practice" / dt.datetime.now().strftime("%Y-%m-%d_%H%M")
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Playbook: {len(playbook)} approved entries from {source}")

    c = client()
    usage = Usage()
    p = Practice(c, usage, playbook, rubric, brief)
    results: list[dict] = []
    failed = 0

    def one(persona):
        if usage.cost_usd >= args.budget:
            return None
        return p.run(persona)

    # The first exchange runs alone so the cached prompts are written once, then the rest run in parallel.
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        queue = list(plan)
        first = queue.pop(0) if queue else None
        futures = []
        if first:
            futures.append(pool.submit(one, first))
            try:
                r = futures.pop().result()
                if r:
                    results.append(r)
                    print(f"[1/{args.n}] {r['persona']}: {r['score']:.0f}/100, ${usage.cost_usd}", flush=True)
            except Exception as exc:
                failed += 1
                print(f"[1/{args.n}] failed: {exc}", file=sys.stderr)
        futures = [pool.submit(one, persona) for persona in queue]
        for f in as_completed(futures):
            try:
                r = f.result()
            except Exception as exc:
                failed += 1
                print(f"    an exchange failed: {exc}", file=sys.stderr)
                continue
            if r is None:
                continue
            results.append(r)
            print(f"[{len(results)}/{args.n}] {r['persona']}: {r['score']:.0f}/100, ${usage.cost_usd}", flush=True)

    if usage.cost_usd >= args.budget and len(results) < args.n:
        print(f"Stopped at the ${args.budget} budget after {len(results)} exchanges.")
    weak = None
    try:
        weak = summarize(c, usage, results)
    except Exception as exc:
        print(f"Could not write the improvement summary: {exc}", file=sys.stderr)

    (out_dir / "results.json").write_text(json.dumps(results, indent=2))
    (out_dir / "report.md").write_text(to_report(results, weak, rubric, usage, source, failed))
    sql = to_sql(results, personas, rubric, usage)
    (out_dir / "practice.sql").write_text(sql)
    saved = ""
    if os.environ.get("DATABASE_URL") and results:
        try:
            from .db import run_sql
            run_sql(sql)
            saved = " Saved to the database."
        except Exception as exc:
            saved = f" Could not save to the database ({exc}); paste practice.sql in the SQL Editor instead."
    avg = statistics.mean(r["score"] for r in results) if results else 0
    print(f"\nDone. {len(results)} exchanges, average score {avg:.0f}/100, cost about ${usage.cost_usd}.{saved}")
    print(f"Read:  {out_dir / 'report.md'}")


if __name__ == "__main__":
    main()
