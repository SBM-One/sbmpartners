import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, day, sentence } from "@/lib/format";
import { bookMeeting, closeMeeting } from "../../actions";
import Submit from "@/components/Submit";

type Check = { key: string; status: "yes" | "unclear" | "no"; evidence: string };
type Msg = { at: string; channel: string; from: string; kind: string; subject: string | null; text: string; summary?: string; category?: string };
type Meeting = {
  id: string; status: string; qualified: boolean; client: string; contact: string; contact_title: string | null; company: string | null;
  buyer_type: string | null; email: string | null; phone: string | null; linkedin_url: string | null; website: string | null;
  fit_score: number | null; interest: string; product_fit: string; checks: Check[]; contact_history: Msg[];
  open_questions: string[]; next_steps: string[]; agenda: string[]; meeting_at: Date | null; meeting_note: string | null;
  owner: string | null; outcome_note: string | null; created_at: Date; decided_at: Date | null;
};

const CHECK: Record<string, string> = { interest: "Interest", product_fit: "Product fit", authority: "Decision maker", timing: "Timing",
  terms: "Terms" };
const WORDS = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"];
const when = (d: Date) => new Date(d).toLocaleString("en-GB", { weekday: "short", day: "numeric", month: "short", hour: "2-digit",
  minute: "2-digit", timeZone: "Europe/Madrid" });

