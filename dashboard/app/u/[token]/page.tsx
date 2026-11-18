import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { sql } from "@/lib/db";

export const metadata: Metadata = { title: "Unsubscribe", robots: { index: false } };

const TOKEN = /^[a-f0-9]{32}$/;

async function unsubscribe(form: FormData) {
  "use server";
  const token = String(form.get("token") ?? "");
  if (TOKEN.test(token)) await sql`select unsubscribe_by_token(${token})`;
  redirect(`/u/${token}?done=1`);
}

/** The link at the bottom of every email. Public: no login. One click on the button stops all contact. */
export default async function Unsubscribe({ params, searchParams }: {
  params: Promise<{ token: string }>; searchParams: Promise<{ done?: string }>;
}) {
  const { token } = await params;
  const { done } = await searchParams;
  const [row] = TOKEN.test(token)
    ? await sql<{ do_not_contact: boolean }[]>`select do_not_contact from contacts where unsubscribe_token = ${token}`
    : [];
  return (
    <div className="frame narrow">
      <main style={{ paddingTop: 96 }}>
        {!row ? (
          <h1 className="statement">This link is not valid. If you want us to stop writing to you, simply reply to the email with
            &ldquo;unsubscribe&rdquo;.</h1>
        ) : row.do_not_contact || done ? (
          <>
            <h1 className="statement">You are unsubscribed. We will not contact you again.</h1>
            <p className="standfirst">This covers every brand we represent and every channel. You can close this page.</p>
          </>
        ) : (
          <>
            <h1 className="statement">Stop hearing from us?</h1>
            <p className="standfirst">One click and we will not contact you again, by email or any other way, for any brand we represent.</p>
            <form action={unsubscribe} style={{ marginTop: 32 }}>
              <input type="hidden" name="token" value={token} />
              <button className="btn solid">Unsubscribe</button>
            </form>
          </>
        )}
      </main>
    </div>
  );
}
