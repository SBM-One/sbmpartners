import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { TZ, ago, clock, day, label, money, num, sentence, today, usd } from "@/lib/format";
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

type Work = { kind: string; done: number; running: number; queued: number; failed: number };
type Done = { id: string; kind: string; status: string; finished_at: Date; yesterday: boolean; company: string | null; contact: string; client: string | null;
  error: string | null };

/** Who does each kind of task, and how one finished task reads in a sentence. */
const TASK_WORDS: Record<string, { agent: string; one: string; many: string; did: string }> = {
  research_prospect: { agent: "Prospect researcher", one: "buyer looked up", many: "buyers looked up", did: "Looked up" },
  qualify_prospect: { agent: "Strategist", one: "buyer scored and planned", many: "buyers scored and planned", did: "Scored and planned" },
  draft_outreach: { agent: "Writer", one: "first message drafted", many: "first messages drafted", did: "Drafted a first message to" },
  draft_reply: { agent: "Writer", one: "answer to a reply drafted", many: "answers to replies drafted", did: "Drafted an answer to" },
  prepare_handoff: { agent: "Meeting briefer", one: "meeting brief prepared", many: "meeting briefs prepared", did: "Prepared a meeting brief on" },
  write_report: { agent: "Reporter", one: "weekly letter written", many: "weekly letters written", did: "Wrote the weekly letter for" },
};
const words = (kind: string) => TASK_WORDS[kind] ?? { agent: sentence(kind), one: "task done", many: "tasks done", did: sentence(kind) };

const AGENT_JOBS: Record<string, string> = {
  supervisor: "Hands out work, paces outreach, watches budgets",
  researcher: "Researches each buyer on the web, scores the fit and plans the pitch",
  writer: "Plans each buyer's channels and writes every message, meeting brief and weekly letter",
  reviewer: "Grades every message and runs the safety checks; sorts replies",
  mock_buyer: "Plays buyers in practice rounds",
};
const AGENT_NAMES: Record<string, string> = { "prospect-researcher": "Prospect researcher", mock_buyer: "Practice buyer",
  "meeting-briefer": "Meeting briefer" };
