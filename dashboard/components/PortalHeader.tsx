import Link from "next/link";
import type { PortalScope } from "@/lib/auth";
import { portalHref } from "@/lib/portal";
import { sql } from "@/lib/db";
import NavLink from "./NavLink";
import ClientSwitcher from "./ClientSwitcher";

/** The portal's masthead. Staff previewing a client's page also get a navy strip to switch clients or go back. */
export default async function PortalHeader({ scope }: { scope: PortalScope }) {
  const clients = scope.preview
    ? await sql<{ id: string; name: string }[]>`select id, name from clients where status <> 'churned' order by name`
    : [];
  return (
    <>
      {scope.preview && (
        <div className="strip">
          <div className="in">
            <span>You are seeing exactly what <b>{scope.clientName}</b> sees.</span>
            <ClientSwitcher clients={clients} current={scope.clientId} />
            <Link href="/">Back to the control room</Link>
          </div>
        </div>
      )}
      <div className="frame" style={{ paddingBottom: 0 }}>
        <header className="mast">
          <div className="mast-left">
            <Link href={portalHref(scope, "/portal")} className="wordmark">SBM<i>Partners</i></Link>
            <nav aria-label="Portal">
              <NavLink href={portalHref(scope, "/portal")}>{scope.clientName}</NavLink>
              <NavLink href={portalHref(scope, "/portal/reports")}>Letters</NavLink>
            </nav>
          </div>
          <form action="/auth/signout" method="post" className="who">
            <span className="muted">{scope.viewerName}</span>
            {!scope.preview && <button className="signout">Sign out</button>}
          </form>
        </header>
      </div>
    </>
  );
}
