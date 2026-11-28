-- Checks the sending controls (0016_operating_controls.sql) with made-up data. Rolls back; nothing is saved.
-- Any failure stops with an error that starts with "CONTROLS CHECK FAILED".

begin;

insert into clients (id, name, brief_approved_at, sender_name, postal_address) values
  ('11111111-0000-0000-0000-0000000000c9', 'Controls test client', now(), 'Test Sender', 'Calle Uno 1, 74325 Chipilo de Francisco Javier Mina, Pue.');
insert into autopilot_settings (client_id, sends_start_on, send_from_hour, send_until_hour, send_days, allow_unverified, past_customers)
values ('11111111-0000-0000-0000-0000000000c9', current_date - 1, 0, 24, '{1,2,3,4,5,6,7}', true, '{"Forbidden Stores"}');
insert into autopilot_ramp values ('11111111-0000-0000-0000-0000000000c9', current_date - 1, 4);
insert into email_country_rules (country, name, cold_email, law, confirmed_at, confirmed_by)
values ('MX', 'México', 'allowed', 'test', now(), 'test')
on conflict (country) do update set confirmed_at = coalesce(email_country_rules.confirmed_at, now()), cold_email = 'allowed';
insert into monitor_runs (ran_at, checked) values (now() - interval '5 minutes', 0);

insert into companies (id, name, domain, country) values
  ('33333333-0000-0000-0000-0000000000c1', 'Buyer One', 'buyer-one.example', 'MX'),
  ('33333333-0000-0000-0000-0000000000c2', 'Buyer Two', 'buyer-two.example', 'MX'),
  ('33333333-0000-0000-0000-0000000000c3', 'Buyer Three', 'buyer-three.example', 'MX');
insert into contacts (id, company_id, first_name, email, email_source, country, email_basis) values
  ('55555555-0000-0000-0000-0000000000c1', '33333333-0000-0000-0000-0000000000c1', 'Ana',   'ana@buyer-one.example',   'apollo', 'MX', 'legitimate_interest'),
  ('55555555-0000-0000-0000-0000000000c2', '33333333-0000-0000-0000-0000000000c1', 'Beto',  'beto@buyer-one.example',  'apollo', 'MX', 'legitimate_interest'),
  ('55555555-0000-0000-0000-0000000000c3', '33333333-0000-0000-0000-0000000000c2', 'Carla', 'carla@buyer-two.example', 'apollo', 'MX', 'legitimate_interest'),
  ('55555555-0000-0000-0000-0000000000c4', '33333333-0000-0000-0000-0000000000c3', 'Dora',  'dora@buyer-three.example', 'apollo', 'MX', 'legitimate_interest');

-- a valid first email body for the copy checks
create temp table body as select
  'Estimada compradora, le escribo del equipo comercial de Santa Fe Rústicos, fabricante de muebles en Chipilo, Puebla, '
  || 'desde 1993. Fabricamos comedores, recámaras y muebles de sala para cadenas y tiendas. ¿Tendría quince minutos esta '
  || 'semana para conocer su programa de compras? Con gusto le comparto el catálogo. '
  || E'\n\nSi prefiere no recibir más correos míos, basta con responder "no, gracias" y no volveré a escribirle.'
  || E'\n\nSaludos cordiales,\nTest Sender\nWhatsApp +52 222 437 4378\nCalle Uno 1, 74325 Chipilo de Francisco Javier Mina, Pue.' as b;

insert into outreach_drafts (id, client_id, contact_id, company_id, channel, step, purpose, subject, body, status)
select v.id::uuid, '11111111-0000-0000-0000-0000000000c9', v.contact::uuid, v.company::uuid, 'email', 1, 'first', 'Muebles', body.b, 'approved'
  from body, (values
    ('66666666-0000-0000-0000-0000000000c1', '55555555-0000-0000-0000-0000000000c1', '33333333-0000-0000-0000-0000000000c1'),
    ('66666666-0000-0000-0000-0000000000c2', '55555555-0000-0000-0000-0000000000c2', '33333333-0000-0000-0000-0000000000c1'),
    ('66666666-0000-0000-0000-0000000000c3', '55555555-0000-0000-0000-0000000000c3', '33333333-0000-0000-0000-0000000000c2'),
    ('66666666-0000-0000-0000-0000000000c4', '55555555-0000-0000-0000-0000000000c4', '33333333-0000-0000-0000-0000000000c3')) v(id, contact, company);

