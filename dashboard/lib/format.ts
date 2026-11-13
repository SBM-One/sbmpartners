export const usd = (n: number | null | undefined) =>
  n == null ? "–" : `$${Number(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/** Whole dollars: $41,200. Millions shorten: $1.2M. */
export const money = (n: number | null | undefined) => {
  if (n == null) return "–";
  if (Math.abs(n) >= 1_000_000) return `$${(n / 1_000_000).toFixed(1).replace(/\.0$/, "")}M`;
  return `$${Math.round(n).toLocaleString("en-US")}`;
};

export const num = (n: number | null | undefined) => (n == null ? "–" : Math.round(n).toLocaleString("en-US"));

export function ago(d: Date | string | null | undefined) {
  if (!d) return "–";
  const s = (Date.now() - new Date(d).getTime()) / 1000;
  if (s < 90) return "just now";
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  const days = Math.round(s / 86400);
  return days === 1 ? "yesterday" : `${days} days ago`;
}

export const label = (s: string | null | undefined) => (s ?? "").replaceAll("_", " ");
export const sentence = (s: string | null | undefined) => {
  const t = label(s);
  return t.charAt(0).toUpperCase() + t.slice(1);
};

export const day = (d: Date | string) => new Date(d).toLocaleDateString("en-US", { month: "short", day: "numeric" });
export const dayLong = (d: Date | string) =>
  new Date(d).toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" });

/** Percent change from `before` to `now`, or null when there is nothing to compare against. */
export const change = (now: number, before: number) => (before > 0 ? Math.round(((now - before) / before) * 100) : null);

export function greeting(name: string) {
  const h = Number(new Date().toLocaleString("en-US", { hour: "numeric", hourCycle: "h23", timeZone: "America/New_York" }));
  return `${h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"}, ${name.split(" ")[0]}`;
}

export const today = () =>
  new Date().toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", timeZone: "America/New_York" });
