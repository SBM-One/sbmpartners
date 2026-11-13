import Link from "next/link";
import { requirePortal } from "@/lib/auth";
import { portalHref, portalQuery } from "@/lib/portal";
import { ago, day, money, num, today } from "@/lib/format";
import { ACTIVITY, BUYER_TYPES, STAGES, stageName } from "@/lib/pipeline";
import PortalHeader from "@/components/PortalHeader";

type Buyer = { id: string; company: string | null; buyer_type: string | null; city: string | null; state: string | null;
  stage: string; value_cents: number | null; last_kind: string | null; last_at: Date | null };
type Month = { buyers: number; replies: number; meetings: number; others: number };
type Report = { id: string; period_start: Date; period_end: Date; summary: string | null; body: string | null; total: number };
type Note = { id: string; message: string; created_at: Date; severity: string };

const ORDER = ["repeat", "first_order", "quote", "sample", "conversation", "lost"];
const WON = ["first_order", "repeat"];

/** The client's page: one sentence on where things stand, every buyer behind it, and the latest letter. */
export default async function PortalHome({ searchParams }: { searchParams: Promise<{ client?: string }> }) {
  const scope = await requirePortal((await searchParams).client);
  const id = scope.clientId;

  const { buyers, month, report, notes } = await portalQuery(scope, async (q) => {
    const buyers = await q<Buyer[]>`
      select p.id, p.company, p.buyer_type, p.city, p.state, p.stage, p.value_cents, l.kind as last_kind, l.occurred_at as last_at
      from v_portal_pipeline p
      left join lateral (select a.kind, a.occurred_at from v_portal_activity a
                         where a.client_id = p.client_id and a.company = p.company and a.kind <> 'sent'
                         order by a.occurred_at desc limit 1) l on true
      where p.client_id = ${id}
      order by array_position(${ORDER}::text[], p.stage), p.value_cents desc nulls last, l.occurred_at desc nulls last`;
    const [month] = await q<Month[]>`
      select count(distinct company) filter (where kind = 'sent' and occurred_at > now() - interval '30 days')::int as buyers,
             count(distinct company) filter (where kind = 'reply' and occurred_at > now() - interval '30 days')::int as replies,
             count(distinct company) filter (where kind = 'meeting_booked' and occurred_at > now() - interval '30 days')::int as meetings,
             count(distinct company) filter (where company not in (select company from v_portal_pipeline where client_id = ${id} and company is not null))::int as others
      from v_portal_activity where client_id = ${id}`;
    const [report] = await q<Report[]>`
      select id, period_start, period_end, summary, body, count(*) over ()::int as total from reports
      where client_id = ${id} and status in ('approved','sent') order by period_start desc limit 1`;
    const notes = await q<Note[]>`
      select id, message, created_at, severity::text from alerts
      where client_id = ${id} and notify_client and status <> 'resolved' order by created_at desc limit 3`;
    return { buyers, month, report, notes };
  });

  const won = buyers.filter((b) => WON.includes(b.stage));
  const deciding = buyers.filter((b) => b.stage === "sample" || b.stage === "quote");
  const sum = (list: Buyer[]) => list.reduce((n, b) => n + (b.value_cents ?? 0) / 100, 0);
  const plural = (n: number, one: string, many: string) => `${num(n)} ${n === 1 ? one : many}`;
  const Plural = (n: number, one: string, many: string) => `${spell(n)} ${n === 1 ? one : many}`;

  return (
    <>
      <PortalHeader scope={scope} />
      <main className="frame">
        <div className="dateline"><span>{today()}</span></div>
        <h1 className="statement">
          {won.length > 0 ? (
            <>{Plural(won.length, "buyer we found has", "buyers we found have")} placed <span className="won">{money(sum(won))}</span> in orders.</>
          ) : <>We are introducing {scope.clientName} to the right buyers.</>}
          {deciding.length > 0 && <> {Plural(deciding.length, "more is", "more are")} deciding, worth {money(sum(deciding))}.</>}
        </h1>
        <p className="standfirst">
          In the last 30 days we wrote to <b>{plural(month.buyers, "buyer", "buyers")}</b> on your behalf.{" "}
          <b>{num(month.replies)}</b> replied and <b>{num(month.meetings)}</b> agreed to meet.
        </p>
        {notes.length > 0 && (
          <div className="notes">
            {notes.map((n) => (
              <p key={n.id} className={n.severity === "urgent" ? "alarm" : ""}><span>{day(n.created_at)}</span><span>{n.message}</span></p>
            ))}
          </div>
        )}

        <section className="section" id="buyers">
          <div className="sh">
            <h2>The buyers<span className="count">{buyers.length}</span></h2>
            <span className="aside">Every buyer in conversation with you, furthest along first</span>
          </div>
          {buyers.length === 0 ? <p className="empty">Buyers appear here the day they reply.</p> : (
            <div className="scroll">
              <table className="ledger">
                <thead>
                  <tr>
                    <th>Buyer</th>
                    <th style={{ width: "40%" }}><div className="steps">{STAGES.map((s) => <span key={s.key}>{s.name}</span>)}</div></th>
                    <th className="num">Value</th>
                    <th style={{ width: 190 }}>Latest</th>
                  </tr>
                </thead>
                <tbody>
                  {buyers.map((b) => {
                    const at = STAGES.findIndex((s) => s.key === b.stage);
                    const isWon = WON.includes(b.stage);
                    return (
                      <tr key={b.id} className={b.stage === "lost" ? "closed" : ""}>
                        <td>
                          <div className="name">{b.company ?? "Buyer"}</div>
                          <div className="sub">{[BUYER_TYPES[b.buyer_type ?? ""] ?? "Buyer", [b.city, b.state].filter(Boolean).join(", ")].filter(Boolean).join(", ")}</div>
                        </td>
                        <td>
                          <div className={`track ${isWon ? "won" : ""}`} aria-label={stageName(b.stage)}>
                            {STAGES.map((s, i) => <i key={s.key} className={i <= at ? `on ${i === at ? "at" : ""}` : ""} />)}
                          </div>
                          <div className="where">{stageName(b.stage)}</div>
                        </td>
                        <td className={`num ${isWon ? "won" : ""}`} style={{ paddingTop: 20 }}>{b.value_cents ? money(b.value_cents / 100) : <span className="faint">–</span>}</td>
                        <td className="small" style={{ paddingTop: 20 }}>
                          {b.last_kind ? <>{ACTIVITY[b.last_kind] ?? b.last_kind}<div className="muted">{ago(b.last_at)}</div></> : <span className="faint">–</span>}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
          {month.others > 0 && (
            <p className="after">We have also written to {plural(month.others, "other buyer who hasn't", "other buyers who haven't")} replied yet. They join this list the day they do.</p>
          )}
        </section>

        <section className="section">
          <div className="sh">
            <h2>This week&apos;s letter</h2>
            {report && report.total > 1 && <Link className="aside" href={portalHref(scope, "/portal/reports")}>All {report.total} letters</Link>}
          </div>
          {report ? (
            <div className="excerpt">
              <div>
                <div className="title">{report.summary ?? "Your week in brief"}</div>
                <div className="period">{day(report.period_start)} to {day(report.period_end)}</div>
              </div>
              <div className="text">
                {opening(report.body).map((p, i) => <p key={i}>{p}</p>)}
                <div className="acts"><Link className="textbtn" href={portalHref(scope, `/portal/reports/${report.id}`)}>Read the whole letter</Link></div>
              </div>
            </div>
          ) : <p className="empty">Your first letter arrives on Monday.</p>}
        </section>
      </main>
    </>
  );
}

/** The first two real paragraphs of a letter, skipping short lines that act as headings. */
function opening(body: string | null) {
  if (!body) return [];
  return body.split(/\n\s*\n/).map((p) => p.trim()).filter((p) => p.length > 60).slice(0, 2);
}

const WORDS = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"];
/** Numbers that open a sentence read better as words, the way a person would write them. */
const spell = (n: number) => WORDS[n] ?? num(n);
