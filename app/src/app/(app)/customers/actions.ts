"use server";

import { revalidatePath } from "next/cache";
import { can, getCurrentUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import { todayIn } from "@/lib/format";
import {
  CUSTOMER_CSV_HEADER,
  EXPORT_MAX_ROWS,
  EXPORT_PAGE_SIZE,
  customerCsvRows,
  exportFilename,
  parseCustomerList,
  parseFilter,
  parseSort,
  searchText,
  toCsv,
  validateCustomerEdit,
  type CustomerRow,
} from "@/lib/customers";

/** Saves the profile. The database checks the right (customer.manage) and writes the audit row with old and new values. */
export async function updateCustomer(
  id: string,
  input: { name: string; email: string; notes: string; birthday: string; consent: boolean },
): Promise<{ ok: true; message: string } | { ok: false; error: string }> {
  const user = await getCurrentUser();
  if (!user) return { ok: false, error: "Please sign in again." };
  const v = validateCustomerEdit(input, todayIn(user.timezone));
  if (!v.ok) return v;
  const supabase = await createClient();
  // email / notes / birthday: null means "clear it" in the database function (null is sent at runtime; the generated types do not allow null).
  const { error } = await supabase.rpc("update_customer", {
    p_customer: id,
    p_name: v.name,
    p_email: v.email as string,
    p_notes: v.notes as string,
    p_birthday: v.birthday as string,
    p_consent: v.consent,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/customers/${id}`);
  revalidatePath("/customers");
  return { ok: true, message: "Guest saved." };
}

/**
 * "Delete guest data" (the guest's right to be forgotten). Needs customer.manage and a manager PIN when the person lacks the
 * right: the database error carries "(customer.manage)" and the screen then shows the PIN prompt, like other approvals.
 */
export async function forgetCustomer(id: string, reason: string): Promise<{ ok: true; message: string } | { ok: false; error: string }> {
  const r = reason.trim();
  if (r.length < 3) return { ok: false, error: "Write a short reason (for example: guest asked us to delete their data)." };
  if (r.length > 200) return { ok: false, error: "The reason can be at most 200 characters." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("forget_customer", { p_customer: id, p_reason: r });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/customers/${id}`);
  revalidatePath("/customers");
  return { ok: true, message: "The guest's name, phone and notes were erased. Bills and totals are kept." };
}

export type ExportResult =
  | { ok: true; filename: string; csv: string; rows: number; truncated: boolean }
  | { ok: false; error: string };

/**
 * Builds the CSV on the server: needs customer.export, reads customer_list in pages of 200 and records the export in the
 * audit log (rows and filter, never the phone numbers). The file is only sent to the person who asked.
 */
export async function exportCustomers(q: string, filterIn: string, sortIn: string): Promise<ExportResult> {
  const user = await getCurrentUser();
  if (!user) return { ok: false, error: "Please sign in again." };
  if (!can(user, "customer.export")) return { ok: false, error: "You do not have permission to export the guest list." };
  const filter = parseFilter(filterIn);
  const sort = parseSort(sortIn);
  const search = searchText(q);

  const supabase = await createClient();
  const all: CustomerRow[] = [];
  let total = Infinity;
  while (all.length < total && all.length < EXPORT_MAX_ROWS) {
    const { data, error } = await supabase.rpc("customer_list", {
      p_q: search || undefined,
      p_filter: filter,
      p_sort: sort,
      p_limit: EXPORT_PAGE_SIZE,
      p_offset: all.length,
    });
    if (error) return { ok: false, error: friendlyDbError(error) };
    const page = parseCustomerList(data);
    total = page.total;
    if (page.rows.length === 0) break;
    all.push(...page.rows);
  }
  const truncated = all.length < total;

  // The audit row is written by the database (log_customer_export, migration 148) and must be written before the file is handed over.
  const audit = await supabase.rpc("log_customer_export", { p_rows: all.length, p_filter: filter });
  if (audit.error) return { ok: false, error: friendlyDbError(audit.error) };

  return { ok: true, filename: exportFilename(todayIn(user.timezone), filter), csv: toCsv(CUSTOMER_CSV_HEADER, customerCsvRows(all)), rows: all.length, truncated };
}
