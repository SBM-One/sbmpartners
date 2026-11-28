-- 0016 · Operating controls (2026-11-28): the rules every send must pass at the moment it goes out, honest
-- delivery states, a stop when the reply monitor goes quiet, one pause switch, and safer reply filing.
--
-- What changes, in plain words:
--   * Every send is checked when it is claimed, not only when it is queued: pause, sending window, today's cap
--     (counting emails that may already be out), the English cap, the reply monitor having run recently, the
--     buyer's country rule, at most one first email per company per day, and the company-level holds below.
--     Two runs can never both take the last slot (the claim locks the client's settings row).
--   * A draft now says how far it got: not_sent, prepared (a LinkedIn/WhatsApp app was opened), attempted
--     (claimed for sending), sent (confirmed), failed (certainly not sent), uncertain (may or may not have gone).
--     Nothing new is sent while an earlier send is unconfirmed; autopilot_reconcile_list() says what to check
--     in Gmail Sent first.
--   * Sends are logged as 'gmail:<message id>', so a follow-up in the same Gmail thread no longer collides with
--     the first email's record. Answers to replies now count against the daily cap.
--   * Account-level holds: after someone at a company says no, nobody there is written to for 180 days; when a
--     colleague replies, or a reply's sender can't be matched with certainty, the company waits for a person.
--   * Out-of-office and "not now" snooze the buyer; follow-ups resume after the date.
--   * Reply matching by company domain or alias no longer acts on a guessed person: it goes to identity review.
--     An unsubscribe from an unknown sender suppresses that sender's address.
--   * WhatsApp needs a recorded opt-in. LinkedIn and WhatsApp: opening the app is "prepared"; only a tap on
--     "Sent" records the message (phone_mark 'confirmed').
--   * Country rules carry their basis, scope, reviewer and review date; a rule past its review date stops sends.
--   * The sales pack (facts with confirmed / client_stated / conflict / missing status) feeds the copy checks:
--     a draft that uses a conflicting or missing fact is held.
--   * The demo client is flagged and left out of reporting.
--   * ops_check() raises alerts for a quiet reply monitor, unconfirmed sends, a missed run, a cap overrun and
--     sends without a record.

-- ─────────────────────────── settings ───────────────────────────
alter table autopilot_settings add column if not exists lang_caps jsonb not null default '{"en": 14}';
alter table autopilot_settings add column if not exists monitor_max_minutes int not null default 90;
alter table autopilot_settings add column if not exists first_touch_per_company_day int not null default 1;
alter table autopilot_settings add column if not exists refusal_cooldown_days int not null default 180;
alter table autopilot_settings add column if not exists colleague_hold_days int not null default 30;
alter table autopilot_settings add column if not exists not_now_days int not null default 60;
alter table autopilot_settings add column if not exists attempt_timeout_minutes int not null default 15;
alter table autopilot_settings add column if not exists send_days int[] not null default '{1,2,3,4,5}';   -- ISO weekdays

-- One switch for everything that sends (autopilot, answers, time proposals, by-hand messages).
create table if not exists ops_state (
  id           boolean primary key default true check (id),
  paused       boolean not null default false,
  pause_reason text,
  paused_at    timestamptz,
  paused_by    text,
  updated_at   timestamptz not null default now()
);
insert into ops_state (id) values (true) on conflict do nothing;
alter table ops_state enable row level security;

-- ─────────────────────────── delivery states ───────────────────────────
alter table outreach_drafts add column if not exists delivery text not null default 'not_sent';
alter table outreach_drafts drop constraint if exists outreach_drafts_delivery_check;
alter table outreach_drafts add constraint outreach_drafts_delivery_check
  check (delivery in ('not_sent','prepared','attempted','sent','failed','uncertain'));
alter table outreach_drafts add column if not exists prepared_at  timestamptz;
alter table outreach_drafts add column if not exists attempted_at timestamptz;
alter table outreach_drafts add column if not exists confirmed_at timestamptz;
update outreach_drafts set delivery = 'sent', confirmed_at = coalesce(confirmed_at, sent_at)
 where status = 'sent' and delivery = 'not_sent';
update outreach_drafts set delivery = 'uncertain', attempted_at = coalesce(attempted_at, send_claimed_at)
 where status = 'approved' and send_claimed_at is not null and delivery = 'not_sent';

-- ─────────────────────────── buyers: snooze and WhatsApp opt-in ───────────────────────────
alter table contacts add column if not exists snoozed_until timestamptz;
alter table contacts add column if not exists snooze_reason text;
alter table contacts add column if not exists whatsapp_opt_in_at timestamptz;
alter table contacts add column if not exists whatsapp_opt_in_source text;      -- 'buyer_wrote_first' | 'asked_on_call' | 'asked_by_email' | 'form'
alter table contacts add column if not exists whatsapp_opt_in_evidence text;    -- where it can be checked (message, call note)
alter table contacts add column if not exists whatsapp_opt_in_by text;
alter table contacts add column if not exists whatsapp_opt_out_at timestamptz;

-- Other domains a company writes from (e.g. a parent group's domain). Used for reply matching only.
create table if not exists company_domains (
  domain     text primary key check (domain = lower(domain) and position('@' in domain) = 0),
  company_id uuid not null references companies(id) on delete cascade,
  source     text,
  added_at   timestamptz not null default now()
);
alter table company_domains enable row level security;

-- Replies whose sender we could not tie to a person with certainty.
create table if not exists identity_reviews (
  id                  uuid primary key default gen_random_uuid(),
  client_id           uuid not null references clients(id) on delete cascade,
  interaction_id      uuid not null references interactions(id) on delete cascade,
  from_address        text,
  company_id          uuid references companies(id),
  guessed_contact_id  uuid references contacts(id),
  matched_by          text,
  category            text,
  status              text not null default 'open' check (status in ('open','same_person','other_person','unrelated')),
  resolved_contact_id uuid references contacts(id),
  resolved_by         text,
  resolved_at         timestamptz,
  created_at          timestamptz not null default now()
);
create index if not exists identity_reviews_open_idx on identity_reviews(client_id) where status = 'open';
alter table identity_reviews enable row level security;

-- ─────────────────────────── demo data ───────────────────────────
alter table clients add column if not exists is_demo boolean not null default false;
update clients set is_demo = true where id = '00000000-0000-0000-0000-0000000000c1' or name = 'Pilot Furniture Co.';
update alerts set status = 'resolved' where status <> 'resolved' and client_id in (select id from clients where is_demo);

-- ─────────────────────────── country rules as operating controls ───────────────────────────
alter table email_country_rules add column if not exists basis text;          -- why this rule (law + how we comply)
alter table email_country_rules add column if not exists scope text;          -- who it covers
alter table email_country_rules add column if not exists reviewer text;
alter table email_country_rules add column if not exists reviewed_on date;
alter table email_country_rules add column if not exists review_due date;
alter table email_country_rules add column if not exists legal_review text not null default 'not_reviewed';
alter table email_country_rules drop constraint if exists email_country_rules_legal_review_check;
alter table email_country_rules add constraint email_country_rules_legal_review_check
  check (legal_review in ('not_reviewed','owner_confirmed','lawyer_confirmed'));
update email_country_rules set
  basis = coalesce(basis, law || '. ' || coalesce(note, '')),
  scope = coalesce(scope, 'B2B email to work addresses of buyers at companies. Not consumers.'),
  reviewer = coalesce(reviewer, confirmed_by),
  reviewed_on = coalesce(reviewed_on, (confirmed_at at time zone 'America/Mexico_City')::date),
  review_due = coalesce(review_due, (confirmed_at at time zone 'America/Mexico_City')::date + 180),
  legal_review = case when legal_review = 'not_reviewed' and confirmed_at is not null then 'owner_confirmed' else legal_review end
 where confirmed_at is not null;

-- ─────────────────────────── the sales pack ───────────────────────────
-- One row per fact a message may use. Only 'confirmed' and 'client_stated' facts may appear in outreach;
-- a draft that matches the lint_pattern of a 'conflict', 'missing' or 'retired' fact is held.
create table if not exists sales_pack_items (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references clients(id) on delete cascade,
  topic        text not null,                 -- company | capacity | product | commercial | logistics | quality | proof | process
  item         text not null,
  value        text,
  status       text not null check (status in ('confirmed','client_stated','conflict','missing','retired')),
  source       text,                          -- who said it, where, when
  owner        text,                          -- who keeps it current
  confirmed_by text,
  confirmed_on date,
  fresh_until  date,                          -- re-check after this date
  lint_pattern text,                          -- regex (case-insensitive) that spots the fact in a message
  note         text,
  updated_at   timestamptz not null default now(),
  unique (client_id, item)
);
alter table sales_pack_items enable row level security;

-- ─────────────────────────── helpers ───────────────────────────
create or replace function draft_lang(d outreach_drafts) returns text language sql immutable as $$
  select coalesce((select substr(x, 6) from jsonb_array_elements_text(
                     case when jsonb_typeof(d.playbook_used) = 'array' then d.playbook_used else '[]'::jsonb end) x
                    where x like 'lang:%' limit 1), 'es')
$$;

create or replace function draft_company(d outreach_drafts) returns uuid language sql stable as $$
  select coalesce(d.company_id, (select company_id from contacts where id = d.contact_id))
$$;

create or replace function draft_local_day(p_client uuid, p_at timestamptz) returns date language sql stable as $$
  select (p_at at time zone coalesce((select timezone from autopilot_settings where client_id = p_client), 'America/Mexico_City'))::date
$$;

-- Every email that left (or may have left) the mailbox today: logged outbound emails plus claimed sends not yet
-- confirmed. First emails, follow-ups, answers and time proposals all count.
create or replace function autopilot_sent_today(p_client uuid) returns int language sql stable as $$
  select (select count(*) from interactions i
           where i.client_id = p_client and i.channel = 'email' and i.direction = 'outbound' and i.kind = 'sent'
             and draft_local_day(p_client, i.occurred_at) = autopilot_today(p_client))::int
       + (select count(*) from outreach_drafts d
           where d.client_id = p_client and d.channel = 'email' and d.status = 'approved'
             and d.delivery in ('attempted','uncertain'))::int
$$;

create or replace function autopilot_sent_today_lang(p_client uuid, p_lang text) returns int language sql stable as $$
  select count(*)::int from outreach_drafts d
   where d.client_id = p_client and d.channel = 'email' and draft_lang(d) = p_lang
     and (   (d.status = 'sent' and draft_local_day(p_client, d.sent_at) = autopilot_today(p_client))
          or (d.status = 'approved' and d.delivery in ('attempted','uncertain')))
$$;

create or replace function autopilot_monitor_last_run() returns timestamptz language sql stable as $$
  select max(ran_at) from monitor_runs
$$;

create or replace function autopilot_monitor_fresh(p_client uuid) returns boolean language sql stable as $$
  select coalesce(autopilot_monitor_last_run() > now() - make_interval(mins => s.monitor_max_minutes), false)
    from autopilot_settings s where s.client_id = p_client
$$;

-- Sends that may or may not have gone out and must be checked in Gmail Sent before anything else is sent.
create or replace function autopilot_unconfirmed(p_client uuid) returns setof outreach_drafts language sql stable as $$
  select d.* from outreach_drafts d join autopilot_settings s on s.client_id = d.client_id
   where d.client_id = p_client and d.channel = 'email' and d.status = 'approved'
     and (d.delivery = 'uncertain'
          or (d.delivery = 'attempted' and d.attempted_at < now() - make_interval(mins => s.attempt_timeout_minutes)))
$$;

-- ─────────────────────────── country rule: review date ───────────────────────────
-- contact_email_blockers() (0006) already checks that the buyer's country has a confirmed rule that allows the
-- email. This adds the review date: a rule past its review date stops new outreach to that country.
create or replace function country_blockers(d outreach_drafts) returns text[] language plpgsql stable as $$
declare c contacts; ctry text; r email_country_rules;
begin
  if d.channel <> 'email' or d.purpose = 'reply' then return '{}'; end if;   -- answering someone who wrote to us
  select * into c from contacts where id = d.contact_id;
  ctry := coalesce(c.country, (select country from companies where id = draft_company(d)));
  select * into r from email_country_rules where country = ctry;
  if r.review_due is not null and r.review_due < current_date then
    return array['The email rule for ' || r.name || ' was due for review on ' || r.review_due || '; Santiago re-confirms it first.'];
  end if;
  return '{}';
end $$;

-- ─────────────────────────── company-level holds ───────────────────────────
create or replace function account_blockers(d outreach_drafts) returns text[] language plpgsql stable as $$
declare
  s   autopilot_settings;
  c   contacts;
  co  uuid := draft_company(d);
  i   record;
  out text[] := '{}';
begin
  if d.purpose = 'reply' then return '{}'; end if;
  select * into s from autopilot_settings where client_id = d.client_id;
  select * into c from contacts where id = d.contact_id;
  if c.snoozed_until is not null and c.snoozed_until > now() then
    out := array_append(out, 'Snoozed until ' || to_char(c.snoozed_until at time zone coalesce(s.timezone, 'America/Mexico_City'), 'DD Mon YYYY')
                             || coalesce(' (' || c.snooze_reason || ')', '') || '.');
  end if;
  if co is null then return out; end if;
  -- someone at the company said no
  select x.occurred_at into i from interactions x
   where x.client_id = d.client_id and x.company_id = co and x.direction = 'inbound'
     and (x.kind = 'unsubscribe' or x.metadata->>'category' in ('not_interested','unsubscribe'))
     and coalesce(x.metadata->>'identity', '') <> 'unrelated'
     and x.occurred_at > now() - make_interval(days => coalesce(s.refusal_cooldown_days, 180))
   order by x.occurred_at desc limit 1;
  if found then
    out := array_append(out, 'Someone at this company said no on ' || to_char(i.occurred_at, 'DD Mon YYYY')
                             || '; nobody there is contacted until ' || to_char(i.occurred_at + make_interval(days => coalesce(s.refusal_cooldown_days, 180)), 'DD Mon YYYY') || '.');
  end if;
  -- a colleague (or an unmatched sender from the company) replied: a person coordinates the account first
  if coalesce(d.research->>'referral_from', '') = '' then
    select x.occurred_at into i from interactions x
     where x.client_id = d.client_id and x.company_id = co and x.direction = 'inbound' and x.kind = 'reply'
       and (x.contact_id is null or x.contact_id <> d.contact_id)
       and coalesce(x.metadata->>'identity', '') <> 'unrelated'
       and coalesce(x.metadata->>'category', '') not in ('not_interested','unsubscribe')
       and x.occurred_at > now() - make_interval(days => coalesce(s.colleague_hold_days, 30))
     order by x.occurred_at desc limit 1;
    if found then
      out := array_append(out, 'Someone else at this company replied on ' || to_char(i.occurred_at, 'DD Mon YYYY')
                               || '; Santiago decides who we write to there next.');
    end if;
  end if;
  if exists (select 1 from identity_reviews r where r.client_id = d.client_id and r.company_id = co and r.status = 'open') then
    out := array_append(out, 'A reply from this company is waiting for identity review.');
  end if;
  return out;
end $$;

-- ─────────────────────────── copy checks: unconfirmed facts ───────────────────────────
create or replace function sales_pack_blockers(d outreach_drafts) returns text[] language sql stable as $$
  select coalesce(array_agg('Uses a fact that is not confirmed (' || s.item || ': ' || s.status || ').' order by s.item), '{}')
    from sales_pack_items s
   where s.client_id = d.client_id and s.status in ('conflict','missing','retired') and s.lint_pattern is not null
     and (coalesce(d.subject, '') || ' ' || coalesce(d.body, '')) ~* s.lint_pattern
$$;

-- ─────────────────────────── the send-time check ───────────────────────────
-- Every reason this email may not go out right now. Empty = it may be claimed.
create or replace function autopilot_send_check(p_draft uuid) returns text[] language plpgsql stable as $$
declare
  d   outreach_drafts;
  s   autopilot_settings;
  o   ops_state;
  c   contacts;
  loc timestamp;
  cap int;
  n   int;
  lcap int;
  out text[] := '{}';
begin
  select * into d from outreach_drafts where id = p_draft;
  if d.id is null then return array['The draft no longer exists.']; end if;
  if d.channel <> 'email' then return array['Not an email.']; end if;
  if d.status <> 'approved' then return array['Not approved (' || d.status || ').']; end if;
  if d.send_claimed_at is not null then
    return array['Already claimed at ' || d.send_claimed_at || ' (' || d.delivery || ').'];
  end if;
  select * into s from autopilot_settings where client_id = d.client_id;
  select * into o from ops_state limit 1;
  select * into c from contacts where id = d.contact_id;
  if s.client_id is null or not s.enabled then out := array_append(out, 'Autopilot is off for this client.'); end if;
  if s.paused then out := array_append(out, 'Paused: ' || coalesce(s.pause_reason, 'no reason given') || '.'); end if;
  if o.paused then out := array_append(out, 'All sending is paused: ' || coalesce(o.pause_reason, 'no reason given') || '.'); end if;
  if s.client_id is not null then
    loc := now() at time zone s.timezone;
    if loc::date < s.sends_start_on or not (extract(isodow from loc)::int = any (s.send_days))
       or extract(hour from loc) < s.send_from_hour or extract(hour from loc) >= s.send_until_hour then
      out := array_append(out, 'Outside the sending window.');
    end if;
    if not autopilot_monitor_fresh(d.client_id) then
      out := array_append(out, 'The reply monitor has not run in the last ' || s.monitor_max_minutes
                               || ' minutes; sending waits so no reply or unsubscribe is missed.');
    end if;
    if exists (select 1 from autopilot_unconfirmed(d.client_id)) then
      out := array_append(out, 'An earlier send is unconfirmed; check Gmail Sent first (autopilot_reconcile_list).');
    end if;
    cap := autopilot_cap_today(d.client_id);
    n := autopilot_sent_today(d.client_id);
    if n >= cap then out := array_append(out, 'Today''s cap is reached (' || n || ' of ' || cap || ').'); end if;
    lcap := (s.lang_caps ->> draft_lang(d))::int;
    if lcap is not null and autopilot_sent_today_lang(d.client_id, draft_lang(d)) >= lcap then
      out := array_append(out, 'Today''s cap for ' || draft_lang(d) || ' emails is reached (' || lcap || ').');
    end if;
    if not (s.allow_unverified or c.email_source = 'apollo' or c.verified_at is not null) then
      out := array_append(out, 'Unverified address while email to unverified addresses is off.');
    end if;
    if coalesce(d.purpose, 'first') = 'first' and (
         select count(*) from outreach_drafts x
          where x.client_id = d.client_id and x.id <> d.id and x.channel = 'email' and coalesce(x.purpose, 'first') = 'first'
            and draft_company(x) = draft_company(d)
            and ((x.status = 'sent' and draft_local_day(d.client_id, x.sent_at) = autopilot_today(d.client_id))
                 or (x.status = 'approved' and x.delivery in ('attempted','uncertain')))) >= s.first_touch_per_company_day then
      out := array_append(out, 'Someone at this company already got a first email today.');
    end if;
  end if;
  if d.send_after is not null and d.send_after > now() then out := array_append(out, 'Scheduled for later.'); end if;
  return out || coalesce(draft_blockers(d), '{}') || coalesce(autopilot_lint(d), '{}')
             || sales_pack_blockers(d) || account_blockers(d) || country_blockers(d);
end $$;

create or replace function autopilot_why_not(p_draft uuid) returns text[] language sql stable as $$
  select autopilot_send_check(p_draft)
$$;

-- What may go out now (each row still has to be claimed; the claim re-checks everything under a lock).
create or replace view autopilot_send_queue with (security_invoker = true) as
with s as (
  select a.*, autopilot_cap_today(a.client_id) - autopilot_sent_today(a.client_id) as slots
  from autopilot_settings a
  where a.enabled and not a.paused and not coalesce((select paused from ops_state limit 1), false)
)
select d.id, d.client_id, d.contact_id, d.step, d.purpose, d.subject, d.body, c.email as to_email,
       coalesce(nullif(trim(c.first_name || ' ' || coalesce(c.last_name, '')), ''), c.email) as to_name,
       d.gmail_thread_id, d.in_reply_to, s.slots,
       row_number() over (partition by d.client_id
                          order by case when d.purpose = 'first' then 1 else 0 end, d.send_after nulls first, d.reviewed_at) as n,
       draft_lang(d) as lang
from outreach_drafts d
join s on s.client_id = d.client_id
join contacts c on c.id = d.contact_id
where d.status = 'approved' and d.channel = 'email' and d.send_claimed_at is null and s.slots > 0
  and cardinality(autopilot_send_check(d.id)) = 0;
revoke all on autopilot_send_queue from anon, authenticated;

-- Claim one draft for sending. Serialised per client, so two runs can't both take the last slot or send twice.
create or replace function autopilot_claim(p_draft uuid) returns boolean language plpgsql as $$
declare cl uuid; n int;
begin
  select client_id into cl from outreach_drafts where id = p_draft;
  if cl is null then return false; end if;
  perform 1 from autopilot_settings where client_id = cl for update;
  perform 1 from outreach_drafts where id = p_draft for update;
  if cardinality(autopilot_send_check(p_draft)) > 0 then return false; end if;
  update outreach_drafts set send_claimed_at = now(), attempted_at = now(), delivery = 'attempted', send_error = null
   where id = p_draft and status = 'approved' and send_claimed_at is null;
  get diagnostics n = row_count;
  return n = 1;
end $$;

-- Gmail accepted it. Logged under the Gmail message id, so later messages in the same thread get their own record.
-- p_sent_at: the time Gmail shows, when reconciling an earlier send.
create or replace function autopilot_mark_sent(p_draft uuid, p_message_id text, p_thread_id text, p_sent_at timestamptz)
returns void language plpgsql as $$
declare d outreach_drafts; unclaimed boolean; iid uuid; at timestamptz := coalesce(p_sent_at, now());
begin
  if coalesce(trim(p_message_id), '') = '' then raise exception 'The Gmail message id is required.'; end if;
  select * into d from outreach_drafts where id = p_draft for update;
  if d.id is null then raise exception 'Draft % does not exist.', p_draft; end if;
  if d.status = 'sent' then
    if d.message_id = p_message_id then return; end if;
    raise exception 'Draft % was already recorded as sent with another message.', p_draft;
  end if;
  if d.status <> 'approved' then raise exception 'Draft % is not approved (%).', p_draft, d.status; end if;
  unclaimed := d.send_claimed_at is null;
  insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, subject, body,
                            external_id, occurred_at, metadata)
  values (d.client_id, d.campaign_id, draft_company(d), d.contact_id, 'email', 'outbound', 'sent', 'bot', d.subject, d.body,
          'gmail:' || p_message_id, at,
          jsonb_strip_nulls(jsonb_build_object('draft_id', d.id, 'gmail_message_id', p_message_id, 'gmail_thread_id', p_thread_id,
                             'step', d.step, 'purpose', d.purpose, 'by', 'autopilot',
                             'unclaimed', case when unclaimed then true end, 'reconciled', case when p_sent_at is not null then true end)))
  on conflict (channel, external_id) do update set metadata = interactions.metadata
  returning id into iid;
  update outreach_drafts set status = 'sent', delivery = 'sent', sent_at = at, confirmed_at = now(), sent_by = 'autopilot',
         message_id = p_message_id, gmail_thread_id = coalesce(p_thread_id, gmail_thread_id),
         send_claimed_at = coalesce(send_claimed_at, at), interaction_id = iid, send_error = null
   where id = p_draft;
  if d.campaign_id is not null then
    update campaign_targets set status = 'contacted', updated_at = now()
     where campaign_id = d.campaign_id and contact_id = d.contact_id and status = 'queued';
  end if;
  if unclaimed then
    insert into alerts (client_id, severity, kind, message, refs)
    values (d.client_id, 'warning', 'unclaimed_send',
            'An email went out without the send-time checks (it was not claimed first). It is recorded; check which run sent it.',
            jsonb_build_object('draft_id', d.id, 'interaction_id', iid));
  end if;
end $$;

-- the usual call (sent just now)
create or replace function autopilot_mark_sent(p_draft uuid, p_message_id text, p_thread_id text) returns void language sql as $$
  select autopilot_mark_sent(p_draft, p_message_id, p_thread_id, null::timestamptz)
$$;

-- Gmail refused it (p_certain = true: certainly not sent, may be retried) or the result is unknown (false: e.g. a
-- timeout; it stays claimed as 'uncertain' until reconciled).
create or replace function autopilot_send_failed(p_draft uuid, p_error text, p_certain boolean)
returns void language sql as $$
  update outreach_drafts
     set send_claimed_at = case when p_certain then null else send_claimed_at end,
         delivery = case when p_certain then 'failed' else 'uncertain' end,
         send_error = left(p_error, 500)
   where id = p_draft and status = 'approved'
$$;

-- the usual call: Gmail refused it, so it certainly did not go out
create or replace function autopilot_send_failed(p_draft uuid, p_error text) returns void language sql as $$
  select autopilot_send_failed(p_draft, p_error, true)
$$;

-- What to look for in Gmail Sent before anything else is sent.
create or replace function autopilot_reconcile_list(p_client uuid) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('draft_id', u.id, 'to_email', c.email, 'subject', u.subject, 'purpose', u.purpose,
                    'gmail_thread_id', u.gmail_thread_id, 'attempted_at', u.attempted_at, 'delivery', u.delivery,
                    'error', u.send_error) order by u.attempted_at), '[]')
    from autopilot_unconfirmed(p_client) u join contacts c on c.id = u.contact_id
