"""The Researcher: studies sales research on the web and drafts playbook entries.

For each topic in research_topics.json it:
  1. searches and reads credible sources (studies, papers, large data sets),
  2. turns its notes into short playbook entries in our own words, each with sources,
  3. keeps only sources it actually opened, so no source is made up.

Nothing it writes goes live. Entries are saved as 'draft'; a person approves them.

Run:  python -m agents.researcher                  (all topics)
      python -m agents.researcher --only cold-email-first-touch
Outputs land in out/research/<date>/ : a readable playbook_draft.md for review,
playbook_draft.sql to load the drafts into Supabase, and the raw notes.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import sys
from typing import List, Literal, Optional

from pydantic import BaseModel, Field

from .common import FALLBACK_BETA, MODEL, Usage, client

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOPICS_FILE = pathlib.Path(__file__).with_name("research_topics.json")

# Values must match the enums in db/migrations/0001_core.sql.
Channel = Literal["email", "linkedin", "call", "sms", "meeting", "form", "ad", "other"]
BuyerType = Literal[
    "retailer", "design_firm", "hospitality", "builder", "distributor", "dealer", "contract", "other"
]
Stage = Literal["conversation", "sample", "quote", "first_order", "repeat", "lost"]

RESEARCH_SYSTEM = """You are the research analyst for SBM Partners, a company that finds wholesale
buyers (independent retailers, interior designers, hotels and hospitality groups, dealers,
distributors) for brands that make furniture, lighting, decor and similar collections, and reaches
out to them by email, LinkedIn and phone.

Your job is to find out what actually works, based on evidence. Search the web and read sources.

Which sources to trust, best first:
1. Peer-reviewed studies and academic papers (psychology, marketing, management journals).
2. Large data sets with a stated method and sample size (for example analyses of millions of
   emails or thousands of recorded calls), from organizations that publish their methods.
3. Official sources for laws and regulations.
4. Well-known books by researchers.
Treat vendor blog posts with no method, "top 10 tips" listicles, and anonymous opinions as weak.
Prefer recent work (2015 onward) but keep classic studies that have been replicated.

Be honest about evidence: note sample sizes, note when a finding failed to replicate or comes from
a company selling a product, and say plainly when the evidence is thin or conflicting.
Never copy text from a source; summarize in your own words.

