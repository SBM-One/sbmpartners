// Shared words for the client portal: deal stages and activity, in the client's language.

export const STAGES = [
  { key: "conversation", name: "In conversation", step: "i" },
  { key: "sample", name: "Samples out", step: "ii" },
  { key: "quote", name: "Quote sent", step: "iii" },
  { key: "first_order", name: "First order", step: "iv" },
  { key: "repeat", name: "Repeat buyer", step: "v" },
] as const;

export const stageName = (key: string) => STAGES.find((s) => s.key === key)?.name ?? (key === "lost" ? "Closed, not now" : key);

export const ACTIVITY: Record<string, { label: string; icon: string; tone?: "gold" | "navy" }> = {
  reply: { label: "Replied", icon: "reply" },
  meeting_booked: { label: "Meeting booked", icon: "calendar", tone: "navy" },
  meeting_held: { label: "Meeting held", icon: "calendar" },
  sample_sent: { label: "Samples sent", icon: "box" },
  quote_sent: { label: "Quote sent", icon: "quote" },
  order: { label: "Order placed", icon: "order", tone: "gold" },
  reorder: { label: "Reorder placed", icon: "order", tone: "gold" },
  call: { label: "Call", icon: "phone" },
};

export const BUYER_TYPES: Record<string, string> = {
  retailer: "Retailer", design_firm: "Design firm", hospitality: "Hospitality", builder: "Builder",
  distributor: "Distributor", dealer: "Dealer", contract: "Contract", other: "Buyer",
};
