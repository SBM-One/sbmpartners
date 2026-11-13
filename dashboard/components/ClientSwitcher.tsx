"use client";

import { usePathname, useRouter } from "next/navigation";

/** Staff only: jump to another client's portal preview on the same page. */
export default function ClientSwitcher({ clients, current }: { clients: { id: string; name: string }[]; current: string }) {
  const router = useRouter();
  const path = usePathname();
  const base = path.startsWith("/portal/reports/") ? "/portal/reports" : path;
  return (
    <select aria-label="Preview another client" value={current} onChange={(e) => router.push(`${base}?client=${e.target.value}`)}>
      {clients.map((c) => <option key={c.id} value={c.id} style={{ color: "#0e1a2b" }}>{c.name}</option>)}
    </select>
  );
}
