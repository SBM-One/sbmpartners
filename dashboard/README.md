# SBM Partners dashboard: control room and client portal

One app, two views, one login page:

- **Control room** (you and your team): what the agents are doing, live, and where you approve their work.
- **Client portal** (each client): their own results, pipeline and approved weekly reports. Nothing else.

The design is one idea, used on every page: it reads like a private-bank statement. A sentence says where things
stand, a ledger lists the names behind it, and a letter explains it. There are no cards, icons, badges or
decorative charts. Colours and fonts are the website's (Navy and Aegean on Porcelain, Gold only for money won;
Instrument Serif, Instrument Sans and Geist). The fonts ship with the app, so nothing loads from Google.

| Page | What you do there |
|---|---|
| Today | What is waiting for you (drafts, letters, new playbook tactics, alerts you can mark seen or resolve), how each client is doing, and each agent's spend, budget and pause switch |
| Drafts | Read and edit each draft, with the research and the Grader's notes underneath, then approve or reject. Nothing is sent without approval |
| Letters | Edit and approve each client's weekly letter. Clients only see approved letters |
| Playbook | Approve or retire playbook entries, one at a time or all at once |
| Clients | Fact sheets, live campaigns, each client's daily draft limit and portal logins |

## The client portal

| Page | What the client sees |
|---|---|
| Their page | One sentence on orders won and buyers deciding, the last 30 days in a line, notes you chose to share, every buyer in conversation with how far along they are and what happened last, and the opening of this week's letter |
| Letters | Every weekly letter you approved |

Clients never see drafts, unapproved reports, other clients, AI costs, buyer emails or phone numbers.
You can see exactly what a client sees: **Their page** next to a client on Today or the Clients page. A navy strip at the top reminds you it's a preview and lets you switch clients.

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
