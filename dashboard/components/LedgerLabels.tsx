"use client";

import { usePathname } from "next/navigation";
import { useEffect } from "react";

/**
 * On a phone, ledger tables stack each row and hide the column headings (see globals.css). This copies each
 * heading onto its cells as data-label, so a stacked number still says what it is ("Replies, 30 days 4").
 * Cells that already carry a data-label keep theirs.
 */
export default function LedgerLabels() {
  const path = usePathname();
  useEffect(() => {
    const label = () => document.querySelectorAll<HTMLTableElement>("table.ledger").forEach((table) => {
      // A heading that is itself a graphic (the pipeline's stage names) gives no label.
      const heads = Array.from(table.querySelectorAll("thead th")).map((th) =>
        th.querySelector(".steps") ? "" : th.textContent?.trim() ?? "");
      if (!heads.length) return;
      table.querySelectorAll("tbody tr").forEach((tr) => {
        Array.from(tr.children).forEach((td, i) => {
          if (i > 0 && !td.hasAttribute("data-label")) td.setAttribute("data-label", heads[i] ?? "");
        });
      });
    });
    label();
    // Pages refresh their numbers in place; label any rows that arrive later.
    const watch = new MutationObserver(label);
    const main = document.querySelector("main") ?? document.body;
    watch.observe(main, { childList: true, subtree: true });
    return () => watch.disconnect();
  }, [path]);
  return null;
}
