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
    return <p className="notice">Check <b>{email}</b> for your sign-in link. You can close this tab.</p>;
  }
  return (
    <form onSubmit={send}>
      <label className="field"><span>Work email</span>
        <input id="email" type="email" required value={email} onChange={(e) => setEmail(e.target.value)} autoFocus placeholder="you@company.com" />
      </label>
      <button className="btn solid" disabled={state === "sending"} style={{ justifySelf: "start", padding: "12px 22px" }}>
        {state === "sending" ? "Sending…" : "Send sign-in link"}
      </button>
      {state === "error" && <p className="notice alarm">{message}</p>}
    </form>
  );
}
