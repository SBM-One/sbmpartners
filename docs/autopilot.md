# Outreach autopilot (Santa Fe Rústicos)

The daily outreach runs on its own, Monday to Friday, Mexico City time. Santiago does not approve emails one by one:
the database's fixed checks (`autopilot_lint`, `draft_blockers`) are the reviewer. He only hears about real buyer
replies, booked calls and one short end-of-day summary. LinkedIn and WhatsApp stay by hand, in the phone app.

Each scheduled task carries its full instructions in its prompt; `docs/autopilot-runbook.md` is the same text.

## The day

| Time (MX) | Stage | Schedule | What it does |
|---|---|---|---|
| 7:37 | morning | autopilot · morning | guard, follow-ups due, Apollo research, first-touch drafts, auto-review, LinkedIn notes |
| 9:20 · 11:20 · 13:20 · 15:20 · 16:20 | send | autopilot · sends | guard, send what the queue allows, time proposals and bookings for interested buyers |
| hourly 8:00–20:00 | replies | reply monitor (its own thread) | files replies and bounces, stops follow-ups, unsubscribes, interested → meeting brief |
| 18:43 | summary | autopilot · day summary | end-of-day numbers to Santiago |

## Rules that never bend

- Never name the factory's past customers (list in `autopilot_settings.past_customers`). Lint blocks it.
- Every email: Santa Fe Rústicos named, "since 1993", SBM as its commercial team, the opt-out line, the WhatsApp line
  and the postal address. No links. Spanish, usted.
- No WhatsApp to a buyer we have emailed. WhatsApp and LinkedIn are drafted only; Santiago sends them from the app.
- Daily email cap from `autopilot_ramp` (warm-up): 18 until 29 Nov, 28 from 30 Nov, 35 from 7 Dec, 40 from 14 Dec.
  Every email counts (first touches, follow-ups, answers).
- Follow-ups: step 2 three business days after the first email, step 3 seven business days after it, as replies in
  the same Gmail thread. They stop on any reply, bounce, unsubscribe, stop or meeting.
- `autopilot_guard()` pauses everything on 3+ verified bounces in 24 h, a 5 % verified bounce rate over 7 days, or
  any spam complaint. Generic inboxes (not Apollo-verified) that bounce too much switch off email to unverified
  addresses only.
- Apollo: at most `apollo_daily_reveals` (40) email reveals a day, none below `apollo_min_credits` (300) left.
- Sends only between 9:00 and 18:00 on weekdays, from `sends_start_on` (Friday 27 Nov 2026). The two one-off Friday
  batches in the sending thread were switched off so there is one sender; the autopilot sends those approved emails.

## Pause, resume, change

```sql
update autopilot_settings set paused = true,  pause_reason = 'paused by Santiago' where client_id = '7928a08f-6c84-46fe-b208-56754f71bf2e';
update autopilot_settings set paused = false, pause_reason = null                where client_id = '7928a08f-6c84-46fe-b208-56754f71bf2e';
insert into autopilot_ramp values ('7928a08f-6c84-46fe-b208-56754f71bf2e', '2026-12-21', 45);   -- raise the cap from a date
```

Calls: offered in `autopilot_settings.availability` (Santiago confirmed weekdays 10:00–13:00 and 16:00–18:00), 30 minutes,
checked against his Google Calendar (sbonillamadrid@gmail.com). The event goes on his calendar with the meeting brief in
the description; the buyer gets the confirmation by email from santiago@sbmpartners.net.

Database: `db/migrations/0012_autopilot.sql` (applied live 2026-11-26). Reply filing: `0011_reply_monitor.sql` and
`docs/reply-monitor.md` (the reply monitor thread).
