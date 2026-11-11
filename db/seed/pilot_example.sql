-- Illustrative pilot data to test the schema and dashboards. Names and numbers are made up.
insert into clients (id, name, industry, plan, founding_partner)
values ('00000000-0000-0000-0000-0000000000c1', 'Pilot Furniture Co.', 'furniture', 'growth', true);

insert into agents (id, name, role, model) values
  ('00000000-0000-0000-0000-0000000000a1', 'writer-email', 'writer', 'claude-opus-5-5'),
  ('00000000-0000-0000-0000-0000000000a2', 'grader', 'grader', 'claude-haiku-5-5'),
  ('00000000-0000-0000-0000-0000000000a3', 'supervisor', 'supervisor', 'claude-opus-5-5');

insert into companies (id, name, domain, type, categories, style_tags, price_tier, store_count, hq_city, hq_state) values
  ('00000000-0000-0000-0000-0000000000b1', 'Oakline Home', 'oaklinehome.example', 'retailer', '{upholstery,case_goods}', '{coastal}', 'upper', 14, 'Charlotte', 'NC'),
  ('00000000-0000-0000-0000-0000000000b2', 'Studio Marrow', 'studiomarrow.example', 'design_firm', '{upholstery}', '{modern}', 'luxury', null, 'Atlanta', 'GA');

insert into contacts (id, company_id, first_name, last_name, title, email, is_decision_maker) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000b1', 'Jenna', 'Park', 'Buyer', 'jenna@oaklinehome.example', true),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000b2', 'Marcus', 'Lee', 'Principal', 'marcus@studiomarrow.example', true);

insert into campaigns (id, client_id, name, channels, buyer_types, status) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000c1', 'Spring · Southeast retailers', '{email,call,linkedin}', '{retailer,design_firm}', 'live');

insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, agent_id, subject, occurred_at, value_cents) values
  ('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d1','email','outbound','sent','bot','00000000-0000-0000-0000-0000000000a1','A coastal line for your spring floor', now() - interval '6 days', null),
  ('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d1','email','inbound','reply','buyer',null,'Re: A coastal line for your spring floor', now() - interval '6 days' + interval '3 hours', null),
  ('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d1','meeting','inbound','meeting_booked','staff',null,'Intro call', now() - interval '5 days', null),
  ('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-0000000000d2','email','outbound','sent','bot','00000000-0000-0000-0000-0000000000a1','Performance fabrics for hotel projects', now() - interval '4 days', null),
  ('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d1','email','inbound','order','buyer',null,'First order', now() - interval '1 day', 1840000);

insert into rubrics (id, name, criteria) values
  ('00000000-0000-0000-0000-0000000000f1', 'outreach_email', '[
    {"key":"relevance","description":"Clearly fits this buyer''s store, style and customers","weight":0.25},
    {"key":"personalization","description":"Uses real specifics about the buyer, not filler","weight":0.2},
    {"key":"clarity","description":"Short, plain, one idea","weight":0.15},
    {"key":"value","description":"States a concrete reason to care (lead time, margin, fit)","weight":0.15},
    {"key":"next_step","description":"One easy, low-pressure next step","weight":0.15},
    {"key":"honesty","description":"No fake urgency, no false claims, compliant","weight":0.1}]');

insert into grades (subject, subject_id, rubric_id, grader_agent_id, score, feedback)
select 'interaction', i.id, '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a2', 86, 'Specific and short; next step could be easier.'
from interactions i where i.kind = 'sent' limit 1;

insert into alerts (client_id, severity, kind, message, notify_client) values
  ('00000000-0000-0000-0000-0000000000c1', 'urgent', 'hot_lead', 'Oakline Home placed a first order. Schedule the reorder check-in.', true);
