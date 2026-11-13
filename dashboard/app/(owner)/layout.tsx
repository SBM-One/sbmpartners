import type { Metadata } from "next";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import Icon from "@/components/Icon";
import NavLink from "@/components/NavLink";

export const metadata: Metadata = { title: "SBM Partners · Control room" };

export default async function OwnerLayout({ children }: { children: React.ReactNode }) {
  const staff = await requireStaff();
  const [c] = await sql<{ drafts: number; reports: number; playbook: number }[]>`
    select (select count(*)::int from outreach_drafts where status = 'pending_review') as drafts,
           (select count(*)::int from reports where status = 'draft') as reports,
           (select count(*)::int from playbook_entries where status = 'draft') as playbook`;
  const badge = (n: number) => (n > 0 ? <span className="badge">{n}</span> : null);
  return (
    <div className="shell">
      <aside className="side">
        <span className="wordmark">SBM <em>Partners</em></span>
        <div className="room">Control room</div>
        <nav aria-label="Control room">
          <NavLink href="/" className="navlink"><Icon name="overview" />Overview</NavLink>
          <NavLink href="/approvals" className="navlink"><Icon name="approvals" />Approvals{badge(c.drafts)}</NavLink>
          <NavLink href="/reports" className="navlink"><Icon name="reports" />Client reports{badge(c.reports)}</NavLink>
          <NavLink href="/playbook" className="navlink"><Icon name="playbook" />Playbook{badge(c.playbook)}</NavLink>
          <NavLink href="/clients" className="navlink"><Icon name="clients" />Clients</NavLink>
          <div className="group">Client view</div>
          <NavLink href="/portal" className="navlink"><Icon name="portal" />Preview the portal</NavLink>
        </nav>
        <form action="/auth/signout" method="post" className="foot">
          <span className="avatar">{staff.name.charAt(0).toUpperCase()}</span>
          <span className="who"><b>{staff.name}</b><span>{staff.role}</span></span>
          <button title="Sign out" aria-label="Sign out"><Icon name="signout" /></button>
        </form>
      </aside>
      <main className="page">{children}</main>
    </div>
  );
}
