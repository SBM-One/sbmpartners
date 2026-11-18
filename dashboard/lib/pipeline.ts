// Shared words for the client portal: deal stages and activity, in the client's language.

export const STAGES = [
  { key: "conversation", name: "Talking" },
  { key: "sample", name: "Samples" },
  { key: "quote", name: "Quote" },
  { key: "first_order", name: "First order" },
  { key: "repeat", name: "Reordering" },
] as const;

export const stageName = (key: string) => STAGES.find((s) => s.key === key)?.name ?? (key === "lost" ? "Closed, not now" : key);

export const ACTIVITY: Record<string, string> = {
  sent: "We wrote to them",
  reply: "They replied",
  meeting_booked: "Meeting booked",
  meeting_held: "Met with them",
  sample_sent: "Samples sent",
  quote_sent: "Quote sent",
  order: "Order placed",
  reorder: "Reorder placed",
  call: "We called",
};

export const BUYER_TYPES: Record<string, string> = {
  retailer: "Retailer", design_firm: "Design firm", hospitality: "Hospitality", builder: "Builder",
  distributor: "Distributor", dealer: "Dealer", contract: "Contract", other: "Buyer",
};
