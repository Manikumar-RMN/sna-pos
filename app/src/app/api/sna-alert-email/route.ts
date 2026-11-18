import { timingSafeEqual } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { cleanEmail } from "@/lib/report-email";

function sameSecret(a: string, b: string) {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const clean = (v: unknown, max: number) =>
  String(v ?? "")
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    .replace(/\s{2,}/g, " ")
    .trim()
    .slice(0, max);

type Section = { title: string; lines: string[] };

/**
 * Sends the daily SNA staff alert (licences ending, follow-ups due, payments overdue). Called only by the
 * database timer with the shared secret, like the restaurant summary email. The database picks the person and
 * the lines; this only turns them into an email. Client names are cut to a sensible length and escaped.
 */
export async function POST(req: NextRequest) {
  const secret = process.env.PUSH_SECRET;
  if (!secret) return NextResponse.json({ error: "Not set up." }, { status: 503 });
  if (!sameSecret(req.headers.get("x-push-secret") ?? "", secret)) return NextResponse.json({ error: "Not allowed." }, { status: 401 });

  const body = (await req.json().catch(() => null)) as { to?: unknown; name?: unknown; payload?: unknown; console_url?: unknown } | null;
  const to = cleanEmail(body?.to);
  const payload = body?.payload as { sections?: unknown } | undefined;
  const sections: Section[] = (Array.isArray(payload?.sections) ? payload.sections : [])
    .map((s: { title?: unknown; lines?: unknown }) => ({
      title: clean(s?.title, 80),
      lines: (Array.isArray(s?.lines) ? s.lines : []).slice(0, 40).map((l: unknown) => clean(l, 220)).filter(Boolean),
    }))
    .filter((s: Section) => s.title && s.lines.length > 0)
    .slice(0, 6);
  if (!to || sections.length === 0) return NextResponse.json({ error: "Nothing to send." }, { status: 400 });

  const key = process.env.RESEND_API_KEY;
  if (!key) return NextResponse.json({ error: "Email is not set up." }, { status: 503 });

  const link = typeof body?.console_url === "string" && /^https:\/\/[\w.-]+\/sna$/.test(body.console_url) ? body.console_url : null;
  const total = sections.reduce((n, s) => n + s.lines.length, 0);
  const name = clean(body?.name, 60) || "there";
  const subject = `SNA console: ${total} ${total === 1 ? "item needs" : "items need"} attention`;
  const text = [
    `Hello ${name},`,
    "",
    ...sections.flatMap((s) => [`${s.title.toUpperCase()}`, ...s.lines.map((l) => `- ${l}`), ""]),
    link ? `Open the console: ${link}` : "",
  ].join("\n");
  const html = `<div style="font-family:Arial,sans-serif;font-size:14px;color:#201a16;max-width:560px">
<p>Hello ${esc(name)},</p>
${sections.map((s) => `<h3 style="margin:16px 0 4px;font-size:15px">${esc(s.title)}</h3><ul style="margin:0;padding-left:18px">${s.lines.map((l) => `<li>${esc(l)}</li>`).join("")}</ul>`).join("")}
${link ? `<p style="margin-top:18px"><a href="${esc(link)}">Open the SNA console</a></p>` : ""}
</div>`;

  const from = process.env.REPORT_EMAIL_FROM || "SNA POS <onboarding@resend.dev>";
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to: [to], subject, text, html }),
    signal: AbortSignal.timeout(8_000),
  }).catch(() => null);
  if (!res?.ok) return NextResponse.json({ sent: 0, error: "Not sent." }, { status: 502 });
  return NextResponse.json({ sent: 1 });
}
