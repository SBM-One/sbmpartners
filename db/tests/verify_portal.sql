-- Checks the client portal views (0004_client_portal.sql): each client login sees only its own pipeline and
-- activity, never another client's, never buyer emails, and the public key sees nothing.
-- Rolls back, so nothing is saved. Any failure stops with an error that starts with "PORTAL CHECK FAILED".

begin;

insert into clients (id, name) values
  ('11111111-0000-0000-0000-0000000000a4', 'Portal test client A'),
  ('11111111-0000-0000-0000-0000000000b4', 'Portal test client B');
insert into client_users (client_id, email, auth_user_id) values
  ('11111111-0000-0000-0000-0000000000a4', 'a@portal-test.example', '22222222-0000-0000-0000-0000000000a4'),
  ('11111111-0000-0000-0000-0000000000b4', 'b@portal-test.example', '22222222-0000-0000-0000-0000000000b4');
insert into companies (id, name, domain) values
  ('33333333-0000-0000-0000-0000000000a4', 'Portal test buyer A', 'portal-test-a.example'),
  ('33333333-0000-0000-0000-0000000000b4', 'Portal test buyer B', 'portal-test-b.example');
insert into contacts (id, company_id, first_name, title, email) values
  ('55555555-0000-0000-0000-0000000000a4', '33333333-0000-0000-0000-0000000000a4', 'Ann', 'Buyer', 'ann@portal-test-a.example');
insert into deals (client_id, company_id, stage) values
  ('11111111-0000-0000-0000-0000000000a4', '33333333-0000-0000-0000-0000000000a4', 'sample'),
  ('11111111-0000-0000-0000-0000000000b4', '33333333-0000-0000-0000-0000000000b4', 'quote');
insert into interactions (client_id, company_id, contact_id, channel, direction, kind, actor, subject, body) values
  ('11111111-0000-0000-0000-0000000000a4', '33333333-0000-0000-0000-0000000000a4', '55555555-0000-0000-0000-0000000000a4',
   'email', 'inbound', 'reply', 'buyer', 'Re: hello', 'private reply text'),
  ('11111111-0000-0000-0000-0000000000a4', null, null, 'other', 'outbound', 'note', 'staff', 'internal note', 'internal'),
  ('11111111-0000-0000-0000-0000000000b4', '33333333-0000-0000-0000-0000000000b4', null, 'email', 'outbound', 'sent', 'bot', 'B only', null);

-- 1) client A's portal login
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
do $$
declare n int; other int; subj text;
begin
  select count(*), count(*) filter (where client_id <> '11111111-0000-0000-0000-0000000000a4') into n, other from v_portal_pipeline;
  if n <> 1 or other <> 0 then raise exception 'PORTAL CHECK FAILED: client A sees % pipeline rows (% not its own)', n, other; end if;

  select count(*), count(*) filter (where client_id <> '11111111-0000-0000-0000-0000000000a4') into n, other from v_portal_activity;
  if n <> 1 or other <> 0 then raise exception 'PORTAL CHECK FAILED: client A sees % activity rows (% not its own; internal notes must be hidden)', n, other; end if;

  select subject into subj from v_portal_activity limit 1;
  if subj is not null then raise exception 'PORTAL CHECK FAILED: a buyer''s own subject line is visible to the client'; end if;

  if exists (select 1 from information_schema.columns where table_name in ('v_portal_activity','v_portal_pipeline')
             and column_name in ('email','phone','body')) then
    raise exception 'PORTAL CHECK FAILED: a portal view exposes emails, phone numbers or message bodies';
  end if;
  raise notice 'ok: client A sees only its own pipeline and activity';
end $$;

-- 2) a login linked to no client
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-0000000000ff","role":"authenticated"}', true);
do $$
declare n int;
begin
  select (select count(*) from v_portal_pipeline) + (select count(*) from v_portal_activity) into n;
  if n <> 0 then raise exception 'PORTAL CHECK FAILED: a stranger login sees % portal rows', n; end if;
  raise notice 'ok: a login with no client sees nothing';
end $$;

-- 3) the public anon key
reset role;
set local role anon;
do $$
declare n int;
begin
  select count(*) into n from v_portal_pipeline;
  raise exception 'PORTAL CHECK FAILED: the public key can read the portal views (% rows)', n;
exception when insufficient_privilege then
  raise notice 'ok: the public key is refused';
end $$;

reset role;
rollback;
select 'All portal checks passed. Nothing was saved.' as result;
