# SBM Partners agents

Every agent reads from and writes to the database (`db/`). Agents never message each other;
the database is the shared memory, so nothing is forgotten between runs.

| Agent | Job | Status |
|---|---|---|
| Researcher | Studies sales research on the web and drafts playbook entries, with sources | built |
| Prospect researcher | Looks up each real buyer before outreach | planned |
| Writers | Write outreach per channel and stage, using approved playbook entries only | planned |
| Mock buyers | Play buyer types in practice exchanges | planned |
| Grader | Scores each exchange against a rubric | planned |
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

### Test without a key

`python -m tests.test_researcher` runs the whole flow with a fake AI, at no cost.