$$;

-- Not in Gmail Sent: release it (it may be sent again later, through the normal checks).
create or replace function autopilot_reconcile_not_sent(p_draft uuid, p_note text default null) returns void language sql as $$
  update outreach_drafts set send_claimed_at = null, delivery = 'failed',
         send_error = left(coalesce(p_note, 'Not found in Gmail Sent when reconciled'), 500)
   where id = p_draft and status = 'approved' and delivery in ('attempted','uncertain')
$$;

-- ─────────────────────────── answers and time proposals ───────────────────────────
create or replace function monitor_mark_answer_sent(p_draft uuid, p_gmail_message_id text, p_by text default 'reply-monitor')
returns void language plpgsql as $$
declare d outreach_drafts; iid uuid;
begin
  if coalesce(trim(p_gmail_message_id), '') = '' then raise exception 'The Gmail message id is required.'; end if;
  select * into d from outreach_drafts where id = p_draft for update;
  if not found then raise exception 'No draft %', p_draft; end if;
  if d.status = 'sent' then return; end if;
  if d.status = 'pending_review' then   -- he sent it himself from Gmail: that was the approval
    update outreach_drafts set status = 'approved', reviewed_by = 'santiago (sent from Gmail)' where id = p_draft;
  end if;
  insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, subject, body,
                            external_id, metadata)
  values (d.client_id, d.campaign_id, draft_company(d), d.contact_id, 'email', 'outbound', 'sent', 'staff', d.subject, d.body,
          'gmail:' || p_gmail_message_id,
          jsonb_build_object('draft_id', d.id, 'gmail_thread_id', d.gmail_thread_id, 'purpose', 'reply', 'by', p_by))
  on conflict (channel, external_id) do update set metadata = interactions.metadata
  returning id into iid;
  update outreach_drafts set status = 'sent', delivery = 'sent', sent_at = now(), confirmed_at = now(), sent_by = p_by,
         message_id = p_gmail_message_id, interaction_id = iid
   where id = p_draft;
