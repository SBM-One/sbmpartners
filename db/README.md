# SBM Partners database (PostgreSQL / Supabase)

One source of truth. Tools, agents, the supervisor and dashboards all read and write here.

| File | What it does |
|---|---|
| `migrations/0001_core.sql` | Tables, indexes and dashboard views. Runs on any PostgreSQL 15+ with `pgvector`. |
| `migrations/0002_supabase_privacy.sql` | Row-level security: client-portal users see only their own client's rows; the buyer network stays internal. Supabase only. |
| `migrations/0003_agent_team.sql` | The agent team: task queue (`tasks`), approval queue (`outreach_drafts`), monthly spending caps, client fact sheets, and report approval. |
| `seed/pilot_example.sql` | Made-up pilot data for testing. Don't load in production. |
| `tests/verify_privacy.sql` | Checks the privacy rules with throwaway test logins. Rolls back, so it saves nothing. |
| `tests/verify_team.sql` | Checks the team rules: each task goes to one agent, nothing is sent without approval, do-not-contact is enforced, clients see only approved reports. Rolls back. |
| `local/supabase_mock.sql` | Local testing only: stands in for Supabase's roles and `auth.uid()`. Never run on Supabase. |

## Main areas
- **Buyer network:** `companies`, `locations`, `contacts`, `field_sources` (where every fact came from; `owned = true` marks data we collected or verified ourselves).
- **Clients:** `clients`, `client_users`, `collections`, `assets` (sales materials), `campaigns`, `campaign_targets`.
- **Activity log:** `interactions` (every email, reply, call, meeting, sample, quote and order), plus `deals`.
- **Agents and training:** `agents`, `playbook_entries`, `rubrics`, `personas`, `simulations`, `grades`.
- **Supervisor and team:** `tasks` (the team's to-do list), `outreach_drafts` (messages waiting for approval), `agent_runs` (cost of every run), `alerts`, `reports`.
- **Dashboard views:** `v_client_weekly` (weekly results per client), `v_agent_scorecard` (grades next to real reply rates per bot), `v_approval_queue` (drafts waiting for you), `v_agent_spend_month` (each agent's spend against its budget), `v_team_status` (tasks by kind and status).

## Connect to Supabase

Keys and passwords live only in a local `.env` file (ignored by git) or in your hosting provider's secret settings. Never commit them.

1. In the Supabase dashboard, click **Connect** (top bar) and copy the **Session pooler** connection string. It works on every network; the "Direct connection" host is IPv6-only and fails on many home and office networks.
2. Copy `.env.example` to `.env` and paste it as `DATABASE_URL`, replacing `[YOUR-PASSWORD]` with your database password. (Forgot it? Project Settings → Database → Reset database password.)
3. The API keys in `.env.example` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`) come from Project Settings → API. The database setup doesn't need them; the app and agents will. The service role key bypasses every privacy rule, so it stays on servers only.

## Set up the database

**Option A: Supabase SQL editor (no installs).** Open SQL Editor → New query, paste and run each file in this order:
1. `migrations/0001_core.sql`
2. `migrations/0002_supabase_privacy.sql`
3. `migrations/0003_agent_team.sql`
4. `seed/pilot_example.sql` (test projects only)
5. `tests/verify_privacy.sql`: the last result should read "All privacy checks passed. Nothing was saved."
6. `tests/verify_team.sql`: the last result should read "All team checks passed. Nothing was saved."

Already set up with 0001 and 0002? Run only `0003_agent_team.sql`, then the two checks.

**Option B: from a terminal** (needs `psql`):
```bash
scripts/db_setup.sh --seed     # migrations + pilot data + privacy checks
scripts/db_setup.sh            # migrations + privacy checks, no pilot data
scripts/db_setup.sh --verify   # re-run only the privacy checks
```
The script stops at the first error and only applies migrations that aren't installed yet.

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
