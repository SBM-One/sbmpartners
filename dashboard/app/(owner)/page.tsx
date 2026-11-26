import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, day, label, money, num, sentence, today, usd } from "@/lib/format";
import { updateAgent, updateAlert } from "../actions";
import AutoRefresh from "@/components/AutoRefresh";
import Submit from "@/components/Submit";

type Totals = { waiting: number; reports: number; playbook: number; spent: number; budget: number; failed24: number; done24: number;
  clients: number; ordered: number };
type Draft = { id: string; contact: string; company: string | null; client: string; score: number | null; created_at: Date };
type Letter = { id: string; client: string; period_start: Date; created_at: Date };
type Alert = { id: string; severity: string; kind: string; message: string; status: string; created_at: Date; client: string | null };
type Client = { id: string; name: string; ordered: number; won: number; in_play: number; deciding: number; replies: number;
  waiting: number; last_at: Date | null };
type Agent = { agent_id: string; name: string; role: string; active: boolean; paused_reason: string | null;
  spent_usd: number; budget_usd: number; pct_used: number | null };

const AGENT_JOBS: Record<string, string> = {
  supervisor: "Hands out work, paces outreach, watches budgets",
  "prospect-researcher": "Looks up each buyer before outreach",
  writer: "Drafts outreach from the approved playbook",
  grader: "Scores every draft from 0 to 100",
  reporter: "Writes the weekly letters to clients",
  researcher: "Builds the sales playbook from research",
  mock_buyer: "Plays buyers in practice rounds",
};
const AGENT_NAMES: Record<string, string> = { "prospect-researcher": "Prospect researcher", mock_buyer: "Practice buyer" };
const WORDS = ["Nothing", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"];
const spell = (n: number, lower = false) => {
  const w = WORDS[n] ?? num(n);
  return lower ? w.toLowerCase() : w;
};

/** Today: what needs the owner, how each client is doing, and what the agent team is costing. */
export default async function Today() {
  await requireStaff();
  const [[k], drafts, letters, alerts, clients, agents] = await Promise.all([
    sql<Totals[]>`
      select (select count(*)::int from outreach_drafts where status = 'pending_review') as waiting,
             (select count(*)::int from reports where status = 'draft') as reports,
             (select count(*)::int from playbook_entries where status = 'draft') as playbook,
             (select coalesce(sum(spent_usd), 0) from v_agent_spend_month) as spent,
             (select coalesce(sum(budget_usd), 0) from v_agent_spend_month where active) as budget,
             (select count(*)::int from tasks where status = 'failed' and finished_at > now() - interval '1 day') as failed24,
             (select count(*)::int from tasks where status = 'done' and finished_at > now() - interval '1 day') as done24,
             (select count(*)::int from clients where status = 'active') as clients,
             (select coalesce(sum(value_cents), 0) / 100.0 from interactions
               where kind in ('order','reorder') and occurred_at > now() - interval '30 days') as ordered`,
    sql<Draft[]>`
      select d.id, trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as contact, co.name as company,
             cl.name as client, d.score, d.created_at
      from outreach_drafts d join contacts c on c.id = d.contact_id join clients cl on cl.id = d.client_id
      left join companies co on co.id = d.company_id
      where d.status = 'pending_review' order by d.created_at limit 5`,
    sql<Letter[]>`
      select r.id, c.name as client, r.period_start, r.created_at from reports r join clients c on c.id = r.client_id
      where r.status = 'draft' order by r.created_at`,
    sql<Alert[]>`
      select a.id, a.severity::text, a.kind, a.message, a.status::text, a.created_at, c.name as client
      from alerts a left join clients c on c.id = a.client_id
      where a.status <> 'resolved' and not a.notify_client
      order by (a.severity = 'urgent') desc, a.created_at desc limit 6`,
    sql<Client[]>`
      select c.id, c.name,
        coalesce((select sum(order_value_cents) from v_client_weekly v where v.client_id = c.id and v.week > now() - interval '30 days'), 0) / 100.0 as ordered,
        coalesce((select sum(value_cents) from v_portal_pipeline p where p.client_id = c.id and p.stage in ('first_order','repeat')), 0) / 100.0 as won,
        (select count(*)::int from v_portal_pipeline p where p.client_id = c.id and p.stage in ('conversation','sample','quote')) as in_play,
        coalesce((select sum(value_cents) from v_portal_pipeline p where p.client_id = c.id and p.stage in ('sample','quote')), 0) / 100.0 as deciding,
        coalesce((select sum(replies) from v_client_weekly v where v.client_id = c.id and v.week > now() - interval '30 days'), 0)::int as replies,
        (select count(*)::int from outreach_drafts d where d.client_id = c.id and d.status = 'pending_review') as waiting,
        (select max(occurred_at) from interactions i where i.client_id = c.id and i.kind <> 'sent') as last_at
      from clients c where c.status <> 'churned' order by c.status = 'active' desc, c.name`,
    sql<Agent[]>`select * from v_agent_spend_month order by budget_usd desc, name`,
  ]);

  const urgent = alerts.filter((a) => a.severity === "urgent").length;
  const owed = [
    k.waiting && `${spell(k.waiting, true)} draft${k.waiting === 1 ? "" : "s"}`,
    k.reports && `${spell(k.reports, true)} letter${k.reports === 1 ? "" : "s"}`,
  ].filter(Boolean) as string[];
  const owedCount = k.waiting + k.reports;
  const owedText = owed.length ? owed.join(" and ") : "";

  return (
    <>
      <AutoRefresh seconds={30} />
      <div className="dateline"><span>{today()}</span></div>
      <h1 className="statement">
        {owedCount === 0 ? "Nothing is waiting for you." : <>{owedText.charAt(0).toUpperCase() + owedText.slice(1)} {owedCount === 1 ? "is" : "are"} waiting for you.</>}
        {urgent > 0 && <> <span className="alarm">{spell(urgent)} alert{urgent === 1 ? " needs" : "s need"} you now.</span></>}
      </h1>
      <p className="standfirst">
        Across {spell(k.clients, true)} active client{k.clients === 1 ? "" : "s"}, buyers ordered <b>{money(k.ordered)}</b> in the last 30 days.
        {" "}The agents finished {num(k.done24)} task{k.done24 === 1 ? "" : "s"} in the last day{k.failed24 ? <>, and <span className="alarm">{num(k.failed24)} failed</span></> : ""},
        {" "}and have spent {usd(k.spent)} of this month&apos;s {usd(k.budget)}.
      </p>

      <section className="section">
        <div className="sh"><h2>Waiting for you</h2><span className="aside">Oldest first</span></div>
        {drafts.length + letters.length + alerts.length + (k.playbook ? 1 : 0) === 0 ? <p className="empty">Clear. New drafts arrive as the agents research buyers.</p> : (
          <table className="ledger"><tbody>
            {drafts.map((d) => (
              <tr key={d.id}>
                <td className="lead">Draft</td>
                <td><div className="name">{d.contact || "(no name)"}{d.company ? `, ${d.company}` : ""}</div>
                  <div className="sub">For {d.client}. Written {ago(d.created_at)}.</div></td>
                <td className="num small" style={{ paddingTop: 21 }}>{d.score == null ? <span className="faint">Not graded</span>
                  : <span className={d.score < 65 ? "alarm" : ""}>Graded {d.score}</span>}</td>
                <td className="num" style={{ paddingTop: 20 }}><Link className="go" href={`/approvals#d-${d.id}`}>Read and decide</Link></td>
              </tr>
            ))}
            {k.waiting > drafts.length && (
              <tr><td className="lead" /><td colSpan={3} className="small"><Link className="go" href="/approvals">{num(k.waiting - drafts.length)} more drafts</Link></td></tr>
            )}
            {letters.map((r) => (
              <tr key={r.id}>
                <td className="lead">Letter</td>
                <td><div className="name">{r.client}</div><div className="sub">Week of {day(r.period_start)}. Drafted {ago(r.created_at)}.</div></td>
                <td />
                <td className="num" style={{ paddingTop: 20 }}><Link className="go" href={`/reports#r-${r.id}`}>Read and approve</Link></td>
              </tr>
            ))}
            {k.playbook > 0 && (
              <tr>
                <td className="lead">Playbook</td>
                <td><div className="name">{spell(k.playbook)} new tactic{k.playbook === 1 ? "" : "s"}</div><div className="sub">The Writer can&apos;t use them until you approve.</div></td>
                <td />
                <td className="num" style={{ paddingTop: 20 }}><Link className="go" href="/playbook">Review</Link></td>
              </tr>
            )}
            {alerts.map((a) => (
              <tr key={a.id}>
                <td className={`lead ${a.severity === "urgent" ? "alarm" : ""}`}>{a.severity === "urgent" ? "Urgent" : "Alert"}</td>
                <td><div style={{ fontSize: 15.5 }}>{a.message}</div>
                  <div className="sub">{sentence(a.kind)}{a.client ? `, ${a.client}` : ""}. {sentence(ago(a.created_at))}{a.status === "acknowledged" ? ", seen" : ""}.</div></td>
                <td />
                <td className="num" style={{ paddingTop: 20 }}>
                  <form action={updateAlert} className="acts" style={{ justifyContent: "flex-end" }}>
                    <input type="hidden" name="id" value={a.id} />
                    {a.status === "open" && <Submit name="status" value="acknowledged" className="textbtn quiet">Seen</Submit>}
                    <Submit name="status" value="resolved" className="textbtn">Resolve</Submit>
                  </form>
                </td>
              </tr>
            ))}
          </tbody></table>
        )}
      </section>

      <section className="section">
        <div className="sh"><h2>Clients<span className="count">{clients.length}</span></h2><Link className="aside" href="/clients">Settings for each client</Link></div>
        <div className="scroll">
          <table className="ledger">
            <thead><tr><th>Client</th><th className="num">Ordered, 30 days</th><th className="num">Won so far</th>
              <th className="num">Buyers deciding</th><th className="num">Replies, 30 days</th><th>Last buyer activity</th><th /></tr></thead>
            <tbody>
              {clients.map((c) => (
                <tr key={c.id}>
                  <td><div className="name">{c.name}</div>{c.waiting > 0 && <div className="sub">{num(c.waiting)} draft{c.waiting === 1 ? "" : "s"} waiting</div>}</td>
                  <td className="num" style={{ paddingTop: 20 }}>{c.ordered ? money(c.ordered) : <span className="faint">–</span>}</td>
                  <td className="num won" style={{ paddingTop: 20 }}>{c.won ? money(c.won) : <span className="faint">–</span>}</td>
                  <td className="num" style={{ paddingTop: 20 }}>{num(c.in_play)}{c.deciding > 0 && <div className="sub">{money(c.deciding)}</div>}</td>
                  <td className="num" style={{ paddingTop: 20 }}>{num(c.replies)}</td>
                  <td className="small" style={{ paddingTop: 21 }}>{ago(c.last_at)}</td>
                  <td className="num" style={{ paddingTop: 20 }}><Link className="go" href={`/portal?client=${c.id}`}>Their page</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="section">
        <div className="sh"><h2>The team</h2><span className="aside">{usd(k.spent)} of {usd(k.budget)} spent this month</span></div>
        <div className="scroll">
          <table className="ledger">
            <thead><tr><th>Agent</th><th>Status</th><th className="num">Spent this month</th><th className="num">Monthly budget</th><th /></tr></thead>
            <tbody>
              {agents.map((a) => {
                const over = (a.pct_used ?? 0) >= 80;
                return (
                  <tr key={a.agent_id}>
                    <td><div className="name">{AGENT_NAMES[a.name] ?? sentence(a.name)}</div><div className="sub">{AGENT_JOBS[a.name] ?? label(a.role)}</div></td>
                    <td className="small" style={{ paddingTop: 21 }}>{a.active ? "Working" : <span className="alarm">Paused</span>}
                      {!a.active && a.paused_reason && <div className="muted">{sentence(a.paused_reason)}</div>}</td>
                    <td className="num" style={{ paddingTop: 20 }}>
                      {a.budget_usd === 0 ? <span className="faint">No AI cost</span> : <span className={over ? "alarm" : ""}>{usd(a.spent_usd)}</span>}
                      {a.budget_usd > 0 && <div className="sub">{Math.round(a.pct_used ?? 0)}% of budget</div>}
                    </td>
                    <td className="num" style={{ paddingTop: 16 }}>
                      {a.name === "supervisor" ? <span className="faint small">Rules only</span> : (
                        <form action={updateAgent} className="inline">
                          <input type="hidden" name="id" value={a.agent_id} />
                          <input type="hidden" name="op" value="budget" />
                          <span className="muted">$</span><input className="line" name="budget" type="number" min="0" step="5" defaultValue={a.budget_usd} aria-label={`Monthly budget for ${a.name}`} />
                          <Submit className="textbtn quiet">Save</Submit>
                        </form>
                      )}
                    </td>
                    <td className="num" style={{ paddingTop: 20 }}>
                      {a.name !== "supervisor" && <form action={updateAgent}>
                        <input type="hidden" name="id" value={a.agent_id} />
                        {a.active
                          ? <Submit name="op" value="pause" className="textbtn alarm" confirm={`Pause ${a.name}? Its tasks will wait until you resume it.`}>Pause</Submit>
                          : <Submit name="op" value="resume" className="textbtn">Resume</Submit>}
                      </form>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>
    </>
  );
}
