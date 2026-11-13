import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, change, day, greeting, label, money, num, sentence, today, usd } from "@/lib/format";
import { updateAgent, updateAlert } from "../actions";
import AutoRefresh from "@/components/AutoRefresh";
import Submit from "@/components/Submit";
import Icon from "@/components/Icon";
import { BarChart, Delta, Sparkline } from "@/components/Charts";

type Agent = { agent_id: string; name: string; role: string; active: boolean; paused_reason: string | null;
  spent_usd: number; budget_usd: number; pct_used: number | null };
type Alert = { id: string; severity: string; kind: string; message: string; status: string; created_at: Date; client: string | null };
type TeamRow = { kind: string; status: string; tasks: number };
type Week = { week: Date; touches: number; replies: number; meetings: number; orders: number; order_value: number };

const AGENT_JOBS: Record<string, string> = {
  supervisor: "Hands out work, paces outreach, watches budgets",
  "prospect-researcher": "Looks up each buyer before outreach",
  writer: "Drafts outreach from the approved playbook",
  grader: "Scores every draft from 0 to 100",
  reporter: "Writes weekly client reports",
  researcher: "Builds the sales playbook from research",
  mock_buyer: "Plays buyers in practice rounds",
};
const AGENT_NAMES: Record<string, string> = { "prospect-researcher": "Prospect researcher" };

