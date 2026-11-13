// Small hand-drawn SVG charts. One series each, so no legend: the card title names what is shown.
// Bars sit on a shared baseline with rounded tops; the current period is gold, the rest Aegean blue.
// Hovering a bar shows its value (and the native tooltip gives the full label for screen readers).

export type Point = { label: string; value: number; title?: string };

export function BarChart({ data, height = 180, format = (v: number) => String(v), highlightLast = true, showLast = true }: {
  data: Point[]; height?: number; format?: (v: number) => string; highlightLast?: boolean; showLast?: boolean;
}) {
  const w = 640;
  const top = 22;
  const bottom = 26;
  const plot = height - top - bottom;
  const max = Math.max(1, ...data.map((d) => d.value));
  const nice = niceMax(max);
  const step = w / Math.max(1, data.length);
  const barW = Math.min(44, step * 0.56);
  const ticks = [0, nice / 2, nice];
  return (
    <svg className="chart" viewBox={`0 0 ${w} ${height}`} role="img"
      aria-label={data.map((d) => `${d.title ?? d.label}: ${format(d.value)}`).join("; ")}>
      {ticks.map((t) => {
        const y = top + plot - (t / nice) * plot;
        return <line key={t} className="grid-line" x1={0} x2={w} y1={y} y2={y} />;
      })}
      {data.map((d, i) => {
        const h = d.value > 0 ? Math.max(4, (d.value / nice) * plot) : 0;
        const x = i * step + (step - barW) / 2;
        const y = top + plot - h;
        const last = i === data.length - 1;
        const r = Math.min(5, barW / 2, h);
        return (
          <g key={i} className="col">
            <title>{`${d.title ?? d.label}: ${format(d.value)}`}</title>
            <rect className="bar-hit" x={i * step} y={0} width={step} height={height} />
            {h > 0 && (
              <path className={`bar ${highlightLast && last ? "now" : ""}`}
                d={`M${x},${y + h} V${y + r} Q${x},${y} ${x + r},${y} H${x + barW - r} Q${x + barW},${y} ${x + barW},${y + r} V${y + h} Z`} />
            )}
            <text className={`val ${showLast && last ? "show" : ""}`} x={x + barW / 2} y={y - 7} textAnchor="middle">{format(d.value)}</text>
            <text className="axis" x={x + barW / 2} y={height - 6} textAnchor="middle">{d.label}</text>
          </g>
        );
      })}
    </svg>
  );
}

function niceMax(v: number) {
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= v) return m * p;
  return 10 * p;
}

/** A tiny trend line for stat tiles. */
export function Sparkline({ values, width = 112, height = 34 }: { values: number[]; width?: number; height?: number }) {
  if (values.length < 2) return null;
  const max = Math.max(...values, 1);
  const min = Math.min(...values, 0);
  const span = max - min || 1;
  const pts = values.map((v, i) => [(i / (values.length - 1)) * (width - 4) + 2, height - 3 - ((v - min) / span) * (height - 8)]);
  const line = pts.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  const [lx, ly] = pts[pts.length - 1];
  return (
    <svg className="spark" width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden="true">
      <defs>
        <linearGradient id="spark-fill" x1="0" x2="0" y1="0" y2="1">
          <stop offset="0%" stopColor="#1e6fd9" stopOpacity="0.16" />
          <stop offset="100%" stopColor="#1e6fd9" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path className="area" d={`${line} L${lx},${height} L2,${height} Z`} />
      <path className="line" d={line} />
      <circle cx={lx} cy={ly} r={3} />
    </svg>
  );
}

/** The Grader's score as a ring: green from 80, amber from 65, red below. */
export function ScoreRing({ score }: { score: number | null }) {
  const r = 24;
  const c = 2 * Math.PI * r;
  const s = score ?? 0;
  const color = score == null ? "#8b94a5" : s >= 80 ? "#17694a" : s >= 65 ? "#c98612" : "#b3261e";
  return (
    <svg className="ring" viewBox="0 0 58 58" aria-label={`Grader score ${score ?? "not graded"} out of 100`}>
      <circle className="track" cx={29} cy={29} r={r} />
      <circle className="val" cx={29} cy={29} r={r} stroke={color} strokeDasharray={`${(s / 100) * c} ${c}`} />
      <text x={29} y={35} textAnchor="middle">{score ?? "–"}</text>
    </svg>
  );
}

export function Delta({ pct, invert = false }: { pct: number | null; invert?: boolean }) {
  if (pct == null) return <span className="delta flat">new</span>;
  const good = invert ? pct < 0 : pct > 0;
  const cls = pct === 0 ? "flat" : good ? "up" : "down";
  return <span className={`delta ${cls}`}>{pct > 0 ? "▲" : pct < 0 ? "▼" : "•"} {Math.abs(pct)}%</span>;
}
