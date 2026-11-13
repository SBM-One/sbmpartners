# SBM Partners dashboard: control room and client portal

One app, two views, one login page:

- **Control room** (you and your team): what the agents are doing, live, and where you approve their work.
- **Client portal** (each client): their own results, pipeline and approved weekly reports. Nothing else.

The design follows the website: Aegean blue and Navy with Gold as the one accent, Instrument Sans headings with
Instrument Serif italic accents, Geist for text. The fonts ship with the app, so nothing loads from Google.

| Page | What you do there |
|---|---|
| Overview | Drafts waiting, alerts (mark seen or resolve), each agent's spend against its budget, pause or resume an agent, change budgets, team work over the last 7 days |
| Approvals | Read each draft next to the research and the Grader's notes, edit it, then approve or reject. Nothing is sent without approval |
| Reports | Edit and approve each client's weekly report. Clients only see approved reports |
| Playbook | Approve or retire playbook entries, one at a time or all at once |
| Clients | Results for the last 30 days, missing fact sheets, and each client's daily draft limit |

## The client portal

| Page | What the client sees |
|---|---|
| Overview | A plain-language summary of the last 30 days, orders by week, replies, meetings, samples and quotes, where every buyer stands, the latest buyer activity, this week's report and updates you chose to share |
| Pipeline | Every buyer we're talking to for them, their stage, value and last activity |
| Reports | Every weekly report you approved, laid out like a letter |

Clients never see drafts, unapproved reports, other clients, AI costs, buyer emails or phone numbers.
You can see exactly what a client sees: **Preview the portal** in the sidebar, or **Portal** next to a client on
the Clients page. A navy strip at the top reminds you it's a preview and lets you switch clients.

**How the privacy works.** A client's pages run inside the database as that client's login, so Supabase's
row-level security decides what comes back, and every query also filters on their client. The pipeline and
activity come from two views (`db/migrations/0004_client_portal.sql`) that show a few safe columns only.
`db/tests/verify_portal.sql` proves it: run it in the SQL Editor after the migration.

**Give someone at a client a login** (SQL Editor, one line per person):

```sql
insert into client_users (client_id, email, name)
values ((select id from clients where name = 'Their company'), 'them@company.com', 'Their name');
```

They sign in on the same page as you, with the email link. The first sign-in links their login to that row.

## Who can log in

People in the `staff` table get the control room; people in `client_users` get their portal. Everyone else is
turned away. You sign in with your email: type it in and click the link that arrives.
There's no password. To add someone, run this in the Supabase SQL Editor (one line per person):

```sql
insert into staff (name, email, role) values ('Their name', 'their@email.com', 'admin');   -- or 'operator'
```

To remove someone: `delete from staff where email = 'their@email.com';`

## Before the first deploy with the portal

In the Supabase SQL Editor, run `db/migrations/0004_client_portal.sql`, then `db/tests/verify_portal.sql`. The
last line should read "All portal checks passed. Nothing was saved."

## Put it online (Vercel, about 10 minutes)

1. Sign in at vercel.com with GitHub. Click **Add New → Project**, then pick `SBM-One/sbmpartners`.
2. Set **Root Directory** to `dashboard`.
3. Under **Environment Variables**, add these three:
   - `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY`: from Supabase → Project Settings → API.
   - `DATABASE_URL`: the same Session pooler connection string the agents use.
4. Click **Deploy**. You get an address like `sbm-dashboard.vercel.app`. You can connect your own domain later.
5. In Supabase, go to **Authentication → URL Configuration**. Set **Site URL** to that address, and add
   `https://<that address>/auth/callback` under **Redirect URLs**.

## Run it on your computer

```bash
cd dashboard
cp .env.example .env.local     # fill in the three values
npm install
npm run dev                    # open http://localhost:3000
```

## Preview it with made-up data

```bash
createdb sbm_demo && psql -d sbm_demo -f ../db/local/supabase_mock.sql
for f in ../db/migrations/*.sql ../db/seed/demo_dashboard.sql; do psql -d sbm_demo -f "$f"; done
# .env.local: DATABASE_URL=postgresql://localhost/sbm_demo
#   DEV_LOGIN_EMAIL=yago@sbm-demo.example            (control room)
#   DEV_LOGIN_EMAIL=claire@harbourline-demo.example  (a client's portal)
npm run dev
```

## How it's built

It's a Next.js app. Supabase handles the email login. After that, the server checks the `staff` table on
every page and every button, then reads and writes the database directly with `DATABASE_URL`. The database
connection string never reaches the browser. The database's own rules still apply here: nothing for a
do-not-contact buyer can be approved, and nothing can be marked sent without approval.
