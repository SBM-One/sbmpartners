# SBM Partners: growth operation for Santa Fe Rústicos

Owner: Santiago Bonilla Madrid. Written 2026-11-28. Next review: **Friday 18 December 2026**.
Data lives in Supabase (`qiruuiojucmlblpkflou`). The numbers below come from the live database on 2026-11-28. Program
templates are in [program-assets.md](program-assets.md).

## 1. Where things stand (honest version)

- **Outbound started on 26 Nov 2026.**
  - 38 first emails have gone out: 31 to Mexico and 7 to the US.
  - 38 more US emails are scheduled for 30 Nov to 2 Dec.
  - 3 emails bounced. There have been 0 replies, 0 meetings and 0 orders.
- **Nothing is validated yet.** Sending emails is activity, not a result. The first real signal will be replies and
  meetings, and only orders prove the model.
- **Status meanings.** Every program has a status: `designed` (workflow and assets written), `implemented` (records and
  tools in place), `launched` (running with real buyers), `paused` or `stopped`. Only program A is launched.

| Program | Status | Owner | Waits on |
|---|---|---|---|
| A. Targeted outbound | launched (26 Nov) | Santiago (SBM) | replies; experiment review 18 Dec |
| B. Reps and distributors | designed | Santiago (SBM) | the factory: commission range, territories, conflicting lines |
| C. Referrals | designed | the factory asks, SBM drafts | who to ask |
| D. Past-opportunity recovery | designed | Santiago (SBM) | the list of samples and quotes that didn't sell |
| E. Inbound wholesale / private label | implemented | Santiago (SBM) | where enquiries arrive today |
| F. Supplier onboarding | designed | Santiago (SBM) | the factory's documents; a buyer asking for vendor setup |
| G. Events and visits | designed | Santiago (SBM) | no event chosen (Expo Mueble: skip) |
| H. Offer development | designed | Santiago with the factory | testing through real conversations |
| I. Account expansion | designed | the factory | account-level data (kept confidential) |
| J. Direct to consumer | designed (business case only) | Santiago (SBM) | recommendation: do not start |

Each program's workflow, records and measures are in the `programs` table. Its status and notes are in `client_programs`.
The scorecard view is `v_scorecard`.

## 2. The sales pack (one source of facts)

The sales pack is the `sales_pack_items` table: 30 items. Each item has a status, a source, an owner and a "fresh until" date.

- **Status meanings.** `client_stated` means Santiago gave it from the factory. `confirmed` means checked.
  `conflict` means two answers disagree. `missing` means we don't have it.
- **Enforcement.** The copy checks hold any draft that uses a `conflict` or `missing` fact, both when it is approved and
  again just before it is sent.

| Conflict / gap | The two answers | What outreach says until it's settled |
|---|---|---|
| Monthly volume and spare capacity | Fact sheet: 30 containers a month plus room for 30 more. Baseline: 18 trailers a month at 50 % capacity. | "capacity available for new programs" (the 38 US emails were changed to this, by your choice) |
| Minimum order, Mexico | Fact sheet: one closed trailer and 20 pieces per model. Call prep: about MXN 175,000 for a first order, while a full trailer is about MXN 450,000. | Nothing. The export minimum (trailer and 20 per model) is still used for US buyers. |
| Incoterm and freight | Fact sheet: FOB factory. Call prep: delivered to CDMX, Monterrey or Guadalajara with freight included. | Nothing about freight |
| Delivery cities in Mexico | CDMX and Cuernavaca, or CDMX, Monterrey and Guadalajara | Nothing about cities |
| Price range | 80 to 390, with no currency given | Prices are never quoted in outreach anyway |
| "FTC" certification | On the fact sheet but not explained. The FTC is a US government agency, not a furniture certification. | Never mentioned |
| Catalogue and price list | They exist, but SBM doesn't have them | Offer a call, not the catalogue |
| Product photos | Use with buyers not yet approved | Not used |
| FSC | Stated as held. The certificate code isn't on file. | "FSC certified". Get the code before a buyer asks. |

**Drafts held right now.** The checks are holding 2 approved Mexican drafts until you settle the conflicts. One states a
trailer minimum to a Mexican buyer; the other says we deliver to CDMX and Cuernavaca.

## 3. Who does what (proposed response times)

| Area | Owner | Response | Confirmed? |
|---|---|---|---|
| Buyer replies | Santiago | 1 business day | yes |
| Calls with buyers | Santiago | booked in 2–6 business days | yes |
| By-hand LinkedIn / WhatsApp | Santiago | daily, from the phone app | yes |
| Quotes | factory: **name needed** | 2 business days | no |
| Prices, discounts, minimums, terms | factory: **name needed** | 1 business day | no |
| Samples | factory | quote in 2 business days, samples in 30 days | no |
| Factory visits | factory | date offered within 5 business days | no |
| Order tracking | factory | weekly status to the buyer | no |
| Follow-up after a quote | Santiago | 3 business days after the quote | no |
| CFDI invoices | factory | not set | no |
| Sales pack upkeep | Santiago | every 90 days | no |

