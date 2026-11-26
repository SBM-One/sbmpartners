-- SBM Partners · step 7: the team is three agents, and LinkedIn and WhatsApp are sent by hand.
--
--   Three agents  researcher (web research + fit score + pitch plan), writer (channel plan + every message, meeting
--                 briefs, weekly reports) and reviewer (grade + safety checks, and sorting replies). The older agent
--                 rows are kept for their history but switched off; their budgets move to the three.
--   Channel plan  for each buyer the writer plans the sequence (email, LinkedIn note, WhatsApp) and drafts the first
--                 message on each channel; it is stored on the buyer's strategy (prospect_strategies.channel_sequence).
--   By hand       LinkedIn and WhatsApp cannot be automated. Once approved, those messages wait on the "Send by hand"
--                 page with a one-tap link (their LinkedIn profile, or wa.me with the text filled in). You send it
--                 yourself and press "I sent it", which logs it like any other message.
--   Reviewer      every draft records the reviewer's safety checks (outreach_drafts.review_checks).
--
-- Safe to run once on a database that already has 0001 to 0006. It only adds things, and wraps the safety gate
-- draft_blockers() from 0006 with two more rules (a WhatsApp message needs a number, a LinkedIn note a profile).

-- ─────────────────────────── WhatsApp as a channel ───────────────────────────
alter type channel add value if not exists 'whatsapp';

-- ─────────────────────────── the writer's channel plan ───────────────────────────
alter table prospect_strategies add column if not exists channel_sequence jsonb;   -- {steps: [{day, channel, purpose}], why}
alter table prospect_strategies drop constraint if exists prospect_strategies_channel_plan_check;
alter table prospect_strategies add constraint prospect_strategies_channel_plan_check
  check (channel_plan in ('email', 'email_and_linkedin', 'linkedin', 'whatsapp'));

-- ─────────────────────────── drafts: plan day and the reviewer's checks ───────────────────────────
alter table outreach_drafts add column if not exists planned_day int;          -- days after the first touch (writer's plan)
alter table outreach_drafts add column if not exists review_checks jsonb;      -- {passed, problems[]} from the reviewer

-- ─────────────────────────── three agents ───────────────────────────
update agents set active = false,
       paused_reason = 'Merged into ' || case name when 'prospect-researcher' then 'researcher' when 'strategist' then 'researcher'
                                              when 'onboarder' then 'researcher' when 'grader' then 'reviewer'
                                              when 'reply-sorter' then 'reviewer' else 'writer' end || ' (2026-11-26)'
 where name in ('prospect-researcher', 'strategist', 'onboarder', 'grader', 'reply-sorter', 'meeting-briefer', 'reporter');
insert into agents (name, role, model, monthly_budget_cents) values
  ('researcher', 'researcher', 'claude-opus-5-5', 10000),
  ('reviewer', 'grader', 'claude-opus-5-5', 10000)
on conflict (name) do update set active = true, paused_reason = null;
update agents set monthly_budget_cents = greatest(monthly_budget_cents, 15000) where name = 'writer';

-- ─────────────────────────── the safety gate, two more rules ───────────────────────────
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'draft_blockers_0006') then
    alter function draft_blockers(outreach_drafts) rename to draft_blockers_0006;
  end if;
end $$;

create or replace function draft_blockers(d outreach_drafts) returns text[] language plpgsql stable as $$
declare
  c   contacts;
  out text[] := draft_blockers_0006(d);
begin
  select * into c from contacts where id = d.contact_id;
  if d.channel::text = 'whatsapp' and length(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g')) not between 10 and 15 then
    out := array_append(out, 'No WhatsApp number on file (with the country code).');
  end if;
  if d.channel::text = 'linkedin' and coalesce(trim(c.linkedin_url), '') = '' then
    out := array_append(out, 'No LinkedIn profile on file.');
  end if;
  return out;
end $$;

-- ─────────────────────────── to send by hand: LinkedIn and WhatsApp ───────────────────────────
create or replace view v_manual_sends as
select d.id, d.channel::text as channel, d.reviewed_at, d.body, d.step, d.planned_day, cl.name as client,
       trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as contact,
       c.title as contact_title, c.linkedin_url, regexp_replace(coalesce(c.phone, ''), '\D', '', 'g') as wa_number,
       co.name as company,
       (select min(s.sent_at) from outreach_drafts s where s.contact_id = d.contact_id and s.campaign_id is not distinct from d.campaign_id
         and s.status = 'sent') as first_touch_at
from outreach_drafts d
join clients cl on cl.id = d.client_id
join contacts c on c.id = d.contact_id
left join companies co on co.id = d.company_id
where d.channel::text in ('linkedin', 'whatsapp') and d.status = 'approved'
order by coalesce(d.planned_day, 0), d.reviewed_at;
alter view v_manual_sends set (security_invoker = true);
