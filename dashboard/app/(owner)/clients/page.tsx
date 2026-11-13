import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { sentence } from "@/lib/format";
import { updateClient } from "../../actions";
import Submit from "@/components/Submit";

type Client = { id: string; name: string; status: string; plan: string | null; has_brief: boolean; daily_draft_limit: number;
  live: number; targets: number; drafts_today: number; portal_users: number };

/** The settings behind each client: fact sheet, campaigns, pace and portal logins. Results live on the Today page. */
export default async function Clients() {
  await requireStaff();
  const clients = await sql<Client[]>`
    select c.id, c.name, c.status, c.plan, c.brief <> '{}'::jsonb as has_brief, c.daily_draft_limit,
      (select count(*)::int from campaigns ca where ca.client_id = c.id and ca.status = 'live') as live,
      (select count(*)::int from campaign_targets t join campaigns ca on ca.id = t.campaign_id where ca.client_id = c.id) as targets,
      (select count(*)::int from outreach_drafts d where d.client_id = c.id and d.created_at::date = current_date) as drafts_today,
      (select count(*)::int from client_users u where u.client_id = c.id) as portal_users
    from clients c
    order by c.status = 'active' desc, c.name`;
  const missing = clients.filter((c) => !c.has_brief && c.status === "active");

  return (
    <>
      <h1 className="statement" style={{ marginTop: 56 }}>
        {missing.length ? `${missing.map((c) => c.name).join(" and ")} ${missing.length === 1 ? "has" : "have"} no fact sheet, so the Writer can't draft for ${missing.length === 1 ? "it" : "them"}.`
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
                    <td className="small" style={{ paddingTop: 21 }}>{c.has_brief ? "Ready" : <span className="alarm">Missing</span>}</td>
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
        <p className="after">Add a fact sheet with <code>python -m agents.team set-brief</code>. To give someone at a client a login, see the dashboard README.</p>
      </section>
    </>
  );
}