Finish with research notes: the findings, each tied to the source URL it came from, and a list of
open questions or conflicting findings."""

DISTILL_SYSTEM = """You turn research notes into playbook entries for B2B sales agents at SBM
Partners. Each entry is one tactic an agent can apply, written in plain, original language (never
copied from a source). Only use findings and URLs that appear in the notes. Rate evidence honestly:
'strong' = replicated studies or very large data with a clear method; 'moderate' = one good study or
large data from an interested party; 'weak' = expert opinion or small samples. Include caveats.
Write 3 to 6 entries per topic, fewer if the evidence only supports fewer."""


class Source(BaseModel):
    title: str
    url: str
    finding: str = Field(description="What this source found, in one sentence, own words")
    kind: Literal["peer_reviewed", "large_dataset", "official", "book", "industry_report", "other"]
    year: Optional[int] = None


class Entry(BaseModel):
    title: str = Field(description="Short name of the tactic, under 10 words")
    body: str = Field(description="The tactic in our own words, 40-120 words")
    example: str = Field(description="A short example of how an agent would use it with a buyer")
    channel: Optional[Channel] = Field(description="Channel it applies to, or null for any")
    buyer_types: List[BuyerType] = Field(description="Buyer types it applies to; empty = all")
    stage: Optional[Stage] = Field(description="Deal stage it applies to, or null for any")
    evidence_strength: Literal["strong", "moderate", "weak"]
    caveats: str = Field(description="Limits, risks, or when not to use it")
    sources: List[Source]


class TopicDraft(BaseModel):
    summary: str = Field(description="2-3 sentence summary of what the evidence says")
    entries: List[Entry]
    open_questions: List[str]


def research(c, usage: Usage, topic: dict) -> tuple[str, set[str]]:
    """Step 1: search and read. Returns the notes and every URL the agent actually retrieved."""
    messages = [{"role": "user", "content": f"Research question: {topic['question']}"}]
    tools = [
        {"type": "web_search_20260209", "name": "web_search", "max_uses": 12},
        {"type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 10},
    ]
    seen: set[str] = set()
    text_parts: list[str] = []
    for _ in range(6):  # a long research turn may pause; resume it a few times at most
        with c.beta.messages.stream(
            model=MODEL,
            max_tokens=32000,
            system=RESEARCH_SYSTEM,
            messages=messages,
            tools=tools,
            output_config={"effort": "high"},
            betas=[FALLBACK_BETA],
            fallbacks="default",
        ) as stream:
            msg = stream.get_final_message()
        usage.add(msg)
        for block in msg.content:
            if block.type == "text":
                text_parts.append(block.text)
            # Results the server returned (search hits, fetched pages) and citations. Not the
            # agent's own tool requests: asking for a URL doesn't prove the page was read.
            if block.type not in ("text", "server_tool_use", "thinking") or getattr(block, "citations", None):
                _collect_urls(block, seen)
        if msg.stop_reason == "refusal":
            raise RuntimeError(f"Research declined for topic {topic['id']}")
        if msg.stop_reason != "pause_turn":
            break
        messages.append({"role": "assistant", "content": msg.content})
    return "\n".join(text_parts).strip(), seen


def _collect_urls(obj, seen: set[str]) -> None:
    """Every URL inside a tool result or citation: these are pages the agent really retrieved."""
    if hasattr(obj, "model_dump"):
        obj = obj.model_dump()
    elif hasattr(obj, "__dict__"):
        obj = vars(obj)
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "url" and isinstance(v, str):
                seen.add(v)
            else:
                _collect_urls(v, seen)
    elif isinstance(obj, list):
        for v in obj:
            _collect_urls(v, seen)


def distill(c, usage: Usage, topic: dict, notes: str) -> TopicDraft:
    """Step 2: turn the notes into structured playbook entries."""
    hints = []
    if topic.get("channel"):
        hints.append(f"Default channel: {topic['channel']}.")
    if topic.get("stage"):
        hints.append(f"Default stage: {topic['stage']}.")
    if topic.get("buyer_types"):
        hints.append(f"Default buyer types: {', '.join(topic['buyer_types'])}.")
    resp = c.beta.messages.parse(
        model=MODEL,
        max_tokens=16000,
        system=DISTILL_SYSTEM,
        messages=[{
            "role": "user",
            "content": f"Topic: {topic['question']}\n{' '.join(hints)}\n\n<notes>\n{notes}\n</notes>",
        }],
        output_format=TopicDraft,
        output_config={"effort": "medium"},
        betas=[FALLBACK_BETA],
        fallbacks="default",
    )
    usage.add(resp)
    if resp.stop_reason == "refusal" or resp.parsed_output is None:
        raise RuntimeError(f"Could not turn notes into entries for topic {topic['id']}")
    return resp.parsed_output


def _norm(url: str) -> str:
    return url.split("#")[0].rstrip("/").lower()


def keep_verified_sources(draft: TopicDraft, seen: set[str]) -> int:
    """Drop any source the agent didn't actually open, and entries left with no source."""
    seen_n = {_norm(u) for u in seen}
    dropped = 0
    kept_entries = []
    for e in draft.entries:
        before = len(e.sources)
        e.sources = [s for s in e.sources if _norm(s.url) in seen_n]
        dropped += before - len(e.sources)
        if e.sources:
            kept_entries.append(e)
    draft.entries = kept_entries
    return dropped


def _sql(s: Optional[str]) -> str:
    return "null" if s is None else "'" + s.replace("'", "''") + "'"


def to_sql(results: list[tuple[dict, TopicDraft]], run_cost: float, usage: Usage) -> str:
    lines = [
        "-- Draft playbook entries from the Researcher. Safe to run: everything is saved as 'draft'.",
        "-- Nothing reaches the sales agents until a person sets status = 'active'.",
        "begin;",
        "insert into agents (name, role, model, prompt_version) values "
        f"('researcher', 'researcher', {_sql(MODEL)}, 'v1') on conflict (name) do nothing;",
    ]
    for topic, draft in results:
        for e in draft.entries:
            body = f"{e.body}\n\nExample: {e.example}\n\nCaveats: {e.caveats}"
            evidence = {
                "topic": topic["id"],
                "strength": e.evidence_strength,
                "sources": [s.model_dump() for s in e.sources],
            }
            buyer_types = "'{" + ",".join(e.buyer_types) + "}'::buyer_type[]"
            lines.append(
                "insert into playbook_entries (title, body, channel, buyer_types, stage, status, evidence, created_by) values ("
                f"{_sql(e.title)}, {_sql(body)}, {_sql(e.channel)}::channel, {buyer_types}, "
                f"{_sql(e.stage)}::deal_stage, 'draft', {_sql(json.dumps(evidence))}::jsonb, 'researcher');"
            )
    summary = f"Drafted {sum(len(d.entries) for _, d in results)} playbook entries on {len(results)} topics."
    lines.append(
        "insert into agent_runs (agent_id, finished_at, status, input_tokens, output_tokens, cost_cents, summary) "
        f"select id, now(), 'ok', {usage.input_tokens}, {usage.output_tokens}, {round(run_cost * 100, 2)}, {_sql(summary)} "
        "from agents where name = 'researcher';"
    )
    lines.append("commit;")
    return "\n".join(lines) + "\n"