/** Interested buyers handed to you: the brief, then booking, then how it went. */
export default async function Meetings() {
  await requireStaff();
  const rows = await sql<Meeting[]>`
    select * from v_meetings
    where status in ('ready','booked') or decided_at > now() - interval '30 days'
    order by case status when 'ready' then 0 when 'booked' then 1 else 2 end, meeting_at nulls last, created_at desc
    limit 60`;
  const ready = rows.filter((r) => r.status === "ready");
  const booked = rows.filter((r) => r.status === "booked");
  const closed = rows.filter((r) => !["ready", "booked"].includes(r.status));

  return (
    <>
      <h1 className="statement" style={{ marginTop: 56 }}>
        {ready.length === 0 ? "No new meeting briefs." : `${WORDS[ready.length] ?? ready.length} interested buyer${ready.length === 1 ? " is" : "s are"} ready for you.`}
        {booked.length > 0 ? ` ${WORDS[booked.length] ?? booked.length} meeting${booked.length === 1 ? "" : "s"} booked.` : ""}
      </h1>
      <p className="standfirst">When a buyer says yes, the Meeting briefer writes this for you: what they want, which products fit, what is
        still unclear, the whole conversation and the next steps. Booking a meeting logs it, opens the deal in the client&apos;s pipeline and
        stops every automatic message to that buyer.</p>

      <section className="section tight">
        <div className="sh"><h2>Ready for you<span className="count">{ready.length}</span></h2><span className="aside">Newest first</span></div>
        {ready.length === 0 && <p className="empty">Interested buyers appear here, with their brief.</p>}
        {ready.map((m) => (
          <article className="spread" key={m.id}>
            <div className="who">
              <h3>{m.contact || "(no name)"}</h3>
              <div className="sub">{[m.contact_title, m.company].filter(Boolean).join(", ") || "Role unknown"}</div>
              <dl className="facts">
                <dt>For</dt><dd>{m.client}</dd>
                <dt>Buyer</dt><dd>{sentence(m.buyer_type) || "Unknown"}</dd>
                {m.fit_score != null && <><dt>Fit</dt><dd>{m.fit_score} of 100</dd></>}
                {m.email && <><dt>Email</dt><dd style={{ wordBreak: "break-all" }}>{m.email}</dd></>}
                {m.phone && <><dt>Phone</dt><dd>{m.phone}</dd></>}
                <dt>Brief</dt><dd>{ago(m.created_at)}</dd>
              </dl>
              <div className={`grade ${m.qualified ? "" : "low"}`}>
                <b>{m.qualified ? "Qualified" : "Not yet"}</b>
                <div className="muted" style={{ marginTop: 4 }}>{m.qualified ? "Interest and product fit are both clear." : "Something important is unclear: see the checks."}</div>
              </div>
            </div>
            <div className="words">
              <h4 style={{ margin: 0 }}>What they want</h4><p>{m.interest}</p>
              <h4 style={{ margin: "14px 0 0" }}>Product fit</h4><p>{m.product_fit}</p>
              <ul style={{ margin: "10px 0 0", paddingLeft: 18 }}>
                {m.checks.map((c) => (
                  <li key={c.key} className={c.status === "no" ? "alarm" : ""}>{CHECK[c.key] ?? c.key}: <b style={{ fontWeight: 500 }}>{c.status}</b>. <span className="muted">{c.evidence}</span></li>
                ))}
              </ul>
              {m.next_steps.length > 0 && (<><h4 style={{ margin: "14px 0 0" }}>Next steps</h4>
                <ol style={{ margin: "6px 0 0", paddingLeft: 18 }}>{m.next_steps.map((s, j) => <li key={j}>{s}</li>)}</ol></>)}
              <details className="research">
                <summary>Still to find out, agenda and the whole conversation ({m.contact_history.length} messages)</summary>
                <div className="body">
                  {m.open_questions.length > 0 && <div><h4>Still to find out</h4><ul>{m.open_questions.map((q, j) => <li key={j}>{q}</li>)}</ul></div>}
                  {m.agenda.length > 0 && <div><h4>Agenda (20 minutes)</h4><ul>{m.agenda.map((q, j) => <li key={j}>{q}</li>)}</ul></div>}
                  <div><h4>Conversation</h4>
                    {m.contact_history.map((h, j) => (
                      <div key={j} style={{ marginBottom: 12 }}>
                        <div className="small muted">{day(h.at)} · {h.from === "buyer" ? "Buyer" : "Us"} · {h.channel}{h.category ? ` · ${h.category.replaceAll("_", " ")}` : ""}</div>
                        <p className="copy" style={{ margin: "2px 0 0", fontSize: 14 }}>{h.subject ? `${h.subject}\n` : ""}{h.text || h.summary || sentence(h.kind)}</p>
                      </div>
                    ))}
                  </div>
                </div>
              </details>
              <form action={bookMeeting} className="inline" style={{ flexWrap: "wrap", marginTop: 18 }}>
                <input type="hidden" name="id" value={m.id} />
                <label className="field"><span>Meeting date and time</span><input type="datetime-local" name="at" required /></label>
                <label className="field"><span>Time zone</span>
                  <select name="timezone" defaultValue="Europe/Madrid">
                    {["Europe/Madrid", "Europe/London", "Europe/Paris", "America/New_York", "America/Chicago", "America/Los_Angeles"].map((z) =>
                      <option key={z} value={z}>{z.replace("_", " ")}</option>)}
                  </select></label>
                <label className="field"><span>Link or place</span><input name="note" placeholder="Zoom link, showroom…" /></label>
                <Submit className="solid">Book the meeting</Submit>
              </form>
              <form action={closeMeeting} className="inline" style={{ marginTop: 12 }}>
                <input type="hidden" name="id" value={m.id} />
                <input type="hidden" name="outcome" value="not_qualified" />
                <input name="note" className="line" style={{ minWidth: 260 }} placeholder="Why it is not a real opportunity" />
                <Submit className="textbtn alarm" confirm="Close this brief as not a qualified meeting? Automatic messages to this buyer stay off.">Not a qualified meeting</Submit>
              </form>
              {m.linkedin_url && <p className="small" style={{ marginTop: 10 }}><a className="textbtn quiet" href={m.linkedin_url} target="_blank" rel="noreferrer noopener">Their LinkedIn</a>
                {m.website && <> · <a className="textbtn quiet" href={m.website} target="_blank" rel="noreferrer noopener">Their website</a></>}</p>}
            </div>
          </article>
        ))}
      </section>

      <section className="section">
        <div className="sh"><h2>Booked<span className="count">{booked.length}</span></h2><span className="aside">Soonest first, Madrid time</span></div>
        {booked.length === 0 ? <p className="empty">Meetings you book show here until you record how they went.</p> : (
          <div className="scroll"><table className="ledger"><tbody>
            {booked.map((m) => (
              <tr key={m.id}>
                <td className="lead">{m.meeting_at ? when(m.meeting_at) : ""}</td>
                <td><div className="name">{m.contact}{m.company ? `, ${m.company}` : ""}</div><div className="sub">For {m.client}{m.meeting_note ? ` · ${m.meeting_note}` : ""}</div></td>
                <td>
                  <form action={closeMeeting} className="inline" style={{ flexWrap: "wrap" }}>
                    <input type="hidden" name="id" value={m.id} />
                    <input name="note" className="line" style={{ minWidth: 220 }} placeholder="How it went, next step" />
                    <Submit name="outcome" value="held" className="sm solid">Held</Submit>
                    <Submit name="outcome" value="no_show" className="sm">No-show</Submit>
                    <Submit name="outcome" value="cancelled" className="textbtn quiet">Cancelled</Submit>
                  </form>
                </td>
              </tr>
            ))}
          </tbody></table></div>
        )}
      </section>

      {closed.length > 0 && (
        <section className="section">
          <div className="sh"><h2>Last 30 days</h2></div>
          <div className="scroll"><table className="ledger"><tbody>
            {closed.map((m) => (
              <tr key={m.id} className={m.status === "held" ? "" : "closed"}>
                <td className="lead">{sentence(m.status)}</td>
                <td><div className="name" style={{ fontSize: 15.5 }}>{m.contact}{m.company ? `, ${m.company}` : ""}</div><div className="sub">For {m.client}</div></td>
                <td className="small muted">{m.outcome_note}</td>
                <td className="num small muted">{ago(m.decided_at)}</td>
              </tr>
            ))}
          </tbody></table></div>
          <p className="after">A held meeting stays in the activity log and the client&apos;s pipeline; move the deal on from there.</p>
        </section>
      )}
    </>
  );
}
