-- Santa Fe Rústicos: sales pack, program status, owners, missing inputs and first experiments (2026-11-28).
-- Real client data, written from what Santiago told us (fact sheet 2026-11-23, call-prep answers and baseline
-- 2026-11-26). Nothing here is invented: where two answers disagree the item is 'conflict', where we have nothing
-- it is 'missing', and neither may be used in outreach (the copy checks hold any draft that uses one).
-- Safe to run again.

-- ─────────────────────────── sales pack ───────────────────────────
-- status: confirmed (checked against a document) | client_stated (Santiago passed it on; no document yet) |
--         conflict (two answers disagree) | missing | retired
insert into sales_pack_items (client_id, topic, item, value, status, source, owner, fresh_until, lint_pattern, note) values
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','company','Founded','1993; Chipilo, Puebla','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-05-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','company','Plant and team','20,000 m² plant in Chipilo, 150 workers','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','capacity','Annual output','75,000 pieces a year','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','capacity','Monthly volume and spare capacity','Fact sheet: 30 containers a month now plus room for 30 more. Baseline: 18 trailers a month, plant at 50 % capacity.','conflict','Fact sheet 2026-11-23 vs baseline 2026-11-26','Santiago',null,
  '(30|treinta|60|sesenta|18|dieciocho) (more |m[aá]s )?(contenedores|containers|tr[aá]ilers|trailers)','Which is right: 30 containers or 18 trailers a month? Until then say only "capacity available for new programs".'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','product','Categories','Dining tables, chairs, coffee and side tables, consoles, dressers, display cabinets, wardrobes, bedroom sets, entertainment centers, bars','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','product','Styles and lines','Mainly modern / contemporary; rustic line (about 4 trailers a month)','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','product','Woods and fabric','Pine and poplar; buyer may supply its own fabric','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','product','Private label and design','Private label yes; in-house design yes','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','product','Packing','Knock-down and assembled','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','product','Catalogue and price list','Exists; SBM has not received it','missing','Santiago, call prep 2026-11-26','Santa Fe Rústicos',null,null,'Drafts offer "the catalogue"; we cannot send it until we have it.'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','product','Product photos for buyers','A ZIP of sample photos is in the project; use in outreach not yet approved','missing','Project upload','Santa Fe Rústicos',null,null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','commercial','Wholesale price range','80 to 390 per piece (currency not stated)','conflict','Santiago, fact sheet 2026-11-23','Santiago',null,
  '\m(80|390)\s*(usd|mxn|d[oó]lares|pesos)|\$\s?(80|390)\M','Currency missing (USD or MXN?). Prices are never quoted in outreach anyway.'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','commercial','Minimum order (export)','One closed trailer and at least 20 pieces per model','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,'Used in the US emails. The MXN 175,000 answer was given for Mexican buyers only.'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','commercial','Minimum order (Mexico)','Fact sheet: one closed trailer and at least 20 pieces per model. Call prep: minimum first order for Mexican buyers about MXN 175,000, while a full trailer is about MXN 450,000.','conflict','Fact sheet 2026-11-23 vs call prep 2026-11-26','Santiago',null,
  '175[ .,]?000|175 ?mil|450[ .,]?000|450 ?mil|m[ií]nimo[^.]{0,40}(tr[aá]iler|piezas)','For Mexican buyers: is the minimum a full trailer, or MXN 175,000 (less than half a trailer)?'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','commercial','Mexican buyers quoted in','MXN','client_stated','Santiago, call prep 2026-11-26','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','commercial','Payment terms','30 % deposit and 70 % at shipment, or an irrevocable confirmed sight letter of credit','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,'Commercial terms: never changed or offered differently in outreach.'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','commercial','Samples','Priced per selection, paid upfront, not credited to the order; 30 days','client_stated','Santiago, call prep 2026-11-26','Santiago','2027-02-28',
  '(muestras?|samples?)[^.]{0,40}(gratis|sin costo|free|cr[eé]dit|bonific)',null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','logistics','Incoterm and freight','Fact sheet: FOB factory. Call prep: a full trailer delivered to CDMX, Monterrey or Guadalajara is about MXN 450,000 with goods and freight together.','conflict','Fact sheet 2026-11-23 vs call prep 2026-11-26','Santiago',null,
  '(flete incluido|freight included|incluye (el )?flete|entrega(do|mos)? (en|a) (monterrey|guadalajara)|deliver(ed|y)? to (monterrey|guadalajara)|\mLAB destino)','Is freight included for Mexican buyers, and to which cities?'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','logistics','Delivery in Mexico','Fact sheet: CDMX and Cuernavaca. Call prep: CDMX, Monterrey and Guadalajara.','conflict','Fact sheet 2026-11-23 vs call prep 2026-11-26','Santiago',null,
  '(entreg|deliver|reparto|repartimos)[^.]{0,60}(monterrey|guadalajara|cuernavaca|\mMTY\M|\mGDL\M)',null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','logistics','Lead times','Samples 30 days; first order 2 months; reorders 30 days after','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','logistics','Exports','USA, Spain, Germany, Israel (98 % of sales are export)','client_stated','Santiago, fact sheet 2026-11-23 and baseline 2026-11-26','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','quality','FSC certification','Stated as held; certificate code and scope not on file','client_stated','Santiago, fact sheet 2026-11-23','Santa Fe Rústicos','2026-12-31',null,'Get the FSC certificate code before any buyer asks; FSC claims normally need the licence code.'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','quality','"FTC" certification','Listed on the fact sheet; not explained (FTC is a US agency, not a furniture certification)','conflict','Santiago, fact sheet 2026-11-23','Santiago',null,'\mFTC\M','What does FTC mean here? Until then it is never mentioned.'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','quality','Big-retailer requirements','Barcodes, audits, CFDI invoices','client_stated','Santiago, fact sheet 2026-11-23','Santa Fe Rústicos','2027-02-28',null,'Which audits, by whom, when? Needed for supplier onboarding (program F).'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','quality','Defects and claims','About 1 % defects; claims resolved within 15 days','client_stated','Santiago, call prep 2026-11-26','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','quality','Warranty','90 days','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','process','Factory visits','Welcome','client_stated','Santiago, fact sheet 2026-11-23','Santiago','2027-02-28',null,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','process','Factory phone','One salesperson answers, speaks English','client_stated','Santiago, call prep 2026-11-26','Santiago','2027-02-28',null,'Name and hours not given.'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','proof','Past customers','Never named or hinted at in outreach (list in autopilot_settings.past_customers)','confirmed','Santiago rule 2026-11-23, US list 2026-11-27','Santiago',null,null,'Enforced by the copy checks.'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','proof','Case study permission','SBM may name Santa Fe Rústicos and quote the founder publicly','client_stated','Santiago 2026-11-26','Santiago',null,null,'There are no SBM results to publish yet.')
