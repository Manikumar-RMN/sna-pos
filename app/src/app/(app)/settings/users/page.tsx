import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export default async function UsersPage() {
  const current = await requireUser();
  const supabase = await createClient();

  const { data: users } = await supabase
    .from("users")
    .select("id, full_name, employee_code, email, is_active, role_id")
    .is("deleted_at", null)
    .order("employee_code");

  const { data: roles } = await supabase
    .from("roles")
    .select("id, name, role_permissions(permission_key)")
    .order("name");

  const roleName = new Map((roles ?? []).map((r) => [r.id, r.name]));

  return (
    <div className="mx-auto max-w-4xl">
      <h1 className="text-xl font-bold tracking-tight">Users and roles</h1>
      <p className="mt-1 mb-6 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Who can sign in, and what each of them is allowed to do.
      </p>

      <div className="card mb-6 overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr style={{ color: "var(--color-ink-3)" }}>
              <th className="px-4 py-3 text-left text-xs font-semibold">Name</th>
              <th className="px-4 py-3 text-left text-xs font-semibold">Code</th>
              <th className="px-4 py-3 text-left text-xs font-semibold">Role</th>
              <th className="px-4 py-3 text-left text-xs font-semibold">Status</th>
            </tr>
          </thead>
          <tbody>
            {(users ?? []).map((u) => (
              <tr key={u.id} style={{ borderTop: "1px solid var(--color-line)" }}>
                <td className="px-4 py-3 font-medium">
                  {u.full_name}
                  {u.email && (
                    <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                      {u.email}
                    </div>
                  )}
                </td>
                <td className="px-4 py-3 tabular-nums">{u.employee_code}</td>
                <td className="px-4 py-3">{roleName.get(u.role_id) ?? "—"}</td>
                <td className="px-4 py-3">
                  <span
                    className="rounded-full px-2 py-1 text-xs font-semibold"
                    style={
                      u.is_active
                        ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" }
                        : { background: "var(--color-bad-soft)", color: "var(--color-bad)" }
                    }
                  >
                    {u.is_active ? "Active" : "Inactive"}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <h2 className="mb-3 text-base font-bold">What each role can do</h2>
      <div className="grid gap-3 sm:grid-cols-2">
        {(roles ?? []).map((r) => {
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
                  <span
                    key={p}
                    className="rounded px-1.5 py-0.5 text-[11px]"
                    style={{ background: "var(--color-ground)", color: "var(--color-ink-2)" }}
                  >
                    {p}
                  </span>
                ))}
              </div>
            </div>
          );
        })}
      </div>

      {!can(current, "user.manage") && (
        <p className="mt-6 text-xs" style={{ color: "var(--color-ink-3)" }}>
          You can view this list but not change it. Adding and editing users
          needs the “user.manage” permission.
        </p>
      )}

      <p className="mt-6 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Adding and editing staff comes in a later stage. These roles were
        created automatically when the restaurant was set up.
      </p>
    </div>
  );
}
