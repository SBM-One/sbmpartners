"""The researcher's daily quota, and proof that it did the work.

  1. Screen   the next `screen_per_day` DENUE companies (INEGI's business directory) by fixed rules, at no AI cost:
              furniture activity, size, branches, a way to reach them. The best `research_per_day` become buyers in
              the campaign and get a research task; every other one keeps its score and the reason it was skipped.
  2. Gate     a researched account only counts once it passes: at least `min_sources` opened pages behind at least
              `min_facts` facts, a logged attempt to name the buyer (who, or why nobody), a fit score with reasons,
              and which channels are open. A failed account is researched again (up to `max_redo` times), with the
              reasons it was sent back; it does not count until it passes.
  3. Check    a random `spot_check_share` of the passed accounts is checked again: the cited pages are fetched and
              every fact is looked for on its page. Too many unsupported facts = a skim, raised as an alert.

All numbers are in the database table research_quota_settings (one row).

  python -m agents.quota import ~/SBM\\ PARTNERS/denue/chains.csv   load DENUE (chains.csv from agents/denue.py, or raw json/jsonl/csv)
  python -m agents.quota screen --client "Santa Fe Rústicos" --campaign <id>   today's screening + research tasks
  python -m agents.quota spot-check                                          re-check a sample of today's passed accounts
  python -m agents.quota status                                              today's numbers
Then `python -m agents.team run` does the research and drafting as usual.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import html
import json
import math
import pathlib
import random
import re
import unicodedata
import urllib.request
from typing import Callable, Iterable, Optional
from zoneinfo import ZoneInfo

from . import teamdb as db

MX = ZoneInfo("America/Mexico_City")
PLACEHOLDER_TITLE = "Compras / comprador(a) de muebles (persona por identificar)"


class IncompleteResearch(Exception):
    """The research did not pass the completeness gate; the task goes back in the queue."""


def today() -> dt.date:
    return dt.datetime.now(MX).date()


def settings(conn) -> dict:
    return db.one(conn, "select * from research_quota_settings where id")


# ─────────────────────────── 1. loading DENUE ───────────────────────────
ALIASES = {
    "key": ["id", "Id", "clee", "CLEE", "denue_id"],
    "name": ["nom_estab", "Nombre", "nombre", "name"],
    "legal_name": ["raz_social", "Razon_social", "razon_social", "legal_name"],
    "activity": ["nombre_act", "Clase_actividad", "clase_actividad", "activity"],
    "activity_code": ["codigo_act", "Codigo_act", "scian", "clase", "activity_code"],
    "staff_band": ["per_ocu", "Estrato", "estrato", "staff_band"],
    "city": ["municipio", "Municipio", "nom_mun", "city"],
    "state": ["entidad", "Entidad", "nom_ent", "state"],
    "phone": ["telefono", "Telefono", "phone"],
    "email": ["correoelec", "Correo_e", "correo_e", "email"],
    "website": ["www", "Sitio_internet", "sitio_internet", "website"],
    "branches": ["establishments", "establecimientos", "branches", "n_estab"],
}


# SCIAN classes the DENUE pull asks for (agents/denue.py): (label, points, kind)
SCIAN = {
    "466111": ("Furniture stores (home)", 35, "retailer"),
    "466112": ("Appliance and furniture stores", 30, "retailer"),
    "466113": ("Garden furniture stores", 25, "retailer"),
    "462210": ("Department stores", 25, "retailer"),
    "462111": ("Supermarkets and clubs", 15, "retailer"),
    "467111": ("Hardware stores", 15, "retailer"),
    "467116": ("Building materials / home improvement", 20, "retailer"),
    "721111": ("Hotels", 15, "hospitality"),
    "541410": ("Interior design firms", 15, "design_firm"),
    "435412": ("Office furniture wholesale", 30, "distributor"),
}


def chain_row(r: dict) -> dict:
    """One row of agents/denue.py's chains.csv (already one row per company)."""
    classes = [c.split(":")[0] for c in (r.get("classes") or "").split() if c]
    code = classes[0] if classes else None
    state = (r.get("top_states") or "").split(";")[0].strip() or None
    return {"source_key": f"chain:{r['chain']}", "name": (r.get("chain") or "").title(), "legal_name": r.get("legal_name") or None,
            "activity": SCIAN.get(code, (code,))[0] if code else None, "activity_code": " ".join(classes) or None,
            "staff_band": f"about {r.get('people_est')} people" if r.get("people_est") else None,
            "staff_min": int(float(r["people_est"])) if r.get("people_est") else None,
            "branches": int(float(r.get("branches") or 1)), "city": None, "state": state.title() if state else None,
            "phone": r.get("phone") or None, "email": r.get("email") or None, "website": r.get("website") or None, "raw": r}


