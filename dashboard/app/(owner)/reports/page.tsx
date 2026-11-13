import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, day, dayLong } from "@/lib/format";
import { reviewReport } from "../../actions";
import Submit from "@/components/Submit";

type Report = { id: string; client_id: string; client: string; kind: string; period_start: Date; period_end: Date; status: string;
  summary: string | null; body: string | null; created_at: Date; approved_at: Date | null };

const WORDS = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"];

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
      <h1 className="statement" style={{ marginTop: 56 }}>
        {drafts.length === 0 ? "Every letter has gone out." : `${WORDS[drafts.length] ?? drafts.length} letter${drafts.length === 1 ? " is" : "s are"} ready for your eye.`}
      </h1>
      <p className="standfirst">The Reporter drafts each client&apos;s weekly letter. Clients only see a letter after you approve it.</p>

      <section className="section tight">
        <div className="sh"><h2>To approve<span className="count">{drafts.length}</span></h2></div>
        {drafts.length === 0 && <p className="empty">New drafts arrive every Monday morning.</p>}
        {drafts.map((r) => (
          <article className="spread" key={r.id} id={`r-${r.id}`}>
            <div className="who">
              <h3>{r.client}</h3>
              <div className="sub">{r.kind === "weekly" ? "Weekly" : "Monthly"} letter</div>
              <dl className="facts">
                <dt>Covers</dt><dd>{day(r.period_start)} to {day(r.period_end)}</dd>
                <dt>Drafted</dt><dd>{ago(r.created_at)}</dd>
              </dl>
              {r.summary && <div className="grade">Headline: {r.summary}</div>}
            </div>
            <form action={reviewReport} className="words">
              <input type="hidden" name="id" value={r.id} />
              <label className="field letterbody"><span>The letter</span><textarea name="body" defaultValue={r.body ?? r.summary ?? ""} /></label>
              <div className="acts">
                <Submit name="decision" value="approve" className="solid">Approve for {r.client}</Submit>
                <Submit name="decision" value="save" className="textbtn">Save edits</Submit>
                <Link className="textbtn quiet" href={`/portal?client=${r.client_id}`}>See their page</Link>
              </div>
            </form>
          </article>
        ))}
      </section>

      <section className="section">
        <div className="sh"><h2>Sent to clients</h2><span className="aside">{done.length} letters</span></div>
        {done.length === 0 ? <p className="empty">Approved letters will be listed here.</p> : (
          <div className="index">
            {done.map((r) => (
              <Link key={r.id} href={`/portal/reports/${r.id}?client=${r.client_id}`}>
                <span className="d">{r.client}<br />{dayLong(r.period_start)}</span>
                <span className="t">{r.summary ?? "Weekly letter"}</span>
                <span className="r">{r.approved_at ? `Approved ${ago(r.approved_at)}` : "Read"}</span>
              </Link>
            ))}
          </div>
        )}
      </section>
    </>
  );
}
