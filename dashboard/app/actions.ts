"use server";

import { revalidatePath } from "next/cache";
import { sql } from "@/lib/db";
import { requireStaff } from "@/lib/auth";

const str = (f: FormData, k: string) => String(f.get(k) ?? "").trim();

/** Approve or reject a draft. You can edit the subject and text first. The database refuses do-not-contact buyers. */
export async function reviewDraft(form: FormData) {
  const me = await requireStaff();
  const id = str(form, "id");
  const decision = str(form, "decision");
  if (!["approved", "rejected"].includes(decision)) throw new Error("Unknown decision");
  const subject = str(form, "subject");
  const body = str(form, "body");
  if (decision === "approved" && !body) throw new Error("The message is empty");
  await gate(sql`
    update outreach_drafts
       set status = ${decision}::draft_status,
           subject = coalesce(nullif(${subject}, ''), subject),
           body = coalesce(nullif(${body}, ''), body),
           review_note = nullif(${str(form, "note")}, ''),
           reviewed_by = ${me.email}
     where id = ${id} and status = 'pending_review'`);
  revalidatePath("/", "layout");
}

/** The database refuses unsafe approvals and sends; show its reason instead of a generic error page. */
async function gate<T>(q: Promise<T>): Promise<T> {
  try {
    return await q;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (/Not allowed yet|do-not-contact|asked not to be contacted|must be approved|un-sent/i.test(msg)) throw new Error(msg);
    throw e;
  }
}

const COUNTRY = /^[A-Z]{2}$/;
const BASES = ["unknown", "consent", "legitimate_interest", "existing_customer"];

/** Fix what the safety gate asks for on one buyer: country, legal basis, where the address came from. */
export async function updateContactSending(form: FormData) {
  await requireStaff();
  const country = str(form, "country").toUpperCase();
  const basis = str(form, "email_basis");
  if (country && !COUNTRY.test(country)) throw new Error("Use a two-letter country code, like ES, FR or GB");
  if (basis && !BASES.includes(basis)) throw new Error("Unknown legal basis");
  await sql`update contacts set country = coalesce(nullif(${country}, ''), country),
                                email_basis = coalesce(nullif(${basis}, ''), email_basis),
                                email_source = coalesce(nullif(${str(form, "email_source")}, ''), email_source)
            where id = ${str(form, "contact_id")}`;
  revalidatePath("/approvals");
  revalidatePath("/sending");
}

/** Never contact this person again, on any channel, for any client. */
export async function stopContact(form: FormData) {
  const me = await requireStaff();
  const reason = str(form, "reason") || `Stopped by ${me.name}`;
  await sql`select stop_contact(${str(form, "contact_id")}, ${reason}, ${me.email})`;
  revalidatePath("/", "layout");
}

/** Add an address or a whole domain to the do-not-contact list. */
export async function addSuppression(form: FormData) {
  const me = await requireStaff();
  const value = str(form, "value").toLowerCase().replace(/^@/, "");
  if (!/^([^@\s]+@)?[a-z0-9.-]+\.[a-z]{2,}$/.test(value)) throw new Error("Enter an email address or a domain like shop.com");
  await sql`insert into suppressions (value, reason, added_by) values (${value}, ${str(form, "reason") || "Added by hand"}, ${me.email})
            on conflict (value) do nothing`;
  await sql`select stop_contact(id, ${"On the do-not-contact list: " + value}, ${me.email}) from contacts
            where lower(email) = ${value} or split_part(lower(email), '@', 2) = ${value}`;
  revalidatePath("/sending");
}

/** You sent a LinkedIn note by hand: record it. Or skip it. */
export async function markLinkedIn(form: FormData) {
  const me = await requireStaff();
  const id = str(form, "id");
  if (str(form, "op") === "skip") {
    await sql`update outreach_drafts set status = 'cancelled', review_note = ${"Skipped by " + me.name} where id = ${id} and status = 'approved'`;
  } else {
    await gate(sql.begin(async (tx) => {
      const [d] = await tx<{ client_id: string; campaign_id: string | null; company_id: string | null; contact_id: string; body: string }[]>`
        update outreach_drafts set status = 'sent', sent_at = now(), sent_by = ${me.email}
         where id = ${id} and status = 'approved' and channel = 'linkedin'
        returning client_id, campaign_id, company_id, contact_id, body`;
      if (!d) return;
      await tx`insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor, body, metadata)
               values (${d.client_id}, ${d.campaign_id}, ${d.company_id}, ${d.contact_id}, 'linkedin', 'outbound', 'sent', 'staff',
                       ${d.body}, ${sql.json({ draft_id: id, sent_by: me.email })})`;
      if (d.campaign_id) await tx`update campaign_targets set status = 'contacted', updated_at = now()
                                  where campaign_id = ${d.campaign_id} and contact_id = ${d.contact_id} and status = 'queued'`;
    }));
  }
  revalidatePath("/linkedin");
}

/** Confirm a country's email rule after the lawyer check, change it, or withdraw the confirmation. */
export async function setCountryRule(form: FormData) {
  const me = await requireStaff();
  const country = str(form, "country");
  const op = str(form, "op");
  const cold = str(form, "cold_email");
  if (!["allowed", "consent_only", "blocked"].includes(cold)) throw new Error("Unknown rule");
  if (op === "confirm") {
    await sql`update email_country_rules set cold_email = ${cold}, confirmed_by = ${me.email}, confirmed_at = now(), updated_at = now()
              where country = ${country}`;
  } else {
    await sql`update email_country_rules set cold_email = ${cold}, confirmed_by = null, confirmed_at = null, updated_at = now()
              where country = ${country}`;
  }
  revalidatePath("/sending");
}

