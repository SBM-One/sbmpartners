import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, num } from "@/lib/format";

type Quota = { day: Date; screen_per_day: number; research_per_day: number; drafts_min: number; drafts_max: number;
  screened: number; picked: number; researched: number; passed: number; failed_attempts: number; spot_checked: number;
  skims: number; drafted: number; waiting: number };
type Check = { id: string; company: string | null; attempt: number; passed: boolean; problems: string[]; sources: string[];
  buyer: { name?: string; title?: string; how_searched?: string; not_found_reason?: string } | null; fit_score: number | null;
  channels: Record<string, boolean> | null; spot_result: string | null; spot_notes: { fact: string; url: string; result: string }[] | null;
  created_at: Date };
type Skip = { name: string; city: string | null; state: string | null; activity: string | null; screen_score: number | null;
  skip_reason: string };

const CH: Record<string, string> = { email: "Email", linkedin: "LinkedIn", whatsapp: "WhatsApp" };

function Bar({ label, done, target, of }: { label: string; done: number; target: number; of?: string }) {
  const pct = target ? Math.min(100, Math.round((done / target) * 100)) : 0;
  return (
    <div className="row">
      <span className="lbl">{label}</span>
      <span className="track"><span className={`fill ${done >= target ? "ok" : ""}`} style={{ width: `${pct}%` }} /></span>
      <span className="val">{num(done)} of {of ?? num(target)}</span>
    </div>
  );
}

