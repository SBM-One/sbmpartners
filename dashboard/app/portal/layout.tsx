import type { Metadata } from "next";

export const metadata: Metadata = { title: "SBM Partners · Client portal" };

// Each portal page draws its own header (it needs to know which client it is showing).
export default function PortalLayout({ children }: { children: React.ReactNode }) {
  return <div className="portal">{children}</div>;
}