end $$;

-- The line between what the autopilot may send on its own (scheduling) and what Santiago approves (anything
-- substantive). Run before sending a time proposal, confirmation or nudge; anything returned → do not send it,
-- save it as an answer for Santiago (monitor_add_answer) instead.
create or replace function autopilot_scheduling_check(p_client uuid, p_body text) returns text[] language plpgsql stable as $$
declare b text := lower(coalesce(p_body, '')); out text[] := '{}'; s autopilot_settings; o ops_state;
begin
  select * into s from autopilot_settings where client_id = p_client;
  select * into o from ops_state limit 1;
  if s.paused or o.paused then out := array_append(out, 'Sending is paused.'); end if;
  if b ~ '(\$|\mmxn\M|\musd\M|pesos|d[oó]lares|dollars|precio|price|cotizaci|\mquote|descuento|discount|%)' then
    out := array_append(out, 'Talks about prices or discounts.');
  end if;
  if b ~ '(m[ií]nimo|minimum|\mmoq\M|pedido m|tr[aá]iler|contenedor|container)' then
    out := array_append(out, 'Talks about minimums or volumes.');
  end if;
  if b ~ '(plazo|lead time|tiempo de entrega|d[ií]as h[aá]biles de entrega|entrega en|delivery|env[ií]o|flete|freight|fob)' then
    out := array_append(out, 'Talks about lead times or delivery.');
  end if;
  if b ~ '(cr[eé]dito|credit|anticipo|deposit|pago|payment|carta de cr[eé]dito|letter of credit|t[eé]rminos|terms)' then
    out := array_append(out, 'Talks about payment terms.');
  end if;
  if b ~ '(exclusiv|garant[ií]a|warranty|certific|fsc|muestra|sample|cat[aá]logo|catalog)' then
    out := array_append(out, 'Talks about samples, catalogue, certifications, warranty or exclusivity.');
  end if;
  if b ~* 'https?://' then out := array_append(out, 'Has a link.'); end if;
  return out;
