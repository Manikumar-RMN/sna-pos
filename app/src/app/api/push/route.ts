import { timingSafeEqual } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import webpush from "web-push";
import { createClient } from "@supabase/supabase-js";

type Sub = { endpoint: string; keys: { p256dh: string; auth: string } };

function sameSecret(a: string, b: string) {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

/**
 * Sends an owner alert to the phones that turned alerts on. Called only by the database (pg_net) with the
 * shared push secret; the database passes the phone subscriptions, so no service key is needed here.
 */
export async function POST(req: NextRequest) {
  const secret = process.env.PUSH_SECRET;
  const pub = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY;
  const priv = process.env.VAPID_PRIVATE_KEY;
  if (!secret || !pub || !priv) return NextResponse.json({ error: "Push is not set up." }, { status: 503 });
  if (!sameSecret(req.headers.get("x-push-secret") ?? "", secret)) return NextResponse.json({ error: "Not allowed." }, { status: 401 });

  const body = (await req.json().catch(() => null)) as { subscriptions?: Sub[]; title?: string; body?: string; url?: string } | null;
  const subs = (body?.subscriptions ?? []).slice(0, 200);
  webpush.setVapidDetails("https://sna-pos.vercel.app", pub, priv);
  const payload = JSON.stringify({ title: String(body?.title ?? "SNA POS").slice(0, 120), body: String(body?.body ?? "").slice(0, 300), url: body?.url ?? "/owner" });

  const gone: string[] = [];
  await Promise.all(
    subs.map((s) =>
      webpush.sendNotification(s, payload, { TTL: 3600 }).catch((e: { statusCode?: number }) => {
        if (e?.statusCode === 404 || e?.statusCode === 410) gone.push(s.endpoint);
      }),
    ),
  );
  if (gone.length) {
    const db = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!, { auth: { persistSession: false } });
    await db.rpc("push_gone", { p_secret: secret, p_endpoints: gone });
  }
  return NextResponse.json({ sent: subs.length - gone.length, removed: gone.length });
}
