"use client";

import { useRouter } from "next/navigation";
import { useEffect } from "react";

/**
 * Reloads the page's numbers every `seconds` while the tab is open, but never while you are typing.
 * Also reloads the moment you come back to the tab or the home-screen app, so a phone never shows stale numbers.
 */
export default function AutoRefresh({ seconds = 30 }: { seconds?: number }) {
  const router = useRouter();
  useEffect(() => {
    const t = setInterval(() => {
      const typing = document.activeElement?.matches("input, textarea");
      if (!document.hidden && !typing) router.refresh();
    }, seconds * 1000);
    const back = () => { if (!document.hidden) router.refresh(); };
    document.addEventListener("visibilitychange", back);
    return () => { clearInterval(t); document.removeEventListener("visibilitychange", back); };
  }, [router, seconds]);
  return null;
}
