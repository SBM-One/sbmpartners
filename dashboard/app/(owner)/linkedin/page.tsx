import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago } from "@/lib/format";
import { markLinkedIn } from "../../actions";
import Submit from "@/components/Submit";

type Todo = { id: string; reviewed_at: Date; body: string; client: string; contact: string; contact_title: string | null;
  linkedin_url: string | null; company: string | null };
type Done = { id: string; contact: string; company: string | null; sent_at: Date; sent_by: string | null };

const WORDS = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"];

/** LinkedIn notes you approved, to send by hand. No tool ever touches the LinkedIn account. */
export default async function LinkedIn() {
  await requireStaff();
  const [todo, done] = await Promise.all([
    sql<Todo[]>`select * from v_linkedin_todo limit 50`,
    sql<Done[]>`select d.id, trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')) as contact, co.name as company,
                  d.sent_at, d.sent_by
                from outreach_drafts d join contacts c on c.id = d.contact_id left join companies co on co.id = d.company_id
                where d.channel = 'linkedin' and d.status = 'sent' order by d.sent_at desc limit 15`,
  ]);
  const today = done.filter((d) => new Date(d.sent_at).toDateString() === new Date().toDateString()).length;

  return (
    <>
      <h1 className="statement" style={{ marginTop: 56 }}>
        {todo.length === 0 ? "No LinkedIn notes to send." : `${WORDS[todo.length] ?? todo.length} LinkedIn note${todo.length === 1 ? " is" : "s are"} ready for you to send.`}
      </h1>
      <p className="standfirst">Open the profile, choose Connect, add a note, and paste the text. Then mark it sent here. Keep to about 15 a day
        {today ? ` (${today} sent today)` : ""}, and never pitch in the note itself.</p>

      <section className="section tight">
        <div className="sh"><h2>To send<span className="count">{todo.length}</span></h2><span className="aside">Oldest approval first</span></div>
        {todo.length === 0 && <p className="empty">Notes you approve on the Drafts page appear here.</p>}
        {todo.map((t) => (
          <article className="spread" key={t.id}>
            <div className="who">
              <h3>{t.contact || "(no name)"}</h3>
              <div className="sub">{[t.contact_title, t.company].filter(Boolean).join(", ") || "Role unknown"}</div>
              <dl className="facts"><dt>For</dt><dd>{t.client}</dd><dt>Approved</dt><dd>{ago(t.reviewed_at)}</dd></dl>
            </div>
            <div className="words">
              <p className="copy">{t.body}</p>
              <p className="small muted">{t.body.length} of 300 characters</p>
              <form action={markLinkedIn} className="acts">
                <input type="hidden" name="id" value={t.id} />
                {t.linkedin_url ? <a className="btn" href={t.linkedin_url} target="_blank" rel="noreferrer noopener">Open their profile</a>
                  : <span className="small alarm">No profile link on file</span>}
                <Submit name="op" value="sent" className="solid">I sent it</Submit>
                <Submit name="op" value="skip" className="textbtn quiet">Skip</Submit>
              </form>
            </div>
          </article>
        ))}
      </section>

      <section className="section">
        <div className="sh"><h2>Sent by hand</h2><span className="aside">The last 15</span></div>
        {done.length === 0 ? <p className="empty">Nothing yet.</p> : (
          <div className="scroll"><table className="ledger"><tbody>
            {done.map((d) => (
              <tr key={d.id}><td className="name" style={{ fontSize: 15.5 }}>{d.contact}{d.company ? `, ${d.company}` : ""}</td>
                <td className="num small muted">{d.sent_by}<div>{ago(d.sent_at)}</div></td></tr>))}
          </tbody></table></div>
        )}
        <p className="after">If someone asks you on LinkedIn to stop, use &ldquo;Never contact this buyer&rdquo; on the Drafts page or add them on the
          Sending page: it stops email too.</p>
      </section>
    </>
  );
}
