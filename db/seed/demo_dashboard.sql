-- Made-up demo data for previewing the dashboards locally (owner control room and client portal).
-- Every name, email and number is invented. Never load this into the real Supabase project.
-- Load into an empty test database after the migrations:  psql -d sbm_test -f db/seed/demo_dashboard.sql

select setseed(0.42);

-- ─────────── people ───────────
insert into staff (name, email, role) values ('Yago', 'yago@sbm-demo.example', 'admin');

insert into clients (id, name, industry, plan, status, founding_partner, daily_draft_limit, brief) values
  ('d0000000-0000-0000-0000-0000000000c1', 'Harbourline Furniture', 'furniture', 'growth',   'active', true,  25, '{"brand":"Harbourline"}'),
  ('d0000000-0000-0000-0000-0000000000c2', 'Atelier Verre Lighting', 'lighting', 'outbound', 'active', false, 15, '{"brand":"Atelier Verre"}'),
  ('d0000000-0000-0000-0000-0000000000c3', 'Coastal Tile Works',    'tile',      'sprint',   'active', false, 10, '{}');

insert into client_users (client_id, email, name) values
  ('d0000000-0000-0000-0000-0000000000c1', 'claire@harbourline-demo.example', 'Claire Whitman'),
  ('d0000000-0000-0000-0000-0000000000c2', 'luc@atelierverre-demo.example', 'Luc Morel');

-- ─────────── agents and what they cost this month ───────────
insert into agents (id, name, role, model, monthly_budget_cents) values
  ('d0000000-0000-0000-0000-0000000000a1', 'supervisor',          'supervisor',          'rules',             0),
  ('d0000000-0000-0000-0000-0000000000a2', 'prospect-researcher', 'prospect_researcher', 'claude-sonnet-5-5', 8000),
  ('d0000000-0000-0000-0000-0000000000a3', 'writer',              'writer',              'claude-opus-5-5',   10000),
  ('d0000000-0000-0000-0000-0000000000a4', 'grader',              'grader',              'claude-haiku-5-5',  10000),
  ('d0000000-0000-0000-0000-0000000000a5', 'reporter',            'reporter',            'claude-sonnet-5-5', 3000);

insert into agent_runs (agent_id, started_at, finished_at, status, cost_cents)
select a.id, date_trunc('month', now()) + (random() * (now() - date_trunc('month', now()))), now(), 'ok',
       case a.name when 'writer' then 120 + random() * 160 when 'prospect-researcher' then 80 + random() * 90
                   when 'grader' then 10 + random() * 15 else 30 + random() * 40 end
from agents a cross join generate_series(1, 30) g
where a.name <> 'supervisor';

-- ─────────── the buyers ───────────
insert into companies (id, name, domain, type, hq_city, hq_state, store_count) values
  ('d0000000-0000-0000-0000-0000000000b1', 'Oakline Home',            'oakline-demo.example',    'retailer',    'Charlotte',   'NC', 14),
  ('d0000000-0000-0000-0000-0000000000b2', 'Studio Marrow Interiors', 'marrow-demo.example',     'design_firm', 'Atlanta',     'GA', null),
  ('d0000000-0000-0000-0000-0000000000b3', 'Harbor Hotel Group',      'harborhg-demo.example',   'hospitality', 'Savannah',    'GA', 22),
  ('d0000000-0000-0000-0000-0000000000b4', 'Bellweather Living',      'bellweather-demo.example','retailer',    'Nashville',   'TN', 6),
  ('d0000000-0000-0000-0000-0000000000b5', 'Coastline Builders',      'coastline-demo.example',  'builder',     'Charleston',  'SC', null),
  ('d0000000-0000-0000-0000-0000000000b6', 'Meridian Design House',   'meridian-demo.example',   'design_firm', 'Miami',       'FL', null),
  ('d0000000-0000-0000-0000-0000000000b7', 'Willow & Pine',           'willowpine-demo.example', 'retailer',    'Raleigh',     'NC', 4),
  ('d0000000-0000-0000-0000-0000000000b8', 'Palmetto Resorts',        'palmetto-demo.example',   'hospitality', 'Hilton Head', 'SC', 9),
  ('d0000000-0000-0000-0000-0000000000b9', 'Granite Peak Homes',      'granite-demo.example',    'builder',     'Asheville',   'NC', null),
  ('d0000000-0000-0000-0000-0000000000ba', 'Lumen & Co.',             'lumen-demo.example',      'retailer',    'Austin',      'TX', 8),
  ('d0000000-0000-0000-0000-0000000000bb', 'The Cordova',             'cordova-demo.example',    'hospitality', 'Tampa',       'FL', 3),
  ('d0000000-0000-0000-0000-0000000000bc', 'Northgate Contract',      'northgate-demo.example',  'contract',    'Dallas',      'TX', null);

