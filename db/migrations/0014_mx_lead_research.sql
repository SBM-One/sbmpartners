-- 0014 · Mexican lead research fields (applied by hand on the live database on 2026-11-26, written down here on
-- 2026-11-28 so a rebuilt database matches production). Nothing new: same columns, checks, views and loader as live.
--   companies / contacts   lead score, collection (email_ready / linkedin_needed / whatsapp_phone / hold_drop),
--                          best channel, hold reason, DENUE size signals
--   mx_lead_board          one row per Mexican lead (person, or account with nobody named yet)
--   mx_lead_collections    counts per collection
--   load_mx_research(doc)  loads a research batch (companies + people + field sources). Owner only.

alter table companies add column if not exists segment          text;
alter table companies add column if not exists lead_score       int;
alter table companies add column if not exists score_rationale  text;
alter table companies add column if not exists lead_collection  text;
alter table companies add column if not exists best_channel     text;
alter table companies add column if not exists hold_reason      text;
alter table companies add column if not exists research_depth   text;
alter table companies add column if not exists denue_branches   int;
alter table companies add column if not exists denue_people_est int;
alter table companies add column if not exists denue_states     int;
alter table companies add column if not exists researched_at    timestamptz;

alter table contacts add column if not exists lead_score      int;
alter table contacts add column if not exists score_rationale text;
alter table contacts add column if not exists lead_collection text;
alter table contacts add column if not exists best_channel    text;
alter table contacts add column if not exists hold_reason     text;
alter table contacts add column if not exists research_notes  text;

-- Live has no country check on contacts (research loads used full names before they were normalised).
alter table contacts drop constraint if exists contacts_country_check;

alter table companies drop constraint if exists companies_best_channel_check;
alter table companies add constraint companies_best_channel_check
  check (best_channel = any (array['email','linkedin','whatsapp','phone','supplier_portal']));
alter table companies drop constraint if exists companies_lead_collection_check;
alter table companies add constraint companies_lead_collection_check
  check (lead_collection = any (array['email_ready','linkedin_needed','whatsapp_phone','hold_drop']));
alter table companies drop constraint if exists companies_lead_score_check;
alter table companies add constraint companies_lead_score_check check (lead_score >= 0 and lead_score <= 100);
alter table companies drop constraint if exists companies_research_depth_check;
alter table companies add constraint companies_research_depth_check
  check (research_depth = any (array['screened','researched','deep']));
alter table contacts drop constraint if exists contacts_best_channel_check;
alter table contacts add constraint contacts_best_channel_check
  check (best_channel = any (array['email','linkedin','whatsapp','phone','supplier_portal']));
alter table contacts drop constraint if exists contacts_lead_collection_check;
alter table contacts add constraint contacts_lead_collection_check
  check (lead_collection = any (array['email_ready','linkedin_needed','whatsapp_phone','hold_drop']));
alter table contacts drop constraint if exists contacts_lead_score_check;
alter table contacts add constraint contacts_lead_score_check check (lead_score >= 0 and lead_score <= 100);

create index if not exists companies_lead_idx on companies (country, lead_collection, lead_score desc);
create index if not exists contacts_lead_idx  on contacts (lead_collection, lead_score desc);

create or replace view mx_lead_board with (security_invoker = true) as
 select 'contact'::text as lead_kind,
    coalesce(ct.lead_collection, co.lead_collection) as collection,
    coalesce(ct.lead_score, co.lead_score) as score,
    coalesce(ct.best_channel, co.best_channel) as best_channel,
    co.name as company, co.segment,
    trim(both from (coalesce(ct.first_name, '') || ' ') || coalesce(ct.last_name, '')) as person,
    ct.title, ct.email, ct.email_status, ct.linkedin_url, ct.whatsapp, ct.phone,
    coalesce(ct.score_rationale, co.score_rationale) as rationale,
    coalesce(ct.hold_reason, co.hold_reason) as hold_reason,
    (select count(distinct fs.source) from field_sources fs
      where fs.entity = 'contact' and fs.entity_id = ct.id or fs.entity = 'company' and fs.entity_id = co.id) as sources,
    co.id as company_id, ct.id as contact_id
   from contacts ct join companies co on co.id = ct.company_id
  where co.country = 'MX' and ct.lead_collection is not null
union all
 select 'account'::text, co.lead_collection, co.lead_score, co.best_channel, co.name, co.segment,
    null::text, null::text, null::text, null::text, null::text, null::text, co.phone,
    co.score_rationale, co.hold_reason,
    (select count(distinct fs.source) from field_sources fs where fs.entity = 'company' and fs.entity_id = co.id),
    co.id, null::uuid
   from companies co
  where co.country = 'MX' and co.lead_collection is not null and not exists (
          select 1 from contacts ct where ct.company_id = co.id and ct.lead_collection is not null
             and (ct.lead_collection <> 'hold_drop' or co.lead_collection = 'hold_drop'));