/** The researcher's daily quota: how many DENUE companies were screened, researched and passed the completeness gate. */
export default async function Research() {
  await requireStaff();
  const [[q], checks, skips] = await Promise.all([
    sql<Quota[]>`select * from v_research_quota where day = (now() at time zone 'America/Mexico_City')::date`,
    sql<Check[]>`
      select r.id, co.name as company, r.attempt, r.passed, r.problems, r.sources, r.buyer, r.fit_score, r.channels,
             r.spot_result, r.spot_notes, r.created_at
      from research_checks r left join companies co on co.id = r.company_id
      where r.quota_day = (now() at time zone 'America/Mexico_City')::date order by r.created_at desc`,
    sql<Skip[]>`
      select name, city, state, activity, screen_score, skip_reason from screen_pool
      where screened_on = (now() at time zone 'America/Mexico_City')::date and not picked
      order by screen_score desc nulls last, name limit 250`,
  ]);
  const [s] = q ? [q] : await sql<Quota[]>`select null as day, *, 0 as screened, 0 as picked, 0 as researched, 0 as passed,
      0 as failed_attempts, 0 as spot_checked, 0 as skims, 0 as drafted,
      (select count(*)::int from screen_pool where screened_on is null) as waiting from research_quota_settings`;
  const n = (v: unknown) => Number(v ?? 0);
  const passed = n(s.passed), target = n(s.research_per_day);
  const reasons = skips.reduce<Record<string, number>>((m, k) => {
    const key = k.skip_reason.startsWith("Scored") ? "Scored below today's cut-off" : k.skip_reason.replace(/\.$/, "");
    m[key] = (m[key] ?? 0) + 1; return m;
  }, {});

  return (
    <>
      <h1 className="statement" style={{ marginTop: 56 }}>
        {n(s.screened) === 0 ? "Today's screening has not run yet." : passed >= target
          ? `Quota met: ${num(passed)} account${passed === 1 ? "" : "s"} researched and checked.`
          : `${num(passed)} of ${num(target)} accounts researched and passed today.`}
      </h1>
      <p className="standfirst">Each day the researcher screens {num(n(s.screen_per_day))} companies from DENUE by fixed rules, researches the
        best {num(target)}, and an account only counts once it passes the completeness gate: {""}
        at least three opened sources, a logged attempt to name the buyer, a fit score with reasons, and which channels are open.
        Failed accounts are researched again. A random sample of passed accounts is checked against its sources.
        {" "}{num(n(s.waiting))} DENUE companies are still waiting to be screened.</p>

      <section className="section tight">
        <div className="sh"><h2>Today</h2><span className="aside">Target, done, passed</span></div>
        <div className="quota">
          <Bar label="Screened" done={n(s.screened)} target={n(s.screen_per_day)} />
          <Bar label="Sent to research" done={n(s.picked)} target={target} />
          <Bar label="Researched" done={n(s.researched)} target={target} />
          <Bar label="Passed the gate" done={passed} target={target} />
          <Bar label="Drafts written" done={n(s.drafted)} target={n(s.drafts_min)} of={`${s.drafts_min}–${s.drafts_max}`} />
        </div>
        <p className="after">{num(n(s.failed_attempts))} attempt{n(s.failed_attempts) === 1 ? " was" : "s were"} sent back as incomplete.
          {" "}Spot check: {num(n(s.spot_checked))} checked, {n(s.skims) ? <span className="alarm">{num(n(s.skims))} skimmed</span> : "no skims"}.</p>
      </section>

      <section className="section">
        <div className="sh"><h2>Researched today<span className="count">{checks.length}</span></h2><span className="aside">Every attempt, newest first</span></div>
        {checks.length === 0 ? <p className="empty">Nothing researched yet today.</p> : (
          <div className="scroll"><table className="ledger"><tbody>
            {checks.map((c) => (
              <tr key={c.id}>
                <td><div className="name" style={{ fontSize: 15.5 }}>{c.company ?? "(company)"}</div>
                  <div className="sub">Attempt {c.attempt}, {ago(c.created_at)}. {c.sources.length} source{c.sources.length === 1 ? "" : "s"}
                    {c.fit_score != null ? `, fit ${c.fit_score}` : ""}.</div>
                  <div className="sub">Buyer: {c.buyer?.name ? `${c.buyer.name}${c.buyer.title ? `, ${c.buyer.title}` : ""}`
                    : c.buyer?.not_found_reason ? `not found (${c.buyer.not_found_reason})` : "no search logged"}</div>
                  {c.channels && <div className="sub">Open channels: {Object.entries(c.channels).filter(([, v]) => v).map(([k]) => CH[k] ?? k).join(", ") || "none"}</div>}
                  {c.problems.length > 0 && <ul className="small alarm" style={{ margin: "6px 0 0", paddingLeft: 18 }}>{c.problems.map((p) => <li key={p}>{p}</li>)}</ul>}
                  {c.spot_result === "skim" && c.spot_notes && <ul className="small alarm" style={{ margin: "6px 0 0", paddingLeft: 18 }}>
                    {c.spot_notes.filter((x) => x.result !== "supported").map((x) => <li key={x.fact}>{x.fact}: {x.result}</li>)}</ul>}</td>
                <td className="num small">{c.passed ? "Passed" : <span className="alarm">Sent back</span>}
                  {c.spot_result && <div className={c.spot_result === "skim" ? "alarm" : "muted"}>Spot check: {c.spot_result === "ok" ? "confirmed" : c.spot_result === "skim" ? "skimmed" : "pages unreadable"}</div>}</td>
              </tr>))}
          </tbody></table></div>
        )}
      </section>

      <section className="section">
        <div className="sh"><h2>Skipped today<span className="count">{skips.length}</span></h2><span className="aside">Highest score first</span></div>
        {skips.length === 0 ? <p className="empty">Nothing skipped yet today.</p> : (<>
          <p className="small muted">{Object.entries(reasons).map(([r, k]) => `${r}: ${k}`).join(" · ")}</p>
          <div className="scroll"><table className="ledger"><tbody>
            {skips.map((k, i) => (
              <tr key={`${k.name}-${i}`}><td><div className="name" style={{ fontSize: 15 }}>{k.name}</div>
                <div className="sub">{[k.activity, [k.city, k.state].filter(Boolean).join(", ")].filter(Boolean).join(" · ")}</div></td>
                <td className="small">{k.skip_reason}</td>
                <td className="num small muted">{k.screen_score ?? "–"}</td></tr>))}
          </tbody></table></div></>)}
      </section>
    </>
  );
}
