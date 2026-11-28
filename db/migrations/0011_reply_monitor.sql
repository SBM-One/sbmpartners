-- 0010 Reply monitor
--
-- Outreach emails go out from santiago@sbmpartners.net through the Gmail connector, not through agents/mailer.py,
-- so nothing read the inbox. A scheduled Claude task now checks Gmail every hour on weekdays (8:00–20:00 Mexico
-- City) and files what it finds with the functions below. The rules live here, in the database, so every run does
-- the same thing:
--
--   monitor_file_email(jsonb)   files one incoming email: a buyer's reply, an automatic reply or a bounce.
--                               Replies go to the phone app's Replies tab and run apply_reply() (no more follow-ups;
--                               "unsubscribe" stops the buyer everywhere; "not now" snoozes). Bounces mark the
--                               address invalid and cancel its unsent emails.
--   monitor_add_answer(...)     saves the suggested answer as a draft (purpose 'reply') for Santiago to approve in
--                               the app. Nothing is sent on its own.
--   monitor_answers_to_send()   approved answers the next run should send as a reply in the Gmail thread.
--   monitor_mark_answer_sent()  records that an answer went out.
--   monitor_log_run(...)        one row per run, so a silent monitor can be told apart from a broken one.
--
-- None of these can be called from the app or the public API; only the database owner (the connector) can.

alter table outreach_drafts add column if not exists gmail_thread_id text;
create index if not exists outreach_drafts_gmail_thread_idx on outreach_drafts(gmail_thread_id) where gmail_thread_id is not null;

create table if not exists monitor_runs (
  id       uuid primary key default gen_random_uuid(),
  ran_at   timestamptz not null default now(),
  checked  int not null default 0,     -- inbox messages looked at
  filed    int not null default 0,     -- replies, auto-replies and bounces filed
  sent     int not null default 0,     -- approved answers sent
  note     text
);
alter table monitor_runs enable row level security;

-- Gmail ignores dots and "+tags" in the part before the @, and its tools sometimes show the address that way.
create or replace function email_key(p text) returns text language sql immutable as $$
  select case when p is null or position('@' in p) = 0 then lower(trim(p))
              else replace(split_part(split_part(lower(trim(p)), '@', 1), '+', 1), '.', '') || '@' || split_part(lower(trim(p)), '@', 2)
         end
$$;

-- Domains that are not one company, so a reply from someone else there is not matched by domain.
create or replace function is_freemail(p_domain text) returns boolean language sql immutable as $$
  select lower(coalesce(p_domain, '')) in ('gmail.com','googlemail.com','hotmail.com','hotmail.es','outlook.com','outlook.es',
    'live.com','live.com.mx','yahoo.com','yahoo.com.mx','yahoo.es','icloud.com','me.com','aol.com','prodigy.net.mx','msn.com',
    'protonmail.com','proton.me')
$$;

