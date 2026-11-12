import type { Metadata } from "next";
import Link from "next/link";
import { getStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import "./globals.css";

export const metadata: Metadata = { title: "SBM Partners · Control room", robots: { index: false } };
export const dynamic = "force-dynamic";

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const staff = await getStaff();
  let waiting = 0;
  let reports = 0;
  if (staff) {
    const [c] = await sql<{ drafts: number; reports: number }[]>`
      select (select count(*)::int from outreach_drafts where status = 'pending_review') as drafts,
             (select count(*)::int from reports where status = 'draft') as reports`;
    waiting = c.drafts;
    reports = c.reports;
  }
  return (
    <html lang="en">
      <body>
        {staff && (
          <header className="top">
            <Link href="/" className="brand">SBM Partners <span>control room</span></Link>
            <nav>
              <Link href="/">Overview</Link>
              <Link href="/approvals">Approvals{waiting > 0 && <b className="count">{waiting}</b>}</Link>
              <Link href="/reports">Reports{reports > 0 && <b className="count">{reports}</b>}</Link>
              <Link href="/playbook">Playbook</Link>
              <Link href="/clients">Clients</Link>
            </nav>
            <form action="/auth/signout" method="post" className="who">
              <span>{staff.name}</span>
              <button className="link">Sign out</button>
            </form>
          </header>
        )}
        <main>{children}</main>
      </body>
    </html>
  );
}
