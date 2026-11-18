import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, sentence } from "@/lib/format";
import { addSuppression, setCountryRule, updateMailbox } from "../../actions";
import Submit from "@/components/Submit";

type Box = { id: string; address: string; display_name: string; daily_cap: number; send_from_hour: number; send_until_hour: number;
  timezone: string; min_gap_minutes: number; paused: boolean; next_send_at: Date | null; today: number };
type Out = { id: string; contact: string; company: string | null; email: string | null; client: string; subject: string | null;
  step: number; reviewed_by: string | null; reviewed_at: Date | null; send_error: string | null; send_claimed_at: Date | null };
type Sent = { id: string; contact: string; company: string | null; client: string; subject: string | null; step: number;
  sent_at: Date; reply: string | null; reply_summary: string | null };
type Rule = { country: string; name: string; cold_email: string; law: string; note: string | null; confirmed_by: string | null;
  confirmed_at: Date | null; buyers: number };
type Supp = { value: string; reason: string; added_by: string; created_at: Date };

const RULE = { allowed: "Allowed, with opt-out", consent_only: "Only with consent", blocked: "Never" } as Record<string, string>;
const WORDS = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"];

/** The outbox: what is approved and waiting, what went out, the mailbox's pace, and who we may email where. */
export default async function Sending() {
  await requireStaff();
  const [boxes, outbox, sent, rules, supp] = await Promise.all([
    sql<Box[]>`select m.*, (select count(*)::int from outreach_drafts d where d.mailbox_id = m.id and d.send_claimed_at is not null
                 and (d.send_claimed_at at time zone m.timezone)::date = (now() at time zone m.timezone)::date) as today
               from mailboxes m order by m.created_at`,
    sql<Out[]>`select d.id, trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')) as contact, co.name as company, c.email,
                 cl.name as client, d.subject, d.step, d.reviewed_by, d.reviewed_at, d.send_error, d.send_claimed_at
               from outreach_drafts d join contacts c on c.id = d.contact_id join clients cl on cl.id = d.client_id
               left join companies co on co.id = d.company_id
               where d.status = 'approved' and d.channel = 'email' order by d.reviewed_at`,
    sql<Sent[]>`select d.id, trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')) as contact, co.name as company,
                  cl.name as client, d.subject, d.step, d.sent_at,
                  (select i.metadata->>'category' from interactions i where i.contact_id = d.contact_id and i.client_id = d.client_id
                     and i.direction = 'inbound' and i.kind in ('reply','unsubscribe','bounce') order by i.occurred_at desc limit 1) as reply,
                  (select coalesce(i.metadata->>'summary', i.kind::text) from interactions i where i.contact_id = d.contact_id
                     and i.client_id = d.client_id and i.direction = 'inbound' and i.kind in ('reply','unsubscribe','bounce')
                     order by i.occurred_at desc limit 1) as reply_summary
                from outreach_drafts d join contacts c on c.id = d.contact_id join clients cl on cl.id = d.client_id
                left join companies co on co.id = d.company_id
                where d.status = 'sent' and d.channel = 'email' order by d.sent_at desc limit 25`,
    sql<Rule[]>`select r.*, (select count(*)::int from contacts c left join companies co on co.id = c.company_id
                  where coalesce(c.country, co.country) = r.country and not c.do_not_contact) as buyers
                from email_country_rules r order by r.confirmed_at is null, r.name`,
    sql<Supp[]>`select * from suppressions order by created_at desc limit 20`,
  ]);
  const box = boxes[0];
  const held = outbox.filter((o) => o.send_error);
  const waiting = outbox.length;
  const unconfirmed = rules.filter((r) => !r.confirmed_at && r.buyers > 0);

  return (
    <>
      <h1 className="statement" style={{ marginTop: 56 }}>
        {!box ? "No mailbox is connected yet, so nothing can be sent."
          : box.paused ? "Sending is paused."
          : `${WORDS[box.today] ?? box.today} of ${box.daily_cap} emails sent today.`}
        {" "}{waiting === 0 ? "Nothing is waiting." : `${WORDS[waiting] ?? waiting} approved ${waiting === 1 ? "email is" : "emails are"} waiting${held.length ? `, ${held.length} held back` : ""}.`}
      </h1>
      <p className="standfirst">The mailbox sends one email at a time, on weekdays within its hours, with a pause between each. Replies are read
        and sorted every few minutes; anyone who asks to stop is never contacted again, on any channel.</p>

      <section className="section tight">
        <div className="sh"><h2>Waiting to go out<span className="count">{waiting}</span></h2><span className="aside">Oldest approval first</span></div>
        {waiting === 0 ? <p className="empty">Emails you approve on the Drafts page wait here until the mailbox sends them.</p> : (
          <div className="scroll"><table className="ledger"><tbody>
            {outbox.map((o) => (
              <tr key={o.id}>
                <td><div className="name" style={{ fontSize: 15.5 }}>{o.contact || o.email}{o.company ? `, ${o.company}` : ""}</div>
                  <div className="sub">For {o.client}. {o.step > 1 ? `Follow-up ${o.step - 1}` : "First email"}.</div></td>
                <td className="small">{o.subject ?? <span className="faint">Reply in the thread</span>}
                  {o.send_error && <div className="alarm" style={{ marginTop: 4 }}>Held: {o.send_error}</div>}
                  {o.send_claimed_at && <div className="alarm" style={{ marginTop: 4 }}>Handed to the mailbox {ago(o.send_claimed_at)} but not confirmed. Check the Sent folder.</div>}</td>
                <td className="num small muted">Approved by {o.reviewed_by ?? "?"}<div>{ago(o.reviewed_at)}</div></td>
              </tr>))}
          </tbody></table></div>
        )}
      </section>

      <section className="section">
        <div className="sh"><h2>Sent</h2><span className="aside">The last 25, with any answer</span></div>
        {sent.length === 0 ? <p className="empty">Nothing has been sent yet.</p> : (
          <div className="scroll"><table className="ledger"><tbody>
            {sent.map((s) => (
              <tr key={s.id}>
                <td className={`lead ${s.reply === "unsubscribe" || s.reply_summary === "bounce" ? "alarm" : ""}`}>
                  {s.reply ? sentence(s.reply.replace(/_/g, " ")) : s.reply_summary === "bounce" ? "Bounced" : "No answer yet"}</td>
                <td><div className="name" style={{ fontSize: 15.5 }}>{s.contact}{s.company ? `, ${s.company}` : ""}</div>
                  <div className="sub">For {s.client}. {s.step > 1 ? `Follow-up ${s.step - 1}` : "First email"}.</div></td>
                <td className="small">{s.subject}{s.reply_summary && s.reply && <div className="muted">{s.reply_summary}</div>}</td>
                <td className="num small muted">{ago(s.sent_at)}</td>
              </tr>))}
          </tbody></table></div>
        )}
      </section>

      <section className="section">
        <div className="sh"><h2>The mailbox</h2><span className="aside">{box ? box.address : "Not connected"}</span></div>
        {!box ? <p className="empty">Set MAIL_ADDRESS and MAIL_PASSWORD on the computer that runs the team, then run <code>python -m agents.mailer setup</code>.</p> : (
          <form action={updateMailbox} className="settings">
            <input type="hidden" name="id" value={box.id} />
            <label className="field"><span>Emails a day, at most</span><input name="daily_cap" type="number" min={0} max={200} defaultValue={box.daily_cap} /></label>
            <label className="field"><span>Send from (hour)</span><input name="send_from_hour" type="number" min={0} max={23} defaultValue={box.send_from_hour} /></label>
            <label className="field"><span>Until (hour)</span><input name="send_until_hour" type="number" min={1} max={24} defaultValue={box.send_until_hour} /></label>
            <label className="field"><span>Minutes between emails</span><input name="min_gap_minutes" type="number" min={1} max={240} defaultValue={box.min_gap_minutes} /></label>
            <label className="field"><span>Time zone</span><input name="timezone" defaultValue={box.timezone} /></label>
            <label className="check"><input type="checkbox" name="paused" defaultChecked={box.paused} /> Pause sending</label>
            <Submit className="sm">Save</Submit>
          </form>
        )}
        <p className="after">A new mailbox should start at 10 to 15 emails a day and grow by a few each week. Replies are never sent
          automatically: interested buyers appear as alerts on Today, and you answer them yourself.</p>
      </section>

      <section className="section">
        <div className="sh"><h2>Who we may email, by country</h2>
          <span className="aside">{unconfirmed.length ? `${unconfirmed.length} with buyers still to confirm` : "Confirmed rules only"}</span></div>
        <p className="standfirst" style={{ marginTop: 0 }}>These are a cautious starting point, not legal advice. Check each country you
          target with a lawyer, then confirm it. Nothing is sent to a country until its rule is confirmed.</p>
        <div className="scroll"><table className="ledger">
          <thead><tr><th>Country</th><th>Cold email</th><th>Law and note</th><th className="num">Buyers</th><th /></tr></thead>
          <tbody>
            {rules.map((r) => (
              <tr key={r.country}>
                <td><div className="name" style={{ fontSize: 15.5 }}>{r.name}</div><div className="sub">{r.country}</div></td>
                <td className="small">{RULE[r.cold_email]}<div className={r.confirmed_at ? "muted" : "alarm"}>
                  {r.confirmed_at ? `Confirmed by ${r.confirmed_by}, ${ago(r.confirmed_at)}` : "Not confirmed"}</div></td>
                <td className="small muted" style={{ maxWidth: 380 }}>{r.law}. {r.note}</td>
                <td className="num">{r.buyers}</td>
                <td className="num">
                  <form action={setCountryRule} className="inline">
                    <input type="hidden" name="country" value={r.country} />
                    <select name="cold_email" defaultValue={r.cold_email} aria-label={`Rule for ${r.name}`}>
                      <option value="allowed">Allowed</option><option value="consent_only">Consent only</option><option value="blocked">Never</option>
                    </select>
                    <Submit name="op" value="confirm" className="textbtn" confirm={`Confirm the email rule for ${r.name}? Only do this after checking it.`}>Confirm</Submit>
                    {r.confirmed_at && <Submit name="op" value="unconfirm" className="textbtn quiet">Withdraw</Submit>}
                  </form>
                </td>
              </tr>))}
          </tbody>
        </table></div>
        <p className="after">A country that is not listed is never emailed. To add one, insert a row in the email_country_rules table.</p>
      </section>

      <section className="section">
        <div className="sh"><h2>Do not contact</h2><span className="aside">The latest 20</span></div>
        <form action={addSuppression} className="inline" style={{ marginBottom: 18, flexWrap: "wrap" }}>
          <label className="field"><span>Email address or whole domain</span><input name="value" placeholder="name@shop.com or shop.com" style={{ width: 260 }} /></label>
          <label className="field"><span>Why</span><input name="reason" placeholder="Asked by phone…" style={{ width: 220 }} /></label>
          <Submit className="sm">Add</Submit>
        </form>
        {supp.length === 0 ? <p className="empty">Nobody yet. Unsubscribes and &ldquo;please stop&rdquo; replies are added here automatically.</p> : (
          <div className="scroll"><table className="ledger"><tbody>
            {supp.map((s) => (
              <tr key={s.value}><td className="name" style={{ fontSize: 15 }}>{s.value}</td><td className="small muted">{s.reason}</td>
                <td className="num small muted">{s.added_by}<div>{ago(s.created_at)}</div></td></tr>))}
          </tbody></table></div>
        )}
      </section>
    </>
  );
}
