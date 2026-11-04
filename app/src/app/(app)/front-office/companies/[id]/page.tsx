import Link from "next/link";
import { notFound } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import type { CompanyLedger } from "@/lib/fo";
import { UpgradeNote } from "../../../upgrade-note";
import { CompanyAccount } from "./company-account";

export default async function CompanyPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const user = await requireUser();
  if (!has(user, "front_office")) return <div className="mx-auto max-w-md"><UpgradeNote feature="Front office and housekeeping" /></div>;
  if (!(can(user, "fo.view") || can(user, "fo.manage"))) return <div className="card mx-auto max-w-md p-5 text-sm">Your role does not include company accounts.</div>;
  const supabase = await createClient();
  const [{ data }, methods] = await Promise.all([
    supabase.rpc("fo_company_ledger", { p_company: id }),
    supabase.from("payment_methods").select("id, name").eq("is_active", true).not("kind", "in", "(gift_card,loyalty,advance,account,room)").order("display_order"),
  ]);
  const ledger = data as unknown as CompanyLedger | null;
  if (!ledger) notFound();
  return (
    <div className="mx-auto max-w-4xl">
      <Link href="/front-office/companies" className="text-sm underline">← Companies</Link>
      <CompanyAccount ledger={ledger} methods={(methods.data ?? []) as { id: string; name: string }[]} currency={user.currency_code} canManage={can(user, "fo.manage")} />
    </div>
  );
}
