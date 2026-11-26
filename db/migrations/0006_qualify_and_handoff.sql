-- SBM Partners · step 6: qualify each buyer before writing, and follow every conversation through to a meeting.
--
--   Qualification & Strategy  after research, the Strategist scores how well the buyer fits the client (0 to 100),
--                             decides pursue / nurture / disqualify, picks the pitch (what to lead with, which proof,
--                             which offer, likely objections) and the channel. Only "pursue" buyers get a first message.
--                             You can overrule it on the Buyers page.
--   Conversations             v_conversations shows where every buyer stands: follow-ups used and left, the next one
--                             due, their last reply and what it meant, and the next step.
--   Answers and check-ins     when a buyer is interested or asks a question, the Writer drafts the answer; when they
--                             say "not now", the campaign waits snooze_days and the Writer drafts one check-in.
--                             Every one of these still waits for your approval and passes the same safety gate.
--   Meeting handoff           an interested buyer becomes a meeting brief for you: what they want, product fit,
--                             the full contact history, what is still unclear, and next steps. You book it, and the
--                             meeting is logged, the deal opens and all automatic messages to that buyer stop.
--
-- Safe to run once on a database that already has 0001 to 0005. It only adds things, and replaces the safety gate
-- draft_blockers() from 0005 with a version that knows about qualification, answers, check-ins and meetings.
-- Every rule from 0005 still applies, with the same wording.

-- ─────────────────────────── new agent roles ───────────────────────────
alter type agent_role add value if not exists 'strategist';
alter type agent_role add value if not exists 'meeting_briefer';

-- ─────────────────────────── new kinds of task ───────────────────────────
alter table tasks drop constraint if exists tasks_kind_check;
alter table tasks add constraint tasks_kind_check check (kind in (
  'research_prospect', 'qualify_prospect', 'draft_outreach', 'draft_reply', 'prepare_handoff', 'write_report'));

-- ─────────────────────────── campaign settings ───────────────────────────
alter table campaigns add column if not exists min_fit_score int not null default 60
  check (min_fit_score between 0 and 100);                    -- buyers below this are not contacted
alter table campaigns add column if not exists snooze_days int not null default 60
  check (snooze_days between 7 and 365);                      -- after "not now", wait this long before one check-in

alter table campaign_targets add column if not exists snoozed_until timestamptz;   -- set when a buyer says "not now"

-- ─────────────────────────── qualification & strategy ───────────────────────────
create table if not exists prospect_strategies (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid not null references clients(id) on delete cascade,
  campaign_id      uuid not null references campaigns(id) on delete cascade,
  contact_id       uuid not null references contacts(id) on delete cascade,
  company_id       uuid references companies(id) on delete set null,
  task_id          uuid references tasks(id) on delete set null,
  research_task_id uuid references tasks(id) on delete set null,
  fit_score        int not null check (fit_score between 0 and 100),
  fit_breakdown    jsonb not null default '[]',      -- [{key, score 0-5, weight, why}]
  decision         text not null check (decision in ('pursue','nurture','disqualify')),
  reason           text not null,
  pitch_angle      text,                              -- the one reason this buyer should care
  lead_with        jsonb not null default '[]',       -- collections / products from the fact sheet to open with
  proof_points     jsonb not null default '[]',       -- facts from the fact sheet that back the pitch
  offer            text,                              -- the offer from the fact sheet that fits best
  objections       jsonb not null default '[]',       -- [{objection, answer}] with answers from the fact sheet
  first_ask        text,                              -- the one low-effort next step to ask for
  channel_plan     text not null check (channel_plan in ('email','email_and_linkedin','linkedin')),
  channel_reason   text,
  decided_by       text not null default 'strategist',  -- 'strategist' or the email of the person who overruled it
  decided_at       timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (campaign_id, contact_id)
);
drop trigger if exists prospect_strategies_touch on prospect_strategies;
create trigger prospect_strategies_touch before update on prospect_strategies for each row execute function touch_updated_at();
create index if not exists prospect_strategies_client_idx on prospect_strategies(client_id, decision);
alter table prospect_strategies enable row level security;

