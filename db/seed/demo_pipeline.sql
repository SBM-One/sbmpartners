-- Made-up demo data for previewing the Buyers and Meetings screens locally. Load after demo_dashboard.sql and demo_sends.sql.
-- Every name, email and conversation is invented. Never load this into the real Supabase project.
-- Run it as one transaction (psql -1, or the SQL editor). The draft guard is paused while the made-up sent emails are added.

alter table outreach_drafts disable trigger outreach_drafts_guard;

insert into campaign_targets (campaign_id, contact_id, company_id, status)
select 'd0000000-0000-0000-0000-0000000000e1', c.id, c.company_id, 'queued' from contacts c
on conflict do nothing;

-- The Strategist's calls
insert into prospect_strategies (client_id, campaign_id, contact_id, company_id, fit_score, fit_breakdown, decision, reason,
                                 pitch_angle, lead_with, proof_points, offer, objections, first_ask, channel_plan, channel_reason)
select 'd0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000e1', c.id, c.company_id, s.score,
       jsonb_build_array(
         jsonb_build_object('key','product_fit','score',s.p,'weight',30,'why',s.pw),
         jsonb_build_object('key','buyer_type_fit','score',4,'weight',20,'why','Independent retail and design trade are the brand''s best channels.'),
         jsonb_build_object('key','price_fit','score',s.pr,'weight',20,'why','Mid-to-upper price level matches the brand.'),
         jsonb_build_object('key','authority','score',4,'weight',15,'why','Title suggests they choose the range.'),
         jsonb_build_object('key','timing','score',s.t,'weight',15,'why',s.tw)),
       s.decision, s.reason, s.angle, s.lead::jsonb, '["Sold in 38 independent stores","Average store reorders every 10 weeks"]'::jsonb,
       'Free sample kit and a 90-day sell-through guarantee on the opening order',
       '[{"objection":"Opening order minimum","answer":"$1,500 to open, no minimum on reorders"},{"objection":"Lead times","answer":"4-6 weeks from stock"}]'::jsonb,
       'Send the free sample kit?', s.plan, s.planwhy