-- Which of our sent emails is this about? By Gmail thread first, then the sender's address, then (for a colleague
-- answering for a shared inbox) the sender's company domain.
create or replace function monitor_match(p_from text, p_thread text)
returns table (draft_id uuid, contact_id uuid, client_id uuid, company_id uuid, campaign_id uuid, matched_by text)
language sql stable as $$
  (select d.id, d.contact_id, d.client_id, coalesce(d.company_id, c.company_id), d.campaign_id, 'thread'
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
  limit 1
$$;

-- File one incoming email. Input (jsonb):
--   gmail_message_id, gmail_thread_id, from, subject, body, received_at,
--   category: interested | question | not_now | wrong_person | not_interested | unsubscribe | out_of_office | bounce | other
--   summary (one line), referral (who they pointed us to, if anyone), bounced_address (for bounces)
-- Returns {status: filed | duplicate | unmatched, ...}.
create or replace function monitor_file_email(p jsonb) returns jsonb language plpgsql as $$
declare
  cat  text := coalesce(nullif(p->>'category', ''), 'other');
  ext  text := 'gmail:' || (p->>'gmail_message_id');
  m    record;
  who  record;
  iid  uuid;
  res  text;
  addr text;
  label text;
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
    if m.contact_id is null or m.matched_by = 'domain' then
      return jsonb_build_object('status', 'unmatched', 'why', 'bounce for an address we did not write to');
    end if;
  else
    select * into m from monitor_match(p->>'from', p->>'gmail_thread_id');
    if m.contact_id is null then
      return jsonb_build_object('status', 'unmatched', 'why', 'not a reply to our outreach');
    end if;
  end if;

  select trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as name, c.email, co.name as company
    into who from contacts c left join companies co on co.id = c.company_id where c.id = m.contact_id;
  label := concat_ws(', ', nullif(who.name, ''), who.company);

  insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor,
                            subject, body, external_id, occurred_at, metadata)
  values (m.client_id, m.campaign_id, m.company_id, m.contact_id, 'email', 'inbound',
          (case cat when 'bounce' then 'bounce' when 'out_of_office' then 'note' else 'reply' end)::interaction_kind,
          (case when cat = 'bounce' then 'system' else 'buyer' end)::actor,
          p->>'subject', left(p->>'body', 20000), ext, coalesce((p->>'received_at')::timestamptz, now()),
          jsonb_strip_nulls(jsonb_build_object('category', cat, 'summary', p->>'summary', 'referral', nullif(p->>'referral', ''),
            'from', lower(p->>'from'), 'gmail_thread_id', p->>'gmail_thread_id', 'gmail_message_id', p->>'gmail_message_id',
            'matched_by', m.matched_by, 'draft_id', m.draft_id, 'by', 'reply-monitor')))
  on conflict (channel, external_id) do nothing
  returning id into iid;
  if iid is null then return jsonb_build_object('status', 'duplicate'); end if;

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
    res := 'out_of_office';
  else
    res := apply_reply(iid);
    insert into alerts (client_id, severity, kind, message, refs)
    values (m.client_id, (case when cat in ('interested','question') then 'urgent' else 'info' end)::severity, 'buyer_replied',
            coalesce(label, p->>'from') || ' replied (' || replace(cat, '_', ' ') || '): ' || coalesce(p->>'summary', '')
            || coalesce(' They suggested: ' || nullif(p->>'referral', '') || '.', ''),
            jsonb_build_object('contact_id', m.contact_id, 'interaction_id', iid));
  end if;

  return jsonb_build_object('status', 'filed', 'result', res, 'interaction_id', iid, 'contact_id', m.contact_id,
                            'client_id', m.client_id, 'contact', nullif(who.name, ''), 'company', who.company,
                            'email', who.email, 'matched_by', m.matched_by, 'category', cat);
end $$;

-- Save the suggested answer for approval. It shows in the app under "To send" and as "Our answer is waiting"
-- on the reply. p_gmail_draft_id is the matching draft in the Gmail thread, if one was made.
create or replace function monitor_add_answer(p_interaction uuid, p_subject text, p_body text, p_gmail_draft_id text default null)
returns uuid language plpgsql as $$
declare i interactions; nid uuid;
begin
  select * into i from interactions where id = p_interaction and direction = 'inbound' and kind = 'reply';
  if not found then raise exception 'No reply %', p_interaction; end if;
  if coalesce(i.metadata->>'category', '') in ('unsubscribe','not_interested') then
    raise exception 'The buyer said no; we do not answer.';
  end if;
  update outreach_drafts set status = 'rejected', review_note = 'Replaced by a newer answer'
   where reply_to_interaction_id in (select id from interactions where contact_id = i.contact_id and client_id = i.client_id)
     and purpose = 'reply' and status = 'pending_review';
  insert into outreach_drafts (client_id, campaign_id, contact_id, company_id, channel, step, purpose, subject, body,
                               reply_to_interaction_id, gmail_thread_id, status, research)
  values (i.client_id, i.campaign_id, i.contact_id, i.company_id, 'email', 1, 'reply', p_subject, p_body,
          i.id, i.metadata->>'gmail_thread_id', 'pending_review',
          jsonb_strip_nulls(jsonb_build_object('gmail_draft_id', p_gmail_draft_id, 'reply_to', i.metadata->>'from',
                                               'written_by', 'reply-monitor')))
  returning id into nid;
  return nid;
end $$;

