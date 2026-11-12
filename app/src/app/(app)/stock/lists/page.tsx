import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../../upgrade-note";
import { ListsBoard } from "./lists-board";

export default async function StockListsPage({ searchParams }: { searchParams: Promise<{ from?: string }> }) {
  const fromSettings = (await searchParams).from === "settings";
  const user = await requireUser();
  if (!can(user, "stock.manage") && !can(user, "stock.view")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include stock. An owner can change this in Settings → Security profiles.
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
  const { data } = await supabase.from("stock_lists").select("id, kind, name, is_active").order("kind").order("name");
  const items = (data ?? []).map((r) => ({ id: r.id, kind: r.kind === "department" ? ("department" as const) : ("category" as const), name: r.name, is_active: r.is_active }));
  return (
    <div className="mx-auto max-w-2xl">
      <Link href={fromSettings ? "/settings" : "/stock"} className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        {fromSettings ? "← Setup" : "← Stock"}
      </Link>
      <h1 className="mt-2 text-xl font-bold tracking-tight">Item groups and departments</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Keep one spelling for each group and department, so reports add up. Items that already have a group keep it even if you switch the group off.
      </p>
      <ListsBoard items={items} canManage={can(user, "stock.manage")} />
    </div>
  );
}
