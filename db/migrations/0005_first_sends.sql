-- SBM Partners · step 5: the first real sends.
--
--   Who we may email   each buyer has a country, a legal basis and a record of where their email came from;
--                      each country has an email rule that a person confirms (after a lawyer check).
--   The safety gate    send_blockers(draft) lists every reason a draft may not go out. The database refuses to
--                      approve or send a draft while that list is not empty, whatever screen or agent asks.
--   Stop means stop    stop_contact() and the suppression list end all outreach to a person, on every channel.
--   Sending            one mailbox with a daily cap and a sending window; the mailer sends approved emails
--                      slowly, one at a time, and never twice.
--   Fact sheets        an agent drafts a client's fact sheet from their catalog; it is used only once approved.
--   Follow-ups         each campaign says how many messages and how many days apart.
--
-- Safe to run once on a database that already has 0001 to 0004. It only adds things, and marks fact sheets
-- that already exist as approved so nothing that works today stops working.

-- ─────────────────────────── new agent roles ───────────────────────────
alter type agent_role add value if not exists 'onboarder';
alter type agent_role add value if not exists 'reply_sorter';

-- ─────────────────────────── buyers: where they are and why we may email them ───────────────────────────
alter table contacts add column if not exists country text
  check (country ~ '^[A-Z]{2}$');                                  -- ISO code (ES, FR, DE, GB, US…); empty = the company's
alter table contacts add column if not exists email_basis text not null default 'unknown'
  check (email_basis in ('unknown','consent','legitimate_interest','existing_customer'));
alter table contacts add column if not exists email_source text;    -- where the address came from: 'their website', 'trade show card'…
alter table contacts add column if not exists unsubscribe_token text not null
  default replace(gen_random_uuid()::text, '-', '');
alter table contacts add column if not exists stopped_at timestamptz;   -- when they asked us to stop
alter table contacts add column if not exists stop_reason text;
create unique index if not exists contacts_unsubscribe_token_idx on contacts(unsubscribe_token);

-- Addresses and whole domains we never write to, even if they are not buyers in our lists yet.
create table if not exists suppressions (
  value      text primary key check (value = lower(value) and value <> ''),   -- 'name@shop.com' or 'shop.com'
  reason     text not null,
  added_by   text not null default 'system',
  created_at timestamptz not null default now()
);
alter table suppressions enable row level security;

create or replace function is_suppressed(p_email text) returns boolean language sql stable as $$
  select p_email is not null and exists (
    select 1 from suppressions s
    where s.value = lower(trim(p_email)) or s.value = split_part(lower(trim(p_email)), '@', 2))
$$;

-- ─────────────────────────── email rules per country ───────────────────────────
-- cold_email: 'allowed'       business addresses may be emailed with a clear opt-out (legitimate interest)
--             'consent_only'  only buyers who agreed to hear from us, or existing customers
--             'blocked'       never cold-email this country
-- A rule only counts once a person has confirmed it (confirmed_at). Until then, nothing is sent there.
create table if not exists email_country_rules (
  country      text primary key check (country ~ '^[A-Z]{2}$'),
  name         text not null,
  cold_email   text not null check (cold_email in ('allowed','consent_only','blocked')),
  law          text not null,
  note         text,
  confirmed_by text,
  confirmed_at timestamptz,
  updated_at   timestamptz not null default now()
);
alter table email_country_rules enable row level security;

