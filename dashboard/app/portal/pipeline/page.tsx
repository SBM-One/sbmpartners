import { requirePortal } from "@/lib/auth";
import { portalQuery } from "@/lib/portal";
import { ago, money } from "@/lib/format";
import { BUYER_TYPES, STAGES, stageName } from "@/lib/pipeline";
import PortalHeader from "@/components/PortalHeader";

type Deal = { id: string; company: string | null; buyer_type: string | null; city: string | null; state: string | null;
  stage: string; value_cents: number | null; opened_at: Date; updated_at: Date; last_activity: Date | null };

const ORDER = ["repeat", "first_order", "quote", "sample", "conversation", "lost"];

export default async function PortalPipeline({ searchParams }: { searchParams: Promise<{ client?: string }> }) {
  const scope = await requirePortal((await searchParams).client);
  const deals = await portalQuery(scope, (q) => q<Deal[]>`
    select id, company, buyer_type, city, state, stage, value_cents, opened_at, updated_at, last_activity
    from v_portal_pipeline where client_id = ${scope.clientId}
    order by array_position(${ORDER}::text[], stage), coalesce(last_activity, updated_at) desc`);
  const live = deals.filter((d) => d.stage !== "lost");
  const won = deals.filter((d) => d.stage === "first_order" || d.stage === "repeat").reduce((n, d) => n + (d.value_cents ?? 0) / 100, 0);
  const open = deals.filter((d) => d.stage === "sample" || d.stage === "quote").reduce((n, d) => n + (d.value_cents ?? 0) / 100, 0);

  return (
    <>
      <PortalHeader scope={scope} />
      <main className="pmain">
        <header className="ph rise">
          <div>
            <span className="eyebrow">Pipeline</span>
            <h1>Every buyer, <em className="accent">every step.</em></h1>
            <p>Each buyer we&apos;re talking to for {scope.clientName}, where they stand, and when we last heard from them.</p>
          </div>
          <div className="aside">
            <div className="card stat" style={{ padding: "14px 18px" }}><div className="k">Won so far</div><div className="v" style={{ fontSize: 28 }}>{money(won)}</div></div>
            <div className="card stat" style={{ padding: "14px 18px" }}><div className="k">In samples and quotes</div><div className="v" style={{ fontSize: 28 }}>{money(open)}</div></div>
          </div>
        </header>

        <div className="row" style={{ marginBottom: 14 }}>
          {STAGES.map((s) => {
            const n = live.filter((d) => d.stage === s.key).length;
            return <span key={s.key} className={`pill ${n ? "blue" : ""}`}>{s.name} · {n}</span>;
          })}
        </div>

        {deals.length === 0 ? <div className="empty boxed"><b>No buyers in the pipeline yet</b>They appear here as soon as a buyer replies.</div> : (
          <div className="card table-scroll rise d1">
            <table className="table">
              <thead><tr><th>Buyer</th><th>Type</th><th>Stage</th><th className="num">Value</th><th className="num">In pipeline</th><th className="num">Last activity</th></tr></thead>
              <tbody>
                {deals.map((d) => (
                  <tr key={d.id} style={d.stage === "lost" ? { opacity: 0.55 } : undefined}>
                    <td><div className="title">{d.company ?? "Buyer"}</div><div className="sub">{[d.city, d.state].filter(Boolean).join(", ")}</div></td>
                    <td className="small">{BUYER_TYPES[d.buyer_type ?? ""] ?? "Buyer"}</td>
                    <td><span className={`pill ${d.stage === "repeat" || d.stage === "first_order" ? "gold" : d.stage === "lost" ? "" : "blue"}`}>{stageName(d.stage)}</span></td>
                    <td className="num">{d.value_cents ? money(d.value_cents / 100) : <span className="faint">–</span>}</td>
                    <td className="num small muted">{ago(d.opened_at).replace(" ago", "")}</td>
                    <td className="num small muted">{ago(d.last_activity ?? d.updated_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </main>
    </>
  );
}
