-- SBM Partners · core schema (PostgreSQL 15+; runs as-is on Supabase)
-- One source of truth: every tool, agent and dashboard reads and writes here.

create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists vector;     -- buyer similarity (pgvector)

-- ─────────────────────────── enums ───────────────────────────
create type buyer_type        as enum ('retailer','design_firm','hospitality','builder','distributor','dealer','contract','other');
create type channel           as enum ('email','linkedin','call','sms','meeting','form','ad','other');
create type direction         as enum ('outbound','inbound');
create type interaction_kind  as enum ('sent','opened','clicked','reply','bounce','unsubscribe','call','voicemail','meeting_booked','meeting_held','sample_sent','quote_sent','order','reorder','note');
create type actor             as enum ('bot','staff','buyer','system');
create type target_status     as enum ('queued','contacted','engaged','meeting','won','lost','do_not_contact');
create type deal_stage        as enum ('conversation','sample','quote','first_order','repeat','lost');
create type asset_kind        as enum ('sell_sheet','line_sheet','brochure','catalog','video','ad','trade_site','other');
create type agent_role        as enum ('researcher','writer','mock_buyer','grader','supervisor');
create type entry_status      as enum ('draft','active','retired');
create type severity          as enum ('info','warning','urgent');
create type alert_status      as enum ('open','acknowledged','resolved');

create or replace function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