end $$;

-- Log a time proposal / booking confirmation / nudge after Gmail accepted it (counts against the cap).
create or replace function autopilot_log_scheduling(p_handoff uuid, p_message_id text, p_thread_id text, p_subject text,
                                                    p_body text, p_type text) returns uuid language plpgsql as $$
declare h meeting_handoffs; iid uuid; why text[];
begin
  if coalesce(trim(p_message_id), '') = '' then raise exception 'The Gmail message id is required.'; end if;
  if p_type not in ('time_proposal','booking_confirmation','nudge') then raise exception 'Unknown type %', p_type; end if;
  select * into h from meeting_handoffs where id = p_handoff;
  if h.id is null then raise exception 'No meeting brief %', p_handoff; end if;
  why := autopilot_scheduling_check(h.client_id, p_body);
  insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, subject, body,
                            external_id, metadata)
  values (h.client_id, h.campaign_id, h.company_id, h.contact_id, 'email', 'outbound', 'sent', 'bot', p_subject, p_body,
          'gmail:' || p_message_id,
          jsonb_build_object('by', 'autopilot', 'type', p_type, 'handoff_id', h.id, 'gmail_thread_id', p_thread_id,
                             'gmail_message_id', p_message_id, 'scheduling_check', to_jsonb(why)))
  on conflict (channel, external_id) do update set metadata = interactions.metadata
  returning id into iid;
  if cardinality(why) > 0 then
    insert into alerts (client_id, severity, kind, message, refs)
    values (h.client_id, 'urgent', 'scheduling_rule_broken',
            'An automatic scheduling email went out with content Santiago should approve: ' || array_to_string(why, ' '),
            jsonb_build_object('interaction_id', iid, 'handoff_id', h.id));
  end if;
  return iid;
