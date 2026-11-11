"""Optional direct database access for agents (needs DATABASE_URL in .env and the psycopg package).

Without it, agents write .sql files you paste into the Supabase SQL Editor instead.

    python -m agents.db load FILE.sql     run a .sql file against the database
"""
from __future__ import annotations

import os
import sys


def _connect():
    try:
        import psycopg
    except ImportError as exc:  # pragma: no cover
        raise SystemExit("Install the database driver first: pip install 'psycopg[binary]'") from exc
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise SystemExit("DATABASE_URL is not set (see .env.example).")
    return psycopg.connect(url)


def fetch_active_playbook() -> list[dict]:
    with _connect() as conn, conn.cursor() as cur:
        cur.execute("select id, title, body, channel::text, coalesce(buyer_types::text[], '{}'), stage::text "
                    "from playbook_entries where status = 'active' order by created_at, title")
        return [{"id": str(r[0]), "title": r[1], "body": r[2], "channel": r[3], "buyer_types": list(r[4]),
                 "stage": r[5]} for r in cur.fetchall()]


def run_sql(sql: str) -> None:
    with _connect() as conn:
        conn.execute(sql)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "load":
        run_sql(open(sys.argv[2]).read())
        print("Loaded.")
    else:
        print(__doc__)
