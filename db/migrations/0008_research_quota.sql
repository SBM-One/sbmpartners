-- SBM Partners · step 8: a daily research quota the researcher has to meet, and proof that it did the work.
--
--   Screening   each day the next batch of DENUE companies (INEGI's business directory) is screened by fixed rules,
--               at no AI cost: furniture activity, size, branches, a way to reach them. Every screened company keeps
--               its score and, if it was not picked, the reason. The best ones go to the researcher.
--   Gate        a researched account only counts once it passes the completeness gate: enough opened sources, a
--               logged attempt to name the buyer (found, or why not), a fit score with reasons, and which channels
--               are open. A failed account is researched again (it does not count until it passes).
--   Spot check  a random share of the passed accounts is checked again against the cited pages; facts the pages
--               do not support are flagged as a skim.
--   All numbers live in research_quota_settings, one row, editable.
--
-- Safe to run once on a database that already has 0001 to 0007. It only adds things.

create table if not exists research_quota_settings (
  id               boolean primary key default true check (id),   -- one row
  screen_per_day   int not null default 200 check (screen_per_day > 0),
  research_per_day int not null default 25 check (research_per_day > 0),
  drafts_min       int not null default 10,
  drafts_max       int not null default 15,
  min_sources      int not null default 3 check (min_sources > 0),   -- distinct opened pages behind the facts
  min_facts        int not null default 3,
  spot_check_share numeric not null default 0.10 check (spot_check_share between 0 and 1),
  max_redo         int not null default 2 check (max_redo >= 0),    -- research again this many times before giving up
  updated_at       timestamptz not null default now()
);
insert into research_quota_settings (id) values (true) on conflict do nothing;

-- the DENUE companies waiting to be screened, and what screening decided
create table if not exists screen_pool (
  id             uuid primary key default gen_random_uuid(),
  source         text not null default 'denue',
  source_key     text not null,                   -- DENUE id, or a key built from the company's name and state
  name           text not null,
  legal_name     text,
  activity       text,                            -- DENUE "clase de actividad"
  activity_code  text,                            -- SCIAN code
  staff_band     text,                            -- DENUE "estrato", e.g. "51 a 100 personas"
  staff_min      int,
  branches       int not null default 1,          -- establishments with this name
  city           text,
  state          text,
  phone          text,
  email          text,
  website        text,
  raw            jsonb,
  screened_on    date,
  screen_score   int,
  screen_notes   text,                            -- why it scored what it scored
  picked         boolean,                         -- true = sent to the researcher that day
  skip_reason    text,                            -- set when screened and not picked
  client_id      uuid references clients(id) on delete set null,
  company_id     uuid references companies(id) on delete set null,
  contact_id     uuid references contacts(id) on delete set null,
  created_at     timestamptz not null default now(),
  unique (source, source_key)
);
create index if not exists screen_pool_waiting_idx on screen_pool(created_at) where screened_on is null;
create index if not exists screen_pool_day_idx on screen_pool(screened_on);
alter table screen_pool enable row level security;

-- one row per research attempt on a quota account: the gate's verdict, and later the spot check
create table if not exists research_checks (
  id            uuid primary key default gen_random_uuid(),
  task_id       uuid references tasks(id) on delete cascade,
  client_id     uuid references clients(id) on delete cascade,
  company_id    uuid references companies(id) on delete set null,
  contact_id    uuid references contacts(id) on delete cascade,
  quota_day     date not null,
  attempt       int not null default 1,
  passed        boolean not null,
  problems      text[] not null default '{}',
  sources       text[] not null default '{}',     -- opened pages behind the facts
  facts         jsonb,                            -- [{fact, source_url}]
  buyer         jsonb,                            -- the researcher's attempt to name the buyer
  fit_score     int,
  channels      jsonb,                            -- {email, linkedin, whatsapp}: open or not
  spot_checked_at timestamptz,
  spot_result   text check (spot_result in ('ok', 'skim', 'unreachable')),
  spot_notes    jsonb,                            -- per fact: supported or not, and why
  created_at    timestamptz not null default now()
);
create index if not exists research_checks_day_idx on research_checks(quota_day);
alter table research_checks enable row level security;

-- the day at a glance (Mexico City time): target vs done vs passed
create or replace view v_research_quota as
with s as (select * from research_quota_settings where id),
days as (
  select screened_on as day from screen_pool where screened_on is not null
  union select quota_day from research_checks
)
select d.day,
       s.screen_per_day, s.research_per_day, s.drafts_min, s.drafts_max,
       (select count(*) from screen_pool p where p.screened_on = d.day)                         as screened,
       (select count(*) from screen_pool p where p.screened_on = d.day and p.picked)            as picked,
       (select count(distinct c.contact_id) from research_checks c where c.quota_day = d.day)   as researched,
       (select count(distinct c.contact_id) from research_checks c where c.quota_day = d.day and c.passed) as passed,
       (select count(*) from research_checks c where c.quota_day = d.day and not c.passed)      as failed_attempts,
       (select count(*) from research_checks c where c.quota_day = d.day and c.spot_result is not null) as spot_checked,
       (select count(*) from research_checks c where c.quota_day = d.day and c.spot_result = 'skim') as skims,
       (select count(distinct o.contact_id) from outreach_drafts o join screen_pool p on p.contact_id = o.contact_id
         where p.screened_on = d.day and o.step = 1)                                            as drafted,
       (select count(*) from screen_pool where screened_on is null)                             as waiting
from days d cross join s;
alter view v_research_quota set (security_invoker = true);
