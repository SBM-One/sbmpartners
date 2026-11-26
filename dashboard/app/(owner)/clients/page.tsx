import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { sentence } from "@/lib/format";
import { approveBrief, updateClient, updateSender } from "../../actions";
import Submit from "@/components/Submit";

type Client = { id: string; name: string; status: string; plan: string | null; has_brief: boolean; daily_draft_limit: number;
  live: number; targets: number; drafts_today: number; portal_users: number; brief_draft: Record<string, unknown> | null;
  brief_source: string | null; brief_approved_at: Date | null; brief_approved_by: string | null; sender_name: string | null;
  sender_company: string | null; postal_address: string | null };

const SHEET: [string, string, boolean][] = [
  ["brand", "Brand", false], ["what_they_make", "What they make", false], ["collections", "Collections, one per line", true],
  ["price_points", "Prices", false], ["terms", "Terms: minimums, lead times, freight", false],
  ["trade_and_contract", "Trade and contract", false], ["proof", "Proof: stockists, projects, press", false],
  ["offer", "Offer", false], ["best_fit_buyers", "Best-fit buyers", false], ["sources_used", "Sources, one per line", true],
  ["questions_for_client", "Questions still to ask the client, one per line", true],
];
const val = (v: unknown) => (Array.isArray(v) ? v.join("\n") : typeof v === "string" ? v : "");

