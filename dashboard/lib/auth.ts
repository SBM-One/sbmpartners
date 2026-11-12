import "server-only";
import { redirect } from "next/navigation";
import { sql } from "./db";
import { supabaseServer } from "./supabase";

export type Staff = { id: string; name: string; email: string; role: string };

/** The logged-in staff member, or null. Only people listed in the `staff` table get in. */
export async function getStaff(): Promise<Staff | null> {
  let email: string | undefined;
  const dev = process.env.DEV_LOGIN_EMAIL;
  if (dev && process.env.NODE_ENV !== "production") {
    email = dev;
  } else {
    const supabase = await supabaseServer();
    const { data } = await supabase.auth.getUser();
    email = data.user?.email ?? undefined;
  }
  if (!email) return null;
  const rows = await sql<Staff[]>`select id, name, email, role from staff where lower(email) = lower(${email})`;
  return rows[0] ?? null;
}

/** Every page and every button calls this first. */
export async function requireStaff(): Promise<Staff> {
  const staff = await getStaff();
  if (!staff) redirect("/login");
  return staff;
}
