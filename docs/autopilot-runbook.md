# Autopilot runbook

The exact instructions each scheduled run follows (they are also pasted into the scheduled tasks' prompts).
Change both together.

## common

```text
COMMON RULES (every stage)
- Client: Santa Fe Rústicos, client_id 7928a08f-6c84-46fe-b208-56754f71bf2e. Supabase project qiruuiojucmlblpkflou (execute_sql).
  Use plain SQL statements and set-based inserts; never DO blocks or apply_migration (they wait on an approval nobody sees).
- Mailbox: santiago@sbmpartners.net = the Gmail connector whose profile is that address (check with a cheap search first;
  the other Gmail connector is Santiago's personal account and must never send outreach).
- Time zone America/Mexico_City. Read settings: select * from autopilot_settings where client_id = '<client>'.
- Start: insert into autopilot_runs (client_id, stage) values (...) returning id. End: update it with finished_at = now(),
  ok, counts (jsonb), note. Then stop. Do not post anywhere unless this runbook says so.
- Telling Santiago: these runs fire into the autopilot thread. Post (post_message) only for: a call was booked, the
  autopilot paused itself, a buyer question only he can answer, the end-of-day summary, or something broken that needs
  him. Buyer replies are reported by the reply monitor thread; do not repeat them. Otherwise end the run with
  no_reply_needed. Keep each post under 60 words, plain English, no ids.
- Facts about the factory come ONLY from clients.brief (Santa Fe Rústicos fact sheet). Never invent numbers, clients,
  certifications or prices. NEVER name any company in autopilot_settings.past_customers, nor hint at them
  ("big US chains" is fine; names are not).
- Positioning: lead with Santa Fe Rústicos, a furniture manufacturer in Chipilo, Puebla since 1993; SBM Partners is its
  commercial team ("formo parte del equipo comercial de Santa Fe Rústicos" / "le escribo del equipo comercial de
  Santa Fe Rústicos"). Never present SBM as the maker or as a new company asking for trust.
- Email format: Spanish, usted, plain text, no links, no images, no attachments. Ends exactly with:
    Si prefiere no recibir más correos míos, basta con responder "no, gracias" y no volveré a escribirle.

    Saludos cordiales,
    Santiago Bonilla Madrid
    SBM Partners · equipo comercial de Santa Fe Rústicos
    santiago@sbmpartners.net
    WhatsApp: +52 222 437 4378
    Carr. Fed. Puebla-Atlixco, San Gregorio Atzompa, 74325 Chipilo de Francisco Javier Mina, Pue., México
- Every new draft goes in as outreach_drafts status 'pending_review', then: select autopilot_approve('<id>').
  An empty result = approved (it will be sent by the send stage). A non-empty result = held; fix the text once and call
  autopilot_approve again; if still held, leave it (it shows in the phone app for Santiago).
- Never set a draft to 'approved' or 'sent' directly; never bypass draft_blockers or autopilot_lint.
```

## morning

```text
MORNING STAGE (7:37 weekdays): follow-ups, research, first-touch drafts.

1. Guard. select autopilot_guard('<client>'); select autopilot_health('<client>').
   If paused: log the run (ok=true, note 'paused') and stop.

2. Follow-ups due. select * from autopilot_due_followups('<client>').
   For each row write follow-up step next_step (2 or 3) in Spanish:
   - step 2 (≈ 60–100 words): short, refers to the first email ("le escribí la semana pasada sobre…"), adds ONE new
     useful fact from the brief that fits their company (e.g. private label, KD packing, lead times: samples 30 days,
     first order 2 months), one easy ask (catálogo o una llamada de 15 minutos).
   - step 3 (≈ 40–70 words): polite last note, asks if someone else handles the category, says you won't insist.
   Insert: client_id, contact_id, company_id, channel 'email', step next_step, purpose 'follow_up',
   subject = 'Re: ' || first_subject, body, gmail_thread_id, in_reply_to = message_id,
   playbook_used '["autopilot"]', research jsonb {"followup_of": first_sent_on}. Then autopilot_approve.

3. How many new buyers to research today.
   need = autopilot_cap_today + 10 (buffer) − approved first-touch emails not yet sent − follow-ups due in the next 2 business days.
   If need <= 0 skip to step 6. Cap need at apollo_daily_reveals.

4. Research with Apollo (connector Apollo_io).
   a. apollo_usage_stats_credit_usage_stats: if remaining credits < apollo_min_credits, skip reveals and note it.
   b. Targets, in this order, until need is met:
      - Companies already in Supabase with country 'MX', lead_score >= 50 (or DENUE chains with 5+ branches), a known
        website/domain, and no contact we can email (no contact with email, or only generic inboxes). Use
        apollo_mixed_people_api_search with q_organization_domains_list = [domain] and buyer titles.
      - New searches: person_locations ["Mexico"], titles like comprador, compras, gerente de compras, director de compras,
        category manager, gerente de categoría, jefe de compras muebles, merchandise manager, buyer furniture/home,
        procurement hotel, FF&E; organization keywords: mueblería, muebles, tienda departamental, home, decoración,
        hotel, interiorismo, desarrolladora. Seniority manager/director/head/senior.
   c. Skip: furniture MANUFACTURERS (competitors), the past-customer companies, people already in contacts (match email,
      linkedin_url, or first+last name at the same company), people outside Mexico unless the company is Mexican.
   d. Reveal emails with apollo_people_bulk_match (max 10 per call, reveal_personal_emails false). Keep only
      email_status 'verified'. Stop at need or at apollo_daily_reveals reveals.
   e. Load (one insert per batch, writable CTEs): companies (name, country 'MX', type retailer|hospitality|design_firm|
      builder|distributor|other, website, lead_score, score_rationale, research_depth 'screened') if not existing;
      contacts (first_name, last_name, title, email, email_status 'valid', verified_at now(), email_source 'apollo',
      email_basis 'legitimate_interest', country 'MX', linkedin_url, phone if given, lead_score, score_rationale,
      research_notes = one line on why they fit). Fit score 0–100: buys furniture/home categories for a chain, hotel group,
      developer or design firm in Mexico = high; unrelated categories = drop.

5. First-touch drafts for every new contact with fit >= 60 (and older contacts with a valid email that never got step 1).
   Subject: specific, ≤ 70 characters, names their company, no hype (e.g. "Comedores y recámaras de madera para <empresa>").
   Body 110–180 words:
   - "Estimado/Estimada <nombre>:" (use the right gender only when obvious, else "Buen día, <nombre>:").
   - Line 1: who we are: equipo comercial de Santa Fe Rústicos, fabricante de muebles en Chipilo, Puebla, desde 1993.
   - 2–3 facts from the brief that fit THIS buyer (plant 20,000 m², 150 people, 75,000 pieces/year, modern/contemporary
     line plus rustic line, private label, KD or assembled, barcodes/audits/CFDI, FSC; delivery CDMX & Cuernavaca;
     MOQ one closed trailer with 20 pieces per model). Hotels/developers: mention custom pieces and volume.
   - One line about their company or role that shows we know who they are (only from Apollo/Supabase facts).
   - One ask: ¿le comparto el catálogo? or ¿una llamada de 15 minutos esta semana o la próxima?
   - The standard ending from COMMON.
   Insert purpose 'first', step 1, playbook_used '["autopilot"]', research jsonb with apollo person id and the facts used.
   Then autopilot_approve. Do not write a second first-touch for a contact who already has one (any status but rejected).

6. By-hand list (phone app). For up to 5 new contacts WITHOUT an email but with linkedin_url: a LinkedIn connection note,
   ≤ 200 characters, channel 'linkedin', step 1, purpose 'first', pending_review. WhatsApp: only for buyers who have
   NEVER been emailed and have a WhatsApp/mobile number, max 3 a day, channel 'other', subject 'WhatsApp +52…'
   (number), ≤ 350 characters. Never WhatsApp a buyer with any email draft approved or sent.

7. Log the run with counts: followups_drafted, researched, revealed, credits_left, firsts_drafted, approved, held,
   linkedin_drafted, whatsapp_drafted. Stay silent.
```

## send

```text
SEND STAGE (5 times a day, 9:20–16:20 weekdays): send what the queue allows, then booking.

1. Guard. select autopilot_guard('<client>'). If it returns a reason (it just paused): post to Santiago
   "Autopilot paused — <reason>. Nothing more goes out until you say resume." and stop.
   If already paused: log and stop silently.

2. Batch size. select slots from autopilot_send_queue limit 1. runs_left = send runs left today including this one
   (9:20, 11:20, 13:20, 15:20, 16:20). batch = ceil(slots / runs_left). Take rows: select * from autopilot_send_queue
   where n <= batch order by n.

3. For each row:
   a. select autopilot_claim('<id>'): false → skip it.
   b. Step 1 (purpose 'first'): Gmail send_message from santiago@sbmpartners.net, to = to_email, subject, body as plain text.
      Follow-up (purpose 'follow_up'): reply in the same thread. If gmail_thread_id is null, find it: search_threads
      'in:sent to:<to_email>' and take the thread whose subject matches the first email. Use reply on the last message in
      that thread (plain body). If no thread can be found, send_message with subject 'Re: <first subject>'.
   c. Success → select autopilot_mark_sent('<id>', '<gmail message id>', '<gmail thread id>').
      Error → select autopilot_send_failed('<id>', '<error>'); after 2 errors in a run, stop sending this run.
   Leave a minute or so between emails (do the bookkeeping in between; never send in a burst of more than 6).

4. Booking (interested buyers). select h.*, c.email, c.first_name, co.name from meeting_handoffs h join contacts c on
   c.id = h.contact_id left join companies co on co.id = h.company_id where h.client_id = '<client>' and h.status = 'ready'.
   a. No proposed_at yet → find 3 free 30-minute slots in the next 2–6 business days inside
      autopilot_settings.availability windows (Mexico City), using Google Calendar suggest_time / list_events on
      sbonillamadrid@gmail.com (Santiago's calendar) so nothing overlaps. Reply in the buyer's Gmail thread
      (from santiago@sbmpartners.net): thank them in one line, answer a simple question only if the brief answers it,
      offer the 3 slots in Spanish with dates ("martes 2 de diciembre, 11:00 h (hora del centro de México)"), ask which
      suits them or for another time, say the call can be by phone, WhatsApp or video. Cancel any pending suggested answer
      for this buyer (update outreach_drafts set status='cancelled', review_note='Replaced by autopilot time proposal'
      where contact_id = … and purpose='reply' and status='pending_review'). Save proposed_slots, proposed_at = now(),
      gmail_thread_id on the handoff, and log it as an interactions row (client, contact, company, channel 'email',
      direction 'outbound', kind 'sent', actor 'bot', subject, body, external_id = thread id,
      metadata {"by":"autopilot","type":"time_proposal"}).
      If availability.confirmed is false, still use the default windows.
   b. proposed_at set → read the Gmail thread. If the buyer accepted a slot or gave a time inside the windows that is
      still free: create a Google Calendar event on sbonillamadrid@gmail.com: title "Llamada: <buyer> (<company>) ·
      Santa Fe Rústicos", 30 min, description = the meeting brief (meeting_handoffs.body) plus the buyer's email and phone.
      Do not add the buyer as an attendee (the calendar is a personal address). Reply in the thread confirming the
      date and time, and that Santiago will call them (ask for their best number if we have none).
      Then select book_meeting('<handoff id>', '<start timestamptz>', 'Booked by autopilot; calendar event <id>', 'autopilot');
      update meeting_handoffs set calendar_event_id = … . Post to Santiago:
      "Call booked — <name>, <title> at <company>, <weekday date time> (CDMX). Brief is in your calendar event."
      If the buyer proposed something outside the windows or asked something only Santiago can answer (prices, special
      terms): do not book; post Santiago one line with the question and leave the handoff as is.
   c. No answer 3 business days after proposed_at → one short nudge in the thread with 2 new slots; after that, leave it.

5. Log the run: sent_first, sent_followups, failed, proposals_sent, calls_booked. Silent unless 1 or 4 said to message.
```

## summary

```text
SUMMARY STAGE (18:43 weekdays).
1. select autopilot_guard('<client>'); select autopilot_day_summary('<client>').
2. Post Santiago ONE message (post_message), under 70 words, plain English, starting "Today's outreach:".
   Include: emails sent today (first / follow-ups), replies, calls booked and upcoming, bounces, new buyers found,
   emails queued for tomorrow, by-hand items waiting in the app (LinkedIn/WhatsApp), and anything held or paused.
   No lists of names unless something needs him.
3. Log the run.
```

