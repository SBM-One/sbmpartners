import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { updateClient } from "../actions";
import Submit from "@/components/Submit";

type Client = { id: string; name: string; status: string; plan: string | null; has_brief: boolean; daily_draft_limit: number;
  live: number; targets: number; drafts_today: number; waiting: number; approved: number;
  touches: number; replies: number; meetings: number; orders: number; order_value: number };

export default async function Clients() {
  await requireStaff();
  const clients = await sql<Client[]>`
    select c.id, c.name, c.status, c.plan, c.brief <> '{}'::jsonb as has_brief, c.daily_draft_limit,
      (select count(*)::int from campaigns ca where ca.client_id = c.id and ca.status = 'live') as live,
      (select count(*)::int from campaign_targets t join campaigns ca on ca.id = t.campaign_id where ca.client_id = c.id) as targets,
      (select count(*)::int from outreach_drafts d where d.client_id = c.id and d.created_at::date = current_date) as drafts_today,
      (select count(*)::int from outreach_drafts d where d.client_id = c.id and d.status = 'pending_review') as waiting,
      (select count(*)::int from outreach_drafts d where d.client_id = c.id and d.status in ('approved','sent')) as approved,
      coalesce(w.touches, 0)::int as touches, coalesce(w.replies, 0)::int as replies, coalesce(w.meetings, 0)::int as meetings,
      coalesce(w.orders, 0)::int as orders, coalesce(w.order_value_cents, 0) / 100.0 as order_value
    from clients c
    left join lateral (select sum(touches) touches, sum(replies) replies, sum(meetings) meetings, sum(orders) orders,
                              sum(order_value_cents) order_value_cents
                       from v_client_weekly v where v.client_id = c.id and v.week > now() - interval '30 days') w on true
    order by c.status = 'active' desc, c.name`;

  return (
    <>
      <h1>Clients</h1>
      <p className="lead">Results over the last 30 days, and how fast the agents work for each client.</p>
      {clients.length === 0 ? <div className="empty">No clients yet.</div> : (
        <table>
          <thead>
            <tr><th>Client</th><th>Fact sheet</th><th className="num">Buyers</th><th className="num">Drafts today</th>
              <th className="num">Waiting</th><th className="num">Sent</th><th className="num">Replies</th>
              <th className="num">Meetings</th><th className="num">Orders</th><th>Drafts per day</th></tr>
          </thead>
          <tbody>
            {clients.map((c) => (
              <tr key={c.id}>
                <td><b>{c.name}</b><div className="muted small">{c.status}{c.plan ? ` · ${c.plan}` : ""} · {c.live} live campaign{c.live === 1 ? "" : "s"}</div></td>
                <td>{c.has_brief ? <span className="pill ok">ready</span> : <span className="pill bad">missing</span>}</td>
                <td className="num">{c.targets}</td>
                <td className="num">{c.drafts_today}</td>
                <td className="num">{c.waiting}</td>
                <td className="num">{c.touches}</td>
                <td className="num">{c.replies}</td>
                <td className="num">{c.meetings}</td>
                <td className="num">{c.orders}{c.order_value > 0 && <div className="muted small">${Math.round(c.order_value).toLocaleString("en-US")}</div>}</td>
                <td>
                  <form action={updateClient} className="inline">
                    <input type="hidden" name="id" value={c.id} />
                    <input className="small" name="daily_draft_limit" type="number" min="0" max="500" defaultValue={c.daily_draft_limit} />
                    <Submit>Save</Submit>
                  </form>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <p className="muted small">A missing fact sheet means the Writer can&apos;t draft for that client. Add one with
        <code> python -m agents.team set-brief</code>.</p>
    </>
  );
}
