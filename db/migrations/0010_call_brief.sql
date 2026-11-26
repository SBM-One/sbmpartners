-- SBM Partners · step 10: the call brief.
--
-- When a buyer books a call, the phone app opens one page with everything needed for it:
--   1. the buyer: company, stores, the person, their lead notes and our strategy for them,
--   2. what we already sent them and what they answered, oldest first, plus the meeting brief if there is one,
--   3. the client's call kit: cheat sheet, answers to hard objections and a call script.
--
--   call_kits          one kit per client (jsonb, see db/seed/call_kit_santa_fe_rusticos.sql for the shape)
--   phone_brief(id)    the whole brief for one contact
--   phone_find(text)   look a buyer up by person or company name, to open a brief for a call booked off-app
--   phone_inbox()      as in 0009, now with each reply's and meeting's contact id so the app can link to the brief
--
-- Like every phone_* function, each one first checks the staff list. Kits hold the client's prices and terms, so
-- the table has row-level security on and no policies: only these functions read it. Needs 0001 to 0009.
-- Safe to run more than once.

create table if not exists call_kits (
  client_id  uuid primary key references clients(id) on delete cascade,
  kit        jsonb not null default '{}',     -- {title, updated, rules[], facts[{heading, items[[label, text]]}],
                                              --  objections[{q, a, proof}], script[{stage, goal, lines[]}], pending[]}
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table call_kits enable row level security;
revoke all on call_kits from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke all on call_kits from anon, authenticated; end if;
end $$;

-- ─────────────────────────── one buyer's brief ───────────────────────────
create or replace function phone_brief(p_contact uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me staff := phone_staff();
  c contacts;
  co companies;
  cid uuid;
begin
  select * into c from contacts where id = p_contact;
  if c.id is null then raise exception 'No buyer with that id.'; end if;
  select * into co from companies where id = c.company_id;

  -- Which client this buyer is being worked for: the latest meeting, strategy, draft or interaction says so.
  cid := coalesce(
    (select client_id from meeting_handoffs where contact_id = c.id order by created_at desc limit 1),
    (select client_id from prospect_strategies where contact_id = c.id order by decided_at desc limit 1),
    (select client_id from outreach_drafts where contact_id = c.id order by created_at desc limit 1),
    (select client_id from interactions where contact_id = c.id and client_id is not null order by occurred_at desc limit 1),
    (select client_id from call_kits order by updated_at desc limit 1));

  return jsonb_build_object(
    'client', (select name from clients where id = cid),
    -- Everything we hold on the company and the person, whatever columns this database has; minus the bulky or secret.
    'company', case when co.id is null then null else to_jsonb(co) - 'embedding' end,
    'contact', to_jsonb(c) - 'unsubscribe_token',
    'locations', coalesce((select jsonb_agg(jsonb_build_object('label', l.label, 'city', l.city, 'state', l.state) order by l.state, l.city)
                           from locations l where l.company_id = co.id), '[]'),
    'colleagues', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', nullif(trim(coalesce(o.first_name, '') || ' ' || coalesce(o.last_name, '')), ''),
                                                             'title', o.title, 'email', o.email, 'phone', o.phone) order by o.is_decision_maker desc, o.created_at)
                            from contacts o where o.company_id = co.id and o.id <> c.id and not o.do_not_contact), '[]'),
    'strategy', (select jsonb_build_object('fit_score', s.fit_score, 'decision', s.decision, 'reason', s.reason, 'pitch_angle', s.pitch_angle,
                                           'lead_with', s.lead_with, 'proof_points', s.proof_points, 'offer', s.offer,
                                           'objections', s.objections, 'first_ask', s.first_ask)
                 from prospect_strategies s where s.contact_id = c.id order by s.decided_at desc limit 1),
    'meeting', (select jsonb_build_object('status', h.status, 'meeting_at', h.meeting_at, 'meeting_note', h.meeting_note,
                                          'interest', h.interest, 'product_fit', h.product_fit, 'open_questions', h.open_questions,
                                          'next_steps', h.next_steps, 'agenda', h.agenda, 'body', h.body)
                from meeting_handoffs h where h.contact_id = c.id order by h.created_at desc limit 1),
    -- Every message both ways with this person, and anything logged against the company without a person.
    'history', coalesce((select jsonb_agg(x order by x.at) from (
        select i.occurred_at as at, i.channel::text as channel, i.direction::text as direction, i.kind::text as kind,
               i.subject, left(i.body, 2000) as body, i.metadata ->> 'summary' as summary, i.metadata ->> 'category' as category
        from interactions i
        where i.contact_id = c.id or (co.id is not null and i.company_id = co.id and i.contact_id is null)
        order by i.occurred_at desc limit 60) x), '[]'),
    'waiting', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', phone_kind(d), 'status', d.status, 'subject', d.subject,
                                                          'body', d.body, 'created_at', d.created_at) order by d.created_at)
                         from outreach_drafts d where d.contact_id = c.id and d.status in ('pending_review','approved')), '[]'),
    'kit', (select kit from call_kits where client_id = cid)
  );
end $$;

-- ─────────────────────────── find a buyer ───────────────────────────
create or replace function phone_find(p_q text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me staff := phone_staff(); q text := '%' || trim(coalesce(p_q, '')) || '%';
begin
  if length(trim(coalesce(p_q, ''))) < 2 then return '[]'; end if;
  return coalesce((select jsonb_agg(r) from (
    select c.id, nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as contact, c.title,
           co.name as company, co.hq_city as city,
           exists (select 1 from meeting_handoffs h where h.contact_id = c.id and h.status in ('ready','booked')) as meeting
    from contacts c left join companies co on co.id = c.company_id
    where (coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) ilike q or co.name ilike q or c.email ilike q
    order by 6 desc, co.name, c.last_name
    limit 15) r), '[]');
end $$;

-- ─────────────────────────── Replies & meetings, with contact ids ───────────────────────────
create or replace function phone_inbox() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me staff := phone_staff();
begin
  return jsonb_build_object(
    'replies', coalesce((select jsonb_agg(r) from (
      select i.id, i.contact_id, i.channel::text as channel, i.occurred_at, i.subject, left(i.body, 600) as body,
             i.metadata ->> 'category' as category, i.metadata ->> 'summary' as summary, cl.name as client,
             nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as contact, co.name as company,
             exists (select 1 from outreach_drafts o where o.contact_id = i.contact_id and o.status = 'pending_review'
                     and o.purpose = 'reply') as answer_waiting
      from interactions i
      left join contacts c on c.id = i.contact_id
      left join companies co on co.id = coalesce(i.company_id, c.company_id)
      left join clients cl on cl.id = i.client_id
      where i.direction = 'inbound' and i.kind = 'reply' and i.occurred_at > now() - interval '30 days'
      order by i.occurred_at desc limit 30) r), '[]'),
    'meetings', coalesce((select jsonb_agg(m) from (
      select id, contact_id, status, meeting_at, meeting_note, client, contact, contact_title, company, email, phone, linkedin_url,
             qualified, interest, product_fit, next_steps, body, created_at
      from v_meetings where status in ('ready','booked')
      order by status = 'ready' desc, meeting_at nulls last, created_at desc limit 20) m), '[]'));
end $$;

do $$
declare f text;
begin
  foreach f in array array['phone_brief(uuid)', 'phone_find(text)', 'phone_inbox()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
