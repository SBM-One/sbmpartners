-- 0011 · Autopilot (after 0010_reply_monitor, which files replies and bounces): the daily outreach run with no per-email approval.
--
-- Scheduled Claude sessions do the work (Apollo for people, Gmail for sending and replies, Google Calendar for
-- calls); this migration is the part they must not get wrong, written as fixed rules in the database:
--   * autopilot_settings     one row per client: on/off, pause switch, windows, follow-up days, Apollo budget
--   * autopilot_ramp         the mailbox warm-up: how many emails a day from which date
--   * autopilot_lint()       fixed copy checks (past customers, opt-out, postal address, client named, length)
--   * autopilot_approve()    the automatic reviewer: approves a draft only when lint AND draft_blockers are empty
--   * autopilot_send_queue   what may go out right now, within today's cap and the sending window
--   * autopilot_mark_sent()  records a send (Gmail ids, interaction) in one call
--   * autopilot_due_followups()  who gets follow-up 2 / 3 today (stops on any reply, bounce, unsubscribe, meeting)
--   * autopilot_health() / autopilot_guard()  bounce and spam checks; pauses everything on a bad signal
--   * autopilot_runs         a log of every stage, read by the end-of-day summary
-- Nothing here sends anything by itself.

create table if not exists autopilot_settings (
  client_id            uuid primary key references clients(id) on delete cascade,
  enabled              boolean not null default true,
  paused               boolean not null default false,
  pause_reason         text,
  paused_at            timestamptz,
  mailbox              text not null default 'santiago@sbmpartners.net',
  timezone             text not null default 'America/Mexico_City',
  send_from_hour       int  not null default 9  check (send_from_hour between 0 and 23),
  send_until_hour      int  not null default 18 check (send_until_hour between 1 and 24),
  sends_start_on       date not null default current_date,          -- first day the autopilot itself sends
  followup_days        int[] not null default '{3,7}',              -- business days after the FIRST email: step 2, step 3
  max_steps            int  not null default 3,
  apollo_daily_reveals int  not null default 40,                    -- Apollo email reveals per weekday
  apollo_min_credits   int  not null default 300,                   -- stop revealing below this balance
  meeting_minutes      int  not null default 30,
  allow_unverified     boolean not null default true,               -- generic inboxes (contacto@, ventas@) not verified by Apollo
  availability         jsonb not null default '{"days":[1,2,3,4,5],"windows":[["10:00","13:00"],["16:00","18:00"]],"confirmed":false}',
  past_customers       text[] not null default '{}',                -- never named in any outreach
  owner_session        text,                                        -- the thread session that relays news to Santiago
  updated_at           timestamptz not null default now()
);

create table if not exists autopilot_ramp (
  client_id  uuid not null references clients(id) on delete cascade,
  from_date  date not null,
  daily_cap  int  not null check (daily_cap between 0 and 200),
  primary key (client_id, from_date)
);

create table if not exists autopilot_runs (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid references clients(id) on delete cascade,
  stage       text not null check (stage in ('research','draft','send','followup','replies','booking','summary','guard')),
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  ok          boolean,
  counts      jsonb not null default '{}',
  note        text
);
create index if not exists autopilot_runs_time_idx on autopilot_runs(client_id, started_at desc);

alter table outreach_drafts  add column if not exists gmail_thread_id text;
alter table meeting_handoffs add column if not exists proposed_slots jsonb;       -- [{"start":..,"end":..}]
alter table meeting_handoffs add column if not exists proposed_at timestamptz;
alter table meeting_handoffs add column if not exists calendar_event_id text;
alter table meeting_handoffs add column if not exists gmail_thread_id text;

alter table autopilot_settings enable row level security;
alter table autopilot_ramp     enable row level security;
alter table autopilot_runs     enable row level security;

-- ─────────────────────────── today, in the client's time zone ───────────────────────────
create or replace function autopilot_today(p_client uuid) returns date language sql stable as $$
  select (now() at time zone coalesce((select timezone from autopilot_settings where client_id = p_client), 'America/Mexico_City'))::date
$$;

create or replace function autopilot_cap_today(p_client uuid) returns int language sql stable as $$
  select coalesce((select daily_cap from autopilot_ramp r where r.client_id = p_client and r.from_date <= autopilot_today(p_client)
                    order by from_date desc limit 1), 0)
$$;

