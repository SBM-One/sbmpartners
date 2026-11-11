-- SBM Partners · row-level security for Supabase
-- Apply on Supabase only (uses auth.uid()). Staff and backend jobs use the service role, which bypasses RLS.
-- Client portal users only ever see rows for their own client. The shared buyer network is never exposed directly.

create or replace function my_client_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select client_id from client_users where auth_user_id = auth.uid()
$$;

do $$
declare t text;
begin
  -- tables that carry client_id: portal users may read their own rows
  foreach t in array array['clients','collections','assets','campaigns','interactions','deals','reports','alerts'] loop
    execute format('alter table %I enable row level security', t);
  end loop;
  -- internal-only tables: RLS on, no portal policies at all
  foreach t in array array['staff','client_users','companies','locations','contacts','field_sources','campaign_targets',
                           'agents','playbook_entries','rubrics','personas','simulations','grades','agent_runs'] loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

create policy portal_read_client      on clients      for select using (id in (select my_client_ids()));
create policy portal_read_collections on collections  for select using (client_id in (select my_client_ids()));
create policy portal_read_assets      on assets       for select using (client_id in (select my_client_ids()));
create policy portal_read_campaigns   on campaigns    for select using (client_id in (select my_client_ids()));
create policy portal_read_interactions on interactions for select using (client_id in (select my_client_ids()));
create policy portal_read_deals       on deals        for select using (client_id in (select my_client_ids()));
create policy portal_read_reports     on reports      for select using (client_id in (select my_client_ids()));
create policy portal_read_alerts      on alerts       for select using (notify_client and client_id in (select my_client_ids()));

-- dashboard views run with the caller's permissions, so the policies above apply to them too
alter view v_client_weekly set (security_invoker = true);
alter view v_agent_scorecard set (security_invoker = true);
