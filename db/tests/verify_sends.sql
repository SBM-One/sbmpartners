-- Checks the first-sends rules (0005_first_sends.sql). Safe to run anytime: everything is rolled back.
-- Works in the Supabase SQL editor or with:  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/verify_sends.sql
-- Any failed check stops with an error that starts with "SENDS CHECK FAILED".

begin;

insert into clients (id, name, brief, brief_approved_at, sender_name, postal_address)
values ('55555555-0000-0000-0000-0000000000b1', 'Sends test client', '{"brand":"T"}', now(), 'Ana', 'Calle 1, Madrid');
insert into companies (id, name, domain, country) values
  ('77777777-0000-0000-0000-0000000000b1', 'Sends test shop', 'sends-shop.example', 'FR'),
  ('77777777-0000-0000-0000-0000000000b2', 'Sends test Studio', 'sends-studio.example', 'DE');
insert into contacts (id, company_id, first_name, email, email_source, email_basis) values
  ('88888888-0000-0000-0000-0000000000b1', '77777777-0000-0000-0000-0000000000b1', 'Fr', 'fr@sends-shop.example', 'their website', 'legitimate_interest'),
  ('88888888-0000-0000-0000-0000000000b2', '77777777-0000-0000-0000-0000000000b2', 'De', 'de@sends-studio.example', 'their website', 'legitimate_interest');
insert into campaigns (id, client_id, name, status) values
  ('99999999-0000-0000-0000-0000000000b1', '55555555-0000-0000-0000-0000000000b1', 'Sends test campaign', 'live');
update email_country_rules set confirmed_at = null where country in ('FR','DE');

