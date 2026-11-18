"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

/** A navigation link that marks itself as the current page. */
export default function NavLink({ href, className = "", exact = false, children }: {
  href: string; className?: string; exact?: boolean; children: React.ReactNode;
}) {
  const path = usePathname();
  const base = href.split("?")[0];
  const on = exact || base === "/" || base === "/portal" ? path === base : path.startsWith(base);
  return <Link href={href} className={`${className} ${on ? "on" : ""}`} aria-current={on ? "page" : undefined}>{children}</Link>;
}
