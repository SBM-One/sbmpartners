-- Archived 2026-11-28. One-off loader used on 2026-11-26 for the "wave 4" Mexican contacts (B2B provider via
-- Firecrawl). It exists only on the live database, is not part of the schema, and nobody may call it
-- (EXECUTE revoked in 0015). Kept here so the live database has no code that the repository does not record.
-- Do not run it again: the company ids and the data format are specific to that one batch.
-- Definition as it is on the live database:
/*
CREATE OR REPLACE FUNCTION public.load_w4_contacts(data jsonb) RETURNS text LANGUAGE plpgsql AS $function$
  -- maps row index -> one of 19 company ids (wave 4 list), inserts or updates contacts with lead_collection,
  -- best_channel, hold_reason ("Left the company ... Do not contact." sets do_not_contact), email_source
  -- 'provider_verified: leadsforge + millionverifier (...)', research_notes 'W4 firecrawl_people.json'.
  -- Full text: select pg_get_functiondef('public.load_w4_contacts(jsonb)'::regprocedure);
$function$;
*/