do $$
declare d uuid; d2 uuid; why text[]; tok text;
begin
  insert into outreach_drafts (id, client_id, campaign_id, contact_id, subject, body)
  values ('aaaaaaaa-0000-0000-0000-0000000000b1', '55555555-0000-0000-0000-0000000000b1', '99999999-0000-0000-0000-0000000000b1',
          '88888888-0000-0000-0000-0000000000b1', 'Oak for your shop', 'Hello') returning id into d;

  -- 1) an unconfirmed country rule blocks the send
  why := send_blockers(d);
  if not array_to_string(why, ' ') like '%rule for France has not been confirmed%' then
    raise exception 'SENDS CHECK FAILED: an unconfirmed country rule did not block (%).', why;
  end if;
  begin
    update outreach_drafts set status = 'approved' where id = d;
    raise exception 'SENDS CHECK FAILED: a blocked draft was approved';
  exception when raise_exception then
    if sqlerrm like 'SENDS CHECK FAILED%' then raise; end if;
  end;

  -- 2) once confirmed, a business address in France with legitimate interest may be approved and sent
  update email_country_rules set confirmed_at = now(), confirmed_by = 'test' where country in ('FR','DE');
  if cardinality(send_blockers(d)) <> 0 then raise exception 'SENDS CHECK FAILED: still blocked: %', send_blockers(d); end if;
  update outreach_drafts set status = 'approved' where id = d;
  update outreach_drafts set status = 'sent', message_id = '<t1@test>' where id = d;
  if (select sent_at from outreach_drafts where id = d) is null then raise exception 'SENDS CHECK FAILED: no sent time'; end if;
  begin
    update outreach_drafts set status = 'approved' where id = d;
    raise exception 'SENDS CHECK FAILED: a sent message was un-sent';
  exception when raise_exception then
    if sqlerrm like 'SENDS CHECK FAILED%' then raise; end if;
  end;
  raise notice 'ok: country rules must be confirmed before anything is approved, and sent stays sent';

  -- 3) Germany needs consent: legitimate interest is not enough
  insert into outreach_drafts (client_id, campaign_id, contact_id, subject, body)
  values ('55555555-0000-0000-0000-0000000000b1', '99999999-0000-0000-0000-0000000000b1',
          '88888888-0000-0000-0000-0000000000b2', 'Hi', 'Hello') returning id into d2;
  if not array_to_string(send_blockers(d2), ' ') like '%Germany needs the buyer''s prior consent%' then
    raise exception 'SENDS CHECK FAILED: Germany without consent was not blocked (%).', send_blockers(d2);
  end if;
  update contacts set email_basis = 'consent' where id = '88888888-0000-0000-0000-0000000000b2';
  if cardinality(send_blockers(d2)) <> 0 then raise exception 'SENDS CHECK FAILED: consent did not unblock Germany'; end if;
  raise notice 'ok: consent-only countries need recorded consent';

  -- 4) missing sender address, missing email source and suppressed domains all block
  update clients set postal_address = null where id = '55555555-0000-0000-0000-0000000000b1';
  update contacts set email_source = null where id = '88888888-0000-0000-0000-0000000000b2';
  insert into suppressions (value, reason) values ('sends-studio.example', 'test');
  why := send_blockers(d2);
  if cardinality(why) <> 3 then raise exception 'SENDS CHECK FAILED: expected 3 blockers, got %', why; end if;
  update clients set postal_address = 'Calle 1, Madrid' where id = '55555555-0000-0000-0000-0000000000b1';
  update contacts set email_source = 'card' where id = '88888888-0000-0000-0000-0000000000b2';
  delete from suppressions where value = 'sends-studio.example';
  raise notice 'ok: sender address, email source and the suppression list are enforced';

  -- 5) a follow-up waits for the first email, and stops once the buyer replied
  insert into outreach_drafts (id, client_id, campaign_id, contact_id, step, body)
  values ('aaaaaaaa-0000-0000-0000-0000000000b2', '55555555-0000-0000-0000-0000000000b1', '99999999-0000-0000-0000-0000000000b1',
          '88888888-0000-0000-0000-0000000000b1', 2, 'Following up');
  if cardinality(send_blockers('aaaaaaaa-0000-0000-0000-0000000000b2')) <> 0 then
    raise exception 'SENDS CHECK FAILED: a valid follow-up was blocked: %', send_blockers('aaaaaaaa-0000-0000-0000-0000000000b2');
  end if;
  insert into interactions (client_id, contact_id, channel, direction, kind, actor)
  values ('55555555-0000-0000-0000-0000000000b1', '88888888-0000-0000-0000-0000000000b1', 'email', 'inbound', 'reply', 'buyer');
  if not array_to_string(send_blockers('aaaaaaaa-0000-0000-0000-0000000000b2'), ' ') like '%already replied%' then
    raise exception 'SENDS CHECK FAILED: a follow-up was allowed after a reply';
  end if;
  raise notice 'ok: follow-ups stop when the buyer replies';

  -- 6) the unsubscribe link stops everything, everywhere
  select unsubscribe_token into tok from contacts where id = '88888888-0000-0000-0000-0000000000b2';
  update outreach_drafts set status = 'approved' where id = d2;
  if not unsubscribe_by_token(tok) then raise exception 'SENDS CHECK FAILED: the unsubscribe link did nothing'; end if;
  if unsubscribe_by_token('not-a-real-token') then raise exception 'SENDS CHECK FAILED: a fake token unsubscribed someone'; end if;
  if not (select do_not_contact from contacts where id = '88888888-0000-0000-0000-0000000000b2') then
    raise exception 'SENDS CHECK FAILED: unsubscribed buyer is not do-not-contact';
  end if;
  if (select status from outreach_drafts where id = d2) <> 'cancelled' then
    raise exception 'SENDS CHECK FAILED: an approved email to an unsubscribed buyer was not cancelled';
  end if;
  if not is_suppressed('DE@sends-studio.example') then raise exception 'SENDS CHECK FAILED: the address was not suppressed'; end if;
  if not exists (select 1 from interactions where contact_id = '88888888-0000-0000-0000-0000000000b2' and kind = 'unsubscribe') then
    raise exception 'SENDS CHECK FAILED: the unsubscribe was not logged';
  end if;
  raise notice 'ok: unsubscribing cancels every unsent message and suppresses the address';
end $$;

select 'All sending checks passed. Nothing was saved.' as result;
rollback;
