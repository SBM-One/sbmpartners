-- 0017 · Growth operation records (2026-11-28): the ten growth programs, one stage path from qualified account to
-- reorder, orders that are counted once, and the records each program needs. Staff only (row security on, no
-- policies); the client portal keeps reading its own views.
--
--   programs / client_programs   A–J and where each stands for each client. "implemented" = the workflow, records
--                                and assets exist; "launched" = it is actually running with real buyers.
--   pipeline_stages              qualified account → conversation → accepted opportunity → sample/spec → quote →
--                                commercial decision → deposit/order → shipment → payment collected → reorder (+ lost)
--   deals (extended) + deal_events   one opportunity, its source program and influences, owner, next action, value,
--                                margin where known, blockers, loss reason; every stage move logged with evidence
--   orders                       one row per real order (unique per client and order reference): new account,
--                                expansion, reactivation or reorder. Never counted twice.
--   client_accounts              the client's existing customers (confidential; never used in outreach) for
--                                concentration and expansion work
--   partner_profiles, referrals, recovery_records, inbound_leads, supplier_applications, trade_events,
--   offer_hypotheses, experiments   the working records of programs B–H
--   responsibilities, inputs_needed, effort_log, spend_log   who owns what, what is still missing, time and money
--   v_scorecard                  per client and program: activity, pipeline and realized results kept apart;
--                                demo clients left out

-- ─────────────────────────── programs ───────────────────────────
create table if not exists programs (
  code        text primary key check (code ~ '^[A-J]$'),
  name        text not null,
  purpose     text not null,
  workflow    text not null,          -- the steps, in one paragraph
  records     text not null,          -- where its data lives
  measure     text not null           -- the numbers that judge it
);

create table if not exists client_programs (
  client_id    uuid not null references clients(id) on delete cascade,
  program_code text not null references programs(code),
  status       text not null default 'not_started'
               check (status in ('not_started','designed','implemented','launched','paused','stopped')),
  owner        text,
  status_note  text,                  -- what it waits on
  launched_on  date,
  next_review  date,
  updated_at   timestamptz not null default now(),
  primary key (client_id, program_code)
);