-- every email that left the mailbox today (first touches, follow-ups and answers all count against the cap)
create or replace function autopilot_sent_today(p_client uuid) returns int language sql stable as $$
  select count(*)::int from outreach_drafts d, autopilot_settings s
   where s.client_id = p_client and d.client_id = p_client and d.channel = 'email' and d.status = 'sent'
     and (d.sent_at at time zone s.timezone)::date = autopilot_today(p_client)
$$;

-- add n business days (Mon–Fri) to a date
create or replace function autopilot_add_business_days(p_from date, p_n int) returns date language plpgsql immutable as $$
declare d date := p_from; k int := 0;
begin
  while k < p_n loop
    d := d + 1;
    if extract(isodow from d) < 6 then k := k + 1; end if;
  end loop;
  return d;
end $$;

-- ─────────────────────────── fixed copy checks ───────────────────────────
create or replace function autopilot_lint(d outreach_drafts) returns text[] language plpgsql stable as $$
declare
  s   autopilot_settings;
  cl  clients;
  b   text := coalesce(d.body, '');
  txt text := lower(coalesce(d.subject, '') || ' ' || coalesce(d.body, ''));
  pc  text;
  words int;
  out text[] := '{}';
begin
  select * into s from autopilot_settings where client_id = d.client_id;
  select * into cl from clients where id = d.client_id;
  if s.client_id is null then return array['Autopilot is not set up for this client.']; end if;

  foreach pc in array coalesce(s.past_customers, '{}') loop
    if position(lower(pc) in txt) > 0 then
      out := array_append(out, 'Names a past customer of the factory (' || pc || ').');
    end if;
  end loop;
  if b ~ '\{\{|\[[A-Z_ ]+\]|<[a-z_]+>' then out := array_append(out, 'Has an unfilled placeholder.'); end if;
  if b ~* 'https?://' then out := array_append(out, 'Has a link (Gmail rewrites links; new domains get flagged).'); end if;

  if d.channel = 'email' then
    words := coalesce(array_length(regexp_split_to_array(trim(b), '\s+'), 1), 0);
    if d.purpose = 'first' or (d.purpose is null and d.step = 1) then
      if coalesce(trim(d.subject), '') = '' then out := array_append(out, 'No subject.'); end if;
      if position('santa fe rústicos' in txt) = 0 and position('santa fe rusticos' in txt) = 0 then
        out := array_append(out, 'Does not name Santa Fe Rústicos.');
      end if;
      if position('1993' in b) = 0 then out := array_append(out, 'Does not say the factory exists since 1993.'); end if;
      if words > 230 then out := array_append(out, 'Too long for a first email (' || words || ' words, max 230).'); end if;
    else
      if words > 140 then out := array_append(out, 'Too long for a follow-up (' || words || ' words, max 140).'); end if;
    end if;
    if words < 25 then out := array_append(out, 'Too short (' || words || ' words).'); end if;
    if position(lower(coalesce(cl.postal_address, '~~')) in lower(b)) = 0 and position('chipilo de francisco javier mina' in lower(b)) = 0 then
      out := array_append(out, 'Missing the postal address in the footer.');
    end if;
    if lower(b) !~ '(palabra baja|no recibir m[aá]s correos|unsubscribe)' then
      out := array_append(out, 'Missing the opt-out line.');
    end if;
    if position('437 4378' in b) = 0 then out := array_append(out, 'Missing the WhatsApp line in the signature.'); end if;
  end if;

  -- WhatsApp only for buyers we never emailed
  if (d.channel = 'whatsapp' or (d.channel = 'other' and d.subject ilike 'whatsapp%')) and exists (
       select 1 from outreach_drafts p where p.contact_id = d.contact_id and p.channel = 'email' and p.status in ('approved','sent')) then
    out := array_append(out, 'This buyer gets email, so no WhatsApp.');
  end if;
  return out;
end $$;

-- ─────────────────────────── the automatic reviewer ───────────────────────────
-- Approves when nothing blocks it; otherwise leaves it in pending_review with the reasons (it then shows in the app).
create or replace function autopilot_approve(p_draft uuid) returns text[] language plpgsql as $$
declare d outreach_drafts; why text[];
begin
  select * into d from outreach_drafts where id = p_draft for update;
  if d.id is null then return array['The draft no longer exists.']; end if;
  if d.status <> 'pending_review' then return '{}'; end if;
  why := autopilot_lint(d) || draft_blockers(d);
  if cardinality(why) = 0 then
    update outreach_drafts set status = 'approved', reviewed_by = 'autopilot', review_note = 'Auto-approved: all checks passed'
     where id = p_draft;
  else
    update outreach_drafts set review_note = left('Autopilot held it: ' || array_to_string(why, ' '), 1000) where id = p_draft;
  end if;
  return why;
