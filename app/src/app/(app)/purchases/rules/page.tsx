import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../../upgrade-note";
import { RulesBoard } from "./rules-board";
import { ApprovalBoard } from "./approval-board";

export default async function RulesPage() {
  const user = await requireUser();
  if (!can(user, "stock.manage") && !can(user, "stock.view")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include stock or purchases. An owner can change this in Settings → Security profiles.
      </div>
    );
  }
  if (!has(user, "stock")) {
    return (
      <div className="mx-auto max-w-md">
        <UpgradeNote feature="Stock and recipes" />
      </div>
    );
  }
  const supabase = await createClient();
  const [{ data }, { data: lv }, { data: people }] = await Promise.all([
    supabase.from("purchase_settings").select("direct_receiving, rate_check, allow_excess_qty, po_needs_requisition, max_backdate_days, approval_block_self").maybeSingle(),
    supabase.from("purchase_approval_levels").select("level, min_amount, approver_id").order("level"),
    supabase.from("users").select("id, full_name").eq("is_active", true).is("deleted_at", null).order("full_name"),
  ]);
  return (
    <div className="mx-auto max-w-3xl">
      <Link href="/purchases" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← Purchases
      </Link>
      <h1 className="mt-2 text-xl font-bold tracking-tight">Purchase rules</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        How strict receiving and ordering should be. Only the owner can change these. Who may enter earlier dates is set per role in Settings → Security profiles (rights &ldquo;earlier date&rdquo; and &ldquo;future date&rdquo;).
      </p>
      <RulesBoard
        canEdit={can(user, "settings.manage")}
        initial={{
          direct: data?.direct_receiving ?? true,
          rateCheck: (data?.rate_check as "off" | "warn" | "block") ?? "off",
          excess: data?.allow_excess_qty ?? true,
          needsRequisition: data?.po_needs_requisition ?? false,
          backdateDays: data?.max_backdate_days ?? 31,
        }}
      />
      <ApprovalBoard
        canEdit={can(user, "settings.manage")}
        currency={user.currency_code}
        people={(people ?? []).map((x) => ({ id: x.id, name: x.full_name }))}
        initial={(lv ?? []).map((l) => ({ level: l.level, minAmount: Number(l.min_amount), approverId: l.approver_id }))}
        blockSelf={!!data?.approval_block_self}
      />
    </div>
  );
}
