/** What the server noted about a bill made offline (orders.offline_flags), in plain words for the bill screen. */
export type OfflineFlag = { flag: string; [k: string]: unknown };

const n = (x: unknown) => (typeof x === "number" ? x.toFixed(2) : String(x ?? ""));

export function describeOfflineFlags(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const f of raw as OfflineFlag[]) {
    switch (f?.flag) {
      case "price_corrected":
        out.push(`The till charged ${n(f.offline_price)} for ${String(f.item)}, which was never its price. The bill uses the real price, ${n(f.menu_price)}.`);
        break;
      case "discount_removed":
        out.push(`A discount of ${n(f.amount)} was given on the till by someone without the right to discount. It was not allowed.`);
        break;
      case "open_price_no_right":
        out.push(`${String(f.item)} is an open-price item. It was billed offline at ${n(f.price)} by someone without the right to enter prices. The bill was kept at that price: please check it.`);
        break;
      case "method_unknown":
        out.push("The payment method on the till was not recognised, so the payment was recorded as cash.");
        break;
      case "total_differs":
        out.push(`The total on the till (${n(f.printed)}) is not the bill total (${n(f.recorded)}).`);
        break;
      case "device_clock_ahead":
        out.push("The till's clock was ahead of the real time. The real time was used.");
        break;
      case "older_than_7_days":
        out.push("This bill was made more than 7 days before it reached the server.");
        break;
      case "price":
      case "discount_without_right":
        out.push(f.flag === "price" ? `Price on the till for ${String(f.item)} was ${n(f.offline_price)}; menu price ${n(f.menu_price)}.` : `A discount of ${n(f.amount)} was given without the right to discount.`);
        break;
      default:
        if (f?.flag) out.push(String(f.flag));
    }
  }
  return out;
}
