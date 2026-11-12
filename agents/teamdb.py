"""Database helpers for the agent team: the task queue, agent records, spending and alerts.

Every agent works through these. Nothing here calls the AI.
"""
from __future__ import annotations

import json
import os
from typing import Any, Iterable, Optional

# Agent name -> (role, default model, monthly budget in cents). Budgets can be changed later in
# Supabase (Table Editor -> agents -> monthly_budget_cents); restarting the team never resets them.
TEAM = {
    "supervisor": ("supervisor", "rules (no AI)", 0),
    "prospect-researcher": ("prospect_researcher", os.environ.get("SBM_PROSPECT_MODEL", "claude-sonnet-5-5"), 5000),
    "writer": ("writer", os.environ.get("SBM_WRITER_MODEL", os.environ.get("SBM_MODEL", "claude-opus-5-5")), 10000),
    "grader": ("grader", os.environ.get("SBM_GRADER_MODEL", os.environ.get("SBM_MODEL", "claude-opus-5-5")), 10000),
    "reporter": ("reporter", os.environ.get("SBM_REPORTER_MODEL", "claude-sonnet-5-5"), 2000),
}

# Which agent does which kind of task.
KIND_AGENT = {"research_prospect": "prospect-researcher", "draft_outreach": "writer", "write_report": "reporter"}


def connect(url: Optional[str] = None):
    try:
        import psycopg
        from psycopg.rows import dict_row
    except ImportError as exc:  # pragma: no cover
        raise SystemExit("Install the database driver first: pip install -r requirements.txt") from exc
    url = url or os.environ.get("DATABASE_URL")
    if not url:
        raise SystemExit("DATABASE_URL is not set (see .env.example).")
    return psycopg.connect(url, row_factory=dict_row, autocommit=True)


def jsonb(v: Any):
    from psycopg.types.json import Jsonb
    return Jsonb(v)


def all_rows(conn, sql: str, params: Iterable = ()) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall() if cur.description else []


def one(conn, sql: str, params: Iterable = ()) -> Optional[dict]:
    rows = all_rows(conn, sql, params)
    return rows[0] if rows else None


# ─────────────────────────── agents ───────────────────────────
def register_team(conn) -> dict[str, dict]:
    """Make sure every team member has a row in `agents`. Keeps budgets and pauses you set."""
    for name, (role, model, budget) in TEAM.items():
        all_rows(conn,
                 "insert into agents (name, role, model, monthly_budget_cents) values (%s, %s::agent_role, %s, %s) "
                 "on conflict (name) do update set model = excluded.model",
                 (name, role, model, budget))
    return {r["name"]: r for r in all_rows(conn, "select * from agents where name = any(%s)", (list(TEAM),))}


def agent(conn, name: str) -> dict:
    return one(conn, "select * from agents where name = %s", (name,))


def spend(conn, name: str) -> dict:
    """This month's spend for one agent: spent_usd, budget_usd, pct_used, active."""
    return one(conn, "select * from v_agent_spend_month where name = %s", (name,))


def can_work(conn, name: str) -> bool:
    a = spend(conn, name)
    return bool(a and a["active"] and a["spent_usd"] < a["budget_usd"])


def record_run(conn, agent_name: str, usage, summary: str, ok: bool = True) -> str:
    row = one(conn,
              "insert into agent_runs (agent_id, finished_at, status, input_tokens, output_tokens, cost_cents, summary) "
              "select id, now(), %s, %s, %s, %s, %s from agents where name = %s returning id",
              ("ok" if ok else "failed", usage.input_tokens, usage.output_tokens, round(usage.cost_usd * 100, 2),
               summary[:500], agent_name))
    return str(row["id"])


# ─────────────────────────── tasks ───────────────────────────
def enqueue(conn, kind: str, *, client_id=None, campaign_id=None, contact_id=None, company_id=None,
            parent_id=None, input: Optional[dict] = None, priority: int = 100, created_by: str = "supervisor") -> Optional[str]:
    """Add a task. Returns its id, or None if the same buyer already has an open task of this kind."""
    row = one(conn,
              "insert into tasks (kind, client_id, campaign_id, contact_id, company_id, parent_id, input, priority, created_by) "
              "values (%s, %s, %s, %s, %s, %s, %s, %s, %s) on conflict do nothing returning id",
              (kind, client_id, campaign_id, contact_id, company_id, parent_id, jsonb(input or {}), priority, created_by))
    return str(row["id"]) if row else None


def claim(conn, kinds: list[str], worker: str, limit: int = 1) -> list[dict]:
    if not kinds or limit <= 0:
        return []
    return all_rows(conn, "select * from claim_tasks(%s, %s, %s)", (kinds, worker, limit))


def finish(conn, task_id, output: dict, run_id: Optional[str] = None) -> None:
    all_rows(conn,
             "update tasks set status = 'done', output = %s, finished_at = now(), agent_run_id = %s, error = null "
             "where id = %s", (jsonb(output), run_id, task_id))


def fail(conn, task_id, error: str, run_id: Optional[str] = None, retry_minutes: int = 10) -> str:
    """Put the task back in the queue to retry later, or mark it failed once it has used its attempts."""
    row = one(conn,
              "update tasks set status = case when attempts >= max_attempts then 'failed'::task_status else 'queued'::task_status end, "
              "error = %s, agent_run_id = coalesce(%s, agent_run_id), claimed_by = null, claimed_at = null, "
              "run_after = now() + make_interval(mins => %s * attempts), "
              "finished_at = case when attempts >= max_attempts then now() end "
              "where id = %s returning status::text", (error[:2000], run_id, retry_minutes, task_id))
    return row["status"] if row else "missing"


# ─────────────────────────── alerts ───────────────────────────
def alert(conn, kind: str, message: str, *, severity: str = "warning", client_id=None, refs: Optional[dict] = None,
          dedupe_key: Optional[str] = None) -> bool:
    """Raise an internal alert. With dedupe_key, nothing is added if an open alert with that key exists."""
    refs = dict(refs or {})
    if dedupe_key:
        refs["key"] = dedupe_key
        if one(conn, "select 1 from alerts where kind = %s and status <> 'resolved' and refs->>'key' = %s",
               (kind, dedupe_key)):
            return False
    all_rows(conn, "insert into alerts (client_id, severity, kind, message, refs) values (%s, %s::severity, %s, %s, %s)",
             (client_id, severity, kind, message, jsonb(refs)))
    return True


def dumps(v: Any) -> str:
    return json.dumps(v, default=str, ensure_ascii=False)