from contacts c
join (values
  ('Jenna',  88, 5, 4, 4, 'pursue',     'Carries solid-wood furniture at the right price; opening a second store.', 'Their second store opens in spring and needs a lounge range.', '["Lounge chairs","Side tables"]', 'email_and_linkedin', 'Email allowed; LinkedIn profile on file.', 'Carries solid oak dining and lounge.', 'Second store opening in spring.'),
  ('Marcus', 76, 4, 4, 4, 'pursue',     'Designer doing residential projects; trade programme fits.', 'Trade pricing and free finish samples for his residential projects.', '["Trade program","Lamps"]', 'email', 'Email allowed.', 'Specifies wood furniture in projects.', 'Two projects in fit-out.'),
  ('Priya',  84, 4, 4, 5, 'pursue',     'Hotel group refurbishing rooms; contract chairs fit.', 'Contract chairs with commercial finish for the room refresh.', '["Contract chairs"]', 'email', 'Email allowed.', 'Buys FF&E for 6 hotels.', 'Room refresh announced.'),
  ('Tom',    72, 4, 3, 3, 'pursue',     'Independent store with a wood-led range.', 'A small opening order with a sell-through guarantee.', '["Side tables"]', 'email', 'Email allowed.', 'Wood-led range.', 'No signal.'),
  ('Elena',  31, 1, 2, 2, 'disqualify', 'Builder buying flooring and fixtures, not furniture.', null, '[]', 'email', 'Email allowed.', 'Does not buy furniture.', 'No signal.'),
  ('Grace',  54, 3, 3, 2, 'nurture',    'Could fit, but no sign of current projects; check again next quarter.', null, '[]', 'email', 'Email allowed.', 'Some wood pieces in past projects.', 'Nothing current.'),
  ('Owen',   79, 4, 4, 4, 'pursue',     'Lifestyle store adding furniture.', 'Furniture to anchor their new home section.', '["Side tables","Lamps"]', 'email_and_linkedin', 'Email allowed; LinkedIn on file.', 'Adding furniture.', 'New home section.'),
  ('Sofia',  81, 4, 4, 4, 'pursue',     'Resort group with FF&E budget.', 'Contract chairs for the terrace refresh.', '["Contract chairs"]', 'email', 'Email allowed.', 'Buys FF&E.', 'Terrace refresh.'),
  ('Maya',   74, 4, 4, 3, 'pursue',     'Lighting-led store adding tables.', 'Lamps first, then tables.', '["Lamps"]', 'email', 'Email allowed.', 'Lighting-led.', 'Some.'),
  ('Leo',    70, 4, 3, 3, 'pursue',     'Hotel procurement; chairs fit.', 'Contract chairs.', '["Contract chairs"]', 'email_and_linkedin', 'Email allowed.', 'Buys chairs.', 'Some.'),
  ('Hannah', 73, 4, 3, 4, 'pursue',     'Contract firm with live projects.', 'Spec sheets and CAD.', '["Contract chairs"]', 'email', 'Email allowed.', 'Contract.', 'Live projects.'),
  ('Lena',   78, 4, 4, 4, 'pursue',     'Berlin store with oak furniture; Germany needs consent for email, so LinkedIn first.', 'Oak lounge pieces for a Berlin store.', '["Lounge chairs"]', 'linkedin', 'Germany needs prior consent for email, and none is recorded.', 'Oak furniture.', 'Some.')
) as s(name, score, p, pr, t, decision, reason, angle, lead, plan, planwhy, pw, tw) on s.name = c.first_name
on conflict (campaign_id, contact_id) do nothing;
update prospect_strategies set decided_by = 'yago@sbm-demo.example', reason = reason || ' (Yago: wait for their next season.)'
 where contact_id = (select id from contacts where first_name = 'Grace');
update campaign_targets t set fit_score = s.fit_score / 100.0 from prospect_strategies s
 where s.campaign_id = t.campaign_id and s.contact_id = t.contact_id;
update outreach_drafts set campaign_id = 'd0000000-0000-0000-0000-0000000000e1' where campaign_id is null;
update outreach_drafts d set strategy_id = s.id from prospect_strategies s where s.contact_id = d.contact_id and d.strategy_id is null;
insert into tasks (kind, status, client_id, campaign_id, contact_id) select 'qualify_prospect', 'running', 'd0000000-0000-0000-0000-0000000000c1',
  'd0000000-0000-0000-0000-0000000000e1', id from contacts where first_name = 'Daniel';

-- Conversations
do $$
declare
  cl uuid := 'd0000000-0000-0000-0000-0000000000c1';
  ca uuid := 'd0000000-0000-0000-0000-0000000000e1';
  jenna uuid; marcus uuid; priya uuid; sofia uuid; tom uuid; r uuid; s1 uuid; h uuid; deal uuid;
