-- SBM Partners · step 3: the agent team works together through the database.
--
--   tasks            the team's to-do list. The Supervisor adds tasks; each agent picks up its own kind.
--   outreach_drafts  every message an agent writes waits here until a person approves it.
--   spending caps    each agent has a monthly budget; the Supervisor pauses an agent that reaches it.
--   reports          now have a status, so clients only see reports a person has approved.
--
-- Safe to run once on a database that already has 0001 and 0002. It adds things; the only data it changes
-- is the starting budget of the existing Writer and Grader (raised to $100 a month each).

-- ─────────────────────────── new agent roles ───────────────────────────
alter type agent_role add value if not exists 'prospect_researcher';
alter type agent_role add value if not exists 'reporter';

-- ─────────────────────────── clients: the facts agents may use ───────────────────────────
alter table clients add column if not exists brief jsonb not null default '{}';     -- the brand fact sheet (same shape as agents/sample_client.json)
alter table clients add column if not exists daily_draft_limit int not null default 20
  check (daily_draft_limit between 0 and 500);                                      -- most new drafts per day, so outreach is paced

-- ─────────────────────────── agents: spending caps and autonomy ───────────────────────────
alter table agents add column if not exists monthly_budget_cents int not null default 5000
  check (monthly_budget_cents >= 0);                                                -- $50 a month unless changed
alter table agents add column if not exists min_score real not null default 80
  check (min_score between 0 and 100);                                              -- drafts below this get one rewrite
alter table agents add column if not exists paused_reason text;                     -- why the Supervisor paused it
update agents set monthly_budget_cents = 10000 where name in ('writer','grader');  -- they do the most work

-- ─────────────────────────── tasks: the team's shared to-do list ───────────────────────────
create type task_status as enum ('queued','running','done','failed','cancelled');

create table tasks (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('research_prospect','draft_outreach','write_report')),
  status       task_status not null default 'queued',
  priority     int not null default 100,             -- lower runs first
  client_id    uuid references clients(id) on delete cascade,
  campaign_id  uuid references campaigns(id) on delete cascade,
  contact_id   uuid references contacts(id) on delete cascade,
  company_id   uuid references companies(id) on delete set null,
  parent_id    uuid references tasks(id) on delete set null,   -- the task that led to this one
  input        jsonb not null default '{}',
  output       jsonb,
  error        text,
  attempts     int not null default 0,
  max_attempts int not null default 3,
  run_after    timestamptz not null default now(),   -- retries wait a little before running again
  claimed_by   text,
  claimed_at   timestamptz,
  finished_at  timestamptz,
  agent_run_id uuid references agent_runs(id) on delete set null,
  created_by   text not null default 'supervisor',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger tasks_touch before update on tasks for each row execute function touch_updated_at();
create index tasks_ready_idx on tasks(priority, created_at) where status = 'queued';
create index tasks_campaign_contact_idx on tasks(campaign_id, contact_id, kind);
-- never two open tasks of the same kind for the same buyer in the same campaign
create unique index tasks_one_open_idx on tasks(kind, campaign_id, contact_id)
  where status in ('queued','running') and contact_id is not null;

-- An agent takes the next tasks of its kind. SKIP LOCKED means two workers never take the same task.
create or replace function claim_tasks(p_kinds text[], p_worker text, p_limit int default 1)
returns setof tasks language sql as $$
  update tasks t
     set status = 'running', claimed_by = p_worker, claimed_at = now(), attempts = t.attempts + 1
   where t.id in (select id from tasks
                   where status = 'queued' and run_after <= now() and kind = any(p_kinds)
                   order by priority, created_at
                   limit p_limit
                   for update skip locked)
  returning t.*;
$$;

-- Tasks stuck in 'running' (a worker crashed or lost its connection) go back in the queue, or fail
-- once they have used all their attempts. Returns how many were released.
create or replace function release_stale_tasks(p_minutes int default 30)
returns int language plpgsql as $$
declare n int;
begin
  update tasks
     set status = case when attempts >= max_attempts then 'failed'::task_status else 'queued'::task_status end,
         error = coalesce(error, '') || case when error is null then '' else E'\n' end
                 || 'Stopped responding after ' || p_minutes || ' minutes',
         finished_at = case when attempts >= max_attempts then now() end,
         claimed_by = null, claimed_at = null
   where status = 'running' and claimed_at < now() - make_interval(mins => p_minutes);
  get diagnostics n = row_count;
  return n;
end $$;

-- ─────────────────────────── outreach drafts: the approval queue ───────────────────────────
create type draft_status as enum ('pending_review','approved','rejected','sent','cancelled');

