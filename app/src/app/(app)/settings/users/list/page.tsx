import Link from "next/link";
import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { todayIn } from "@/lib/format";
import { CsvButton } from "../../../reports/csv-button";
import { PrintButton } from "../../../print-button";

/** User list, like Winsar's User List report: every user with role, department, designation, status and relieving date. */
export default async function UserListPage() {
  const user = await requireUser();
  if (!can(user, "user.manage")) {
    return <div className="card p-5 text-sm">Your role does not include managing users.</div>;
  }
  const supabase = await createClient();
  const [{ data: users }, { data: roles }, { data: rest }] = await Promise.all([
    supabase
      .from("users")
      .select("full_name, employee_code, email, is_active, role_id, phone, department, designation, employee_no, relieving_date")
      .is("deleted_at", null)
      .order("employee_code"),
    supabase.from("roles").select("id, name"),
    supabase.from("restaurants").select("trading_name, client_code").eq("id", user.restaurant_id).maybeSingle(),
  ]);
  const roleName = new Map((roles ?? []).map((r) => [r.id, r.name]));
  const today = todayIn(user.timezone);
  const status = (u: { is_active: boolean; relieving_date: string | null }) =>
    u.relieving_date && u.relieving_date < today ? "Relieved" : u.is_active ? "Active" : "Inactive";

  const head = ["User code", "User name", "Role", "Department", "Designation", "Employee no", "Mobile", "Email", "Status", "Relieving date"];
  const rows = (users ?? []).map((u) => [
    u.employee_code,
    u.full_name,
    roleName.get(u.role_id) ?? "—",
    u.department ?? "",
    u.designation ?? "",
    u.employee_no ?? "",
    u.phone ?? "",
    u.email && !u.email.endsWith("@staff.sna-pos.app") ? u.email : "",
    status(u),
    u.relieving_date ?? "",
  ]);

  return (
    <div className="report-root">
      <div className="no-print mb-3 flex flex-wrap items-center justify-between gap-2">
        <Link href="/settings/users" className="text-xs font-semibold" style={{ color: "var(--color-brand-strong)" }}>
          ← Back to users
        </Link>
        <div className="flex gap-2">
          <PrintButton label="Print" />
          <CsvButton filename="user_list.csv" header={head} rows={rows} label="Excel (CSV)" />
        </div>
      </div>
      <h2 className="text-xl font-bold">User list</h2>
      <p className="mb-4 text-xs" style={{ color: "var(--color-ink-3)" }}>
        {rest?.trading_name ?? ""} {rest?.client_code ? `· client code ${rest.client_code}` : ""} · as on {today} · {rows.length} users
      </p>
      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr style={{ color: "var(--color-ink-3)" }}>
              {head.map((h) => (
                <th key={h} className="whitespace-nowrap border-b px-2 py-1.5 text-xs font-semibold">
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i} className="border-b">
                {r.map((c, j) => (
                  <td key={j} className="px-2 py-1.5">
                    {c || "—"}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
