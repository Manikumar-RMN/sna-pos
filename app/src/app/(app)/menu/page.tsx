import { redirect } from "next/navigation";

/** The menu now lives under Settings. Old links still work. */
export default function MenuRedirect() {
  redirect("/settings/menu");
}
