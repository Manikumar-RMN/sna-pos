# WS-I -> WS-P: Stock nav link for stock.view / stock.adjust holders

Target: app/src/app/(app)/layout.tsx, line ~64 (the `/stock` entry). Purchases stays manage-only.

Replace
    { href: "/stock", label: "Stock", show: can(user, "stock.manage") && has(user, "stock") },
with
    { href: "/stock", label: "Stock", show: (can(user, "stock.manage") || can(user, "stock.view") || can(user, "stock.adjust")) && has(user, "stock") },

Also (e2e-ui): add routes /stock and /stock/count (needs stock.adjust or stock.manage).
