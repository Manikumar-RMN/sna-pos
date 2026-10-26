import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import Link from "next/link";
import { POINTS_DO_NOT_EXPIRE } from "@/lib/customers";
import { GiftCardDesk, LoyaltyRules } from "./loyalty-forms";

export default async function LoyaltyPage() {
  const user = await requireUser();
  if (!has(user, "loyalty")) {
    return <p className="card p-5 text-sm">Loyalty and gift cards is an add-on. Ask for it in Settings → Plan and modules.</p>;
  }
  const supabase = await createClient();
  const [{ data: rules }, { data: methods }, { data: cards }, { data: ledger }] = await Promise.all([
    supabase.from("loyalty_settings").select("*").maybeSingle(),
    supabase.from("payment_methods").select("id, name").eq("is_active", true).not("kind", "in", "(gift_card,loyalty,advance,account)").order("display_order"),
    supabase.from("gift_cards").select("id, code, value, expires_on, created_at, customers!gift_cards_customer_id_fkey(name, phone)").order("created_at", { ascending: false }).limit(50),
    supabase.from("gift_card_ledger").select("gift_card_id, amount"),
  ]);
  const bal = new Map<string, number>();
  for (const l of ledger ?? []) bal.set(l.gift_card_id, (bal.get(l.gift_card_id) ?? 0) + Number(l.amount));
  // redeem_mode and max_redeem_percent are new columns; read them without depending on the generated types.
  const extra = (rules ?? {}) as unknown as { redeem_mode?: string; max_redeem_percent?: number | string };
  const m = (n: number) => money(n, user.currency_code);
  const liability = [...bal.values()].reduce((a, b) => a + b, 0);

  return (
    <div className="mx-auto max-w-4xl space-y-4">
      <div>
        <h1 className="text-xl font-bold tracking-tight">Loyalty and gift cards</h1>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          Guests earn points on paid bills when their phone number is on the bill. Points and gift cards are used from the bill screen.
        </p>
      </div>

      {can(user, "settings.manage") && (
        <LoyaltyRules
          currency={user.currency_code}
          initial={{
            spend: Number(rules?.spend_per_point ?? 100),
            value: Number(rules?.point_value ?? 1),
            min: Number(rules?.min_redeem ?? 0),
            // A restaurant that never saved rules starts on "discount"; one that saved before keeps what it has (payment).
            mode: rules ? (extra.redeem_mode === "discount" ? "discount" : "tender") : "discount",
            maxPercent: Number(extra.max_redeem_percent ?? 100),
            saved: !!rules,
          }}
        />
      )}

      {can(user, "payment.take") && <GiftCardDesk currency={user.currency_code} methods={methods ?? []} canPayBack={can(user, "order.refund")} />}

      <section className="card p-4">
        <h2 className="mb-2 text-sm font-bold">Gift cards sold (last 50) · unused balance {m(liability)}</h2>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}>
                <th className="py-1">Code</th><th>Guest</th><th className="text-right">Value</th><th className="text-right">Left</th><th className="text-right">Expires</th>
              </tr>
            </thead>
            <tbody>
              {(cards ?? []).map((c) => {
                const g = c.customers as unknown as { name: string; phone: string } | null;
                return (
                  <tr key={c.id} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                    <td className="py-1.5 font-mono">{c.code}</td>
                    <td>{g ? `${g.name} (+${g.phone})` : "—"}</td>
                    <td className="text-right tabular-nums">{m(Number(c.value))}</td>
                    <td className="text-right tabular-nums">{m(bal.get(c.id) ?? 0)}</td>
                    <td className="text-right">{c.expires_on ?? "Never"}</td>
                  </tr>
                );
              })}
              {(cards ?? []).length === 0 && (
                <tr><td colSpan={5} className="py-2" style={{ color: "var(--color-ink-3)" }}>No gift cards yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <section className="card p-4">
        <h2 className="mb-1 text-sm font-bold">Guests with points</h2>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          {can(user, "customer.view") || can(user, "customer.manage") ? (
            <>See every guest, their visits and their points in <Link className="font-semibold underline" href="/customers?sort=points">Customers</Link>. </>
          ) : null}
          {POINTS_DO_NOT_EXPIRE}
        </p>
      </section>
    </div>
  );
}