insert into programs (code, name, purpose, workflow, records, measure) values
 ('A', 'Targeted outbound',
  'Reach buyers that fit the client''s capacity, price range and categories, one account at a time.',
  'Pick accounts that fit (segment, size, categories, price tier); separate facts, estimates and unknowns in the research; write to one person per company per day; follow up twice in the same thread; any reply, refusal or colleague answer holds the whole account for a person.',
  'companies, contacts, field_sources, outreach_drafts, interactions, deals (source_program A)',
  'accounts qualified, first emails, reply rate, positive replies, meetings, accepted opportunities, orders'),
 ('B', 'Reps and distributors',
  'Add independent reps, agents and distributors who already sell to the target buyers.',
  'Screen candidates (territory, lines carried, conflicts with the client''s lines, references); Santiago approves each before contact; first message and call; commission and territory are proposed by the client, never by SBM; agreement only with the client''s signature.',
  'partner_profiles, interactions, deals (source_program B)',
  'candidates screened, conversations, agreements signed, opportunities and orders through partners'),
 ('C', 'Referrals',
  'Ask satisfied buyers and contacts for introductions.',
  'After a delivered order or a good call, the account owner asks for one introduction; SBM drafts the ask, the client sends it to its own customers; the introduced buyer is contacted naming who referred them (with their permission).',
  'referrals, deals (source_program C)',
  'asks made, introductions given, conversations, orders'),
 ('D', 'Past-opportunity recovery',
  'Reopen samples, quotes and enquiries that never became orders.',
  'The client lists past samples, quotes and enquiries; SBM checks each (still in business, still buying, why it stalled); Santiago approves the list; one personal message per account with what changed; stop on any no.',
  'recovery_records, deals (kind reactivation, source_program D)',
  'records reviewed, approved to contact, conversations reopened, orders'),
 ('E', 'Inbound wholesale and private label',
  'Answer every inbound trade enquiry quickly and qualify it.',
  'Every enquiry (website, email, WhatsApp, events) is logged with a response deadline; qualify volume, categories, timing and private-label needs; route to quote or politely decline.',
  'inbound_leads, deals (source_program E)',
  'enquiries, time to first answer, qualified share, quotes, orders'),
 ('F', 'Supplier onboarding and procurement',
  'Get approved as a vendor where a buyer requires a formal onboarding (portals, audits, tenders).',
  'Per buyer: collect requirements, the client''s documents, audits and insurance; prepare the application; submit only with the client''s approval; track until approved.',
  'supplier_applications',
  'applications open, documents missing, approved vendor numbers, orders from approved buyers'),
 ('G', 'Trade events and visits',
  'Use fairs, showrooms and factory visits where the expected buyers justify the cost.',
  'Evaluate each event (who attends, cost, the client''s time, expected meetings) before any spend; book meetings ahead; log every contact within 48 hours; review after.',
  'trade_events, interactions, deals (source_program G)',
  'cost per qualified meeting, meetings, opportunities, orders'),
 ('H', 'Offer development',
  'Shape what is offered (ranges, private label, packing, terms) to what target buyers buy.',
  'Write each offer idea as a hypothesis with its evidence; test with real buyer conversations; the client decides any change to products, prices or terms.',
  'offer_hypotheses, experiments',
  'hypotheses tested, evidence for or against, offers adopted by the client'),
 ('I', 'Existing-account expansion and concentration',
  'Grow existing customers and lower dependence on the largest one.',
  'For each existing account: share of sales, categories bought, room to grow; the client''s own team leads (these customers are never named in outreach); track concentration monthly.',
  'client_accounts, orders (kind expansion / reorder)',
  'largest-account share, revenue from accounts outside the top two, expansion orders'),
 ('J', 'Direct to consumer',
  'A separate business case, not part of B2B outreach.',
  'Only a written business case (channel, margins, returns, logistics, channel conflict with existing buyers); nothing launches without the client''s decision and budget.',
  'offer_hypotheses (program J), experiments',
  'decision taken: go / no go, and why')
on conflict (code) do update set name = excluded.name, purpose = excluded.purpose, workflow = excluded.workflow,
  records = excluded.records, measure = excluded.measure;

-- ─────────────────────────── the stage path ───────────────────────────
create table if not exists pipeline_stages (
  code        text primary key,
  ord         int not null unique,
  name        text not null,
  enters_when text not null,
  evidence    text not null,
  legacy      deal_stage not null        -- the older deals.stage it maps to (portal and meetings use it)
);
insert into pipeline_stages (code, ord, name, enters_when, evidence, legacy) values
 ('qualified_account',    1, 'Qualified account',     'The account fits and has a named buyer or a known route in.', 'research with sources', 'conversation'),
 ('conversation',         2, 'Conversation',          'The buyer answered with interest or a question, or took a call.', 'reply or call logged', 'conversation'),
 ('accepted_opportunity', 3, 'Accepted opportunity',  'The buyer named a need (categories, volume or timing) and the client agreed to pursue it.', 'note of the need + client OK', 'conversation'),
 ('sample_spec',          4, 'Sample / specification','Samples requested or specs exchanged.', 'sample order or spec sheet', 'sample'),
 ('quote',                5, 'Quote',                 'A written quote was sent by the client.', 'quote document', 'quote'),
 ('commercial_decision',  6, 'Commercial decision',   'The buyer is deciding (negotiation, vendor setup, approvals).', 'buyer''s written status', 'quote'),
 ('deposit_order',        7, 'Deposit / order',       'A purchase order was received or the deposit was paid.', 'PO or deposit receipt', 'first_order'),
 ('shipment',             8, 'Shipment',              'The goods shipped.', 'shipping document', 'first_order'),
 ('payment_collected',    9, 'Payment collected',     'The balance was paid.', 'payment receipt', 'first_order'),
 ('reorder',             10, 'Reorder',               'The same buyer ordered again.', 'new PO', 'repeat'),
 ('lost',                99, 'Lost',                  'The buyer said no or went silent after the agreed follow-ups.', 'reason recorded', 'lost')