on conflict (client_id, item) do update set topic = excluded.topic, value = excluded.value, status = excluded.status,
  source = excluded.source, owner = excluded.owner, fresh_until = excluded.fresh_until, lint_pattern = excluded.lint_pattern,
  note = excluded.note, updated_at = now();

-- ─────────────────────────── programs: where each stands ───────────────────────────
insert into client_programs (client_id, program_code, status, owner, status_note, launched_on, next_review) values
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','A','launched','Santiago (SBM)','Running since 26 Nov 2026: 38 emails out by 27 Nov (31 Mexico, 7 US), 38 US emails scheduled 30 Nov to 2 Dec. No replies, meetings or orders yet, so nothing is proven.', '2026-11-26','2026-12-18'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','B','designed','Santiago (SBM)','Screening sheet and first-message drafts ready. Waits on Santa Fe Rústicos: commission range, territories, lines that would conflict.', null,'2026-12-11'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','C','designed','Santa Fe Rústicos (asks) / SBM (drafts)','Ask templates ready. Only the factory can ask its own customers; waits on who to ask.', null,'2026-12-11'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','D','designed','Santiago (SBM)','About 100 samples went out last year and about 30 sold. Waits on the list of the other samples and of open quotes.', null,'2026-12-11'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','E','implemented','Santiago (SBM)','Inbound log with a one-business-day answer deadline is in the database. Waits on where the factory''s enquiries arrive today (website form, email, phone).', null,'2026-12-11'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','F','designed','Santiago (SBM)','Checklist ready. Waits on the factory''s documents (tax papers, audits, insurance) and on a buyer asking for vendor setup.', null,'2026-12-18'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','G','designed','Santiago (SBM)','Event scorecard ready. The factory is not attending Expo Mueble. No event spend without a scorecard and Santiago''s OK.', null,'2027-01-15'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','H','designed','Santiago (SBM) with the factory','Four offer ideas written as hypotheses; none tested. Any change to products, prices or terms is the factory''s decision.', null,'2026-12-18'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','I','designed','Santa Fe Rústicos','Baseline: largest account about 60 % of sales, second about 20 %; existing accounts could take about 40 % more. Waits on account-level data. These accounts are never named in outreach.', null,'2026-12-18'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','J','designed','Santiago (SBM)','Business case only. Recommendation: do not start now.', null,'2027-03-01')
on conflict (client_id, program_code) do update set status = excluded.status, owner = excluded.owner, status_note = excluded.status_note,
  launched_on = excluded.launched_on, next_review = excluded.next_review, updated_at = now();

