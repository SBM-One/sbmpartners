-- Made-up demo data for previewing the sending screens locally. Load after demo_dashboard.sql.
-- Every name, email and address is invented. Never load this into the real Supabase project.

-- Harbourline is fully set up; Atelier Verre has a fact sheet drafted from its catalog, waiting for approval.
update clients set brief_approved_at = now() - interval '5 days', brief_approved_by = 'yago@sbm-demo.example',
       sender_name = 'Ana Ruiz', sender_company = 'SBM Partners for Harbourline Furniture',
       postal_address = 'Calle de Serrano 41, 28001 Madrid, Spain'
 where name = 'Harbourline Furniture';
update clients set brief_approved_at = null, brief_source = 'atelier-verre-catalog-2026.pdf, atelierverre-demo.example',
       brief_draft = '{"brand":"Atelier Verre","what_they_make":"Hand-blown glass pendants and wall lights, made in a 12-person studio near Lyon.","collections":["Sillage: ribbed glass pendants in 3 sizes","Brume: frosted wall lights, IP44 for bathrooms"],"price_points":"Wholesale from EUR 180 (Sillage small) to EUR 640 (Sillage large). Retail about 2.3x.","terms":"","trade_and_contract":"UL and CE listed. Spec sheets on request.","proof":"Stocked by 22 lighting shops in France and Belgium (catalog, p. 2).","offer":"","best_fit_buyers":"Lighting shops and interior designers doing residential and boutique hotel work.","sources_used":["atelier-verre-catalog-2026.pdf","atelierverre-demo.example/about"],"questions_for_client":["What is the opening-order minimum?","Lead time for each collection?","Do you ship to the UK and the US, and who pays freight?","Is there a sample or display offer for new stockists?"]}'
 where name = 'Atelier Verre Lighting';

update email_country_rules set confirmed_at = now() - interval '2 days', confirmed_by = 'yago@sbm-demo.example'
 where country in ('US','GB','FR');
update contacts set email_source = 'their website, wholesale page', email_basis = 'legitimate_interest', country = 'US';
update contacts set linkedin_url = 'https://www.linkedin.com/in/demo-' || lower(first_name) where linkedin_url is null;
update campaigns set channels = '{email,linkedin}';

insert into mailboxes (address, display_name, daily_cap, timezone)
values ('ana@harbourline-sbm-demo.example', 'Ana Ruiz', 15, 'Europe/Madrid') on conflict do nothing;

-- One buyer in Germany without recorded consent: its draft shows what the safety gate asks for.
insert into companies (id, name, domain, type, country, hq_city)
values ('c0000000-0000-0000-0000-0000000000d1', 'Wohnhaus Berlin', 'wohnhaus-demo.example', 'retailer', 'DE', 'Berlin');
insert into contacts (id, company_id, first_name, last_name, title, email, email_source, email_basis, country)
values ('c1000000-0000-0000-0000-0000000000d1', 'c0000000-0000-0000-0000-0000000000d1', 'Lena', 'Vogt', 'Head of buying',
        'lena@wohnhaus-demo.example', 'trade fair card, imm cologne', 'legitimate_interest', 'DE');
insert into outreach_drafts (client_id, campaign_id, contact_id, company_id, channel, subject, body, score, grade_feedback, created_at)
select cl.id, 'd0000000-0000-0000-0000-0000000000e1', 'c1000000-0000-0000-0000-0000000000d1', 'c0000000-0000-0000-0000-0000000000d1',
       'email', 'Oak for Wohnhaus', 'Hi Lena, we met briefly at imm cologne. Harbourline makes solid oak dining tables in Portugal…',
       84, 'Specific and short.', now() - interval '3 hours'
  from clients cl where cl.name = 'Harbourline Furniture';

-- LinkedIn notes approved and waiting to be sent by hand.
insert into outreach_drafts (client_id, campaign_id, contact_id, company_id, channel, body, status, reviewed_by, created_at)
select d.client_id, d.campaign_id, d.contact_id, d.company_id, 'linkedin',
       'Hi ' || c.first_name || ', I saw ' || coalesce(co.name, 'your shop') || ' just opened a second floor for dining. I work with a family oak workshop in Portugal and would be glad to connect.',
       'pending_review', null, now() - interval '1 day'
  from outreach_drafts d join contacts c on c.id = d.contact_id left join companies co on co.id = d.company_id
 where d.status = 'pending_review' and d.channel = 'email' and c.country = 'US'
   and d.client_id = (select id from clients where name = 'Harbourline Furniture')
 limit 2;
update outreach_drafts set status = 'approved', reviewed_by = 'yago@sbm-demo.example' where channel = 'linkedin' and status = 'pending_review';

-- Emails already sent, with what came back.
do $$
declare d record; mb uuid; n int := 0; mid text;
begin
  select id into mb from mailboxes limit 1;
  for d in select x.* from outreach_drafts x where x.status = 'approved' and x.channel = 'email'
             and x.client_id = (select id from clients where name = 'Harbourline Furniture') order by x.created_at loop
    n := n + 1;
    mid := '<demo-' || n || '@harbourline-sbm-demo.example>';
    update outreach_drafts set status = 'sent', mailbox_id = mb, send_claimed_at = now() - make_interval(hours => n * 5),
           sent_at = now() - make_interval(hours => n * 5), message_id = mid where id = d.id;
    insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, subject, external_id, occurred_at)
    values (d.client_id, d.campaign_id, d.company_id, d.contact_id, 'email', 'outbound', 'sent', 'bot', d.subject, mid, now() - make_interval(hours => n * 5));
    if n = 1 then
      insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, body, external_id, metadata)
      values (d.client_id, d.campaign_id, d.company_id, d.contact_id, 'email', 'inbound', 'reply', 'buyer', 'Yes, please send the price list.',
              '<demo-reply-1@buyer>', '{"category":"interested","summary":"Wants the wholesale price list and lead times."}');
    end if;
  end loop;
end $$;
