import { redirect } from "next/navigation";
import { getStaff } from "@/lib/auth";
import LoginForm from "./LoginForm";

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  if (await getStaff()) redirect("/");
  const { error } = await searchParams;
  return (
    <div className="login card">
      <h1>SBM Partners</h1>
      <p className="lead">Control room. Enter your work email and we&apos;ll send you a sign-in link.</p>
      {error === "not_staff" && (
        <p className="pill bad">That email isn&apos;t on the staff list. Ask an admin to add you.</p>
      )}
      {error === "link" && <p className="pill bad">That link has expired or was already used. Request a new one.</p>}
      <LoginForm />
    </div>
  );
}