create table outreach_drafts (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references clients(id) on delete cascade,
  campaign_id     uuid references campaigns(id) on delete set null,
  contact_id      uuid not null references contacts(id) on delete cascade,
  company_id      uuid references companies(id) on delete set null,
  task_id         uuid references tasks(id) on delete set null,
  writer_agent_id uuid references agents(id) on delete set null,
  channel         channel not null default 'email',
  step            int not null default 1,             -- 1 = first message, 2+ = follow-ups
  subject         text,
  body            text not null,
  playbook_used   jsonb not null default '[]',        -- titles of the playbook entries it applied
  research        jsonb not null default '{}',        -- what the Prospect researcher found, with sources
  score           real check (score between 0 and 100),
  grade_feedback  text,
  rewrites        int not null default 0,
  status          draft_status not null default 'pending_review',
  review_note     text,                               -- your note when approving or rejecting
  reviewed_by     text,
  reviewed_at     timestamptz,
  interaction_id  uuid references interactions(id) on delete set null,   -- the real message, once sent
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create trigger outreach_drafts_touch before update on outreach_drafts for each row execute function touch_updated_at();
create index outreach_drafts_status_idx on outreach_drafts(status, created_at);
create index outreach_drafts_client_idx on outreach_drafts(client_id, created_at desc);

-- Safety rules no agent or screen can get around:
--   * nothing is approved or sent to a contact marked do_not_contact,
--   * nothing is marked sent unless a person approved it first,
--   * reviewing stamps the time.
create or replace function outreach_drafts_guard() returns trigger language plpgsql as $$
begin
  if new.status in ('approved','sent') and exists (select 1 from contacts where id = new.contact_id and do_not_contact) then
    raise exception 'This contact asked not to be contacted; the draft cannot be approved or sent.';
  end if;
  if new.status = 'sent' then
    if tg_op = 'INSERT' then
      raise exception 'A draft must be approved before it is sent.';
    elsif old.status not in ('approved','sent') then
      raise exception 'A draft must be approved before it is sent.';
    end if;
  end if;
  if new.status in ('approved','rejected') and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    new.reviewed_at := coalesce(new.reviewed_at, now());
  end if;
  return new;
end $$;
create trigger outreach_drafts_guard before insert or update on outreach_drafts
  for each row execute function outreach_drafts_guard();

-- ─────────────────────────── reports: approve before clients see them ───────────────────────────
alter table reports add column if not exists status text not null default 'draft'
  check (status in ('draft','approved','sent'));
alter table reports add column if not exists body text;                   -- the report itself, ready to read
alter table reports add column if not exists approved_at timestamptz;
alter table reports add column if not exists sent_at timestamptz;

drop policy if exists portal_read_reports on reports;
create policy portal_read_reports on reports for select
  using (status in ('approved','sent') and client_id in (select my_client_ids()));

-- ─────────────────────────── privacy: the new tables are internal only ───────────────────────────
alter table tasks enable row level security;
alter table outreach_drafts enable row level security;

-- ─────────────────────────── views for the dashboard (and for the SQL editor until then) ───────────────────────────
-- What each agent spent this calendar month against its budget.
create view v_agent_spend_month as
select a.id as agent_id, a.name, a.role, a.active, a.paused_reason,
       round(coalesce(sum(r.cost_cents), 0) / 100.0, 2)                     as spent_usd,
       round(a.monthly_budget_cents / 100.0, 2)                             as budget_usd,
       case when a.monthly_budget_cents > 0
            then round(100.0 * coalesce(sum(r.cost_cents), 0) / a.monthly_budget_cents, 0) end as pct_used
from agents a
left join agent_runs r on r.agent_id = a.id and r.started_at >= date_trunc('month', now())
group by a.id;

-- Drafts waiting for a person, oldest first, with who they are for.
create view v_approval_queue as
select d.id, d.created_at, cl.name as client, c.first_name || ' ' || coalesce(c.last_name, '') as contact,
       c.title as contact_title, co.name as company, co.type as buyer_type, d.channel, d.step,
       d.subject, d.body, d.score, d.grade_feedback, d.rewrites
from outreach_drafts d
join clients cl on cl.id = d.client_id
join contacts c on c.id = d.contact_id
left join companies co on co.id = d.company_id
where d.status = 'pending_review'
order by d.created_at;

-- The team at a glance: tasks by kind and status over the last 7 days.
create view v_team_status as
select kind, status, count(*) as tasks,
       max(updated_at) as last_change,
       round(avg(extract(epoch from (finished_at - claimed_at)) / 60)::numeric, 1) as avg_minutes
from tasks
where created_at > now() - interval '7 days'
group by kind, status;

alter view v_agent_spend_month set (security_invoker = true);
alter view v_approval_queue set (security_invoker = true);
alter view v_team_status set (security_invoker = true);
