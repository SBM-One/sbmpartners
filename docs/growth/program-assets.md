# Program assets: templates, checklists and scorecards

These are the working assets for programs B to J. Program A (targeted outbound) is described in
`docs/autopilot-runbook.md`.

- **Facts:** every fact in a template must come from the sales pack (`sales_pack_items`), and only from an item with
  status `client_stated` or `confirmed`. Text in `<angle brackets>` is filled in per buyer.
- **Customer names:** the factory's existing and past customers are never named.
- **Status:** having an asset ready does not mean its program has launched. Each program's status is in
  `client_programs`, and the launches still need Santiago's OK.

---

## B. Reps and distributors

**Screening sheet.** Fill in one `partner_profiles` row per candidate before anyone contacts them.

| Field | What to check | Where the answer comes from |
|---|---|---|
| kind | Rep, agent or distributor | Their website or LinkedIn |
| territory | The states or countries they cover | Their own description |
| lines_carried | The furniture lines they already sell | Their website or catalogue |
| conflicts | Whether they carry a direct competitor, or sell to accounts the factory already serves | Ask the factory. The factory's own customers are never shared with the candidate. |
| references_ok | Whether one or two manufacturers they represent will confirm they work with them | A call |
| status | candidate → screened → approved_to_contact (Santiago) → in_talks → agreement_pending → active | |

**First message** (Spanish; English version alike):

> Buen día, `<nombre>`: le escribo del equipo comercial de Santa Fe Rústicos, fabricante de muebles en Chipilo, Puebla,
> desde 1993. Vi que `<empresa>` representa líneas de mueble en `<territorio>`. Buscamos representantes para nuestra
> línea moderna y contemporánea (comedores, recámaras, consolas, centros de entretenimiento), con marca propia o
> maquila. ¿Le interesaría una llamada de 15 minutos para ver si encaja con lo que ya ofrece?

**Rules**
- Commission, territory and exclusivity are proposed by the factory, never by SBM. That information is still missing; see the inputs list.
- An agreement is signed only by the factory.

## C. Referrals

**When to ask:**
- after a delivered order the buyer is happy with;
- after a good call with a buyer who is not a fit but knows the market.

The factory asks its own customers. SBM only drafts the message.

**Ask, for the factory to send to its own customer:**

> `<nombre>`, gracias por su confianza en Santa Fe Rústicos. Estamos buscando crecer con pocos clientes nuevos que
> trabajen como ustedes. ¿Conoce a alguien en otra cadena o tienda que compre comedores, recámaras o muebles de sala y
> con quien valga la pena hablar? Si nos permite mencionar que usted nos recomendó, lo haremos solo con su permiso.

**Recording it**
- Every introduction gets a `referrals` row.
- `may_name_referrer` is true only when the referrer said yes in writing.
- The first message to the introduced buyer names the referrer only if `may_name_referrer` is true.

## D. Past-opportunity recovery

**What it needs:** the factory's list of samples, quotes and enquiries that did not become orders. The baseline puts
about 100 samples last year, with about 30 sold.

**Steps**
- Each record becomes a `recovery_records` row with `status = 'to_review'`.
- SBM checks the record: the company still exists, still buys these categories, and why the sale stalled (if known).
- Santiago approves the list. Status then becomes `approved_to_contact`.
- Anyone on the do-not-contact or suppression lists, and every existing customer, is excluded automatically.

**Message:** one per account, personal, and never automated in bulk.

> Buen día, `<nombre>`: en `<mes/año>` les enviamos muestras de `<categoría>` de Santa Fe Rústicos y no llegamos a
> concretar. Desde entonces `<algo que cambió y que esté en el sales pack, p. ej. nueva línea contemporánea / tiempos de
> resurtido de 30 días>`. ¿Vale la pena retomar la conversación, o ya no es prioridad para ustedes?

A no closes the record (`closed`). Nothing more is sent to that account.

## E. Inbound wholesale and private label

**Logging:** every enquiry becomes an `inbound_leads` row. The `respond_by` deadline defaults to one business day.

