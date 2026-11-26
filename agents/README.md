# SBM Partners agents

Every agent reads from and writes to the database (`db/`). Agents never message each other;
the database is the shared memory, so nothing is forgotten between runs.

| Agent | Job | Status |
|---|---|---|
| Researcher | Studies sales research on the web and drafts playbook entries, with sources | built |
| Prospect researcher | Looks up each real buyer on the web before outreach, keeping only facts from pages it opened | built |
| Strategist | Scores each researched buyer's fit (0-100), decides pursue / nurture / disqualify, plans the pitch and picks the channel | built |
| Writer | Writes outreach, follow-ups, answers to replies and one check-in after "not now", using approved playbook entries only | built |
| Mock buyers | Play 8 buyer types in practice exchanges | built |
| Grader | Scores each practice exchange and every real draft from 0 to 100 against a rubric | built |
| Supervisor | Hands out work, paces outreach, enforces budgets, raises alerts (fixed rules, no AI cost) | built |
| Reporter | Writes each client's weekly report from the database numbers, for your approval | built |
| Onboarder | Drafts a client's fact sheet from their catalog, price list or website, for your approval | built |
| Mailer | Sends approved emails slowly within the mailbox's daily cap, with address and unsubscribe link | built (no AI) |
| Reply sorter | Reads replies, sorts them, stops follow-ups, snoozes "not now", and ends all contact on "unsubscribe" | built |
| Meeting briefer | Turns an interested buyer into a meeting brief for you: interest, product fit, checks, contact history, next steps | built |

## The Researcher

For each topic in `research_topics.json` it searches the web, reads studies, papers and large data
sets, and writes 3 to 6 playbook entries per topic. Each entry has:

- the tactic in our own words, with an example and its caveats,
- an evidence rating (strong, moderate or weak),
- the sources it came from. Any source the agent didn't actually open is removed automatically.

Everything is saved as a **draft**. Sales agents only ever use entries a person has approved.

### Run it (one time setup, then one command)

You need Python 3.10 or newer and an Anthropic API key (console.anthropic.com → API keys).

```bash
pip install -r requirements.txt
cp .env.example .env            # then paste your key after ANTHROPIC_API_KEY=
set -a; source .env; set +a
python -m agents.researcher     # all topics; or: --only cold-email-first-touch
```

A full run of all 11 topics takes roughly 20 to 40 minutes. It prints the running cost as it goes;
expect a few dollars per topic.

### What you get (in `out/research/<date>/`)

- `playbook_draft.md`: the draft playbook to read and review.
- `playbook_draft.sql`: loads the drafts into Supabase. Open SQL Editor, paste the file, click Run.
- `notes_<topic>.md`: the agent's full research notes, if you want to dig deeper.

### Approve entries

In Supabase, open **Table Editor → playbook_entries**, and change `status` from `draft` to
`active` on the entries you approve (or to `retired` for the ones you reject).

### Change what it studies

Edit `research_topics.json`: each topic is one question, plus optional default channel, stage and
buyer types. Add a topic, then run `python -m agents.researcher --only <its id>`.

## The practice round

`python -m agents.practice` runs practice exchanges between the Writer and the Mock buyers, and the
Grader scores each one. Default is 50 exchanges, spread evenly over the 8 buyer types in
`personas.json`. It stops starting new exchanges once it passes `--budget` dollars (default $15).

- **The Writer** uses only approved playbook entries: from the database (`status = active`) when
  `DATABASE_URL` is set, otherwise from the latest `playbook_draft.json`. It may only state facts in
  the client brief. The default brief, `sample_client.json`, is a made-up brand for practice;
  pass `--client your_brief.json` for a real one.
- **Mock buyers** reply the way real ones do: they ignore most messages, push back, or say yes.
  If ignored, the Writer sends one follow-up. If answered, the Writer replies, for up to 3 turns.
- **The Grader** scores each skill in `rubric.json` from 0 to 10 and explains why. Invented facts or
  pressure tactics cap the score at 40.