on conflict (code) do update set ord = excluded.ord, name = excluded.name, enters_when = excluded.enters_when,
  evidence = excluded.evidence, legacy = excluded.legacy;

alter table deals add column if not exists pipeline_stage   text references pipeline_stages(code);
alter table deals add column if not exists kind             text check (kind in ('new_account','expansion','reactivation','reorder'));
alter table deals add column if not exists source_program   text references programs(code);
alter table deals add column if not exists influence        text[] not null default '{}';    -- other programs that helped
alter table deals add column if not exists owner            text;
alter table deals add column if not exists next_action      text;
alter table deals add column if not exists next_action_on   date;
alter table deals add column if not exists product_interest text;
alter table deals add column if not exists currency         text check (currency in ('MXN','USD'));
alter table deals add column if not exists est_value_cents  bigint;     -- estimate; value_cents stays the agreed value
alter table deals add column if not exists margin_pct       numeric(5,2);
alter table deals add column if not exists blockers         text;
alter table deals add column if not exists loss_reason      text check (loss_reason in ('price','moq','lead_time','quality','fit','timing','competitor','no_response','credit_terms','other'));
alter table deals add column if not exists loss_detail      text;
update deals set pipeline_stage = case stage when 'conversation' then 'conversation' when 'sample' then 'sample_spec'
                                             when 'quote' then 'quote' when 'first_order' then 'deposit_order'
                                             when 'repeat' then 'reorder' when 'lost' then 'lost' end
 where pipeline_stage is null;

create table if not exists deal_events (
  id         uuid primary key default gen_random_uuid(),
  deal_id    uuid not null references deals(id) on delete cascade,
  at         timestamptz not null default now(),
  from_stage text,
  to_stage   text not null references pipeline_stages(code),
  note       text,
  evidence   text,
  by_name    text not null
);
create index if not exists deal_events_deal_idx on deal_events(deal_id, at);

-- Move an opportunity. Evidence is required from "accepted opportunity" on, and a loss needs a reason.
create or replace function deal_move(p_deal uuid, p_stage text, p_by text, p_note text default null, p_evidence text default null,
                                     p_loss_reason text default null) returns void language plpgsql as $$
declare d deals; st pipeline_stages;
begin
  select * into d from deals where id = p_deal for update;
  if d.id is null then raise exception 'No opportunity %', p_deal; end if;
  select * into st from pipeline_stages where code = p_stage;
  if st.code is null then raise exception 'Unknown stage %', p_stage; end if;
  if st.ord between 3 and 98 and coalesce(trim(p_evidence), '') = '' then
    raise exception 'Say what shows the opportunity is at "%" (%).', st.name, st.evidence;
  end if;
  if p_stage = 'lost' and p_loss_reason is null then raise exception 'A lost opportunity needs a loss reason.'; end if;
  insert into deal_events (deal_id, from_stage, to_stage, note, evidence, by_name)
  values (p_deal, d.pipeline_stage, p_stage, p_note, p_evidence, p_by);
  update deals set pipeline_stage = p_stage, stage = st.legacy, updated_at = now(),
         loss_reason = coalesce(p_loss_reason, loss_reason),
         closed_at = case when p_stage in ('lost','payment_collected','reorder') then coalesce(closed_at, now()) else closed_at end
   where id = p_deal;
end $$;

-- ─────────────────────────── orders: counted once ───────────────────────────
create table if not exists orders (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references clients(id) on delete cascade,
  deal_id         uuid references deals(id),
  company_id      uuid references companies(id),
  account_id      uuid,                                   -- client_accounts, for existing customers
  order_ref       text not null,                          -- the client's PO / invoice number
  kind            text not null check (kind in ('new_account','expansion','reactivation','reorder')),
  source_program  text references programs(code),
  ordered_on      date not null,
  currency        text not null check (currency in ('MXN','USD')),
  value_cents     bigint not null check (value_cents >= 0),
  deposit_cents   bigint,
  deposit_on      date,
  shipped_on      date,
  paid_cents      bigint,
  paid_on         date,
  evidence        text not null,                          -- where the PO / receipt can be checked
  recorded_by     text not null,
  created_at      timestamptz not null default now(),
  unique (client_id, order_ref)
);