-- An interested buyer gets a meeting handoff (the Meetings page and the call-booking step read it). One open
-- handoff per buyer: a later reply refreshes it instead of adding another.
create or replace function monitor_upsert_handoff(p_interaction uuid, p_interest text, p_product_fit text, p_body text,
                                                  p_qualified boolean default true, p_next_steps jsonb default '[]')
returns uuid language plpgsql as $$
declare i interactions; hid uuid;
begin
  select * into i from interactions where id = p_interaction and direction = 'inbound' and kind = 'reply';
  if not found then raise exception 'No reply %', p_interaction; end if;
  update meeting_handoffs set reply_interaction_id = i.id, interest = p_interest, product_fit = p_product_fit, body = p_body,
         qualified = p_qualified, next_steps = coalesce(p_next_steps, '[]')
   where client_id = i.client_id and contact_id = i.contact_id and status in ('ready','booked')
  returning id into hid;
  if hid is null then
    insert into meeting_handoffs (client_id, campaign_id, contact_id, company_id, reply_interaction_id, status, qualified,
                                  interest, product_fit, body, next_steps, contact_history)
    values (i.client_id, i.campaign_id, i.contact_id, i.company_id, i.id, 'ready', p_qualified, p_interest, p_product_fit,
            p_body, coalesce(p_next_steps, '[]'),
            coalesce((select jsonb_agg(jsonb_build_object('at', x.occurred_at, 'direction', x.direction, 'kind', x.kind,
                                                          'subject', x.subject, 'body', left(x.body, 2000)) order by x.occurred_at)
                        from interactions x where x.contact_id = i.contact_id and x.client_id = i.client_id), '[]'))
    returning id into hid;
  end if;
  return hid;
end $$;

-- Answers Santiago approved in the app that still have to go out (as a reply in the Gmail thread).
create or replace function monitor_answers_to_send() returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'draft_id', d.id, 'gmail_thread_id', d.gmail_thread_id, 'gmail_draft_id', d.research->>'gmail_draft_id',
           'reply_to', d.research->>'reply_to', 'reply_to_gmail_message_id', i.metadata->>'gmail_message_id',
           'subject', d.subject, 'body', d.body, 'blockers', draft_blockers(d), 'approved_at', d.reviewed_at)), '[]')
    from outreach_drafts d left join interactions i on i.id = d.reply_to_interaction_id
   where d.purpose = 'reply' and d.channel = 'email' and d.status = 'approved'
$$;

create or replace function monitor_mark_answer_sent(p_draft uuid, p_gmail_message_id text, p_by text default 'reply-monitor')
returns void language plpgsql as $$
declare d outreach_drafts; iid uuid;
begin
  select * into d from outreach_drafts where id = p_draft for update;
  if not found then raise exception 'No draft %', p_draft; end if;
  if d.status = 'sent' then return; end if;
  if d.status = 'pending_review' then   -- he sent it himself from Gmail: that was the approval
    update outreach_drafts set status = 'approved', reviewed_by = 'santiago (sent from Gmail)' where id = p_draft;
  end if;
  insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, subject, body,
                            external_id, metadata)
  values (d.client_id, d.campaign_id, d.company_id, d.contact_id, 'email', 'outbound', 'sent', 'staff', d.subject, d.body,
          'gmail:' || p_gmail_message_id, jsonb_build_object('gmail_thread_id', d.gmail_thread_id, 'purpose', 'reply'))
  on conflict (channel, external_id) do update set metadata = interactions.metadata
  returning id into iid;
  update outreach_drafts set status = 'sent', sent_by = p_by, message_id = p_gmail_message_id, interaction_id = iid
   where id = p_draft;
end $$;

create or replace function monitor_log_run(p_checked int, p_filed int, p_sent int, p_note text default null)
returns void language sql as $$
  insert into monitor_runs (checked, filed, sent, note) values (p_checked, p_filed, p_sent, p_note)
$$;

revoke all on function email_key(text), is_freemail(text), monitor_match(text, text), monitor_file_email(jsonb),
  monitor_add_answer(uuid, text, text, text),
  monitor_upsert_handoff(uuid, text, text, text, boolean, jsonb), monitor_answers_to_send(), monitor_mark_answer_sent(uuid, text, text),
  monitor_log_run(int, int, int, text) from public, anon, authenticated;
revoke all on monitor_runs from public, anon, authenticated;
