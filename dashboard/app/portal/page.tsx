import Link from "next/link";
import { requirePortal } from "@/lib/auth";
import { portalHref, portalQuery } from "@/lib/portal";
import { ago, change, day, greeting, money, num } from "@/lib/format";
import { ACTIVITY, BUYER_TYPES, STAGES } from "@/lib/pipeline";
import PortalHeader from "@/components/PortalHeader";
import Icon from "@/components/Icon";
import { BarChart, Delta, Sparkline } from "@/components/Charts";

type Week = { week: Date; touches: number; replies: number; meetings: number; samples: number; quotes: number; orders: number; order_value: number };
type Totals = { touches: number; touches_prev: number; replies: number; replies_prev: number; meetings: number; meetings_prev: number;
  samples: number; samples_prev: number; orders: number; value: number; value_prev: number; buyers: number };
type Stage = { stage: string; deals: number; value: number };
type Activity = { id: string; occurred_at: Date; kind: string; company: string | null; buyer_type: string | null; city: string | null;
  state: string | null; contact_title: string | null; value_cents: number | null };
type Report = { id: string; period_start: Date; period_end: Date; summary: string | null; body: string | null };
type Update = { id: string; message: string; created_at: Date; severity: string };

export default async function PortalOverview({ searchParams }: { searchParams: Promise<{ client?: string }> }) {
  const scope = await requirePortal((await searchParams).client);
  const id = scope.clientId;

  const data = await portalQuery(scope, async (q) => {
    const weeks = await q<Week[]>`
      select g.week::date as week, coalesce(v.touches, 0)::int as touches, coalesce(v.replies, 0)::int as replies,
             coalesce(v.meetings, 0)::int as meetings, coalesce(v.samples, 0)::int as samples, coalesce(v.quotes, 0)::int as quotes,
             coalesce(v.orders, 0)::int as orders, coalesce(v.order_value_cents, 0) / 100.0 as order_value
      from generate_series(date_trunc('week', now()) - interval '9 weeks', date_trunc('week', now()), interval '1 week') g(week)
      left join v_client_weekly v on v.client_id = ${id} and v.week = g.week::date
      order by g.week`;
    const [totals] = await q<Totals[]>`
      select count(*) filter (where kind = 'sent' and occurred_at > now() - interval '30 days')::int as touches,
             count(*) filter (where kind = 'sent' and occurred_at <= now() - interval '30 days')::int as touches_prev,
             count(*) filter (where kind = 'reply' and occurred_at > now() - interval '30 days')::int as replies,
             count(*) filter (where kind = 'reply' and occurred_at <= now() - interval '30 days')::int as replies_prev,
             count(*) filter (where kind = 'meeting_booked' and occurred_at > now() - interval '30 days')::int as meetings,
             count(*) filter (where kind = 'meeting_booked' and occurred_at <= now() - interval '30 days')::int as meetings_prev,
             count(*) filter (where kind in ('sample_sent','quote_sent') and occurred_at > now() - interval '30 days')::int as samples,
             count(*) filter (where kind in ('sample_sent','quote_sent') and occurred_at <= now() - interval '30 days')::int as samples_prev,
             count(*) filter (where kind in ('order','reorder') and occurred_at > now() - interval '30 days')::int as orders,
             coalesce(sum(value_cents) filter (where kind in ('order','reorder') and occurred_at > now() - interval '30 days'), 0) / 100.0 as value,
             coalesce(sum(value_cents) filter (where kind in ('order','reorder') and occurred_at <= now() - interval '30 days'), 0) / 100.0 as value_prev,
             count(distinct company) filter (where kind = 'sent' and occurred_at > now() - interval '30 days')::int as buyers
      from v_portal_activity where client_id = ${id} and occurred_at > now() - interval '60 days'`;
    const stages = await q<Stage[]>`
      select stage, count(*)::int as deals, coalesce(sum(value_cents), 0) / 100.0 as value
      from v_portal_pipeline where client_id = ${id} group by stage`;
    const activity = await q<Activity[]>`
      select id, occurred_at, kind, company, buyer_type, city, state, contact_title, value_cents
      from v_portal_activity
      where client_id = ${id} and kind in ('reply','meeting_booked','meeting_held','sample_sent','quote_sent','order','reorder')
      order by occurred_at desc limit 8`;
    const [report] = await q<Report[]>`
      select id, period_start, period_end, summary, body from reports
      where client_id = ${id} and status in ('approved','sent') order by period_start desc limit 1`;
    const updates = await q<Update[]>`
      select id, message, created_at, severity::text from alerts
      where client_id = ${id} and notify_client and status <> 'resolved' order by created_at desc limit 3`;
    const [camp] = await q<{ live: number }[]>`select count(*)::int as live from campaigns where client_id = ${id} and status = 'live'`;
    return { weeks, totals, stages, activity, report, updates, live: camp.live };
  });

  const t = data.totals;
  const open = STAGES.filter((s) => s.key !== "repeat").reduce((n, s) => n + (data.stages.find((x) => x.stage === s.key)?.deals ?? 0), 0);
  const openValue = data.stages.filter((s) => ["sample", "quote"].includes(s.stage)).reduce((n, s) => n + s.value, 0);
  const maxDeals = Math.max(1, ...data.stages.map((s) => s.deals));
  const firstName = scope.preview ? scope.clientName : scope.viewerName;

  return (
    <>
      <PortalHeader scope={scope} />
      <main className="pmain">
        <section className="hero">
          <div className="rise">
            <span className="eyebrow">{greeting(firstName)}</span>
            <h1>Your growth, <em>in plain view.</em></h1>
            <p className="lede">
              In the last 30 days we reached <b>{num(t.buyers)} buyers</b> for {scope.clientName}. {num(t.replies)} replied,
              {" "}{num(t.meetings)} meeting{t.meetings === 1 ? " was" : "s were"} booked and {money(t.value)} in orders came in.
            </p>
            <div className="facts-row">
              <span><span className="dot ok" /> {data.live} live campaign{data.live === 1 ? "" : "s"}</span>
              <span><span className="dot info" /> {open} buyer{open === 1 ? "" : "s"} in your pipeline</span>
              {scope.plan && <span><span className="dot" style={{ background: "var(--gold)" }} /> {scope.plan.charAt(0).toUpperCase() + scope.plan.slice(1)} plan</span>}
            </div>
          </div>
          <div className="feature statement rise d1">
            <span className="eyebrow">Orders, last 30 days</span>
            <div className="figure">{money(t.value)}</div>
            <div className="figure-sub">
              {t.orders} order{t.orders === 1 ? "" : "s"} · {money(openValue)} more in samples and quotes · <Delta pct={change(t.value, t.value_prev)} />
            </div>
            <BarChart height={150} format={money}
              data={data.weeks.map((w) => ({ label: day(w.week), value: w.order_value, title: `Orders, week of ${day(w.week)}` }))} />
          </div>
        </section>

        <section className="grid g4">
          <Stat label="Outreach sent" value={t.touches} pct={change(t.touches, t.touches_prev)} trend={data.weeks.map((w) => w.touches)} />
          <Stat label="Replies" value={t.replies} pct={change(t.replies, t.replies_prev)} trend={data.weeks.map((w) => w.replies)}
            note={t.touches ? `${((t.replies / t.touches) * 100).toFixed(1)}% reply rate` : undefined} />
          <Stat label="Meetings booked" value={t.meetings} pct={change(t.meetings, t.meetings_prev)} trend={data.weeks.map((w) => w.meetings)} />
          <Stat label="Samples and quotes" value={t.samples} pct={change(t.samples, t.samples_prev)} trend={data.weeks.map((w) => w.samples + w.quotes)} />
        </section>

        <div className="section-title">
          <h2>Where every buyer stands</h2>
          <Link className="btn sm dash" href={portalHref(scope, "/portal/pipeline")}>See the full pipeline</Link>
        </div>
        <section className="card stages rise">
          {STAGES.map((s) => {
            const row = data.stages.find((x) => x.stage === s.key);
            return (
              <div className={`stage ${s.key === "first_order" || s.key === "repeat" ? "won" : ""}`} key={s.key}>
                <span className="step">{s.step}</span>
                <div className="n">{row?.deals ?? 0}</div>
                <div className="name">{s.name}</div>
                <div className="v">{row?.value ? money(row.value) : "No value yet"}</div>
                <div className="track"><i style={{ width: `${((row?.deals ?? 0) / maxDeals) * 100}%` }} /></div>
              </div>
            );
          })}
        </section>

        <section className="split" style={{ marginTop: 16 }}>
          <div className="card">
            <div className="card-head"><h3>Latest from your buyers</h3><span className="note">Replies, meetings, samples and orders</span></div>
            {data.activity.length === 0 ? <div className="empty"><b>Nothing yet</b>Replies and meetings will appear here as they happen.</div> : (
              <ul className="timeline">
                {data.activity.map((a) => {
                  const k = ACTIVITY[a.kind] ?? { label: a.kind, icon: "spark" };
                  return (
                    <li key={a.id}>
                      <span className={`ico ${k.tone ?? ""}`}><Icon name={k.icon} /></span>
                      <div>
                        <div className="t">{k.label}{a.company ? ` · ${a.company}` : ""}{a.value_cents ? ` · ${money(a.value_cents / 100)}` : ""}</div>
                        <div className="m">{[a.contact_title, BUYER_TYPES[a.buyer_type ?? ""] ?? null, [a.city, a.state].filter(Boolean).join(", ")].filter(Boolean).join(" · ")}</div>
                      </div>
                      <span className="when">{ago(a.occurred_at)}</span>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>

          <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
            <div className="card pad letter-teaser">
              <span className="eyebrow">This week&apos;s report</span>
              {data.report ? (
                <>
                  <h3>{data.report.summary ?? "Your weekly report"}</h3>
                  <div className="xs muted">Week of {day(data.report.period_start)} to {day(data.report.period_end)}</div>
                  <p className="excerpt">{excerpt(data.report.body)}</p>
                  <Link className="btn primary dash" style={{ alignSelf: "flex-start" }} href={portalHref(scope, `/portal/reports/${data.report.id}`)}>Read the report</Link>
                </>
              ) : <p className="muted">Your first weekly report arrives on Monday.</p>}
            </div>
            {data.updates.length > 0 && (
              <div className="card">
                <div className="card-head"><h3>Updates from your team</h3></div>
                <div className="list" style={{ marginTop: 8 }}>
                  {data.updates.map((u) => (
                    <div className="item" key={u.id}>
                      <span className={`dot ${u.severity === "urgent" ? "urgent" : "info"}`} />
                      <div className="body"><div style={{ fontSize: 13.5 }}>{u.message}</div><div className="meta">{ago(u.created_at)}</div></div>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        </section>
        <p className="xs faint" style={{ marginTop: 28, textAlign: "center" }}>
          Prepared for {scope.clientName} by SBM Partners. Figures update as activity happens.
        </p>
      </main>
    </>
  );
}

function Stat({ label, value, pct, trend, note }: { label: string; value: number; pct: number | null; trend: number[]; note?: string }) {
  return (
    <div className="card stat rise d2">
      <div className="k">{label}<Delta pct={pct} /></div>
      <div className="v">{num(value)}</div>
      <div className="foot"><span>{note ?? "vs prior 30 days"}</span><Sparkline values={trend} /></div>
    </div>
  );
}

function excerpt(body: string | null) {
  if (!body) return "";
  const paras = body.split(/\n\s*\n/).map((p) => p.trim()).filter((p) => p.length > 40);
  const first = paras[0] ?? body;
  return first.length > 260 ? `${first.slice(0, 257).trimEnd()}…` : first;
}
