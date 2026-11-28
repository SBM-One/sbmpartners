-- Checks the phone app's functions (0009_phone_app.sql, 0016_operating_controls.sql): only people on the staff list get anything, the public
-- key can't even call them, and the actions log what they should. Rolls back, so nothing is saved.
-- Any failure stops with an error that starts with "PHONE CHECK FAILED".

begin;

insert into staff (name, email, role) values ('Phone test', 'phone-test@sbm-test.example', 'admin');
insert into clients (id, name, brief_approved_at) values ('11111111-0000-0000-0000-0000000000f9', 'Phone test client', now());
insert into companies (id, name) values ('33333333-0000-0000-0000-0000000000f9', 'Phone test buyer');
insert into contacts (id, company_id, first_name, phone, whatsapp, linkedin_url, email) values
  ('55555555-0000-0000-0000-0000000000f9', '33333333-0000-0000-0000-0000000000f9', 'Ana', '+52 55 1234 5678', null,
   'https://www.linkedin.com/in/phone-test', 'ana@phone-test.example'),
  ('55555555-0000-0000-0000-0000000000f8', '33333333-0000-0000-0000-0000000000f9', 'Beto', null, null, null, null);
update contacts set do_not_contact = true where id = '55555555-0000-0000-0000-0000000000f8';
insert into outreach_drafts (id, client_id, contact_id, company_id, channel, subject, body) values
  ('66666666-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-0000000000f9', '55555555-0000-0000-0000-0000000000f9',
   '33333333-0000-0000-0000-0000000000f9', 'other', 'WhatsApp +52 55 9999 8888', 'Hola Ana'),
  ('66666666-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-0000000000f9', '55555555-0000-0000-0000-0000000000f9',
   '33333333-0000-0000-0000-0000000000f9', 'linkedin', 'Nota', 'Nota para Ana'),
  ('66666666-0000-0000-0000-0000000000f3', '11111111-0000-0000-0000-0000000000f9', '55555555-0000-0000-0000-0000000000f8',
   '33333333-0000-0000-0000-0000000000f9', 'linkedin', 'Nota', 'Nota para Beto');

-- 1) the public key cannot call the functions at all
set local role anon;
do $$ begin
  perform phone_today();
  raise exception 'PHONE CHECK FAILED: the public key could call phone_today()';
exception when insufficient_privilege then null;
end $$;
reset role;

-- 2) a signed-in stranger is turned away
set local role authenticated;
select set_config('request.jwt.claims', '{"email":"stranger@example.com","role":"authenticated"}', true);
do $$ begin
  perform phone_queue();
  raise exception 'PHONE CHECK FAILED: a login that is not on the staff list could read the queue';
exception when insufficient_privilege then null;
end $$;

-- 3) staff (email matched without regard to case) see the queue, with the WhatsApp number from the subject
select set_config('request.jwt.claims', '{"email":"Phone-Test@sbm-test.example","role":"authenticated"}', true);
do $$
declare q jsonb := phone_queue(); w jsonb;
begin
  select e into w from jsonb_array_elements(q) e where e->>'id' = '66666666-0000-0000-0000-0000000000f1';
  if w is null then raise exception 'PHONE CHECK FAILED: the WhatsApp draft is missing from the queue'; end if;
  if w->>'kind' <> 'whatsapp' or w->>'number' <> '525599998888' then
    raise exception 'PHONE CHECK FAILED: WhatsApp kind/number wrong: % %', w->>'kind', w->>'number';
  end if;
  if phone_today() ->> 'me' <> 'Phone test' then raise exception 'PHONE CHECK FAILED: phone_today() did not know who is signed in'; end if;
  if jsonb_typeof(phone_inbox() -> 'replies') <> 'array' then raise exception 'PHONE CHECK FAILED: phone_inbox() has no replies list'; end if;
end $$;

-- 4) WhatsApp needs a recorded opt-in; opening the app only "prepares" it; tapping Sent records and logs it
do $$ begin
  perform phone_mark('66666666-0000-0000-0000-0000000000f1', 'opened');
  raise exception 'PHONE CHECK FAILED: a WhatsApp without opt-in could be opened';
exception when raise_exception then
  if sqlerrm like 'PHONE CHECK FAILED%' then raise; end if;
end $$;
do $$ begin
  if phone_opt_in('55555555-0000-0000-0000-0000000000f9', 'asked_on_call', 'Call 27 Nov, she said WhatsApp is fine') <> 'recorded' then
    raise exception 'PHONE CHECK FAILED: opt-in not recorded';
  end if;
  if phone_mark('66666666-0000-0000-0000-0000000000f1', 'opened') <> 'prepared' then raise exception 'PHONE CHECK FAILED: opened'; end if;
end $$;
reset role;
do $$ begin
  if (select delivery from outreach_drafts where id = '66666666-0000-0000-0000-0000000000f1') <> 'prepared'
     or exists (select 1 from interactions where metadata->>'draft_id' = '66666666-0000-0000-0000-0000000000f1') then
    raise exception 'PHONE CHECK FAILED: opening the app must not log a send';
  end if;
end $$;
set local role authenticated;
select set_config('request.jwt.claims', '{"email":"phone-test@sbm-test.example","role":"authenticated"}', true);
do $$ begin
  if phone_mark('66666666-0000-0000-0000-0000000000f1', 'confirmed') <> 'sent' then raise exception 'PHONE CHECK FAILED: confirm'; end if;
end $$;
reset role;
do $$ begin
  if (select status::text || delivery from outreach_drafts where id = '66666666-0000-0000-0000-0000000000f1') <> 'sentsent' then
    raise exception 'PHONE CHECK FAILED: the WhatsApp draft is not marked sent';
  end if;
  if not exists (select 1 from interactions where metadata->>'draft_id' = '66666666-0000-0000-0000-0000000000f1'
                 and channel::text = 'whatsapp' and actor = 'staff' and direction = 'outbound') then
    raise exception 'PHONE CHECK FAILED: the WhatsApp send was not logged';
  end if;
end $$;

-- 5) the safety gate still holds: a do-not-contact buyer can't be approved or marked sent
set local role authenticated;
select set_config('request.jwt.claims', '{"email":"phone-test@sbm-test.example","role":"authenticated"}', true);
do $$ begin
  perform phone_mark('66666666-0000-0000-0000-0000000000f3', 'sent');
  raise exception 'PHONE CHECK FAILED: a do-not-contact buyer was marked sent';
exception when raise_exception then
  if sqlerrm like 'PHONE CHECK FAILED%' then raise; end if;
end $$;

-- 6) skipping a LinkedIn note cancels it, and a second decision is refused
do $$ begin
  perform phone_mark('66666666-0000-0000-0000-0000000000f2', 'skip');
  begin
    perform phone_mark('66666666-0000-0000-0000-0000000000f2', 'sent');
    raise exception 'PHONE CHECK FAILED: a skipped note could still be marked sent';
  exception when raise_exception then
    if sqlerrm like 'PHONE CHECK FAILED%' then raise; end if;
  end;
end $$;
reset role;

select 'All phone checks passed. Nothing was saved.' as result;
rollback;