-- ─────────────────────────── existing customers (confidential) ───────────────────────────
create table if not exists client_accounts (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid not null references clients(id) on delete cascade,
  name             text not null,                  -- never used in outreach
  share_pct        numeric(5,2),
  monthly_cents    bigint,
  currency         text check (currency in ('MXN','USD')),
  as_of            date,
  source           text,
  room_to_grow_pct numeric(5,2),
  owner            text,
  note             text
);

-- ─────────────────────────── program records ───────────────────────────
create table if not exists partner_profiles (            -- B
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references clients(id) on delete cascade,
  company_id    uuid references companies(id),
  contact_id    uuid references contacts(id),
  kind          text not null check (kind in ('rep','agent','distributor')),
  territory     text,
  lines_carried text,
  conflicts     text,
  references_ok boolean,
  status        text not null default 'candidate' check (status in ('candidate','screened','approved_to_contact','in_talks','agreement_pending','active','declined','dropped')),
  owner         text,
  next_action_on date,
  note          text,
  created_at    timestamptz not null default now()
);

create table if not exists referrals (                    -- C
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null references clients(id) on delete cascade,
  asked_of       text not null,                -- who we asked (account or contact name; internal only)
  asked_on       date,
  introduced     text,                         -- who they introduced
  company_id     uuid references companies(id),
  contact_id     uuid references contacts(id),
  may_name_referrer boolean not null default false,
  status         text not null default 'to_ask' check (status in ('to_ask','asked','given','contacted','converted','declined')),
  deal_id        uuid references deals(id),
  note           text,
  created_at     timestamptz not null default now()
);

create table if not exists recovery_records (             -- D
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references clients(id) on delete cascade,
  company_id    uuid references companies(id),
  contact_id    uuid references contacts(id),
  what          text not null check (what in ('sample','quote','enquiry','lapsed_customer')),
  happened_on   date,
  stalled_why   text,
  source        text not null,                 -- the client's record it came from
  status        text not null default 'to_review' check (status in ('to_review','approved_to_contact','contacted','reopened','closed','do_not_contact')),
  approved_by   text,
  deal_id       uuid references deals(id),
  note          text,
  created_at    timestamptz not null default now()
);

create table if not exists inbound_leads (                -- E
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references clients(id) on delete cascade,
  received_at     timestamptz not null default now(),
  channel         text not null check (channel in ('website','email','whatsapp','phone','referral','event','other')),
  company_name    text,
  contact_name    text,
  contact_detail  text,
  kind            text not null default 'wholesale' check (kind in ('wholesale','private_label','retail_consumer','other')),
  need            text,
  respond_by      timestamptz not null default now() + interval '1 day',
  responded_at    timestamptz,
  status          text not null default 'new' check (status in ('new','answered','qualified','quoted','won','declined','disqualified')),
  company_id      uuid references companies(id),
  deal_id         uuid references deals(id),
  note            text
);

create table if not exists supplier_applications (        -- F
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references clients(id) on delete cascade,
  company_id    uuid references companies(id),
  program_name  text not null,                 -- e.g. the buyer's vendor portal
  requirements  text,
  docs_missing  text[] not null default '{}',
  status        text not null default 'identified' check (status in ('identified','requirements_known','documents_in_progress','ready_for_client_ok','submitted','approved','rejected')),
  owner         text,
  due_on        date,
  note          text,
  created_at    timestamptz not null default now()
);

