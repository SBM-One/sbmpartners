import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, sentence } from "@/lib/format";
import { reviewDraft, stopContact, updateContactSending } from "../../actions";
import Submit from "@/components/Submit";

type Draft = {
  id: string; created_at: Date; client: string; contact: string; contact_title: string | null; email: string | null;
  company: string | null; buyer_type: string | null; website: string | null; channel: string; step: number;
  subject: string | null; body: string; score: number | null; grade_feedback: string | null; rewrites: number;
  contact_id: string; country: string | null; email_basis: string; email_source: string | null; blockers: string[];
  purpose: string; reply_text: string | null; reply_summary: string | null; reply_at: Date | null;
  fit_score: number | null; pitch_angle: string | null; lead_with: string[] | null; channel_reason: string | null;
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
             d.channel::text, d.step, d.subject, d.body, d.score, d.grade_feedback, d.rewrites, d.playbook_used, d.research,
             d.contact_id, coalesce(c.country, co.country) as country, c.email_basis, c.email_source, send_blockers(d.id) as blockers,
             d.purpose, ri.body as reply_text, ri.metadata->>'summary' as reply_summary, ri.occurred_at as reply_at,
             ps.fit_score, ps.pitch_angle, ps.lead_with, ps.channel_reason
      from outreach_drafts d
      join clients cl on cl.id = d.client_id
      join contacts c on c.id = d.contact_id
      left join companies co on co.id = d.company_id
      left join interactions ri on ri.id = d.reply_to_interaction_id
      left join prospect_strategies ps on ps.id = d.strategy_id
      where d.status = 'pending_review'
      order by case d.purpose when 'reply' then 0 else 1 end, d.created_at
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
      <p className="standfirst">Edit anything. What you approve is exactly what goes out: emails leave the mailbox slowly within its daily
        limit, and LinkedIn notes go to your LinkedIn list to send by hand. The research and the Grader&apos;s notes sit under each draft.</p>

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
                  <dt>Send by</dt><dd>{sentence(d.channel)}, {d.purpose === "reply" ? "answer to their reply" : d.purpose === "check_in"
                    ? "check-in after their \u201cnot now\u201d" : d.step > 1 ? `follow-up ${d.step - 1}` : "first message"}</dd>
                  {d.email && <><dt>To</dt><dd style={{ wordBreak: "break-all" }}>{d.email}</dd></>}
                  <dt>Written</dt><dd>{ago(d.created_at)}</dd>
                </dl>
                <div className={`grade ${d.score != null && d.score < 65 ? "low" : ""}`}>
                  <b>{d.score ?? "–"}</b>out of 100. {verdict}
                  {(d.rewrites > 0 || d.fit_score != null || d.research?.fit != null) && (
                    <div className="muted" style={{ marginTop: 4 }}>
                      {[d.rewrites > 0 && "Rewritten once", d.fit_score != null ? `Fit ${d.fit_score} of 100` : d.research?.fit != null && `Fit ${d.research.fit} of 5`].filter(Boolean).join(". ")}.
                    </div>
                  )}
                </div>
              </div>

              <div className="words">
              {d.blockers.length > 0 && (
                <div className="notice alarm">
                  <p>Can&apos;t be approved yet:</p>
                  <ul style={{ margin: "6px 0 0", paddingLeft: 18 }}>{d.blockers.map((b, j) => <li key={j}>{b}</li>)}</ul>
                  {d.blockers.some((b) => /email rule for/i.test(b)) && (
                    <p style={{ marginTop: 8 }}><a className="textbtn" href="/sending">Check and confirm country rules on the Sending page</a></p>)}
                  {d.blockers.some((b) => /fact sheet|sender name/i.test(b)) && (
                    <p style={{ marginTop: 8 }}><a className="textbtn" href="/clients">Fix it on the Clients page</a></p>)}
                  {d.channel === "email" && d.blockers.some((b) => /country|consent|legal basis|came from|no email rule/i.test(b)) && (
                    <form action={updateContactSending} className="inline" style={{ marginTop: 12, flexWrap: "wrap", color: "var(--ink)" }}>
                      <input type="hidden" name="contact_id" value={d.contact_id} />
                      <label className="field"><span>Country (2 letters)</span>
                        <input name="country" defaultValue={d.country ?? ""} maxLength={2} style={{ width: 70 }} /></label>
                      <label className="field"><span>Why we may email them</span>
                        <select name="email_basis" defaultValue={d.email_basis}>
                          <option value="unknown">Not recorded</option>
                          <option value="legitimate_interest">Business address, relevant to their job</option>
                          <option value="consent">They agreed to hear from us</option>
                          <option value="existing_customer">Existing customer</option>
                        </select></label>
                      <label className="field"><span>Where the address came from</span>
                        <input name="email_source" defaultValue={d.email_source ?? ""} placeholder="Their website, trade show card…" /></label>
                      <Submit className="textbtn">Save</Submit>
                    </form>
                  )}
                </div>
              )}
              {(d.purpose === "reply" || d.purpose === "check_in") && (d.reply_text || d.reply_summary) && (
                <div className="notice" style={{ marginBottom: 16 }}>
                  <p className="small muted">{d.purpose === "reply" ? "What they wrote" : "What they said"}{d.reply_at ? `, ${ago(d.reply_at)}` : ""}</p>
                  <p className="copy" style={{ marginTop: 4 }}>{d.reply_text || d.reply_summary}</p>
                  {d.purpose === "reply" && <p className="small muted" style={{ marginTop: 6 }}>If you already answered them from the mailbox, reject this draft.</p>}
                </div>
              )}
              <form action={reviewDraft} className="words">
                <input type="hidden" name="id" value={d.id} />
                {d.channel === "email" && !(["reply", "check_in"].includes(d.purpose) && !d.subject) && <label className="field subject"><span>Subject</span><input name="subject" defaultValue={d.subject ?? ""} /></label>}
                <label className="field body"><span>{d.channel === "linkedin" ? (d.purpose === "first" ? `LinkedIn note (${d.body.length} of 300 characters)` : "LinkedIn message, sent by you by hand") :
                  d.channel === "whatsapp" ? `WhatsApp message, sent by you by hand (${d.body.length} of 600 characters)` :
                  d.purpose === "reply" ? "Our answer, sent in their thread" : d.purpose === "check_in" ? "Check-in, sent in their thread" :
                  d.step > 1 ? "Follow-up, sent as a reply in the same email thread" : "Message"}</span><textarea name="body" defaultValue={d.body} /></label>
                {d.channel === "email" && <p className="small muted">The sender&apos;s name, postal address and an unsubscribe link are added under the email.</p>}
                <label className="field"><span>Note for the team, if any</span><input name="note" placeholder="Why you approved, changed or rejected it" /></label>
                <div className="acts">
                  <Submit name="decision" value="approved" className="solid" disabled={d.blockers.length > 0}>
                    {d.channel === "email" ? "Approve and send" : d.channel === "linkedin" ? "Approve for LinkedIn" : d.channel === "whatsapp" ? "Approve for WhatsApp" : "Approve"}</Submit>
                  <Submit name="decision" value="rejected" className="textbtn alarm">Reject</Submit>
                  {d.website && <a className="textbtn quiet" href={d.website} target="_blank" rel="noreferrer noopener">Their website</a>}
                </div>
                <details className="research">
                  <summary>Strategy, research and the Grader&apos;s notes</summary>
                  <div className="body">
                    {d.pitch_angle && <div><h4>Strategy</h4><p>{d.pitch_angle}{d.lead_with?.length ? ` Lead with: ${d.lead_with.join(", ")}.` : ""}
                      {d.channel_reason ? ` ${d.channel_reason}` : ""}</p></div>}
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
              <form action={stopContact} style={{ marginTop: 14 }}>
                <input type="hidden" name="contact_id" value={d.contact_id} />
                <Submit className="textbtn quiet" confirm={`Never contact ${d.contact || "this buyer"} again, on any channel?`}>Never contact this buyer</Submit>
              </form>
              </div>
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
        <p className="after">The database itself refuses to approve or send anything the safety gate blocks: do-not-contact buyers,
          countries whose email rule you have not confirmed, missing consent where a country needs it, and emails without a sender address.</p>
      </section>
    </>
  );
}
