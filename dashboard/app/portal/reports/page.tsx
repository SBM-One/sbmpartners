import Link from "next/link";
import { requirePortal } from "@/lib/auth";
import { portalHref, portalQuery } from "@/lib/portal";
import { dayLong } from "@/lib/format";
import PortalHeader from "@/components/PortalHeader";

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
      <main className="frame">
        <h1 className="statement" style={{ marginTop: 56 }}>Every Monday we write to you about the week.</h1>
        <section className="section tight">
          <div className="sh"><h2>Letters<span className="count">{reports.length}</span></h2></div>
          {reports.length === 0 ? <p className="empty">Your first letter arrives on Monday.</p> : (
            <div className="index">
              {reports.map((r) => (
                <Link key={r.id} href={portalHref(scope, `/portal/reports/${r.id}`)}>
                  <span className="d">{dayLong(r.period_start)}</span>
                  <span className="t">{r.summary ?? `${r.kind === "weekly" ? "Weekly" : "Monthly"} letter`}</span>
                  <span className="r">Read</span>
                </Link>
              ))}
            </div>
          )}
        </section>
      </main>
    </>
  );
}