-- ─────────────────────────── clients (our customers) ───────────────────────────
create table clients (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  industry      text,                         -- e.g. 'furniture'
  plan          text check (plan in ('sprint','outbound','growth','partner')),
  status        text not null default 'active' check (status in ('prospect','active','paused','churned')),
  founding_partner boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create trigger clients_touch before update on clients for each row execute function touch_updated_at();

create table staff (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  email      text not null unique,
  role       text not null default 'operator' check (role in ('admin','operator','caller','designer')),
  created_at timestamptz not null default now()
);

-- people at a client who can log into the client portal
create table client_users (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null references clients(id) on delete cascade,
  email      text not null,
  name       text,
  auth_user_id uuid,                          -- Supabase auth.users.id once they sign up
  created_at timestamptz not null default now(),
  unique (client_id, email)
);

-- ─────────────────────────── the buyer network (proprietary) ───────────────────────────
create table companies (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  domain       text unique,                   -- main de-duplication key
  type         buyer_type not null default 'other',
  categories   text[] not null default '{}',  -- what they carry: upholstery, lighting, tile…
  style_tags   text[] not null default '{}',  -- coastal, modern, traditional…
  price_tier   text check (price_tier in ('value','mid','upper','luxury')),
  store_count  int,
  hq_city      text,
  hq_state     text,
  country      text not null default 'US',
  website      text,
  phone        text,
  notes        text,
  embedding    vector(1024),                  -- for "find buyers like these"
  verified_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger companies_touch before update on companies for each row execute function touch_updated_at();
create index companies_type_idx on companies(type);
create index companies_state_idx on companies(hq_state);
create index companies_categories_idx on companies using gin(categories);

create table locations (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies(id) on delete cascade,
  label       text,
  address     text,
  city        text,
  state       text,
  country     text not null default 'US',
  lat         double precision,
  lon         double precision
);
create index locations_company_idx on locations(company_id);

create table contacts (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid references companies(id) on delete set null,
  first_name     text,
  last_name      text,
  title          text,
  email          text unique,
  email_status   text check (email_status in ('unknown','valid','risky','invalid')) default 'unknown',
  phone          text,
  linkedin_url   text unique,
  is_decision_maker boolean,
  do_not_contact boolean not null default false,   -- honored everywhere (unsubscribes, requests)
  verified_at    timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create trigger contacts_touch before update on contacts for each row execute function touch_updated_at();
create index contacts_company_idx on contacts(company_id);

-- where every fact came from (keeps rented data separate from data we own)
create table field_sources (
  id          bigserial primary key,
  entity      text not null check (entity in ('company','contact','location')),
  entity_id   uuid not null,
  field       text not null,
  value       text,
  source      text not null,                  -- 'apollo', 'website', 'trade_show:high_point', 'caller_verified', …
  owned       boolean not null default false, -- true = collected/verified by us, safe to keep and reuse
  confidence  real check (confidence between 0 and 1),
  observed_at timestamptz not null default now()
);
create index field_sources_entity_idx on field_sources(entity, entity_id);

-- ─────────────────────────── client products & sales materials ───────────────────────────
create table collections (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references clients(id) on delete cascade,
  name        text not null,
  category    text,
  description text,
  price_from_cents int,
  created_at  timestamptz not null default now()
);

create table assets (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references clients(id) on delete cascade,
  collection_id uuid references collections(id) on delete set null,
  kind          asset_kind not null,
  title         text not null,
  url           text,
  created_at    timestamptz not null default now()
);

-- ─────────────────────────── campaigns ───────────────────────────
create table campaigns (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references clients(id) on delete cascade,
  name         text not null,
  channels     channel[] not null default '{email}',
  buyer_types  buyer_type[] not null default '{}',
  status       text not null default 'draft' check (status in ('draft','live','paused','done')),
  starts_on    date,
  created_at   timestamptz not null default now()
);

create table campaign_targets (
  campaign_id  uuid not null references campaigns(id) on delete cascade,
  contact_id   uuid not null references contacts(id) on delete cascade,
  company_id   uuid references companies(id) on delete set null,
  fit_score    real check (fit_score between 0 and 1),
  status       target_status not null default 'queued',
  updated_at   timestamptz not null default now(),
  primary key (campaign_id, contact_id)
);

-- ─────────────────────────── the activity log (heart of the system) ───────────────────────────
create table interactions (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references clients(id) on delete cascade,
  campaign_id  uuid references campaigns(id) on delete set null,
  company_id   uuid references companies(id) on delete set null,
  contact_id   uuid references contacts(id) on delete set null,
  channel      channel not null,
  direction    direction not null,
  kind         interaction_kind not null,
  actor        actor not null,
  agent_id     uuid,                          -- which bot wrote it (if actor = bot)
  subject      text,
  body         text,
  value_cents  bigint,                        -- orders / quotes
  external_id  text,                          -- id in the email tool / CRM, for idempotent webhooks
  metadata     jsonb not null default '{}',
  occurred_at  timestamptz not null default now(),
  created_at   timestamptz not null default now(),
  unique (channel, external_id)
);
create index interactions_client_time_idx on interactions(client_id, occurred_at desc);
create index interactions_contact_idx on interactions(contact_id, occurred_at);
create index interactions_kind_idx on interactions(kind);

create table deals (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references clients(id) on delete cascade,
  company_id    uuid references companies(id) on delete set null,
  contact_id    uuid references contacts(id) on delete set null,
  stage         deal_stage not null default 'conversation',
  value_cents   bigint,
  opened_at     timestamptz not null default now(),
  closed_at     timestamptz,
  updated_at    timestamptz not null default now()
);
create trigger deals_touch before update on deals for each row execute function touch_updated_at();

-- ─────────────────────────── agents, playbook, training & grading ───────────────────────────
create table agents (
  id             uuid primary key default gen_random_uuid(),
  name           text not null unique,
  role           agent_role not null,
  model          text not null,               -- e.g. claude-opus-5-5, claude-haiku-5-5
  prompt_version text not null default 'v1',
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);
alter table interactions add constraint interactions_agent_fk foreign key (agent_id) references agents(id) on delete set null;

create table playbook_entries (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  body         text not null,                 -- the tactic, in our own words
  channel      channel,
  buyer_types  buyer_type[] not null default '{}',
  stage        deal_stage,
  status       entry_status not null default 'draft',
  version      int not null default 1,
  evidence     jsonb not null default '{}',   -- win rates, sample sizes, source notes
  created_by   text not null default 'staff', -- 'staff' or an agent name
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger playbook_touch before update on playbook_entries for each row execute function touch_updated_at();

create table rubrics (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  version    int not null default 1,
  criteria   jsonb not null,                  -- [{key, description, weight}]
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (name, version)
);

create table personas (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,           -- 'Busy independent store owner'
  buyer_type  buyer_type not null,
  profile     text not null,                  -- how they think, object, decide
  created_at  timestamptz not null default now()
);

create table simulations (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid references clients(id) on delete set null,
  persona_id      uuid not null references personas(id),
  writer_agent_id uuid not null references agents(id),
  channel         channel not null default 'email',
  transcript      jsonb not null,             -- [{role:'writer'|'buyer', text}]
  outcome         text check (outcome in ('no_reply','negative','neutral','positive','meeting')),
  created_at      timestamptz not null default now()
);

create table grades (
  id              uuid primary key default gen_random_uuid(),
  subject         text not null check (subject in ('interaction','simulation')),
  subject_id      uuid not null,
  rubric_id       uuid not null references rubrics(id),
  grader_agent_id uuid references agents(id),
  score           real not null check (score between 0 and 100),
  criteria_scores jsonb not null default '{}',
  feedback        text,
  created_at      timestamptz not null default now()
);
create index grades_subject_idx on grades(subject, subject_id);

-- ─────────────────────────── supervisor: runs, alerts, reports ───────────────────────────
create table agent_runs (
  id          uuid primary key default gen_random_uuid(),
  agent_id    uuid not null references agents(id),
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  status      text not null default 'running' check (status in ('running','ok','failed')),
  input_tokens  int,
  output_tokens int,
  cost_cents  numeric(10,2),
  summary     text
);

create table alerts (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid references clients(id) on delete cascade,  -- null = internal
  severity    severity not null default 'info',
  kind        text not null,                  -- 'hot_lead', 'reply_rate_drop', 'bot_underperforming', …
  message     text not null,
  refs        jsonb not null default '{}',
  status      alert_status not null default 'open',
  notify_client boolean not null default false,
  created_at  timestamptz not null default now()
);
create index alerts_open_idx on alerts(status, severity);

create table reports (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references clients(id) on delete cascade,
  kind          text not null check (kind in ('weekly','monthly')),
  period_start  date not null,
  period_end    date not null,
  data          jsonb not null,
  summary       text,
  created_at    timestamptz not null default now(),
  unique (client_id, kind, period_start)
);

-- ─────────────────────────── dashboard views ───────────────────────────
create view v_client_weekly as
select
  i.client_id,
  date_trunc('week', i.occurred_at)::date                                   as week,
  count(*) filter (where i.direction = 'outbound' and i.kind in ('sent','call'))  as touches,
  count(*) filter (where i.kind = 'reply')                                  as replies,
  count(*) filter (where i.kind = 'meeting_booked')                         as meetings,
  count(*) filter (where i.kind = 'sample_sent')                            as samples,
  count(*) filter (where i.kind = 'quote_sent')                             as quotes,
  count(*) filter (where i.kind in ('order','reorder'))                     as orders,
  coalesce(sum(i.value_cents) filter (where i.kind in ('order','reorder')), 0) as order_value_cents
from interactions i
group by 1, 2;

-- how each writer bot is doing: grader scores (practice + real) next to real reply rates
create view v_agent_scorecard as
with graded as (
  select coalesce(i.agent_id, s.writer_agent_id) as agent_id,
         count(*) as graded,
         avg(g.score) as avg_score,
         avg(g.score) filter (where g.subject = 'simulation') as practice_score,
         avg(g.score) filter (where g.subject = 'interaction') as live_score
  from grades g
  left join interactions i on g.subject = 'interaction' and i.id = g.subject_id
  left join simulations s on g.subject = 'simulation' and s.id = g.subject_id
  group by 1
), sends as (
  select i.agent_id,
         count(*) as real_sends,
         count(*) filter (where exists (
           select 1 from interactions x
           where x.contact_id = i.contact_id and x.client_id = i.client_id and x.kind = 'reply'
             and x.occurred_at > i.occurred_at and x.occurred_at < i.occurred_at + interval '14 days')) as real_replies
  from interactions i
  where i.kind = 'sent' and i.agent_id is not null
  group by 1
)
select a.id as agent_id, a.name, a.role, a.prompt_version,
       coalesce(g.graded, 0) as graded,
       round(g.avg_score::numeric, 1) as avg_score,
       round(g.practice_score::numeric, 1) as practice_score,
       round(g.live_score::numeric, 1) as live_score,
       coalesce(s.real_sends, 0) as real_sends,
       coalesce(s.real_replies, 0) as real_replies,
       case when s.real_sends > 0 then round(100.0 * s.real_replies / s.real_sends, 1) end as reply_rate_pct
from agents a
left join graded g on g.agent_id = a.id
left join sends s on s.agent_id = a.id;
