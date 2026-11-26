import "server-only";
import { cache } from "react";
import { redirect } from "next/navigation";
import { sql } from "./db";
import { supabaseServer } from "./supabase";

export type Staff = { id: string; name: string; email: string; role: string };
export type ClientUser = { id: string; name: string | null; email: string; client_id: string; client_name: string;
  plan: string | null; auth_user_id: string | null };

/** The email of whoever is signed in. In local development DEV_LOGIN_EMAIL stands in for the email login. */
const signedInEmail = cache(async (): Promise<{ email: string; authId: string | null } | null> => {
  const dev = process.env.DEV_LOGIN_EMAIL;
  if (dev && process.env.NODE_ENV !== "production") return { email: dev, authId: null };
  const supabase = await supabaseServer();
  const { data } = await supabase.auth.getUser();
  return data.user?.email ? { email: data.user.email, authId: data.user.id } : null;
});

/** The logged-in staff member, or null. Only people listed in the `staff` table get in. */
export const getStaff = cache(async (): Promise<Staff | null> => {
  const who = await signedInEmail();
  if (!who) return null;
  const rows = await sql<Staff[]>`select id, name, email, role from staff where lower(email) = lower(${who.email})`;
  return rows[0] ?? null;
});

/**
 * The logged-in client user, or null. Only people listed in `client_users` get in. The first time they sign in,
 * their login is linked to that row (auth_user_id), which is what the database's privacy rules check.
 */
export const getClientUser = cache(async (): Promise<ClientUser | null> => {
  const who = await signedInEmail();
  if (!who) return null;
  const rows = await sql<ClientUser[]>`
    select u.id, u.name, u.email, u.client_id, c.name as client_name, c.plan, u.auth_user_id
    from client_users u join clients c on c.id = u.client_id
    where lower(u.email) = lower(${who.email}) and c.status <> 'churned'
    order by u.created_at limit 1`;
  const user = rows[0];
  if (!user) return null;
  if (who.authId) {
    // A real login: link it the first time. A row already linked to a different login is refused.
    if (!user.auth_user_id) {
      await sql`update client_users set auth_user_id = ${who.authId} where id = ${user.id} and auth_user_id is null`;
      user.auth_user_id = who.authId;
    } else if (user.auth_user_id !== who.authId) {
      return null;
    }
  } else if (!user.auth_user_id) {
    // Local development only: a stable stand-in id so the privacy rules still run.
    await sql`update client_users set auth_user_id = ${user.id} where id = ${user.id}`;
    user.auth_user_id = user.id;
  }
  return user;
});

/** Every owner page and every button calls this first. Clients are sent to their portal. */
export async function requireStaff(): Promise<Staff> {
  const staff = await getStaff();
  if (staff) return staff;
  if (await getClientUser()) redirect("/portal");
  redirect("/login");
}

/** Who the portal is showing, and whether this is a client or a staff member previewing a client's portal. */
export type PortalScope = { clientId: string; clientName: string; plan: string | null; viewerName: string;
  authUserId: string | null; preview: boolean };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function requirePortal(previewClientId?: string): Promise<PortalScope> {
  const staff = await getStaff();
  if (staff) {
    type C = { id: string; name: string; plan: string | null };
    const [c] = previewClientId && UUID.test(previewClientId)
      ? await sql<C[]>`select id, name, plan from clients where id = ${previewClientId}`
      : await sql<C[]>`select id, name, plan from clients order by status = 'active' desc, created_at limit 1`;
    if (!c) redirect("/clients");
    return { clientId: c.id, clientName: c.name, plan: c.plan, viewerName: staff.name, authUserId: null, preview: true };
  }
  const user = await getClientUser();
  if (!user) redirect("/login");
  return { clientId: user.client_id, clientName: user.client_name, plan: user.plan,
    viewerName: user.name ?? user.email, authUserId: user.auth_user_id, preview: false };
}
