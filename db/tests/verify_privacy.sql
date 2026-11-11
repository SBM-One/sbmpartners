-- Checks the privacy rules (0002_supabase_privacy.sql) on a real Supabase database.
-- Safe to run anytime: everything happens inside one transaction that is rolled back, so nothing is saved.
-- Works in the Supabase SQL editor or with:  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/verify_privacy.sql
-- Any failed check stops with an error that starts with "PRIVACY CHECK FAILED".

begin;

-- test data: two clients, one portal user each, one buyer in the shared network
insert into clients (id, name) values
  ('11111111-0000-0000-0000-00000000000a', 'Privacy test client A'),
  ('11111111-0000-0000-0000-00000000000b', 'Privacy test client B');
insert into client_users (client_id, email, auth_user_id) values
  ('11111111-0000-0000-0000-00000000000a', 'a@privacy-test.example', '22222222-0000-0000-0000-00000000000a'),
  ('11111111-0000-0000-0000-00000000000b', 'b@privacy-test.example', '22222222-0000-0000-0000-00000000000b');
insert into companies (id, name, domain) values
  ('33333333-0000-0000-0000-000000000001', 'Privacy test buyer', 'privacy-test-buyer.example');
insert into campaigns (id, client_id, name) values
  ('44444444-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-00000000000a', 'A campaign'),
  ('44444444-0000-0000-0000-00000000000b', '11111111-0000-0000-0000-00000000000b', 'B campaign');
insert into interactions (client_id, campaign_id, company_id, channel, direction, kind, actor) values
  ('11111111-0000-0000-0000-00000000000a', '44444444-0000-0000-0000-00000000000a', '33333333-0000-0000-0000-000000000001', 'email', 'outbound', 'sent', 'bot'),
  ('11111111-0000-0000-0000-00000000000b', '44444444-0000-0000-0000-00000000000b', '33333333-0000-0000-0000-000000000001', 'email', 'outbound', 'sent', 'bot');
insert into alerts (client_id, severity, kind, message, notify_client) values
  ('11111111-0000-0000-0000-00000000000a', 'info', 'test', 'visible to A', true),
  ('11111111-0000-0000-0000-00000000000a', 'info', 'test', 'internal only', false);

-- 1) logged in as client A's portal user
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-00000000000a","role":"authenticated"}', true);
do $$
declare n int; other int;
begin
  select count(*), count(*) filter (where id <> '11111111-0000-0000-0000-00000000000a') into n, other from clients;
  if n <> 1 or other <> 0 then raise exception 'PRIVACY CHECK FAILED: client A sees % client rows (% not its own)', n, other; end if;

  select count(*) filter (where client_id <> '11111111-0000-0000-0000-00000000000a') into other from campaigns;
  if other <> 0 then raise exception 'PRIVACY CHECK FAILED: client A sees another client''s campaigns'; end if;

  select count(*), count(*) filter (where client_id <> '11111111-0000-0000-0000-00000000000a') into n, other from interactions;
  if n <> 1 or other <> 0 then raise exception 'PRIVACY CHECK FAILED: client A sees % interactions (% not its own)', n, other; end if;

  select count(*) into n from alerts;
  if n <> 1 then raise exception 'PRIVACY CHECK FAILED: client A sees % alerts, expected 1 (internal alerts must stay hidden)', n; end if;

  select count(*) into n from companies;
  if n <> 0 then raise exception 'PRIVACY CHECK FAILED: the buyer network is visible to a client login'; end if;
  select count(*) into n from contacts;
  if n <> 0 then raise exception 'PRIVACY CHECK FAILED: buyer contacts are visible to a client login'; end if;
  select count(*) into n from client_users;
  if n <> 0 then raise exception 'PRIVACY CHECK FAILED: client_users is visible to a client login'; end if;

  select count(*) filter (where client_id <> '11111111-0000-0000-0000-00000000000a') into other from v_client_weekly;
  if other <> 0 then raise exception 'PRIVACY CHECK FAILED: the weekly dashboard view leaks another client''s numbers'; end if;

  begin
    update clients set name = 'hacked' where id = '11111111-0000-0000-0000-00000000000a';
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'PRIVACY CHECK FAILED: a client login can edit data'; end if;
  exception when insufficient_privilege then null;  -- refused outright is also fine
  end;
  raise notice 'ok: client A sees only its own rows and nothing internal';
end $$;

-- 2) logged in as a user who is not linked to any client
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-0000000000ff","role":"authenticated"}', true);
do $$
declare n int;
begin
  select (select count(*) from clients) + (select count(*) from campaigns) + (select count(*) from interactions)
       + (select count(*) from alerts) + (select count(*) from companies) into n;
  if n <> 0 then raise exception 'PRIVACY CHECK FAILED: a stranger login sees % rows', n; end if;
  raise notice 'ok: a login with no client sees nothing';
end $$;

-- 3) not logged in at all (public anon key)
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$
declare n int;
begin
  select (select count(*) from clients) + (select count(*) from interactions) + (select count(*) from companies) into n;
  if n <> 0 then raise exception 'PRIVACY CHECK FAILED: the public (anon) key sees % rows', n; end if;
  raise notice 'ok: the public key sees nothing';
exception when insufficient_privilege then
  raise notice 'ok: the public key is refused outright';
end $$;

reset role;
rollback;
select 'All privacy checks passed. Nothing was saved.' as result;
