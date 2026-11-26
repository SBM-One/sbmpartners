"""A throwaway Postgres database for the benchmark, so nothing touches Supabase.

Either it starts its own Postgres in a temporary folder (needs Postgres 15+ with pgvector installed on the computer:
`brew install postgresql@17 pgvector` on a Mac), or you pass --db with a LOCAL throwaway database.
A Supabase address is always refused.
"""
from __future__ import annotations

import glob
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
from typing import Optional
from urllib.parse import urlparse, parse_qs

ROOT = pathlib.Path(__file__).resolve().parent.parent
MIGRATIONS = sorted((ROOT / "db" / "migrations").glob("*.sql"))
MOCK = ROOT / "db" / "local" / "supabase_mock.sql"


def is_local(url: str) -> bool:
    """True only for a database on this computer. Anything hosted (Supabase, a pooler, any other host) is refused."""
    if any(s in url.lower() for s in ("supabase", "pooler", "amazonaws", "neon.tech", "render.com")):
        return False
    u = urlparse(url)
    hosts = [u.hostname or ""] + parse_qs(u.query).get("host", [])
    return all(h in ("", "localhost", "127.0.0.1", "::1") or h.startswith("/") for h in hosts)


def _bin(name: str) -> Optional[str]:
    found = shutil.which(name)
    if found:
        return found
    for pattern in ("/opt/homebrew/opt/postgresql@*/bin/", "/usr/local/opt/postgresql@*/bin/",
                    "/Applications/Postgres.app/Contents/Versions/latest/bin/", "/usr/lib/postgresql/*/bin/"):
        for d in sorted(glob.glob(pattern), reverse=True):
            if os.path.exists(d + name):
                return d + name
    return None


class Sandbox:
    """Context manager: yields a database URL with every migration applied; stops and deletes it afterwards."""

    def __init__(self, url: Optional[str] = None, keep: bool = False):
        self.url, self.keep, self.dir, self.pg_ctl = url, keep, None, None

    def __enter__(self) -> str:
        if self.url:
            if not is_local(self.url):
                raise SystemExit("The benchmark only runs on a local throwaway database, never on Supabase or a hosted one.")
        else:
            self.url = self._start()
        self._migrate()
        return self.url

    def _start(self) -> str:
        initdb, self.pg_ctl = _bin("initdb"), _bin("pg_ctl")
        if not initdb or not self.pg_ctl:
            raise SystemExit("Postgres is not installed on this computer. On a Mac: brew install postgresql@17 pgvector")
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            raise SystemExit("Postgres will not start as root. Pass --db with a local throwaway database instead.")
        self.dir = tempfile.mkdtemp(prefix="sbm-bench-")
        data = os.path.join(self.dir, "data")
        subprocess.run([initdb, "-D", data, "-U", "postgres", "--auth=trust", "-E", "UTF8", "--no-instructions"],
                       check=True, stdout=subprocess.DEVNULL)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        subprocess.run([self.pg_ctl, "-D", data, "-l", os.path.join(self.dir, "pg.log"), "-w", "start",
                        "-o", f"-p {port} -k {self.dir} -c listen_addresses=''"], check=True, stdout=subprocess.DEVNULL)
        url = f"postgresql://postgres@/postgres?host={self.dir}&port={port}"
        import psycopg
        with psycopg.connect(url, autocommit=True) as c:
            c.execute("create database sbm_bench")
        return f"postgresql://postgres@/sbm_bench?host={self.dir}&port={port}"

    def _migrate(self) -> None:
        import psycopg
        with psycopg.connect(self.url, autocommit=True) as c:
            if c.execute("select to_regclass('public.outreach_drafts') is not null").fetchone()[0]:
                return   # already set up (a --db you reuse)
            try:
                c.execute("create extension if not exists vector")
            except psycopg.Error as exc:
                raise SystemExit("pgvector is missing. On a Mac: brew install pgvector (then run again).") from exc
            for f in [MOCK, *MIGRATIONS]:
                c.execute(f.read_text())

    def __exit__(self, *exc) -> None:
        if self.dir and not self.keep:
            subprocess.run([self.pg_ctl, "-D", os.path.join(self.dir, "data"), "-m", "fast", "stop"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(self.dir, ignore_errors=True)
