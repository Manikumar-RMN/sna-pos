"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type SetupState = { error: string | null };

export async function createRestaurant(
  _prev: SetupState,
  formData: FormData,
): Promise<SetupState> {
  const legalName = String(formData.get("legal_name") ?? "").trim();
  const tradingName = String(formData.get("trading_name") ?? "").trim();
  const ownerName = String(formData.get("owner_name") ?? "").trim();
  const countryCode = String(formData.get("country_code") ?? "IN").trim();
  const branchName = String(formData.get("branch_name") ?? "Main Branch").trim();
  const branchCode = String(formData.get("branch_code") ?? "MN").trim().toUpperCase();
  const taxNo = String(formData.get("tax_registration_no") ?? "").trim();

  if (!legalName || !tradingName || !ownerName) {
    return { error: "Fill in the business name, display name and your name." };
  }

  const supabase = await createClient();

  // One call creates the restaurant, its roles and permissions, the first
  // branch, the country's tax setup, payment methods, receipt settings and a
  // billing device — all in one transaction, so a half-built restaurant
  // cannot exist. The database refuses unsupported countries and refuses a
  // second restaurant for the same account.
  const { error } = await supabase.rpc("create_restaurant_with_owner", {
    p_legal_name: legalName,
    p_trading_name: tradingName,
    p_country_code: countryCode,
    p_owner_name: ownerName,
    p_branch_name: branchName || "Main Branch",
    p_branch_code: branchCode || "MN",
    p_timezone: undefined,
    p_tax_registration_no: taxNo || undefined,
  });

  if (error) return { error: error.message };

  // The new rows are not visible to a read taken in the same request, so the
  // redirect matters: the next request gets a fresh snapshot and sees them.
  revalidatePath("/", "layout");
  redirect("/dashboard");
}