def _get(row: dict, field: str):
    for k in ALIASES[field]:
        v = row.get(k)
        if v not in (None, ""):
            return str(v).strip() if not isinstance(v, (int, float)) else v
    return None


def staff_min(band) -> Optional[int]:
    """'51 a 100 personas' -> 51, '251 y más personas' -> 251, 37 -> 37."""
    if band is None:
        return None
    if isinstance(band, (int, float)):
        return int(band)
    m = re.search(r"\d+", str(band))
    return int(m.group(0)) if m else None


def fold(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def read_rows(path: pathlib.Path) -> Iterable[dict]:
    text = path.read_text(encoding="utf-8-sig")
    if path.suffix.lower() == ".csv":
        yield from csv.DictReader(text.splitlines())
    elif path.suffix.lower() == ".jsonl":
        for line in text.splitlines():
            if line.strip():
                yield json.loads(line)
    else:
        data = json.loads(text)
        if isinstance(data, dict):   # {"data": [...]} or {"companies": [...]}
            data = next((v for v in data.values() if isinstance(v, list)), [])
        yield from data


def companies_from(rows: Iterable[dict]) -> list[dict]:
    """DENUE lists establishments (each branch); group them into companies by name and state."""
    out: dict[str, dict] = {}
    for r in rows:
        if r.get("chain"):   # chains.csv: already one row per company
            c = chain_row(r)
            out[c["source_key"]] = c
            continue
        name = _get(r, "name")
        if not name:
            continue
        state, city = _get(r, "state"), _get(r, "city")
        if not state and r.get("Ubicacion"):   # the API's "localidad, municipio, ENTIDAD"
            parts = [p.strip() for p in str(r["Ubicacion"]).split(",")]
            state, city = parts[-1].title(), city or (parts[-2] if len(parts) > 1 else None)
        key = f"{fold(_get(r, 'legal_name') or name)}|{fold(state or '')}"
        c = out.get(key)
        n = int(_get(r, "branches") or 1)
        if c is None:
            out[key] = {"source_key": str(_get(r, "key") or key), "name": name, "legal_name": _get(r, "legal_name"),
                        "activity": _get(r, "activity"), "activity_code": str(_get(r, "activity_code") or "") or None,
                        "staff_band": _get(r, "staff_band"), "staff_min": staff_min(_get(r, "staff_band")),
                        "branches": n, "city": city, "state": state, "phone": _get(r, "phone"),
                        "email": _get(r, "email"), "website": _get(r, "website"), "raw": r}
            continue
        c["branches"] += n
        if (staff_min(_get(r, "staff_band")) or -1) > (c["staff_min"] or -1):
            c["staff_band"], c["staff_min"] = _get(r, "staff_band"), staff_min(_get(r, "staff_band"))
        for f in ("phone", "email", "website"):
            c[f] = c[f] or _get(r, f)
    return list(out.values())


def load(conn, path: pathlib.Path) -> int:
    """Add DENUE companies to the screening pool. Ones already there are left as they are."""
    added = 0
    for c in companies_from(read_rows(path)):
        row = db.one(conn, """
            insert into screen_pool (source, source_key, name, legal_name, activity, activity_code, staff_band, staff_min,
                                     branches, city, state, phone, email, website, raw)
            values ('denue', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            on conflict (source, source_key) do nothing returning id""",
                     (c["source_key"], c["name"], c["legal_name"], c["activity"], c["activity_code"], c["staff_band"],
                      c["staff_min"], c["branches"], c["city"], c["state"], c["phone"], c["email"], c["website"],
                      db.jsonb(c["raw"])))
        added += bool(row)
    return added


# ─────────────────────────── 2. screening ───────────────────────────
def domain_of(website: Optional[str]) -> Optional[str]:
    if not website:
        return None
    d = re.sub(r"^(https?://)?(www\.)?", "", website.strip().lower()).split("/")[0]
    return d if "." in d else None


def score(c: dict) -> tuple[int, list[str], Optional[str]]:
    """(score 0-100, why, reason to skip outright). Fixed rules; no AI."""
    act = fold(c.get("activity") or "")
    notes, s = [], 0
    if "fabricacion" in act or "manufactur" in act:
        return 0, ["makes furniture"], "A maker, not a buyer (would be a competitor)."
    codes = (c.get("activity_code") or "").split()
    if codes and codes[0].startswith("337"):
        return 0, ["makes furniture"], "A maker, not a buyer (would be a competitor)."
    known_code = next((k for k in codes if k in SCIAN), None)
    if known_code:
        label, pts, _ = SCIAN[known_code]
        s += pts; notes.append(f"{label} +{pts}")
        act = ""
    furniture = ("mueble" in act or "mobiliario" in act) and not any(w in act for w in ("computo", "medic", "laboratorio"))
    if known_code:
        pass
    elif furniture and "por mayor" in act:
        s += 35; notes.append("furniture wholesaler +35")
    elif furniture:
        s += 35; notes.append("furniture retailer +35")
    elif "departamental" in act or "autoservicio" in act:
        s += 25; notes.append("department / big-box store +25")
    elif "hotel" in act or "decoracion" in act or "interior" in act:
        s += 15; notes.append("contract or interiors buyer +15")
    else:
        return 0, [f"activity: {c.get('activity') or 'unknown'}"], "Not a furniture buyer by its DENUE activity."
    n = c.get("staff_min")
    size = 30 if (n or 0) >= 251 else 25 if (n or 0) >= 101 else 20 if (n or 0) >= 51 else 15 if (n or 0) >= 31 else \
        8 if (n or 0) >= 11 else 0
    if size:
        s += size; notes.append(f"{c.get('staff_band')} staff +{size}")
    b = int(c.get("branches") or 1)
    if b > 1:
        add = min(20, 4 * (b - 1)); s += add; notes.append(f"{b} branches +{add}")
    if not (c.get("website") or c.get("email") or c.get("phone")):
        return s, notes, "No website, email or phone in DENUE: nothing to research or reach."
    for f, pts in (("website", 10), ("email", 3), ("phone", 2)):
        if c.get(f):
            s += pts; notes.append(f"{f} +{pts}")
    return min(s, 100), notes, None


def known(conn, c: dict) -> bool:
    d = domain_of(c.get("website"))
    return bool(db.one(conn, "select 1 from companies where (domain is not null and domain = %s) "
                             "or (lower(name) = lower(%s) and coalesce(lower(hq_state), '') = coalesce(lower(%s), ''))",
                       (d, c["name"], c.get("state"))))


def screen(conn, client_id, campaign_id, day: Optional[dt.date] = None, log: Callable[[str], None] = print) -> dict:
    """Screen today's batch and send the best to the researcher. Running it again the same day only tops up."""
    day, q = day or today(), settings(conn)
    done = db.one(conn, "select count(*) as n, count(*) filter (where picked) as p from screen_pool where screened_on = %s", (day,))
    want = max(0, q["screen_per_day"] - done["n"])
    batch = db.all_rows(conn, "select * from screen_pool where screened_on is null "
                              "order by staff_min desc nulls last, branches desc, created_at limit %s", (want,))
    scored = []
    for c in batch:
        s, notes, skip = score(c)
        if not skip and known(conn, c):
            skip = "Already in the database."
        scored.append((s, c, notes, skip))
    ranked = sorted((x for x in scored if not x[3]), key=lambda x: -x[0])
    room = max(0, q["research_per_day"] - done["p"])
    picked, cut = ranked[:room], (ranked[room - 1][0] if 0 < room <= len(ranked) else None)
    picked_ids = {x[1]["id"] for x in picked}
    for s, c, notes, skip in scored:
        if c["id"] in picked_ids:
            continue
        reason = skip or f"Scored {s}; below today's top {q['research_per_day']}" + (f" (cut-off {cut})." if cut is not None else ".")
        db.all_rows(conn, "update screen_pool set screened_on = %s, screen_score = %s, screen_notes = %s, picked = false, "
                          "skip_reason = %s, client_id = %s where id = %s", (day, s, "; ".join(notes), reason, client_id, c["id"]))
    enqueued = 0
    for s, c, notes, _ in picked:
        company_id, contact_id = add_buyer(conn, c, campaign_id)
        db.all_rows(conn, "update screen_pool set screened_on = %s, screen_score = %s, screen_notes = %s, picked = true, "
                          "client_id = %s, company_id = %s, contact_id = %s where id = %s",
                    (day, s, "; ".join(notes), client_id, company_id, contact_id, c["id"]))
        tid = db.enqueue(conn, "research_prospect", client_id=client_id, campaign_id=campaign_id, contact_id=contact_id,
                         company_id=company_id, input={"quota_day": day.isoformat()}, priority=40, created_by="quota")
        if tid:
            db.all_rows(conn, "update tasks set max_attempts = %s where id = %s", (1 + q["max_redo"], tid))
            enqueued += 1
    out = {"day": day.isoformat(), "screened": len(batch), "picked": len(picked), "research_tasks": enqueued,
           "skipped": len(batch) - len(picked), "waiting": db.one(conn, "select count(*) as n from screen_pool where screened_on is null")["n"]}
    log(f"Screened {out['screened']} DENUE companies for {day}: {out['picked']} to research, {out['skipped']} skipped, "
        f"{out['waiting']} still waiting.")
    return out


def buyer_type(activity: Optional[str], codes: Optional[str] = None) -> str:
    code = next((k for k in (codes or "").split() if k in SCIAN), None)
    if code:
        return SCIAN[code][2]
    a = fold(activity or "")
    return "distributor" if "por mayor" in a else "hospitality" if "hotel" in a else "retailer"


def add_buyer(conn, c: dict, campaign_id) -> tuple:
    d = domain_of(c.get("website"))
    company_id = db.one(conn, """insert into companies (name, domain, type, hq_city, hq_state, country, website, phone, notes)
                                 values (%s, %s, %s::buyer_type, %s, %s, 'MX', %s, %s, %s)
                                 on conflict (domain) do update set updated_at = now() returning id""",
                        (c["name"], d, buyer_type(c.get("activity"), c.get("activity_code")), c.get("city"), c.get("state"), c.get("website"), c.get("phone"),
                         f"From DENUE (INEGI): {c.get('activity') or ''}; {c.get('staff_band') or ''}; {c.get('branches')} branch(es)."))["id"]
    email = (c.get("email") or "").strip().lower() or None
    if email and db.one(conn, "select 1 from contacts where email = %s", (email,)):
        email = None
    contact_id = db.one(conn, """insert into contacts (company_id, title, email, email_source, email_basis, phone, country)
                                 values (%s, %s, %s, %s, 'legitimate_interest', %s, 'MX') returning id""",
                        (company_id, PLACEHOLDER_TITLE, email, "DENUE (INEGI) public business directory" if email else None,
                         c.get("phone")))["id"]
    db.all_rows(conn, "insert into campaign_targets (campaign_id, contact_id, company_id) values (%s, %s, %s) "
                      "on conflict do nothing", (campaign_id, contact_id, company_id))
    return company_id, contact_id


# ─────────────────────────── 3. the completeness gate ───────────────────────────
def quota_day(task: dict) -> Optional[dt.date]:
    d = (task.get("input") or {}).get("quota_day")
    return dt.date.fromisoformat(d) if d else None


def sent_back(conn, task: dict) -> list[str]:
    """Why earlier attempts at this task were sent back (for the researcher's next try)."""
    rows = db.all_rows(conn, "select problems from research_checks where task_id = %s and not passed order by created_at", (task["id"],))
    return [p for r in rows for p in r["problems"]]


def research_problems(result: dict, q: dict) -> list[str]:
    facts = result.get("facts") or []
    sources = {f["source_url"] for f in facts}
    problems = []
    if len(facts) < q["min_facts"]:
        problems.append(f"Only {len(facts)} fact(s) backed by a page you opened; at least {q['min_facts']} are needed.")
    if len(sources) < q["min_sources"]:
        problems.append(f"Facts come from {len(sources)} opened page(s); at least {q['min_sources']} different pages are needed.")
    b = result.get("buyer") or {}
    if not (b.get("how_searched") or "").strip():
        problems.append("No record of how you looked for the person who buys (where you searched).")
    elif b.get("name") and not b.get("source_verified"):
        problems.append(f"Named {b['name']} as the buyer without a page you opened that says so.")
    elif not b.get("name") and not (b.get("not_found_reason") or "").strip():
        problems.append("No buyer named and no reason given why none could be found.")
    if result.get("dropped_unverified", 0) > len(facts):
        problems.append(f"{result['dropped_unverified']} facts cited pages you never opened (dropped).")
    return problems


def score_problems(scored: Optional[dict], s: Optional[dict]) -> list[str]:
    if not scored or not s:
        return ["No fit score was saved."]
    problems = []
    whys = [r for r in (s.get("fit_breakdown") or []) if (r.get("why") or "").strip() in ("", "Not scored.")]
    if whys:
        problems.append(f"Fit score has {len(whys)} criteria without a reason.")
    if not (s.get("reason") or "").strip():
        problems.append("The decision has no reason.")
    return problems


def record(conn, task: dict, day: dt.date, result: dict, problems: list[str], *, fit_score=None, channels=None) -> None:
    facts = result.get("facts") or []
    db.all_rows(conn, """insert into research_checks (task_id, client_id, company_id, contact_id, quota_day, attempt, passed, problems,
                                                      sources, facts, buyer, fit_score, channels)
                         values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (task["id"], task["client_id"], task["company_id"], task["contact_id"], day, task.get("attempts") or 1,
                 not problems, problems, sorted({f["source_url"] for f in facts}), db.jsonb(facts),
                 db.jsonb(result.get("buyer")), fit_score, db.jsonb(channels)))


def save_buyer(conn, contact_id, b: Optional[dict]) -> None:
    """A buyer the researcher named (from a page it opened) goes on the contact."""
    if not b or not b.get("name") or not b.get("source_verified"):
        return
    first, _, last = b["name"].strip().partition(" ")
    db.all_rows(conn, "update contacts set first_name = %s, last_name = nullif(%s, ''), title = coalesce(nullif(%s, ''), title) "
                      "where id = %s and first_name is null", (first, last, b.get("title") or "", contact_id))
    url = (b.get("linkedin_url") or "").strip()
    if re.match(r"https?://([a-z]{2,3}\.)?linkedin\.com/in/", url) and not db.one(conn, "select 1 from contacts where linkedin_url = %s", (url,)):
        db.all_rows(conn, "update contacts set linkedin_url = %s where id = %s and linkedin_url is null", (url, contact_id))
    db.all_rows(conn, "insert into field_sources (entity, entity_id, field, value, source, owned, confidence) "
                      "values ('contact', %s, 'buyer_name', %s, %s, false, 0.6)",
                (contact_id, f"{b['name']} ({b.get('title') or ''})"[:1000], "web:" + (b.get("source_url") or "")[:500]))


# ─────────────────────────── 4. the spot check ───────────────────────────
STOP = set("para with that this from their they have como sobre entre desde donde tiene tienen esta este estos estas "
           "también about which sells offers vende ofrece cuenta cuentas the and los las una unos unas sus del".split())


def page_text(url: str, timeout: int = 15) -> Optional[str]:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (SBM Partners research checker)"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read(3_000_000).decode(r.headers.get_content_charset() or "utf-8", "ignore")
    except Exception:
        return None
    raw = re.sub(r"(?is)<(script|style|noscript)[^>]*>.*?</\1>", " ", raw)
    return html.unescape(re.sub(r"<[^>]+>", " ", raw))


def tokens(text: str) -> set[str]:
    return {w for w in fold(text).split() if (len(w) >= 4 or w.isdigit()) and w not in STOP}


def supported(fact: str, page: str) -> tuple[bool, float]:
    want, have = tokens(fact), tokens(page)
    if not want:
        return True, 1.0
    share = len(want & have) / len(want)
    return share >= 0.5, round(share, 2)


def spot_check(conn, day: Optional[dt.date] = None, fetch: Callable[[str], Optional[str]] = page_text,
               rnd: Optional[random.Random] = None, log: Callable[[str], None] = print) -> dict:
    """Check a random share of the day's passed accounts against their pages. No AI, no cost."""
    day, q, rnd = day or today(), settings(conn), rnd or random.Random()
    passed = db.all_rows(conn, "select * from research_checks where quota_day = %s and passed", (day,))
    target = math.ceil(len(passed) * float(q["spot_check_share"])) if passed else 0
    done = sum(1 for r in passed if r["spot_checked_at"])
    todo = rnd.sample([r for r in passed if not r["spot_checked_at"]], max(0, min(target - done, len(passed) - done)))
    out = {"day": day.isoformat(), "passed": len(passed), "checked": 0, "skims": 0, "unreachable": 0}
    cache: dict[str, Optional[str]] = {}
    for r in todo:
        notes, ok, readable = [], 0, 0
        for f in r["facts"] or []:
            url = f["source_url"]
            if url not in cache:
                cache[url] = fetch(url)
            page = cache[url]
            if not page or len(page.strip()) < 300:
                notes.append({"fact": f["fact"], "url": url, "result": "page could not be read"})
                continue
            readable += 1
            yes, share = supported(f["fact"], page)
            ok += yes
            notes.append({"fact": f["fact"], "url": url, "result": "supported" if yes else "not on the page", "overlap": share})
        result = "unreachable" if readable == 0 else ("ok" if ok * 2 >= readable else "skim")
        db.all_rows(conn, "update research_checks set spot_checked_at = now(), spot_result = %s, spot_notes = %s where id = %s",
                    (result, db.jsonb(notes), r["id"]))
        out["checked"] += 1
        out["skims"] += result == "skim"
        out["unreachable"] += result == "unreachable"
        if result == "skim":
            name = db.one(conn, "select name from companies where id = %s", (r["company_id"],))
            db.alert(conn, "research_skim", f"Spot check: {readable - ok} of {readable} facts about "
                     f"{(name or {}).get('name', 'a buyer')} are not on the pages cited. The research may have been skimmed.",
                     client_id=r["client_id"], refs={"research_check_id": str(r["id"])}, dedupe_key=f"skim:{r['id']}")
    log(f"Spot check {day}: {out['checked']} of {out['passed']} passed accounts checked, {out['skims']} skims, "
        f"{out['unreachable']} pages unreadable.")
    return out


def status(conn, day: Optional[dt.date] = None) -> Optional[dict]:
    return db.one(conn, "select * from v_research_quota where day = %s", (day or today(),))


# ─────────────────────────── command line ───────────────────────────
def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("import").add_argument("path", type=pathlib.Path)
    s = sub.add_parser("screen")
    s.add_argument("--client", required=True, help="client name or id")
    s.add_argument("--campaign", required=True, help="campaign id")
    sub.add_parser("spot-check")
    sub.add_parser("status")
    for p in sub.choices.values():
        p.add_argument("--day", type=dt.date.fromisoformat, default=None)
    a = ap.parse_args(argv)
    conn = db.connect()
    if a.cmd == "import":
        print(f"Added {load(conn, a.path)} companies to the screening pool.")
    elif a.cmd == "screen":
        cl = db.one(conn, "select id from clients where id::text = %s or name = %s", (a.client, a.client))
        if not cl:
            raise SystemExit(f"No client {a.client!r}.")
        screen(conn, cl["id"], a.campaign, a.day)
    elif a.cmd == "spot-check":
        spot_check(conn, a.day)
    else:
        print(json.dumps(status(conn, a.day), default=str, indent=1))


if __name__ == "__main__":
    main()
