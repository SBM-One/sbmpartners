import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, label, usd } from "@/lib/format";
import { updateAgent, updateAlert } from "./actions";
import AutoRefresh from "@/components/AutoRefresh";
import Submit from "@/components/Submit";

type Agent = { agent_id: string; name: string; role: string; active: boolean; paused_reason: string | null;
  spent_usd: number; budget_usd: number; pct_used: number | null };
type Alert = { id: string; severity: string; kind: string; message: string; status: string; created_at: Date; client: string | null };
type TeamRow = { kind: string; status: string; tasks: number };

const AGENT_JOBS: Record<string, string> = {
  supervisor: "Hands out work, paces outreach, watches budgets",
  "prospect-researcher": "Looks up each buyer before outreach",
  writer: "Drafts outreach from the approved playbook",
  grader: "Scores every draft from 0 to 100",
  reporter: "Writes weekly client reports",
  researcher: "Builds the sales playbook from research",
  mock_buyer: "Plays buyers in practice rounds",
};

export default async function Overview() {
  await requireStaff();
  const [[k], agents, alerts, team] = await Promise.all([
    sql<{ waiting: number; oldest: Date | null; alerts: number; urgent: number; spent: number; budget: number;
      drafts7: number; score7: number | null; failed24: number; done24: number }[]>`
      select (select count(*)::int from outreach_drafts where status = 'pending_review') as waiting,
             (select min(created_at) from outreach_drafts where status = 'pending_review') as oldest,
             (select count(*)::int from alerts where status = 'open' and not notify_client) as alerts,
             (select count(*)::int from alerts where status = 'open' and severity = 'urgent' and not notify_client) as urgent,
             (select coalesce(sum(spent_usd), 0) from v_agent_spend_month) as spent,
             (select coalesce(sum(budget_usd), 0) from v_agent_spend_month where active) as budget,
             (select count(*)::int from outreach_drafts where created_at > now() - interval '7 days') as drafts7,
             (select round(avg(score)::numeric, 0) from outreach_drafts where created_at > now() - interval '7 days') as score7,
             (select count(*)::int from tasks where status = 'failed' and finished_at > now() - interval '1 day') as failed24,
             (select count(*)::int from tasks where status = 'done' and finished_at > now() - interval '1 day') as done24`,
    sql<Agent[]>`select * from v_agent_spend_month order by budget_usd desc, name`,
    sql<Alert[]>`select a.id, a.severity::text, a.kind, a.message, a.status::text, a.created_at, c.name as client
                 from alerts a left join clients c on c.id = a.client_id
                 where a.status <> 'resolved' and not a.notify_client
                 order by (a.severity = 'urgent') desc, a.created_at desc limit 20`,
    sql<TeamRow[]>`select kind, status::text, tasks::int from v_team_status`,
  ]);

  const kinds = ["research_prospect", "draft_outreach", "write_report"];
  const statuses = ["queued", "running", "done", "failed"];
  const count = (kind: string, status: string) => team.find((t) => t.kind === kind && t.status === status)?.tasks ?? 0;

  return (
    <>
      <AutoRefresh seconds={30} />
      <h1>Overview</h1>
      <p className="lead">Everything the agents are doing, live. Updates every 30 seconds.</p>

      <div className="grid kpis">
        <Link href="/approvals" className={`card kpi ${k.waiting ? "hot" : ""}`}>
          <div className="n">{k.waiting}</div>
          <div className="l">drafts waiting for approval{k.oldest ? ` · oldest ${ago(k.oldest)}` : ""}</div>
        </Link>
        <div className={`card kpi ${k.urgent ? "hot" : ""}`}>
          <div className="n">{k.alerts}</div>
          <div className="l">open alerts{k.urgent ? ` · ${k.urgent} urgent` : ""}</div>
        </div>
        <div className="card kpi">
          <div className="n">{usd(k.spent)}</div>
          <div className="l">AI spend this month · budgets {usd(k.budget)}</div>
        </div>
        <div className="card kpi">
          <div className="n">{k.score7 ?? "–"}</div>
          <div className="l">average draft score, last 7 days ({k.drafts7} drafts)</div>
        </div>
      </div>

      <h2>Alerts</h2>
      {alerts.length === 0 ? (
        <div className="empty">No open alerts. All quiet.</div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          {alerts.map((a) => (
            <div className="alert-row" key={a.id}>
              <span className={`pill ${a.severity}`}>{a.severity}</span>
              <div className="msg">
                {a.message}
                <div className="when">{label(a.kind)}{a.client ? ` · ${a.client}` : ""} · {ago(a.created_at)}
                  {a.status === "acknowledged" ? " · seen" : ""}</div>
              </div>
              <form action={updateAlert} className="inline">
                <input type="hidden" name="id" value={a.id} />
                {a.status === "open" && <Submit name="status" value="acknowledged">Seen</Submit>}
                <Submit name="status" value="resolved">Resolve</Submit>
              </form>
            </div>
          ))}
        </div>
      )}

      <h2>Agents</h2>
      <table>
        <thead>
          <tr><th>Agent</th><th>Status</th><th>Spent this month</th><th></th><th>Monthly budget</th><th></th></tr>
        </thead>
        <tbody>
          {agents.map((a) => {
            const pct = Math.min(100, a.pct_used ?? 0);
            const tone = pct >= 100 ? "urgent" : pct >= 80 ? "warning" : "";
            const unlimited = a.budget_usd === 0;
            return (
              <tr key={a.agent_id}>
                <td><b>{a.name}</b><div className="muted small">{AGENT_JOBS[a.name] ?? label(a.role)}</div></td>
                <td>
                  {a.active ? <span className="pill ok">working</span>
                    : <span className="pill warning" title={a.paused_reason ?? ""}>paused</span>}
                  {!a.active && a.paused_reason && <div className="muted small">{a.paused_reason}</div>}
                </td>
                <td className="num">{usd(a.spent_usd)}</td>
                <td style={{ width: 140 }}>{!unlimited && <div className="bar"><i className={tone} style={{ width: `${pct}%` }} /></div>}</td>
                <td>
                  {a.name === "supervisor" ? <span className="muted small">no AI cost</span> : (
                    <form action={updateAgent} className="inline">
                      <input type="hidden" name="id" value={a.agent_id} />
                      <input type="hidden" name="op" value="budget" />
                      $<input className="small" name="budget" type="number" min="0" step="5" defaultValue={a.budget_usd} />
                      <Submit>Save</Submit>
                    </form>
                  )}
                </td>
                <td>
                  {a.name !== "supervisor" && <form action={updateAgent}>
                    <input type="hidden" name="id" value={a.agent_id} />
                    {a.active
                      ? <Submit name="op" value="pause" className="danger" confirm={`Pause ${a.name}? Its tasks will wait until you resume it.`}>Pause</Submit>
                      : <Submit name="op" value="resume">Resume</Submit>}
                  </form>}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

      <h2>Team work, last 7 days</h2>
      <table>
        <thead><tr><th>Task</th>{statuses.map((s) => <th key={s} className="num">{s}</th>)}</tr></thead>
        <tbody>
          {kinds.map((kind) => (
            <tr key={kind}>
              <td>{label(kind)}</td>
              {statuses.map((s) => (
                <td key={s} className="num">{s === "failed" && count(kind, s) ? <span className="pill bad">{count(kind, s)}</span> : count(kind, s)}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <p className="muted small">In the last 24 hours: {k.done24} tasks finished, {k.failed24} failed.</p>
    </>
  );
}
