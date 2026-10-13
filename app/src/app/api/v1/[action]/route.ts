import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@supabase/supabase-js";

const ACTIONS = new Set(["menu", "orders", "sales", "stock"]);

/**
 * SNA POS Open API v1 (read-only).
 *   GET /api/v1/menu
 *   GET /api/v1/orders?from=2026-09-01&to=2026-09-28
 *   GET /api/v1/sales?from=…&to=…
 *   GET /api/v1/stock
 * Send the key as "Authorization: Bearer snapi_…". At most 60 calls a minute per key; at most 31 days per call.
 */
export async function GET(req: NextRequest, { params }: { params: Promise<{ action: string }> }) {
  const { action } = await params;
  if (!ACTIONS.has(action)) return NextResponse.json({ error: "Unknown endpoint. Use menu, orders, sales or stock." }, { status: 404 });
  const auth = req.headers.get("authorization") ?? "";
  const key = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : (req.headers.get("x-api-key") ?? "").trim();
  if (!key) return NextResponse.json({ error: "Send your API key as: Authorization: Bearer snapi_…" }, { status: 401 });

  const q = req.nextUrl.searchParams;
  const p: Record<string, string> = {};
  for (const k of ["from", "to"]) {
    const v = q.get(k);
    if (v) p[k] = v;
  }
  const db = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!, { auth: { persistSession: false } });
  const { data, error } = await db.rpc("api_v1", { p_key: key, p_action: action, p_params: p });
  if (error) {
    const m = error.message;
    const status = /Invalid API key/.test(m) ? 401 : /Too many requests/.test(m) ? 429 : /not switched on/.test(m) ? 403 : 400;
    return NextResponse.json({ error: m }, { status, headers: status === 429 ? { "Retry-After": "60" } : undefined });
  }
  return NextResponse.json(data, { headers: { "Cache-Control": "no-store" } });
}

/**
 * POST /api/v1/online-orders — an online-ordering partner (Swiggy, Zomato, website) sends a new order.
 * The order waits on the Online orders screen until the restaurant accepts it. The same order_id sent again is taken once.
 */
export async function POST(req: NextRequest, { params }: { params: Promise<{ action: string }> }) {
  const { action } = await params;
  if (action !== "online-orders") return NextResponse.json({ error: "Unknown endpoint. POST is only for online-orders." }, { status: 404 });
  const auth = req.headers.get("authorization") ?? "";
  const key = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : (req.headers.get("x-api-key") ?? "").trim();
  if (!key) return NextResponse.json({ error: "Send your API key as: Authorization: Bearer snapi_…" }, { status: 401 });
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Send the order as JSON." }, { status: 400 });
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) return NextResponse.json({ error: "Send the order as a JSON object." }, { status: 400 });
  const db = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!, { auth: { persistSession: false } });
  const { data, error } = await db.rpc("online_order_receive", { p_key: key, p: body as never });
  if (error) {
    const m = error.message;
    const status = /Invalid API key/.test(m) ? 401 : /Too many requests/.test(m) ? 429 : /not switched on/.test(m) ? 403 : 400;
    return NextResponse.json({ error: m }, { status, headers: status === 429 ? { "Retry-After": "60" } : undefined });
  }
  const d = data as { repeat?: boolean };
  return NextResponse.json(data, { status: d?.repeat ? 200 : 201, headers: { "Cache-Control": "no-store" } });
}
