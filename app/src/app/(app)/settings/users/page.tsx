import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import Link from "next/link";
import { rightLabel, sortRoles } from "@/lib/permissions";
import { StaffManager } from "./staff-manager";


export default async function StaffPage() {
  const current = await requireUser();
  const supabase = await createClient();

  const [{ data: users }, { data: roles }, { data: rest }] = await Promise.all([
    supabase
      .from("users")
      .select("id, full_name, employee_code, email, is_active, role_id, auth_user_id, pin_set_at, phone, department, designation, employee_no, relieving_date, login_locked_until")
      .is("deleted_at", null)
      .order("employee_code"),
    supabase.from("roles").select("id, name, role_permissions(permission_key)").order("name"),
    supabase.from("restaurants").select("client_code").eq("id", current.restaurant_id).maybeSingle(),
  ]);
  const roleName = new Map((roles ?? []).map((r) => [r.id, r.name]));

  return (
    <div>
      <h2 className="text-xl font-bold">Users</h2>
      <p className="mt-1 mb-6 text-sm" style={{ color: "var(--color-ink-3)" }}>
        The people who can sign in. What each role may do is set in{" "}
        <Link href="/settings/security" className="font-bold" style={{ color: "var(--color-brand)" }}>
          Security profiles
        </Link>
        .{" "}
        <Link href="/reports/user-list" className="font-bold" style={{ color: "var(--color-brand)" }}>
          Print the user list
        </Link>
      </p>

      {rest?.client_code && (
        <div className="card mb-4 flex flex-wrap items-center gap-x-5 gap-y-2 p-4">
          <div>
            <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Client code for staff sign-in
            </div>
            <div className="mt-0.5 text-2xl font-bold tabular-nums tracking-wider">{rest.client_code}</div>
          </div>
          <p className="min-w-0 flex-1 basis-64 text-sm" style={{ color: "var(--color-ink-2)" }}>
            On the sign-in page everyone types this <b>restaurant code</b> first (remembered on that device), then their <b>username</b> (the code under
            their name below, for example EMP001, or their email) and their password.
          </p>
        </div>
      )}

      <StaffManager
        canManage={can(current, "user.manage")}
        isOwner={current.role_name === "Owner"}
        appUrl="sna-pos.vercel.app"
        roles={sortRoles(roles ?? []).map((r) => ({
          id: r.id,
          name: r.name,
          // These rights run the back office, so a PIN-only counter login may not hold them.
          backOffice: (r.role_permissions ?? []).some((p) => ["stock.manage", "settings.manage", "user.manage", "tax.manage"].includes(p.permission_key)),
        }))}
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
          phone: u.phone ?? "",
          department: u.department ?? "",
          designation: u.designation ?? "",
          employeeNo: u.employee_no ?? "",
          relievingDate: u.relieving_date ?? "",
          isMe: u.id === current.user_id,
          signInLocked: !!u.login_locked_until && new Date(u.login_locked_until).getTime() > Date.now(),
        }))}
      />

      <h3 className="mb-3 mt-10 text-base font-bold">What each role can do</h3>
      <div className="grid gap-3 sm:grid-cols-2">
        {sortRoles(roles ?? [])
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
                      {rightLabel(p)}
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
