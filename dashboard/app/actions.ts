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
  await sql`
    update outreach_drafts
       set status = ${decision}::draft_status,
           subject = coalesce(nullif(${subject}, ''), subject),
           body = coalesce(nullif(${body}, ''), body),
           review_note = nullif(${str(form, "note")}, ''),
           reviewed_by = ${me.email}
     where id = ${id} and status = 'pending_review'`;
  revalidatePath("/", "layout");
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