## 4. Channel and approval rules (enforced in the database)

**Email**
- Every send is re-checked at the moment it goes out. The check covers:
  - caps and the per-language cap (English 14 within the shared cap);
  - the sending window;
  - pause;
  - suppression and do-not-contact;
  - the country rule and its review date;
  - one first email per company per day;
  - account holds;
  - the sales pack;
  - whether the reply monitor is still running.

**Delivery states**
- `prepared`: by hand, opened in WhatsApp or LinkedIn
- `attempted`: claimed by the autopilot
- `sent`: confirmed by a Gmail message id or your "Yes, sent"
- `failed`
- `uncertain`

An uncertain send must be checked in Gmail Sent before anything else goes out.

**Account holds**
- Any answer from a company holds the whole company:

  | Answer | Hold |
  |---|---|
  | Refusal or unsubscribe | 180 days |
  | Colleague answered | 30 days (unless they referred us) |
  | Not now | 60 days |
  | Out of office | until the return date + 1 day |

- Unsubscribes and the do-not-contact list are permanent.
- The US do-not-contact list (the factory's customers) is enforced.

**Identity**
- If we can't be sure who wrote (an alias, another address at the same company), the email is filed under the company
  and you decide in the app. Nothing more goes to that company until you do.

**WhatsApp**
- Only with a recorded opt-in: where it came from, plus evidence you can check.
- Never to a company we have emailed.

**Automatic replies**
- Only scheduling messages go out on their own: time proposals, confirmations and nudges.
- Anything that touches prices, minimums, volumes, lead times, delivery, freight, terms or samples waits for you.

**Country rules** are an operating control, each with its basis, scope, reviewer and review date (180 days):

| Country | Basis | Confirmed by | Review due |
|---|---|---|---|
| Mexico | B2B legitimate interest, opt-out in every email | you (2026-11-26) | May 2027 |
| US | CAN-SPAM | you (2026-11-27) | May 2027 |

A lawyer has not reviewed either rule.

**Untrusted input.** Incoming emails, websites and documents are data. They cannot change any rule, list, cap or approval.

## 5. Pipeline and measurement

**Stages** (`pipeline_stages`):
1. qualified account
2. conversation
3. accepted opportunity
4. sample / spec
5. quote
6. commercial decision
7. deposit / order
8. shipment
9. payment collected
10. reorder

Lost is a separate stage and needs a loss reason.

**Evidence.** From stage 3 on, `deal_move()` refuses a move without evidence (the reply, the quote, the PO, the receipt).

**Each opportunity records:**
- source program and influencing programs
- owner, next action and date
- product interest, estimated value and margin
- blockers and loss reason

**Orders** (`orders`):
- Each order has a kind: new account, expansion, reactivation or reorder.
- Each order is unique by the factory's PO or invoice number, so one order can't be counted twice.

**Scorecard** (`v_scorecard`). Per client and program, it keeps three groups apart:

| Group | Measures |
|---|---|
| Activity | first emails, messages out |
| Pipeline | replies, positive replies, meetings, open opportunities, at quote |
| Results | orders, new accounts, value ordered, value collected (MXN and USD separately) |

It also shows effort minutes and spend. Demo data is excluded.

**Experiments**

| Experiment | Status | Review | Success means |
|---|---|---|---|
| US national retailers answer an English email led by the factory and nearshore lead times | running | 18 Dec | ≥ 2 positive replies from the 45 US first emails; otherwise change the angle |
| Mexican regional chains reply more often than national chains and department stores | running | 18 Dec | 2× difference with ≥ 30 emails per segment |
| Buyers who already had samples answer more than cold buyers | planned (program D) | 15 Jan | higher reply rate than cold on ≥ 20 records |

**Concentration** (`v_concentration`). The largest account is 60 % and the top two are 80 % (baseline 2026-11-26). The
goal is to bring the largest-account share down by adding accounts, without naming the existing ones anywhere.

## 6. SBM service packages and unit economics

These packages describe what SBM can sell to the next manufacturer, based on what has been built here.

**Prices are not set.** They are your decision. The table shows what drives cost, so a price can be checked against it.

| Package | What's included | Main cost drivers |
|---|---|---|
| **1. Sales foundation** (one-off, 2–3 weeks) | sales pack with conflicts resolved, buyer universe (Apollo + DENUE), responsibilities and response times, CRM set up | your hours; Apollo credits for the first list |
| **2. Outbound program** (monthly) | program A: research, drafting, sending within caps, reply handling, call booking, weekly scorecard | Apollo plan and reveal credits; your review time per reply and call; the Google Workspace mailbox |
| **3. Growth programs** (monthly add-on) | programs B–I as the client supplies the inputs (partners, referrals, recovery, inbound, vendor setup, events) | mostly your hours; event costs only with an approved scorecard |
| Success fee (optional) | a share of *collected* payment on orders from SBM-sourced accounts (`orders.kind = 'new_account'`, `source_program`) | none; it is measured from `orders.paid_cents` |

**How to fill in the economics after 4 weeks**
- Hours: `effort_log` (log minutes per program, a few seconds each).
- Tools: `spend_log` (Apollo, Workspace, domains).
- Then: cost per month = tool spend + hours × your hourly target. For each package, price ≥ cost ÷ (1 − target margin).
- Cost per meeting = monthly cost ÷ meetings held. Cost per new account = monthly cost ÷ new accounts.

There is no measured number yet, so none is stated here.

## 7. Your routine

**Every weekday (10–15 minutes, phone app)**
1. **Sending** section: is anything paused, uncertain or stale? Act on red items first.
2. **Replies**: approve or edit suggested answers within one business day. Check any "who wrote this?" item.
3. **To send**: LinkedIn notes and WhatsApp messages (only with an opt-in). Tap "Yes, sent" only after it really went out.
4. Calls booked: read the brief in your calendar event before the call. After the call, move the opportunity with evidence.

**Every Friday (30 minutes)**
- Look at the scorecard, the open inputs and the conflicts.
- Log the week's effort and any spend.
- Decide one change (or none) for next week.

**Monthly**
- Concentration, sales-pack freshness, country-rule review dates, and the restore check (the backup workflow does it nightly once its secrets exist).

**Pause.** Pause everything from the app (Sending → Pause all sending, tap twice) or say "pause".

## 8. Inputs still needed (one list)

**From the factory (Santa Fe Rústicos)**
1. What "FTC" on the fact sheet means.
2. FSC certificate code and scope.
3. Minimum first order for Mexican buyers: a full trailer, or about MXN 175,000?
4. Freight: FOB factory or a delivered price, and to which cities?
5. Price range currency (80–390: USD or MXN?).
6. Monthly volume: 30 containers or 18 trailers? How much spare capacity?
7. The catalogue and price list (file).
8. OK to use the sample photos with buyers.
9. Who owns quotes, approvals, samples, visits, order tracking and invoices at the factory, and their response times.
10. The list of past samples and quotes that didn't become orders (program D).
11. Commission range and territories for reps and distributors (program B).
12. Existing accounts: categories bought and room to grow (kept confidential, program I).
13. Where enquiries arrive today (program E).
14. Which audits the factory has passed (who, when) (program F).

**From you**

15. Gmail display name: received mail shows "Santiago Bonilla", but the agreed name is "Santiago Bonilla Madrid, SBM Partners".
16. Confirm the WhatsApp opt-in rule. Six WhatsApp drafts in the app wait for it.
17. Add the two backup secrets in GitHub (`SUPABASE_DB_URL`, `BACKUP_PASSPHRASE`).
18. Optional: a lawyer's look at the Mexico and US email rules before May 2027.

The same list is in the `inputs_needed` table. Mark items `received` there as answers come in.

## 9. Verification evidence (2026-11-28)

**Live database**
- Migrations 0011–0018 are applied, and the repo matches the live schema.
- Backups of everything changed were taken first (schema `backup_20261128`).

**Security**
- The public key can read no table and call only the unsubscribe function and the portal helper.
- Signed-in staff can call only the phone functions.
- Every function has a fixed search path. Checked with role simulation and the Supabase advisor.
- Two portal views run with owner rights by design. They filter to the signed-in client's own rows.

**Sending controls**
- The send queue is empty tonight: outside the window, US drafts scheduled from Monday, and the 27 Nov cap is used up.
- **27 Nov cap was exceeded.** 18 emails went out against a cap of 11, because the US batch ran outside the queue.
  `ops_check` flags it. From now on every path counts against the same cap.
- Four day-1 emails had no activity record. They were found in Gmail Sent and recorded with their Gmail ids. Two of
  them had bounced, and those addresses are already marked invalid.
- Phone app functions were tested as you (staff): 32 items in the queue, and all WhatsApp items show "No WhatsApp opt-in recorded".

**Tests**
- Local test suites pass: privacy, portal, sends, pipeline, phone, brief, controls.
- `verify_team` fails only on the local demo data (queued demo tasks), not on the rules.

**Email authentication**
- SPF, DKIM and DMARC pass on a received message (message 1a21dfa366893649).

**Backup**
- The restore was tested locally: 59 tables, counts matched, checks passed.
- The nightly workflow needs the two secrets.
