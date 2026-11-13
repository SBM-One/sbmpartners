import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { sentence } from "@/lib/format";
import { setPlaybookStatus } from "../../actions";
import Submit from "@/components/Submit";

type Entry = { id: string; title: string; body: string; channel: string | null; stage: string | null;
  buyer_types: string[]; status: string; evidence: { strength?: string; evidence_strength?: string; sources?: { title: string; url: string }[] } };

const ORDER = ["draft", "active", "retired"] as const;
const TITLES = { draft: "Waiting for your review", active: "Approved, in use by the Writer", retired: "Retired" };

export default async function Playbook() {
  await requireStaff();
  const entries = await sql<Entry[]>`
    select id, title, body, channel::text, stage::text, coalesce(buyer_types::text[], '{}') as buyer_types,
           status::text, evidence
    from playbook_entries order by created_at, title`;
  const counts = Object.fromEntries(ORDER.map((s) => [s, entries.filter((e) => e.status === s).length]));

  return (
    <>
      <header className="ph rise">
        <div>
          <span className="eyebrow">Playbook</span>
          <h1>What we say, <em className="accent">and why it works.</em></h1>
          <p>The Writer only ever uses approved tactics. Each one carries the evidence behind it.</p>
        </div>
        <div className="aside">
          <span className="pill ok">{counts.active} approved</span>
          <span className="pill blue">{counts.draft} to review</span>
          {counts.retired > 0 && <span className="pill">{counts.retired} retired</span>}
        </div>
      </header>

      {entries.length === 0 && <div className="empty boxed"><b>No playbook yet</b>Load the Researcher&apos;s draft first.</div>}

      {ORDER.map((status) => {
        const list = entries.filter((e) => e.status === status);
        if (!list.length) return null;
        return (
          <section key={status}>
            <div className="section-title">
              <h2>{TITLES[status]} <span className="muted" style={{ fontWeight: 400 }}>{list.length}</span></h2>
              {status === "draft" && (
                <form action={setPlaybookStatus}>
                  <input type="hidden" name="status" value="active" />
                  {list.map((e) => <input type="hidden" name="id" value={e.id} key={e.id} />)}
                  <Submit className="primary dash sm" confirm={`Approve all ${list.length} entries? The Writer will start using them.`}>
                    Approve all {list.length}
                  </Submit>
                </form>
              )}
            </div>
            <div className="card">
              {list.map((e) => {
                const strength = e.evidence?.evidence_strength ?? e.evidence?.strength;
                const sources = e.evidence?.sources ?? [];
                return (
                  <div className="entry" key={e.id}>
                    <div>
                      <h4>{e.title}</h4>
                      <div className="text">{e.body}</div>
                      <div className="meta">
                        {strength && <span className={`pill ${strength === "strong" ? "ok" : strength === "moderate" ? "gold" : ""}`}>{sentence(strength)} evidence</span>}
                        <span className="pill">{e.channel ? sentence(e.channel) : "Any channel"}</span>
                        <span className="pill">{e.stage ? sentence(e.stage) : "Any stage"}</span>
                        <span className="pill">{e.buyer_types.length ? e.buyer_types.map(sentence).join(", ") : "All buyers"}</span>
                        {sources.slice(0, 4).map((s, i) => (
                          <a key={i} className="xs" href={s.url} target="_blank" rel="noreferrer noopener">{s.title || "Source"}</a>
                        ))}
                      </div>
                    </div>
                    <form action={setPlaybookStatus} className="inline">
                      <input type="hidden" name="id" value={e.id} />
                      {status !== "active" && <Submit name="status" value="active" className="sm">Approve</Submit>}
                      {status !== "retired" && <Submit name="status" value="retired" className="sm danger">Retire</Submit>}
                      {status === "retired" && <Submit name="status" value="draft" className="sm quiet">Back to review</Submit>}
                    </form>
                  </div>
                );
              })}
            </div>
          </section>
        );
      })}
    </>
  );
}
