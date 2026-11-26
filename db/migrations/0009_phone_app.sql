-- SBM Partners · step 9: the phone app.
--
-- The phone app (phone/) is a few static files with no server of its own. It signs in with Supabase's email link
-- and talks to the database only through the functions below. Each one first checks that whoever is signed in is
-- in the `staff` table, so a stranger with the public app key gets nothing: no table is opened to the app directly.
--
--   phone_today()      what the agents did today, what is waiting for you, alerts, spend and the research quota
--   phone_queue()      every message waiting for you: email drafts to approve, and LinkedIn / WhatsApp / call
--                      scripts to send by hand, with the profile link or number
--   phone_review()     approve or reject an email draft (approved emails go out through the mailbox, as before)
--   phone_mark()       you sent a LinkedIn note, WhatsApp message or call by hand: log it. Or skip it.
--   phone_inbox()      recent replies and meetings
--   phone_alert()      mark an alert seen or resolved
--
-- The usual safety gate still applies: the database refuses do-not-contact buyers and anything draft_blockers()
-- objects to, and its reason is shown in the app. Needs 0001 to 0008. Safe to run more than once.

alter table contacts add column if not exists whatsapp text;     -- a WhatsApp number, when it differs from the phone

-- ─────────────────────────── who is signed in ───────────────────────────
create or replace function phone_staff() returns staff language plpgsql stable security definer set search_path = public as $$
declare s staff;
begin
  select * into s from staff where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) limit 1;
  if s.id is null then raise exception 'This login is not on the team.' using errcode = '42501'; end if;
  return s;
end $$;

-- How a draft is sent: email by the mailbox, the rest by hand. Older WhatsApp drafts were stored as channel
-- "other" with a subject like "WhatsApp +52 …".
create or replace function phone_kind(d outreach_drafts) returns text language sql immutable as $$
  select case when d.channel::text = 'whatsapp' or (d.channel::text = 'other' and d.subject ilike 'whatsapp%') then 'whatsapp'
              else d.channel::text end
$$;

-- The number to open in WhatsApp or to call: the contact's WhatsApp, else the number in the subject, else their phone.
create or replace function phone_number(d outreach_drafts, c contacts) returns text language sql immutable as $$
  select nullif(regexp_replace(coalesce(
           case when phone_kind(d) = 'whatsapp' then nullif(c.whatsapp, '') end,
           case when d.subject ~ '\+?\d[\d\s().-]{8,}' then substring(d.subject from '\+?\d[\d\s().-]{8,}') end,
           c.phone, ''), '\D', '', 'g'), '')
$$;

-- ─────────────────────────── Today ───────────────────────────
create or replace function phone_today() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me staff := phone_staff();
  tz text := 'America/Mexico_City';
  midnight timestamptz := date_trunc('day', now() at time zone tz) at time zone tz;
  out jsonb;
begin
  select jsonb_build_object(
    'me', me.name,
    'now', now(),
    'waiting', (select jsonb_build_object(
        'email',    count(*) filter (where phone_kind(d) = 'email' and d.status = 'pending_review'),
        'linkedin', count(*) filter (where phone_kind(d) = 'linkedin' and d.status in ('pending_review','approved')),
        'whatsapp', count(*) filter (where phone_kind(d) = 'whatsapp' and d.status in ('pending_review','approved')),
        'call',     count(*) filter (where phone_kind(d) = 'call' and d.status in ('pending_review','approved')))
      from outreach_drafts d where d.status in ('pending_review','approved')),
    'sent_today', (select jsonb_build_object(
        'email',    count(*) filter (where phone_kind(d) = 'email'),
        'by_hand',  count(*) filter (where phone_kind(d) <> 'email'))
      from outreach_drafts d where d.status = 'sent' and d.sent_at >= midnight),
    'replies_today', (select count(*) from interactions where direction = 'inbound' and kind = 'reply' and occurred_at >= midnight),
    'meetings_ready', (select count(*) from meeting_handoffs where status = 'ready'),
    'meetings_booked', (select count(*) from meeting_handoffs where status = 'booked' and meeting_at >= now()),
    'work', coalesce((select jsonb_agg(w order by w.kind) from (
        select kind,
               count(*) filter (where status = 'done' and finished_at >= midnight) as done,
               count(*) filter (where status = 'running') as running,
               count(*) filter (where status = 'queued') as queued,
               count(*) filter (where status = 'failed' and finished_at >= midnight) as failed
        from tasks group by kind) w), '[]'),
    'latest', coalesce((select jsonb_agg(l) from (
        select t.kind, t.status::text as status, t.finished_at, left(t.error, 160) as error,
               coalesce(co.name, nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), cl.name) as company
        from tasks t left join companies co on co.id = t.company_id left join contacts c on c.id = t.contact_id
        left join clients cl on cl.id = t.client_id
        where t.status in ('done','failed') and t.finished_at > now() - interval '24 hours'
        order by t.finished_at desc limit 10) l), '[]'),
    'alerts', coalesce((select jsonb_agg(a) from (
        select a.id, a.severity::text as severity, a.kind, a.message, a.status::text as status, a.created_at
        from alerts a where a.status <> 'resolved' and not a.notify_client
        order by (a.severity = 'urgent') desc, a.created_at desc limit 8) a), '[]'),
    'spend', (select jsonb_build_object('spent', coalesce(sum(spent_usd), 0), 'budget', coalesce(sum(budget_usd) filter (where active), 0))
              from v_agent_spend_month),
    'quota', (select to_jsonb(q) from v_research_quota q where q.day = (now() at time zone tz)::date)
  ) into out;
  return out;
