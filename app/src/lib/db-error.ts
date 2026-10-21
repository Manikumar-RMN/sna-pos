/**
 * Turns an error from the database into words a person can act on.
 *
 * Messages the database functions raise on purpose ("Enter the guest's name.") are already plain and pass through
 * (only the "ERROR:" prefix is removed). A rule of the table itself being broken ("new row for relation ... violates
 * check constraint ...") is not meant to be read by a person, so it is replaced: by a sentence for the rules we know
 * (negative cost, party of 500...), or by a general one for the rest.
 */
export type DbErrorLike = { message?: string | null; code?: string | null };

const KNOWN: Record<string, string> = {
  ingredients_cost_per_unit_check: "The cost cannot be negative.",
  ingredients_reorder_level_check: "The reorder level cannot be negative.",
  ingredients_unit_check: "Choose a unit from the list (kg, g, l, ml, pcs or pack).",
  ingredients_name_check: "The ingredient name must be 1 to 60 letters.",
  suppliers_name_check: "The supplier name must be 1 to 80 letters.",
  suppliers_payment_days_check: "Payment days must be between 0 and 365.",
  purchase_order_lines_qty_check: "Each quantity must be more than zero.",
  purchase_order_lines_unit_cost_check: "A cost cannot be negative.",
  goods_receipt_lines_qty_check: "Each quantity must be more than zero.",
  goods_receipt_lines_unit_cost_check: "A cost cannot be negative.",
  goods_receipts_tax_amount_check: "Tax cannot be negative.",
  goods_receipts_other_charges_check: "Other charges cannot be negative.",
  recipe_lines_qty_check: "Each recipe quantity must be more than zero.",
  loyalty_settings_spend_per_point_check: "Spend per point must be more than zero.",
  loyalty_settings_point_value_check: "The value of a point cannot be negative.",
  loyalty_settings_min_redeem_check: "The minimum points to use cannot be negative.",
  gift_cards_value_check: "Enter the gift card value (more than zero).",
  reservations_party_size_check: "A booking is for 1 to 200 people.",
  reservations_guest_name_check: "Enter the guest's name (up to 80 letters).",
  reservations_note_check: "The note can be at most 200 characters.",
  riders_name_check: "Enter the rider's name (up to 60 letters).",
  riders_phone_check: "The phone number is too long.",
  pre_orders_guest_name_check: "Enter the guest's name (up to 80 letters).",
  pre_orders_address_check: "The address can be at most 300 characters.",
  pre_orders_note_check: "The note can be at most 500 characters.",
  pre_orders_items_check: "A pre-order needs between 1 and 100 dishes.",
  pre_order_payments_amount_check: "Enter an amount greater than zero.",
  dining_tables_seats_check: "A table needs at least one seat.",
};

const GENERAL: Record<string, string> = {
  "23514": "One of the values is not allowed. Check the numbers and choices and try again.",
  "23505": "That already exists.",
  "23503": "This is linked to something that no longer exists. Refresh the page and try again.",
  "23502": "A required value is missing.",
  "22P02": "A value is not in the right format.",
  "22003": "A number is too large or too small.",
  "22007": "A date or time is not in the right format.",
  "22001": "A text is too long.",
};

const NO_PERMISSION = "You do not have permission to do that.";
const SIGN_IN_AGAIN = "Please sign in again.";
const NO_CONNECTION = "Could not reach the server. Check the internet connection.";

export function friendlyDbError(err: DbErrorLike | null | undefined): string {
  const raw = String(err?.message ?? "").trim();
  const code = String(err?.code ?? "");
  // Messages our own functions raise on purpose (code P0001) are plain already and always pass through.
  if (code !== "P0001") {
    if (/fetch failed|failed to fetch|network request failed|econnrefused|enotfound|etimedout|socket hang up/i.test(raw)) return NO_CONNECTION;
    if (code === "PGRST301" || /jwt expired|invalid jwt|jwt is expired/i.test(raw)) return SIGN_IN_AGAIN;
    if (code === "42501" || /row-level security|permission denied/i.test(raw)) return NO_PERMISSION;
  }
  const constraint = /constraint "([^"]+)"/.exec(raw)?.[1];
  if (constraint && KNOWN[constraint]) return KNOWN[constraint];
  const byText = /violates check constraint/.test(raw) ? "23514" : /violates unique constraint|duplicate key/.test(raw) ? "23505" : /violates foreign key/.test(raw) ? "23503" : /violates not-null/.test(raw) ? "23502" : /invalid input syntax/.test(raw) ? "22P02" : /numeric field overflow|out of range/.test(raw) ? "22003" : /value too long/.test(raw) ? "22001" : "";
  const general = GENERAL[code] ?? GENERAL[byText];
  if (general && (code !== "P0001")) return general;
  return raw.replace(/^[^]*?ERROR:\s*/, "").trim() || "Something went wrong. Please try again.";
}