const WORDS = ["Nothing", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"];
const spell = (n: number, lower = false) => {
  const w = WORDS[n] ?? num(n);
  return lower ? w.toLowerCase() : w;
};

/** Today: what needs the owner, how each client is doing, and what the agent team is costing. */
export default async function Today() {
  await requireStaff();
  const [[k], drafts, letters, alerts, clients, agents, work, done] = await Promise.all([
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
    // Today's work, counted from midnight in the owner's time zone.
    sql<Work[]>`
      with midnight as (select (date_trunc('day', now() at time zone ${TZ}) at time zone ${TZ}) as t)
      select kind,
             count(*) filter (where status = 'done' and finished_at >= (select t from midnight))::int as done,
             count(*) filter (where status = 'running')::int as running,
             count(*) filter (where status = 'queued')::int as queued,
             count(*) filter (where status = 'failed' and finished_at >= (select t from midnight))::int as failed
      from tasks group by kind`,
    sql<Done[]>`
      select t.id, t.kind, t.status::text, t.finished_at, co.name as company, t.error,
             t.finished_at < (date_trunc('day', now() at time zone ${TZ}) at time zone ${TZ}) as yesterday,
             trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as contact, cl.name as client
      from tasks t left join companies co on co.id = t.company_id left join contacts c on c.id = t.contact_id
      left join clients cl on cl.id = t.client_id
      where t.status in ('done', 'failed') and t.finished_at > now() - interval '24 hours'
      order by t.finished_at desc limit 8`,
  ]);

  const kinds = Object.keys(TASK_WORDS).filter((kind) => work.some((w) => w.kind === kind))
    .concat(work.map((w) => w.kind).filter((kind) => !TASK_WORDS[kind]));
  const doneToday = work.reduce((n, w) => n + w.done, 0);

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
        <div className="sh"><h2>Done today<span className="count">{num(doneToday)}</span></h2><span className="aside">Since midnight</span></div>
        {kinds.length === 0 ? <p className="empty">The agents haven&apos;t started yet. Their work shows here as it finishes.</p> : (
          <table className="ledger work">
            <thead><tr><th>Agent</th><th className="num">Done today</th><th className="num">Working now</th><th className="num">In line</th><th className="num">Failed</th></tr></thead>
            <tbody>
              {kinds.map((kind) => {
                const w = work.find((x) => x.kind === kind)!;
                const t = words(kind);
                return (
                  <tr key={kind}>
                    <td><div className="name">{t.agent}</div><div className="sub">{w.done ? `${num(w.done)} ${w.done === 1 ? t.one : t.many}` : w.running ? "Working on it now" : "Nothing finished yet today"}</div></td>
                    <td className="num" data-label="Done today" style={{ paddingTop: 20 }}>{w.done ? num(w.done) : <span className="faint">–</span>}</td>
                    <td className="num" data-label="Working now" style={{ paddingTop: 20 }}>{w.running ? num(w.running) : <span className="faint">–</span>}</td>
                    <td className="num" data-label="In line" style={{ paddingTop: 20 }}>{w.queued ? num(w.queued) : <span className="faint">–</span>}</td>
                    <td className="num" data-label="Failed" style={{ paddingTop: 20 }}>{w.failed ? <span className="alarm">{num(w.failed)}</span> : <span className="faint">–</span>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
        {done.length > 0 && (
          <table className="ledger latest">
            <tbody>
              {done.map((d) => {
                const who = d.company || d.contact || d.client;
                return (
                  <tr key={d.id}>
                    <td className="lead">{clock(d.finished_at)}{d.yesterday && <div className="faint">Yesterday</div>}</td>
                    <td><div className={d.status === "failed" ? "alarm" : ""}>{d.status === "failed" ? `Failed: ${words(d.kind).did.toLowerCase()}` : words(d.kind).did}{who ? ` ${who}` : ""}.</div>
                      <div className="sub">{words(d.kind).agent}{d.client ? `, for ${d.client}` : ""}{d.status === "failed" && d.error ? `. ${d.error.slice(0, 140)}` : ""}</div></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
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
                  <td className="num" data-label="Ordered, 30 days" style={{ paddingTop: 20 }}>{c.ordered ? money(c.ordered) : <span className="faint">–</span>}</td>
                  <td className="num won" data-label="Won so far" style={{ paddingTop: 20 }}>{c.won ? money(c.won) : <span className="faint">–</span>}</td>
                  <td className="num" data-label="Buyers deciding" style={{ paddingTop: 20 }}>{num(c.in_play)}{c.deciding > 0 && <div className="sub">{money(c.deciding)}</div>}</td>
                  <td className="num" data-label="Replies, 30 days" style={{ paddingTop: 20 }}>{num(c.replies)}</td>
                  <td className="small" data-label="Last buyer activity" style={{ paddingTop: 21 }}>{ago(c.last_at)}</td>
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
                    <td className="small" data-label="Status" style={{ paddingTop: 21 }}>{a.active ? "Working" : <span className="alarm">Paused</span>}
                      {!a.active && a.paused_reason && <div className="muted">{sentence(a.paused_reason)}</div>}</td>
                    <td className="num" data-label="Spent this month" style={{ paddingTop: 20 }}>
                      {a.budget_usd === 0 ? <span className="faint">No AI cost</span> : <span className={over ? "alarm" : ""}>{usd(a.spent_usd)}</span>}
                      {a.budget_usd > 0 && <div className="sub">{Math.round(a.pct_used ?? 0)}% of budget</div>}
                    </td>
                    <td className="num" data-label="Monthly budget" style={{ paddingTop: 16 }}>
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
