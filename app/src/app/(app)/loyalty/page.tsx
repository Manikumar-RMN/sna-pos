import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import { GiftCardDesk, LoyaltyRules } from "./loyalty-forms";

export default async function LoyaltyPage() {
  const user = await requireUser();
  if (!has(user, "loyalty")) {
    return <p className="card p-5 text-sm">Loyalty and gift cards is an add-on. Ask for it in Settings → Plan and modules.</p>;
  }
  const supabase = await createClient();
  const [{ data: rules }, { data: methods }, { data: cards }, { data: ledger }, { data: led }] = await Promise.all([
    supabase.from("loyalty_settings").select("spend_per_point, point_value, min_redeem").maybeSingle(),
    supabase.from("payment_methods").select("id, name").eq("is_active", true).not("kind", "in", "(gift_card,loyalty)").order("display_order"),
    supabase.from("gift_cards").select("id, code, value, expires_on, created_at, customers!gift_cards_customer_id_fkey(name, phone)").order("created_at", { ascending: false }).limit(50),
    supabase.from("gift_card_ledger").select("gift_card_id, amount"),
    supabase.from("loyalty_ledger").select("customer_id, points, customers!loyalty_ledger_customer_id_fkey(name, phone)"),
  ]);
  const bal = new Map<string, number>();
  for (const l of ledger ?? []) bal.set(l.gift_card_id, (bal.get(l.gift_card_id) ?? 0) + Number(l.amount));
  const guests = new Map<string, { name: string; phone: string; points: number }>();
  for (const l of led ?? []) {
    const c = l.customers as unknown as { name: string; phone: string } | null;
    const g = guests.get(l.customer_id) ?? { name: c?.name ?? "Guest", phone: c?.phone ?? "", points: 0 };
    g.points += Number(l.points);
    guests.set(l.customer_id, g);
  }
  const top = [...guests.values()].filter((g) => g.points > 0).sort((a, b) => b.points - a.points).slice(0, 30);
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
          initial={{ spend: Number(rules?.spend_per_point ?? 100), value: Number(rules?.point_value ?? 1), min: Number(rules?.min_redeem ?? 0), saved: !!rules }}
        />
      )}

      {can(user, "payment.take") && <GiftCardDesk currency={user.currency_code} methods={methods ?? []} />}

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
        <h2 className="mb-2 text-sm font-bold">Guests with points</h2>
        {top.length === 0 ? (
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>No points earned yet.</p>
        ) : (
          <ul className="grid gap-1 text-sm sm:grid-cols-2">
            {top.map((g, i) => (
              <li key={i} className="flex justify-between">
                <span>{g.name} · +{g.phone}</span>
                <b className="tabular-nums">{g.points}</b>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
