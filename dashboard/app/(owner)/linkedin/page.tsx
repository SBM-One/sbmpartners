import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago } from "@/lib/format";
import { markLinkedIn } from "../../actions";
import Submit from "@/components/Submit";

type Todo = { id: string; channel: "linkedin" | "whatsapp"; reviewed_at: Date; body: string; planned_day: number | null;
  client: string; contact: string; contact_title: string | null; linkedin_url: string | null; wa_number: string;
  company: string | null; first_touch_at: Date | null };
type Done = { id: string; channel: string; contact: string; company: string | null; sent_at: Date; sent_by: string | null };

const WORDS = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"];
const LIMIT = { linkedin: 300, whatsapp: 600 };
const DAY = 24 * 3600 * 1000;

/** The writer's plan for when this touch is due: "day N" counts from the first message that went out. */
function due(t: Todo): { label: string; early: boolean } {
  if (!t.planned_day) return { label: "Due now", early: false };
  if (!t.first_touch_at) return { label: `Day ${t.planned_day} of the plan, after the first message goes out`, early: true };
  const at = new Date(new Date(t.first_touch_at).getTime() + t.planned_day * DAY);
  return at.getTime() <= Date.now() ? { label: `Due since ${at.toLocaleDateString("en-GB", { day: "numeric", month: "short" })}`, early: false }
    : { label: `Due ${at.toLocaleDateString("en-GB", { day: "numeric", month: "short" })} (day ${t.planned_day} of the plan)`, early: true };
}

/** LinkedIn notes and WhatsApp messages you approved, to send yourself. No tool ever touches those accounts. */
export default async function ByHand() {
  await requireStaff();
  const [todo, done] = await Promise.all([
    sql<Todo[]>`select * from v_manual_sends limit 80`,
    sql<Done[]>`select d.id, d.channel::text as channel, trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')) as contact,
                  co.name as company, d.sent_at, d.sent_by
                from outreach_drafts d join contacts c on c.id = d.contact_id left join companies co on co.id = d.company_id
                where d.channel::text in ('linkedin', 'whatsapp') and d.status = 'sent' order by d.sent_at desc limit 15`,
  ]);
  const today = done.filter((d) => new Date(d.sent_at).toDateString() === new Date().toDateString()).length;

  return (
    <>
      <h1 className="statement" style={{ marginTop: 56 }}>
        {todo.length === 0 ? "Nothing to send by hand." : `${WORDS[todo.length] ?? todo.length} message${todo.length === 1 ? " is" : "s are"} ready for you to send.`}
      </h1>
      <p className="standfirst">LinkedIn and WhatsApp can&apos;t be sent automatically, so these wait for you. Tap the button: LinkedIn opens
        their profile (choose Connect, add a note, paste the text); WhatsApp opens the chat with the message already typed. Then press
        &ldquo;I sent it&rdquo; so it is logged like any email. Keep LinkedIn to about 15 a day{today ? ` (${today} sent today)` : ""}.</p>

      <section className="section tight">
        <div className="sh"><h2>To send<span className="count">{todo.length}</span></h2><span className="aside">In the order of each buyer&apos;s plan</span></div>
        {todo.length === 0 && <p className="empty">LinkedIn notes and WhatsApp messages you approve on the Drafts page appear here.</p>}
        {todo.map((t) => {
          const d = due(t);
          const link = t.channel === "whatsapp"
            ? (t.wa_number ? `https://wa.me/${t.wa_number}?text=${encodeURIComponent(t.body)}` : null)
            : t.linkedin_url;
          return (
            <article className="spread" key={t.id}>
              <div className="who">
                <h3>{t.contact || "(no name)"}</h3>
                <div className="sub">{[t.contact_title, t.company].filter(Boolean).join(", ") || "Role unknown"}</div>
                <dl className="facts">
                  <dt>Channel</dt><dd>{t.channel === "whatsapp" ? "WhatsApp" : "LinkedIn"}</dd>
                  <dt>For</dt><dd>{t.client}</dd>
                  <dt>When</dt><dd className={d.early ? "muted" : undefined}>{d.label}</dd>
                  <dt>Approved</dt><dd>{ago(t.reviewed_at)}</dd>
                </dl>
              </div>
              <div className="words">
                <p className="copy">{t.body}</p>
                <p className="small muted">{t.body.length} of {LIMIT[t.channel]} characters</p>
                <form action={markLinkedIn} className="acts">
                  <input type="hidden" name="id" value={t.id} />
                  {link ? <a className="btn" href={link} target="_blank" rel="noreferrer noopener">
                      {t.channel === "whatsapp" ? "Open in WhatsApp" : "Open their profile"}</a>
                    : <span className="small alarm">{t.channel === "whatsapp" ? "No WhatsApp number on file" : "No profile link on file"}</span>}
                  <Submit name="op" value="sent" className="solid">I sent it</Submit>
                  <Submit name="op" value="skip" className="textbtn quiet">Skip</Submit>
                </form>
              </div>
            </article>
          );
        })}
      </section>

      <section className="section">
        <div className="sh"><h2>Sent by hand</h2><span className="aside">The last 15</span></div>
        {done.length === 0 ? <p className="empty">Nothing yet.</p> : (
          <div className="scroll"><table className="ledger"><tbody>
            {done.map((d) => (
              <tr key={d.id}><td className="name" style={{ fontSize: 15.5 }}>{d.contact}{d.company ? `, ${d.company}` : ""}
                <div className="small muted">{d.channel === "whatsapp" ? "WhatsApp" : "LinkedIn"}</div></td>
                <td className="num small muted">{d.sent_by}<div>{ago(d.sent_at)}</div></td></tr>))}
          </tbody></table></div>
        )}
        <p className="after">If someone asks you on LinkedIn or WhatsApp to stop, use &ldquo;Never contact this buyer&rdquo; on the Drafts page
          or add them on the Sending page: it stops every channel.</p>
      </section>
    </>
  );
}