end $$;

-- ─────────────────────────── health and the pause switch ───────────────────────────
create or replace function autopilot_health(p_client uuid) returns jsonb language sql stable as $$
  with s as (select * from autopilot_settings where client_id = p_client),
  sent as (select count(*) filter (where d.sent_at > now() - interval '7 days'
                                      and coalesce(c.email_source = 'apollo' or c.verified_at is not null, false)) n7,
                  count(*) filter (where d.sent_at > now() - interval '1 day') n1
             from outreach_drafts d join contacts c on c.id = d.contact_id where d.client_id = p_client and d.channel = 'email' and d.status = 'sent'),
  bad as (select count(*) filter (where i.kind = 'bounce' and i.occurred_at > now() - interval '7 days' and v.verified) b7,
                 count(*) filter (where i.kind = 'bounce' and i.occurred_at > now() - interval '1 day' and v.verified) b1,
                 count(*) filter (where i.kind = 'bounce' and i.occurred_at > now() - interval '7 days' and not v.verified) u7,
                 count(*) filter (where i.metadata->>'category' = 'spam_complaint' and i.occurred_at > now() - interval '30 days') spam,
                 count(*) filter (where i.kind = 'unsubscribe' or i.metadata->>'category' = 'unsubscribe') unsub7
            from interactions i
            left join lateral (select coalesce(c.email_source = 'apollo' or c.verified_at is not null, false) as verified
                                 from contacts c where c.id = i.contact_id) v on true
           where i.client_id = p_client and i.direction = 'inbound' and i.occurred_at > now() - interval '30 days'),
  usent as (select count(*) n7 from outreach_drafts d join contacts c on c.id = d.contact_id
             where d.client_id = p_client and d.channel = 'email' and d.status = 'sent' and d.sent_at > now() - interval '7 days'
               and not coalesce(c.email_source = 'apollo' or c.verified_at is not null, false))
  select jsonb_build_object(
    'paused', (select paused from s), 'pause_reason', (select pause_reason from s),
    'cap_today', autopilot_cap_today(p_client), 'sent_today', autopilot_sent_today(p_client),
    'verified_sent_7d', sent.n7, 'sent_24h', sent.n1, 'bounces_7d', bad.b7, 'bounces_24h', bad.b1,
    'bounce_rate_7d', case when sent.n7 > 0 then round(bad.b7::numeric / sent.n7, 3) else 0 end,
    'unverified_sent_7d', usent.n7, 'unverified_bounces_7d', bad.u7,
    'allow_unverified', (select allow_unverified from s),
    'spam_30d', bad.spam, 'unsubscribes_30d', bad.unsub7)
  from sent, bad, usent
$$;

-- Pauses the client's autopilot on a bad signal. Returns the reason, or null when all is fine.
--   Verified addresses (Apollo or checked): 3+ bounces in 24 h, or a 7-day bounce rate over 5 % once 20+ went out.
--   Any spam complaint pauses everything.
--   Unverified generic inboxes: 3+ bounces and over 15 % of them in 7 days stops email to unverified addresses only.
create or replace function autopilot_guard(p_client uuid) returns text language plpgsql as $$
declare h jsonb := autopilot_health(p_client); why text;
begin
  if (h->>'bounces_24h')::int >= 3 then why := 'Three or more verified addresses bounced in 24 hours.';
  elsif (h->>'verified_sent_7d')::int >= 20 and (h->>'bounce_rate_7d')::numeric > 0.05 then
    why := 'Bounce rate over 5 % this week (' || (h->>'bounces_7d') || ' of ' || (h->>'verified_sent_7d') || ' verified).';
  elsif (h->>'spam_30d')::int > 0 then why := 'A buyer reported us as spam.';
  end if;
  if why is null and (h->>'unverified_bounces_7d')::int >= 3
     and (h->>'unverified_bounces_7d')::numeric > 0.15 * greatest((h->>'unverified_sent_7d')::int, 1) then
    update autopilot_settings set allow_unverified = false where client_id = p_client and allow_unverified;
    if found then
      insert into alerts (client_id, severity, kind, message, refs)
      values (p_client, 'warning', 'autopilot_unverified_off',
              'Too many generic inboxes bounced; autopilot now emails only verified addresses.', h);
    end if;
  end if;
  if why is not null then
    update autopilot_settings set paused = true, pause_reason = why, paused_at = now()
     where client_id = p_client and not paused;
    if found then
      insert into alerts (client_id, severity, kind, message, refs)
      values (p_client, 'urgent', 'autopilot_paused', 'Autopilot paused all sends: ' || why, h);
    end if;
  end if;
  return why;
