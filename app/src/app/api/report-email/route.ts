import { timingSafeEqual } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { buildSummaryEmail, cleanEmail, cleanSummary } from "@/lib/report-email";

function sameSecret(a: string, b: string) {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

/** What the email service said, shortened for the Settings screen. Never the key. */
async function failure(res: Response): Promise<string> {
  const body = (await res.json().catch(() => null)) as { message?: unknown } | null;
  const said = typeof body?.message === "string" ? body.message : `error ${res.status}`;
  return said.replace(/\s+/g, " ").slice(0, 120);
}

/**
 * Sends the scheduled daily summary by email. Called only by the database (pg_net) with the shared
 * secret, the same way phone alerts are; the database passes the figures and the addresses, so no
 * service key is needed here. Afterwards it tells the database what happened, for the Settings screen.
 */
export async function POST(req: NextRequest) {
  const secret = process.env.PUSH_SECRET;
  if (!secret) return NextResponse.json({ error: "Not set up." }, { status: 503 });
  if (!sameSecret(req.headers.get("x-push-secret") ?? "", secret)) return NextResponse.json({ error: "Not allowed." }, { status: 401 });

  const body = (await req.json().catch(() => null)) as { schedule_id?: unknown; test?: unknown; to?: unknown; summary?: unknown } | null;
  const scheduleId = typeof body?.schedule_id === "string" && /^[0-9a-f-]{36}$/i.test(body.schedule_id) ? body.schedule_id : null;
  const to = [...new Set((Array.isArray(body?.to) ? body.to : []).map(cleanEmail).filter((e): e is string => e !== null))].slice(0, 5);
  const summary = cleanSummary(body?.summary);

  const reportBack = async (ok: boolean, note: string) => {
    if (!scheduleId) return;
    const db = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!, { auth: { persistSession: false } });
    await db.rpc("report_sent", { p_secret: secret, p_schedule: scheduleId, p_ok: ok, p_note: note }).then(
      () => undefined,
      () => undefined,
    );
  };

  if (!summary || to.length === 0) {
    await reportBack(false, "The email could not be made. Nothing was sent.");
    return NextResponse.json({ error: "Nothing to send." }, { status: 400 });
  }
  const key = process.env.RESEND_API_KEY;
  if (!key) {
    await reportBack(false, "Email is not switched on for SNA POS yet, so no email went out.");
    return NextResponse.json({ error: "Email is not set up." }, { status: 503 });
  }

  const from = process.env.REPORT_EMAIL_FROM || "SNA POS <onboarding@resend.dev>";
  const mail = buildSummaryEmail(summary, body?.test === true);
  // One email per person, so nobody sees the other addresses -- but handed over in a single call, because
  // the email service allows only a couple of calls a second and many restaurants send at the same minute.
  const batch = JSON.stringify(to.map((address) => ({ from, to: [address], subject: mail.subject, text: mail.text, html: mail.html })));
  let problem: string | null = null;
  for (let attempt = 1; attempt <= 3; attempt++) {
    const res = await fetch("https://api.resend.com/emails/batch", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: batch,
      signal: AbortSignal.timeout(8_000),
    }).catch(() => null);
    if (res?.ok) {
      problem = null;
      break;
    }
    problem = res ? await failure(res) : "the email service did not answer";
    // Only "too many at once" is worth another try, after a short wait.
    if (res?.status !== 429 || attempt === 3) break;
    await new Promise((r) => setTimeout(r, attempt * 1200));
  }

  const count = `${to.length} ${to.length === 1 ? "address" : "addresses"}`;
  await reportBack(problem === null, problem === null ? `Emailed to ${count}.` : `The email was not sent: ${problem}`);
  return NextResponse.json(problem === null ? { sent: to.length } : { sent: 0, error: "Not sent." }, { status: problem === null ? 200 : 502 });
}
