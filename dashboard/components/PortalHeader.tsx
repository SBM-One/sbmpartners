import Link from "next/link";
import type { PortalScope } from "@/lib/auth";
import { portalHref } from "@/lib/portal";
import { sql } from "@/lib/db";
import Icon from "./Icon";
import NavLink from "./NavLink";
import ClientSwitcher from "./ClientSwitcher";

/** The portal's top bar. Staff previewing a client's portal also get a navy strip to switch clients or go back. */
export default async function PortalHeader({ scope }: { scope: PortalScope }) {
  const clients = scope.preview
    ? await sql<{ id: string; name: string }[]>`select id, name from clients where status <> 'churned' order by name`
    : [];
  return (
    <>
      {scope.preview && (
        <div className="preview-bar">
          <div className="in">
            <Icon name="portal" size={16} />
            <span>Preview: you&apos;re seeing exactly what <b>{scope.clientName}</b> sees.</span>
            <ClientSwitcher clients={clients} current={scope.clientId} />
            <Link href="/">Back to the control room</Link>
          </div>
        </div>
      )}
      <header className="topbar">
        <div className="in">
          <Link href={portalHref(scope, "/portal")} className="wordmark" style={{ color: "var(--ink)" }}>SBM <em>Partners</em></Link>
          <nav aria-label="Portal">
            <NavLink href={portalHref(scope, "/portal")}>Overview</NavLink>
            <NavLink href={portalHref(scope, "/portal/pipeline")}>Pipeline</NavLink>
            <NavLink href={portalHref(scope, "/portal/reports")}>Reports</NavLink>
          </nav>
          <form action="/auth/signout" method="post" className="acct">
            <span className="name"><b>{scope.clientName}</b><span>{scope.viewerName}</span></span>
            <span className="avatar">{scope.clientName.charAt(0)}</span>
            {!scope.preview && <button title="Sign out" aria-label="Sign out"><Icon name="signout" /></button>}
          </form>
        </div>
      </header>
    </>
  );
}
