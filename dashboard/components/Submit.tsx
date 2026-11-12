"use client";

import { useFormStatus } from "react-dom";

export default function Submit({ children, className = "", name, value, confirm }: {
  children: React.ReactNode; className?: string; name?: string; value?: string; confirm?: string;
}) {
  const { pending } = useFormStatus();
  return (
    <button type="submit" name={name} value={value} disabled={pending} className={`btn ${className}`}
      onClick={(e) => { if (confirm && !window.confirm(confirm)) e.preventDefault(); }}>
      {pending ? "Saving…" : children}
    </button>
  );
}
