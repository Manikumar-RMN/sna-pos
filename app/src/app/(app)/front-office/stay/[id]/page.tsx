import Link from "next/link";
import { notFound } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../../../upgrade-note";
import type { Company, Folio, FixOptions, InvoiceState } from "@/lib/fo";
import { FolioView } from "./folio";

export default async function StayPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const user = await requireUser();
  if (!has(user, "front_office")) {
    return (
      <div className="mx-auto max-w-md">
        <UpgradeNote feature="Front office and housekeeping" />
      </div>
    );
  }
  if (!(can(user, "fo.view") || can(user, "fo.manage"))) {
    return <div className="card mx-auto max-w-md p-5 text-sm">Your role does not include guest folios.</div>;
  }
  const supabase = await createClient();
  const [{ data }, methods] = await Promise.all([
    supabase.rpc("fo_folio", { p_stay: id }),
    supabase.from("payment_methods").select("id, name").eq("is_active", true).not("kind", "in", "(gift_card,loyalty,advance,account,room)").order("display_order"),
  ]);
  const folio = data as unknown as Folio | null;
  if (!folio) notFound();
  const { data: grp } = await supabase.rpc("fo_stay_group", { p_stay: id });
  const group = (grp as unknown as { group_id: string; group_no: number; name: string } | null) ?? null;
  const invoices: { guest: InvoiceState | null; company: InvoiceState | null } = { guest: null, company: null };
  if (folio.stay.status === "checked_out") {
    const [g, c] = await Promise.all([
      supabase.rpc("fo_invoice_for_stay", { p_stay: id, p_party: "guest" }),
      folio.stay.company ? supabase.rpc("fo_invoice_for_stay", { p_stay: id, p_party: "company" }) : Promise.resolve({ data: null }),
    ]);
    invoices.guest = (g.data as unknown as InvoiceState | null) ?? null;
    invoices.company = (c.data as unknown as InvoiceState | null) ?? null;
  }
  let fix: FixOptions | null = null;
  if (folio.stay.status === "checked_out" && can(user, "fo.manage")) {
    const { data: fx } = await supabase.rpc("fo_fix_options", { p_stay: id });
    fix = (fx as unknown as FixOptions | null) ?? null;
  }
  let companies: Company[] = [];
  if ((folio.stay.status === "reserved" || folio.stay.status === "inhouse") && can(user, "fo.manage")) {
    const { data: co } = await supabase.rpc("fo_companies_list", { p_include_inactive: false });
    companies = (co ?? []) as unknown as Company[];
  }
  return (
    <div className="mx-auto max-w-3xl">
      <Link href="/front-office" className="text-sm underline">← Front office</Link>
      <FolioView folio={folio} methods={(methods.data ?? []) as { id: string; name: string }[]} currency={user.currency_code} canManage={can(user, "fo.manage")} invoices={invoices} fix={fix} group={group} companies={companies} />
    </div>
  );
}
