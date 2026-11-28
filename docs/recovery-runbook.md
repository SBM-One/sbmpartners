# Recovery runbook

What to do when something goes wrong. Written 2026-11-28. The live database is Supabase project
`qiruuiojucmlblpkflou`; the repo's `db/migrations/0001`–`0018` rebuild its schema.

## Stop everything first

- **Phone app:** Sending section → tap **Pause all sending** twice. This sets `ops_state.paused`; every send path checks
  it (autopilot emails, answers, time proposals, by-hand WhatsApp and LinkedIn). **Resume** is the same button.
- **From SQL:** `select ops_pause('reason', 'santiago');` and later `select ops_resume('santiago');`
- The client-level switch `autopilot_settings.paused` also exists (the autopilot sets it itself when its guard trips).
  Both must be off for anything to go out.

## Backups

- **Nightly:** GitHub Actions workflow `db-backup` (08:17 UTC = 02:17 Mexico City) runs `scripts/db_backup.sh`
  (`pg_dump` of the `public` schema plus a row-count manifest), restores it into a throwaway PostgreSQL 17 with
  pgvector (`scripts/db_restore_check.sh`), checks the counts and runs the privacy and sending-control tests, then
  encrypts the dump (AES-256, `BACKUP_PASSPHRASE`) and keeps it 30 days as a workflow artifact.
  It needs two repository secrets: `SUPABASE_DB_URL` (Session pooler string) and `BACKUP_PASSPHRASE`.
  Until they are added the workflow fails visibly, and there is no off-site backup.
- **Supabase's own daily backups** depend on the plan; do not count on them.
- **Before any risky change**, copy what you will change into a dated schema, e.g. `backup_20261128` (used on
  2026-11-28 for functions, views, drafts, contacts and alerts before 0016, and the US email wording).

## Restore (tested locally 2026-11-28: 59 tables, counts matched, checks passed)

1. Download the artifact (Actions → db-backup → the run → Artifacts) and unpack it:
   `gpg --decrypt sbm-backup-YYYYMMDD.tar.gz.gpg | tar xzf -` gives `sbm-….dump` and `sbm-….counts.tsv`.
2. **Prove it first** on a scratch PostgreSQL 17 with pgvector (not Supabase):
   `RESTORE_URL=postgres://…scratch… scripts/db_restore_check.sh sbm-….dump`. It mocks the Supabase roles,
   **revokes default privileges from anon/authenticated before restoring** (otherwise restored functions become callable
   with the public key again), restores everything except the `public` schema entry, compares row counts with the
   manifest and runs `verify_privacy.sql` and `verify_controls.sql`.
3. **Real restore** into a new, empty Supabase project (never on top of the live one), with its Session pooler URL:
   ```bash
   psql "$NEW" -c "create extension if not exists vector with schema public" \
     -c "alter default privileges in schema public revoke execute on functions from public, anon, authenticated" \
     -c "alter default privileges in schema public revoke all on tables from anon, authenticated"
   pg_restore --list sbm-….dump | grep -v ' SCHEMA - public ' > list.txt
   pg_restore --dbname="$NEW" --no-owner --use-list=list.txt sbm-….dump
   DATABASE_URL="$NEW" scripts/db_setup.sh --verify
   ```
4. Point the apps at the new project (phone app `phone/config.js`, dashboard `DATABASE_URL`, the project id in the
   scheduled-task prompts) only after the checks pass. Auth users (sign-ins) are not in the dump: invite Santiago again.

## Rebuild from the repo (no backup)

`scripts/db_setup.sh` on an empty Supabase project applies 0001–0018 and runs every check. Then load the real-client
seeds: `db/seed/call_kit_santa_fe_rusticos.sql` and `db/seed/growth_santa_fe_rusticos.sql`. Buyer data (companies,
contacts, drafts, activity) exists only in the database and its backups.

## Emails whose outcome is unknown

A send attempt that timed out is `delivery = 'uncertain'` (or `'attempted'` for more than 15 minutes). Nothing new is
sent until it is settled:
1. `select autopilot_reconcile_list('<client>');`
2. For each: look in Gmail Sent of santiago@sbmpartners.net.
   - Found → `select autopilot_mark_sent('<draft>', '<message id>', '<thread id>', '<sent time>');`
   - Not found → `select autopilot_reconcile_not_sent('<draft>', 'not in Sent');` (it may be sent later, after all checks)
3. Never send it again first and check afterwards.

## Alerts

`select ops_check('<client>');` lists what is wrong and writes it to `alerts` (the phone app and dashboard show them).
It clears its own alerts when the problem is gone. Kinds: `reply_monitor_stale`, `unconfirmed_sends`, `cap_exceeded`,
`send_not_logged`, `morning_run_missing`, `send_run_missing`, `summary_missing`, `run_failed`.

| Alert | First step |
|---|---|
| reply_monitor_stale | Check the "Buyer reply monitor" scheduled task ran; sending waits until it logs a run. |
| unconfirmed_sends | Reconcile (above). |
| cap_exceeded | Pause, find which path sent outside the queue (`interactions` today), fix, resume. |
| send_not_logged | Find the email in Gmail Sent and add the activity record with its Gmail message id. |
| *_run_missing / run_failed | Open the autopilot thread; re-run the stage by hand if needed. |

## Connector limits (live database)

Through the Supabase connector, `DO` blocks and `DROP` statements wait for an approval prompt nobody sees and time out.
Use plain statements, `create or replace`, and new overloads; apply long migrations in pieces under ~15 KB.
