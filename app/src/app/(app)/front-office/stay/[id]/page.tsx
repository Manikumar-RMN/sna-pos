import Link from "next/link";
import { notFound } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../../../upgrade-note";
import type { Folio } from "@/lib/fo";
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
    supabase.from("payment_methods").select("id, name").eq("is_active", true).order("display_order"),
  ]);
  const folio = data as unknown as Folio | null;
  if (!folio) notFound();
  return (
    <div className="mx-auto max-w-3xl">
      <Link href="/front-office" className="text-sm underline">← Front office</Link>
      <FolioView folio={folio} methods={(methods.data ?? []) as { id: string; name: string }[]} currency={user.currency_code} canManage={can(user, "fo.manage")} />
    </div>
  );
}
