import Link from "next/link";
import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { BusinessForm, PaymentMethodsForm, TablesForm, TaxForm } from "./settings-forms";

export default async function SettingsPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [{ data: rest }, { data: branch }, { data: bs }, { data: tables }, { data: groups }, { data: rates }, { data: products }, { data: methods }, { data: openTabs }] =
    await Promise.all([
      supabase.from("restaurants").select("legal_name, trading_name, tax_registration_no, contact_phone").limit(1).maybeSingle(),
      supabase.from("branches").select("name, address_line1, address_line2, city, state_or_region, postal_code, phone").is("deleted_at", null).order("created_at").limit(1).maybeSingle(),
      supabase.from("branch_settings").select("receipt_header, receipt_footer, cash_rounding_mode, auto_print_kot").limit(1).maybeSingle(),
      supabase.from("dining_tables").select("id, table_number, seats").eq("is_active", true).order("table_number"),
      supabase.from("tax_groups").select("id, name").eq("is_active", true).order("name"),
      supabase.from("tax_rates").select("tax_group_id, total_rate, valid_from, valid_to").lte("valid_from", today).order("valid_from", { ascending: false }),
      supabase.from("products").select("tax_group_id").is("deleted_at", null),
      supabase.from("payment_methods").select("id, name, is_active").order("display_order"),
      supabase.from("orders").select("dining_table_id").eq("payment_status", "unpaid").neq("status", "voided").not("dining_table_id", "is", null),
    ]);

  const currentRate = (gid: string) => {
    const r = (rates ?? []).find((x) => x.tax_group_id === gid && (!x.valid_to || x.valid_to >= today));
    return r ? Number(r.total_rate) : null;
  };
  const busy = new Set((openTabs ?? []).map((o) => o.dining_table_id));

  return (
    <div className="mx-auto max-w-4xl space-y-5">
      <div>
        <h1 className="text-xl font-bold tracking-tight">Settings</h1>
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
          Your business details, receipt, tables, payment methods and GST. Staff are on the{" "}
          <Link href="/settings/users" className="font-semibold" style={{ color: "var(--color-brand)" }}>
            Staff
          </Link>{" "}
          screen.
        </p>
      </div>

      <BusinessForm
        canEdit={can(user, "settings.manage")}
        initial={{
          legal_name: rest?.legal_name ?? "",
          trading_name: rest?.trading_name ?? "",
          tax_registration_no: rest?.tax_registration_no ?? "",
          contact_phone: rest?.contact_phone ?? "",
          branch_name: branch?.name ?? "",
          address_line1: branch?.address_line1 ?? "",
          address_line2: branch?.address_line2 ?? "",
          city: branch?.city ?? "",
          state_or_region: branch?.state_or_region ?? "",
          postal_code: branch?.postal_code ?? "",
          phone: branch?.phone ?? "",
          receipt_header: bs?.receipt_header ?? "",
          receipt_footer: bs?.receipt_footer ?? "",
          cash_rounding_mode: bs?.cash_rounding_mode ?? "nearest_1",
          auto_print_kot: bs?.auto_print_kot ?? true,
        }}
      />

      <div className="grid gap-5 lg:grid-cols-2">
        <TaxForm
          canEdit={can(user, "tax.manage")}
          groups={(groups ?? []).map((g) => ({
            id: g.id,
            name: g.name,
            rate: currentRate(g.id),
            items: (products ?? []).filter((p) => p.tax_group_id === g.id).length,
          }))}
        />
        <div className="space-y-5">
          <TablesForm
            canEdit={can(user, "settings.manage")}
            tables={(tables ?? []).map((t) => ({ id: t.id, number: t.table_number, seats: t.seats, busy: busy.has(t.id) }))}
          />
          <PaymentMethodsForm canEdit={can(user, "settings.manage")} methods={methods ?? []} />
        </div>
      </div>
    </div>
  );
}