-- A cautious starting point, NOT legal advice. Each row must be checked with a lawyer and confirmed in the dashboard.
insert into email_country_rules (country, name, cold_email, law, note) values
  ('GB','United Kingdom','allowed','PECR, UK GDPR','Corporate addresses may get relevant B2B email with an easy opt-out. Sole traders and partnerships need consent.'),
  ('FR','France','allowed','CPCE L34-5, GDPR, CNIL guidance','B2B email allowed if it relates to the person''s job, with an easy opt-out.'),
  ('IE','Ireland','allowed','S.I. 336/2011, GDPR','Business addresses allowed with opt-out; check sole traders.'),
  ('US','United States','allowed','CAN-SPAM','Allowed with true sender, postal address and a working opt-out honoured within 10 business days.'),
  ('ES','Spain','consent_only','LSSI art. 21, GDPR','Commercial email generally needs prior consent, also to business addresses.'),
  ('DE','Germany','consent_only','UWG §7, GDPR','Prior express consent needed for email advertising, also B2B.'),
  ('AT','Austria','consent_only','TKG §174, GDPR','Prior consent needed, also B2B.'),
  ('IT','Italy','consent_only','Codice privacy art. 130, GDPR','Prior consent needed, also B2B.'),
  ('NL','Netherlands','consent_only','Telecommunicatiewet 11.7, GDPR','Consent needed for most B2B email; legal entities may differ. Check.'),
  ('PT','Portugal','consent_only','Lei 41/2004, GDPR','Check: rules for legal persons differ from individuals.'),
  ('BE','Belgium','consent_only','Code of Economic Law XII.13, GDPR','Check: exceptions for generic business addresses.')
on conflict (country) do nothing;

-- ─────────────────────────── clients: sender details and fact-sheet approval ───────────────────────────
alter table clients add column if not exists sender_name text;          -- the person emails come from
alter table clients add column if not exists sender_company text;       -- e.g. 'SBM Partners for Alder & Oak'
alter table clients add column if not exists postal_address text;       -- required in every email
alter table clients add column if not exists brief_draft jsonb;         -- fact sheet drafted by the Onboarder, waiting for you
alter table clients add column if not exists brief_source text;         -- the files it was drafted from
alter table clients add column if not exists brief_approved_at timestamptz;
alter table clients add column if not exists brief_approved_by text;
update clients set brief_approved_at = coalesce(brief_approved_at, now()), brief_approved_by = coalesce(brief_approved_by, 'existing')
 where brief <> '{}'::jsonb and brief_approved_at is null;

-- ─────────────────────────── campaigns: follow-up rhythm ───────────────────────────
alter table campaigns add column if not exists max_steps int not null default 3 check (max_steps between 1 and 5);
alter table campaigns add column if not exists followup_days int not null default 5 check (followup_days between 2 and 30);

