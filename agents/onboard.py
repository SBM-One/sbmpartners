"""The Onboarder: drafts a client's fact sheet from their own catalog, price list or website.

The fact sheet is the only thing the Writer may state about a client, so it must be right. The Onboarder:
  * reads the PDFs you give it (catalog, price list, trade terms) and, if you give one, the client's website,
  * writes the fact sheet in the same shape as agents/sample_client.json, using only what those sources say,
  * lists every question it could not answer from them (minimums, lead times, freight…) so you can ask the client.

It is saved as a DRAFT on the client (clients.brief_draft). Nothing is written to buyers until a person approves it
on the dashboard's Clients page, which copies it into clients.brief.

Run:
  python -m agents.onboard --client "Alder & Oak" --file catalog.pdf --file prices.pdf --website https://alderandoak.com
  python -m agents.onboard --client "Alder & Oak" --file catalog.pdf --create     (adds the client if it is new)
Also writes out/onboarding/<client>.md so you can read it before opening the dashboard.
"""
from __future__ import annotations

import argparse
import base64
import json
import pathlib
import re
from typing import List, Optional

from pydantic import BaseModel, Field

from . import teamdb as db
from .common import FALLBACK_BETA, Usage, client

OUT = pathlib.Path("out") / "onboarding"
MAX_PDF_BYTES = 30 * 1024 * 1024


class FactSheet(BaseModel):
    brand: str = Field(description="The brand name as the client writes it")
    what_they_make: str = Field(description="Products, materials and where/how they are made. Only what the sources say.")
    collections: List[str] = Field(description="Named collections or product families, with one short line each")
    price_points: str = Field(description="Wholesale and retail prices exactly as stated, with currency. Empty if none given.")
    terms: str = Field(description="Minimums, lead times, freight, payment terms, as stated. Empty if none given.")
    trade_and_contract: str = Field(description="Trade/designer programs, contract-grade versions, certifications (FR, BIFMA…), "
                                                "spec sheets and CAD availability, as stated. Empty if none given.")
    proof: str = Field(description="Stockists, projects, press, awards, numbers, exactly as stated. Never round or embellish.")
    offer: str = Field(description="Any sample, opening-order or trial offer the sources state. Empty if none.")
    best_fit_buyers: str = Field(description="Which buyer types this suits (stores, designers, hotels, contract dealers…) and why, "
                                             "based only on the sources")
    sources_used: List[str] = Field(description="File names and URLs actually used")
    questions_for_client: List[str] = Field(description="Everything a buyer will ask that the sources do not answer, "
                                                        "e.g. opening-order minimum, lead time, EU freight, sample policy")


SYSTEM = """You prepare the fact sheet that SBM Partners' sales writers may use about a client brand. A writer may
state ONLY what is in this fact sheet, so accuracy matters more than completeness.

Rules:
- Use only what the provided documents and pages say. Never guess, generalise or fill gaps from general knowledge.
- Copy numbers, prices, dates and claims exactly, with their currency and unit. If two sources disagree, give both
  and add a question for the client.
- If a field is not covered, leave it empty and add a question to questions_for_client.
- No marketing adjectives that the sources do not use ("luxury", "sustainable", "handmade" only if stated).
- Write in plain, precise English."""


def _pdf_block(path: pathlib.Path) -> dict:
    data = path.read_bytes()
    if len(data) > MAX_PDF_BYTES:
        raise SystemExit(f"{path.name} is larger than 30 MB. Split it or export a lighter PDF.")
    return {"type": "document", "title": path.name,
            "source": {"type": "base64", "media_type": "application/pdf", "data": base64.standard_b64encode(data).decode()}}


