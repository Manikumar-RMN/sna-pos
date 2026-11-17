import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { NoAccess, SectionHead } from "../section-head";
import { StockOnSaleForm } from "./form";

export default async function StockOnSale() {
  const user = await requireUser();
  if (!can(user, "settings.manage")) return <NoAccess />;
  const supabase = await createClient();
  const { data: bs } = await supabase.from("branch_settings").select("auto_consumption").eq("branch_id", user.branch_id).maybeSingle();
  return (
    <div className="space-y-4">
      <SectionHead title="Stock on sale">
        Whether a bill takes stock out of {user.outlet_count > 1 ? user.branch_name : "this outlet"}. Only dishes and drinks that have a recipe take stock.
      </SectionHead>
      <StockOnSaleForm initial={bs?.auto_consumption !== false} />
    </div>
  );
}
