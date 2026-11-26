# SBM phone app

A small app for your phone's home screen that shows what the agents did today and lets you do every manual step:

| Tab | What it shows |
|---|---|
| **Today** | What is waiting for you, today's sends and replies, the research quota (screened, researched, drafted), what each agent finished since midnight (Mexico City time), alerts you can mark seen or resolve, and this month's AI spend |
| **To send** | Every message waiting for you, filtered by LinkedIn, WhatsApp, Calls or Email. **LinkedIn:** *Copy note + open profile*, then *Sent*. **WhatsApp:** *Open WhatsApp* (the message is already typed), then *Sent*. **Calls:** *Call* with the script on screen, then *Called*. **Email:** read, edit if needed, then *Approve* (it goes out from the mailbox within its daily limit) or *Reject* |
| **Replies** | Meetings ready or booked, with the brief, and every reply from the last 30 days |

It refreshes every 30 seconds while open, and the moment you come back to it.

## How it stays free and private

- **No server.** The app is a few static files (`index.html`, `app.js`, `style.css`), hosted free on Cloudflare Pages.
- **Sign-in** is Supabase's email code: type your email, then the 6-digit code from the email. There is no password.
- **The database decides who sees what.** The app can only call the `phone_*` functions in
  `db/migrations/0009_phone_app.sql`. Each one checks that the signed-in email is in the `staff` table, so anyone
  else gets nothing, even with the app's public key. The usual safety gate still applies: the database refuses
  do-not-contact buyers and shows why a message isn't allowed yet.
- **Cost:** $0. Cloudflare Pages is free, including for business use. Supabase's free plan pauses a project after
  7 days with no activity, and daily use keeps it awake.

## Put it online (once)

1. **Database:** run migrations up to `0009_phone_app.sql` (`scripts/db_setup.sh`), then add yourself to the team:
   ```sql
   insert into staff (name, email, role) values ('Santiago', 'santiago@sbmpartners.net', 'admin');
   ```
2. **Cloudflare Pages:** Cloudflare dashboard → **Workers & Pages → Create → Pages → Connect to Git** → pick
   `SBM-One/sbmpartners`, branch `main`. Framework preset **None**, build command empty, **build output directory
   `phone`**. Deploy. Then **Custom domains → Set up a domain → `app.sbmpartners.net`** (Cloudflare adds the DNS record).
3. **Supabase → Authentication:**
   - **URL Configuration:** Site URL `https://app.sbmpartners.net`; add `https://app.sbmpartners.net/**` to Redirect URLs.
   - **Email Templates → Magic Link:** add the code to the email, for example
     `<p>Your SBM code: <b>{{ .Token }}</b></p>` above the link. On an iPhone, a home-screen app can't receive the link,
     so the code is how you sign in there.

## Add it to your phone

Open `https://app.sbmpartners.net` and sign in. Then:

- **iPhone (Safari):** Share → **Add to Home Screen**. Open it from the home screen and sign in once more with a new code
  (the home-screen app keeps its own sign-in).
- **Android (Chrome):** menu → **Install app** (or **Add to Home screen**).

## Preview it on your computer

With a local test database (see `db/README.md`) and the demo data loaded, including `db/seed/demo_phone.sql`:

```bash
DATABASE_URL=postgres://… node scripts/phone_preview.mjs     # → http://localhost:8788, signed in as the demo staff member
```

The preview answers the app's calls itself, so no Supabase sign-in is needed. Never point it at the real database.
