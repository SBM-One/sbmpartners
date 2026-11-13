import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { money, sentence } from "@/lib/format";
import { updateClient } from "../../actions";
import Submit from "@/components/Submit";
import Icon from "@/components/Icon";
import { Sparkline } from "@/components/Charts";

type Client = { id: string; name: string; status: string; plan: string | null; has_brief: boolean; daily_draft_limit: number;
  live: number; targets: number; drafts_today: number; waiting: number; portal_users: number;
  touches: number; replies: number; meetings: number; orders: number; order_value: number; trend: number[] };

export default async function Clients() {
  await requireStaff();
  const clients = await sql<Client[]>`
    select c.id, c.name, c.status, c.plan, c.brief <> '{}'::jsonb as has_brief, c.daily_draft_limit,
      (select count(*)::int from campaigns ca where ca.client_id = c.id and ca.status = 'live') as live,
      (select count(*)::int from campaign_targets t join campaigns ca on ca.id = t.campaign_id where ca.client_id = c.id) as targets,
      (select count(*)::int from outreach_drafts d where d.client_id = c.id and d.created_at::date = current_date) as drafts_today,
      (select count(*)::int from outreach_drafts d where d.client_id = c.id and d.status = 'pending_review') as waiting,
      (select count(*)::int from client_users u where u.client_id = c.id) as portal_users,
      coalesce(w.touches, 0)::int as touches, coalesce(w.replies, 0)::int as replies, coalesce(w.meetings, 0)::int as meetings,
      coalesce(w.orders, 0)::int as orders, coalesce(w.order_value_cents, 0) / 100.0 as order_value,
      (select coalesce(array_agg(coalesce(v.replies, 0)::int order by g.week), '{}')
         from generate_series(date_trunc('week', now()) - interval '9 weeks', date_trunc('week', now()), interval '1 week') g(week)
         left join v_client_weekly v on v.client_id = c.id and v.week = g.week::date) as trend
    from clients c
    left join lateral (select sum(touches) touches, sum(replies) replies, sum(meetings) meetings, sum(orders) orders,
                              sum(order_value_cents) order_value_cents
                       from v_client_weekly v where v.client_id = c.id and v.week > now() - interval '30 days') w on true
    order by c.status = 'active' desc, c.name`;

  return (
    <>
      <header className="ph rise">
        <div>
          <span className="eyebrow">Clients</span>
          <h1>Every partner, <em className="accent">at a glance.</em></h1>
          <p>Results over the last 30 days, how fast the agents work for each client, and a direct look at what each
            client sees in their portal.</p>
        </div>
      </header>
      {clients.length === 0 ? <div className="empty boxed"><b>No clients yet</b>Add one in the Supabase table editor.</div> : (
        <div className="card table-scroll">
          <table className="table">
            <thead>
              <tr><th>Client</th><th>Fact sheet</th><th className="num">Sent</th><th className="num">Replies</th>
                <th>Replies, 10 weeks</th><th className="num">Meetings</th><th className="num">Orders</th>
                <th className="num">Waiting</th><th>Drafts per day</th><th></th></tr>
            </thead>
            <tbody>
              {clients.map((c) => (
                <tr key={c.id}>
                  <td>
                    <div className="title">{c.name}</div>
                    <div className="sub">{sentence(c.status)}{c.plan ? ` · ${sentence(c.plan)} plan` : ""} · {c.live} live campaign{c.live === 1 ? "" : "s"}</div>
                  </td>
                  <td>{c.has_brief ? <span className="pill ok">Ready</span> : <span className="pill bad">Missing</span>}</td>
                  <td className="num">{c.touches}</td>
                  <td className="num">{c.replies}</td>
                  <td><Sparkline values={c.trend} width={96} height={28} /></td>
                  <td className="num">{c.meetings}</td>
                  <td className="num">{c.orders}{c.order_value > 0 && <div className="sub">{money(c.order_value)}</div>}</td>
                  <td className="num">{c.waiting ? <span className="pill blue">{c.waiting}</span> : 0}</td>
                  <td>
                    <form action={updateClient} className="inline">
                      <input type="hidden" name="id" value={c.id} />
                      <input className="compact" name="daily_draft_limit" type="number" min="0" max="500" defaultValue={c.daily_draft_limit}
                        aria-label={`Daily draft limit for ${c.name}`} />
                      <Submit className="sm quiet">Save</Submit>
                    </form>
                  </td>
                  <td style={{ textAlign: "right" }}>
                    <Link className="btn sm" href={`/portal?client=${c.id}`} title={c.portal_users ? `${c.portal_users} portal login(s)` : "No portal logins yet"}>
                      <Icon name="portal" />Portal
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="xs faint" style={{ marginTop: 12 }}>A missing fact sheet means the Writer can&apos;t draft for that client. Add one with
        <span className="mono"> python -m agents.team set-brief</span>. To give someone at a client a portal login, see the dashboard README.</p>
    </>
  );
}
