import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago } from "@/lib/format";
import { reviewReport } from "../actions";
import Submit from "@/components/Submit";

type Report = { id: string; client: string; kind: string; period_start: Date; period_end: Date; status: string;
  summary: string | null; body: string | null; created_at: Date; approved_at: Date | null };

const day = (d: Date) => new Date(d).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });

export default async function Reports() {
  await requireStaff();
  const reports = await sql<Report[]>`
    select r.id, c.name as client, r.kind, r.period_start, r.period_end, r.status, r.summary, r.body, r.created_at, r.approved_at
    from reports r join clients c on c.id = r.client_id
    order by (r.status = 'draft') desc, r.period_start desc limit 40`;
  const drafts = reports.filter((r) => r.status === "draft");
  const done = reports.filter((r) => r.status !== "draft");

  return (
    <>
      <h1>Client reports</h1>
      <p className="lead">The Reporter drafts each client&apos;s report every Monday. Clients only see a report after you approve it.</p>

      {drafts.length === 0 && <div className="empty">No reports waiting for approval.</div>}
      {drafts.map((r) => (
        <form action={reviewReport} className="card" key={r.id} style={{ marginBottom: 16 }}>
          <input type="hidden" name="id" value={r.id} />
          <h3 style={{ margin: 0 }}>{r.client} · {r.kind} report</h3>
          <div className="muted small">{day(r.period_start)} to {day(r.period_end)} · drafted {ago(r.created_at)}</div>
          <label>Report (edit freely)</label>
          <textarea name="body" defaultValue={r.body ?? r.summary ?? ""} style={{ minHeight: 260 }} />
          <div className="row" style={{ marginTop: 12 }}>
            <Submit name="decision" value="approve" className="primary">Approve for client</Submit>
            <Submit name="decision" value="save">Save edits</Submit>
          </div>
        </form>
      ))}

      <h2>Approved and sent</h2>
      {done.length === 0 ? <div className="empty">None yet.</div> : (
        <table>
          <thead><tr><th>Client</th><th>Period</th><th>Headline</th><th>Status</th></tr></thead>
          <tbody>
            {done.map((r) => (
              <tr key={r.id}>
                <td>{r.client}</td>
                <td className="small">{day(r.period_start)} to {day(r.period_end)}</td>
                <td>{r.summary}</td>
                <td><span className="pill ok">{r.status}</span> <span className="muted small">{ago(r.approved_at)}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