Output in `out/practice/<time>/`: `report.md` (average score, scores by buyer and by skill, what to
improve, best and weakest exchanges), `results.json`, and `practice.sql`. With `DATABASE_URL` set,
the results are saved to the database automatically; otherwise, paste `practice.sql` in the SQL
Editor. Saved grades show up in the `v_agent_scorecard` dashboard view.

Models: the Writer and Grader use Claude Opus. Mock buyers use Claude Sonnet, which is cheaper.
Change them with `SBM_WRITER_MODEL`, `SBM_GRADER_MODEL` and `SBM_BUYER_MODEL`.

### Test without a key

`python -m tests.test_researcher` and `python -m tests.test_practice` run the whole flow with a fake AI, at no cost.

## The agent team (real campaigns)

`python -m agents.team run` keeps the team working. Every 5 minutes the **Supervisor** checks the
database and hands out tasks; each agent picks up its own kind of task from the `tasks` table.

For each live campaign:
1. The Supervisor picks the best-fit buyers in `campaign_targets` (never anyone marked do-not-contact),
   up to the client's `daily_draft_limit` per day (20 unless changed).
2. The **Prospect researcher** looks each one up on the web. Facts from pages it didn't actually open are dropped.
3. The **Strategist** scores the fit from 0 to 100 (product fit 30, kind of buyer 20, price level 20, decision maker 15,
   timing 15) and decides: **pursue**, **nurture** (not now) or **disqualify**. Pursue needs at least the campaign's
   `min_fit_score` (60) and clear product fit. It also plans the pitch (angle, what to lead with, proof, offer, likely
   objections, the one ask) and the channel the rules allow: email, email plus a LinkedIn note, or LinkedIn only
   (e.g. Germany without consent). Saved in `prospect_strategies`; you can overrule it on the Buyers page, and it never
   overwrites your decision. The database refuses a first message to anyone not marked pursue.
4. The **Writer** drafts the first message from the client's fact sheet, the approved playbook, the research and the strategy.
   The **Grader** scores it; below the Writer's `min_score` (80) it gets one rewrite with the Grader's feedback.
5. The draft waits in `outreach_drafts` with status `pending_review` until a person approves it on the dashboard.
   If the campaign's channels include `linkedin` and the buyer has a `linkedin_url`, the Writer also drafts a short
   connection note (no pitch, at most 280 characters) for you to send by hand.
6. Approved emails go out through the **Mailer** (below). A sent email with no answer after the campaign's
   `followup_days` (5) gets a follow-up draft, up to `max_steps` (3) messages; each follow-up waits for approval too.
7. When a buyer replies (by email, or logged by you on the Buyers page for LinkedIn or a call), `apply_reply()` stops
   their follow-ups. Interested or a question: the **Writer** drafts our answer, sent in their thread once you approve.
   Interested: the **Meeting briefer** writes a brief on the Meetings page and you get an urgent alert. "Not now": the
   buyer is snoozed for the campaign's `snooze_days` (60), then gets one check-in draft. "Stop": everything ends.
8. You book the meeting on the Meetings page: it is logged, a deal opens in the client's pipeline, the buyer moves to
   "meeting", and no automatic message goes to them again. Afterwards you mark it held, no-show or cancelled.
   `v_conversations` (the Buyers page) shows where every buyer stands.

Every Monday the **Reporter** drafts last week's report for each client (`reports`, status `draft`).
Clients only ever see reports you set to `approved`.

### Before the first real run
1. In Supabase, run `db/migrations/0005_first_sends.sql`, then `db/tests/verify_sends.sql` (SQL Editor, paste, Run).
2. Draft the client's fact sheet from their own material, then check and approve it on the dashboard's Clients page:
   `python -m agents.onboard --client "Brand name" --file catalog.pdf --file prices.pdf --website https://brand.com`
   (add `--create` for a new client). It lists the questions to ask the client that their material doesn't answer.
