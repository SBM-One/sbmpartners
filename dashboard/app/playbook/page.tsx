import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { label } from "@/lib/format";
import { setPlaybookStatus } from "../actions";
import Submit from "@/components/Submit";

type Entry = { id: string; title: string; body: string; channel: string | null; stage: string | null;
  buyer_types: string[]; status: string; evidence: { strength?: string; evidence_strength?: string; sources?: { title: string; url: string }[] } };

const ORDER = ["draft", "active", "retired"] as const;
const TITLES = { draft: "Waiting for your review", active: "Approved (the Writer uses these)", retired: "Retired" };

export default async function Playbook() {
  await requireStaff();
  const entries = await sql<Entry[]>`
    select id, title, body, channel::text, stage::text, coalesce(buyer_types::text[], '{}') as buyer_types,
           status::text, evidence
    from playbook_entries order by created_at, title`;
  const counts = Object.fromEntries(ORDER.map((s) => [s, entries.filter((e) => e.status === s).length]));

  return (
    <>
      <h1>Playbook</h1>
      <p className="lead">{counts.active} approved · {counts.draft} waiting for review · {counts.retired} retired.
        The Writer only ever uses approved entries.</p>

      {entries.length === 0 && <div className="empty">No playbook entries yet. Load the Researcher&apos;s draft first.</div>}

      {ORDER.map((status) => {
        const list = entries.filter((e) => e.status === status);
        if (!list.length) return null;
        return (
          <section key={status}>
            <h2>{TITLES[status]} ({list.length})</h2>
            {status === "draft" && (
              <form action={setPlaybookStatus} style={{ marginBottom: 12 }}>
                <input type="hidden" name="status" value="active" />
                {list.map((e) => <input type="hidden" name="id" value={e.id} key={e.id} />)}
                <Submit className="primary" confirm={`Approve all ${list.length} entries? The Writer will start using them.`}>
                  Approve all {list.length}
                </Submit>
              </form>
            )}
            <table>
              <thead><tr><th style={{ width: "60%" }}>Tactic</th><th>Applies to</th><th>Evidence</th><th></th></tr></thead>
              <tbody>
                {list.map((e) => {
                  const strength = e.evidence?.evidence_strength ?? e.evidence?.strength;
                  const sources = e.evidence?.sources ?? [];
                  return (
                    <tr key={e.id}>
                      <td><b>{e.title}</b><div className="small" style={{ whiteSpace: "pre-line" }}>{e.body}</div>
                        {sources.length > 0 && (
                          <div className="small muted">Sources: {sources.slice(0, 4).map((s, i) => (
                            <span key={i}>{i > 0 && ", "}<a href={s.url} target="_blank" rel="noreferrer noopener">{s.title || "link"}</a></span>
                          ))}</div>
                        )}
                      </td>
                      <td className="small">{[e.channel ?? "any channel", e.stage ? label(e.stage) : "any stage",
                        e.buyer_types.length ? e.buyer_types.map(label).join(", ") : "all buyers"].join(" · ")}</td>
                      <td>{strength && <span className={`pill ${strength === "strong" ? "ok" : strength === "moderate" ? "warning" : ""}`}>{strength}</span>}</td>
                      <td>
                        <form action={setPlaybookStatus} className="inline">
                          <input type="hidden" name="id" value={e.id} />
                          {status !== "active" && <Submit name="status" value="active">Approve</Submit>}
                          {status !== "retired" && <Submit name="status" value="retired" className="danger">Retire</Submit>}
                          {status === "retired" && <Submit name="status" value="draft">Back to review</Submit>}
                        </form>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </section>
        );
      })}
    </>
  );
}