/** The settings behind each client: fact sheet, campaigns, pace and portal logins. Results live on the Today page. */
export default async function Clients() {
  await requireStaff();
  const clients = await sql<Client[]>`
    select c.id, c.name, c.status, c.plan, (c.brief <> '{}'::jsonb and c.brief_approved_at is not null) as has_brief, c.daily_draft_limit,
      c.brief_draft, c.brief_source, c.brief_approved_at, c.brief_approved_by, c.sender_name, c.sender_company, c.postal_address,
      (select count(*)::int from campaigns ca where ca.client_id = c.id and ca.status = 'live') as live,
      (select count(*)::int from campaign_targets t join campaigns ca on ca.id = t.campaign_id where ca.client_id = c.id) as targets,
      (select count(*)::int from outreach_drafts d where d.client_id = c.id and d.created_at::date = current_date) as drafts_today,
      (select count(*)::int from client_users u where u.client_id = c.id) as portal_users
    from clients c
    order by c.status = 'active' desc, c.name`;
  const missing = clients.filter((c) => !c.has_brief && c.status === "active");
  const drafts = clients.filter((c) => c.brief_draft);
  const noSender = clients.filter((c) => c.status === "active" && (!c.sender_name || !c.postal_address));

  return (
    <>
      <h1 className="statement" style={{ marginTop: 56 }}>
        {drafts.length ? `${drafts.map((c) => c.name).join(" and ")}'s fact sheet ${drafts.length === 1 ? "is" : "are"} drafted and waiting for your approval.`
          : missing.length ? `${missing.map((c) => c.name).join(" and ")} ${missing.length === 1 ? "has" : "have"} no fact sheet, so the Writer can't draft for ${missing.length === 1 ? "it" : "them"}.`
          : "Every client is set up and drafting."}
      </h1>

      <section className="section tight">
        <div className="sh"><h2>Clients<span className="count">{clients.length}</span></h2></div>
        {clients.length === 0 ? <p className="empty">No clients yet. Add one in the Supabase table editor.</p> : (
          <div className="scroll">
            <table className="ledger">
              <thead><tr><th>Client</th><th>Fact sheet</th><th className="num">Live campaigns</th><th className="num">Buyers targeted</th>
                <th className="num">Drafts today</th><th className="num">Daily limit</th><th className="num">Portal logins</th><th /></tr></thead>
              <tbody>
                {clients.map((c) => (
                  <tr key={c.id}>
                    <td><div className="name">{c.name}</div><div className="sub">{sentence(c.status)}{c.plan ? `, ${c.plan} plan` : ""}</div></td>
                    <td className="small" style={{ paddingTop: 21 }}>{c.brief_draft ? <span className="alarm">Waiting for you</span>
                      : c.has_brief ? "Approved" : <span className="alarm">Missing</span>}</td>
                    <td className="num" style={{ paddingTop: 20 }}>{c.live}</td>
                    <td className="num" style={{ paddingTop: 20 }}>{c.targets}</td>
                    <td className="num" style={{ paddingTop: 20 }}>{c.drafts_today}</td>
                    <td className="num" style={{ paddingTop: 16 }}>
                      <form action={updateClient} className="inline">
                        <input type="hidden" name="id" value={c.id} />
                        <input className="line" name="daily_draft_limit" type="number" min="0" max="500" defaultValue={c.daily_draft_limit}
                          aria-label={`Daily draft limit for ${c.name}`} />
                        <Submit className="textbtn quiet">Save</Submit>
                      </form>
                    </td>
                    <td className="num" style={{ paddingTop: 20 }}>{c.portal_users || <span className="faint">None</span>}</td>
                    <td className="num" style={{ paddingTop: 20 }}><Link className="go" href={`/portal?client=${c.id}`}>Their page</Link></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <p className="after">Draft a fact sheet from a client&apos;s catalog with <code>python -m agents.onboard --client &quot;Name&quot; --file catalog.pdf</code>.
          To give someone at a client a login, see the dashboard README.</p>
      </section>

      {drafts.map((c) => (
        <section className="section" key={`brief-${c.id}`} id={`brief-${c.id}`}>
          <div className="sh"><h2>{c.name}: fact sheet to approve</h2><span className="aside">Drafted from {c.brief_source ?? "their material"}</span></div>
          <p className="standfirst" style={{ marginTop: 0 }}>The Writer may state only what is written here. Check every number against the
            client&apos;s own material, delete anything you are not sure of, and ask the client the open questions before approving.</p>
          <form action={approveBrief} className="words" style={{ maxWidth: 820 }}>
            <input type="hidden" name="id" value={c.id} />
            {SHEET.map(([k, label]) => (
              <label className="field" key={k}><span>{label}</span>
                <textarea name={k} defaultValue={val(c.brief_draft?.[k])} rows={k === "brand" ? 1 : 3} /></label>
            ))}
            <div className="acts"><Submit className="solid" confirm={`Approve ${c.name}'s fact sheet? The Writer will start using it.`}>Approve fact sheet</Submit></div>
          </form>
        </section>
      ))}

      <section className="section">
        <div className="sh"><h2>Who the emails come from</h2>
          <span className="aside">{noSender.length ? `${noSender.length} client${noSender.length === 1 ? "" : "s"} missing details` : "Every client set"}</span></div>
        <p className="standfirst" style={{ marginTop: 0 }}>Every email shows the sender&apos;s name and a real postal address. Without them, nothing is sent.</p>
        <div className="scroll"><table className="ledger"><tbody>
          {clients.filter((c) => c.status !== "churned").map((c) => (
            <tr key={`s-${c.id}`}>
              <td><div className="name" style={{ fontSize: 15.5 }}>{c.name}</div></td>
              <td>
                <form action={updateSender} className="inline" style={{ flexWrap: "wrap" }}>
                  <input type="hidden" name="id" value={c.id} />
                  <label className="field"><span>Signed by</span><input name="sender_name" defaultValue={c.sender_name ?? ""} placeholder="Ana Ruiz" /></label>
                  <label className="field"><span>On behalf of</span><input name="sender_company" defaultValue={c.sender_company ?? ""} placeholder="SBM Partners for Alder & Oak" /></label>
                  <label className="field"><span>Postal address</span><input name="postal_address" defaultValue={c.postal_address ?? ""} placeholder="Street, postcode, city, country" style={{ width: 300 }} /></label>
                  <Submit className="textbtn">Save</Submit>
                </form>
              </td>
            </tr>
          ))}
        </tbody></table></div>
      </section>
    </>
  );
}