end $$;

-- ─────────────────────────── To send ───────────────────────────
create or replace function phone_queue() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me staff := phone_staff();
begin
  return coalesce((select jsonb_agg(q order by q.sort, q.created_at) from (
    select d.id, phone_kind(d) as kind, d.status::text as status, d.subject, d.body, d.step, d.purpose, d.score,
           d.grade_feedback, d.created_at, d.reviewed_at, cl.name as client,
           nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as contact,
           c.title, co.name as company, c.email, c.linkedin_url, phone_number(d, c) as number,
           draft_blockers(d) as blockers,
           case phone_kind(d) when 'email' then 2 else 1 end as sort
    from outreach_drafts d
    join contacts c on c.id = d.contact_id
    join clients cl on cl.id = d.client_id
    left join companies co on co.id = coalesce(d.company_id, c.company_id)
    where d.status = 'pending_review' or (d.status = 'approved' and phone_kind(d) <> 'email')
    limit 200) q), '[]');
end $$;

-- Approve or reject a draft (any channel). Approved emails wait for the mailbox; approved LinkedIn / WhatsApp /
-- call scripts stay in the app until you mark them sent.
create or replace function phone_review(p_id uuid, p_decision text, p_subject text default null, p_body text default null,
                                        p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare me staff := phone_staff(); n int;
begin
  if p_decision not in ('approved','rejected') then raise exception 'Unknown decision.'; end if;
  if p_decision = 'approved' and coalesce(trim(p_body), 'x') = '' then raise exception 'The message is empty.'; end if;
  update outreach_drafts
     set status = p_decision::draft_status,
         subject = coalesce(nullif(trim(p_subject), ''), subject),
         body = coalesce(nullif(trim(p_body), ''), body),
         review_note = nullif(trim(p_note), ''),
         reviewed_by = me.email
   where id = p_id and status = 'pending_review';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Someone already decided this one.'; end if;
  return p_decision;
end $$;

-- You sent it by hand (or skipped it). A draft still waiting for review is approved and sent in one go, since
-- pressing "Sent" after reading it is the approval.
create or replace function phone_mark(p_id uuid, p_op text, p_body text default null) returns text
language plpgsql security definer set search_path = public as $$
declare me staff := phone_staff(); d outreach_drafts; k text; ch channel;
begin
  select * into d from outreach_drafts where id = p_id for update;
  if d.id is null or d.status not in ('pending_review','approved') then raise exception 'This one is already done.'; end if;
  k := phone_kind(d);
  if k = 'email' then raise exception 'Emails go out through the mailbox: approve them instead.'; end if;
  if p_op = 'skip' then
    update outreach_drafts set status = 'cancelled', review_note = 'Skipped by ' || me.name, reviewed_by = me.email where id = p_id;
    return 'skipped';
  end if;
  if p_op <> 'sent' then raise exception 'Unknown action.'; end if;
  if d.status = 'pending_review' then
    update outreach_drafts set status = 'approved', reviewed_by = me.email, body = coalesce(nullif(trim(p_body), ''), body)
     where id = p_id;
  end if;
  update outreach_drafts set status = 'sent', sent_at = now(), sent_by = me.email where id = p_id returning * into d;
  ch := case k when 'whatsapp' then 'whatsapp' when 'call' then 'call' when 'linkedin' then 'linkedin' else d.channel::text end::channel;
  insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, body, metadata)
  values (d.client_id, d.campaign_id, d.company_id, d.contact_id, ch, 'outbound', (case when k = 'call' then 'call' else 'sent' end)::interaction_kind,
          'staff', d.body, jsonb_build_object('draft_id', d.id, 'sent_by', me.email, 'by_hand', true));
  if d.campaign_id is not null then
    update campaign_targets set status = 'contacted', updated_at = now()
     where campaign_id = d.campaign_id and contact_id = d.contact_id and status = 'queued';
  end if;
  return 'sent';
end $$;

-- ─────────────────────────── Replies & meetings ───────────────────────────
create or replace function phone_inbox() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me staff := phone_staff();
begin
  return jsonb_build_object(
    'replies', coalesce((select jsonb_agg(r) from (
      select i.id, i.channel::text as channel, i.occurred_at, i.subject, left(i.body, 600) as body,
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
      select id, status, meeting_at, meeting_note, client, contact, contact_title, company, email, phone, linkedin_url,
             qualified, interest, product_fit, next_steps, body, created_at
      from v_meetings where status in ('ready','booked')
      order by status = 'ready' desc, meeting_at nulls last, created_at desc limit 20) m), '[]'));
end $$;

create or replace function phone_alert(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare me staff := phone_staff();
begin
  if p_status not in ('acknowledged','resolved') then raise exception 'Unknown status.'; end if;
  update alerts set status = p_status::alert_status where id = p_id;
end $$;

-- Only signed-in people can call these, and each one checks the staff list itself.
do $$
declare f text;
begin
  foreach f in array array['phone_staff()', 'phone_today()', 'phone_queue()', 'phone_inbox()',
                           'phone_review(uuid, text, text, text, text)', 'phone_mark(uuid, text, text)', 'phone_alert(uuid, text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
