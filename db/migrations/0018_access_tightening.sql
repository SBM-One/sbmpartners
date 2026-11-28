-- 0018: access tightening found while verifying 0016/0017 on live (2026-11-28). Applied to live the same day.
--
-- 1. The anon key (public, it ships in the phone app) could still SELECT every table. RLS returned nothing because no
--    policy matches anon, but RLS alone is not proof: anon now has no table or sequence privileges at all.
--    Nothing uses anon for data: the dashboard reads through its own database connection, the phone app signs in
--    and calls phone_* functions as authenticated, and the unsubscribe link is the only anon call.
-- 2. unsubscribe_by_token ran as the caller, so with (1) it could not read contacts. It now runs as owner with a fixed
--    search_path; it only looks up the exact token and stops that one contact.
-- 3. phone_kind / phone_number were callable by anon (harmless helpers, but not needed).
-- 4. Every function in public gets a fixed search_path (Supabase advisor 0011).

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;

alter function unsubscribe_by_token(text) security definer set search_path = public;
revoke execute on function phone_kind(outreach_drafts), phone_number(outreach_drafts, contacts) from public, anon;

do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.proconfig is null
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('alter function %s set search_path = public', f);
  end loop;
end $$;