insert into contacts (id, company_id, first_name, last_name, title, email)
select ('d0000000-0000-0000-0000-0000000001' || substr(id::text, 35, 2))::uuid, id,
       (array['Jenna','Marcus','Priya','Tom','Elena','Grace','Owen','Sofia','Daniel','Maya','Leo','Hannah'])[row_number() over (order by id)],
       (array['Park','Lee','Shah','Reyes','Brooks','Kim','Hart','Diaz','Cole','Ford','Grant','Wells'])[row_number() over (order by id)],
       (array['Head buyer','Principal','Director of purchasing','Owner','Purchasing manager','Principal designer',
              'Owner','VP, FF&E','Purchasing lead','Merchandise director','Procurement manager','Project director'])[row_number() over (order by id)],
       'purchasing@' || domain
from companies;

insert into campaigns (id, client_id, name, channels, buyer_types, status) values
  ('d0000000-0000-0000-0000-0000000000e1', 'd0000000-0000-0000-0000-0000000000c1', 'Southeast retailers and designers', '{email,call,linkedin}', '{retailer,design_firm}', 'live'),
  ('d0000000-0000-0000-0000-0000000000e2', 'd0000000-0000-0000-0000-0000000000c1', 'Hospitality FF&E', '{email,linkedin}', '{hospitality}', 'live'),
  ('d0000000-0000-0000-0000-0000000000e3', 'd0000000-0000-0000-0000-0000000000c2', 'Lighting for builders', '{email}', '{builder,contract}', 'live');

-- ─────────── ten weeks of activity, growing week by week ───────────
-- client 1 gets most of it; the volume ramps up so the charts have a story
insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, agent_id, subject, occurred_at, value_cents)
select c.client_id, c.campaign_id, co.id,
       ('d0000000-0000-0000-0000-0000000001' || substr(co.id::text, 35, 2))::uuid,
       k.channel::channel, k.direction::direction, k.kind::interaction_kind, k.actor::actor,
       case when k.actor = 'bot' then 'd0000000-0000-0000-0000-0000000000a3'::uuid end,
       case when k.kind = 'sent' then (array['A coastal line for your spring floor','Performance fabrics for hotel projects',
            'Samples for your next install','Lead times that fit your season'])[1 + floor(random() * 4)::int] end,
       now() - (w * interval '7 days') - (random() * interval '6 days'),
       case when k.kind in ('order','reorder') then (6000 + floor(random() * 22000))::bigint * 100 end
from (values ('d0000000-0000-0000-0000-0000000000c1'::uuid, 'd0000000-0000-0000-0000-0000000000e1'::uuid, 1.0),
             ('d0000000-0000-0000-0000-0000000000c2'::uuid, 'd0000000-0000-0000-0000-0000000000e3'::uuid, 0.45)) as c(client_id, campaign_id, scale)
cross join generate_series(0, 9) w
cross join lateral (values
    ('email','outbound','sent','bot',          38), ('call','outbound','call','staff',       6),
    ('email','inbound','reply','buyer',         5), ('meeting','inbound','meeting_booked','staff', 2),
    ('other','outbound','sample_sent','staff',  1), ('other','outbound','quote_sent','staff',  1),
    ('email','inbound','order','buyer',         1)) as k(channel, direction, kind, actor, per_week)
cross join lateral generate_series(1, greatest(0, round(k.per_week * c.scale * (1.6 - w * 0.11) * (0.75 + random() * 0.5))::int)) n
cross join lateral (select id from companies order by md5(id::text || w || n || k.kind) limit 1) co
where not (k.kind = 'order' and w > 6);

-- ─────────── deals: where each buyer stands ───────────
insert into deals (client_id, company_id, stage, value_cents, opened_at, closed_at) values
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000b1', 'repeat',       4120000, now() - interval '62 days', null),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000b3', 'first_order',  2860000, now() - interval '41 days', null),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000b2', 'quote',        1450000, now() - interval '33 days', null),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000b8', 'quote',        3900000, now() - interval '21 days', null),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000b4', 'sample',        880000, now() - interval '18 days', null),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000b6', 'sample',       1200000, now() - interval '12 days', null),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000b7', 'conversation',  null,   now() - interval '9 days',  null),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000b5', 'conversation',  null,   now() - interval '6 days',  null),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000bb', 'conversation',  null,   now() - interval '3 days',  null),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000b9', 'lost',          null,   now() - interval '50 days', now() - interval '20 days'),
  ('d0000000-0000-0000-0000-0000000000c2', 'd0000000-0000-0000-0000-0000000000b9', 'quote',        2200000, now() - interval '20 days', null),
  ('d0000000-0000-0000-0000-0000000000c2', 'd0000000-0000-0000-0000-0000000000bc', 'sample',        640000, now() - interval '11 days', null),
  ('d0000000-0000-0000-0000-0000000000c2', 'd0000000-0000-0000-0000-0000000000ba', 'conversation',  null,   now() - interval '4 days',  null);