-- 1) a clean draft can be claimed; it is then "attempted" and counts against the cap before it is confirmed
do $$ begin
  if cardinality(autopilot_send_check('66666666-0000-0000-0000-0000000000c1')) > 0 then
    raise exception 'CONTROLS CHECK FAILED: clean draft blocked: %', autopilot_send_check('66666666-0000-0000-0000-0000000000c1');
  end if;
  if not autopilot_claim('66666666-0000-0000-0000-0000000000c1') then raise exception 'CONTROLS CHECK FAILED: claim refused'; end if;
  if autopilot_claim('66666666-0000-0000-0000-0000000000c1') then raise exception 'CONTROLS CHECK FAILED: claimed twice'; end if;
  if autopilot_sent_today('11111111-0000-0000-0000-0000000000c9') <> 1 then raise exception 'CONTROLS CHECK FAILED: in-flight not counted'; end if;
end $$;

-- 2) one first email per company per day: Beto (same company as Ana) waits
do $$ begin
  if not exists (select 1 from unnest(autopilot_send_check('66666666-0000-0000-0000-0000000000c2')) w where w like '%already got a first email today%') then
    raise exception 'CONTROLS CHECK FAILED: second first-touch at the same company was not held';
  end if;
end $$;

-- 3) mark sent is logged under the message id; a follow-up in the same Gmail thread gets its own record
do $$ begin
  perform autopilot_mark_sent('66666666-0000-0000-0000-0000000000c1', 'msg-1', 'thread-1');
  perform autopilot_mark_sent('66666666-0000-0000-0000-0000000000c1', 'msg-1', 'thread-1');   -- repeat is harmless
  if (select count(*) from interactions where external_id = 'gmail:msg-1') <> 1 then raise exception 'CONTROLS CHECK FAILED: send not logged once'; end if;
end $$;
insert into outreach_drafts (id, client_id, contact_id, company_id, channel, step, purpose, subject, body, status, gmail_thread_id)
select '66666666-0000-0000-0000-0000000000c5', '11111111-0000-0000-0000-0000000000c9', '55555555-0000-0000-0000-0000000000c1',
       '33333333-0000-0000-0000-0000000000c1', 'email', 2, 'follow_up', 'Re: Muebles',
       'Le escribo de nuevo por si mi correo anterior se perdió entre otros. Santa Fe Rústicos fabrica muebles desde 1993 en Chipilo. '
       || E'\n\nSi prefiere no recibir más correos míos, basta con responder "no, gracias" y no volveré a escribirle.'
       || E'\nWhatsApp +52 222 437 4378\nCalle Uno 1, 74325 Chipilo de Francisco Javier Mina, Pue.', 'approved', 'thread-1';
do $$ begin
  if not autopilot_claim('66666666-0000-0000-0000-0000000000c5') then
    raise exception 'CONTROLS CHECK FAILED: follow-up refused: %', autopilot_send_check('66666666-0000-0000-0000-0000000000c5');
  end if;
  perform autopilot_mark_sent('66666666-0000-0000-0000-0000000000c5', 'msg-2', 'thread-1');
  if (select count(*) from interactions where metadata->>'gmail_thread_id' = 'thread-1' and direction = 'outbound') <> 2 then
    raise exception 'CONTROLS CHECK FAILED: the follow-up in the same thread was not logged separately';
  end if;
end $$;

