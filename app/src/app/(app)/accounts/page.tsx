import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Accounts, type Account } from "./accounts";

/** Customer accounts: eat now, pay later. */
export default async function AccountsPage() {
  const user = await requireUser();
  if (!can(user, "payment.take") && !can(user, "customer.manage")) {
    return (
      <div className="card mx-auto mt-4 max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role cannot open customer accounts. Ask an owner or manager.
      </div>
    );
  }
  const supabase = await createClient();
  const [{ data: list }, { data: methods }] = await Promise.all([
    supabase.rpc("accounts_list"),
    supabase.from("payment_methods").select("id, name, kind").eq("is_active", true).not("kind", "in", "(gift_card,loyalty,advance,account)").order("display_order"),
  ]);
  return (
    <Accounts
      accounts={(list ?? []) as unknown as Account[]}
      methods={methods ?? []}
      currency={user.currency_code}
      canManage={can(user, "customer.manage")}
      canPay={can(user, "payment.take")}
    />
  );
}
