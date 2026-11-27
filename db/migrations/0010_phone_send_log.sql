-- SBM Partners · step 10: every LinkedIn note and WhatsApp you send from the phone is logged, so nobody gets
-- messaged twice.
--
--   phone_blockers(d)  draft_blockers() plus two by-hand rules:
--                        · no WhatsApp to a buyer whose company we already emailed (Santiago, 2026-11-26)
--                        · no second LinkedIn note / WhatsApp to someone already messaged on that channel
--   phone_queue()      now shows those blockers
--   phone_mark()       refuses a blocked draft. The app now logs a note as sent the moment you tap to open it.

create or replace function phone_blockers(d outreach_drafts) returns text[] language plpgsql stable security definer
set search_path = public as $$
declare out text[] := coalesce(draft_blockers(d), '{}'); k text := phone_kind(d); co uuid;
begin
  if k not in ('whatsapp', 'linkedin') then return out; end if;
  select coalesce(d.company_id, c.company_id) into co from contacts c where c.id = d.contact_id;
  if k = 'whatsapp' and (
       exists (select 1 from outreach_drafts e join contacts c2 on c2.id = e.contact_id
               where phone_kind(e) = 'email' and e.status in ('approved', 'sent')
                 and (e.contact_id = d.contact_id or (co is not null and coalesce(e.company_id, c2.company_id) = co)))
    or exists (select 1 from interactions i where i.channel = 'email' and i.direction = 'outbound'
                 and (i.contact_id = d.contact_id or (co is not null and i.company_id = co)))) then
    out := array_append(out, 'We already emailed this company, so no WhatsApp (your rule).');
  end if;
  if exists (select 1 from interactions i
             where i.contact_id = d.contact_id and i.direction = 'outbound'
               and i.channel::text = case k when 'whatsapp' then 'whatsapp' else 'linkedin' end
               and coalesce(i.metadata->>'draft_id', '') <> d.id::text) then
    out := array_append(out, 'Already messaged on ' || case k when 'whatsapp' then 'WhatsApp' else 'LinkedIn' end || '.');
  end if;
  return out;
end $$;

create or replace function phone_queue() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me staff := phone_staff();
begin
  return coalesce((select jsonb_agg(q order by q.sort, q.created_at) from (
    select d.id, phone_kind(d) as kind, d.status::text as status, d.subject, d.body, d.step, d.purpose, d.score,
           d.grade_feedback, d.created_at, d.reviewed_at, cl.name as client,
           nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as contact,
           c.title, co.name as company, c.email, c.linkedin_url, phone_number(d, c) as number,
           phone_blockers(d) as blockers,
           case phone_kind(d) when 'email' then 2 else 1 end as sort
    from outreach_drafts d
    join contacts c on c.id = d.contact_id
    join clients cl on cl.id = d.client_id
    left join companies co on co.id = coalesce(d.company_id, c.company_id)
    where d.status = 'pending_review' or (d.status = 'approved' and phone_kind(d) <> 'email')
    limit 200) q), '[]');
end $$;

create or replace function phone_mark(p_id uuid, p_op text, p_body text default null) returns text
language plpgsql security definer set search_path = public as $$
declare me staff := phone_staff(); d outreach_drafts; k text; ch channel; bl text[];
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
  bl := phone_blockers(d);
  if cardinality(bl) > 0 then raise exception 'Not allowed yet: %', array_to_string(bl, ' '); end if;
  if d.status = 'pending_review' then
    update outreach_drafts set status = 'approved', reviewed_by = me.email, reviewed_at = now(),
                               body = coalesce(nullif(trim(p_body), ''), body)
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

revoke all on function phone_blockers(outreach_drafts) from public, anon;