def draft(c, files: List[pathlib.Path], website: Optional[str], usage: Usage, model: str) -> FactSheet:
    content: list = []
    for f in files:
        if f.suffix.lower() == ".pdf":
            content.append(_pdf_block(f))
        else:
            content.append({"type": "document", "title": f.name,
                            "source": {"type": "text", "media_type": "text/plain", "data": f.read_text(errors="replace")}})
    notes = ""
    if website:
        # First read the website (and a few of its own pages), then turn everything into the fact sheet.
        msgs = [{"role": "user", "content": [*content, {"type": "text", "text":
                 f"Read the client's website {website} (home, about, collections, trade/wholesale pages) and write "
                 "notes of every concrete fact about the brand, each with the URL it came from."}]}]
        tools = [{"type": "web_fetch_20250910", "name": "web_fetch", "max_uses": 8, "allowed_domains": [_domain(website)]}]
        for _ in range(4):
            with c.beta.messages.stream(model=model, max_tokens=32000, system=SYSTEM, messages=msgs, tools=tools,
                                        output_config={"effort": "medium"}, betas=[FALLBACK_BETA], fallbacks="default") as s:
                msg = s.get_final_message()
            usage.add(msg)
            notes += "\n".join(b.text for b in msg.content if b.type == "text")
            if msg.stop_reason != "pause_turn":
                break
            msgs.append({"role": "assistant", "content": msg.content})
    content.append({"type": "text", "text": "Write the client's fact sheet from the documents above"
                    + (f" and these website notes:\n<website_notes>\n{notes}\n</website_notes>" if notes else ".")})
    for _ in range(2):
        try:
            resp = c.beta.messages.parse(model=model, max_tokens=16000, system=SYSTEM,
                                         messages=[{"role": "user", "content": content}], output_format=FactSheet,
                                         output_config={"effort": "high"}, betas=[FALLBACK_BETA], fallbacks="default")
        except ValueError:
            continue
        usage.add(resp)
        if resp.parsed_output is not None:
            return resp.parsed_output
    raise RuntimeError("The fact sheet could not be drafted (no usable answer after a retry).")


def _domain(url: str) -> str:
    return re.sub(r"^https?://(www\.)?", "", url).split("/")[0]


def to_markdown(name: str, fs: FactSheet) -> str:
    d = fs.model_dump()
    lines = [f"# Fact sheet draft: {name}", "", "Approve it on the dashboard's Clients page. Until then no buyer is contacted.", ""]
    for k, v in d.items():
        if k == "questions_for_client":
            continue
        lines += [f"## {k.replace('_', ' ').capitalize()}", ""]
        lines += [f"- {x}" for x in v] if isinstance(v, list) else [v or "_Not in the sources._"]
        lines.append("")
    lines += ["## Questions for the client", ""] + [f"- {q}" for q in fs.questions_for_client]
    return "\n".join(lines) + "\n"


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--client", required=True, help="the client's name, exactly as in the clients table")
    ap.add_argument("--file", action="append", default=[], help="a catalog, price list or terms (PDF or text); repeatable")
    ap.add_argument("--website", help="the client's website (optional)")
    ap.add_argument("--create", action="store_true", help="add the client if it does not exist yet")
    args = ap.parse_args(argv)
    files = [pathlib.Path(f) for f in args.file]
    for f in files:
        if not f.exists():
            raise SystemExit(f"File not found: {f}")
    if not files and not args.website:
        raise SystemExit("Give at least one --file or a --website.")

    conn = db.connect()
    db.register_team(conn)
    row = db.one(conn, "select id from clients where name = %s", (args.client,))
    if not row and args.create:
        row = db.one(conn, "insert into clients (name, industry, status) values (%s, 'furniture', 'active') returning id",
                     (args.client,))
    if not row:
        raise SystemExit(f"No client named {args.client!r}. Check the name, or add --create.")
    if not db.can_work(conn, "researcher"):
        raise SystemExit("The Onboarder is paused or out of budget this month (dashboard: Today).")

    usage = Usage()
    model = db.TEAM["researcher"][1]
    print(f"Reading {len(files)} file(s){' and the website' if args.website else ''} with {model}…")
    try:
        fs = draft(client(), files, args.website, usage, model)
    except Exception:
        db.record_run(conn, "researcher", usage, f"fact sheet for {args.client}: failed", ok=False)
        raise
    db.record_run(conn, "researcher", usage, f"fact sheet draft for {args.client}")
    source = ", ".join([f.name for f in files] + ([args.website] if args.website else []))
    sheet = {**fs.model_dump(), "_note": "Drafted by the Onboarder from the client's own material. Approved fact sheets only."}
    db.all_rows(conn, "update clients set brief_draft = %s, brief_source = %s where id = %s",
                (db.jsonb(sheet), source, row["id"]))
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{re.sub(r'[^a-z0-9]+', '-', args.client.lower()).strip('-')}.md"
    path.write_text(to_markdown(args.client, fs))
    print(f"Draft saved for approval (cost about ${usage.cost_usd}). Read it: {path}")
    print(f"{len(fs.questions_for_client)} question(s) for the client are listed at the end.")


if __name__ == "__main__":
    main()