-- 4) an uncertain send blocks everything until it is reconciled
do $$ begin
  if not autopilot_claim('66666666-0000-0000-0000-0000000000c3') then raise exception 'CONTROLS CHECK FAILED: claim Carla'; end if;
  perform autopilot_send_failed('66666666-0000-0000-0000-0000000000c3', 'timeout', false);
  if autopilot_claim('66666666-0000-0000-0000-0000000000c4') then raise exception 'CONTROLS CHECK FAILED: sent while a send is uncertain'; end if;
  if jsonb_array_length(autopilot_reconcile_list('11111111-0000-0000-0000-0000000000c9')) <> 1 then
    raise exception 'CONTROLS CHECK FAILED: reconcile list';
  end if;
  perform autopilot_reconcile_not_sent('66666666-0000-0000-0000-0000000000c3');
  if (select delivery from outreach_drafts where id = '66666666-0000-0000-0000-0000000000c3') <> 'failed' then
    raise exception 'CONTROLS CHECK FAILED: reconcile did not release it';
  end if;
end $$;

-- 5) a quiet reply monitor stops sending, and ops_check raises an alert
update monitor_runs set ran_at = now() - interval '3 hours';
do $$ begin
  if autopilot_claim('66666666-0000-0000-0000-0000000000c4') then raise exception 'CONTROLS CHECK FAILED: sent with a stale reply monitor'; end if;
  perform ops_check('11111111-0000-0000-0000-0000000000c9');
  if not exists (select 1 from alerts where client_id = '11111111-0000-0000-0000-0000000000c9' and kind = 'reply_monitor_stale' and status = 'open')
     and extract(hour from now() at time zone 'America/Mexico_City') between 9 and 20 then
    raise exception 'CONTROLS CHECK FAILED: no alert for the stale monitor';
  end if;
end $$;
update monitor_runs set ran_at = now();

-- 6) the pause switch stops claims
do $$ begin
  perform ops_pause('test', 'tester');
  if autopilot_claim('66666666-0000-0000-0000-0000000000c4') then raise exception 'CONTROLS CHECK FAILED: sent while paused'; end if;
  perform ops_resume('tester');
end $$;

-- 7) the cap counts every email out today: with a cap of 2, Dora waits
update autopilot_ramp set daily_cap = 2 where client_id = '11111111-0000-0000-0000-0000000000c9';
do $$ begin
  if autopilot_claim('66666666-0000-0000-0000-0000000000c4') then raise exception 'CONTROLS CHECK FAILED: cap overrun'; end if;
end $$;
update autopilot_ramp set daily_cap = 10 where client_id = '11111111-0000-0000-0000-0000000000c9';

-- 8) a reply from a colleague at the same domain goes to identity review and holds the company; Ana is untouched
do $$
declare r jsonb;
begin
  r := monitor_file_email(jsonb_build_object('gmail_message_id', 'in-1', 'gmail_thread_id', 'thread-other', 'from', 'boss@buyer-one.example',
         'subject', 'Re: Muebles', 'body', 'Please stop emailing our team', 'category', 'unsubscribe', 'summary', 'asked to stop'));
  if r->>'result' <> 'identity_review' then raise exception 'CONTROLS CHECK FAILED: domain match acted on a guessed person: %', r; end if;
  if (select do_not_contact from contacts where id = '55555555-0000-0000-0000-0000000000c1') then
    raise exception 'CONTROLS CHECK FAILED: the guessed contact was stopped';
  end if;
  if not is_suppressed('boss@buyer-one.example') then raise exception 'CONTROLS CHECK FAILED: the sender was not suppressed'; end if;
  if not exists (select 1 from unnest(autopilot_send_check('66666666-0000-0000-0000-0000000000c2')) w where w like '%identity review%') then
    raise exception 'CONTROLS CHECK FAILED: the company was not held during identity review';
  end if;
end $$;

