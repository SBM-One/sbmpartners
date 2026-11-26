import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { sql } from "@/lib/db";
import { ago, day, sentence } from "@/lib/format";
import { logReply, requestBrief, setStrategyDecision } from "../../actions";
import Submit from "@/components/Submit";

type Row = {
  campaign_id: string; client: string; campaign: string; contact_id: string; contact: string; contact_title: string | null;
  company: string | null; buyer_type: string | null; country: string | null; stage: string;
  strategy_id: string | null; fit_score: number | null; decision: string | null; decided_by: string | null;
  decision_reason: string | null; pitch_angle: string | null; channel_plan: string | null;
  channel_sequence: { steps: { day: number; channel: string; purpose: string }[]; why: string } | null;
  lead_with: string[] | null; proof_points: string[] | null; offer: string | null; first_ask: string | null;
  channel_reason: string | null; objections: { objection: string; answer: string }[] | null;
  fit_breakdown: { key: string; score: number; weight: number; why: string }[] | null;
  messages_sent: number; follow_ups_sent: number; follow_ups_left: number; last_sent_at: Date | null;
  next_follow_up_at: Date | null; replies: number; last_reply_at: Date | null; last_reply_channel: string | null;
  last_reply_category: string | null; last_reply_summary: string | null; snoozed_until: Date | null;
  handoff_id: string | null; handoff_status: string | null; meeting_at: Date | null; drafts_waiting: number;
  answers_waiting: number; brief_requested: boolean;
};

// What each stage means, in a sentence.
const STAGE: Record<string, string> = {
  queued: "Waiting to be researched",
  researching: "Being researched",
  qualifying: "The Strategist is scoring the fit",
  drafting: "Pursue: the Writer is drafting the first message",
  nurture: "Held back for now",
  disqualified: "Not a fit",
  waiting_approval: "A draft waits for your approval",
  approved: "Approved, waiting to go out",
  contacted: "Contacted, no reply yet",
  no_reply: "No reply after every follow-up",
  replied: "Replied: needs an answer",
  answer_waiting: "Replied: our answer waits for your approval",
  snoozed: "Said not now: snoozed",
  not_interested: "Said no",
  meeting_ready: "Interested: meeting brief ready for you",
  meeting_booked: "Meeting booked",
  meeting_held: "Meeting held",
  closed: "Closed",
  stopped: "Asked us to stop",
};

const VIEWS: { key: string; name: string; stages: string[] | null }[] = [
  { key: "you", name: "Needs you", stages: ["replied", "answer_waiting", "meeting_ready", "waiting_approval"] },
  { key: "talking", name: "In conversation", stages: ["drafting", "approved", "contacted", "snoozed"] },
  { key: "meetings", name: "Meetings", stages: ["meeting_ready", "meeting_booked", "meeting_held"] },
  { key: "held", name: "Held back", stages: ["nurture", "disqualified"] },
  { key: "early", name: "Being qualified", stages: ["queued", "researching", "qualifying"] },
  { key: "done", name: "Finished", stages: ["no_reply", "not_interested", "closed", "stopped"] },
  { key: "all", name: "All", stages: null },
];

const CRITERIA: Record<string, string> = { product_fit: "Product fit", buyer_type_fit: "Kind of buyer", price_fit: "Price level",
  authority: "Decision maker", timing: "Timing" };
const PLAN: Record<string, string> = { email: "Email", email_and_linkedin: "Email and a LinkedIn note", linkedin: "LinkedIn only",
  whatsapp: "WhatsApp only" };

