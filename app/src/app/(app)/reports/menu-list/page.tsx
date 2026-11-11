import Link from "next/link";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

/** Menu list (Winsar "Menu List"): every dish with its group, price and whether it can be ordered now. */
type Row = { id: string; name: string; price: number | null; is_available: boolean; is_veg: boolean | null; prep_minutes: number | null; kitchen_station: string | null; categories: { name: string } | null };

export default async function MenuListPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; active?: string }> }) {
  const sp = await searchParams;
  const r = await loadReport(sp, { title: "Menu list" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, user } = ctx;
  const c = user.currency_code;
  const onlyActive = sp.active === "1";
  let q = supabase.from("products").select("id, name, price, is_available, is_veg, prep_minutes, kitchen_station, categories(name)").is("deleted_at", null);
  if (onlyActive) q = q.eq("is_available", true);
  const { data, error } = await q.order("name").limit(2000);
  const rows = ((error ? [] : (data ?? [])) as unknown as Row[]).sort((a, b) => (a.categories?.name ?? "~").localeCompare(b.categories?.name ?? "~") || a.name.localeCompare(b.name));
  const head = ["Group", "Item", "Price", "Veg", "Prep (min)", "Station", "Available"];
  const table = rows.map((x) => [x.categories?.name ?? "No group", x.name, money(Number(x.price ?? 0), c), x.is_veg == null ? "—" : x.is_veg ? "Veg" : "Non-veg", x.prep_minutes == null ? "—" : String(x.prep_minutes), x.kitchen_station ?? "—", x.is_available ? "Yes" : "No"]);
  return (
    <ReportShell
      ctx={ctx}
      title="Menu list"
      basePath="/reports/menu-list"
      basis="the current menu"
      excel={rows.length > 0 ? { filename: "menu_list.csv", header: head, rows: rows.map((x) => [x.categories?.name ?? "No group", x.name, Number(x.price ?? 0), x.is_veg == null ? "" : x.is_veg ? "Veg" : "Non-veg", x.prep_minutes ?? "", x.kitchen_station ?? "", x.is_available ? "Yes" : "No"]) } : null}
    >
      <p className="no-print mb-2 text-xs">
        <Link href={onlyActive ? "/reports/menu-list" : "/reports/menu-list?active=1"} className="font-semibold" style={{ color: "var(--color-brand-strong)" }}>
          {onlyActive ? "Show all items" : "Show only items that can be ordered"}
        </Link>
      </p>
      {error ? <Err e={{ message: "Could not read the menu." }} /> : rows.length === 0 ? <Empty text="The menu has no items." /> : <ReportTable head={head} textCols={[0, 1, 3, 5, 6]} zebra rows={table} />}
      <Note>{rows.length} items. Price is the menu price; outlet-specific prices and tax are set in Menu and Settings.</Note>
    </ReportShell>
  );
}