-- 9) out of office snoozes; a refusal holds the whole company
do $$
declare r jsonb;
begin
  r := monitor_file_email(jsonb_build_object('gmail_message_id', 'in-2', 'gmail_thread_id', 'thread-1', 'from', 'ana@buyer-one.example',
         'subject', 'Fuera de la oficina', 'body', 'Regreso el lunes', 'category', 'out_of_office', 'resume_on', (current_date + 5)::text));
  if coalesce(r->>'result', '') <> 'out_of_office'
     or (select snoozed_until from contacts where id = '55555555-0000-0000-0000-0000000000c1') < (current_date + 6)::timestamptz
     or exists (select 1 from autopilot_due_followups('11111111-0000-0000-0000-0000000000c9') f where f.contact_id = '55555555-0000-0000-0000-0000000000c1') then
    raise exception 'CONTROLS CHECK FAILED: out of office did not snooze';
  end if;
  perform autopilot_mark_sent('66666666-0000-0000-0000-0000000000c3', 'msg-3', 'thread-3');
  r := monitor_file_email(jsonb_build_object('gmail_message_id', 'in-3', 'from', 'carla@buyer-two.example',
         'subject', 'Re: Muebles', 'body', 'No gracias', 'category', 'not_interested', 'summary', 'no'));
  insert into contacts (id, company_id, first_name, email, email_source, country, email_basis)
  values ('55555555-0000-0000-0000-0000000000c6', '33333333-0000-0000-0000-0000000000c2', 'Eva', 'eva@buyer-two.example', 'apollo', 'MX', 'legitimate_interest');
  insert into outreach_drafts (id, client_id, contact_id, company_id, channel, step, purpose, subject, body, status)
  select '66666666-0000-0000-0000-0000000000c6', '11111111-0000-0000-0000-0000000000c9', '55555555-0000-0000-0000-0000000000c6',
         '33333333-0000-0000-0000-0000000000c2', 'email', 1, 'first', 'Muebles', b, 'approved' from body;
  if not exists (select 1 from unnest(autopilot_send_check('66666666-0000-0000-0000-0000000000c6')) w where w like 'Someone at this company said no%') then
    raise exception 'CONTROLS CHECK FAILED: refusal did not hold the company';
  end if;
end $$;

-- 10) a fact marked "conflict" in the sales pack holds a draft that uses it
insert into sales_pack_items (client_id, topic, item, status, lint_pattern)
values ('11111111-0000-0000-0000-0000000000c9', 'quality', 'FTC certification', 'conflict', '\mFTC\M');
update outreach_drafts set body = replace(body, 'desde 1993.', 'desde 1993, con certificación FTC.') where id = '66666666-0000-0000-0000-0000000000c4';
do $$ begin
  if not exists (select 1 from unnest(autopilot_send_check('66666666-0000-0000-0000-0000000000c4')) w where w like 'Uses a fact that is not confirmed%') then
    raise exception 'CONTROLS CHECK FAILED: unconfirmed fact not caught';
  end if;
end $$;

-- 11) scheduling messages: a price question is not for the autopilot
do $$ begin
  if cardinality(autopilot_scheduling_check('11111111-0000-0000-0000-0000000000c9', '¿Le acomoda el martes a las 11:00?')) > 0 then
    raise exception 'CONTROLS CHECK FAILED: a plain time proposal was blocked';
  end if;
  if cardinality(autopilot_scheduling_check('11111111-0000-0000-0000-0000000000c9', 'El precio por pieza es de $1,200 MXN')) = 0 then
    raise exception 'CONTROLS CHECK FAILED: a price in a scheduling email was allowed';
  end if;
end $$;

-- 12) the public key can call none of it
set local role anon;
do $$ begin
  perform autopilot_claim('66666666-0000-0000-0000-0000000000c4');
  raise exception 'CONTROLS CHECK FAILED: the public key could claim a send';
exception when insufficient_privilege then null;
end $$;
do $$ begin
  perform phone_pause(true, 'x');
  raise exception 'CONTROLS CHECK FAILED: the public key could pause';
exception when insufficient_privilege then null;
end $$;
reset role;

select 'All sending-control checks passed. Nothing was saved.' as result;
rollback;