-- concentration baseline (names withheld on purpose)
insert into client_accounts (client_id, name, share_pct, as_of, source, room_to_grow_pct, owner, note)
select '7928a08f-6c84-46fe-b208-56754f71bf2e', v.n, v.s, '2026-11-26', 'Santiago, baseline 2026-11-26', 40, 'Santa Fe Rústicos', 'Name withheld; existing customer.'
  from (values ('Largest existing account', 60.0), ('Second existing account', 20.0)) v(n, s)
 where not exists (select 1 from client_accounts where client_id = '7928a08f-6c84-46fe-b208-56754f71bf2e');

-- ─────────────────────────── who owns what ───────────────────────────
insert into responsibilities (client_id, area, owner, side, backup, respond_within, confirmed, note) values
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','buyer_replies','Santiago','SBM',null,'1 business day',true,'Scheduling emails go out automatically; anything about price, minimums, terms, samples or delivery waits for Santiago.'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','calls_with_buyers','Santiago','SBM',null,'Booked within 2-6 business days',true,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','quotes',null,'client',null,'Proposed: 2 business days',false,'Who prepares and sends quotes at the factory?'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','commercial_approvals',null,'client',null,'Proposed: 1 business day',false,'Who approves prices, discounts, minimums and terms?'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','samples',null,'client',null,'Quote for samples in 2 business days; samples in 30 days',false,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','factory_visits',null,'client',null,'Date offered within 5 business days',false,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','order_tracking',null,'client',null,'Weekly status to the buyer',false,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','follow_up_after_quote','Santiago','SBM',null,'3 business days after the quote',false,'Proposed: SBM follows up, the factory answers commercial questions.'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','cfdi_invoices',null,'client',null,null,false,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','sales_pack_upkeep','Santiago','SBM',null,'Review every 90 days',false,null),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','by_hand_messages','Santiago','SBM',null,'Daily, from the phone app',true,'LinkedIn notes and WhatsApp (with opt-in only).')
on conflict (client_id, area) do nothing;

-- ─────────────────────────── what we still need ───────────────────────────
insert into inputs_needed (client_id, item, needed_from, why, blocks) values
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','What "FTC" on the fact sheet means','Santa Fe Rústicos','FTC is a US agency, not a furniture certification','Mentioning it anywhere'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','FSC certificate code and scope','Santa Fe Rústicos','59 drafts mention FSC; buyers and FSC rules ask for the code','Answering certification questions'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','Minimum first order: full trailer or MXN 175,000?','Santa Fe Rústicos','The two answers disagree','Quoting minimums to Mexican buyers'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','Freight: FOB factory or delivered price, and to which cities','Santa Fe Rústicos','Fact sheet says FOB and CDMX/Cuernavaca; call prep says delivered to CDMX/Monterrey/Guadalajara','Answering delivery questions'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','Price range currency (80 to 390: USD or MXN?)','Santa Fe Rústicos','Currency missing','Price conversations (always the factory''s)'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','Monthly volume: 30 containers or 18 trailers?','Santa Fe Rústicos','Fact sheet and baseline disagree','Capacity claims'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','Catalogue and price list (file)','Santa Fe Rústicos','82 drafts offer the catalogue','Sending it when a buyer asks'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','OK to use the sample photos with buyers','Santa Fe Rústicos','Photos exist in the project','Catalogue answers, partner pack'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','Who owns quotes, approvals, samples, visits, order tracking and invoices at the factory','Santa Fe Rústicos','Nobody is named yet','Any buyer who reaches the quote stage'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','List of past samples and quotes that did not become orders','Santa Fe Rústicos','About 70 samples last year did not sell','Program D'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','Commission range and territories for reps and distributors','Santa Fe Rústicos','SBM never proposes commercial terms','Program B'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','Existing accounts: categories bought and room to grow (kept confidential)','Santa Fe Rústicos','Baseline has only shares','Program I'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','Where factory enquiries arrive today (website form, email, phone)','Santa Fe Rústicos','One new client last year came from the website','Program E'),
 ('7928a08f-6c84-46fe-b208-56754f71bf2e','Which audits the factory has passed (who, when)','Santa Fe Rústicos','"Audits" is on the fact sheet without detail','Program F'),
 (null,'Outreach sender display name','Santiago','Received mail shows "Santiago Bonilla", the agreed sender is "Santiago Bonilla Madrid, SBM Partners" (Gmail setting)','Nothing; consistency'),
 (null,'WhatsApp opt-in rule','Santiago','WhatsApp now needs a recorded opt-in; the 6 WhatsApp drafts in the app wait for it','By-hand WhatsApp'),
 (null,'Backup secrets in GitHub (SUPABASE_DB_URL, BACKUP_PASSPHRASE)','Santiago','The nightly backup cannot run without them','Off-site backups'),
 (null,'Lawyer review of the Mexico and US email rules','Santiago','Both are confirmed by Santiago, not by a lawyer; review due May 2027','Nothing now')
