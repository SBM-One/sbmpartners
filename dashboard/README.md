# SBM Partners control room (owner dashboard)

The internal dashboard for you and your team. It shows what the agents are doing, live, and is where you
approve their work.

| Page | What you do there |
|---|---|
| Overview | Drafts waiting, alerts (mark seen or resolve), each agent's spend against its budget, pause or resume an agent, change budgets, team work over the last 7 days |
| Approvals | Read each draft next to the research and the Grader's notes, edit it, then approve or reject. Nothing is sent without approval |
| Reports | Edit and approve each client's weekly report. Clients only see approved reports |
| Playbook | Approve or retire playbook entries, one at a time or all at once |
| Clients | Results for the last 30 days, missing fact sheets, and each client's daily draft limit |

## Who can log in

Only people in the `staff` table. You sign in with your email: type it in and click the link that arrives.
There's no password. To add someone, run this in the Supabase SQL Editor (one line per person):

```sql
insert into staff (name, email, role) values ('Their name', 'their@email.com', 'admin');   -- or 'operator'
```

To remove someone: `delete from staff where email = 'their@email.com';`

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

## How it's built

It's a Next.js app. Supabase handles the email login. After that, the server checks the `staff` table on
every page and every button, then reads and writes the database directly with `DATABASE_URL`. The database
connection string never reaches the browser. The database's own rules still apply here: nothing for a
do-not-contact buyer can be approved, and nothing can be marked sent without approval.