-- ─────────── the approval queue ───────────
insert into outreach_drafts (client_id, campaign_id, contact_id, company_id, writer_agent_id, channel, step, subject, body, score, grade_feedback, rewrites, research, playbook_used, created_at) values
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000e1', 'd0000000-0000-0000-0000-0000000001b7', 'd0000000-0000-0000-0000-0000000000b7',
   'd0000000-0000-0000-0000-0000000000a3', 'email', 1, 'Performance linen for your Raleigh floor',
   E'Hi Owen,\n\nI noticed Willow & Pine just opened a fourth store in Durham, and that most of your upholstery is in natural linen.\n\nHarbourline makes performance linen sofas in North Carolina with a six-week lead time, so you can reorder mid-season without carrying deep stock.\n\nWould a swatch box be useful before your spring buy? I can have one at the Raleigh store this week.\n\nBest,\nClaire',
   88, 'Specific and short. The swatch-box offer is an easy next step. Consider naming one bestseller.', 0,
   '{"summary":"Four-store home retailer in the Triangle; opened Durham in September; leans coastal and natural fibres.","fit":5,"angle":"Short lead times for mid-season reorders","facts":[{"fact":"Opened a fourth store in Durham in September","source_url":"https://willowpine-demo.example/news"},{"fact":"About 60% of upholstery on the site is linen or linen blend","source_url":"https://willowpine-demo.example/shop"}],"cautions":"Owner buys directly; keep it personal, no deck."}',
   '["Lead with lead time","Offer a swatch box"]', now() - interval '3 hours'),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000e2', 'd0000000-0000-0000-0000-0000000001bb', 'd0000000-0000-0000-0000-0000000000bb',
   'd0000000-0000-0000-0000-0000000000a3', 'email', 1, 'Lobby seating for The Cordova renovation',
   E'Hi Leo,\n\nCongratulations on the Cordova renovation approval. Lobby and guest-room seating is what we do for boutique hotels across the Southeast.\n\nOur contract-grade frames carry a ten-year warranty and ship in eight weeks.\n\nWould a 15-minute call next week help you scope the FF&E package?\n\nBest,\nClaire',
   81, 'Good timing hook. "What we do" is a little generic; name a comparable hotel project.', 1,
   '{"summary":"Three-property boutique group in Tampa; renovation of the flagship approved by the city in October.","fit":4,"angle":"Renovation timing","facts":[{"fact":"Renovation permit approved October 2026","source_url":"https://cordova-demo.example/press"}]}',
   '["Use a timing trigger"]', now() - interval '5 hours'),
  ('d0000000-0000-0000-0000-0000000000c2', 'd0000000-0000-0000-0000-0000000000e3', 'd0000000-0000-0000-0000-0000000001ba', 'd0000000-0000-0000-0000-0000000000ba',
   'd0000000-0000-0000-0000-0000000000a3', 'email', 2, 'Re: Hand-blown pendants for Lumen & Co.',
   E'Hi Maya,\n\nFollowing up on the pendants. We can hold three samples for your Austin showroom until Friday.\n\nShould I send them over?\n\nLuc',
   72, 'Fine as a follow-up but the deadline reads as pressure. Remove "until Friday".', 0,
   '{"summary":"Eight-store lighting and decor retailer in Texas.","fit":3}', '[]', now() - interval '1 day');

insert into outreach_drafts (client_id, contact_id, company_id, channel, subject, body, score, status, reviewed_by, reviewed_at, review_note, created_at) values
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000001b4', 'd0000000-0000-0000-0000-0000000000b4', 'email', 'Swatches for Bellweather', 'Hi Tom, ...', 90, 'approved', 'yago@sbm-demo.example', now() - interval '1 day', null, now() - interval '2 days'),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000001b6', 'd0000000-0000-0000-0000-0000000000b6', 'email', 'Linen for Meridian projects', 'Hi Grace, ...', 64, 'rejected', 'yago@sbm-demo.example', now() - interval '2 days', 'Too long, and the warranty claim needs checking.', now() - interval '3 days'),
  ('d0000000-0000-0000-0000-0000000000c2', 'd0000000-0000-0000-0000-0000000001bc', 'd0000000-0000-0000-0000-0000000000bc', 'email', 'Lighting for Northgate projects', 'Hi Hannah, ...', 84, 'approved', 'yago@sbm-demo.example', now() - interval '3 days', null, now() - interval '4 days');

-- ─────────── the team's to-do list, last 7 days ───────────
insert into tasks (kind, status, client_id, created_at, finished_at)
select k, s, 'd0000000-0000-0000-0000-0000000000c1', now() - random() * interval '6 days',
       case when s in ('done','failed') then now() - random() * interval '6 days' end