create or replace view mx_lead_collections with (security_invoker = true) as
 select collection, count(*) as leads, count(*) filter (where lead_kind = 'contact') as named_people, round(avg(score)) as avg_score
   from mx_lead_board group by collection;

create or replace function load_mx_research(doc jsonb) returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare a jsonb; c jsonb; s jsonb; cid uuid; v_ct uuid; n_co int := 0; n_ct int := 0; n_fs int := 0;
begin
  for a in select * from jsonb_array_elements(doc) loop
    cid := null;
    if a->>'match_name' is not null then
      select id into cid from companies where name = a->>'match_name' limit 1;
    end if;
    if cid is null and nullif(a->>'domain','') is not null then
      select id into cid from companies where domain = a->>'domain' limit 1;
    end if;
    if cid is null then
      select id into cid from companies where name = a->>'name' limit 1;
    end if;
    if cid is null then
      insert into companies(name, domain, type, country, hq_city, hq_state, store_count, phone, website)
      values (a->>'name', nullif(a->>'domain',''), coalesce(a->>'type','retailer')::buyer_type, 'MX',
              a->>'hq_city', a->>'hq_state', (a->>'store_count')::int, a->>'phone', a->>'website')
      returning id into cid;
    end if;
    update companies set
      country = 'MX',
      segment = coalesce(a->>'segment', segment),
      hq_city = coalesce(a->>'hq_city', hq_city), hq_state = coalesce(a->>'hq_state', hq_state),
      store_count = coalesce((a->>'store_count')::int, store_count),
      phone = coalesce(a->>'phone', phone), website = coalesce(a->>'website', website),
      lead_score = (a->>'score')::int, score_rationale = a->>'rationale',
      lead_collection = a->>'collection', best_channel = a->>'channel', hold_reason = a->>'hold',
      research_depth = coalesce(a->>'depth','researched'), researched_at = now(), verified_at = now(),
      notes = case when a->>'notes' is null then notes else coalesce(notes || E'\n', '') || (a->>'notes') end,
      updated_at = now()
    where id = cid;
    n_co := n_co + 1;
    for s in select * from jsonb_array_elements(coalesce(a->'sources','[]'::jsonb)) loop
      insert into field_sources(entity, entity_id, field, value, source, confidence)
      values ('company', cid, s->>0, s->>1, s->>2, (s->>3)::real);
      n_fs := n_fs + 1;
    end loop;
    for c in select * from jsonb_array_elements(coalesce(a->'contacts','[]'::jsonb)) loop
      v_ct := null;
      select ct.id into v_ct from contacts ct
        where ct.company_id = cid and lower(coalesce(ct.first_name,'')) = lower(coalesce(c->>'fn',''))
          and lower(coalesce(ct.last_name,'')) = lower(coalesce(c->>'ln','')) limit 1;
      if v_ct is null and nullif(c->>'email','') is not null then
        select ct.id into v_ct from contacts ct where lower(ct.email) = lower(c->>'email') limit 1;
      end if;
      if v_ct is null then
        insert into contacts(company_id, first_name, last_name) values (cid, c->>'fn', c->>'ln') returning id into v_ct;
      end if;
      update contacts set
        company_id = cid, title = c->>'title', email = nullif(c->>'email',''),
        email_status = coalesce(c->>'email_status','unknown'), email_source = c->>'email_source',
        linkedin_url = nullif(c->>'li',''), phone = nullif(c->>'phone',''), whatsapp = nullif(c->>'wa',''),
        is_decision_maker = coalesce((c->>'dm')::boolean, false), country = 'MX',
        lead_score = (c->>'score')::int, score_rationale = c->>'rationale', lead_collection = c->>'collection',
        best_channel = c->>'channel', hold_reason = c->>'hold', research_notes = c->>'notes',
        verified_at = now(), updated_at = now()
      where id = v_ct;
      n_ct := n_ct + 1;
      for s in select * from jsonb_array_elements(coalesce(c->'sources','[]'::jsonb)) loop
        insert into field_sources(entity, entity_id, field, value, source, confidence)
        values ('contact', v_ct, s->>0, s->>1, s->>2, (s->>3)::real);
        n_fs := n_fs + 1;
      end loop;
    end loop;
  end loop;
  return jsonb_build_object('companies', n_co, 'contacts', n_ct, 'field_sources', n_fs);
end $function$;

revoke all on function load_mx_research(jsonb) from public, anon, authenticated;
revoke all on mx_lead_board, mx_lead_collections from anon, authenticated;
