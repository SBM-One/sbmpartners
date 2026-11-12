"use client";

import { useRouter } from "next/navigation";
import { useEffect } from "react";

/** Reloads the page's numbers every `seconds` while the tab is open, but never while you are typing. */
export default function AutoRefresh({ seconds = 30 }: { seconds?: number }) {
  const router = useRouter();
  useEffect(() => {
    const t = setInterval(() => {
      const typing = document.activeElement?.matches("input, textarea");
      if (!document.hidden && !typing) router.refresh();
    }, seconds * 1000);
    return () => clearInterval(t);
  }, [router, seconds]);
  return null;
}