-- ─────────────────────────── the mailbox ───────────────────────────
-- The password stays on the computer that sends (MAIL_PASSWORD in .env), never in the database.
create table if not exists mailboxes (
  id              uuid primary key default gen_random_uuid(),
  address         text not null unique check (address = lower(address)),
  display_name    text not null,
  daily_cap       int not null default 15 check (daily_cap between 0 and 200),
  send_from_hour  int not null default 9  check (send_from_hour between 0 and 23),
  send_until_hour int not null default 17 check (send_until_hour between 1 and 24),
  timezone        text not null default 'Europe/Madrid',
  min_gap_minutes int not null default 7 check (min_gap_minutes between 1 and 240),
  next_send_at    timestamptz,                      -- the mailer waits until then before the next email
  paused          boolean not null default false,
  imap_last_uid   bigint not null default 0,        -- replies already read
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
drop trigger if exists mailboxes_touch on mailboxes;
create trigger mailboxes_touch before update on mailboxes for each row execute function touch_updated_at();
alter table mailboxes enable row level security;

-- ─────────────────────────── drafts: sending state ───────────────────────────
alter table outreach_drafts add column if not exists mailbox_id uuid references mailboxes(id) on delete set null;
alter table outreach_drafts add column if not exists send_after timestamptz;        -- follow-ups wait until then
alter table outreach_drafts add column if not exists send_claimed_at timestamptz;   -- the mailer took it; never sent twice
alter table outreach_drafts add column if not exists sent_at timestamptz;
alter table outreach_drafts add column if not exists sent_by text;                 -- LinkedIn: the person who sent it
alter table outreach_drafts add column if not exists message_id text;              -- the email's Message-ID
alter table outreach_drafts add column if not exists send_error text;
alter table outreach_drafts add column if not exists in_reply_to text;             -- follow-ups thread under the first email
create index if not exists outreach_drafts_outbox_idx on outreach_drafts(reviewed_at)
  where status = 'approved' and channel = 'email' and send_claimed_at is null;

-- ─────────────────────────── the safety gate ───────────────────────────
-- Every reason this draft may not go out. Empty = it may be approved and sent.
create or replace function draft_blockers(d outreach_drafts) returns text[] language plpgsql stable as $$
declare
  c   contacts;
  cl  clients;
  ca  campaigns;
  r   email_country_rules;
  ctry text;
  out text[] := '{}';
begin
  select * into c from contacts where id = d.contact_id;
  select * into cl from clients where id = d.client_id;
  select * into ca from campaigns where id = d.campaign_id;

  if c.do_not_contact then out := array_append(out, 'The buyer asked us not to contact them.'); end if;
  if is_suppressed(c.email) then out := array_append(out, 'This address or its domain is on the do-not-contact list.'); end if;
  if cl.brief_approved_at is null then out := array_append(out, 'The client''s fact sheet is not approved yet.'); end if;
  if ca.id is not null and ca.status <> 'live' then out := array_append(out, 'The campaign is not live.'); end if;
  if d.step > 1 and exists (select 1 from interactions i where i.contact_id = d.contact_id and i.client_id = d.client_id
                              and i.direction = 'inbound' and i.kind in ('reply','unsubscribe','bounce')) then
    out := array_append(out, 'The buyer has already replied, so no automatic follow-up.');
  end if;
  if d.step > 1 and not exists (select 1 from outreach_drafts p where p.contact_id = d.contact_id and p.client_id = d.client_id
                                  and p.channel = d.channel and p.step = d.step - 1 and p.status = 'sent') then
    out := array_append(out, 'The previous message has not been sent yet.');
  end if;

  if d.channel = 'email' then
    if coalesce(trim(c.email), '') = '' then out := array_append(out, 'No email address.'); end if;
    if c.email_status = 'invalid' then out := array_append(out, 'The email address is invalid or bounced.'); end if;
    if coalesce(trim(c.email_source), '') = '' then
      out := array_append(out, 'Record where this email address came from (email source).');
    end if;
    if coalesce(trim(d.subject), '') = '' and d.step = 1 then out := array_append(out, 'The email has no subject.'); end if;
    if coalesce(trim(cl.sender_name), '') = '' or coalesce(trim(cl.postal_address), '') = '' then
      out := array_append(out, 'Add the sender name and postal address for this client (every email must show them).');
    end if;
    ctry := coalesce(c.country, (select co.country from companies co where co.id = c.company_id));
    if ctry is null then
      out := array_append(out, 'The buyer''s country is unknown.');
    else
      select * into r from email_country_rules where country = ctry;
      if not found then
        out := array_append(out, ('There is no email rule for ' || ctry || ' yet.'));
      elsif r.confirmed_at is null then
        out := array_append(out, ('The email rule for ' || r.name || ' has not been confirmed yet.'));
      elsif r.cold_email = 'blocked' then
        out := array_append(out, ('Email to ' || r.name || ' is switched off.'));
      elsif r.cold_email = 'consent_only' and c.email_basis not in ('consent','existing_customer') then
        out := array_append(out, (r.name || ' needs the buyer''s prior consent, and none is recorded.'));
      elsif c.email_basis = 'unknown' then
        out := array_append(out, 'Record the legal basis for emailing this buyer.');
      end if;
    end if;
  end if;
  return out;
end $$;

create or replace function send_blockers(p_draft uuid) returns text[] language sql stable as $$
  select coalesce((select draft_blockers(d) from outreach_drafts d where d.id = p_draft),
                  array['The draft no longer exists.'])
$$;

-- The draft guard from 0003, now with the safety gate. Approving or sending is refused while anything blocks it.
create or replace function outreach_drafts_guard() returns trigger language plpgsql as $$
declare why text[];
begin
  if new.status in ('approved','sent') and exists (select 1 from contacts where id = new.contact_id and do_not_contact) then
    raise exception 'This contact asked not to be contacted; the draft cannot be approved or sent.';
  end if;
  if new.status = 'sent' then
    if tg_op = 'INSERT' then
      raise exception 'A draft must be approved before it is sent.';
    elsif old.status not in ('approved','sent') then
      raise exception 'A draft must be approved before it is sent.';
    end if;
  end if;
  if tg_op = 'UPDATE' and new.status in ('approved','sent') and old.status is distinct from new.status then
    why := draft_blockers(new);
    if cardinality(why) > 0 then
      raise exception 'Not allowed yet: %', array_to_string(why, ' ');
    end if;
  end if;
  if tg_op = 'UPDATE' and old.status = 'sent' and new.status <> 'sent' then
    raise exception 'A sent message cannot be un-sent.';
  end if;
  if new.status in ('approved','rejected') and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    new.reviewed_at := coalesce(new.reviewed_at, now());
  end if;
  if new.status = 'sent' and new.sent_at is null then new.sent_at := now(); end if;
  return new;
end $$;

-- ─────────────────────────── stop means stop ───────────────────────────
-- Ends all outreach to one person, for every client and channel: marks them do-not-contact, adds their address
-- to the suppression list, cancels every unsent draft and logs it. Returns false if they were already stopped.
create or replace function stop_contact(p_contact uuid, p_reason text, p_by text default 'system')
returns boolean language plpgsql as $$
declare c contacts; first_time boolean;
begin
  select * into c from contacts where id = p_contact for update;
  if not found then return false; end if;
  first_time := not c.do_not_contact;
  update contacts set do_not_contact = true, stopped_at = coalesce(stopped_at, now()),
                      stop_reason = coalesce(stop_reason, p_reason)
   where id = p_contact;
  if c.email is not null then
    insert into suppressions (value, reason, added_by) values (lower(trim(c.email)), p_reason, p_by)
    on conflict (value) do nothing;
  end if;
  update outreach_drafts set status = 'cancelled', review_note = coalesce(review_note, 'Stopped: ' || p_reason)
   where contact_id = p_contact and status in ('pending_review','approved');
  update campaign_targets set status = 'do_not_contact', updated_at = now() where contact_id = p_contact;
  update tasks set status = 'cancelled', finished_at = now()
   where contact_id = p_contact and status = 'queued';
  if first_time then
    insert into interactions (client_id, contact_id, company_id, channel, direction, kind, actor, body, metadata)
    select distinct d.client_id, p_contact, c.company_id, 'email'::channel, 'inbound'::direction, 'unsubscribe'::interaction_kind,
           'buyer'::actor, p_reason, jsonb_build_object('by', p_by)
      from outreach_drafts d where d.contact_id = p_contact;
  end if;
  return first_time;
end $$;

-- The unsubscribe link in every email calls this with the buyer's private token.
create or replace function unsubscribe_by_token(p_token text) returns boolean language plpgsql as $$
declare cid uuid;
begin
  select id into cid from contacts where unsubscribe_token = p_token;
  if cid is null then return false; end if;
  perform stop_contact(cid, 'Used the unsubscribe link', 'unsubscribe link');
  return true;
end $$;

-- ─────────────────────────── views for the dashboard ───────────────────────────
-- Approved LinkedIn notes waiting for a person to send them by hand.
create or replace view v_linkedin_todo as
select d.id, d.reviewed_at, d.body, d.step, cl.name as client,
       trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as contact,
       c.title as contact_title, c.linkedin_url, co.name as company
from outreach_drafts d
join clients cl on cl.id = d.client_id
join contacts c on c.id = d.contact_id
left join companies co on co.id = d.company_id
where d.channel = 'linkedin' and d.status = 'approved'
order by d.reviewed_at;
alter view v_linkedin_todo set (security_invoker = true);
