"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useRef } from "react";

/** A navigation link that marks itself as the current page. */
export default function NavLink({ href, className = "", exact = false, children }: {
  href: string; className?: string; exact?: boolean; children: React.ReactNode;
}) {
  const path = usePathname();
  const base = href.split("?")[0];
  const on = exact || base === "/" || base === "/portal" ? path === base : path.startsWith(base);
  const ref = useRef<HTMLAnchorElement>(null);
  // On a phone the menu is one line you swipe; keep the current page's link in view.
  useEffect(() => { if (on) ref.current?.scrollIntoView({ inline: "nearest", block: "nearest" }); }, [on]);
  return <Link ref={ref} href={href} className={`${className} ${on ? "on" : ""}`} aria-current={on ? "page" : undefined}>{children}</Link>;
}
