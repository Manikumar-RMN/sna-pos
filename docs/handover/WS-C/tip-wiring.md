# WS-C -> WS-A: wire the tip box into the payment panel
New files (already in the branch, do not edit): `bills/tip.ts` (parseTip, suggestTip, tipForRequest, tipError, tipText; unit tested) and `bills/tip-field.tsx` (`<TipField>`).

## 1. bills/actions.ts, `payBill`
Anchor: the `input` type and the `supabase.rpc("pay_order", {...})` call.
```ts
export async function payBill(input: {
  orderId: string;
  paymentMethodId: string;
  tendered: number | null;
  amount: number | null;
  reference?: string | null;
  clientRef?: string;
  /** Optional tip, a memo recorded next to the payment (never part of the bill). Omit for none. */
  tip?: number;
}): Promise<ActionResult> {
  ...
  const { data, error } = await supabase.rpc("pay_order", {
    ...existing arguments...,
    p_tip: input.tip && input.tip > 0 ? input.tip : undefined,
  });
```
In the success message, optionally append: `const tipText = Number((data as { tip?: number } | null)?.tip ?? 0) > 0 ? ` Tip ${Number(...).toFixed(2)} recorded.` : "";`

## 2. bills/bill-actions.tsx, payment panel (anchor: the `Cash received` input / the `btn btn-pay` button near line 334-358)
```tsx
import { TipField } from "./tip-field";
import { tipError, tipForRequest } from "./tip";
...
const [tip, setTip] = useState("");
...
// directly above the pay button:
<TipField value={tip} onChange={setTip} base={due} disabled={pending} offline={!navigator.onLine /* or the screen's own offline flag */} />
// pay button: add to disabled:   || tipError(tip) !== null
// payBill({... , tip: tipForRequest(tip) })
// after success (the second argument of run(...) that already resets payRef): setTip("");
```
The tip is NOT added to `due`, `Take ...`, change or the cash-received check (it is a memo: the cash drawer and day close never include it).

## 3. Counter "Charge" in the one-screen /pos
`create_order` is unchanged and takes no tip. For a tip at the counter: create the bill unpaid, then call `payBill` with `tip` (same two-step flow the plan describes), or show the tip box on the bill panel after the KOT. Offline bills carry no tip (hide the box, `offline` prop).
