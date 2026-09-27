import { NextResponse, type NextRequest } from "next/server";
import type { EmailOtpType } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/server";

/**
 * Landing page for links in Supabase emails (password reset). Handles both link
 * styles: `?code=` (opened on the same device that asked) and
 * `?token_hash=&type=` (works on any device, if the email template uses it).
 */
export async function GET(request: NextRequest) {
  const url = request.nextUrl;
  const next = url.searchParams.get("next");
  const safeNext = next && next.startsWith("/") && !next.startsWith("//") ? next : "/dashboard";
  const supabase = await createClient();

  // Never let an email link replace a counter tablet's own sign-in.
  const { data: state } = await supabase.rpc("my_account_state");
  if (state === "device_locked" || state === "device_removed" || (state === "active" && (await supabase.from("v_current_user").select("device_name").maybeSingle()).data?.device_name)) {
    const back = url.clone();
    back.search = "";
    back.pathname = "/counter";
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
