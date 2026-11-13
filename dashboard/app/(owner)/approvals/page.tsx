import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, sentence } from "@/lib/format";
import { reviewDraft } from "../../actions";
import Submit from "@/components/Submit";
import { ScoreRing } from "@/components/Charts";

type Draft = {
  id: string; created_at: Date; client: string; contact: string; contact_title: string | null; email: string | null;
  company: string | null; buyer_type: string | null; website: string | null; channel: string; step: number;
  subject: string | null; body: string; score: number | null; grade_feedback: string | null; rewrites: number;
  playbook_used: string[]; research: { summary?: string; angle?: string; cautions?: string; fit?: number;
    facts?: { fact: string; source_url: string }[] };
};
type Recent = { id: string; status: string; reviewed_at: Date | null; reviewed_by: string | null; contact: string;
  company: string | null; client: string; subject: string | null; review_note: string | null };

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
      <header className="ph rise">
        <div>
          <span className="eyebrow">Approvals</span>
          <h1>Nothing leaves <em className="accent">without you.</em></h1>
          <p>Each draft sits next to the research behind it and the Grader&apos;s notes. Edit anything you like; what you
            approve is exactly what gets sent.</p>
        </div>
        <div className="aside"><span className="pill blue">{drafts.length} waiting</span></div>
      </header>

      {drafts.length === 0 && (
        <div className="empty boxed"><b>The queue is clear</b>The agents will add new drafts as they research buyers.</div>
      )}

      {drafts.map((d, i) => {
        const tone = d.score == null ? "" : d.score >= 80 ? "ok" : d.score >= 65 ? "warning" : "bad";
        const verdict = d.score == null ? "Not graded" : d.score >= 80 ? "Ready to send" : d.score >= 65 ? "Worth a second look" : "Needs rework";
        return (
          <article className={`card lift draft rise d${Math.min(i + 1, 4)}`} key={d.id}>
            <form action={reviewDraft} className="compose">
              <input type="hidden" name="id" value={d.id} />
              <div className="to">
                <span className="monogram">{(d.company ?? d.contact ?? "?").charAt(0)}</span>
                <div>
                  <h3>{d.contact || "(no name)"}{d.company ? <span className="muted" style={{ fontWeight: 400 }}> · {d.company}</span> : ""}</h3>
                  <div className="meta">{d.contact_title ?? "Role unknown"} · {sentence(d.buyer_type) || "Buyer"}{d.email ? ` · ${d.email}` : ""}</div>
                </div>
              </div>
              <div className="row">
                <span className="pill gold">For {d.client}</span>
                <span className="pill">{sentence(d.channel)} · {d.step > 1 ? `follow-up ${d.step - 1}` : "first message"}</span>
                <span className="pill">Written {ago(d.created_at)}</span>
              </div>
              {d.channel === "email" && (
                <label className="field"><span>Subject</span><input name="subject" defaultValue={d.subject ?? ""} /></label>
              )}
              <label className="field message"><span>Message</span><textarea name="body" defaultValue={d.body} /></label>
              <label className="field"><span>Note for the team (optional)</span>
                <input name="note" placeholder="Why you approved, rejected or changed it" /></label>
              <div className="row">
                <Submit name="decision" value="approved" className="primary dash">Approve and queue</Submit>
                <Submit name="decision" value="rejected" className="danger">Reject</Submit>
              </div>
            </form>

            <aside className="dossier">
              <div className="score">
                <ScoreRing score={d.score} />
                <div>
                  <b>{verdict}</b>
                  <span>Grader score out of 100{d.rewrites > 0 ? " · rewritten once" : ""}{d.research?.fit != null ? ` · fit ${d.research.fit}/5` : ""}</span>
                </div>
                <span className={`pill ${tone}`} style={{ marginLeft: "auto" }}>{d.score ?? "–"}</span>
              </div>
              {d.grade_feedback && <div><h4>Grader&apos;s notes</h4><div className="notes">{d.grade_feedback}</div></div>}
              {d.research?.summary && <div><h4>What research found</h4><p className="text">{d.research.summary}</p></div>}
              {d.research?.facts && d.research.facts.length > 0 && (
                <div><h4>Sourced facts</h4>
                  <ul className="facts">
                    {d.research.facts.map((f, j) => (
                      <li key={j}><span>{f.fact} <a href={f.source_url} target="_blank" rel="noreferrer noopener">Source</a></span></li>
                    ))}
                  </ul>
                </div>
              )}
              {d.research?.angle && <div><h4>Angle</h4><p className="text">{d.research.angle}</p></div>}
              {d.research?.cautions && <div><h4>Cautions</h4><p className="text">{d.research.cautions}</p></div>}
              {d.playbook_used?.length > 0 && (
                <div><h4>Playbook used</h4><div className="tags">{d.playbook_used.map((p) => <span className="pill blue" key={p}>{p}</span>)}</div></div>
              )}
              {d.website && <a className="small" href={d.website} target="_blank" rel="noreferrer noopener">Open their website</a>}
            </aside>
          </article>
        );
      })}

      <div className="section-title"><h2>Recently reviewed</h2><span className="note">Last 15 decisions</span></div>
      {recent.length === 0 ? <div className="empty boxed"><b>Nothing reviewed yet</b>Your decisions will show here.</div> : (
        <div className="card table-scroll">
          <table className="table">
            <thead><tr><th>Buyer</th><th>Subject</th><th>Decision</th><th>By</th><th className="num">When</th></tr></thead>
            <tbody>
              {recent.map((r) => (
                <tr key={r.id}>
                  <td><div className="title">{r.contact}{r.company ? ` · ${r.company}` : ""}</div><div className="sub">For {r.client}</div></td>
                  <td>{r.subject ?? "–"}{r.review_note && <div className="sub">{r.review_note}</div>}</td>
                  <td><span className={`pill ${r.status === "approved" || r.status === "sent" ? "ok" : r.status === "rejected" ? "bad" : ""}`}>{sentence(r.status)}</span></td>
                  <td className="small muted">{r.reviewed_by ?? "–"}</td>
                  <td className="num small muted">{ago(r.reviewed_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="xs faint" style={{ marginTop: 12 }}>The database itself refuses to approve or send anything to a buyer marked do-not-contact.</p>
    </>
  );
}