end $$;

-- ─────────────────────────── what may go out now ───────────────────────────
-- Approved emails, oldest first with follow-ups ahead of first touches, only inside the sending window on a weekday,
-- never above today's cap, never while paused. "slots" = how many more may go out today.
create or replace view autopilot_send_queue as
with s as (
  select a.*, autopilot_cap_today(a.client_id) - autopilot_sent_today(a.client_id) as slots,
         now() at time zone a.timezone as local_now
  from autopilot_settings a
  where a.enabled and not a.paused
)
select d.id, d.client_id, d.contact_id, d.step, d.purpose, d.subject, d.body, c.email as to_email,
       coalesce(nullif(trim(c.first_name || ' ' || coalesce(c.last_name, '')), ''), c.email) as to_name,
       d.gmail_thread_id, d.in_reply_to, s.slots,
       row_number() over (partition by d.client_id
                          order by case when d.purpose = 'first' then 1 else 0 end, d.send_after nulls first, d.reviewed_at) as n
from outreach_drafts d
join s on s.client_id = d.client_id
join contacts c on c.id = d.contact_id
where d.status = 'approved' and d.channel = 'email' and d.send_claimed_at is null
  and (d.send_after is null or d.send_after <= now())
  and s.local_now::date >= s.sends_start_on
  and extract(isodow from s.local_now) < 6
  and extract(hour from s.local_now) >= s.send_from_hour and extract(hour from s.local_now) < s.send_until_hour
  and s.slots > 0
  and (s.allow_unverified or c.email_source = 'apollo' or c.verified_at is not null)
  and cardinality(draft_blockers(d)) = 0
  and cardinality(autopilot_lint(d)) = 0;

-- Claim one draft before sending it, so two runs can never send the same email.
create or replace function autopilot_claim(p_draft uuid) returns boolean language plpgsql as $$
declare n int;
begin
  update outreach_drafts set send_claimed_at = now()
   where id = p_draft and status = 'approved' and send_claimed_at is null and cardinality(draft_blockers(outreach_drafts.*)) = 0;
  get diagnostics n = row_count;
  return n = 1;
end $$;

-- After Gmail accepted it: mark sent, keep the Gmail ids for threading follow-ups, log the interaction.
create or replace function autopilot_mark_sent(p_draft uuid, p_message_id text, p_thread_id text) returns void language plpgsql as $$
declare d outreach_drafts;
begin
  update outreach_drafts set status = 'sent', sent_at = now(), sent_by = 'autopilot',
         message_id = coalesce(p_message_id, message_id), gmail_thread_id = coalesce(p_thread_id, gmail_thread_id)
   where id = p_draft and status in ('approved','sent') returning * into d;
  if d.id is null then raise exception 'Draft % is not approved.', p_draft; end if;
  insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, subject, body, external_id, metadata)
  values (d.client_id, d.campaign_id, d.company_id, d.contact_id, 'email', 'outbound', 'sent', 'bot', d.subject, d.body,
          p_thread_id, jsonb_build_object('draft_id', d.id, 'gmail_message_id', p_message_id, 'step', d.step, 'by', 'autopilot'));
end $$;

-- Gmail refused it: release the claim and record why.
create or replace function autopilot_send_failed(p_draft uuid, p_error text) returns void language sql as $$
  update outreach_drafts set send_claimed_at = null, send_error = left(p_error, 500) where id = p_draft and status = 'approved'
$$;

-- ─────────────────────────── follow-ups due ───────────────────────────
-- One row per buyer whose next follow-up is due today or earlier: step 2 at followup_days[1] business days after the
-- first email, step 3 at followup_days[2]. Nothing for buyers who replied, bounced, unsubscribed, were stopped, were
-- handed over for a meeting, or already have that step drafted.
create or replace function autopilot_due_followups(p_client uuid) returns table (
  contact_id uuid, company_id uuid, next_step int, first_sent_on date, first_subject text, first_body text,
  last_body text, gmail_thread_id text, message_id text, to_email text, first_name text, company text)
