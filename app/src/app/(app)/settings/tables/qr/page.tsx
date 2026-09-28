import { headers } from "next/headers";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { NoAccess, SectionHead } from "../../section-head";
import { QrSheet } from "./qr-sheet";

export default async function TableQrCodes() {
  const user = await requireUser();
  if (!can(user, "settings.manage")) return <NoAccess />;
  if (!has(user, "qr_ordering")) return <NoAccess />;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("table_qr_codes");
  const h = await headers();
  const origin = `${h.get("x-forwarded-proto") ?? "https"}://${h.get("host")}`;
  const codes = (data as unknown as { table_id: string; table_number: string; token: string }[] | null) ?? [];
  return (
    <div>
      <SectionHead title="Table QR codes">
        Print this page and put each code on its table. Guests scan it, choose dishes and send the order; your staff accept it on the
        Table orders screen. Pay at the counter or to the steward as usual.
      </SectionHead>
      {error && <p className="card p-4 text-sm" style={{ color: "var(--color-bad)" }}>{error.message}</p>}
      <QrSheet restaurant={user.trading_name} origin={origin} codes={codes} />
    </div>
  );
}
