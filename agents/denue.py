"""DENUE puller: the bulk list of Mexican furniture buyers, straight from INEGI.

INEGI's DENUE (Directorio Estadístico Nacional de Unidades Económicas) lists every registered
business establishment in Mexico (5M+), with its activity class (SCIAN), size band, address,
and sometimes phone, email and website. It is free and public; you only need a token
(https://www.inegi.org.mx/app/api/denue/tokenVerify/tokenverify.html).

This is step 1 of buyer research (bulk list -> AI filter/score -> deep research on the top accounts).
It pulls the activity classes where furniture buyers live, then rolls the establishments up into
companies ("chains"): how many branches, how many people work in them, in how many states.
A company with 300 furniture stores in 25 states is a chain worth researching; a single 0-5
person shop is not.

Nothing is written to the database. Output goes to out/denue/<date>/:
  establishments.csv   every establishment pulled (raw)
  chains.csv           one row per company, biggest first (the list the AI filter reads next)

Run:  DENUE_TOKEN=... python -m agents.denue
      python -m agents.denue --only 466111 --min-branches 3
The token lives in ~/SBM PARTNERS/.secrets/denue.env on Yago's Mac (never commit it).
"""
from __future__ import annotations

import argparse
import collections
import csv
import datetime as dt
import json
import os
import pathlib
import re
import ssl
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
API = "https://www.inegi.org.mx/app/api/denue/v1/consulta"
PAGE = 1000  # the API returns at most 1000 rows per call

# SCIAN activity class -> (label, size bands to pull; 0 = all sizes).
# Size bands: 1=0-5, 2=6-10, 3=11-30, 4=31-50, 5=51-100, 6=101-250, 7=251+ people.
CLASSES: dict[str, tuple[str, list[int]]] = {
    "466111": ("Furniture stores (home)", [0]),
    "466112": ("Appliance and furniture stores", [0]),
    "466113": ("Garden furniture stores", [0]),
    "462210": ("Department stores", [0]),
    "462111": ("Supermarkets and clubs", [0]),
    "467111": ("Hardware stores (51+ people)", [5, 6, 7]),
    "467116": ("Building-materials / home improvement, e.g. Home Depot (51+ people)", [5, 6, 7]),
    "721111": ("Hotels with services (31+ people)", [4, 5, 6, 7]),
    "541410": ("Interior design firms", [0]),
    "435412": ("Office furniture wholesale", [0]),
}

BAND_MID = {"0 a 5": 3, "6 a 10": 8, "11 a 30": 20, "31 a 50": 40, "51 a 100": 75, "101 a 250": 175, "251 y m": 300}
SUFFIX = re.compile(r"\b(S\.?\s?A\.?\s?P\.?\s?I\.?|S\.?\s?A\.?\s?B\.?|S\.?\s?A\.?|S\.?\s?DE\s?R\.?\s?L\.?|DE\s+C\.?\s?V\.?|"
                    r"S\.?\s?C\.?|A\.?\s?C\.?|SOCIEDAD ANONIMA|PROMOTORA DE INVERSION|BURSATIL|DE CAPITAL VARIABLE)\b")
BRANCH_TAIL = re.compile(r"\b(SUC(URSAL)?|TIENDA|STORE|NO\.?|NUM\.?)\b.*$|\s+\d+\s*$")


def band_people(estrato: str) -> int:
    for k, v in BAND_MID.items():
        if estrato.startswith(k):
            return v
    return 0


def norm(s: str) -> str:
    """Upper case, no accents or punctuation, no company-type suffix (SA DE CV, S DE RL...)."""
    s = unicodedata.normalize("NFKD", (s or "").upper())
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = re.sub(r"\s+", " ", re.sub(r"[.,\-]", " ", s))
    for _ in range(2):
        s = re.sub(r"\s+", " ", SUFFIX.sub(" ", s)).strip()
    return s


GENERIC = {"MUEBLERIA", "MUEBLES", "MUEBLERIA SIN NOMBRE", "SIN NOMBRE", "HOTEL", "DECORACION",
           "DISEÑO DE INTERIORES", "TIENDA DE MUEBLES"}   # unnamed shops, not one company


def chain_key(row: dict) -> str:
    """Roll establishments up by legal name; fall back to the store name without its branch tag."""
    rs = norm(row.get("Razon_social", ""))
    if rs:
        return rs
    name = norm(row.get("Nombre", ""))
    name = re.sub(r"^\d+\s+", "", name)          # "2961 SALINAS Y ROCHA" -> "SALINAS Y ROCHA"
    return BRANCH_TAIL.sub("", name).strip() or name