create table if not exists trade_events (                 -- G
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null references clients(id) on delete cascade,
  name           text not null,
  kind           text not null check (kind in ('fair','showroom','buyer_visit','factory_visit','other')),
  city           text,
  starts_on      date,
  ends_on        date,
  est_cost_cents bigint,
  currency       text check (currency in ('MXN','USD')),
  expected_buyers text,
  decision       text not null default 'evaluate' check (decision in ('evaluate','attend','skip')),
  decided_by     text,
  rationale      text,
  meetings_target int,
  meetings_held  int,
  note           text
);

create table if not exists experiments (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid not null references clients(id) on delete cascade,
  program_code     text references programs(code),
  hypothesis       text not null,
  owner            text not null,
  budget_cents     bigint not null default 0,
  currency         text check (currency in ('MXN','USD')),
  metric           text not null,
  success_criteria text not null,
  starts_on        date,
  review_on        date not null,
  status           text not null default 'planned' check (status in ('planned','running','reviewed')),
  result           text,
  decision         text check (decision in ('continue','change','stop')),
  decided_by       text,
  decided_on       date
);

create table if not exists offer_hypotheses (             -- H (and J)
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references clients(id) on delete cascade,
  program_code  text not null default 'H' references programs(code),
  title         text not null,
  segment       text,
  offer         text not null,
  evidence      text,                  -- what we know (facts), kept apart from what we guess
  unknowns      text,
  status        text not null default 'idea' check (status in ('idea','testing','supported','not_supported','adopted','dropped')),
  experiment_id uuid references experiments(id),
  note          text
);

-- ─────────────────────────── ownership, missing inputs, time and money ───────────────────────────
create table if not exists responsibilities (
  client_id      uuid not null references clients(id) on delete cascade,
  area           text not null,          -- quotes | commercial_approvals | samples | visits | order_tracking | follow_up | ...
  owner          text,                   -- null = not assigned yet
  side           text check (side in ('SBM','client')),
  backup         text,
  respond_within text,                   -- e.g. '1 business day'
  confirmed      boolean not null default false,
  note           text,
  primary key (client_id, area)
);

create table if not exists inputs_needed (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid references clients(id) on delete cascade,
  item        text not null,
  needed_from text not null,              -- 'Santiago' | 'Santa Fe Rústicos'
  why         text not null,
  blocks      text,                       -- what waits on it
  status      text not null default 'open' check (status in ('open','received','not_needed')),
  asked_on    date not null default current_date,
  received_on date,
  answer      text,
  unique (client_id, item)
);

create table if not exists effort_log (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references clients(id) on delete cascade,
  on_date      date not null default current_date,
  who          text not null,
  program_code text references programs(code),
  minutes      int not null check (minutes > 0),
  note         text
);

create table if not exists spend_log (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid references clients(id) on delete cascade,   -- null = SBM overhead
  on_date      date not null default current_date,
  vendor       text not null,
  amount_cents bigint not null,
  currency     text not null check (currency in ('MXN','USD')),
  program_code text references programs(code),
  note         text
);

-- ─────────────────────────── scorecard ───────────────────────────
-- Activity (what we did), pipeline (what might happen) and realized (orders and cash) stay in separate columns.
-- Outbound email activity belongs to program A. Demo clients are left out.
create or replace view v_scorecard with (security_invoker = true) as
with cl as (select id, name from clients where not is_demo),
pg as (select c.id as client_id, c.name as client, p.code, p.name as program, coalesce(cp.status, 'not_started') as status,
              cp.owner, cp.status_note, cp.next_review
         from cl c cross join programs p left join client_programs cp on cp.client_id = c.id and cp.program_code = p.code),
act as (select i.client_id, 'A'::text as code,
               count(*) filter (where i.direction = 'outbound' and i.channel = 'email' and i.kind = 'sent' and coalesce(i.metadata->>'purpose','first') = 'first') as first_emails,
               count(*) filter (where i.direction = 'outbound' and i.kind = 'sent') as messages_out,
               count(*) filter (where i.direction = 'inbound' and i.kind = 'reply') as replies,
               count(*) filter (where i.direction = 'inbound' and i.kind = 'reply' and i.metadata->>'category' in ('interested','question')) as positive_replies,
               count(*) filter (where i.kind = 'meeting_booked') as meetings
          from interactions i group by i.client_id),
