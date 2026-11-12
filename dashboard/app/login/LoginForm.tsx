"use client";

import { createBrowserClient } from "@supabase/ssr";
import { useState } from "react";

export default function LoginForm() {
  const [email, setEmail] = useState("");
  const [state, setState] = useState<"idle" | "sending" | "sent" | "error">("idle");
  const [message, setMessage] = useState("");

  async function send(e: React.FormEvent) {
    e.preventDefault();
    setState("sending");
    const supabase = createBrowserClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!);
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: `${window.location.origin}/auth/callback`, shouldCreateUser: true },
    });
    if (error) {
      setState("error");
      setMessage(error.message);
    } else {
      setState("sent");
    }
  }

  if (state === "sent") {
    return <p>Check <b>{email}</b> for a sign-in link. You can close this tab.</p>;
  }
  return (
    <form onSubmit={send}>
      <label htmlFor="email">Work email</label>
      <input id="email" type="email" required value={email} onChange={(e) => setEmail(e.target.value)} autoFocus />
      <div style={{ marginTop: 14 }}>
        <button className="btn primary" disabled={state === "sending"}>
          {state === "sending" ? "Sending…" : "Send sign-in link"}
        </button>
      </div>
      {state === "error" && <p className="pill bad" style={{ marginTop: 12 }}>{message}</p>}
    </form>
  );
}
