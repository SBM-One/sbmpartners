#!/usr/bin/env bash
# Proves a backup can be restored: loads it into an empty PostgreSQL (with the Supabase roles mocked), compares every
# table's row count with the manifest taken at backup time, then runs the repository's checks against the copy.
#   RESTORE_URL=postgres://...empty database...  scripts/db_restore_check.sh path/to/sbm-....dump
set -euo pipefail
cd "$(dirname "$0")/.."
dump="${1:?dump file}"
counts="${dump%.dump}.counts.tsv"
: "${RESTORE_URL:?RESTORE_URL is not set (an empty database to restore into)}"
psql "$RESTORE_URL" -X -q -v ON_ERROR_STOP=1 -f db/local/supabase_mock.sql >/dev/null
psql "$RESTORE_URL" -X -q -c "create extension if not exists vector with schema public" \
  -c "alter default privileges in schema public revoke execute on functions from public, anon, authenticated" \
  -c "alter default privileges in schema public revoke all on tables from anon, authenticated" >/dev/null   # as on live (0015): restored objects get only the grants in the backup
list="$(mktemp)"
pg_restore --list "$dump" | grep -v ' SCHEMA - public ' > "$list"    # the empty database already has the public schema
pg_restore --dbname="$RESTORE_URL" --no-owner --exit-on-error --use-list="$list" "$dump"
fail=0
while IFS=$'\t' read -r table n; do
  got="$(psql "$RESTORE_URL" -X -tA -c "select count(*) from public.\"$table\"")"
  if [[ "$got" != "$n" ]]; then echo "MISMATCH $table: backup had $n rows, restore has $got"; fail=1; fi
done < "$counts"
[[ $fail == 0 ]] || { echo "Restore check FAILED"; exit 1; }
echo "All $(wc -l < "$counts") tables restored with matching row counts."
for t in privacy controls; do psql "$RESTORE_URL" -X -q -v ON_ERROR_STOP=1 -f "db/tests/verify_$t.sql" | tail -2; done
echo "Restore check passed."
