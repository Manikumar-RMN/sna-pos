import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { NoAccess, SectionHead } from "../section-head";
import { BusinessTypeCard } from "../company/business-type";

export default async function BusinessTypeSettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage")) return <NoAccess />;
  const supabase = await createClient();
  const { data: rest } = await supabase.from("restaurants").select("business_type").limit(1).maybeSingle();
  return (
    <div className="space-y-4">
      <SectionHead title="Type of business">Sets the starting POS settings: which kinds of bill, which one starts on, and token numbers.</SectionHead>
      <BusinessTypeCard initial={rest?.business_type ?? "restaurant"} canEdit />
    </div>
  );
}
