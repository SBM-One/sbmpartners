-- 0015 · Security hardening (applied on the live database on 2026-11-28, written down here).
--
-- Found on 2026-11-28 with the public (publishable) key that ships in the phone app:
--   * a one-off backup table of 89 contacts had row security off, so anyone with the key could read it
--   * research_quota_settings had row security off
--   * autopilot_send_queue was a definer view, so it could be read with the public key
--   * every database function was callable by anyone (Postgres grants EXECUTE to PUBLIC by default),
--     including the ones that mark emails sent, stop contacts or approve drafts
-- Fix: lock those tables, make the queue an invoker view, take EXECUTE away from everyone on every function, then
-- give back only what the phone app, the client portal and the public unsubscribe page need. New functions are
-- private by default from now on.

do $$ begin
  if to_regclass('public.backup_contacts_20261126_w4') is not null then
    execute 'alter table public.backup_contacts_20261126_w4 enable row level security';
    execute 'revoke all on public.backup_contacts_20261126_w4 from public, anon, authenticated';
  end if;
end $$;

alter table research_quota_settings enable row level security;
revoke all on research_quota_settings from anon, authenticated;

alter view autopilot_send_queue set (security_invoker = true);
revoke all on autopilot_send_queue from anon, authenticated;

-- Every function in public (not the ones extensions own): nobody but the owner.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

-- What signed-in staff use from the phone app (each checks the caller is on the staff list).
do $$
declare f text;
begin
  foreach f in array array['phone_today()', 'phone_queue()', 'phone_inbox()', 'phone_review(uuid,text,text,text,text)',
                           'phone_mark(uuid,text,text)', 'phone_alert(uuid,text)', 'phone_brief(uuid)', 'phone_find(text)'] loop
    if to_regprocedure(f) is not null then execute format('grant execute on function %s to authenticated', f); end if;
  end loop;
end $$;
-- Row security policies call my_client_ids(), so whoever reads a portal view must be able to run it.
grant execute on function my_client_ids() to anon, authenticated;
-- The unsubscribe link in every email works without signing in.
grant execute on function unsubscribe_by_token(text) to anon, authenticated;

-- Functions created later by the owner are private unless a migration grants them.
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon, authenticated;
