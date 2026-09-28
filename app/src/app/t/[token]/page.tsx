import type { Metadata } from "next";
import { createClient } from "@/lib/supabase/server";
import { GuestOrder, type GuestMenu } from "./guest-order";

export const metadata: Metadata = { title: "Order from your table", robots: { index: false } };
export const dynamic = "force-dynamic";

export default async function TableQrPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("qr_menu", { p_token: token });
  if (error || !data) {
    return (
      <main className="grid min-h-screen place-items-center p-6 text-center">
        <div className="card max-w-sm p-6">
          <h1 className="text-lg font-bold">This QR code is not active</h1>
          <p className="mt-2 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Please ask the staff to take your order.
          </p>
        </div>
      </main>
    );
  }
  return <GuestOrder token={token} menu={data as unknown as GuestMenu} />;
}