end $$;

-- ─────────────────────────── the pause switch ───────────────────────────
create or replace function ops_pause(p_reason text, p_by text) returns jsonb language plpgsql as $$
begin
  update ops_state set paused = true, pause_reason = coalesce(nullif(trim(p_reason), ''), 'paused'), paused_at = now(),
                       paused_by = p_by, updated_at = now();
  insert into alerts (client_id, severity, kind, message, refs)
  select c.id, 'warning', 'ops_paused', 'All sending paused by ' || coalesce(p_by, '?') || ': ' || coalesce(p_reason, ''), '{}'
    from clients c where not c.is_demo and c.status = 'active';
  return (select to_jsonb(o) from ops_state o);
end $$;

create or replace function ops_resume(p_by text) returns jsonb language plpgsql as $$
begin
  update ops_state set paused = false, pause_reason = null, paused_at = null, paused_by = p_by, updated_at = now();
  update alerts set status = 'resolved' where kind = 'ops_paused' and status <> 'resolved';
  return (select to_jsonb(o) from ops_state o);
end $$;

-- ─────────────────────────── health check that raises alerts ───────────────────────────
-- Run by every scheduled task (and safe to run any time). Opens one alert per problem per day; returns the list.
create or replace function ops_check(p_client uuid) returns jsonb language plpgsql as $$
declare
  s   autopilot_settings;
  loc timestamp;
  wk  boolean;
  probs jsonb := '[]';
  n   int;
  p   jsonb;
  last_mon timestamptz := autopilot_monitor_last_run();
begin
  select * into s from autopilot_settings where client_id = p_client;
  if s.client_id is null then return '[]'; end if;
  loc := now() at time zone s.timezone;
  wk := extract(isodow from loc)::int = any (s.send_days) and loc::date >= s.sends_start_on;

  if wk and extract(hour from loc) between 9 and 20 and (last_mon is null or last_mon < now() - make_interval(mins => s.monitor_max_minutes)) then
    probs := probs || jsonb_build_object('kind', 'reply_monitor_stale', 'severity', 'urgent',
      'message', 'The reply monitor has not run since ' || coalesce(to_char(last_mon at time zone s.timezone, 'DD Mon HH24:MI'), 'ever')
                 || '. Automatic sending is held until it runs again.');
  end if;
  select count(*) into n from autopilot_unconfirmed(p_client);
  if n > 0 then
    probs := probs || jsonb_build_object('kind', 'unconfirmed_sends', 'severity', 'warning',
      'message', n || ' email(s) may or may not have gone out. Nothing more is sent until they are checked in Gmail Sent.');
  end if;
  if autopilot_sent_today(p_client) > autopilot_cap_today(p_client) then
    probs := probs || jsonb_build_object('kind', 'cap_exceeded', 'severity', 'urgent',
      'message', 'Today ' || autopilot_sent_today(p_client) || ' emails left the mailbox; the cap is ' || autopilot_cap_today(p_client) || '.');
  end if;
  select count(*) into n from outreach_drafts d
   where d.client_id = p_client and d.channel = 'email' and d.status = 'sent' and d.sent_at > now() - interval '7 days'
     and d.interaction_id is null
     and not exists (select 1 from interactions i where i.metadata->>'draft_id' = d.id::text and i.direction = 'outbound');
  if n > 0 then
    probs := probs || jsonb_build_object('kind', 'send_not_logged', 'severity', 'warning',
      'message', n || ' sent email(s) have no activity record.');
  end if;
  if wk and extract(hour from loc) >= 9 and not exists (
       select 1 from autopilot_runs r where r.client_id = p_client and draft_local_day(p_client, r.started_at) = loc::date
          and r.stage in ('research','draft','followup','guard')) then
    probs := probs || jsonb_build_object('kind', 'morning_run_missing', 'severity', 'warning',
      'message', 'The morning outreach run has not logged anything today.');
  end if;
  if wk and (extract(hour from loc) * 60 + extract(minute from loc)) >= 600 and not exists (
       select 1 from autopilot_runs r where r.client_id = p_client and draft_local_day(p_client, r.started_at) = loc::date
          and r.stage = 'send') then
    probs := probs || jsonb_build_object('kind', 'send_run_missing', 'severity', 'warning',
      'message', 'No send run has logged anything today (first one is due at 9:20).');
  end if;
  if wk and (extract(hour from loc) * 60 + extract(minute from loc)) >= 1170 and not exists (
       select 1 from autopilot_runs r where r.client_id = p_client and draft_local_day(p_client, r.started_at) = loc::date
          and r.stage = 'summary') then
    probs := probs || jsonb_build_object('kind', 'summary_missing', 'severity', 'info',
      'message', 'The end-of-day summary has not run today.');
  end if;
  select count(*) into n from autopilot_runs r
   where r.client_id = p_client and r.started_at > now() - interval '24 hours'
     and (r.ok = false or (r.finished_at is null and r.started_at < now() - interval '1 hour'));
  if n > 0 then
    probs := probs || jsonb_build_object('kind', 'run_failed', 'severity', 'warning',
      'message', n || ' scheduled run(s) in the last 24 hours failed or never finished.');
  end if;

  for p in select * from jsonb_array_elements(probs) loop
    if not exists (select 1 from alerts a where a.client_id = p_client and a.kind = p->>'kind' and a.status <> 'resolved'
                     and draft_local_day(p_client, a.created_at) = loc::date) then
      insert into alerts (client_id, severity, kind, message, refs)
      values (p_client, (p->>'severity')::severity, p->>'kind', p->>'message', jsonb_build_object('by', 'ops_check'));
    end if;
  end loop;
  -- problems that went away close their alert
  update alerts a set status = 'resolved'
   where a.client_id = p_client and a.status <> 'resolved' and a.refs->>'by' = 'ops_check'
     and a.kind not in (select x->>'kind' from jsonb_array_elements(probs) x);
  return probs;
end $$;

