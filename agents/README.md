# SBM Partners agents

Every agent reads from and writes to the database (`db/`). Agents never message each other;
the database is the shared memory, so nothing is forgotten between runs.

| Agent | Job | Status |
|---|---|---|
| Researcher | Studies sales research on the web and drafts playbook entries, with sources | built |
| Prospect researcher | Looks up each real buyer on the web before outreach, keeping only facts from pages it opened | built |
| Writer | Writes outreach (email, LinkedIn, call openers) using approved playbook entries only | built |
| Mock buyers | Play 8 buyer types in practice exchanges | built |
| Grader | Scores each practice exchange and every real draft from 0 to 100 against a rubric | built |
| Supervisor | Hands out work, paces outreach, enforces budgets, raises alerts (fixed rules, no AI cost) | built |
| Reporter | Writes each client's weekly report from the database numbers, for your approval | built |

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
3. The **Writer** drafts the first message from the client's fact sheet, the approved playbook and the research.
   The **Grader** scores it; below the Writer's `min_score` (80) it gets one rewrite with the Grader's feedback.
4. The draft waits in `outreach_drafts` with status `pending_review`. **Nothing is ever sent from here.**

Every Monday the **Reporter** drafts last week's report for each client (`reports`, status `draft`).
Clients only ever see reports you set to `approved`.

### Before the first real run
1. In Supabase, run `db/migrations/0003_agent_team.sql`, then `db/tests/verify_team.sql` (SQL Editor, paste, Run).
2. Save the brand's fact sheet (same shape as `sample_client.json`):
   `python -m agents.team set-brief --client "Brand name" --file brief.json`
3. Approve playbook entries (status `active`), and add buyers to a campaign's `campaign_targets`, campaign status `live`.

### Approve or reject drafts
Until the dashboard is built: Supabase → Table Editor → `outreach_drafts` (or SQL Editor:
`select * from v_approval_queue`). Change `status` to `approved` or `rejected`, and add a `review_note` if you like.
The database refuses to approve anything for a do-not-contact buyer, and refuses `sent` unless it was approved first.

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
Writer and Grader: Claude Opus. Prospect researcher and Reporter: Claude Sonnet (cheaper). Change them with
`SBM_WRITER_MODEL`, `SBM_GRADER_MODEL`, `SBM_PROSPECT_MODEL`, `SBM_REPORTER_MODEL`.

### Test without a key
`TEST_DATABASE_URL=postgresql:///sbm_test python -m tests.test_team` runs the whole team with a fake AI against a
throwaway local database (see the file's header). It checks pacing, rewrites, source checks, budget caps, retries and alerts.