def _get(url: str) -> str:
    """Python's own certificate store first; if this machine's TLS chain isn't in it (common with the
    python.org installer on macOS, or antivirus that re-signs HTTPS), fall back to curl, which uses the
    system store."""
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.URLError as e:
        if not isinstance(e.reason, ssl.SSLError):
            raise
        out = subprocess.run(["curl", "-sS", "--fail", "--max-time", "90", url], capture_output=True, check=True)
        return out.stdout.decode("utf-8", "replace")


def fetch(path: str, tries: int = 4):
    url = f"{API}/{path}"
    for i in range(tries):
        try:
            text = _get(url)
            return json.loads(text) if text.startswith("[") else []   # "No hay resultados." = end
        except (urllib.error.URLError, subprocess.CalledProcessError, TimeoutError, json.JSONDecodeError):
            if i == tries - 1:
                raise
            time.sleep(2 * (i + 1))
    return []


def pull(token: str, only: list[str] | None = None) -> list[dict]:
    rows: list[dict] = []
    for cls, (label, bands) in CLASSES.items():
        if only and cls not in only:
            continue
        for band in bands:
            start = 1
            while True:
                page = fetch(f"BuscarAreaActEstr/00/0/0/0/0/0/0/0/{cls}/0/{start}/{start + PAGE - 1}/0/{band}/{token}")
                for r in page:
                    r["clase"] = cls
                rows.extend(page)
                print(f"  {cls} band {band or 'all'}: {start + len(page) - 1}", file=sys.stderr)
                if len(page) < PAGE:
                    break
                start += PAGE
    return rows


def roll_up(rows: list[dict]) -> list[dict]:
    by: dict[str, dict] = {}
    for r in rows:
        k = chain_key(r)
        if not k or k in GENERIC:
            continue
        c = by.setdefault(k, {"chain": k, "legal_name": r.get("Razon_social", ""), "sample_store": r.get("Nombre", ""),
                              "branches": 0, "people_est": 0, "big_sites": 0, "classes": collections.Counter(),
                              "states": collections.Counter(), "website": "", "email": "", "phone": ""})
        c["branches"] += 1
        p = band_people(r.get("Estrato", ""))
        c["people_est"] += p
        c["big_sites"] += p >= 175
        c["classes"][r["clase"]] += 1
        state = (r.get("Ubicacion", "").split(",") or [""])[-1].strip()
        c["states"][state] += 1
        for f, src in (("website", "Sitio_internet"), ("email", "Correo_e"), ("phone", "Telefono")):
            if not c[f] and r.get(src):
                c[f] = r[src].strip().lower() if f != "phone" else r[src].strip()
    out = []
    for c in by.values():
        out.append({**c, "classes": " ".join(f"{k}:{v}" for k, v in c["classes"].most_common()),
                    "n_states": len(c["states"]),
                    "top_states": "; ".join(s for s, _ in c["states"].most_common(3))})
        out[-1].pop("states")
    out.sort(key=lambda c: (c["people_est"], c["branches"]), reverse=True)
    return out


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", nargs="*", help="SCIAN classes to pull (default: all in CLASSES)")
    ap.add_argument("--min-branches", type=int, default=1, help="keep chains with at least this many branches")
    ap.add_argument("--min-people", type=int, default=0, help="keep chains with at least this many estimated people")
    args = ap.parse_args(argv)
    token = os.environ.get("DENUE_TOKEN")
    if not token:
        sys.exit("Set DENUE_TOKEN (see ~/SBM PARTNERS/.secrets/denue.env).")
    rows = pull(token, args.only)
    chains = [c for c in roll_up(rows) if c["branches"] >= args.min_branches and c["people_est"] >= args.min_people]
    day = dt.date.today().isoformat()
    out = ROOT / "out" / "denue" / day
    out.mkdir(parents=True, exist_ok=True)
    raw_cols = ["Id", "clase", "Nombre", "Razon_social", "Clase_actividad", "Estrato", "Ubicacion", "CP",
                "Telefono", "Correo_e", "Sitio_internet", "Tipo", "Latitud", "Longitud"]
    with open(out / "establishments.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=raw_cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    with open(out / "chains.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(chains[0].keys()) if chains else ["chain"])
        w.writeheader()
        w.writerows(chains)
    print(f"{len(rows)} establishments -> {len(chains)} companies. Files in {out}")


if __name__ == "__main__":
    main()
