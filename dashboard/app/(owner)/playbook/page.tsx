import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { sentence } from "@/lib/format";
import { setPlaybookStatus } from "../../actions";
import Submit from "@/components/Submit";

type Entry = { id: string; title: string; body: string; channel: string | null; stage: string | null;
  buyer_types: string[]; status: string; evidence: { strength?: string; evidence_strength?: string; sources?: { title: string; url: string }[] } };

const ORDER = ["draft", "active", "retired"] as const;
const TITLES = { draft: "Waiting for you", active: "In use by the Writer", retired: "Retired" };

export default async function Playbook() {
  await requireStaff();
  const entries = await sql<Entry[]>`
    select id, title, body, channel::text, stage::text, coalesce(buyer_types::text[], '{}') as buyer_types,
           status::text, evidence
    from playbook_entries order by created_at, title`;
  const count = (s: string) => entries.filter((e) => e.status === s).length;

  return (
    <>
      <h1 className="statement" style={{ marginTop: 56 }}>The Writer only says what you have approved here.</h1>
      <p className="standfirst">{count("active")} tactics are in use and {count("draft")} are waiting for you. Each one carries the evidence behind it.</p>

      {entries.length === 0 && <p className="empty" style={{ marginTop: 40 }}>No playbook yet. Load the Researcher&apos;s draft first.</p>}

      {ORDER.map((status, n) => {
        const list = entries.filter((e) => e.status === status);
        if (!list.length) return null;
        return (
          <section className={`section ${n === 0 ? "tight" : ""}`} key={status}>
            <div className="sh">
              <h2>{TITLES[status]}<span className="count">{list.length}</span></h2>
              {status === "draft" && (
                <form action={setPlaybookStatus}>
                  <input type="hidden" name="status" value="active" />
                  {list.map((e) => <input type="hidden" name="id" value={e.id} key={e.id} />)}
                  <Submit className="textbtn" confirm={`Approve all ${list.length}? The Writer will start using them.`}>Approve all {list.length}</Submit>
                </form>
              )}
            </div>
            {list.map((e) => {
              const strength = e.evidence?.evidence_strength ?? e.evidence?.strength;
              const sources = e.evidence?.sources ?? [];
              const meta = [
                strength && `${sentence(strength)} evidence`,
                e.channel ? sentence(e.channel) : "Any channel",
                e.stage ? sentence(e.stage) : "Any stage",
                e.buyer_types.length ? e.buyer_types.map(sentence).join(", ") : "All buyers",
              ].filter(Boolean).join(". ");
              return (
                <div className="entry" key={e.id}>
                  <div>
                    <h3>{e.title}</h3>
                    <div className="text">{e.body}</div>
                    <div className="meta">
                      {meta}.
                      {sources.slice(0, 4).map((s, i) => <span key={i}> <a href={s.url} target="_blank" rel="noreferrer noopener">{s.title || "Source"}</a>{i < Math.min(sources.length, 4) - 1 ? "," : ""}</span>)}
                    </div>
                  </div>
                  <form action={setPlaybookStatus} className="acts" style={{ alignContent: "start" }}>
                    <input type="hidden" name="id" value={e.id} />
                    {status !== "active" && <Submit name="status" value="active" className="textbtn">Approve</Submit>}
                    {status !== "retired" && <Submit name="status" value="retired" className="textbtn quiet">Retire</Submit>}
                    {status === "retired" && <Submit name="status" value="draft" className="textbtn quiet">Back to review</Submit>}
                  </form>
                </div>
              );
            })}
          </section>
        );
      })}
    </>
  );
}
