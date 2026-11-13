// A small line-icon set (1.6px strokes, 24px grid) so the app doesn't pull in an icon library.
const PATHS: Record<string, string> = {
  overview: "M3 12.5 12 4l9 8.5M5.5 10.5V20h13v-9.5M10 20v-5h4v5",
  approvals: "M4 6.5h11M4 11.5h8M4 16.5h6M14.5 16l2.5 2.5L21.5 14",
  reports: "M7 3.5h7l4.5 4.5V20a.5.5 0 0 1-.5.5H7a.5.5 0 0 1-.5-.5V4a.5.5 0 0 1 .5-.5ZM14 3.5V8h4.5M9.5 12.5h6M9.5 16h4",
  playbook: "M5 4.5h10.5a2 2 0 0 1 2 2v13H7a2 2 0 0 1-2-2v-13ZM5 17.5a2 2 0 0 1 2-2h10.5M9 8.5h5",
  clients: "M8.5 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7ZM2.5 20c.6-3.3 3-5.5 6-5.5s5.4 2.2 6 5.5M16 4.5a3.5 3.5 0 0 1 0 6.5M18 14.8c1.9.7 3.2 2.6 3.5 5.2",
  portal: "M3.5 12s3.2-6.5 8.5-6.5 8.5 6.5 8.5 6.5-3.2 6.5-8.5 6.5S3.5 12 3.5 12ZM12 14.8a2.8 2.8 0 1 0 0-5.6 2.8 2.8 0 0 0 0 5.6Z",
  signout: "M14.5 4.5h4a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-4M10 16l4-4-4-4M14 12H4",
  pipeline: "M4 5h16M6.5 12h11M9.5 19h5",
  mail: "M3.5 6.5h17v11h-17zM3.5 7l8.5 6.5L20.5 7",
  reply: "M9.5 7.5 4.5 12l5 4.5M5 12h9.5a5 5 0 0 1 5 5v1",
  calendar: "M4.5 6h15v14h-15zM4.5 10h15M8.5 3.5V7M15.5 3.5V7",
  box: "M12 3.5 20 7.5v9L12 20.5 4 16.5v-9L12 3.5ZM4 7.5l8 4 8-4M12 11.5v9",
  quote: "M6 3.5h9l3.5 3.5v13.5H6zM9 10h6M9 13.5h6M9 17h3.5",
  order: "M4 5h2.5l2 10.5h9.5L20 8H7.2M10 19.5h.01M17 19.5h.01",
  phone: "M5.5 4h3l1.5 4-2 1.5a10 10 0 0 0 6.5 6.5l1.5-2 4 1.5v3a1.5 1.5 0 0 1-1.6 1.5A16.5 16.5 0 0 1 4 5.6 1.5 1.5 0 0 1 5.5 4Z",
  spark: "M12 3.5v5M12 15.5v5M3.5 12h5M15.5 12h5M6.3 6.3l2.4 2.4M15.3 15.3l2.4 2.4M6.3 17.7l2.4-2.4M15.3 8.7l2.4-2.4",
  arrow: "M5 12h14M13 6l6 6-6 6",
  back: "M19 12H5M11 6l-6 6 6 6",
  bell: "M6.5 16.5V11a5.5 5.5 0 0 1 11 0v5.5l1.5 2h-14l1.5-2ZM10 20.5h4",
  check: "M5 12.5 10 17l9-10",
  pause: "M8.5 5.5v13M15.5 5.5v13",
  play: "M7.5 5.5v13l11-6.5-11-6.5Z",
  link: "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
};

export default function Icon({ name, size }: { name: keyof typeof PATHS | string; size?: number }) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" strokeWidth={1.6}
      strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={PATHS[name] ?? PATHS.spark} />
    </svg>
  );
}
