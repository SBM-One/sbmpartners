-- Checks the agent-team rules (0003_agent_team.sql). Safe to run anytime: everything is rolled back.
-- Works in the Supabase SQL editor or with:  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/verify_team.sql
-- Any failed check stops with an error that starts with "TEAM CHECK FAILED".

begin;

insert into clients (id, name) values ('55555555-0000-0000-0000-00000000000a', 'Team test client');
insert into client_users (client_id, email, auth_user_id) values
  ('55555555-0000-0000-0000-00000000000a', 'team@team-test.example', '66666666-0000-0000-0000-00000000000a');
insert into companies (id, name, domain) values ('77777777-0000-0000-0000-000000000001', 'Team test buyer', 'team-test-buyer.example');
insert into contacts (id, company_id, first_name, email) values
  ('88888888-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000001', 'Ok', 'ok@team-test-buyer.example'),
  ('88888888-0000-0000-0000-000000000002', '77777777-0000-0000-0000-000000000001', 'Stop', 'stop@team-test-buyer.example');
update contacts set do_not_contact = true where id = '88888888-0000-0000-0000-000000000002';
insert into campaigns (id, client_id, name, status) values
  ('99999999-0000-0000-0000-00000000000a', '55555555-0000-0000-0000-00000000000a', 'Team test campaign', 'live');

-- 1) the task queue
do $$
declare a int; b int; n int;
begin
  insert into tasks (kind, client_id, campaign_id, contact_id) values
    ('research_prospect', '55555555-0000-0000-0000-00000000000a', '99999999-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-000000000001');
  begin
    insert into tasks (kind, client_id, campaign_id, contact_id) values
      ('research_prospect', '55555555-0000-0000-0000-00000000000a', '99999999-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-000000000001');
    raise exception 'TEAM CHECK FAILED: the same buyer got two open tasks of the same kind';
  exception when unique_violation then null;
  end;

  select count(*) into a from claim_tasks(array['research_prospect'], 'worker-1', 5);
  select count(*) into b from claim_tasks(array['research_prospect'], 'worker-2', 5);
  if a <> 1 or b <> 0 then raise exception 'TEAM CHECK FAILED: a task was handed out % times', a + b; end if;

  update tasks set claimed_at = now() - interval '2 hours' where claimed_by = 'worker-1';
  n := release_stale_tasks(30);
  if n <> 1 or (select status from tasks where contact_id = '88888888-0000-0000-0000-000000000001') <> 'queued' then
    raise exception 'TEAM CHECK FAILED: a stuck task was not put back in the queue';
  end if;
  raise notice 'ok: each task goes to exactly one agent, and stuck tasks are retried';
end $$;

-- 2) the approval rules
do $$
declare d uuid;
begin
  insert into outreach_drafts (client_id, campaign_id, contact_id, body)
  values ('55555555-0000-0000-0000-00000000000a', '99999999-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-000000000001', 'Hello')
  returning id into d;
  begin
    update outreach_drafts set status = 'sent' where id = d;
    raise exception 'TEAM CHECK FAILED: a draft was sent without approval';
  exception when raise_exception then
    if sqlerrm like 'TEAM CHECK FAILED%' then raise; end if;
  end;
  update outreach_drafts set status = 'approved' where id = d;
  if (select reviewed_at from outreach_drafts where id = d) is null then
    raise exception 'TEAM CHECK FAILED: approving a draft did not record the time';
  end if;
  update outreach_drafts set status = 'sent' where id = d;

  insert into outreach_drafts (client_id, contact_id, body)
  values ('55555555-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-000000000002', 'Hello')
  returning id into d;
  begin
    update outreach_drafts set status = 'approved' where id = d;
    raise exception 'TEAM CHECK FAILED: a do-not-contact buyer''s draft was approved';
  exception when raise_exception then
    if sqlerrm like 'TEAM CHECK FAILED%' then raise; end if;
  end;
  raise notice 'ok: nothing is sent without approval, and do-not-contact is enforced';
end $$;

-- 3) clients see approved reports only, and none of the team's internal work
insert into reports (client_id, kind, period_start, period_end, data, status) values
  ('55555555-0000-0000-0000-00000000000a', 'weekly', '2026-01-05', '2026-01-11', '{}', 'draft'),
  ('55555555-0000-0000-0000-00000000000a', 'weekly', '2026-01-12', '2026-01-18', '{}', 'approved');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"66666666-0000-0000-0000-00000000000a","role":"authenticated"}', true);
do $$
declare n int;
begin
  select count(*) into n from reports;
  if n <> 1 then raise exception 'TEAM CHECK FAILED: the client sees % reports, expected only the 1 approved report', n; end if;
  select (select count(*) from tasks) + (select count(*) from outreach_drafts) into n;
  if n <> 0 then raise exception 'TEAM CHECK FAILED: a client login can see the team''s tasks or drafts'; end if;
  raise notice 'ok: clients see only approved reports and nothing internal';
end $$;

reset role;
rollback;
select 'All team checks passed. Nothing was saved.' as result;