begin
  select id into jenna from contacts where first_name = 'Jenna';
  select id into marcus from contacts where first_name = 'Marcus';
  select id into priya from contacts where first_name = 'Priya';
  select id into sofia from contacts where first_name = 'Sofia';
  select id into tom from contacts where first_name = 'Tom';
  update outreach_drafts set sent_at = now() - interval '3 days' where contact_id = tom and status = 'sent';

  -- Jenna: interested yesterday. Our answer waits for approval; the meeting brief is ready.
  insert into outreach_drafts (client_id, campaign_id, contact_id, channel, step, purpose, subject, body, status, sent_at, message_id, score)
  values (cl, ca, jenna, 'email', 1, 'first', 'Lounge chairs for your second store',
          'Hi Jenna, congratulations on the second Oakline store. Our white-oak lounge chairs sell through in 10 weeks on average in independent stores like yours. Could I send you our free sample kit?', 'sent', now() - interval '8 days', '<j1@demo>', 88);
  insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, subject, body, external_id, occurred_at)
  values (cl, ca, jenna, 'email', 'outbound', 'sent', 'bot', 'Lounge chairs for your second store', 'Hi Jenna, congratulations on the second Oakline store. Our white-oak lounge chairs sell through in 10 weeks on average in independent stores like yours. Could I send you our free sample kit?', '<j1@demo>', now() - interval '8 days');
  insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, subject, body, external_id, occurred_at, metadata)
  values (cl, ca, jenna, 'email', 'inbound', 'reply', 'buyer', 'Re: Lounge chairs for your second store',
          'Yes, please send the sample kit and your wholesale price list. We are finalising the range for the new store by the end of next month. Who decides the terms on your side?',
          '<j2@demo>', now() - interval '1 day', '{"category":"interested","summary":"Wants the sample kit and price list; finalising the new store range by end of next month."}')
  returning id into r;
  insert into outreach_drafts (client_id, campaign_id, contact_id, channel, step, purpose, reply_to_interaction_id, body, score, grade_feedback)
  values (cl, ca, jenna, 'email', 2, 'reply', r,
          'Thank you, Jenna. The sample kit goes out today, and the price list is attached: lounge chairs from $640 wholesale, a $1,500 opening order, and no minimum on reorders. I set the terms with Alder & Oak myself. Would a 20-minute call on Tuesday or Thursday suit you to walk through the range for the new store?',
          91, 'Answers both questions with facts from the brief and proposes a clear next step.' || chr(10) || 'Top fix: none needed.');
  insert into meeting_handoffs (client_id, campaign_id, contact_id, reply_interaction_id, strategy_id, qualified, checks, interest, product_fit,
                                contact_history, open_questions, next_steps, agenda, body)
  values (cl, ca, jenna, r, (select id from prospect_strategies where contact_id = jenna), true,
    '[{"key":"interest","status":"yes","evidence":"\"Yes, please send the sample kit and your wholesale price list.\""},
      {"key":"product_fit","status":"yes","evidence":"Oakline carries solid oak lounge and dining; the new store needs a lounge range."},
      {"key":"authority","status":"yes","evidence":"Head buyer, and she is finalising the range herself."},
      {"key":"timing","status":"yes","evidence":"\"Finalising the range for the new store by the end of next month.\""},
      {"key":"terms","status":"unclear","evidence":"Asked who decides terms; minimums and freight not discussed yet."}]',
    'The sample kit and the wholesale price list, to choose lounge pieces for the second store by the end of next month.',
    'White-oak lounge chairs and side tables: solid wood, mid-to-upper price, matching what Oakline already sells.',
    jsonb_build_array(
      jsonb_build_object('at', to_char(now() - interval '8 days', 'YYYY-MM-DD"T"HH24:MI'), 'channel','email','direction','outbound','kind','sent','from','us','subject','Lounge chairs for your second store','text','Hi Jenna, congratulations on the second Oakline store. Our white-oak lounge chairs sell through in 10 weeks on average in independent stores like yours. Could I send you our free sample kit?'),
      jsonb_build_object('at', to_char(now() - interval '1 day', 'YYYY-MM-DD"T"HH24:MI'), 'channel','email','direction','inbound','kind','reply','from','buyer','subject','Re: Lounge chairs for your second store','text','Yes, please send the sample kit and your wholesale price list. We are finalising the range for the new store by the end of next month. Who decides the terms on your side?','category','interested')),
    '["Floor space for lounge in the new store","Freight to their warehouse","Whether they want exclusivity in their town"]',
    '["Send the sample kit and price list today","Book a 20-minute call before the end of next week","Prepare a suggested opening order around $1,500"]',
    '["Their plan for the new store","Walk through lounge chairs and side tables","Terms: opening order, reorders, freight","Next step: opening order"]',
    '# Jenna Park, Oakline Home');

  -- Marcus: asked a question three hours ago; the Writer has not answered yet.
  insert into outreach_drafts (client_id, campaign_id, contact_id, channel, step, purpose, subject, body, status, sent_at, message_id)
  values (cl, ca, marcus, 'email', 1, 'first', 'Trade pricing for your residential projects', 'Hi Marcus, ...', 'sent', now() - interval '6 days', '<m1@demo>');
  insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, subject, body, external_id, occurred_at)
  values (cl, ca, marcus, 'email', 'outbound', 'sent', 'bot', 'Trade pricing for your residential projects', 'Hi Marcus, ...', '<m1@demo>', now() - interval '6 days');
  insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, subject, body, external_id, occurred_at, metadata)
  values (cl, ca, marcus, 'email', 'inbound', 'reply', 'buyer', 'Re: Trade pricing', 'Do you do custom finishes, and how long do they take?', '<m2@demo>',
          now() - interval '3 hours', '{"category":"question","summary":"Asks about custom finishes and their lead time."}');

  -- Priya: meeting booked for the day after tomorrow.
  insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, subject, body, external_id, occurred_at)
  values (cl, ca, priya, 'email', 'outbound', 'sent', 'bot', 'Contract chairs for the room refresh', 'Hi Priya, ...', '<p1@demo>', now() - interval '12 days');
  insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, subject, body, external_id, occurred_at, metadata)
  values (cl, ca, priya, 'email', 'inbound', 'reply', 'buyer', 'Re: Contract chairs', 'Interesting. Can we talk next week?', '<p2@demo>',
          now() - interval '5 days', '{"category":"interested","summary":"Wants a call next week about contract chairs."}') returning id into r;
  insert into outreach_drafts (client_id, campaign_id, contact_id, channel, step, purpose, subject, body, status, sent_at, message_id)
  values (cl, ca, priya, 'email', 1, 'first', 'Contract chairs for the room refresh', 'Hi Priya, ...', 'sent', now() - interval '12 days', '<p1@demo>');
  insert into meeting_handoffs (client_id, campaign_id, contact_id, reply_interaction_id, qualified, interest, product_fit, body, checks)
  values (cl, ca, priya, r, true, 'A call about contract chairs for the room refresh.', 'Contract chairs with commercial finish.', '# Priya Shah',
          '[{"key":"interest","status":"yes","evidence":"\"Can we talk next week?\""},{"key":"product_fit","status":"yes","evidence":"Contract chairs"}]')
  returning id into h;
  perform book_meeting(h, date_trunc('hour', now()) + interval '2 days 3 hours', 'Video call, link sent', 'yago@sbm-demo.example');

  -- Sofia: said not now; snoozed.
  insert into outreach_drafts (client_id, campaign_id, contact_id, channel, step, purpose, subject, body, status, sent_at, message_id)
  values (cl, ca, sofia, 'email', 1, 'first', 'Terrace chairs', 'Hi Sofia, ...', 'sent', now() - interval '20 days', '<s1@demo>');
  insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, subject, body, external_id, occurred_at)
  values (cl, ca, sofia, 'email', 'outbound', 'sent', 'bot', 'Terrace chairs', 'Hi Sofia, ...', '<s1@demo>', now() - interval '20 days');
  insert into interactions (client_id, campaign_id, contact_id, channel, direction, kind, actor, subject, body, external_id, occurred_at, metadata)
  values (cl, ca, sofia, 'email', 'inbound', 'reply', 'buyer', 'Re: Terrace chairs', 'Budget is set for this year. Try me in the new year.', '<s2@demo>',
          now() - interval '18 days', '{"category":"not_now","summary":"Budget set for this year; try again in the new year."}') returning id into r;
  perform apply_reply(r);
end $$;

alter table outreach_drafts enable trigger outreach_drafts_guard;
