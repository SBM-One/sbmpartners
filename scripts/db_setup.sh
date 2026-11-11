#!/usr/bin/env bash
# Sets up the database on Supabase (or any PostgreSQL 15+ with pgvector).
#   scripts/db_setup.sh            apply migrations, then run the privacy checks
#   scripts/db_setup.sh --seed     same, plus load the made-up pilot data (test projects only)
#   scripts/db_setup.sh --verify   only run the privacy checks
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

if ! $verify_only; then
  # migrations are not re-runnable: stop early if the schema is already there
  if [[ "$(psql "$DATABASE_URL" -X -tAc "select to_regclass('public.clients') is not null")" == "t" ]]; then
    echo "The schema is already installed (table 'clients' exists). Skipping migrations."
  else
    for f in db/migrations/*.sql; do run "$f"; done
  fi
  $seed && run db/seed/pilot_example.sql
fi
run db/tests/verify_privacy.sql
