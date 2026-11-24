# Team benchmark

Tests the whole agent team, as it is, on **fake buyers** for Santa Fe Rústicos, and scores each agent.

- Runs in a **throwaway local database** that it starts and deletes itself. Supabase is only read once, for the
  approved playbook (or pass `--playbook file.json`). A Supabase or hosted database address is always refused.
- **Nothing is sent.** The Mailer runs in dry-run mode and writes `.eml` files to the output folder.
- The fake buyers and the answer key are in `fixtures/` (13 buyers with the right pursue / nurture / disqualify
  call, 15 labelled replies, 16 drafts with planted flaws, 4 weeks of numbers for the Reporter, 3 made-up
  businesses for the web researcher).

## Run it

Needs Postgres with pgvector on the computer (Mac: `brew install postgresql@17 pgvector`) and the usual `.env`
(ANTHROPIC_API_KEY, and DATABASE_URL only to read the playbook).

```bash
set -a; source .env; set +a
python -m bench.run                     # all stages, about $10-15, stops at --budget (default $20)
python -m bench.run --only grader,sorter --budget 3
```

Read `out/benchmark/<date_time>/report.md` (scores and problems), `drafts.md` (every draft, brief and report)
and `results.json` (everything).

## What each score means

| Agent | Score | Target |
|---|---|---|
| Supervisor + safety gate | share of rule checks passed (right work at each step, nothing emailed where the rules say no) | 100 |
| Prospect researcher | share of made-up businesses where it kept no facts and rated fit 2 or lower; also cost per buyer | 100, < $0.25 |
| Strategist | per buyer: right decision 60%, right channel 20%, pitch with no past customers or made-up numbers 20% | 85 |
| Writer (pipeline) | average Grader score of every draft; fixed rule checks listed separately | 80 |
| Writer (practice) | average of 8 mock conversations, one per buyer type (round 1 was 67) | 80, none below 70 |
| Grader | share of 16 planted drafts judged right (good ≥ 70, flawed < the rewrite line of 80) | 85 |
| Reply sorter | share of 15 replies put in the right category | 90 |
| Meeting briefer | interested buyer comes out as a qualified meeting | 100 |
| Reporter | share of weekly reports where every number is in the data and a quiet week is called quiet | 100 |

Offline check of the benchmark itself (fake AI, no cost): `TEST_DATABASE_URL=postgresql:///sbm_bench python -m tests.test_benchmark`.
