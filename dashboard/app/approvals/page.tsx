import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, label } from "@/lib/format";
import { reviewDraft } from "../actions";
import Submit from "@/components/Submit";

type Draft = {
  id: string; created_at: Date; client: string; contact: string; contact_title: string | null; email: string | null;
  company: string | null; buyer_type: string | null; website: string | null; channel: string; step: number;
  subject: string | null; body: string; score: number | null; grade_feedback: string | null; rewrites: number;
  playbook_used: string[]; research: { summary?: string; angle?: string; cautions?: string; fit?: number;
    facts?: { fact: string; source_url: string }[] };
};
type Recent = { id: string; status: string; reviewed_at: Date | null; reviewed_by: string | null; contact: string;
  company: string | null; subject: string | null; review_note: string | null };

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
      select d.id, d.status::text, d.reviewed_at, d.reviewed_by, d.subject, d.review_note,
             trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as contact, co.name as company
      from outreach_drafts d join contacts c on c.id = d.contact_id left join companies co on co.id = d.company_id
      where d.status <> 'pending_review' order by d.reviewed_at desc nulls last limit 15`,
  ]);

  return (
    <>
      <h1>Approvals</h1>
      <p className="lead">Nothing is sent until you approve it. Edit the text if you like, then approve or reject.
        Your edits are what will be sent.</p>

      {drafts.length === 0 && <div className="empty">No drafts waiting. The agents will add new ones as they research buyers.</div>}

      {drafts.map((d) => (
        <div className="card draft" key={d.id}>
          <form action={reviewDraft}>
            <input type="hidden" name="id" value={d.id} />
            <h3>{d.contact || "(no name)"}{d.company ? ` · ${d.company}` : ""}</h3>
            <div className="meta">
              {d.contact_title ?? "role unknown"} · {label(d.buyer_type) || "buyer"} · for <b>{d.client}</b> ·{" "}
              {d.channel}{d.step > 1 ? ` follow-up ${d.step - 1}` : " first message"} · {ago(d.created_at)}
            </div>
            {d.email && <div className="meta">To: {d.email}</div>}
            {d.channel === "email" && (
              <>
                <label>Subject</label>
                <input name="subject" defaultValue={d.subject ?? ""} />
              </>
            )}
            <label>Message</label>
            <textarea name="body" defaultValue={d.body} />
            <label>Note (optional, for the team)</label>
            <input name="note" placeholder="Why you approved, rejected or changed it" />
            <div className="row" style={{ marginTop: 14 }}>
              <Submit name="decision" value="approved" className="primary">Approve</Submit>
              <Submit name="decision" value="rejected" className="danger">Reject</Submit>
            </div>
          </form>

          <div>
            <div className="row">
              <span className={`pill ${d.score == null ? "" : d.score >= 80 ? "ok" : d.score >= 65 ? "warning" : "bad"}`}>
                Grader: {d.score ?? "–"}/100
              </span>
              {d.rewrites > 0 && <span className="pill">rewritten once</span>}
              {d.research?.fit != null && <span className="pill">fit {d.research.fit}/5</span>}
            </div>
            {d.grade_feedback && (<><label>Grader&apos;s notes</label><div className="feedback">{d.grade_feedback}</div></>)}
            {d.research?.summary && (<><label>What research found</label><div className="small">{d.research.summary}</div></>)}
            {d.research?.facts && d.research.facts.length > 0 && (
              <ul className="facts">
                {d.research.facts.map((f, i) => (
                  <li key={i}>{f.fact} <a href={f.source_url} target="_blank" rel="noreferrer noopener">source</a></li>
                ))}
              </ul>
            )}
            {d.research?.cautions && (<><label>Cautions</label><div className="small">{d.research.cautions}</div></>)}
            {d.playbook_used?.length > 0 && (<><label>Playbook used</label><div className="small">{d.playbook_used.join(" · ")}</div></>)}
            {d.website && <p className="small"><a href={d.website} target="_blank" rel="noreferrer noopener">Their website</a></p>}
          </div>
        </div>
      ))}

      <h2>Recently reviewed</h2>
      {recent.length === 0 ? <div className="empty">Nothing reviewed yet.</div> : (
        <table>
          <thead><tr><th>Buyer</th><th>Subject</th><th>Decision</th><th>By</th><th>When</th></tr></thead>
          <tbody>
            {recent.map((r) => (
              <tr key={r.id}>
                <td>{r.contact}{r.company ? ` · ${r.company}` : ""}</td>
                <td>{r.subject ?? "–"}{r.review_note && <div className="muted small">{r.review_note}</div>}</td>
                <td><span className={`pill ${r.status === "approved" || r.status === "sent" ? "ok" : r.status === "rejected" ? "bad" : ""}`}>{r.status}</span></td>
                <td className="small">{r.reviewed_by ?? "–"}</td>
                <td className="small">{ago(r.reviewed_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
