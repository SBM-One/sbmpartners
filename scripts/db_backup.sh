#!/usr/bin/env bash
# Dumps the live database's public schema (tables, data, functions, policies, grants) plus a row-count manifest.
#   DATABASE_URL=postgres://...  scripts/db_backup.sh OUT_DIR
# Writes OUT_DIR/sbm-YYYYMMDD-HHMM.dump (pg_dump custom format) and OUT_DIR/sbm-YYYYMMDD-HHMM.counts.tsv.
set -euo pipefail
out="${1:?output folder}"
: "${DATABASE_URL:?DATABASE_URL is not set}"
mkdir -p "$out"
stamp="$(date -u +%Y%m%d-%H%M)"
pg_dump "$DATABASE_URL" --schema=public --format=custom --no-owner --file="$out/sbm-$stamp.dump"
psql "$DATABASE_URL" -X -tA -F $'\t' -c "
  select c.relname, (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' order by 1" > "$out/sbm-$stamp.counts.tsv"
echo "$out/sbm-$stamp.dump"
