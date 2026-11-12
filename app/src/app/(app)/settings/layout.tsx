import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { SettingsNav } from "./settings-nav";
import { settingsSections } from "./sections";

export default async function SettingsLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const user = await requireUser();
  const supabase = await createClient();
  const { data: country } = await supabase.from("countries").select("tax_system_name").eq("code", user.country_code).maybeSingle();
  const links = settingsSections(user, country?.tax_system_name ?? "Tax");

  return (
    <div className="mx-auto max-w-7xl">
      <h1 className="mb-4 text-2xl font-bold tracking-tight">Settings</h1>
      <div className="flex flex-col gap-4 md:flex-row md:items-start md:gap-6">
        <aside className="md:sticky md:top-3 md:max-h-[calc(100vh/var(--z)_-_1.5rem)] md:w-64 md:shrink-0 md:overflow-y-auto">
          <SettingsNav links={links} />
        </aside>
        <section className="min-w-0 flex-1">{children}</section>
      </div>
    </div>
  );
}
