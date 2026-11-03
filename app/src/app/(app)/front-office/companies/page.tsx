import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import type { Company } from "@/lib/fo";
import { UpgradeNote } from "../../upgrade-note";
import { CompaniesClient } from "./companies-client";

export default async function CompaniesPage() {
  const user = await requireUser();
  if (!has(user, "front_office")) return <div className="mx-auto max-w-md"><UpgradeNote feature="Front office and housekeeping" /></div>;
  if (!(can(user, "fo.view") || can(user, "fo.manage"))) return <div className="card mx-auto max-w-md p-5 text-sm">Your role does not include company accounts.</div>;
  const { data } = await (await createClient()).rpc("fo_companies_list", { p_include_inactive: true });
  return (
    <div className="mx-auto max-w-4xl">
      <Link href="/front-office" className="text-sm underline">← Front office</Link>
      <CompaniesClient companies={(data ?? []) as unknown as Company[]} currency={user.currency_code} canManage={can(user, "fo.manage")} />
    </div>
  );
}
