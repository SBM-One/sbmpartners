# Reply monitor

Outreach emails go out from santiago@sbmpartners.net through the Gmail connector, so `agents/mailer.py`'s IMAP
reader never runs. A scheduled Claude task reads the inbox instead:

- **When:** every hour, Monday to Friday, 8:00 to 20:00 Mexico City (scheduled task "Buyer reply monitor").
- **What it does each run:**
  1. Finds new inbox mail from buyers and delivery failures (mailer-daemon).
  2. Sorts each one (interested, question, not now, wrong person, not interested, unsubscribe, out of office,
     bounce, other) and files it with `monitor_file_email()`. Replies show in the phone app's Replies tab and run
     `apply_reply()`, so automatic follow-ups stop. Unsubscribes call `stop_contact()`. Bounces mark the address
     invalid and cancel its unsent emails.
  3. Writes a suggested answer, saved two ways: as a Gmail draft in the buyer's thread, and as an
     `outreach_drafts` row (`purpose = 'reply'`, `pending_review`) that the app shows under To send.
     Interested buyers also get a `meeting_handoffs` row (`status = 'ready'`).
  4. Sends answers Santiago approved in the app, as a reply in the same Gmail thread. If he already sent the
     Gmail draft himself, it only records that.
  5. Logs the run in `monitor_runs`.
  6. Posts a heads-up only when a real buyer reply arrives.
- **Never:** sends an answer nobody approved; names the factory's customers.
- LinkedIn and WhatsApp replies can't be read automatically: log them in the app.

## What other stages can read

| Where | Meaning |
|---|---|
| `interactions` with `direction='inbound'`, `channel='email'`, `external_id='gmail:<message id>'` | every filed email |
| `interactions.kind` | `reply` (a real answer), `note` (auto-reply), `bounce` |
| `interactions.metadata` | `category`, `summary`, `referral`, `from`, `gmail_thread_id`, `gmail_message_id`, `matched_by` (`thread`/`address`/`domain`), `draft_id`, `by='reply-monitor'` |
| `contacts.email_status = 'invalid'` | bounced |
| `contacts.do_not_contact`, `suppressions` | unsubscribed (via `stop_contact`) |
| `outreach_drafts` with `purpose='reply'` | suggested answers; `research->>'gmail_draft_id'`, `research->>'reply_to'` |
| `outreach_drafts.gmail_thread_id` | the Gmail thread of a sent email. **Senders should fill this in** when they mark a draft `sent`, so replies match by thread (matching by address and company domain still works without it). |
| `meeting_handoffs` `status='ready'`, `reply_interaction_id` | interested buyer, waiting for a call to be booked |
| `alerts` kinds `buyer_replied`, `email_bounced` | for the dashboard |
| `monitor_runs` | one row per run |

Functions: `db/migrations/0010_reply_monitor.sql` (applied to the live database 2026-11-26). Only the database
owner can call them, not the app or the public API.
