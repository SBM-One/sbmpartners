-- Checks qualification, answers, check-ins and the meeting handoff (0006_qualify_and_handoff.sql).
-- Safe to run anytime: everything is rolled back.
-- Works in the Supabase SQL editor or with:  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/verify_pipeline.sql
-- Any failed check stops with an error that starts with "PIPELINE CHECK FAILED".

begin;

insert into clients (id, name, brief, brief_approved_at, sender_name, postal_address)
values ('66666666-0000-0000-0000-0000000000c1', 'Pipeline test client', '{"brand":"T"}', now(), 'Ana', 'Calle 1, Madrid');
insert into companies (id, name, domain, country) values
  ('77777777-0000-0000-0000-0000000000c1', 'Pipeline test shop', 'pipeline-shop.example', 'FR');
insert into contacts (id, company_id, first_name, email, email_source, email_basis) values
  ('88888888-0000-0000-0000-0000000000c1', '77777777-0000-0000-0000-0000000000c1', 'Fit', 'fit@pipeline-shop.example', 'their website', 'legitimate_interest'),
  ('88888888-0000-0000-0000-0000000000c2', '77777777-0000-0000-0000-0000000000c1', 'Meh', 'meh@pipeline-shop.example', 'their website', 'legitimate_interest');
insert into campaigns (id, client_id, name, status, snooze_days) values
  ('99999999-0000-0000-0000-0000000000c1', '66666666-0000-0000-0000-0000000000c1', 'Pipeline test campaign', 'live', 30);
insert into campaign_targets (campaign_id, contact_id, company_id) values
  ('99999999-0000-0000-0000-0000000000c1', '88888888-0000-0000-0000-0000000000c1', '77777777-0000-0000-0000-0000000000c1'),
  ('99999999-0000-0000-0000-0000000000c1', '88888888-0000-0000-0000-0000000000c2', '77777777-0000-0000-0000-0000000000c1');
update email_country_rules set confirmed_at = now(), confirmed_by = 'test' where country = 'FR';
insert into prospect_strategies (client_id, campaign_id, contact_id, fit_score, decision, reason, channel_plan) values
  ('66666666-0000-0000-0000-0000000000c1', '99999999-0000-0000-0000-0000000000c1', '88888888-0000-0000-0000-0000000000c1', 82, 'pursue', 'Fits', 'email'),
  ('66666666-0000-0000-0000-0000000000c1', '99999999-0000-0000-0000-0000000000c1', '88888888-0000-0000-0000-0000000000c2', 41, 'nurture', 'Weak', 'email');

do $$
declare
  cl uuid := '66666666-0000-0000-0000-0000000000c1';
  ca uuid := '99999999-0000-0000-0000-0000000000c1';
  fit uuid := '88888888-0000-0000-0000-0000000000c1';
  meh uuid := '88888888-0000-0000-0000-0000000000c2';
  d1 uuid; d2 uuid; fu uuid; ans uuid; ci uuid; rep uuid; h uuid; deal uuid; st text;