/** Every buyer in every live campaign: the Strategist's call, where the conversation stands, and what happens next. */
export default async function Buyers({ searchParams }: { searchParams: Promise<{ view?: string }> }) {
  await requireStaff();
  const { view = "you" } = await searchParams;
  const v = VIEWS.find((x) => x.key === view) ?? VIEWS[0];
  const rows = await sql<Row[]>`
    select v.*, ps.lead_with, ps.proof_points, ps.offer, ps.first_ask, ps.channel_reason, ps.objections, ps.fit_breakdown, ps.channel_sequence,
           exists (select 1 from tasks t where t.kind = 'prepare_handoff' and t.contact_id = v.contact_id
                   and t.client_id = v.client_id and t.status in ('queued','running')) as brief_requested
    from v_conversations v
    join campaigns ca on ca.id = v.campaign_id
    left join prospect_strategies ps on ps.id = v.strategy_id
    where ca.status in ('live','paused')
    order by case v.stage when 'meeting_ready' then 0 when 'replied' then 1 when 'answer_waiting' then 2 else 3 end,
             coalesce(v.last_reply_at, v.last_sent_at) desc nulls last, v.fit_score desc nulls last
    limit 500`;
  const count = (stages: string[] | null) => (stages ? rows.filter((r) => stages.includes(r.stage)).length : rows.length);
  const shown = (v.stages ? rows.filter((r) => v.stages!.includes(r.stage)) : rows).slice(0, 100);
  const needYou = count(VIEWS[0].stages);

  return (
    <>
      <h1 className="statement" style={{ marginTop: 56 }}>
        {rows.length === 0 ? "No buyers in a live campaign yet." :
          `${rows.length} buyer${rows.length === 1 ? "" : "s"} in play. ${needYou === 0 ? "None need" : needYou === 1 ? "One needs" : `${needYou} need`} you.`}
      </h1>
      <p className="standfirst">Each buyer is researched, then the Strategist scores the fit and decides: pursue, hold back for now, or not a fit.
        Only pursued buyers get a first message. When someone replies, the Writer drafts the answer for you, and an interested buyer
        becomes a meeting brief. You can overrule any decision here.</p>

      <nav className="inline" style={{ flexWrap: "wrap", gap: 18, marginTop: 28 }} aria-label="Views">
        {VIEWS.map((x) => (
          <Link key={x.key} href={`/buyers?view=${x.key}`} className="textbtn" style={x.key === v.key ? { color: "var(--ink)", textDecoration: "none" } : undefined}>
            {x.name} ({count(x.stages)})
          </Link>
        ))}
      </nav>

      <section className="section tight">
        <div className="sh"><h2>{v.name}<span className="count">{shown.length}</span></h2>
          <span className="aside">Replies and meeting briefs first</span></div>
        {shown.length === 0 && <p className="empty">Nobody here right now.</p>}
        {shown.length > 0 && (
          <div className="scroll">
            <table className="ledger">
              <thead><tr><th>Buyer</th><th>Fit</th><th>Where it stands</th><th className="num">Messages</th></tr></thead>
              <tbody>
                {shown.map((r) => (
                  <tr key={`${r.campaign_id}-${r.contact_id}`} className={["stopped", "not_interested", "disqualified", "closed"].includes(r.stage) ? "closed" : ""}>
                    <td style={{ minWidth: 220 }}>
                      <div className="name">{r.contact || "(no name)"}</div>
                      <div className="sub">{[r.contact_title, r.company].filter(Boolean).join(", ") || "Role unknown"}</div>
                      <div className="sub">For {r.client} · {r.campaign}{r.country ? ` · ${r.country}` : ""}</div>
                    </td>
                    <td style={{ minWidth: 130 }}>
                      {r.fit_score == null ? <span className="faint">Not scored</span> : (
                        <><div><b style={{ fontSize: 20, fontWeight: 500 }}>{r.fit_score}</b> <span className="muted small">of 100</span></div>
                          <div className={`small ${r.decision === "pursue" ? "" : "muted"}`}>{sentence(r.decision)}
                            {r.decided_by && r.decided_by !== "strategist" ? " (you)" : ""}</div></>
                      )}
                    </td>
                    <td style={{ maxWidth: 480 }}>
                      <div className={["replied", "meeting_ready"].includes(r.stage) ? "alarm" : ""}>{STAGE[r.stage] ?? sentence(r.stage)}
                        {r.stage === "snoozed" && r.snoozed_until ? ` until ${day(r.snoozed_until)}` : ""}
                        {r.stage === "meeting_booked" && r.meeting_at ? ` for ${day(r.meeting_at)}` : ""}</div>
                      {r.last_reply_summary && (
                        <div className="small muted" style={{ marginTop: 4 }}>
                          Last reply {ago(r.last_reply_at)}{r.last_reply_channel && r.last_reply_channel !== "email" ? ` on ${r.last_reply_channel}` : ""}
                          {r.last_reply_category ? ` (${sentence(r.last_reply_category).toLowerCase()})` : ""}: {r.last_reply_summary}
                        </div>
                      )}
                      {r.next_follow_up_at && <div className="small muted" style={{ marginTop: 4 }}>Next follow-up due {day(r.next_follow_up_at)}</div>}
                      {r.answers_waiting > 0 && r.stage !== "answer_waiting" && <div className="small" style={{ marginTop: 4 }}><Link className="textbtn" href="/approvals">Our answer waits on the Drafts page</Link></div>}
                      {r.stage === "meeting_ready" && <div className="small" style={{ marginTop: 4 }}><Link className="textbtn" href="/meetings">Read the meeting brief</Link></div>}

                      <details className="research" style={{ marginTop: 10 }}>
                        <summary>Strategy and actions</summary>
                        <div className="body">
                          {r.strategy_id ? (
                            <>
                              {r.decision_reason && <div><h4>Why {r.decision}</h4><p>{r.decision_reason}</p></div>}
                              {r.fit_breakdown && r.fit_breakdown.length > 0 && (
                                <div><h4>Fit</h4><ul style={{ margin: 0, paddingLeft: 18 }}>
                                  {r.fit_breakdown.map((c) => <li key={c.key}>{CRITERIA[c.key] ?? c.key}: {c.score} of 5. <span className="muted">{c.why}</span></li>)}
                                </ul></div>
                              )}
                              {r.pitch_angle && <div><h4>Angle</h4><p>{r.pitch_angle}</p></div>}
                              {(r.lead_with?.length ?? 0) > 0 && <div><h4>Lead with</h4><p>{r.lead_with!.join(", ")}</p></div>}
                              {(r.proof_points?.length ?? 0) > 0 && <div><h4>Proof</h4><p>{r.proof_points!.join("; ")}</p></div>}
                              {r.offer && <div><h4>Offer</h4><p>{r.offer}</p></div>}
                              {r.first_ask && <div><h4>Ask for</h4><p>{r.first_ask}</p></div>}
                              {(r.objections?.length ?? 0) > 0 && (
                                <div><h4>Likely objections</h4><ul style={{ margin: 0, paddingLeft: 18 }}>
                                  {r.objections!.map((o, j) => <li key={j}>{o.objection}: <span className="muted">{o.answer}</span></li>)}</ul></div>
                              )}
                              {r.channel_plan && <div><h4>Channel</h4><p>{PLAN[r.channel_plan] ?? r.channel_plan}. {r.channel_reason}</p></div>}
                              {r.channel_sequence?.steps?.length ? <div><h4>Writer&apos;s plan</h4><p>{r.channel_sequence.steps.map((s) =>
                                `Day ${s.day}: ${s.channel === "whatsapp" ? "WhatsApp" : s.channel === "linkedin" ? "LinkedIn" : "email"} (${s.purpose})`).join(" · ")}</p></div> : null}
                              {r.messages_sent === 0 && (
                                <form action={setStrategyDecision} className="inline" style={{ flexWrap: "wrap", marginTop: 6 }}>
                                  <input type="hidden" name="id" value={r.strategy_id} />
                                  <label className="field"><span>Your reason, if any</span><input name="note" placeholder="Why you are changing it" /></label>
                                  {r.decision !== "pursue" && <Submit name="decision" value="pursue" className="sm solid">Pursue</Submit>}
                                  {r.decision !== "nurture" && <Submit name="decision" value="nurture" className="sm">Hold back</Submit>}
                                  {r.decision !== "disqualify" && <Submit name="decision" value="disqualify" className="textbtn alarm">Not a fit</Submit>}
                                </form>
                              )}
                            </>
                          ) : <p className="muted">Not qualified yet{r.messages_sent > 0 ? " (contacted before the Strategist joined)" : ""}.</p>}

                          {r.messages_sent > 0 && !["stopped"].includes(r.stage) && (
                            <div>
                              <h4>Log a reply that did not come by email</h4>
                              <form action={logReply} style={{ display: "grid", gap: 10, maxWidth: 520 }}>
                                <input type="hidden" name="campaign_id" value={r.campaign_id} />
                                <input type="hidden" name="contact_id" value={r.contact_id} />
                                <div className="inline" style={{ flexWrap: "wrap" }}>
                                  <label className="field"><span>Where</span>
                                    <select name="channel" defaultValue="linkedin"><option value="linkedin">LinkedIn</option><option value="whatsapp">WhatsApp</option><option value="call">Phone call</option>
                                      <option value="other">Other</option></select></label>
                                  <label className="field"><span>What they said</span>
                                    <select name="category" defaultValue="interested">
                                      <option value="interested">Interested</option><option value="question">A question</option>
                                      <option value="not_now">Not now</option><option value="wrong_person">Wrong person</option>
                                      <option value="not_interested">Not interested</option><option value="unsubscribe">Stop contacting me</option>
                                      <option value="other">Something else</option></select></label>
                                </div>
                                <label className="field"><span>In one line</span><input name="summary" placeholder="Wants the price list for spring" /></label>
                                <label className="field"><span>Their words, if you have them</span><textarea name="body" rows={2} /></label>
                                <Submit className="sm">Log reply</Submit>
                              </form>
                              <p className="small muted">The same rules as email replies: follow-ups stop, &ldquo;not now&rdquo; snoozes, &ldquo;stop&rdquo; ends all contact,
                                and an interested buyer gets a meeting brief.</p>
                            </div>
                          )}

                          {!r.handoff_id && !r.brief_requested && r.messages_sent > 0 && !["stopped", "not_interested"].includes(r.stage) && (
                            <form action={requestBrief}>
                              <input type="hidden" name="campaign_id" value={r.campaign_id} />
                              <input type="hidden" name="contact_id" value={r.contact_id} />
                              <Submit className="textbtn">Prepare a meeting brief now</Submit>
                            </form>
                          )}
                          {r.brief_requested && <p className="small muted">The meeting brief is being written.</p>}
                        </div>
                      </details>
                    </td>
                    <td className="num small">
                      {r.messages_sent} sent{r.replies > 0 ? `, ${r.replies} repl${r.replies === 1 ? "y" : "ies"}` : ""}
                      {r.messages_sent > 0 && <div className="muted">{r.follow_ups_sent} follow-up{r.follow_ups_sent === 1 ? "" : "s"} used, {r.follow_ups_left} left</div>}
                      {r.last_sent_at && <div className="muted">Last {ago(r.last_sent_at)}</div>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <p className="after">Follow-ups, answers and check-ins all wait for your approval on the Drafts page, and the database refuses anything to a
          buyer who asked us to stop. Once a buyer is handed to you for a meeting, no automatic message goes to them.</p>
      </section>
    </>
  );
}
