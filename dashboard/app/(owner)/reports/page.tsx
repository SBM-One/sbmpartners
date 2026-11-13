import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, day, dayLong } from "@/lib/format";
import { reviewReport } from "../../actions";
import Submit from "@/components/Submit";

type Report = { id: string; client_id: string; client: string; kind: string; period_start: Date; period_end: Date; status: string;
  summary: string | null; body: string | null; created_at: Date; approved_at: Date | null };

export default async function Reports() {
  await requireStaff();
  const reports = await sql<Report[]>`
    select r.id, r.client_id, c.name as client, r.kind, r.period_start, r.period_end, r.status, r.summary, r.body, r.created_at, r.approved_at
    from reports r join clients c on c.id = r.client_id
    order by (r.status = 'draft') desc, r.period_start desc limit 40`;
  const drafts = reports.filter((r) => r.status === "draft");
  const done = reports.filter((r) => r.status !== "draft");

  return (
    <>
      <header className="ph rise">
        <div>
          <span className="eyebrow">Client reports</span>
          <h1>Every Monday, <em className="accent">a clear story.</em></h1>
          <p>The Reporter drafts each client&apos;s weekly report. Read it, edit it, and approve it. Clients only ever see
            approved reports, in their portal.</p>
        </div>
        <div className="aside"><span className="pill blue">{drafts.length} to approve</span></div>
      </header>

      {drafts.length === 0 && <div className="empty boxed"><b>Nothing to approve</b>New drafts arrive every Monday morning.</div>}
      <div className="grid g2">
        {drafts.map((r, i) => (
          <form action={reviewReport} className={`card lift rise d${Math.min(i + 1, 4)}`} key={r.id} style={{ padding: "24px 26px", display: "flex", flexDirection: "column", gap: 16 }}>
            <input type="hidden" name="id" value={r.id} />
            <div className="row" style={{ justifyContent: "space-between" }}>
              <span className="pill gold">{r.client}</span>
              <span className="xs muted">Drafted {ago(r.created_at)}</span>
            </div>
            <div>
              <h3 style={{ fontSize: 22 }}>{r.kind === "weekly" ? "Weekly" : "Monthly"} report</h3>
              <div className="small muted">{dayLong(r.period_start)} to {dayLong(r.period_end)}</div>
            </div>
            {r.summary && <p style={{ fontFamily: "var(--font-serif)", fontStyle: "italic", fontSize: 19, lineHeight: 1.35, color: "var(--ink)" }}>{r.summary}</p>}
            <label className="field"><span>Report (edit freely)</span>
              <textarea name="body" defaultValue={r.body ?? r.summary ?? ""} style={{ minHeight: 240 }} /></label>
            <div className="row">
              <Submit name="decision" value="approve" className="primary dash">Approve for client</Submit>
              <Submit name="decision" value="save">Save edits</Submit>
              <Link className="btn quiet" href={`/portal?client=${r.client_id}`}>See their portal</Link>
            </div>
          </form>
        ))}
      </div>

      <div className="section-title"><h2>Approved and shared</h2><span className="note">Visible in each client&apos;s portal</span></div>
      {done.length === 0 ? <div className="empty boxed"><b>None yet</b>Approved reports will be listed here.</div> : (
        <div className="card table-scroll">
          <table className="table">
            <thead><tr><th>Client</th><th>Week</th><th>Headline</th><th>Status</th><th className="num">Approved</th></tr></thead>
            <tbody>
              {done.map((r) => (
                <tr key={r.id}>
                  <td className="title">{r.client}</td>
                  <td className="small nowrap">{day(r.period_start)} to {day(r.period_end)}</td>
                  <td>{r.summary}</td>
                  <td><span className="pill ok">{r.status === "sent" ? "Sent" : "Approved"}</span></td>
                  <td className="num small muted">{ago(r.approved_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
