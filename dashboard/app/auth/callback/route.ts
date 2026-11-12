import { NextResponse, type NextRequest } from "next/server";
import { getStaff } from "@/lib/auth";
import { supabaseServer } from "@/lib/supabase";

// The sign-in email links here. We swap the one-time code for a session, then check the staff list.
export async function GET(req: NextRequest) {
  const url = new URL(req.url);
  const code = url.searchParams.get("code");
  if (!code) return NextResponse.redirect(new URL("/login?error=link", url.origin));
  const supabase = await supabaseServer();
  const { error } = await supabase.auth.exchangeCodeForSession(code);
  if (error) return NextResponse.redirect(new URL("/login?error=link", url.origin));
  if (!(await getStaff())) {
    await supabase.auth.signOut();
    return NextResponse.redirect(new URL("/login?error=not_staff", url.origin));
  }
  return NextResponse.redirect(new URL("/", url.origin));
}