on conflict (client_id, item) do nothing;

-- ─────────────────────────── offer ideas (H) and the DTC case (J) ───────────────────────────
insert into offer_hypotheses (client_id, program_code, title, segment, offer, evidence, unknowns, status, note)
select '7928a08f-6c84-46fe-b208-56754f71bf2e', v.p, v.t, v.s, v.o, v.e, v.u, 'idea', v.n
  from (values
   ('H','Private label with 30-day reorders','Mexican and US chains with their own brands',
    'Private-label ranges built to the buyer''s spec, reorders shipped 30 days after the PO',
    'Private label and in-house design yes; reorders in 30 days (fact sheet)', 'Minimums per model; who pays for prototypes', null),
   ('H','Nearshore alternative to Asian imports','US retailers and e-commerce',
    'Same categories from Mexico: first order in 2 months, reorders in 30 days, KD packing',
    'Lead times and KD packing (fact sheet); exports to the USA', 'Landed cost against Asia; duty position', 'Never quote prices in outreach'),
   ('H','Hospitality furniture from the rustic line','Boutique hotels and hotel groups in Mexico',
    'Rustic and contemporary pieces for rooms and lobbies',
    'Rustic line about 4 trailers a month (fact sheet); hotel groups appear among researched leads', 'Contract-grade requirements (fire, durability); project timelines', null),
   ('H','Mixed-model first trailer','Regional Mexican chains',
    'One trailer mixing models, at least 20 pieces per model',
    'MOQ: one closed trailer and 20 pieces per model (fact sheet)', 'Whether the minimum is a full trailer or MXN 175,000 (conflict)', 'Waits on the minimum-order answer'),
   ('J','Direct to consumer','Mexican consumers online',
    'Business case only',
    'The plant ships trailers to retailers; 98 % of sales are export to retailers', 'Margins, returns, last-mile cost, channel conflict with retail buyers',
    'Recommendation: do not start now. It competes with the buyers SBM is courting and needs a retail operation the factory does not have.')
  ) v(p, t, s, o, e, u, n)
 where not exists (select 1 from offer_hypotheses where client_id = '7928a08f-6c84-46fe-b208-56754f71bf2e');

-- ─────────────────────────── first experiments ───────────────────────────
insert into experiments (client_id, program_code, hypothesis, owner, budget_cents, currency, metric, success_criteria, starts_on, review_on, status)
select '7928a08f-6c84-46fe-b208-56754f71bf2e', v.p, v.h, 'Santiago', 0, 'MXN', v.m, v.c, v.s::date, v.r::date, v.st
  from (values
   ('A','US national retailers answer an English email that leads with the factory and nearshore lead times.',
    'positive replies (interested or question) from the 45 US first emails','At least 2 positive replies by the review date; otherwise change the angle before more US sends',
    '2026-11-27','2026-12-18','running'),
   ('A','Mexican regional chains reply more often than national chains and department stores.',
    'positive reply rate by segment (Mexico)','A difference of 2x or more with at least 30 emails per segment; otherwise keep the mix',
    '2026-11-26','2026-12-18','running'),
   ('D','Buyers who already received samples answer more than cold buyers.',
    'reply rate of recovery messages against cold first emails','Higher than cold outreach on at least 20 records',
    null,'2027-01-15','planned')
  ) v(p, h, m, c, s, r, st)
 where not exists (select 1 from experiments where client_id = '7928a08f-6c84-46fe-b208-56754f71bf2e');

-- ─────────────────────────── events ───────────────────────────
insert into trade_events (client_id, name, kind, city, decision, decided_by, rationale)
select '7928a08f-6c84-46fe-b208-56754f71bf2e', 'Expo Mueble', 'fair', null, 'skip', 'Santa Fe Rústicos',
       'The factory said it is not attending (call prep 2026-11-26).'
 where not exists (select 1 from trade_events where client_id = '7928a08f-6c84-46fe-b208-56754f71bf2e' and name = 'Expo Mueble');
