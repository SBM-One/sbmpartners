"""The reviewer's fixed safety checks. They run on every message after the AI grade, cost nothing, and a message
that fails one is sent back to the writer (and capped below the approval line if the rewrite fails too).

  confidential customers   names from the fact sheet's confidential list, or a hint at them ("a top-10 US chain")
  invented numbers         money, percentages and numbers of 20 or more that are not in the fact sheet or the research
  length and form          per channel (email, LinkedIn note, WhatsApp); no links in LinkedIn/WhatsApp openers;
                           no home-made opt-out line in emails (the Mailer adds it)
  language                 a buyer in a country whose language the fact sheet sets gets that language
The send rules themselves (do-not-contact, country email rules, the buyer's decision...) stay in the database's
safety gate (draft_blockers), which no screen or agent can get around.
"""
from __future__ import annotations

import json
import re
from typing import Optional

VEILED = re.compile(
    r"\btop[- ]?\d+\b[^.\n]{0,25}\b(chains?|retailers?|stores?)\b"
    r"|\b(largest|biggest|major|leading)\s+(u\.?s\.?\s+|american\s+|national\s+)?(furniture\s+)?(chains?|retailers?)\b"
    r"|\bnational\s+(furniture\s+)?chains?\b"
    r"|\b(las\s+)?(principales|mayores|m[aá]s\s+grandes)\s+(cadenas|minoristas|mueblerías|tiendas)\b"
    r"|\b(cadenas?|minoristas|tiendas|mueblerías)\s+((muy|m[aá]s)\s+)?(grandes|importantes|reconocidas)\s+(de|en)\s+(ee\.?\s?uu\.?|estados\s+unidos)"
    r"|\b(cadenas?|minoristas)\s+(estadounidenses|norteamericanas|de\s+ee\.?\s?uu\.?|de\s+estados\s+unidos)", re.I)
DEFAULT_CONFIDENTIAL = ["Rooms To Go", "Nebraska Furniture Mart", "Furniture Stores International", "Bob's Discount Furniture"]
MONEY = re.compile(r"\$\s?(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)\s*([kK]\b)?")
NUM = re.compile(r"(?<![\w.,])(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)(?![\w])")
URL = re.compile(r"https?://|www\.", re.I)
SPANISH = re.compile(r"\b(de|que|para|con|los|las|una|sus|nuestra|nuestro|muebles|usted|le|su|por)\b", re.I)
ENGLISH = re.compile(r"\b(the|and|with|your|our|we|you|for|furniture|would)\b", re.I)
LIMITS = {"email": {"first": 150, "follow_up": 110, "reply": 170, "check_in": 110}}   # words
CHARS = {"linkedin": 200, "whatsapp": 600}  # LinkedIn cuts connection notes at 200


def confidential_names(brief: dict) -> list[str]:
    names = list(brief.get("confidential_customers") or [])
    text = str(brief.get("confidential_never_mention") or "")
    for group in re.findall(r"\(([^)]*)\)", text):
        names += [n.strip() for n in group.split(",") if n.strip() and not n.strip().lower().startswith("e.g")]
    return names or DEFAULT_CONFIDENTIAL


def _name_pattern(name: str) -> str:
    words = [re.escape(w) for w in name.replace("'s", "").split()]
    full = r"\s*".join(words)
    if "'s" in name:   # "Bob's Discount Furniture" is also just "Bob's"
        return rf"\b{re.escape(name.split()[0].replace(chr(39) + 's', ''))}'?s\b|\b{full}\b"
    return rf"\b{full}\b"


def leaks(text: str, brief: Optional[dict] = None) -> list[str]:
    names = confidential_names(brief or {})
    past = re.compile("|".join(_name_pattern(n) for n in names), re.I)
    return [m.group(0) for m in past.finditer(text or "")] + [m.group(0) for m in VEILED.finditer(text or "")]


def nums(text: str) -> set[float]:
    out = set()
    for m in NUM.finditer(text or ""):
        try:
            out.add(float(m.group(1).replace(",", "")))
        except ValueError:
            pass
    return out


def unsupported_numbers(text: str, sources: str) -> list[str]:
    """Money amounts, percentages and numbers of 20 or more in `text` that appear nowhere in the sources."""
    have = nums(sources)
    bad = []
    for m in MONEY.finditer(text or ""):
        v = float(m.group(1).replace(",", "")) * (1000 if m.group(2) else 1)
        if v not in have:
            bad.append(m.group(0).strip())
    for m in re.finditer(r"(\d+(?:\.\d+)?)\s?%", text or ""):
        if float(m.group(1)) not in have:
            bad.append(m.group(0))
    for v in nums(re.sub(r"\$\s?\d[\d,]*(\.\d+)?|\d+(\.\d+)?\s?%", " ", text or "")):
        if v >= 20 and v not in have and not (1990 <= v <= 2030):
            bad.append(f"{v:g}")
    return sorted(set(bad))


def words(text: str) -> int:
    return len(re.findall(r"\b\w+\b", text or ""))


def language(text: str) -> str:
    es, en = len(SPANISH.findall(text or "")), len(ENGLISH.findall(text or ""))
    return "es" if es >= 2 * max(en, 1) else ("en" if en > es else "mixed")


def wants_spanish(brief: dict, country: Optional[str]) -> bool:
    rule = str(brief.get("outreach_language") or "")
    return country == "MX" and "spanish" in rule.lower() or (country in ("ES",) and "spanish" in rule.lower())


def check(message: str, subject: Optional[str], channel: str, purpose: str, brief: dict, sources: str,
          country: Optional[str] = None) -> list[str]:
    """Problems with one message, in plain words. An empty list means it passed."""
    text = f"{subject or ''}\n{message or ''}"
    problems = []
    found = leaks(text, brief)
    if found:
        problems.append(f"Mentions or hints at a confidential customer ({', '.join(sorted(set(found)))}). Remove it.")
    bad = unsupported_numbers(text, sources + json.dumps(brief, ensure_ascii=False))
    if bad:
        problems.append(f"Uses numbers that are not in the fact sheet or the research ({', '.join(bad)}). Remove or correct them.")
    if channel in CHARS:
        if len(message or "") > CHARS[channel]:
            problems.append(f"{len(message)} characters; a {channel} opener must stay under {CHARS[channel]}.")
        if URL.search(message or "") and purpose == "first":
            problems.append(f"Contains a link; a first {channel} message should not.")
    if channel == "email":
        limit = LIMITS["email"].get(purpose, 150)
        if words(message) > limit:
            problems.append(f"{words(message)} words; keep it to {limit} or fewer.")
        if re.search(r"unsubscribe|opt[- ]out|darse de baja|dar de baja", message or "", re.I):
            problems.append("Writes its own opt-out line; the Mailer adds it under every email.")
        if purpose == "first" and not (subject or "").strip():
            problems.append("A first email needs a subject line.")
    if re.search(r"just (checking|following|circling) (in|up|back)|solo (quería|para) (dar seguimiento|saber)", message or "", re.I):
        problems.append("Says 'just checking in'; every message must add something new.")
    if wants_spanish(brief, country) and language(message) != "es":
        problems.append("This buyer is in Mexico; the fact sheet says to write in Spanish.")
    return problems
