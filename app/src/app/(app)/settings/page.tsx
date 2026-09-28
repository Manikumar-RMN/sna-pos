import { redirect } from "next/navigation";
import { requireUser } from "@/lib/auth";
import { settingsSections } from "./sections";

/** /settings opens the first section this person may use. */
export default async function SettingsIndex() {
  const user = await requireUser();
  redirect(settingsSections(user, "Tax")[0]?.href ?? "/settings/menu");
}