language sql stable as $$
  with s as (select * from autopilot_settings where client_id = p_client),
  firsts as (
    select distinct on (d.contact_id) d.*
      from outreach_drafts d
     where d.client_id = p_client and d.channel = 'email' and d.status = 'sent' and coalesce(d.purpose, 'first') = 'first'
     order by d.contact_id, d.sent_at),
  last_sent as (
    select distinct on (d.contact_id) d.contact_id, d.step, d.body
      from outreach_drafts d
     where d.client_id = p_client and d.channel = 'email' and d.status = 'sent' and coalesce(d.purpose, 'first') in ('first','follow_up')
     order by d.contact_id, d.step desc, d.sent_at desc)
  select f.contact_id, coalesce(f.company_id, c.company_id), ls.step + 1, (f.sent_at at time zone s.timezone)::date,
         f.subject, f.body, ls.body, f.gmail_thread_id, f.message_id, c.email, c.first_name, co.name
    from firsts f
    join s on true
    join last_sent ls on ls.contact_id = f.contact_id
    join contacts c on c.id = f.contact_id
    left join companies co on co.id = coalesce(f.company_id, c.company_id)
   where ls.step < s.max_steps
     and autopilot_add_business_days((f.sent_at at time zone s.timezone)::date, s.followup_days[ls.step]) <= autopilot_today(p_client)
     and not c.do_not_contact and c.stopped_at is null and coalesce(c.email_status, '') <> 'invalid'
     and not is_suppressed(c.email)
     and not exists (select 1 from interactions i where i.contact_id = f.contact_id and i.direction = 'inbound'
                       and i.kind in ('reply','bounce','unsubscribe'))
     and not exists (select 1 from meeting_handoffs h where h.contact_id = f.contact_id and h.client_id = p_client)
     and not exists (select 1 from outreach_drafts x where x.contact_id = f.contact_id and x.client_id = p_client
                       and x.channel = 'email' and x.step = ls.step + 1 and x.status <> 'rejected')
$$;

-- ─────────────────────────── the end-of-day numbers ───────────────────────────
create or replace function autopilot_day_summary(p_client uuid) returns jsonb language sql stable as $$
  with s as (select * from autopilot_settings where client_id = p_client),
  t as (select autopilot_today(p_client) as day)
  select jsonb_build_object(
    'day', (select day from t),
    'sent_first', (select count(*) from outreach_drafts d, s, t where d.client_id = p_client and d.channel = 'email' and d.status = 'sent'
                     and coalesce(d.purpose, 'first') = 'first' and (d.sent_at at time zone s.timezone)::date = t.day),
    'sent_followups', (select count(*) from outreach_drafts d, s, t where d.client_id = p_client and d.channel = 'email' and d.status = 'sent'
                     and d.purpose = 'follow_up' and (d.sent_at at time zone s.timezone)::date = t.day),
    'replies', (select count(*) from interactions i, s, t where i.client_id = p_client and i.direction = 'inbound' and i.kind = 'reply'
                     and (i.occurred_at at time zone s.timezone)::date = t.day),
    'bounces', (select count(*) from interactions i, s, t where i.client_id = p_client and i.kind = 'bounce'
                     and (i.occurred_at at time zone s.timezone)::date = t.day),
    'unsubscribes', (select count(*) from interactions i, s, t where i.client_id = p_client and i.kind = 'unsubscribe'
                     and (i.occurred_at at time zone s.timezone)::date = t.day),
    'calls_booked_today', (select count(*) from meeting_handoffs h, s, t where h.client_id = p_client and h.status = 'booked'
                     and (h.decided_at at time zone s.timezone)::date = t.day),
    'calls_upcoming', (select count(*) from meeting_handoffs h where h.client_id = p_client and h.status = 'booked' and h.meeting_at > now()),
    'new_buyers_researched', (select count(*) from contacts c, s, t where c.email_source = 'apollo'
                     and (c.created_at at time zone s.timezone)::date = t.day),
    'queued_for_tomorrow', (select count(*) from outreach_drafts d where d.client_id = p_client and d.channel = 'email' and d.status = 'approved'),
    'held_for_review', (select count(*) from outreach_drafts d where d.client_id = p_client and d.status = 'pending_review'
                     and d.review_note like 'Autopilot held it:%'),
    'by_hand_waiting', (select count(*) from outreach_drafts d where d.client_id = p_client and d.status = 'approved' and d.channel <> 'email'),
    'health', autopilot_health(p_client),
    'stages', (select jsonb_agg(jsonb_build_object('stage', r.stage, 'ok', r.ok, 'counts', r.counts, 'note', r.note) order by r.started_at)
                 from autopilot_runs r, s, t where r.client_id = p_client and (r.started_at at time zone s.timezone)::date = t.day))
$$;