def to_markdown(results: list[tuple[dict, TopicDraft]], usage: Usage, day: str) -> str:
    out = [
        f"# Draft sales playbook ({day})",
        "",
        "Written by the Researcher agent. **Nothing here is live yet.** Mark what you like and what "
        "you don't; only approved entries are used by the sales agents.",
        "",
        "Evidence strength: **strong** = replicated studies or very large data; **moderate** = one good "
        "study or company data; **weak** = expert opinion or small samples.",
        "",
        f"Run cost: about ${usage.cost_usd} ({usage.web_searches} web searches).",
        "",
    ]
    n = 0
    for topic, draft in results:
        out += [f"## {topic['question']}", "", draft.summary, ""]
        for e in draft.entries:
            n += 1
            tags = ", ".join(x for x in [e.channel or "any channel", e.stage or "any stage",
                                         "/".join(e.buyer_types) or "all buyers"])
            out += [
                f"### {n}. {e.title}",
                f"*Evidence: {e.evidence_strength} · {tags}*",
                "",
                e.body,
                "",
                f"**Example:** {e.example}",
                "",
                f"**Caveats:** {e.caveats}",
                "",
                "**Sources:**",
            ]
            out += [f"- [{s.title}]({s.url}){f' ({s.year})' if s.year else ''}: {s.finding}" for s in e.sources]
            out.append("")
        if draft.open_questions:
            out += ["**Open questions:**"] + [f"- {q}" for q in draft.open_questions] + [""]
    return "\n".join(out)


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", nargs="*", help="topic ids to run (default: all)")
    ap.add_argument("--out", default=None, help="output folder (default: out/research/<date>)")
    args = ap.parse_args(argv)

    topics = json.loads(TOPICS_FILE.read_text())
    if args.only:
        topics = [t for t in topics if t["id"] in set(args.only)]
        if not topics:
            raise SystemExit("No matching topic ids. See agents/research_topics.json.")

    day = dt.date.today().isoformat()
    out_dir = pathlib.Path(args.out) if args.out else ROOT / "out" / "research" / day
    out_dir.mkdir(parents=True, exist_ok=True)

    c = client()
    usage = Usage()
    results: list[tuple[dict, TopicDraft]] = []
    for i, topic in enumerate(topics, 1):
        print(f"[{i}/{len(topics)}] Researching: {topic['id']} ...", flush=True)
        try:
            notes, seen = research(c, usage, topic)
            (out_dir / f"notes_{topic['id']}.md").write_text(notes)
            draft = distill(c, usage, topic, notes)
        except Exception as exc:  # keep going; one bad topic shouldn't lose the rest
            print(f"    skipped: {exc}", file=sys.stderr)
            continue
        dropped = keep_verified_sources(draft, seen)
        results.append((topic, draft))
        print(f"    {len(draft.entries)} entries, {dropped} unverified sources removed, "
              f"running cost ${usage.cost_usd}", flush=True)

    (out_dir / "playbook_draft.json").write_text(
        json.dumps([{"topic": t, "draft": d.model_dump()} for t, d in results], indent=2)
    )
    (out_dir / "playbook_draft.md").write_text(to_markdown(results, usage, day))
    (out_dir / "playbook_draft.sql").write_text(to_sql(results, usage.cost_usd, usage))
    print(f"\nDone. {sum(len(d.entries) for _, d in results)} draft entries. Cost about ${usage.cost_usd}.")
    print(f"Read:  {out_dir / 'playbook_draft.md'}")
    print(f"Load into Supabase (as drafts): {out_dir / 'playbook_draft.sql'}")


if __name__ == "__main__":
    main()
