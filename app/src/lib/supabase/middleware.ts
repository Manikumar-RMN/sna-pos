import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { CONSOLE_SESSION } from "./console-session";
import type { Database } from "./database.types";

/**
 * Refreshes the auth session on every request and decides where an
 * unauthenticated visitor is sent.
 *
 * Note on the response object: it must be returned as-is, with the cookies
 * Supabase set on it. Building a fresh NextResponse here and returning that
 * instead silently drops the refreshed session and logs people out at random.
 */
export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request });

  const path = request.nextUrl.pathname;
  // The SNA console has its own sign-in, separate from the restaurant app's,
  // so both can be open in one browser. Each side checks only its own.
  const isConsole = path === "/sna" || path.startsWith("/sna/");

  const supabase = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      ...(isConsole ? { cookieOptions: { name: CONSOLE_SESSION } } : {}),
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value),
          );
          supabaseResponse = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  // Do not run any code between createServerClient and getUser(). A stray
  // await here is the usual cause of sessions that seem to expire on their own.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // /t/… = guest QR ordering, /r/… = e-bill link: guests open these without signing in.
  // /sna/login = the SNA console's own sign-in page; the console is not part of the restaurant app.
  const isPublic = path.startsWith("/login") || path === "/sna/login" || path === "/sna/login/forgot" || path.startsWith("/auth") || path.startsWith("/t/") || path.startsWith("/r/") ||
    // Machine calls: the push and email senders (shared secret) and the open API (API key).
    path === "/api/push" || path === "/api/report-email" || path.startsWith("/api/v1/");

  // A redirect must carry any cookies Supabase just refreshed, or the new
  // session is lost and the person is signed out later for no visible reason.
  const redirectTo = (pathname: string) => {
    const url = request.nextUrl.clone();
    url.pathname = pathname;
    url.search = "";
    const res = NextResponse.redirect(url);
    supabaseResponse.cookies.getAll().forEach((c) => res.cookies.set(c));
    return res;
  };

  if (!user && !isPublic) return redirectTo(isConsole ? "/sna/login" : "/login");
  if (user && path.startsWith("/login")) return redirectTo("/dashboard");

  return supabaseResponse;
}