**First answer** (pending review, through the phone app):

> Gracias por escribir a Santa Fe Rústicos. Para darle una respuesta concreta: ¿qué categorías le interesan, qué
> volumen aproximado por modelo, para cuándo, y si sería con su marca (maquila) o la nuestra? Con eso le propongo una
> llamada corta y, si aplica, muestras (se cotizan por selección y salen en unos 30 días).

**Qualifying:**
- Is it a business buyer?
- Do the categories match what the factory makes?
- Can the volume fill a trailer of mixed models? The Mexican minimum is still a conflict, so it is not quoted.
- Is the timing realistic?
- `kind = 'retail_consumer'` means a consumer. The answer is a polite decline that points to retail stores. Program J does not exist yet.

**Waits on:** where enquiries reach the factory today (website form, email, phone). These have to be routed to santiago@sbmpartners.net or logged by hand.

## F. Supplier onboarding

Fill in one `supplier_applications` row per buyer that asks for a vendor setup.

**Checklist.** `docs_missing` lists what is not in hand:
- Constancia de situación fiscal (RFC) / W-9 or W-8BEN-E for US buyers
- Comprobante de domicilio, acta constitutiva, poder del representante
- Bank letter (carta bancaria)
- FSC certificate code and scope: missing; see the inputs list
- Audit reports (which audits, by whom, when): missing
- Product liability insurance (some US retailers require it): unknown
- Barcode (GS1) registration
- CFDI 4.0 invoicing confirmation
- Product specification sheets, packing specs (KD/assembled), photos

**Rule:** SBM prepares the application. It is submitted only with the factory's OK (`status = 'ready_for_client_ok'` first).

## G. Trade events and visits

**Event scorecard.** Fill it in before any spend and store it in `trade_events`.

| Question | Answer |
|---|---|
| Who attends (buyer types, how many target accounts) | |
| Total cost (stand, travel, samples, time) in MXN | |
| Days of the factory's and Santiago's time | |
| Meetings we can book in advance (target) | |
| Cost per expected qualified meeting | cost ÷ meetings target |
| Decision (attend / skip) and who decided | |

**Rules**
- No spend without this scorecard and Santiago's OK.
- After the event, log every contact within 48 hours and fill in `meetings_held`.
- **Factory visit:** a buyer who asks for one is offered a date within 5 business days (the proposed response time, not yet confirmed by the factory).

**Current decision:** Expo Mueble is a skip. The factory said it will not attend.

## H. Offer development

Offer ideas are stored as `offer_hypotheses`. Each idea has a segment, the offer, the evidence (sales-pack facts) and
what is unknown.

**Testing:** an idea is tested through real buyer conversations, as an `experiments` row with a metric and a review date.

**Decision:** any change to products, prices or terms is the factory's decision.

**Ideas loaded (all status `idea`):**
- private label with 30-day reorders
- a nearshore alternative to Asian imports for US retailers
- hospitality furniture from the rustic line
- a mixed-model first trailer

The mixed-model trailer waits on the minimum-order answer.

## I. Existing-account expansion and concentration

**Baseline:**
- 6 active accounts
- the largest is about 60 % of sales and the second about 20 %
- existing accounts could take about 40 % more

These figures are stored in `client_accounts` without names. The `v_concentration` view gives the largest share and the top-two share.

**Ownership:** these accounts are the factory's. The factory's own salesperson leads, and SBM only prepares material.
Their names never appear in outreach.

**Monthly measure:**
- the largest-account share
- revenue from accounts outside the top two
- expansion and reorder `orders`

**Waits on:** account-level categories and room to grow (confidential).

## J. Direct to consumer (business case only)

**Recommendation:** do not start now.

**Why:**
- it competes with the retailers SBM is courting;
- it needs a retail operation (site, returns, last-mile delivery, customer service) that the factory does not have;
- 98 % of sales are export to retailers today.

**What would change this:** a written case with margins, returns, last-mile cost and channel-conflict rules, and a
budget the factory approves. It is stored as an `offer_hypotheses` row with program J.
