import { NextResponse, type NextRequest } from "next/server";
import type { EmailOtpType } from "@supabase/supabase-js";
import { createClient, createConsoleClient } from "@/lib/supabase/server";
import { CONSOLE_COOKIE } from "@/app/sna/console-cookie";

/**
 * Landing page for links in Supabase emails (password reset). Handles both link
 * styles: `?code=` (opened on the same device that asked) and
 * `?token_hash=&type=` (works on any device, if the email template uses it).
 */
export async function GET(request: NextRequest) {
  const url = request.nextUrl;
  const next = url.searchParams.get("next");
  const safeNext = next && next.startsWith("/") && !next.startsWith("//") ? next : "/dashboard";

  // A reset link asked for from the SNA console signs in to the console only.
  // It never touches a restaurant sign-in in the same browser.
  if (safeNext === "/sna" || safeNext.startsWith("/sna/")) return consoleLink(request, safeNext);

  const supabase = await createClient();

  // Never let an email link replace a counter tablet's own sign-in.
  const { data: state } = await supabase.rpc("my_account_state");
  if (state === "device_locked" || state === "device_removed" || (state === "active" && (await supabase.from("v_current_user").select("device_name").maybeSingle()).data?.device_name)) {
    const back = url.clone();
    back.search = "";
    back.pathname = "/login";
    return NextResponse.redirect(back);
  }

  const code = url.searchParams.get("code");
  const tokenHash = url.searchParams.get("token_hash");
  const type = url.searchParams.get("type") as EmailOtpType | null;

  let ok = false;
  if (code) {
    ok = !(await supabase.auth.exchangeCodeForSession(code)).error;
  } else if (tokenHash && type) {
    ok = !(await supabase.auth.verifyOtp({ token_hash: tokenHash, type })).error;
  }

  const dest = url.clone();
  dest.search = "";
  if (ok) {
    const [path, query] = safeNext.split("?");
    dest.pathname = path;
    if (query) dest.search = "?" + query;
  } else {
    dest.pathname = "/login";
    dest.searchParams.set("link", "expired");
  }
  return NextResponse.redirect(dest);
}

/** The same link, for the SNA console: it uses the console's own sign-in. */
async function consoleLink(request: NextRequest, next: string) {
  const url = request.nextUrl;
  const supabase = await createConsoleClient();
  const code = url.searchParams.get("code");
  const tokenHash = url.searchParams.get("token_hash");
  const type = url.searchParams.get("type") as EmailOtpType | null;

  let userId: string | null = null;
  if (code) {
    const { data, error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) userId = data.user?.id ?? null;
  } else if (tokenHash && type) {
    const { data, error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type });
    if (!error) userId = data.user?.id ?? null;
  }

  const dest = url.clone();
  dest.search = "";
  dest.pathname = "/sna/login";
  if (!userId) return NextResponse.redirect(dest);

  // Only SNA staff may hold a console sign-in.
  if (!(await supabase.rpc("sna_me")).data) {
    await supabase.auth.signOut({ scope: "local" });
    return NextResponse.redirect(dest);
  }

  const [path, query] = next.split("?");
  dest.pathname = path;
  if (query) dest.search = "?" + query;
  const res = NextResponse.redirect(dest);
  // The same mark the console's sign-in page sets: 12 hours, console pages only.
  res.cookies.set(CONSOLE_COOKIE, userId, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/sna",
    maxAge: 60 * 60 * 12,
  });
  return res;
}