from (values ('research_prospect','done',46), ('research_prospect','queued',8), ('research_prospect','running',2),
             ('draft_outreach','done',41), ('draft_outreach','queued',5), ('draft_outreach','failed',1),
             ('write_report','done',3)) as t(k, s0, n)
cross join lateral generate_series(1, t.n) g
cross join lateral (select t.s0::task_status as s) x;

-- ─────────── alerts ───────────
insert into alerts (client_id, severity, kind, message, notify_client, created_at) values
  ('d0000000-0000-0000-0000-0000000000c1', 'urgent',  'hot_lead',         'Harbor Hotel Group asked for a quote on 22 properties. Call within the hour.', false, now() - interval '40 minutes'),
  (null,                                   'warning', 'budget',           'The Writer has used 82% of its monthly budget with 17 days left.', false, now() - interval '6 hours'),
  ('d0000000-0000-0000-0000-0000000000c3', 'warning', 'missing_brief',    'Coastal Tile Works has no fact sheet, so the Writer can''t draft for them.', false, now() - interval '1 day'),
  ('d0000000-0000-0000-0000-0000000000c1', 'info',    'meeting_booked',   'Meeting booked with Palmetto Resorts, Tuesday 10:00.', true, now() - interval '2 days'),
  ('d0000000-0000-0000-0000-0000000000c1', 'info',    'order',            'Oakline Home placed a reorder of $41,200.', true, now() - interval '4 days');

-- ─────────── reports ───────────
insert into reports (client_id, kind, period_start, period_end, data, summary, body, status, approved_at, created_at)
select 'd0000000-0000-0000-0000-0000000000c1', 'weekly', (date_trunc('week', now()) - (w * interval '7 days'))::date,
       (date_trunc('week', now()) - (w * interval '7 days') + interval '6 days')::date, '{}',
       (array['Two new hospitality conversations and a reorder from Oakline Home.',
              'Harbor Hotel Group moved to first order; three samples out.',
              'Strong reply week: 7 replies from 41 messages.'])[w],
       (array[E'This week in brief\n\nWe reached 41 buyers across retail, design and hospitality. Seven replied and two booked meetings: Palmetto Resorts (Tuesday) and The Cordova (Thursday).\n\nOakline Home reordered $41,200 of the coastal collection, their third order since August.\n\nNext week\n\nWe will follow up on the three swatch boxes sent to Willow & Pine, Meridian and Bellweather, and prepare the Palmetto quote for your review.',
              E'This week in brief\n\nHarbor Hotel Group confirmed a first order for lobby seating across four properties ($28,600). Samples went to three design firms.\n\nNext week\n\nWe start the hospitality sequence for coastal Carolina resorts.',
              E'This week in brief\n\nSeven of forty-one buyers replied, the best rate so far. Two asked for line sheets.'])[w],
       'approved', now() - (w * interval '7 days') + interval '1 day', now() - (w * interval '7 days')
from generate_series(1, 3) w;

insert into reports (client_id, kind, period_start, period_end, data, summary, body, status, created_at) values
  ('d0000000-0000-0000-0000-0000000000c1', 'weekly', date_trunc('week', now())::date, (date_trunc('week', now()) + interval '6 days')::date, '{}',
   'Quote requested by Harbor Hotel Group for 22 properties.',
   E'This week in brief\n\nHarbor Hotel Group asked for a quote covering all 22 properties. We sent swatches to Willow & Pine and booked two calls.\n\nNext week\n\nQuote review with you on Monday.', 'draft', now() - interval '2 hours'),
  ('d0000000-0000-0000-0000-0000000000c2', 'weekly', date_trunc('week', now())::date, (date_trunc('week', now()) + interval '6 days')::date, '{}',
   'Northgate Contract requested samples.', E'This week in brief\n\nNorthgate Contract asked for three pendant samples.', 'draft', now() - interval '3 hours');

-- ─────────── playbook ───────────
insert into playbook_entries (title, body, channel, buyer_types, status, evidence) values
  ('Lead with lead time', 'Independent retailers reorder mid-season. Name the lead time in the first two lines.', 'email', '{retailer}', 'active', '{"evidence_strength":"strong"}'),
  ('Offer a swatch box', 'Designers say yes to a physical sample far more often than to a call.', 'email', '{design_firm}', 'active', '{"evidence_strength":"moderate"}'),
  ('Use a timing trigger', 'Open with a renovation, opening or expansion the buyer announced in the last 90 days.', null, '{hospitality,retailer}', 'draft', '{"evidence_strength":"moderate"}'),
  ('Call after the second email', 'A short call two days after the second email doubles reply rates for builders.', 'call', '{builder}', 'draft', '{"evidence_strength":"weak"}');