export default async function Overview() {
  const me = await requireStaff();
  const [[k], agents, alerts, team, weeks, [p]] = await Promise.all([
    sql<{ waiting: number; oldest: Date | null; reports: number; urgent: number; spent: number; budget: number;
      drafts7: number; score7: number | null; failed24: number; done24: number; clients: number }[]>`
      select (select count(*)::int from outreach_drafts where status = 'pending_review') as waiting,
             (select min(created_at) from outreach_drafts where status = 'pending_review') as oldest,
             (select count(*)::int from reports where status = 'draft') as reports,
             (select count(*)::int from alerts where status = 'open' and severity = 'urgent' and not notify_client) as urgent,
             (select coalesce(sum(spent_usd), 0) from v_agent_spend_month) as spent,
             (select coalesce(sum(budget_usd), 0) from v_agent_spend_month where active) as budget,
             (select count(*)::int from outreach_drafts where created_at > now() - interval '7 days') as drafts7,
             (select round(avg(score)::numeric, 0) from outreach_drafts where created_at > now() - interval '7 days') as score7,
             (select count(*)::int from tasks where status = 'failed' and finished_at > now() - interval '1 day') as failed24,
             (select count(*)::int from tasks where status = 'done' and finished_at > now() - interval '1 day') as done24,
             (select count(*)::int from clients where status = 'active') as clients`,
    sql<Agent[]>`select * from v_agent_spend_month order by budget_usd desc, name`,
    sql<Alert[]>`select a.id, a.severity::text, a.kind, a.message, a.status::text, a.created_at, c.name as client
                 from alerts a left join clients c on c.id = a.client_id
                 where a.status <> 'resolved' and not a.notify_client
                 order by (a.severity = 'urgent') desc, a.created_at desc limit 8`,
    sql<TeamRow[]>`select kind, status::text, tasks::int from v_team_status`,
    sql<Week[]>`
      select g.week::date as week, coalesce(sum(v.touches), 0)::int as touches, coalesce(sum(v.replies), 0)::int as replies,
             coalesce(sum(v.meetings), 0)::int as meetings, coalesce(sum(v.orders), 0)::int as orders,
             coalesce(sum(v.order_value_cents), 0) / 100.0 as order_value
      from generate_series(date_trunc('week', now()) - interval '9 weeks', date_trunc('week', now()), interval '1 week') g(week)
      left join v_client_weekly v on v.week = g.week::date
      group by g.week order by g.week`,
    sql<{ replies: number; replies_prev: number; meetings: number; meetings_prev: number; value: number; value_prev: number;
      touches: number; touches_prev: number }[]>`
      select count(*) filter (where kind = 'reply' and occurred_at > now() - interval '30 days')::int as replies,
             count(*) filter (where kind = 'reply' and occurred_at <= now() - interval '30 days')::int as replies_prev,
             count(*) filter (where kind = 'meeting_booked' and occurred_at > now() - interval '30 days')::int as meetings,
             count(*) filter (where kind = 'meeting_booked' and occurred_at <= now() - interval '30 days')::int as meetings_prev,
             coalesce(sum(value_cents) filter (where kind in ('order','reorder') and occurred_at > now() - interval '30 days'), 0) / 100.0 as value,
             coalesce(sum(value_cents) filter (where kind in ('order','reorder') and occurred_at <= now() - interval '30 days'), 0) / 100.0 as value_prev,
             count(*) filter (where kind in ('sent','call') and direction = 'outbound' and occurred_at > now() - interval '30 days')::int as touches,
             count(*) filter (where kind in ('sent','call') and direction = 'outbound' and occurred_at <= now() - interval '30 days')::int as touches_prev
      from interactions where occurred_at > now() - interval '60 days'`,
  ]);

  const kinds = ["research_prospect", "draft_outreach", "write_report"];
  const statuses = ["queued", "running", "done", "failed"];
  const count = (kind: string, status: string) => team.find((t) => t.kind === kind && t.status === status)?.tasks ?? 0;
  const spendPct = k.budget > 0 ? Math.round((k.spent / k.budget) * 100) : 0;
  const needs = [k.waiting && `${k.waiting} draft${k.waiting === 1 ? "" : "s"}`, k.reports && `${k.reports} report${k.reports === 1 ? "" : "s"}`]
    .filter(Boolean).join(" and ");
  const paused = agents.filter((a) => !a.active && a.name !== "supervisor").length;

  return (
    <>
      <AutoRefresh seconds={30} />
      <header className="ph rise">
        <div>
          <span className="eyebrow">{today()}</span>
          <h1>{greeting(me.name)}, <em className="accent">here&apos;s your day.</em></h1>
          <p>{needs ? `${needs} need your approval.` : "Nothing is waiting for you."} {k.clients} active client{k.clients === 1 ? "" : "s"},
            {" "}{k.done24} tasks finished in the last 24 hours. This page refreshes itself every 30 seconds.</p>
        </div>
        <div className="aside">
          <span className="pill">{paused ? <><span className="dot warning" /> {paused} agent{paused === 1 ? "" : "s"} paused</>
            : <><span className="dot ok" /> All agents working</>}</span>
        </div>
      </header>

      <section className="grid g3">
        <Link href="/approvals" className="feature action rise d1">
          <span className="eyebrow">Needs you</span>
          <div className="big">{k.waiting}</div>
          <div>
            <div className="what">Drafts waiting for approval</div>
            <div className="sub">{k.oldest ? `Oldest written ${ago(k.oldest)}` : "The queue is clear"}{k.score7 ? ` · average score ${k.score7}` : ""}</div>
          </div>
          <span className="go">Review drafts</span>
        </Link>
        <Link href="/reports" className="action quiet rise d2">
          <span className="eyebrow plain">Client reports</span>
          <div className="big">{k.reports}</div>
          <div>
            <div className="what">Reports to approve</div>
            <div className="sub">Clients only see a report after you approve it</div>
          </div>
          <span className="go">Open reports</span>
        </Link>
        <a href="#alerts" className="action quiet rise d3">
          <span className="eyebrow plain">Alerts</span>
          <div className="big" style={{ color: k.urgent ? "var(--bad)" : undefined }}>{k.urgent}</div>
          <div>
            <div className="what">Urgent alert{k.urgent === 1 ? "" : "s"}</div>
            <div className="sub">{alerts.length} open in total</div>
          </div>
          <span className="go">See alerts</span>
        </a>
      </section>

      <div className="section-title"><h2>Results, last 30 days</h2><span className="note">All clients · compared with the 30 days before</span></div>
      <section className="grid g4">
        <Stat label="Outreach sent" value={num(p.touches)} pct={change(p.touches, p.touches_prev)} trend={weeks.map((w) => w.touches)} />
        <Stat label="Replies" value={num(p.replies)} pct={change(p.replies, p.replies_prev)} trend={weeks.map((w) => w.replies)}
          sub={p.touches ? `${((p.replies / p.touches) * 100).toFixed(1)}% reply rate` : undefined} />
        <Stat label="Meetings booked" value={num(p.meetings)} pct={change(p.meetings, p.meetings_prev)} trend={weeks.map((w) => w.meetings)} />
        <Stat label="Order value" value={money(p.value)} pct={change(p.value, p.value_prev)} trend={weeks.map((w) => w.order_value)} />
      </section>

      <section className="split" style={{ marginTop: 16 }}>
        <div className="card">
          <div className="card-head"><h3>Meetings booked per week</h3><span className="note">All clients · this week in gold</span></div>
          <div className="card-body">
            <BarChart data={weeks.map((w) => ({ label: day(w.week), value: w.meetings, title: `Week of ${day(w.week)}` }))} />
          </div>
        </div>
        <div className="card" id="alerts">
          <div className="card-head"><h3>Alerts</h3><span className="note">{alerts.length} open</span></div>
          {alerts.length === 0 ? <div className="empty"><b>All quiet</b>No open alerts.</div> : (
            <div className="list" style={{ marginTop: 8 }}>
              {alerts.map((a) => (
                <div className="item" key={a.id}>
                  <span className={`dot ${a.severity}`} />
                  <div className="body">
                    <div style={{ fontSize: 13.5, color: "var(--ink)" }}>{a.message}</div>
                    <div className="meta">{sentence(a.kind)}{a.client ? ` · ${a.client}` : ""} · {ago(a.created_at)}{a.status === "acknowledged" ? " · seen" : ""}</div>
                    <form action={updateAlert} className="actions">
                      <input type="hidden" name="id" value={a.id} />
                      <Submit name="status" value="resolved" className="sm">Resolve</Submit>
                      {a.status === "open" && <Submit name="status" value="acknowledged" className="sm quiet">Mark seen</Submit>}
                    </form>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </section>

      <div className="section-title">
        <h2>The agent team</h2>
        <span className="note">AI spend this month {usd(k.spent)} of {usd(k.budget)} ({spendPct}%)</span>
      </div>
      <div className="card table-scroll">
        <table className="table">
          <thead>
            <tr><th>Agent</th><th>Status</th><th className="num">Spent this month</th><th>Of budget</th><th>Monthly budget</th><th></th></tr>
          </thead>
          <tbody>
            {agents.map((a) => {
              const pct = Math.min(100, a.pct_used ?? 0);
              const tone = pct >= 100 ? "urgent" : pct >= 80 ? "warning" : "";
              const unlimited = a.budget_usd === 0;
              return (
                <tr key={a.agent_id}>
                  <td><div className="title">{AGENT_NAMES[a.name] ?? sentence(a.name)}</div><div className="sub">{AGENT_JOBS[a.name] ?? label(a.role)}</div></td>
                  <td>
                    {a.active ? <span className="pill ok"><span className="dot ok" />Working</span>
                      : <span className="pill warning" title={a.paused_reason ?? ""}><span className="dot warning" />Paused</span>}
                    {!a.active && a.paused_reason && <div className="sub">{a.paused_reason}</div>}
                  </td>
                  <td className="num">{usd(a.spent_usd)}</td>
                  <td style={{ width: 180 }}>{unlimited ? <span className="faint small">no AI cost</span> : (
                    <div className="inline" style={{ width: "100%" }}>
                      <div className="meter" style={{ flex: 1 }}><i className={tone} style={{ width: `${pct}%` }} /></div>
                      <span className="xs muted tnum">{Math.round(a.pct_used ?? 0)}%</span>
                    </div>
                  )}</td>
                  <td>
                    {a.name === "supervisor" ? <span className="faint small">rules only</span> : (
                      <form action={updateAgent} className="inline">
                        <input type="hidden" name="id" value={a.agent_id} />
                        <input type="hidden" name="op" value="budget" />
                        <span className="money-input">$<input className="compact" name="budget" type="number" min="0" step="5" defaultValue={a.budget_usd} aria-label={`Monthly budget for ${a.name}`} /></span>
                        <Submit className="sm quiet">Save</Submit>
                      </form>
                    )}
                  </td>
                  <td style={{ textAlign: "right" }}>
                    {a.name !== "supervisor" && <form action={updateAgent}>
                      <input type="hidden" name="id" value={a.agent_id} />
                      {a.active
                        ? <Submit name="op" value="pause" className="sm danger" confirm={`Pause ${a.name}? Its tasks will wait until you resume it.`}><Icon name="pause" />Pause</Submit>
                        : <Submit name="op" value="resume" className="sm"><Icon name="play" />Resume</Submit>}
                    </form>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div className="section-title"><h2>Team work, last 7 days</h2><span className="note">{k.done24} finished and {k.failed24} failed in the last 24 hours</span></div>
      <div className="card table-scroll">
        <table className="table">
          <thead><tr><th>Task</th>{statuses.map((s) => <th key={s} className="num">{s}</th>)}</tr></thead>
          <tbody>
            {kinds.map((kind) => (
              <tr key={kind}>
                <td className="title">{sentence(kind)}</td>
                {statuses.map((s) => (
                  <td key={s} className="num">{s === "failed" && count(kind, s) ? <span className="pill bad">{count(kind, s)}</span>
                    : s === "running" && count(kind, s) ? <span className="pill blue">{count(kind, s)}</span> : count(kind, s)}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}

function Stat({ label, value, pct, trend, sub }: { label: string; value: string; pct: number | null; trend: number[]; sub?: string }) {
  return (
    <div className="card stat rise">
      <div className="k">{label}<Delta pct={pct} /></div>
      <div className="v">{value}</div>
      <div className="foot"><span>{sub ?? "10-week trend"}</span><Sparkline values={trend} /></div>
    </div>
  );
}
