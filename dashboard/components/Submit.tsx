"use client";

import { useFormStatus } from "react-dom";

export default function Submit({ children, className = "", name, value, confirm, title, disabled = false }: {
  children: React.ReactNode; className?: string; name?: string; value?: string; confirm?: string; title?: string;
  disabled?: boolean;
}) {
  const { pending } = useFormStatus();
  return (
    <button type="submit" name={name} value={value} disabled={pending || disabled} className={className.includes("textbtn") ? className : `btn ${className}`} title={title}
      onClick={(e) => { if (confirm && !window.confirm(confirm)) e.preventDefault(); }}>
      {pending ? "Saving…" : children}
    </button>
  );
}
