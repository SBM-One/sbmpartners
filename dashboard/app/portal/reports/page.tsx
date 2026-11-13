import Link from "next/link";
import { requirePortal } from "@/lib/auth";
import { portalHref, portalQuery } from "@/lib/portal";
import { dayLong } from "@/lib/format";
import PortalHeader from "@/components/PortalHeader";
import Icon from "@/components/Icon";

type Report = { id: string; kind: string; period_start: Date; period_end: Date; summary: string | null };

export default async function PortalReports({ searchParams }: { searchParams: Promise<{ client?: string }> }) {
  const scope = await requirePortal((await searchParams).client);
  const reports = await portalQuery(scope, (q) => q<Report[]>`
    select id, kind, period_start, period_end, summary from reports
    where client_id = ${scope.clientId} and status in ('approved','sent')
    order by period_start desc limit 52`);

  return (
    <>
      <PortalHeader scope={scope} />
      <main className="pmain">
        <header className="ph rise">
          <div>
            <span className="eyebrow">Reports</span>
            <h1>Your weekly <em className="accent">reports.</em></h1>
            <p>Every Monday your SBM Partners team writes up what happened, what came back and what&apos;s next.</p>
          </div>
        </header>
        {reports.length === 0 ? <div className="empty boxed"><b>Your first report arrives on Monday</b>We&apos;ll email you when it&apos;s ready.</div> : (
          <div className="card list report-list rise d1">
            {reports.map((r, i) => (
              <Link className="item" key={r.id} href={portalHref(scope, `/portal/reports/${r.id}`)} style={{ alignItems: "center", padding: "20px 24px" }}>
                <span className="monogram" style={{ fontSize: 18 }}>{i === 0 ? "★" : "W"}</span>
                <div className="body">
                  <div className="title" style={{ fontSize: 16 }}>{r.summary ?? `${r.kind === "weekly" ? "Weekly" : "Monthly"} report`}</div>
                  <div className="meta">{dayLong(r.period_start)} to {dayLong(r.period_end)}</div>
                </div>
                {i === 0 && <span className="pill gold">Latest</span>}
                <span className="end muted"><Icon name="arrow" size={18} /></span>
              </Link>
            ))}
          </div>
        )}
      </main>
    </>
  );
}
