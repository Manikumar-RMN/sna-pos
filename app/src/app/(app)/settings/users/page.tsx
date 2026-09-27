import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { StaffManager } from "./staff-manager";

const PERMISSION_LABELS: Record<string, string> = {
  "order.create": "Take bills and payments",
  "order.reprint": "Reprint bills",
  "order.discount": "Give discounts",
  "order.void": "Void bills",
  "order.refund": "Refund bills",
  "menu.manage": "Edit the menu",
  "menu.price_change": "Change prices",
  "shift.open": "Open a shift",
  "shift.close": "Close a shift / count cash",
  "cash.movement": "Cash in / out",
  "report.view_sales": "See sales reports",
  "report.view_financial": "See tax and cash figures",
  "customer.manage": "Manage customers",
  "customer.export": "Export customers",
  "user.manage": "Manage staff",
  "settings.manage": "Change settings",
  "tax.manage": "Change GST rates",
  "agent.use": "Use the assistant",
  "agent.configure": "Set up the assistant",
  "agent.approve_action": "Approve assistant actions",
};

export default async function StaffPage() {
  const current = await requireUser();
  const supabase = await createClient();

  const [{ data: users }, { data: roles }] = await Promise.all([
    supabase
      .from("users")
      .select("id, full_name, employee_code, email, is_active, role_id, auth_user_id, pin_set_at")
      .is("deleted_at", null)
      .order("employee_code"),
    supabase.from("roles").select("id, name, role_permissions(permission_key)").order("name"),
  ]);
  const roleName = new Map((roles ?? []).map((r) => [r.id, r.name]));
  const order = ["Owner", "Manager", "Cashier", "Waiter", "Chef"];

  return (
    <div className="mx-auto max-w-4xl">
      <h1 className="text-xl font-bold tracking-tight">Staff</h1>
      <p className="mt-1 mb-6 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Who can sign in, and what each of them is allowed to do.
      </p>

      <StaffManager
        canManage={can(current, "user.manage")}
        isOwner={current.role_name === "Owner"}
        appUrl="sna-pos.vercel.app"
        roles={(roles ?? []).map((r) => ({ id: r.id, name: r.name }))}
        staff={(users ?? []).map((u) => ({
          id: u.id,
          name: u.full_name,
          code: u.employee_code,
          email: u.email,
          roleId: u.role_id,
          roleName: roleName.get(u.role_id) ?? "—",
          active: u.is_active,
          joined: !!u.auth_user_id,
          pinOnly: !u.auth_user_id && !u.email,
          hasPin: !!u.pin_set_at,
          isMe: u.id === current.user_id,
        }))}
      />

      <h2 className="mb-3 mt-10 text-base font-bold">What each role can do</h2>
      <div className="grid gap-3 sm:grid-cols-2">
        {[...(roles ?? [])]
          .sort((a, b) => order.indexOf(a.name) - order.indexOf(b.name))
          .map((r) => {
            const perms = (r.role_permissions ?? []).map((p) => p.permission_key).sort();
            return (
              <div key={r.id} className="card p-4">
                <div className="mb-2 flex items-center justify-between">
                  <span className="font-semibold">{r.name}</span>
                  <span className="text-xs tabular-nums" style={{ color: "var(--color-ink-3)" }}>
                    {perms.length} permissions
                  </span>
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {perms.map((p) => (
                    <span key={p} className="rounded px-1.5 py-0.5 text-[11px]" style={{ background: "var(--color-ground)", color: "var(--color-ink-2)" }}>
                      {PERMISSION_LABELS[p] ?? p}
                    </span>
                  ))}
                </div>
              </div>
            );
          })}
      </div>
    </div>
  );
}