begin
  -- 1) a first message needs "pursue"
  insert into outreach_drafts (client_id, campaign_id, contact_id, subject, body) values (cl, ca, meh, 'Hi', 'Hello') returning id into d2;
  if (select purpose from outreach_drafts where id = d2) <> 'first' then raise exception 'PIPELINE CHECK FAILED: purpose not set'; end if;
  if not array_to_string(send_blockers(d2), ' ') like '%marked "nurture"%' then
    raise exception 'PIPELINE CHECK FAILED: a nurture buyer could get a first message (%)', send_blockers(d2);
  end if;
  update prospect_strategies set decision = 'pursue', decided_by = 'you' where contact_id = meh;
  if cardinality(send_blockers(d2)) <> 0 then raise exception 'PIPELINE CHECK FAILED: your override did not unblock'; end if;
  raise notice 'ok: only buyers marked "pursue" can get a first message, and your override counts';

  -- 2) send the first email; a follow-up is fine until the buyer replies
  insert into outreach_drafts (client_id, campaign_id, contact_id, subject, body) values (cl, ca, fit, 'Oak', 'Hello') returning id into d1;
  update outreach_drafts set status = 'approved' where id = d1;
  update outreach_drafts set status = 'sent', message_id = '<p1@test>' where id = d1;
  insert into outreach_drafts (client_id, campaign_id, contact_id, step, body) values (cl, ca, fit, 2, 'More') returning id into fu;
  if (select purpose from outreach_drafts where id = fu) <> 'follow_up' then raise exception 'PIPELINE CHECK FAILED: follow-up not labelled'; end if;
  if cardinality(send_blockers(fu)) <> 0 then raise exception 'PIPELINE CHECK FAILED: valid follow-up blocked: %', send_blockers(fu); end if;

  -- 3) the buyer is interested: follow-ups stop, but our answer may go out
  insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, subject, body, external_id, metadata)
  values (cl, ca, fit, 'email', 'inbound', 'reply', 'buyer', 'Re: Oak', 'Yes, send prices', '<r1@buyer>',
          '{"category":"interested","summary":"Wants prices"}') returning id into rep;
  if apply_reply(rep) <> 'interested' then raise exception 'PIPELINE CHECK FAILED: apply_reply'; end if;
  if (select status from outreach_drafts where id = fu) <> 'cancelled' then
    raise exception 'PIPELINE CHECK FAILED: the follow-up was not cancelled after the reply';
  end if;
  if (select status from campaign_targets where campaign_id = ca and contact_id = fit) <> 'engaged' then
    raise exception 'PIPELINE CHECK FAILED: buyer not marked engaged';
  end if;
  insert into outreach_drafts (client_id, campaign_id, contact_id, step, purpose, reply_to_interaction_id, body)
  values (cl, ca, fit, 2, 'reply', rep, 'Here are the prices') returning id into ans;
  if cardinality(send_blockers(ans)) <> 0 then raise exception 'PIPELINE CHECK FAILED: answer blocked: %', send_blockers(ans); end if;
  if (select stage from v_conversations where campaign_id = ca and contact_id = fit) <> 'answer_waiting' then
    raise exception 'PIPELINE CHECK FAILED: tracker stage is % (expected answer_waiting)',
      (select stage from v_conversations where campaign_id = ca and contact_id = fit);
  end if;
  raise notice 'ok: a reply stops follow-ups; our answer to it is allowed and shows in the tracker';

  -- 4) the meeting handoff: booking logs it, opens the deal and blocks automatic messages
  insert into meeting_handoffs (client_id, campaign_id, contact_id, reply_interaction_id, qualified, interest, product_fit, body)
  values (cl, ca, fit, rep, true, 'Prices', 'Oak chairs', '# Brief') returning id into h;
  begin
    insert into meeting_handoffs (client_id, contact_id, qualified, interest, product_fit, body) values (cl, fit, true, 'x', 'x', 'x');
    raise exception 'PIPELINE CHECK FAILED: two open meeting briefs for one buyer';
  exception when unique_violation then null;
  end;
  deal := book_meeting(h, now() + interval '2 days', 'Zoom', 'test');
  if not exists (select 1 from deals where id = deal and client_id = cl) then raise exception 'PIPELINE CHECK FAILED: no deal'; end if;
  if not exists (select 1 from interactions where contact_id = fit and kind = 'meeting_booked') then
    raise exception 'PIPELINE CHECK FAILED: the meeting was not logged';
  end if;
  if (select status from campaign_targets where campaign_id = ca and contact_id = fit) <> 'meeting' then
    raise exception 'PIPELINE CHECK FAILED: buyer not moved to meeting';
  end if;
  insert into outreach_drafts (client_id, campaign_id, contact_id, step, purpose, body) values (cl, ca, fit, 3, 'follow_up', 'x') returning id into fu;
  if not array_to_string(send_blockers(fu), ' ') like '%handed to you for a meeting%' then
    raise exception 'PIPELINE CHECK FAILED: a follow-up was allowed after the meeting was booked';
  end if;
  if (select stage from v_conversations where campaign_id = ca and contact_id = fit) <> 'meeting_booked' then
    raise exception 'PIPELINE CHECK FAILED: tracker does not show the booked meeting';
  end if;
  perform close_meeting(h, 'held', 'Good', 'test');
  if not exists (select 1 from interactions where contact_id = fit and kind = 'meeting_held') then
    raise exception 'PIPELINE CHECK FAILED: the held meeting was not logged';
  end if;
  raise notice 'ok: booking a meeting logs it, opens the deal and stops automatic messages';

  -- 5) "not now": snoozed, one check-in only after the snooze
  update outreach_drafts set status = 'approved' where id = d2;
  update outreach_drafts set status = 'sent', message_id = '<p2@test>' where id = d2;
  insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, body, external_id, metadata)
  values (cl, ca, meh, 'email', 'inbound', 'reply', 'buyer', 'Maybe in spring', '<r2@buyer>',
          '{"category":"not_now","summary":"Spring"}') returning id into rep;
  perform apply_reply(rep);
  if (select snoozed_until from campaign_targets where campaign_id = ca and contact_id = meh) < now() + interval '29 days' then
    raise exception 'PIPELINE CHECK FAILED: not now did not snooze for the campaign''s 30 days';
  end if;
  insert into outreach_drafts (client_id, campaign_id, contact_id, step, purpose, reply_to_interaction_id, body)
  values (cl, ca, meh, 2, 'check_in', rep, 'Spring is here') returning id into ci;
  if not array_to_string(send_blockers(ci), ' ') like '%snooze%has not ended%' then
    raise exception 'PIPELINE CHECK FAILED: a check-in was allowed during the snooze';
  end if;
  update campaign_targets set snoozed_until = now() - interval '1 minute' where campaign_id = ca and contact_id = meh;
  if cardinality(send_blockers(ci)) <> 0 then raise exception 'PIPELINE CHECK FAILED: check-in blocked: %', send_blockers(ci); end if;
  update outreach_drafts set status = 'approved' where id = ci;
  update outreach_drafts set status = 'sent' where id = ci;
  insert into outreach_drafts (client_id, campaign_id, contact_id, step, purpose, reply_to_interaction_id, body)
  values (cl, ca, meh, 3, 'check_in', rep, 'Again') returning id into ci;
  if not array_to_string(send_blockers(ci), ' ') like '%one check-in%' then
    raise exception 'PIPELINE CHECK FAILED: a second check-in was allowed';
  end if;
  raise notice 'ok: not now snoozes the buyer and allows exactly one check-in afterwards';

  -- 6) unsubscribe in a reply stops everything, including pending answers
  insert into outreach_drafts (client_id, campaign_id, contact_id, step, purpose, reply_to_interaction_id, body)
  values (cl, ca, meh, 3, 'reply', rep, 'Pending answer') returning id into ans;
  insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, body, metadata)
  values (cl, ca, meh, 'linkedin', 'inbound', 'reply', 'buyer', 'Stop', '{"category":"unsubscribe","summary":"Stop"}')
  returning id into rep;
  if apply_reply(rep) <> 'stopped' then raise exception 'PIPELINE CHECK FAILED: unsubscribe not applied'; end if;
  if not (select do_not_contact from contacts where id = meh) then raise exception 'PIPELINE CHECK FAILED: not do-not-contact'; end if;
  if (select status from outreach_drafts where id = ans) <> 'cancelled' then
    raise exception 'PIPELINE CHECK FAILED: a pending answer survived an unsubscribe';
  end if;
  raise notice 'ok: an unsubscribe on any channel cancels pending answers and stops everything';
end $$;

select 'All pipeline checks passed. Nothing was saved.' as result;
rollback;