-- ─────────────────────────── reply matching and filing ───────────────────────────
create or replace function monitor_match(p_from text, p_thread text)
returns table (draft_id uuid, contact_id uuid, client_id uuid, company_id uuid, campaign_id uuid, matched_by text)
language sql stable as $$
  (select d.id, d.contact_id, d.client_id, coalesce(d.company_id, c.company_id), d.campaign_id,
          case when p_from is null or email_key(c.email) = email_key(p_from) then 'thread' else 'thread_other_sender' end
     from outreach_drafts d join contacts c on c.id = d.contact_id
    where p_thread is not null and d.gmail_thread_id = p_thread and d.channel = 'email' and d.status = 'sent'
    order by d.sent_at desc nulls last limit 1)
  union all
  (select d.id, d.contact_id, d.client_id, coalesce(d.company_id, c.company_id), d.campaign_id, 'address'
     from outreach_drafts d join contacts c on c.id = d.contact_id
    where email_key(c.email) = email_key(p_from) and d.channel = 'email' and d.status = 'sent'
    order by d.sent_at desc nulls last limit 1)
  union all
  (select d.id, d.contact_id, d.client_id, coalesce(d.company_id, c.company_id), d.campaign_id, 'domain'
     from outreach_drafts d join contacts c on c.id = d.contact_id
    where not is_freemail(split_part(email_key(p_from), '@', 2))
      and split_part(email_key(c.email), '@', 2) = split_part(email_key(p_from), '@', 2)
      and d.channel = 'email' and d.status = 'sent'
    order by d.sent_at desc nulls last limit 1)
  union all
  (select d.id, d.contact_id, d.client_id, coalesce(d.company_id, c.company_id), d.campaign_id, 'alias'
     from company_domains cd
     join contacts c on c.company_id = cd.company_id
     join outreach_drafts d on d.contact_id = c.id
    where cd.domain = split_part(email_key(p_from), '@', 2) and d.channel = 'email' and d.status = 'sent'
    order by d.sent_at desc nulls last limit 1)
  limit 1
$$;

-- File one incoming email. Input (jsonb):
--   gmail_message_id, gmail_thread_id, from, subject, body, received_at,
--   category: interested | question | not_now | wrong_person | not_interested | unsubscribe | out_of_office | bounce | other
--   summary (one line), referral (who they pointed us to), bounced_address (bounces), resume_on (out of office: the
--   date they are back, if the auto-reply says)
-- A reply is tied to a person only when it comes from that person's address (or their thread, from their address).
-- Anything else (same company domain, an alias domain, a colleague answering in the thread) is filed against the
-- company, goes to identity review, and holds the company; nothing is done to the guessed person.
create or replace function monitor_file_email(p jsonb) returns jsonb language plpgsql as $$
declare
  cat  text := coalesce(nullif(p->>'category', ''), 'other');
  ext  text := 'gmail:' || (p->>'gmail_message_id');
  frm  text := lower(trim(p->>'from'));
  m    record;
  who  record;
  s    autopilot_settings;
  iid  uuid;
  rid  uuid;
  res  text;
  addr text;
  label text;
  sure boolean;
  back date;
begin
  if coalesce(p->>'gmail_message_id', '') = '' then raise exception 'gmail_message_id is required'; end if;
  if cat not in ('interested','question','not_now','wrong_person','not_interested','unsubscribe','out_of_office','bounce','other') then
    raise exception 'Unknown category %', cat;
  end if;
  if exists (select 1 from interactions where channel = 'email' and external_id = ext) then
    return jsonb_build_object('status', 'duplicate');
  end if;

  if cat = 'bounce' then
    addr := nullif(trim(p->>'bounced_address'), '');
    select * into m from monitor_match(addr, p->>'gmail_thread_id');
    if m.contact_id is null or m.matched_by not in ('address','thread') then
      return jsonb_build_object('status', 'unmatched', 'why', 'bounce for an address we did not write to');
    end if;
    sure := true;
  else
    select * into m from monitor_match(frm, p->>'gmail_thread_id');
    if m.contact_id is null then
      return jsonb_build_object('status', 'unmatched', 'why', 'not a reply to our outreach');
    end if;
    sure := m.matched_by in ('address','thread');
  end if;
  select * into s from autopilot_settings where client_id = m.client_id;

  select trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as name, c.email, co.name as company
    into who from contacts c left join companies co on co.id = coalesce(m.company_id, c.company_id) where c.id = m.contact_id;
  label := case when sure then concat_ws(', ', nullif(who.name, ''), who.company) else concat_ws(', ', frm, who.company) end;

  insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor,
                            subject, body, external_id, occurred_at, metadata)
  values (m.client_id, m.campaign_id, m.company_id, case when sure then m.contact_id end, 'email', 'inbound',
          (case cat when 'bounce' then 'bounce' when 'out_of_office' then 'note' else 'reply' end)::interaction_kind,
          (case when cat = 'bounce' then 'system' else 'buyer' end)::actor,
          p->>'subject', left(p->>'body', 20000), ext, coalesce((p->>'received_at')::timestamptz, now()),
          jsonb_strip_nulls(jsonb_build_object('category', cat, 'summary', p->>'summary', 'referral', nullif(p->>'referral', ''),
            'from', frm, 'gmail_thread_id', p->>'gmail_thread_id', 'gmail_message_id', p->>'gmail_message_id',
            'matched_by', m.matched_by, 'draft_id', m.draft_id, 'by', 'reply-monitor',
            'identity', case when sure then 'matched' else 'uncertain' end,
            'guessed_contact_id', case when not sure then m.contact_id end,
            'resume_on', nullif(p->>'resume_on', ''))))
  on conflict (channel, external_id) do nothing
  returning id into iid;
  if iid is null then return jsonb_build_object('status', 'duplicate'); end if;

  if not sure then
    insert into identity_reviews (client_id, interaction_id, from_address, company_id, guessed_contact_id, matched_by, category)
    values (m.client_id, iid, frm, m.company_id, m.contact_id, m.matched_by, cat) returning id into rid;
    if cat = 'unsubscribe' and frm is not null then
      insert into suppressions (value, reason, added_by) values (frm, 'Asked to stop (reply from an address we had not written to)', 'reply-monitor')
      on conflict (value) do nothing;
    end if;
    if cat <> 'out_of_office' then
      insert into alerts (client_id, severity, kind, message, refs)
      values (m.client_id, (case when cat in ('interested','question','wrong_person') then 'urgent' else 'info' end)::severity, 'identity_review',
              frm || ' (' || coalesce(who.company, 'unknown company') || ') replied (' || replace(cat, '_', ' ') || '): '
              || coalesce(p->>'summary', '') || ' We wrote to ' || coalesce(nullif(who.name, ''), who.email)
              || ' there; say whether this is the same person, someone else, or unrelated. Outreach to this company waits.',
              jsonb_build_object('identity_review_id', rid, 'interaction_id', iid, 'guessed_contact_id', m.contact_id));
    end if;
    return jsonb_build_object('status', 'filed', 'result', 'identity_review', 'interaction_id', iid, 'identity_review_id', rid,
                              'client_id', m.client_id, 'company', who.company, 'from', frm, 'matched_by', m.matched_by,
                              'category', cat);
  end if;

  if cat = 'bounce' then
    update contacts set email_status = 'invalid' where id = m.contact_id;
    update outreach_drafts set status = 'cancelled', review_note = coalesce(review_note, 'Address bounced')
     where contact_id = m.contact_id and channel = 'email' and status in ('pending_review','approved') and send_claimed_at is null;
    insert into alerts (client_id, severity, kind, message, refs)
    values (m.client_id, 'warning', 'email_bounced', 'Email to ' || coalesce(label, addr) || ' (' || coalesce(addr, who.email)
            || ') bounced. The address is marked invalid and its unsent emails are cancelled.',
            jsonb_build_object('contact_id', m.contact_id, 'interaction_id', iid));
    res := 'bounce';
  elsif cat = 'out_of_office' then
    -- follow-ups wait until the day after they are back (a week if the auto-reply gives no date)
    back := coalesce(nullif(p->>'resume_on', '')::date + 1, current_date + 7);
    update contacts set snoozed_until = greatest(coalesce(snoozed_until, now()), back::timestamptz),
                        snooze_reason = 'out of office'
     where id = m.contact_id;
    res := 'out_of_office';
  else
    res := apply_reply(iid);
    if cat = 'not_now' then
      update contacts set snoozed_until = greatest(coalesce(snoozed_until, now()), now() + make_interval(days => coalesce(s.not_now_days, 60))),
                          snooze_reason = 'said not now'
       where id = m.contact_id;
    end if;
    insert into alerts (client_id, severity, kind, message, refs)
    values (m.client_id, (case when cat in ('interested','question') then 'urgent' else 'info' end)::severity, 'buyer_replied',
            coalesce(label, frm) || ' replied (' || replace(cat, '_', ' ') || '): ' || coalesce(p->>'summary', '')
            || coalesce(' They suggested: ' || nullif(p->>'referral', '') || '.', ''),
            jsonb_build_object('contact_id', m.contact_id, 'interaction_id', iid));
  end if;

  return jsonb_build_object('status', 'filed', 'result', res, 'interaction_id', iid, 'contact_id', m.contact_id,
                            'client_id', m.client_id, 'contact', nullif(who.name, ''), 'company', who.company,
                            'email', who.email, 'matched_by', m.matched_by, 'category', cat);