-- ─────────────────────────── drafts: what each message is for ───────────────────────────
--   first      the first message to a buyer
--   follow_up  a follow-up after no answer (counts toward the campaign's max_steps)
--   reply      our answer to something the buyer wrote
--   check_in   one message after the snooze, when the buyer said "not now"
alter table outreach_drafts add column if not exists purpose text
  check (purpose in ('first','follow_up','reply','check_in'));
alter table outreach_drafts add column if not exists reply_to_interaction_id uuid references interactions(id) on delete set null;
alter table outreach_drafts add column if not exists strategy_id uuid references prospect_strategies(id) on delete set null;
-- Label the drafts that already exist. The guard is switched off for this one update: it only fills in the new
-- column, and the guard would otherwise re-check old sent emails to buyers who have unsubscribed since.
alter table outreach_drafts disable trigger outreach_drafts_guard;
update outreach_drafts set purpose = case when step > 1 then 'follow_up' else 'first' end where purpose is null;
alter table outreach_drafts enable trigger outreach_drafts_guard;

create or replace function outreach_drafts_purpose() returns trigger language plpgsql as $$
begin
  if new.purpose is null then new.purpose := case when new.step > 1 then 'follow_up' else 'first' end; end if;
  return new;
end $$;
-- Triggers fire in name order, so the "a_" makes this run before outreach_drafts_guard checks the draft.
drop trigger if exists a_outreach_drafts_purpose on outreach_drafts;
create trigger a_outreach_drafts_purpose before insert or update on outreach_drafts
  for each row execute function outreach_drafts_purpose();

-- ─────────────────────────── meeting handoffs ───────────────────────────
--   ready          the brief is ready and waiting for you
--   booked         you set a date; the meeting is logged and the deal is open
--   held           the meeting happened
--   no_show        the buyer did not come
--   not_qualified  you decided it is not a real opportunity (follow-ups stay off)
--   cancelled      called off
create table if not exists meeting_handoffs (
  id                   uuid primary key default gen_random_uuid(),
  client_id            uuid not null references clients(id) on delete cascade,
  campaign_id          uuid references campaigns(id) on delete set null,
  contact_id           uuid not null references contacts(id) on delete cascade,
  company_id           uuid references companies(id) on delete set null,
  task_id              uuid references tasks(id) on delete set null,
  reply_interaction_id uuid references interactions(id) on delete set null,   -- the reply that showed interest
  strategy_id          uuid references prospect_strategies(id) on delete set null,
  status               text not null default 'ready'
                       check (status in ('ready','booked','held','no_show','not_qualified','cancelled')),
  qualified            boolean not null,                -- the Meeting briefer's verdict; you decide
  checks               jsonb not null default '[]',     -- [{key, status yes|unclear|no, evidence}]
  interest             text not null,                   -- what the buyer wants, in plain words
  product_fit          text not null,                   -- which of the client's products fit, and why
  contact_history      jsonb not null default '[]',     -- every message both ways, oldest first (built from the log)
  open_questions       jsonb not null default '[]',
  next_steps           jsonb not null default '[]',
  agenda               jsonb not null default '[]',
  body                 text not null,                   -- the whole brief, ready to read
  meeting_at           timestamptz,
  meeting_note         text,                            -- link, place, who joins
  owner                text,                            -- who takes the meeting
  outcome_note         text,
  deal_id              uuid references deals(id) on delete set null,
  decided_by           text,
  decided_at           timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
drop trigger if exists meeting_handoffs_touch on meeting_handoffs;
create trigger meeting_handoffs_touch before update on meeting_handoffs for each row execute function touch_updated_at();
-- one open handoff per buyer per client
create unique index if not exists meeting_handoffs_open_idx on meeting_handoffs(client_id, contact_id)
  where status in ('ready','booked');
create index if not exists meeting_handoffs_status_idx on meeting_handoffs(status, created_at);
alter table meeting_handoffs enable row level security;

-- ─────────────────────────── the safety gate, per person ───────────────────────────
-- Everything about a person (not a draft) that stops an email to them. The Strategist uses it to pick a channel
-- the rules allow, and draft_blockers uses it for every email. Messages are the same as in 0005.
create or replace function contact_email_blockers(p_contact uuid, p_client uuid) returns text[] language plpgsql stable as $$
declare
  c   contacts;
  cl  clients;
  r   email_country_rules;
  ctry text;
  out text[] := '{}';
begin
  select * into c from contacts where id = p_contact;
  select * into cl from clients where id = p_client;
  if coalesce(trim(c.email), '') = '' then out := array_append(out, 'No email address.'); end if;
  if c.email_status = 'invalid' then out := array_append(out, 'The email address is invalid or bounced.'); end if;
  if coalesce(trim(c.email_source), '') = '' then
    out := array_append(out, 'Record where this email address came from (email source).');
  end if;
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
  return out;
end $$;

-- ─────────────────────────── the safety gate, per draft (replaces 0005's) ───────────────────────────
-- Same rules as before, plus:
--   * a first message needs the Strategist's (or your) "pursue";
--   * follow-ups and check-ins stop once the buyer is handed to you for a meeting;
--   * an answer to the buyer is allowed after they replied (a follow-up is not), and never after an unsubscribe or bounce;
--   * a check-in only goes out after the snooze, once, and only if "not now" is still their latest word.
create or replace function draft_blockers(d outreach_drafts) returns text[] language plpgsql stable as $$
declare
  c   contacts;
  cl  clients;
  ca  campaigns;
  ps  prospect_strategies;
  last_reply interactions;
  purpose text := coalesce(d.purpose, case when d.step > 1 then 'follow_up' else 'first' end);
  out text[] := '{}';
begin
  select * into c from contacts where id = d.contact_id;
  select * into cl from clients where id = d.client_id;
  select * into ca from campaigns where id = d.campaign_id;

  if c.do_not_contact then out := array_append(out, 'The buyer asked us not to contact them.'); end if;
  if is_suppressed(c.email) then out := array_append(out, 'This address or its domain is on the do-not-contact list.'); end if;
  if cl.brief_approved_at is null then out := array_append(out, 'The client''s fact sheet is not approved yet.'); end if;
  if ca.id is not null and ca.status <> 'live' then out := array_append(out, 'The campaign is not live.'); end if;

  if purpose = 'first' and d.campaign_id is not null then
    select * into ps from prospect_strategies where campaign_id = d.campaign_id and contact_id = d.contact_id;
    if found and ps.decision <> 'pursue' then
      out := array_append(out, ('This buyer was marked "' || ps.decision || '" (fit ' || ps.fit_score
                                || ' of 100), so no first message. Change it on the Buyers page if you disagree.'));
    end if;
  end if;

  if purpose in ('follow_up','check_in') and exists (
       select 1 from meeting_handoffs h where h.client_id = d.client_id and h.contact_id = d.contact_id
          and h.status in ('ready','booked','held','not_qualified')) then
    out := array_append(out, 'This buyer has been handed to you for a meeting, so no automatic messages.');
  end if;

  if purpose = 'follow_up' then
    if d.step > 1 and exists (select 1 from interactions i where i.contact_id = d.contact_id and i.client_id = d.client_id
                                and i.direction = 'inbound' and i.kind in ('reply','unsubscribe','bounce')) then
      out := array_append(out, 'The buyer has already replied, so no automatic follow-up.');
    end if;
    if d.step > 1 and not exists (select 1 from outreach_drafts p where p.contact_id = d.contact_id and p.client_id = d.client_id
                                    and p.channel = d.channel and p.step = d.step - 1 and p.status = 'sent') then
      out := array_append(out, 'The previous message has not been sent yet.');
    end if;
  end if;

  if purpose in ('reply','check_in') then
    if exists (select 1 from interactions i where i.contact_id = d.contact_id and i.client_id = d.client_id
                 and i.direction = 'inbound' and i.kind in ('unsubscribe','bounce')) then
      out := array_append(out, 'The buyer unsubscribed or the address bounced.');
    end if;
    select * into last_reply from interactions i
     where i.contact_id = d.contact_id and i.client_id = d.client_id and i.direction = 'inbound' and i.kind = 'reply'
     order by i.occurred_at desc limit 1;
    if last_reply.id is null then
      out := array_append(out, 'There is no reply from the buyer to answer.');
    elsif purpose = 'reply' and last_reply.metadata->>'category' in ('not_interested','unsubscribe') then
      out := array_append(out, 'The buyer said no, so we do not write again.');
    elsif purpose = 'check_in' then
      if coalesce(last_reply.metadata->>'category', '') <> 'not_now' then
        out := array_append(out, 'The buyer''s latest reply was not "not now", so no check-in.');
      end if;
      if not exists (select 1 from campaign_targets t where t.campaign_id = d.campaign_id and t.contact_id = d.contact_id
                       and t.snoozed_until is not null and t.snoozed_until <= now()) then
        out := array_append(out, 'The snooze after "not now" has not ended yet.');
      end if;
      if exists (select 1 from outreach_drafts p where p.contact_id = d.contact_id and p.campaign_id is not distinct from d.campaign_id
                   and p.purpose = 'check_in' and p.status = 'sent' and p.id <> d.id) then
        out := array_append(out, 'This buyer already got their one check-in.');
      end if;
    end if;
  end if;

  if d.channel = 'email' then
    if coalesce(trim(d.subject), '') = '' and d.step = 1 and purpose = 'first' then
      out := array_append(out, 'The email has no subject.');
    end if;
    out := out || contact_email_blockers(d.contact_id, d.client_id);
  end if;
  return out;
end $$;

-- ─────────────────────────── what a reply changes ───────────────────────────
-- Called once for each reply we file (the Mailer for email; the dashboard when you log a LinkedIn message or a call):
--   * unsent automatic follow-ups, check-ins and earlier answers to this buyer are cancelled (a fresh answer is drafted),
--   * "unsubscribe" stops all outreach everywhere,
--   * "not now" snoozes the buyer for the campaign's snooze_days,
--   * the buyer's status in the campaign moves on (engaged, lost).
create or replace function apply_reply(p_interaction uuid) returns text language plpgsql as $$
declare
  i   interactions;
  cat text;
  days int;
begin
  select * into i from interactions where id = p_interaction;
  if not found or i.direction <> 'inbound' or i.kind <> 'reply' or i.contact_id is null then return 'ignored'; end if;
  cat := coalesce(i.metadata->>'category', 'other');

  update outreach_drafts set status = 'cancelled', review_note = coalesce(review_note, 'Buyer replied')
   where contact_id = i.contact_id and client_id = i.client_id and status in ('pending_review','approved')
     and send_claimed_at is null
     and (purpose in ('follow_up','check_in','reply') or (purpose is null and step > 1));
  update tasks set status = 'cancelled', finished_at = now()
   where contact_id = i.contact_id and client_id = i.client_id and status = 'queued' and kind in ('draft_outreach','draft_reply');

  if cat = 'unsubscribe' then
    perform stop_contact(i.contact_id, left('Replied: ' || coalesce(i.metadata->>'summary', 'asked to stop'), 300), 'reply');
    return 'stopped';
  end if;

  if i.campaign_id is not null then
    if cat = 'not_now' then
      select snooze_days into days from campaigns where id = i.campaign_id;
      update campaign_targets set snoozed_until = i.occurred_at + make_interval(days => coalesce(days, 60)), updated_at = now()
       where campaign_id = i.campaign_id and contact_id = i.contact_id;
    else
      update campaign_targets set snoozed_until = null where campaign_id = i.campaign_id and contact_id = i.contact_id;
    end if;
    update campaign_targets
       set status = case when cat = 'not_interested' then 'lost'::target_status else 'engaged'::target_status end, updated_at = now()
     where campaign_id = i.campaign_id and contact_id = i.contact_id and status in ('queued','contacted','engaged')
       and cat in ('interested','question','not_now','wrong_person','other','not_interested');
  end if;
  return cat;
end $$;

-- ─────────────────────────── booking the meeting ───────────────────────────
-- You set the date on the Meetings page. The meeting is logged, the deal opens (the client sees it in their
-- pipeline), the buyer moves to "meeting" and no automatic message goes to them any more.
create or replace function book_meeting(p_handoff uuid, p_at timestamptz, p_note text, p_by text) returns uuid
language plpgsql as $$
declare h meeting_handoffs; deal uuid;
begin
  select * into h from meeting_handoffs where id = p_handoff for update;
  if not found then raise exception 'That meeting brief no longer exists.'; end if;
  if h.status not in ('ready','booked') then raise exception 'This meeting brief is closed (%).', h.status; end if;
  if exists (select 1 from contacts where id = h.contact_id and do_not_contact) then
    raise exception 'This contact asked not to be contacted; the meeting cannot be booked.';
  end if;
  if p_at is null then raise exception 'Choose the meeting date and time.'; end if;

  deal := h.deal_id;
  if deal is null then
    select id into deal from deals where client_id = h.client_id and contact_id = h.contact_id
       and closed_at is null and stage <> 'lost' order by opened_at desc limit 1;
  end if;
  if deal is null then
    insert into deals (client_id, company_id, contact_id, stage) values (h.client_id, h.company_id, h.contact_id, 'conversation')
    returning id into deal;
  end if;

  update meeting_handoffs set status = 'booked', meeting_at = p_at, meeting_note = coalesce(nullif(p_note, ''), meeting_note),
         owner = coalesce(owner, p_by), deal_id = deal, decided_by = p_by, decided_at = now()
   where id = p_handoff;
  if h.status = 'ready' then
    insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, body, occurred_at, metadata)
    values (h.client_id, h.campaign_id, h.company_id, h.contact_id, 'meeting', 'outbound', 'meeting_booked', 'staff',
            nullif(p_note, ''), now(), jsonb_build_object('handoff_id', h.id, 'meeting_at', p_at, 'by', p_by));
  end if;
  if h.campaign_id is not null then
    update campaign_targets set status = 'meeting', snoozed_until = null, updated_at = now()
     where campaign_id = h.campaign_id and contact_id = h.contact_id and status <> 'do_not_contact';
  end if;
  update outreach_drafts set status = 'cancelled', review_note = coalesce(review_note, 'Meeting booked')
   where contact_id = h.contact_id and client_id = h.client_id and status in ('pending_review','approved')
     and send_claimed_at is null and purpose in ('follow_up','check_in');
  return deal;
end $$;

-- After the meeting: held, no-show or cancelled. "Held" is logged as meeting_held.
create or replace function close_meeting(p_handoff uuid, p_outcome text, p_note text, p_by text) returns void
language plpgsql as $$
declare h meeting_handoffs;
begin
  if p_outcome not in ('held','no_show','cancelled','not_qualified') then raise exception 'Unknown outcome %', p_outcome; end if;
  select * into h from meeting_handoffs where id = p_handoff for update;
  if not found then raise exception 'That meeting brief no longer exists.'; end if;
  if p_outcome in ('held','no_show') and h.status <> 'booked' then raise exception 'Book the meeting first.'; end if;
  update meeting_handoffs set status = p_outcome, outcome_note = nullif(p_note, ''), decided_by = p_by, decided_at = now()
   where id = p_handoff;
  if p_outcome = 'held' then
    insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, body, metadata)
    values (h.client_id, h.campaign_id, h.company_id, h.contact_id, 'meeting', 'outbound', 'meeting_held', 'staff',
            nullif(p_note, ''), jsonb_build_object('handoff_id', h.id, 'by', p_by));
  end if;
end $$;

-- ─────────────────────────── where every buyer stands ───────────────────────────
-- One row per buyer per campaign. "stage" in plain words:
--   queued, researching, qualifying, nurture, disqualified, drafting, waiting_approval, approved, contacted,
--   no_reply (all follow-ups used), replied (needs an answer), answer_waiting (our answer waits for you),
--   snoozed (said not now), not_interested, meeting_ready, meeting_booked, meeting_held, closed, stopped
create or replace view v_conversations as
with d as (
  select o.campaign_id, o.contact_id,
         count(*) filter (where o.status = 'sent')                                                   as messages_sent,
         count(*) filter (where o.status = 'sent' and o.purpose = 'follow_up')                       as follow_ups_sent,
         max(o.sent_at) filter (where o.status = 'sent')                                             as last_sent_at,
         max(o.step) filter (where o.status = 'sent' and o.channel = 'email' and o.purpose in ('first','follow_up')) as email_step,
         max(o.sent_at) filter (where o.status = 'sent' and o.channel = 'email' and o.purpose in ('first','follow_up')) as last_email_at,
         count(*) filter (where o.status = 'pending_review')                                         as waiting,
         count(*) filter (where o.status = 'pending_review' and o.purpose = 'reply')                 as answers_waiting,
         count(*) filter (where o.status = 'approved')                                               as approved
  from outreach_drafts o where o.campaign_id is not null group by 1, 2
), r as (
  select distinct on (i.campaign_id, i.contact_id) i.campaign_id, i.contact_id, i.id as reply_id, i.occurred_at, i.channel,
         i.metadata->>'category' as category, i.metadata->>'summary' as summary
  from interactions i where i.direction = 'inbound' and i.kind = 'reply' and i.campaign_id is not null
  order by i.campaign_id, i.contact_id, i.occurred_at desc
), rn as (
  select campaign_id, contact_id, count(*) as replies from interactions
  where direction = 'inbound' and kind = 'reply' and campaign_id is not null group by 1, 2
), h as (
  select distinct on (client_id, contact_id) * from meeting_handoffs order by client_id, contact_id, created_at desc
), t as (
  select campaign_id, contact_id, bool_or(kind = 'research_prospect') as researching, bool_or(kind = 'qualify_prospect') as qualifying
  from tasks where status in ('queued','running') and campaign_id is not null group by 1, 2
)
select ct.campaign_id, ca.client_id, cl.name as client, ca.name as campaign, ct.contact_id, coalesce(ct.company_id, c.company_id) as company_id,
       trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as contact, c.title as contact_title,
       co.name as company, co.type::text as buyer_type, coalesce(c.country, co.country) as country,
       ct.status::text as target_status, c.do_not_contact,
       ps.id as strategy_id, ps.fit_score, ps.decision, ps.decided_by, ps.reason as decision_reason, ps.pitch_angle, ps.channel_plan,
       coalesce(d.messages_sent, 0)::int as messages_sent,
       coalesce(d.follow_ups_sent, 0)::int as follow_ups_sent,
       greatest(ca.max_steps - 1 - coalesce(d.follow_ups_sent, 0), 0)::int as follow_ups_left,
       d.last_sent_at,
       case when r.reply_id is null and not c.do_not_contact and d.email_step is not null and d.email_step < ca.max_steps
                 and h.id is null and coalesce(d.waiting, 0) = 0 and coalesce(d.approved, 0) = 0
            then d.last_email_at + make_interval(days => ca.followup_days) end as next_follow_up_at,
       coalesce(d.waiting, 0)::int as drafts_waiting, coalesce(d.answers_waiting, 0)::int as answers_waiting,
       coalesce(rn.replies, 0)::int as replies,
       r.reply_id as last_reply_id, r.occurred_at as last_reply_at, r.channel::text as last_reply_channel,
       r.category as last_reply_category, r.summary as last_reply_summary,
       ct.snoozed_until,
       h.id as handoff_id, h.status as handoff_status, h.qualified as handoff_qualified, h.meeting_at,
       case
         when c.do_not_contact or ct.status = 'do_not_contact'                       then 'stopped'
         when h.status = 'held'                                                      then 'meeting_held'
         when h.status = 'booked'                                                    then 'meeting_booked'
         when h.status = 'ready'                                                     then 'meeting_ready'
         when h.status in ('no_show','not_qualified','cancelled')                    then 'closed'
         when r.category = 'not_interested' or ct.status = 'lost'                    then 'not_interested'
         when r.category = 'not_now' and ct.snoozed_until > now()                    then 'snoozed'
         when coalesce(d.answers_waiting, 0) > 0                                     then 'answer_waiting'
         when r.reply_id is not null and r.category <> 'not_now'
              and not exists (select 1 from outreach_drafts o where o.reply_to_interaction_id = r.reply_id and o.status = 'sent')
                                                                                     then 'replied'
         when coalesce(d.waiting, 0) > 0                                             then 'waiting_approval'
         when coalesce(d.approved, 0) > 0                                            then 'approved'
         when ps.decision = 'disqualify'                                             then 'disqualified'
         when ps.decision = 'nurture'                                                then 'nurture'
         when coalesce(d.messages_sent, 0) > 0 and r.reply_id is null and d.email_step >= ca.max_steps
              and d.last_email_at < now() - make_interval(days => ca.followup_days) then 'no_reply'
         when coalesce(d.messages_sent, 0) > 0                                       then 'contacted'
         when t.qualifying                                                           then 'qualifying'
         when ps.decision = 'pursue'                                                 then 'drafting'
         when t.researching                                                          then 'researching'
         else 'queued'
       end as stage
from campaign_targets ct
join campaigns ca on ca.id = ct.campaign_id
join clients cl on cl.id = ca.client_id
join contacts c on c.id = ct.contact_id
left join companies co on co.id = coalesce(ct.company_id, c.company_id)
left join prospect_strategies ps on ps.campaign_id = ct.campaign_id and ps.contact_id = ct.contact_id
left join d on d.campaign_id = ct.campaign_id and d.contact_id = ct.contact_id
left join r on r.campaign_id = ct.campaign_id and r.contact_id = ct.contact_id
left join rn on rn.campaign_id = ct.campaign_id and rn.contact_id = ct.contact_id
left join h on h.client_id = ca.client_id and h.contact_id = ct.contact_id
left join t on t.campaign_id = ct.campaign_id and t.contact_id = ct.contact_id;
alter view v_conversations set (security_invoker = true);

-- Meeting briefs waiting for you, and booked meetings, soonest first.
create or replace view v_meetings as
select h.*, cl.name as client, trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as contact,
       c.title as contact_title, c.email, c.phone, c.linkedin_url, co.name as company, co.type::text as buyer_type,
       co.website, ps.fit_score
from meeting_handoffs h
join clients cl on cl.id = h.client_id
join contacts c on c.id = h.contact_id
left join companies co on co.id = coalesce(h.company_id, c.company_id)
left join prospect_strategies ps on ps.id = h.strategy_id;
alter view v_meetings set (security_invoker = true);
