import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePortal } from "@/lib/auth";
import { portalHref, portalQuery } from "@/lib/portal";
import { dayLong } from "@/lib/format";
import PortalHeader from "@/components/PortalHeader";

type Report = { id: string; kind: string; period_start: Date; period_end: Date; summary: string | null; body: string | null;
  approved_at: Date | null };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function PortalReport({ params, searchParams }: {
  params: Promise<{ id: string }>; searchParams: Promise<{ client?: string }>;
}) {
  const { id } = await params;
  const scope = await requirePortal((await searchParams).client);
  if (!UUID.test(id)) notFound();
  const [r] = await portalQuery(scope, (q) => q<Report[]>`
    select id, kind, period_start, period_end, summary, body, approved_at from reports
    where id = ${id} and client_id = ${scope.clientId} and status in ('approved','sent')`);
  if (!r) notFound();

  // Short lines without a full stop ("This week in brief", "Next week") read as headings.
  const blocks = (r.body ?? r.summary ?? "").split(/\n\s*\n/).map((b) => b.trim()).filter(Boolean);

  return (
    <>
      <PortalHeader scope={scope} />
      <main className="frame">
        <article className="letter">
          <div className="period">{dayLong(r.period_start)} to {dayLong(r.period_end)}</div>
          <h1>{r.summary ?? "Your week in brief."}</h1>
          <div className="content">
            {blocks.map((b, i) => b.length < 48 && !/[.!?]$/.test(b)
              ? <h3 key={i}>{b}</h3>
              : <p key={i}>{b.split("\n").map((line, j) => <span key={j}>{j > 0 && <br />}{line}</span>)}</p>)}
          </div>
          <div className="sign">
            <span>Your team at SBM Partners{r.approved_at ? `, ${dayLong(r.approved_at)}` : ""}</span>
            <Link className="textbtn" href={portalHref(scope, "/portal/reports")}>All letters</Link>
          </div>
        </article>
      </main>
    </>
  );
}