end $$;

-- Santiago (or a run he asked) settles an identity review:
--   same_person   it was the person we wrote to → the reply is applied to them as usual
--   other_person  a different person (pass their contact id; add them first if new) → applied to that person
--   unrelated     nothing to do with our outreach → the company hold lifts
create or replace function identity_resolve(p_review uuid, p_decision text, p_contact uuid default null, p_by text default 'santiago')
returns text language plpgsql as $$
declare r identity_reviews; who uuid; res text := 'resolved';
begin
  select * into r from identity_reviews where id = p_review for update;
  if r.id is null then raise exception 'No identity review %', p_review; end if;
  if r.status <> 'open' then return 'already ' || r.status; end if;
  if p_decision not in ('same_person','other_person','unrelated') then raise exception 'Unknown decision %', p_decision; end if;
  who := case p_decision when 'same_person' then coalesce(p_contact, r.guessed_contact_id) when 'other_person' then p_contact end;
  if p_decision = 'other_person' and who is null then raise exception 'Pass the contact id of the person who wrote.'; end if;
  update identity_reviews set status = p_decision, resolved_contact_id = who, resolved_by = p_by, resolved_at = now() where id = p_review;
  if p_decision = 'unrelated' then
    update interactions set metadata = metadata || '{"identity":"unrelated"}' where id = r.interaction_id;
  else
    update interactions set contact_id = who, metadata = metadata || '{"identity":"confirmed"}' where id = r.interaction_id;
    if (select kind from interactions where id = r.interaction_id) = 'reply' then res := apply_reply(r.interaction_id); end if;
  end if;
  update alerts set status = 'resolved' where kind = 'identity_review' and refs->>'identity_review_id' = p_review::text;
  return res;
end $$;

-- Follow-ups respect the snooze (out of office) as well as everything they respected before.
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
     and (c.snoozed_until is null or c.snoozed_until <= now())
     and not exists (select 1 from interactions i where i.contact_id = f.contact_id and i.direction = 'inbound'
                       and i.kind in ('reply','bounce','unsubscribe'))
     and not exists (select 1 from meeting_handoffs h where h.contact_id = f.contact_id and h.client_id = p_client)
     and not exists (select 1 from outreach_drafts x where x.contact_id = f.contact_id and x.client_id = p_client
                       and x.channel = 'email' and x.step = ls.step + 1 and x.status <> 'rejected')
$$;

-- ─────────────────────────── WhatsApp opt-in ───────────────────────────
create or replace function record_whatsapp_opt_in(p_contact uuid, p_source text, p_evidence text, p_by text) returns void
language plpgsql as $$
begin
  if p_source not in ('buyer_wrote_first','asked_on_call','asked_by_email','form') then
    raise exception 'Opt-in source must be buyer_wrote_first, asked_on_call, asked_by_email or form.';
  end if;
  if coalesce(trim(p_evidence), '') = '' then raise exception 'Say where the opt-in can be checked.'; end if;
  update contacts set whatsapp_opt_in_at = now(), whatsapp_opt_in_source = p_source, whatsapp_opt_in_evidence = left(p_evidence, 500),
                      whatsapp_opt_in_by = p_by, whatsapp_opt_out_at = null
   where id = p_contact;
  if not found then raise exception 'No contact %', p_contact; end if;
end $$;

-- By-hand rules for the phone app: everything draft_blockers checks, plus the account holds, the global pause,
-- the WhatsApp opt-in, no WhatsApp after email, and no second message on the same channel. A message that was
-- opened in the app but not confirmed ('prepared') counts as possibly sent.
create or replace function phone_blockers(d outreach_drafts) returns text[] language plpgsql stable security definer
set search_path = public as $$
declare out text[] := coalesce(draft_blockers(d), '{}') || account_blockers(d); k text := phone_kind(d); co uuid; c contacts;
begin
  if k not in ('whatsapp', 'linkedin') then return out; end if;
  select * into c from contacts where id = d.contact_id;
  co := coalesce(d.company_id, c.company_id);
  if coalesce((select paused from ops_state limit 1), false) then
    out := array_append(out, 'All sending is paused: ' || coalesce((select pause_reason from ops_state limit 1), '') || '.');
  end if;
  if k = 'whatsapp' then
    if c.whatsapp_opt_in_at is null or c.whatsapp_opt_out_at is not null then
      out := array_append(out, 'No WhatsApp opt-in recorded for this buyer.');
    end if;
    if exists (select 1 from outreach_drafts e join contacts c2 on c2.id = e.contact_id
               where phone_kind(e) = 'email' and e.status in ('approved', 'sent')
                 and (e.contact_id = d.contact_id or (co is not null and coalesce(e.company_id, c2.company_id) = co)))
    or exists (select 1 from interactions i where i.channel = 'email' and i.direction = 'outbound'
                 and (i.contact_id = d.contact_id or (co is not null and i.company_id = co))) then
      out := array_append(out, 'We already emailed this company, so no WhatsApp (your rule).');
    end if;
  end if;
  if exists (select 1 from interactions i
             where i.contact_id = d.contact_id and i.direction = 'outbound'
               and i.channel::text = case k when 'whatsapp' then 'whatsapp' else 'linkedin' end
               and coalesce(i.metadata->>'draft_id', '') <> d.id::text)
  or exists (select 1 from outreach_drafts p where p.contact_id = d.contact_id and p.id <> d.id
               and phone_kind(p) = k and p.delivery in ('prepared','sent')) then
    out := array_append(out, 'Already messaged (or opened to message) on ' || case k when 'whatsapp' then 'WhatsApp' else 'LinkedIn' end || '.');
  end if;
  return out;
end $$;

