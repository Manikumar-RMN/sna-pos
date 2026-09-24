"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type SetupState = { error: string | null };

export async function createRestaurant(_prev: SetupState, formData: FormData): Promise<SetupState> {
  const legalName = String(formData.get("legal_name") ?? "").trim();
  const tradingName = String(formData.get("trading_name") ?? "").trim();
  const ownerName = String(formData.get("owner_name") ?? "").trim();
  const countryCode = String(formData.get("country_code") ?? "IN").trim();
  const branchName = String(formData.get("branch_name") ?? "Main Branch").trim();
  const branchCode = String(formData.get("branch_code") ?? "MN").trim().toUpperCase();
  const taxNo = String(formData.get("tax_registration_no") ?? "").trim().toUpperCase();

  if (!legalName || !tradingName || !ownerName) {
    return { error: "Fill in the business name, display name and your name." };
  }

  const supabase = await createClient();

  // One call creates the restaurant, its roles and permissions, the first
  // branch, the country's tax setup, payment methods, receipt settings and a
  // billing device — all in one transaction.
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

  revalidatePath("/", "layout");
  redirect("/dashboard");
}

/** A staff member joins the restaurant that invited them. */
export async function joinWithCode(_prev: SetupState, formData: FormData): Promise<SetupState> {
  const code = String(formData.get("code") ?? "").trim();
  if (code.replace(/[^A-Za-z0-9]/g, "").length !== 8) {
    return { error: "The invite code is 8 letters and numbers, like ABCD-2345." };
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc("claim_staff_invite", { p_code: code });
  if (error) return { error: error.message };
  revalidatePath("/", "layout");
  redirect("/dashboard");
}