/** The mailbox's pace: daily cap, sending hours, pause. */
export async function updateMailbox(form: FormData) {
  await requireStaff();
  const int = (k: string, lo: number, hi: number) => {
    const v = Number(str(form, k));
    if (!Number.isInteger(v) || v < lo || v > hi) throw new Error(`${k.replace(/_/g, " ")} must be ${lo} to ${hi}`);
    return v;
  };
  const cap = int("daily_cap", 0, 200), from = int("send_from_hour", 0, 23), until = int("send_until_hour", 1, 24),
    gap = int("min_gap_minutes", 1, 240);
  if (until <= from) throw new Error("The sending window must end after it starts");
  const tz = str(form, "timezone");
  try { new Intl.DateTimeFormat("en", { timeZone: tz }); } catch { throw new Error("Unknown time zone"); }
  await sql`update mailboxes set daily_cap = ${cap}, send_from_hour = ${from}, send_until_hour = ${until}, min_gap_minutes = ${gap},
              timezone = ${tz}, paused = ${str(form, "paused") === "on"} where id = ${str(form, "id")}`;
  revalidatePath("/sending");
}

const SHEET_TEXT = ["brand", "what_they_make", "price_points", "terms", "trade_and_contract", "proof", "offer", "best_fit_buyers"];
const SHEET_LISTS = ["collections", "sources_used", "questions_for_client"];

/** Approve a client's fact sheet (with your edits). From then on the Writer may use it. */
export async function approveBrief(form: FormData) {
  const me = await requireStaff();
  const sheet: Record<string, unknown> = {};
  for (const k of SHEET_TEXT) sheet[k] = str(form, k);
  for (const k of SHEET_LISTS) sheet[k] = str(form, k).split("\n").map((x) => x.trim()).filter(Boolean);
  if (!sheet.brand || !sheet.what_they_make) throw new Error("The fact sheet needs at least the brand and what they make");
  await sql`update clients set brief = ${sql.json(sheet as never)}, brief_draft = null, brief_approved_at = now(),
              brief_approved_by = ${me.email} where id = ${str(form, "id")}`;
  revalidatePath("/clients");
}

/** Who the emails come from: required in every email. */
export async function updateSender(form: FormData) {
  await requireStaff();
  await sql`update clients set sender_name = nullif(${str(form, "sender_name")}, ''),
              sender_company = nullif(${str(form, "sender_company")}, ''),
              postal_address = nullif(${str(form, "postal_address")}, '') where id = ${str(form, "id")}`;
  revalidatePath("/clients");
}

export async function setPlaybookStatus(form: FormData) {
  await requireStaff();
  const status = str(form, "status");
  if (!["draft", "active", "retired"].includes(status)) throw new Error("Unknown status");
  const ids = form.getAll("id").map(String).filter(Boolean);
  if (ids.length) await sql`update playbook_entries set status = ${status}::entry_status where id = any(${ids}::uuid[])`;
  revalidatePath("/playbook");
}

export async function reviewReport(form: FormData) {
  await requireStaff();
  const id = str(form, "id");
  const body = str(form, "body");
  if (str(form, "decision") === "approve") {
    await sql`update reports set status = 'approved', approved_at = now(), body = coalesce(nullif(${body}, ''), body)
              where id = ${id} and status = 'draft'`;
  } else {
    await sql`update reports set body = coalesce(nullif(${body}, ''), body) where id = ${id} and status = 'draft'`;
  }
  revalidatePath("/reports");
}

export async function updateAlert(form: FormData) {
  await requireStaff();
  const status = str(form, "status");
  if (!["acknowledged", "resolved"].includes(status)) throw new Error("Unknown status");
  await sql`update alerts set status = ${status}::alert_status where id = ${str(form, "id")}`;
  revalidatePath("/", "layout");
}

/** Pause or resume an agent, or change its monthly budget. */
export async function updateAgent(form: FormData) {
  const me = await requireStaff();
  const id = str(form, "id");
  const op = str(form, "op");
  if (op === "pause") {
    await sql`update agents set active = false, paused_reason = ${"paused by " + me.name} where id = ${id}`;
  } else if (op === "resume") {
    await sql`update agents set active = true, paused_reason = null where id = ${id}`;
  } else if (op === "budget") {
    const usd = Number(str(form, "budget"));
    if (!Number.isFinite(usd) || usd < 0 || usd > 10000) throw new Error("Budget must be between $0 and $10,000");
    await sql`update agents set monthly_budget_cents = ${Math.round(usd * 100)} where id = ${id}`;
  }
  revalidatePath("/");
}

export async function updateClient(form: FormData) {
  await requireStaff();
  const limit = Number(str(form, "daily_draft_limit"));
  if (!Number.isInteger(limit) || limit < 0 || limit > 500) throw new Error("Daily limit must be 0 to 500");
  await sql`update clients set daily_draft_limit = ${limit} where id = ${str(form, "id")}`;
  revalidatePath("/clients");
}
