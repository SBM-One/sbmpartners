import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

// Supabase is used only to log you in (an email link). Data comes from lib/db.ts after the staff check.
export async function supabaseServer() {
  const store = await cookies();
  return createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    cookies: {
      getAll: () => store.getAll(),
      setAll: (list) => {
        try {
          list.forEach(({ name, value, options }) => store.set(name, value, options));
        } catch {
          // Called from a Server Component, where cookies are read-only. The next request refreshes them.
        }
      },
    },
  });
}
