# Repeat last order: wiring into PosTerminal (WS-A)

Built by WS-B: `pos/repeat-round.ts` (`"use server"`, `loadLastRound(orderId)`), `lib/repeat-round.ts` (pure `mapRoundToMenu`,
`buildRoundLines`, `pickRoundTickets`), tests in `lib/__tests__/repeat-round.test.ts`.

What it does: reads the newest kitchen round of an OPEN bill (tickets made within 60 s of the newest one, same grouping as the KOT
screen), returns plain lines `{ p, nm, o, q, n }` (product id, name, option ids, quantity, note). Prices are never returned or copied:
the lines are mapped onto the CURRENT menu, so the new items are priced as the menu says now (and by the database when sent).
Items or options no longer on the menu are skipped and named in a message. Needs `order.create`. No audit row.

## Where to show the button

In add-to-bill mode only (`addTo` set; in the one-screen layout: whenever an open bill is selected), next to the cart heading
("Items to add"). Needs internet: hide or disable when `offline`.

## Code in pos/pos-terminal.tsx

```tsx
import { loadLastRound } from "./repeat-round";
import { mapRoundToMenu } from "@/lib/repeat-round";

// inside PosTerminal (uses existing: menu, packing, addTo, cart/setCart, setError, lineKey, CartLine, offline):
const [repeating, setRepeating] = useState(false);

async function repeatLastRound() {
  if (!addTo || offline || repeating) return;
  setRepeating(true);
  setError(null);
  try {
    const res = await loadLastRound(addTo.id);
    if (!res.ok) return setError(res.error);
    if (res.lines.length === 0) return setError("Nothing has been sent to the kitchen on this bill yet.");
    const mapped = mapRoundToMenu(res.lines, menu, packing?.productId ?? null);
    if (mapped.lines.length === 0) return setError(mapped.message ?? "None of those items can be repeated.");
    setCart((c) => {
      const next = { ...c };
      for (const l of mapped.lines) {
        const key = lineKey(l.item.id, l.options);
        const cur = next[key];
        // same dish + options already in the cart: add the quantity, as tapping it again would
        next[key] = cur ? { ...cur, qty: cur.qty + l.qty } : { key, item: l.item, options: l.options, qty: l.qty, note: l.note };
      }
      return next;
    });
    if (mapped.message) setError(mapped.message);   // shown like the "menu changed" message of takeCarried
  } catch {
    setError("Could not reach the server. Check the internet and try again.");
  } finally {
    setRepeating(false);
  }
}

// button (anchor: in the header row of the cart card, `<div className="text-sm font-bold">{addTo ? "Items to add" : "Current bill"}</div>`):
{addTo && !offline && (
  <button type="button" className="btn border px-2 text-xs" style={{ borderColor: "var(--color-line)" }} onClick={repeatLastRound} disabled={repeating || pending}>
    {repeating ? "Loading…" : "Repeat last order"}
  </button>
)}
```

If the item is sold in sizes (`variantOf`), the menu list contains the size as its own entry with the same product id the bill holds,
so `mapRoundToMenu` finds it; no special case. Held ("hold and fire") state is NOT repeated (the first round is already fired).

## e2e-ui (WS-A / WS-F)

"Repeat then send creates a new kitchen ticket": open a bill with one KOT, press "Repeat last order", confirm the cart shows the same
items at today's prices, press the add button, expect `/pos/kot/<id>?then=bill` and two tickets on the bill.
