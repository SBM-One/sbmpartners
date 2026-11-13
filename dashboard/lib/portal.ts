import "server-only";
import type postgres from "postgres";
import { sql } from "./db";
import type { PortalScope } from "./auth";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Runs the portal's queries for one client. Every query also filters on scope.clientId.
 *
 * For a client's own login there is a second lock: the queries run as that login inside the database
 * (role "authenticated" with their user id), so Supabase's row-level security decides what they can read,
 * exactly as it would through the Supabase API. Even a mistake in a query here can't show another client's rows.
 * Staff previewing a portal keep their normal access.
 */
export async function portalQuery<T>(scope: PortalScope, run: (q: postgres.TransactionSql) => Promise<T>): Promise<T> {
  if (!UUID.test(scope.clientId)) throw new Error("Bad client id");
  return (await sql.begin(async (tx) => {
    if (!scope.preview) {
      if (!scope.authUserId || !UUID.test(scope.authUserId)) throw new Error("This login isn't linked to a client yet");
      const claims = JSON.stringify({ sub: scope.authUserId, role: "authenticated" });
      await tx`select set_config('request.jwt.claims', ${claims}, true)`;
      await tx`set local role authenticated`;
    }
    return run(tx);
  })) as T;
}

/** Keeps the staff preview on the same client as you click around the portal. */
export const portalHref = (scope: PortalScope, path: string) =>
  scope.preview ? `${path}${path.includes("?") ? "&" : "?"}client=${scope.clientId}` : path;
