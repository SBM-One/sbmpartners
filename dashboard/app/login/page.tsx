import { redirect } from "next/navigation";
import { getClientUser, getStaff } from "@/lib/auth";
import LoginForm from "./LoginForm";

export const metadata = { title: "Sign in · SBM Partners" };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  if (await getStaff()) redirect("/");
  if (await getClientUser()) redirect("/portal");
  const { error } = await searchParams;
  return (
    <div className="signin">
      <header className="mast"><span className="wordmark">SBM<i>Partners</i></span></header>
      <main>
        <h1 className="statement">Where every buyer stands, and what we are doing about it.</h1>
        <div>
          <p className="standfirst" style={{ marginTop: 0, marginBottom: 28, fontSize: 15.5 }}>
            Enter your work email and we will send you a link to sign in. There is no password.
          </p>
          {error === "not_allowed" && <p className="notice alarm" style={{ marginBottom: 20 }}>That email doesn&apos;t have access yet. Ask your SBM Partners contact to add you.</p>}
          {error === "link" && <p className="notice alarm" style={{ marginBottom: 20 }}>That link has expired or was already used. Ask for a new one below.</p>}
          <LoginForm />
        </div>
      </main>
      <footer>For partners of SBM Partners and the SBM team.</footer>
    </div>
  );
}
