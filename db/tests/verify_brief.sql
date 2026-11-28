-- Checks the call brief (0010_call_brief.sql): only staff can open a brief or search buyers, the public key can't
-- read the kits table, and a brief carries the buyer, the history both ways, the meeting and the client's kit.
-- Rolls back, so nothing is saved. Any failure stops with an error that starts with "BRIEF CHECK FAILED".

begin;

insert into staff (name, email, role) values ('Brief test', 'brief-test@sbm-test.example', 'admin');
insert into clients (id, name) values ('11111111-0000-0000-0000-0000000000b1', 'Brief test client');
insert into call_kits (client_id, kit) values ('11111111-0000-0000-0000-0000000000b1', '{"title":"Brief test client","rules":["no names"]}');
insert into companies (id, name, store_count, hq_city) values ('33333333-0000-0000-0000-0000000000b1', 'Brief test buyer', 7, 'Puebla');
insert into contacts (id, company_id, first_name, last_name, title, email) values
  ('55555555-0000-0000-0000-0000000000b1', '33333333-0000-0000-0000-0000000000b1', 'Carla', 'Ruiz', 'Compras', 'carla@brief-test.example'),
  ('55555555-0000-0000-0000-0000000000b2', '33333333-0000-0000-0000-0000000000b1', 'Diego', null, 'Director', null);
insert into interactions (client_id, company_id, contact_id, channel, direction, kind, actor, subject, body, occurred_at) values
  ('11111111-0000-0000-0000-0000000000b1', '33333333-0000-0000-0000-0000000000b1', '55555555-0000-0000-0000-0000000000b1',
   'email', 'outbound', 'sent', 'staff', 'Hola', 'Primer correo', now() - interval '3 days'),
  ('11111111-0000-0000-0000-0000000000b1', '33333333-0000-0000-0000-0000000000b1', '55555555-0000-0000-0000-0000000000b1',
   'email', 'inbound', 'reply', 'buyer', 'Re: Hola', 'Me interesa, llámame', now() - interval '1 day');

-- 1) the public key can call neither function nor read the kits
set local role anon;
do $$ begin
  perform phone_brief('55555555-0000-0000-0000-0000000000b1');
  raise exception 'BRIEF CHECK FAILED: the public key could open a brief';
exception when insufficient_privilege then null;
end $$;
do $$ begin
  perform 1 from call_kits;
  raise exception 'BRIEF CHECK FAILED: the public key could read call_kits';
exception when insufficient_privilege then null;
end $$;
reset role;

-- 2) a signed-in stranger is turned away
set local role authenticated;
select set_config('request.jwt.claims', '{"email":"stranger@example.com","role":"authenticated"}', true);
do $$ begin
  perform phone_find('Brief');
  raise exception 'BRIEF CHECK FAILED: a login not on the staff list could search buyers';
exception when insufficient_privilege then null;
end $$;

-- 3) staff get the whole brief
select set_config('request.jwt.claims', '{"email":"brief-test@sbm-test.example","role":"authenticated"}', true);
do $$
declare b jsonb := phone_brief('55555555-0000-0000-0000-0000000000b1');
begin
  if b->>'client' <> 'Brief test client' then raise exception 'BRIEF CHECK FAILED: wrong client %', b->>'client'; end if;
  if (b->'company'->>'store_count')::int <> 7 then raise exception 'BRIEF CHECK FAILED: company store count missing'; end if;
  if b->'company' ? 'embedding' or b->'contact' ? 'unsubscribe_token' then raise exception 'BRIEF CHECK FAILED: brief leaks internal columns'; end if;
  if jsonb_array_length(b->'history') <> 2 or b->'history'->0->>'direction' <> 'outbound' then
    raise exception 'BRIEF CHECK FAILED: history should be both messages, oldest first: %', b->'history';
  end if;
  if jsonb_array_length(b->'colleagues') <> 1 then raise exception 'BRIEF CHECK FAILED: colleague missing'; end if;
  if b->'kit'->>'title' <> 'Brief test client' then raise exception 'BRIEF CHECK FAILED: kit missing'; end if;
  if jsonb_array_length(phone_find('brief test')) <> 2 then raise exception 'BRIEF CHECK FAILED: search should find both people'; end if;
  if jsonb_array_length(phone_find('x')) <> 0 then raise exception 'BRIEF CHECK FAILED: one-letter search should return nothing'; end if;
  if not (phone_inbox()->'replies'->0 ? 'contact_id') then raise exception 'BRIEF CHECK FAILED: replies carry no contact id'; end if;
end $$;
reset role;

select 'All brief checks passed. Nothing was saved.' as result;
rollback;
