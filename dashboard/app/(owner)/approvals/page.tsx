import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, sentence } from "@/lib/format";
import { reviewDraft } from "../../actions";
import Submit from "@/components/Submit";

type Draft = {
  id: string; created_at: Date; client: string; contact: string; contact_title: string | null; email: string | null;
  company: string | null; buyer_type: string | null; website: string | null; channel: string; step: number;
  subject: string | null; body: string; score: number | null; grade_feedback: string | null; rewrites: number;
  playbook_used: string[]; research: { summary?: string; angle?: string; cautions?: string; fit?: number;
    facts?: { fact: string; source_url: string }[] };
};
type Recent = { id: string; status: string; reviewed_at: Date | null; reviewed_by: string | null; contact: string;
  company: string | null; client: string; subject: string | null; review_note: string | null };

const WORDS = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"];

export default async function Approvals() {
  await requireStaff();
  const [drafts, recent] = await Promise.all([
    sql<Draft[]>`
      select d.id, d.created_at, cl.name as client, trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as contact,
             c.title as contact_title, c.email, co.name as company, co.type::text as buyer_type, co.website,
             d.channel::text, d.step, d.subject, d.body, d.score, d.grade_feedback, d.rewrites, d.playbook_used, d.research
      from outreach_drafts d
      join clients cl on cl.id = d.client_id
      join contacts c on c.id = d.contact_id
      left join companies co on co.id = d.company_id
      where d.status = 'pending_review'
      order by d.created_at
      limit 25`,
    sql<Recent[]>`
      select d.id, d.status::text, d.reviewed_at, d.reviewed_by, d.subject, d.review_note, cl.name as client,
             trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as contact, co.name as company
      from outreach_drafts d join contacts c on c.id = d.contact_id left join companies co on co.id = d.company_id
      join clients cl on cl.id = d.client_id
      where d.status <> 'pending_review' order by d.reviewed_at desc nulls last limit 15`,
  ]);

  return (
    <>
      <h1 className="statement" style={{ marginTop: 56 }}>
        {drafts.length === 0 ? "No drafts are waiting." : `${WORDS[drafts.length] ?? drafts.length} draft${drafts.length === 1 ? " is" : "s are"} waiting.`}
        {" "}Nothing reaches a buyer until you approve it.
      </h1>
      <p className="standfirst">Edit anything. What you approve is exactly what goes out. The research and the Grader&apos;s notes sit under each draft.</p>

      <section className="section tight">
        <div className="sh"><h2>Drafts<span className="count">{drafts.length}</span></h2><span className="aside">Oldest first</span></div>
        {drafts.length === 0 && <p className="empty">The agents add new drafts as they research buyers.</p>}
        {drafts.map((d) => {
          const verdict = d.score == null ? "Not graded yet." : d.score >= 80 ? "Ready to send." : d.score >= 65 ? "Worth a second look." : "Needs rework.";
          return (
            <article className="spread" key={d.id} id={`d-${d.id}`}>
              <div className="who">
                <h3>{d.contact || "(no name)"}</h3>
                <div className="sub">{[d.contact_title, d.company].filter(Boolean).join(", ") || "Role unknown"}</div>
                <dl className="facts">
                  <dt>For</dt><dd>{d.client}</dd>
                  <dt>Buyer</dt><dd>{sentence(d.buyer_type) || "Unknown"}</dd>
                  <dt>Send by</dt><dd>{sentence(d.channel)}, {d.step > 1 ? `follow-up ${d.step - 1}` : "first message"}</dd>
                  {d.email && <><dt>To</dt><dd style={{ wordBreak: "break-all" }}>{d.email}</dd></>}
                  <dt>Written</dt><dd>{ago(d.created_at)}</dd>
                </dl>
                <div className={`grade ${d.score != null && d.score < 65 ? "low" : ""}`}>
                  <b>{d.score ?? "–"}</b>out of 100. {verdict}
                  {(d.rewrites > 0 || d.research?.fit != null) && (
                    <div className="muted" style={{ marginTop: 4 }}>
                      {[d.rewrites > 0 && "Rewritten once", d.research?.fit != null && `Fit ${d.research.fit} of 5`].filter(Boolean).join(". ")}.
                    </div>
                  )}
                </div>
              </div>

              <form action={reviewDraft} className="words">
                <input type="hidden" name="id" value={d.id} />
                {d.channel === "email" && <label className="field subject"><span>Subject</span><input name="subject" defaultValue={d.subject ?? ""} /></label>}
                <label className="field body"><span>Message</span><textarea name="body" defaultValue={d.body} /></label>
                <label className="field"><span>Note for the team, if any</span><input name="note" placeholder="Why you approved, changed or rejected it" /></label>
                <div className="acts">
                  <Submit name="decision" value="approved" className="solid">Approve and queue</Submit>
                  <Submit name="decision" value="rejected" className="textbtn alarm">Reject</Submit>
                  {d.website && <a className="textbtn quiet" href={d.website} target="_blank" rel="noreferrer noopener">Their website</a>}
                </div>
                <details className="research">
                  <summary>Research and the Grader&apos;s notes</summary>
                  <div className="body">
                    {d.grade_feedback && <div><h4>Grader</h4><p style={{ whiteSpace: "pre-wrap" }}>{d.grade_feedback}</p></div>}
                    {d.research?.summary && <div><h4>What research found</h4><p>{d.research.summary}</p></div>}
                    {d.research?.facts && d.research.facts.length > 0 && (
                      <div><h4>Sourced facts</h4>
                        <ol>{d.research.facts.map((f, j) => <li key={j}>{f.fact} <a href={f.source_url} target="_blank" rel="noreferrer noopener">source</a></li>)}</ol>
                      </div>
                    )}
                    {d.research?.angle && <div><h4>Angle</h4><p>{d.research.angle}</p></div>}
                    {d.research?.cautions && <div><h4>Cautions</h4><p>{d.research.cautions}</p></div>}
                    {d.playbook_used?.length > 0 && <div><h4>Playbook used</h4><p>{d.playbook_used.join(", ")}</p></div>}
                  </div>
                </details>
              </form>
            </article>
          );
        })}
      </section>

      <section className="section">
        <div className="sh"><h2>Decided recently</h2><span className="aside">The last 15</span></div>
        {recent.length === 0 ? <p className="empty">Your decisions will show here.</p> : (
          <div className="scroll">
            <table className="ledger">
              <tbody>
                {recent.map((r) => (
                  <tr key={r.id}>
                    <td className={`lead ${r.status === "rejected" ? "alarm" : ""}`}>{sentence(r.status)}</td>
                    <td><div className="name" style={{ fontSize: 15.5 }}>{r.contact}{r.company ? `, ${r.company}` : ""}</div><div className="sub">For {r.client}</div></td>
                    <td className="small">{r.subject ?? <span className="faint">No subject</span>}{r.review_note && <div className="muted">{r.review_note}</div>}</td>
                    <td className="num small muted">{r.reviewed_by ?? ""}<div>{ago(r.reviewed_at)}</div></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <p className="after">The database itself refuses to approve or send anything to a buyer marked do-not-contact.</p>
      </section>
    </>
  );
}
