-- SBM Partners · client portal
-- Two read-only views the client portal uses to show a client its own pipeline and activity.
--
-- Why views: a client should see the names of the buyers we are talking to on their behalf, but the buyer
-- network itself (companies, contacts) stays internal. These views expose only a few safe columns
-- (company name, buyer type, city, contact job title; never emails, phone numbers or message bodies), and
-- only for the logged-in client's own rows.
--
-- How the privacy works: the views read the internal tables with the owner's rights, then filter rows
-- themselves. A portal login (role "authenticated") only gets rows where client_id is one of its own
-- clients (my_client_ids(), from 0002). The public anon key can't read them at all. Staff and backend jobs
-- (the database owner / service role) see every client, the same as they do for every other table.
-- The dashboard also adds "where client_id = <this client>" to every portal query, so there are two locks.

create or replace view v_portal_pipeline as
select d.id,
       d.client_id,
       co.name                     as company,
       co.type::text               as buyer_type,
       co.hq_city                  as city,
       co.hq_state                 as state,
       d.stage::text               as stage,
       d.value_cents,
       d.opened_at,
       d.closed_at,
       d.updated_at,
       (select max(i.occurred_at) from interactions i
         where i.client_id = d.client_id and i.company_id = d.company_id) as last_activity
from deals d
left join companies co on co.id = d.company_id
where current_user not in ('anon', 'authenticated')
   or d.client_id in (select my_client_ids());

create or replace view v_portal_activity as
select i.id,
       i.client_id,
       i.campaign_id,
       i.occurred_at,
       i.kind::text                as kind,
       i.channel::text             as channel,
       i.direction::text           as direction,
       co.name                     as company,
       co.type::text               as buyer_type,
       co.hq_city                  as city,
       co.hq_state                 as state,
       c.title                     as contact_title,
       case when i.direction = 'outbound' then i.subject end as subject,   -- our own subject lines only
       i.value_cents
from interactions i
left join companies co on co.id = i.company_id
left join contacts  c  on c.id  = i.contact_id
where i.kind not in ('note')
  and (current_user not in ('anon', 'authenticated')
       or i.client_id in (select my_client_ids()));

revoke all on v_portal_pipeline, v_portal_activity from public, anon;
grant select on v_portal_pipeline, v_portal_activity to authenticated;