pipe as (select d.client_id, coalesce(d.source_program, 'A') as code,
                count(*) filter (where s.ord between 3 and 8) as open_opportunities,
                count(*) filter (where s.code = 'quote' or s.code = 'commercial_decision') as at_quote,
                sum(d.est_value_cents) filter (where s.ord between 3 and 8) as open_est_cents
           from deals d left join pipeline_stages s on s.code = d.pipeline_stage group by 1, 2),
rz as (select o.client_id, coalesce(o.source_program, 'A') as code,
                count(*) as orders, count(*) filter (where o.kind = 'new_account') as new_accounts,
                sum(o.value_cents) filter (where o.currency = 'MXN') as ordered_mxn_cents,
                sum(o.value_cents) filter (where o.currency = 'USD') as ordered_usd_cents,
                sum(o.paid_cents) filter (where o.currency = 'MXN') as collected_mxn_cents,
                sum(o.paid_cents) filter (where o.currency = 'USD') as collected_usd_cents
           from orders o group by 1, 2),
eff as (select client_id, program_code as code, sum(minutes) as minutes from effort_log group by 1, 2),
spd as (select client_id, program_code as code, sum(amount_cents) filter (where currency = 'MXN') as spend_mxn_cents,
               sum(amount_cents) filter (where currency = 'USD') as spend_usd_cents from spend_log group by 1, 2)
select pg.client, pg.code as program_code, pg.program, pg.status, pg.owner, pg.status_note, pg.next_review,
       act.first_emails, act.messages_out, act.replies, act.positive_replies, act.meetings,
       pipe.open_opportunities, pipe.at_quote, pipe.open_est_cents,
       rz.orders, rz.new_accounts, rz.ordered_mxn_cents, rz.ordered_usd_cents,
       rz.collected_mxn_cents, rz.collected_usd_cents,
       eff.minutes as effort_minutes, spd.spend_mxn_cents, spd.spend_usd_cents
  from pg
  left join act  on act.client_id  = pg.client_id and act.code  = pg.code
  left join pipe on pipe.client_id = pg.client_id and pipe.code = pg.code
  left join rz on rz.client_id = pg.client_id and rz.code = pg.code
  left join eff  on eff.client_id  = pg.client_id and eff.code  = pg.code
  left join spd  on spd.client_id  = pg.client_id and spd.code  = pg.code;

-- Largest-account share per client, from the client's own figures (program I).
create or replace view v_concentration with (security_invoker = true) as
select a.client_id, max(a.share_pct) as largest_share_pct,
       sum(a.share_pct) filter (where a.rk <= 2) as top2_share_pct, max(a.as_of) as as_of
  from (select ca.*, row_number() over (partition by client_id order by share_pct desc nulls last) rk from client_accounts ca) a
 group by a.client_id;

-- ─────────────────────────── access: staff only ───────────────────────────
alter table programs              enable row level security;
alter table client_programs       enable row level security;
alter table pipeline_stages       enable row level security;
alter table deal_events           enable row level security;
alter table orders                enable row level security;
alter table client_accounts       enable row level security;
alter table partner_profiles      enable row level security;
alter table referrals             enable row level security;
alter table recovery_records      enable row level security;
alter table inbound_leads         enable row level security;
alter table supplier_applications enable row level security;
alter table trade_events          enable row level security;
alter table experiments           enable row level security;
alter table offer_hypotheses      enable row level security;
alter table responsibilities      enable row level security;
alter table inputs_needed         enable row level security;
alter table effort_log            enable row level security;
alter table spend_log             enable row level security;
revoke all on programs, client_programs, pipeline_stages, deal_events, orders, client_accounts, partner_profiles, referrals,
  recovery_records, inbound_leads, supplier_applications, trade_events, experiments, offer_hypotheses, responsibilities,
  inputs_needed, effort_log, spend_log, v_scorecard, v_concentration from anon, authenticated;
revoke execute on function deal_move(uuid, text, text, text, text, text) from public, anon, authenticated;