-- Phone app actions on a LinkedIn note / WhatsApp:
--   'opened'    the app opened LinkedIn/WhatsApp with the text → prepared (not sent; counts as possibly sent)
--   'confirmed' Santiago tapped "Sent" after sending it → sent, logged
--   'not_sent'  he opened it but did not send → back to approved
--   'skip'      cancel the draft
--   'sent'      old app version: treated as 'opened'
create or replace function phone_mark(p_id uuid, p_op text, p_body text default null) returns text
language plpgsql security definer set search_path = public as $$
declare me staff := phone_staff(); d outreach_drafts; k text; ch channel; bl text[]; iid uuid; op text := p_op;
begin
  if op = 'sent' then op := 'opened'; end if;
  select * into d from outreach_drafts where id = p_id for update;
  if d.id is null or d.status not in ('pending_review','approved') then raise exception 'This one is already done.'; end if;
  k := phone_kind(d);
  if k = 'email' then raise exception 'Emails go out through the mailbox: approve them instead.'; end if;
  if op = 'skip' then
    update outreach_drafts set status = 'cancelled', review_note = 'Skipped by ' || me.name, reviewed_by = me.email where id = p_id;
    return 'skipped';
  end if;
  if op = 'not_sent' then
    update outreach_drafts set delivery = 'not_sent', prepared_at = null where id = p_id and delivery = 'prepared';
    return 'not_sent';
  end if;
  if op not in ('opened','confirmed') then raise exception 'Unknown action.'; end if;
  if d.delivery <> 'prepared' then
    bl := phone_blockers(d);
    if cardinality(bl) > 0 then raise exception 'Not allowed yet: %', array_to_string(bl, ' '); end if;
  end if;
  if d.status = 'pending_review' then
    update outreach_drafts set status = 'approved', reviewed_by = me.email, reviewed_at = now(),
                               body = coalesce(nullif(trim(p_body), ''), body)
     where id = p_id;
  end if;
  if op = 'opened' then
    update outreach_drafts set delivery = 'prepared', prepared_at = now(), sent_by = me.email where id = p_id;
    return 'prepared';
  end if;
  ch := case k when 'whatsapp' then 'whatsapp' when 'call' then 'call' when 'linkedin' then 'linkedin' else d.channel::text end::channel;
  insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, body, metadata)
  values (d.client_id, d.campaign_id, draft_company(d), d.contact_id, ch, 'outbound', (case when k = 'call' then 'call' else 'sent' end)::interaction_kind,
          'staff', coalesce(nullif(trim(p_body), ''), d.body),
          jsonb_build_object('draft_id', d.id, 'sent_by', me.email, 'by_hand', true, 'confirmed', true,
                             'prepared_at', d.prepared_at))
  returning id into iid;
  update outreach_drafts set status = 'sent', delivery = 'sent', sent_at = now(), confirmed_at = now(), sent_by = me.email,
         interaction_id = iid
   where id = p_id;
  if d.campaign_id is not null then
    update campaign_targets set status = 'contacted', updated_at = now()
     where campaign_id = d.campaign_id and contact_id = d.contact_id and status = 'queued';
  end if;
  return 'sent';
end $$;

-- Phone app queue: as before, plus how far each by-hand message got (prepared = opened, not yet confirmed).
create or replace function phone_queue() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me staff := phone_staff();
begin
  return coalesce((select jsonb_agg(q order by q.sort, q.created_at) from (
    select d.id, phone_kind(d) as kind, d.status::text as status, d.subject, d.body, d.step, d.purpose, d.score,
           d.grade_feedback, d.created_at, d.reviewed_at, cl.name as client,
           nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as contact,
           c.title, co.name as company, c.email, c.linkedin_url, phone_number(d, c) as number,
           phone_blockers(d) as blockers, d.delivery, d.prepared_at, c.id as contact_id,
           (c.whatsapp_opt_in_at is not null and c.whatsapp_opt_out_at is null) as whatsapp_opt_in,
           case when d.delivery = 'prepared' then 0 when phone_kind(d) = 'email' then 2 else 1 end as sort
    from outreach_drafts d
    join contacts c on c.id = d.contact_id
    join clients cl on cl.id = d.client_id
    left join companies co on co.id = coalesce(d.company_id, c.company_id)
    where not cl.is_demo and (d.status = 'pending_review' or (d.status = 'approved' and phone_kind(d) <> 'email'))
    limit 200) q), '[]');
end $$;

-- Phone app: record that a buyer agreed to WhatsApp.
create or replace function phone_opt_in(p_contact uuid, p_source text, p_evidence text) returns text
language plpgsql security definer set search_path = public as $$
declare me staff := phone_staff();
begin
  perform record_whatsapp_opt_in(p_contact, p_source, p_evidence, me.email);
  return 'recorded';
end $$;

-- Phone app: the state of the machine, and the pause switch.
create or replace function phone_ops() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me staff := phone_staff(); cl uuid;
begin
  select a.client_id into cl from autopilot_settings a join clients c on c.id = a.client_id where not c.is_demo order by c.created_at limit 1;
  return jsonb_build_object(
    'paused', (select paused from ops_state limit 1), 'pause_reason', (select pause_reason from ops_state limit 1),
    'paused_at', (select paused_at from ops_state limit 1), 'paused_by', (select paused_by from ops_state limit 1),
    'autopilot_paused', (select paused from autopilot_settings where client_id = cl),
    'autopilot_pause_reason', (select pause_reason from autopilot_settings where client_id = cl),
    'monitor_last_run', autopilot_monitor_last_run(), 'monitor_fresh', autopilot_monitor_fresh(cl),
    'sent_today', autopilot_sent_today(cl), 'cap_today', autopilot_cap_today(cl),
    'unconfirmed', (select count(*) from autopilot_unconfirmed(cl)),
    'identity_reviews', (select count(*) from identity_reviews where status = 'open'));
end $$;

create or replace function phone_pause(p_on boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me staff := phone_staff();
begin
  if p_on then perform ops_pause(coalesce(nullif(trim(p_reason), ''), 'Paused from the phone'), me.email);
  else perform ops_resume(me.email); end if;
  return phone_ops();
end $$;

-- ─────────────────────────── copy checks now include the sales pack ───────────────────────────
-- autopilot_lint stays as it was; autopilot_approve and the send check add the sales-pack and account checks.
create or replace function autopilot_approve(p_draft uuid) returns text[] language plpgsql as $$
declare d outreach_drafts; why text[];
begin
  select * into d from outreach_drafts where id = p_draft for update;
  if d.id is null then return array['The draft no longer exists.']; end if;
  if d.status <> 'pending_review' then return '{}'; end if;
  why := autopilot_lint(d) || draft_blockers(d) || sales_pack_blockers(d) || account_blockers(d) || country_blockers(d);
  if cardinality(why) = 0 then
    update outreach_drafts set status = 'approved', reviewed_by = 'autopilot', review_note = 'Auto-approved: all checks passed'
     where id = p_draft;
  else
    update outreach_drafts set review_note = left('Autopilot held it: ' || array_to_string(why, ' '), 1000) where id = p_draft;
  end if;
  return why;
end $$;

-- ─────────────────────────── access ───────────────────────────
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('draft_lang','draft_company','draft_local_day','autopilot_sent_today','autopilot_sent_today_lang',
                'autopilot_monitor_last_run','autopilot_monitor_fresh','autopilot_unconfirmed','country_blockers','account_blockers',
                'sales_pack_blockers','autopilot_send_check','autopilot_why_not','autopilot_claim',
                'autopilot_mark_sent','autopilot_send_failed','autopilot_reconcile_list','autopilot_reconcile_not_sent',
                'monitor_mark_answer_sent','autopilot_scheduling_check','autopilot_log_scheduling','ops_pause','ops_resume',
                'ops_check','monitor_match','monitor_file_email','identity_resolve','autopilot_due_followups',
                'record_whatsapp_opt_in','phone_blockers','phone_mark','phone_queue','phone_opt_in','phone_ops','phone_pause','autopilot_approve') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
grant execute on function phone_mark(uuid, text, text), phone_queue(), phone_opt_in(uuid, text, text), phone_ops(), phone_pause(boolean, text)
  to authenticated;
revoke all on ops_state, company_domains, identity_reviews, sales_pack_items from anon, authenticated;
