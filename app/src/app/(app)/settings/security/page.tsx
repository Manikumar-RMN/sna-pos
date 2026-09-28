import { can, has, requireUser } from "@/lib/auth";
import { UpgradeNote } from "../../upgrade-note";
import { createClient } from "@/lib/supabase/server";
import { rightGroups, sortRoles } from "@/lib/permissions";
import { NoAccess, SectionHead } from "../section-head";
import { SecurityEditor } from "./security-editor";

export default async function SecuritySettings() {
  const user = await requireUser();
  if (!can(user, "user.manage")) return <NoAccess />;
  if (!has(user, "custom_roles")) {
    return (
      <div>
        <SectionHead title="Security profiles">
          Basic comes with ready-made roles: Owner, Manager, Cashier, Steward and Chef. Give each person a role on the Users page.
        </SectionHead>
        <UpgradeNote feature="Custom security profiles" />
      </div>
    );
  }
  const supabase = await createClient();
  const [{ data: roles }, { data: users }, { data: country }] = await Promise.all([
    supabase.from("roles").select("id, name, is_system, role_permissions(permission_key)"),
    supabase.from("users").select("role_id").is("deleted_at", null),
    supabase.from("countries").select("tax_system_name").eq("code", user.country_code).maybeSingle(),
  ]);
  const people = new Map<string, number>();
  for (const u of users ?? []) people.set(u.role_id, (people.get(u.role_id) ?? 0) + 1);

  return (
    <div>
      <SectionHead title="Security profiles">
        Each role is a profile. Tick what the people with that role are allowed to do, then give each person a role on the Users page.
      </SectionHead>
      <SecurityEditor
        isOwner={user.role_name === "Owner"}
        groups={rightGroups(country?.tax_system_name ?? "tax")}
        roles={sortRoles(roles ?? []).map((r) => ({
          id: r.id,
          name: r.name,
          locked: r.name === "Owner" && r.is_system,
          people: people.get(r.id) ?? 0,
          rights: (r.role_permissions ?? []).map((p) => p.permission_key),
        }))}
      />
    </div>
  );
}
