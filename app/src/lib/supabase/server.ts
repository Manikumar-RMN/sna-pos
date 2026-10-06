import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { CONSOLE_SESSION } from "./console-session";
import type { Database } from "./database.types";

/**
 * Supabase client for Server Components, Server Actions and Route Handlers.
 *
 * `cookies()` is async in Next.js 15, hence the await. Every query made through
 * this client carries the signed-in user's session, so Row Level Security
 * applies to it exactly as it applies to that person.
 */
export async function createClient() {
  return build();
}

/**
 * The same, for the SNA console: it reads and writes the console's own sign-in,
 * never the restaurant app's. Everything under /sna uses this one.
 */
export async function createConsoleClient() {
  return build(CONSOLE_SESSION);
}

async function build(sessionName?: string) {
  const cookieStore = await cookies();

  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      ...(sessionName ? { cookieOptions: { name: sessionName } } : {}),
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options),
            );
          } catch {
            // Called from a Server Component, which cannot set cookies.
            // The middleware refreshes the session instead, so this is safe
            // to ignore.
          }
        },
      },
    },
  );
}
