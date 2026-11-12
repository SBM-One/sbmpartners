#!/usr/bin/env bash
# Sets up the database on Supabase (or any PostgreSQL 15+ with pgvector).
#   scripts/db_setup.sh            apply any migrations not yet installed, then run the checks
#   scripts/db_setup.sh --seed     same, plus load the made-up pilot data (test projects only)
#   scripts/db_setup.sh --verify   only run the checks
# Reads DATABASE_URL from the environment or from a .env file in the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DATABASE_URL:-}" && -f .env ]]; then
  set -a; source .env; set +a
fi
if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "DATABASE_URL is not set. Copy .env.example to .env and paste your Supabase connection string." >&2
  exit 1
fi
command -v psql >/dev/null || { echo "psql is not installed (macOS: brew install libpq; Ubuntu: apt install postgresql-client)." >&2; exit 1; }

run() { echo "→ $1"; psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f "$1"; }

seed=false; verify_only=false
for arg in "$@"; do
  case "$arg" in
    --seed) seed=true ;;
    --verify) verify_only=true ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

# Each migration is applied once. A table or rule it creates tells us it is already installed.
installed() {
  local check
  case "$(basename "$1")" in
    0001_core.sql)             check="select to_regclass('public.clients') is not null" ;;
    0002_supabase_privacy.sql) check="select exists (select 1 from pg_policies where policyname = 'portal_read_client')" ;;
    0003_agent_team.sql)       check="select to_regclass('public.tasks') is not null" ;;
    *) echo "No install check for $1; add one to scripts/db_setup.sh." >&2; exit 1 ;;
  esac
  [[ "$(psql "$DATABASE_URL" -X -tAc "$check")" == "t" ]]
}

if ! $verify_only; then
  for f in db/migrations/*.sql; do
    if installed "$f"; then echo "✓ $f already installed"; else run "$f"; fi
  done
  $seed && run db/seed/pilot_example.sql
fi
run db/tests/verify_privacy.sql
run db/tests/verify_team.sql
