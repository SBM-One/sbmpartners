import { redirect } from "next/navigation";
import { getClientUser, getStaff } from "@/lib/auth";
import LoginForm from "./LoginForm";

export const metadata = { title: "Sign in · SBM Partners" };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  if (await getStaff()) redirect("/");
  if (await getClientUser()) redirect("/portal");
  const { error } = await searchParams;
  return (
    <div className="login-wrap">
      <section className="login-art">
        <span className="rings" aria-hidden="true" />
        <span className="wordmark">SBM <em>Partners</em></span>
        <h1>Great products deserve <em>more buyers.</em></h1>
        <p>Your pipeline, your meetings and your weekly report, in one place. Partners and the SBM team sign in here.</p>
      </section>
      <section className="login-form">
        <div className="box">
          <span className="eyebrow">Sign in</span>
          <h2>Welcome back.</h2>
          <p className="muted">Enter your work email and we&apos;ll send you a one-time sign-in link. No password needed.</p>
          {error === "not_allowed" && (
            <p className="notice">That email doesn&apos;t have access yet. Ask your SBM Partners contact to add you.</p>
          )}
          {error === "link" && <p className="notice">That link has expired or was already used. Request a new one.</p>}
          <LoginForm />
        </div>
      </section>
    </div>
  );
}
