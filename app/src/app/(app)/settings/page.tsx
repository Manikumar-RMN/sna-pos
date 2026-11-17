import { redirect } from "next/navigation";
import { requireUser } from "@/lib/auth";
import { settingsSections } from "./sections";

/** /settings opens the first section this person may use. */
export default async function SettingsIndex() {
  const user = await requireUser();
  const all = settingsSections(user, "Tax");
  // Company first (the list is sorted by name, which would open "API keys").
  redirect((all.find((s) => s.href === "/settings/company") ?? all[0])?.href ?? "/settings/menu");
}