3. On the Clients page, fill in who the emails come from: name, "on behalf of", and a real postal address.
4. Approve playbook entries (status `active`), add buyers to a campaign's `campaign_targets`, campaign status `live`.
   For each buyer record `country` (or the company's), `email_basis` and `email_source` (see the safety gate below).
5. Check the target country's email rule with a lawyer and confirm it on the Sending page.

### The safety gate
Before anything can be approved, and again right before it is sent, the database runs `send_blockers()`. A draft is
refused while any of these is true: the buyer is do-not-contact or on the suppression list; the client's fact sheet
is not approved; for email: no address, a bounced address, no record of where the address came from, no sender name
or postal address, an unknown country, a country rule nobody has confirmed, a consent-only country (Germany, Spain,
Italy…) without recorded consent, or a follow-up to a buyer who already answered. The Drafts page shows the reasons
and lets you fix the buyer's details there. The starting country rules are cautious defaults, **not legal advice**.

### The Mailer: sending and replies
Add to `.env` on the computer that runs the team:
```
MAIL_ADDRESS=ana@yourdomain.com          # a real mailbox, ideally on a separate sending domain with SPF, DKIM and DMARC
MAIL_PASSWORD=...                        # Google Workspace: an app password (Google Account > Security > App passwords)
MAIL_DISPLAY_NAME=Ana Ruiz
UNSUBSCRIBE_URL=https://your-dashboard.vercel.app   # the dashboard's address; the unsubscribe page lives there
# SMTP_HOST=smtp.gmail.com  SMTP_PORT=465  IMAP_HOST=imap.gmail.com   (defaults; change for other providers)
```
Then `python -m agents.mailer setup` once. From then on `python -m agents.team run` also sends and reads replies
each round. `MAIL_DRY_RUN=1` writes each email to `out/mail/` instead of sending it: use it only against a test
database, because the emails are marked as sent.

- Sends one approved email at a time, Monday to Friday within the mailbox's hours, at most `daily_cap` a day
  (15 to start), with a random pause of at least `min_gap_minutes`. Change these on the dashboard's Sending page.
- Adds the sender's name and postal address and an unsubscribe link to every email, plus the one-click
  unsubscribe headers Gmail and Yahoo require. Follow-ups are sent as replies in the same thread.
- Never sends an email twice: it is marked as taken before it is handed to the mail server.
- Reads new mail in the inbox (without marking it read). "Unsubscribe", "remove me" and similar (in several
  languages) stop all contact without the AI; other replies are sorted by Claude. Interested buyers and questions
  raise an urgent alert: you reply yourself. Any reply cancels that buyer's follow-ups. Bounces mark the address invalid.

### Approve or reject drafts
On the dashboard's Drafts page. Emails then wait on the Sending page; LinkedIn notes on the LinkedIn page, where
you send them by hand and mark them sent. Nothing ever automates the LinkedIn account.

### Spending caps
Each agent has a monthly budget in `agents.monthly_budget_cents` (Writer and Grader $100, Prospect researcher $50,
Reporter $20). At 80% you get a warning alert; at 100% the Supervisor pauses that agent and raises an urgent alert.
It resumes on the 1st of the month, or as soon as you raise the budget. See spend with
`python -m agents.team status` or `select * from v_agent_spend_month`.

### Run it on a cloud server instead of your Mac
The repo includes a `Dockerfile` and `Procfile`, so Railway or Fly.io can run it as-is: create a project from
this GitHub repo, add `DATABASE_URL` and `ANTHROPIC_API_KEY` as secrets (variables) in their dashboard, and
deploy. It runs `python -m agents.team run` and restarts on its own if it crashes.

### Models
Writer, Grader, Onboarder and Reply sorter: Claude Opus. Prospect researcher and Reporter: Claude Sonnet (cheaper).
Change them with `SBM_WRITER_MODEL`, `SBM_GRADER_MODEL`, `SBM_PROSPECT_MODEL`, `SBM_REPORTER_MODEL`,
`SBM_ONBOARD_MODEL`, `SBM_REPLY_MODEL`.

### Test without a key
`TEST_DATABASE_URL=postgresql:///sbm_test python -m tests.test_team` runs the whole team with a fake AI against a
throwaway local database (see the file's header). It checks pacing, rewrites, source checks, budget caps, retries and alerts.
`TEST_DATABASE_URL=postgresql:///sbm_test python -m tests.test_sends` checks sending and replies with a fake mail
server: approval only, sending window, gaps, daily cap, held emails, threaded follow-ups, reply sorting,
unsubscribes on every channel, bounces and refused addresses.
