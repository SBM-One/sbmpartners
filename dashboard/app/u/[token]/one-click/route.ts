import { sql } from "@/lib/db";

/**
 * One-click unsubscribe (RFC 8058): mail apps such as Gmail POST here when someone presses their "Unsubscribe" button.
 * The address is in each email's List-Unsubscribe header. No login, no confirmation page.
 */
export async function POST(_req: Request, { params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  if (/^[a-f0-9]{32}$/.test(token)) await sql`select unsubscribe_by_token(${token})`;
  return new Response("You are unsubscribed.", { status: 200, headers: { "content-type": "text/plain" } });
}
