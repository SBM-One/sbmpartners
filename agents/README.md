# SBM Partners agents

Every agent reads from and writes to the database (`db/`). Agents never message each other;
the database is the shared memory, so nothing is forgotten between runs.

| Agent | Job | Status |
|---|---|---|
| Researcher | Studies sales research on the web and drafts playbook entries, with sources | built |
| Prospect researcher | Looks up each real buyer before outreach | planned |
| Writer | Writes outreach (email, LinkedIn, call openers) using approved playbook entries only | built (practice) |
| Mock buyers | Play 8 buyer types in practice exchanges | built |
| Grader | Scores each exchange from 0 to 100 against a rubric | built |
| Supervisor | Watches scores, flags problems, writes reports for dashboards | planned |

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
