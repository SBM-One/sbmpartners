import type { Metadata } from "next";
import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import NavLink from "@/components/NavLink";

export const metadata: Metadata = { title: "SBM Partners · Control room" };

export default async function OwnerLayout({ children }: { children: React.ReactNode }) {
  const staff = await requireStaff();
  const [c] = await sql<{ drafts: number; reports: number; playbook: number }[]>`
    select (select count(*)::int from outreach_drafts where status = 'pending_review') as drafts,
           (select count(*)::int from reports where status = 'draft') as reports,
           (select count(*)::int from playbook_entries where status = 'draft') as playbook`;
  const n = (v: number) => (v > 0 ? <sup>{v}</sup> : null);
  return (
    <div className="frame">
      <header className="mast">
        <div className="mast-left">
          <Link href="/" className="wordmark">SBM<i>Partners</i></Link>
          <nav aria-label="Control room">
            <NavLink href="/">Today</NavLink>
            <NavLink href="/approvals">Drafts{n(c.drafts)}</NavLink>
            <NavLink href="/reports">Letters{n(c.reports)}</NavLink>
            <NavLink href="/playbook">Playbook{n(c.playbook)}</NavLink>
            <NavLink href="/clients">Clients</NavLink>
          </nav>
        </div>
        <form action="/auth/signout" method="post" className="who">
          <span className="muted">{staff.name}</span>
          <button className="signout">Sign out</button>
        </form>
      </header>
      <main>{children}</main>
    </div>
  );
}
