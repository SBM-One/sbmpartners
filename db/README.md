# SBM Partners database (PostgreSQL / Supabase)

One source of truth. Tools, agents, the supervisor and dashboards all read and write here.

| File | What it does |
|---|---|
| `migrations/0001_core.sql` | Tables, indexes and dashboard views. Runs on any PostgreSQL 15+ with `pgvector`. |
| `migrations/0002_supabase_privacy.sql` | Row-level security: client-portal users see only their own client's rows; the buyer network stays internal. Supabase only. |
| `seed/pilot_example.sql` | Made-up pilot data for testing. Don't load in production. |
| `tests/verify_privacy.sql` | Checks the privacy rules with throwaway test logins. Rolls back, so it saves nothing. |
| `local/supabase_mock.sql` | Local testing only: stands in for Supabase's roles and `auth.uid()`. Never run on Supabase. |

## Main areas
- **Buyer network:** `companies`, `locations`, `contacts`, `field_sources` (where every fact came from; `owned = true` marks data we collected or verified ourselves).
- **Clients:** `clients`, `client_users`, `collections`, `assets` (sales materials), `campaigns`, `campaign_targets`.
- **Activity log:** `interactions` (every email, reply, call, meeting, sample, quote and order), plus `deals`.
- **Agents and training:** `agents`, `playbook_entries`, `rubrics`, `personas`, `simulations`, `grades`.
- **Supervisor:** `agent_runs`, `alerts`, `reports`.
- **Dashboard views:** `v_client_weekly` (weekly results per client), `v_agent_scorecard` (grades next to real reply rates per bot).

## Connect to Supabase

Keys and passwords live only in a local `.env` file (ignored by git) or in your hosting provider's secret settings. Never commit them.

1. In the Supabase dashboard, click **Connect** (top bar) and copy the **Session pooler** connection string. It works on every network; the "Direct connection" host is IPv6-only and fails on many home and office networks.
2. Copy `.env.example` to `.env` and paste it as `DATABASE_URL`, replacing `[YOUR-PASSWORD]` with your database password. (Forgot it? Project Settings → Database → Reset database password.)
3. The API keys in `.env.example` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`) come from Project Settings → API. The database setup doesn't need them; the app and agents will. The service role key bypasses every privacy rule, so it stays on servers only.

## Set up the database

**Option A: Supabase SQL editor (no installs).** Open SQL Editor → New query, paste and run each file in this order:
1. `migrations/0001_core.sql`
2. `migrations/0002_supabase_privacy.sql`
3. `seed/pilot_example.sql` (test projects only)
4. `tests/verify_privacy.sql`: the last result should read "All privacy checks passed. Nothing was saved."

**Option B: from a terminal** (needs `psql`):
```bash
scripts/db_setup.sh --seed     # migrations + pilot data + privacy checks
scripts/db_setup.sh            # migrations + privacy checks, no pilot data
scripts/db_setup.sh --verify   # re-run only the privacy checks
```
The script stops at the first error, and skips the migrations if the schema is already installed.

## What the privacy check proves
- A client's portal login sees only its own client, campaigns, activity, deals, reports and client-facing alerts, and the weekly dashboard view only shows its own numbers.
- The buyer network (`companies`, `contacts`, …), internal alerts and the agent tables are hidden from every client login.
- A login that isn't linked to a client, and the public (anon) key, see nothing. Client logins can't edit data.
- Staff and backend jobs use the service role, which bypasses these rules by design.

## Test locally
```bash
createdb sbm_test && psql -d sbm_test -f db/local/supabase_mock.sql
DATABASE_URL=postgresql://localhost/sbm_test scripts/db_setup.sh --seed
```
