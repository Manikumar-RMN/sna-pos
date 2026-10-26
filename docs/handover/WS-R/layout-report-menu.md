# For WS-P: Reports drop-down in the top menu (APP/layout.tsx)

Target: `app/src/app/(app)/layout.tsx`, the line that builds `reportItems` (about L49) and its import (L7).

`REPORT_LINKS[].need` now has two more values, `"stock"` and `"customers"`. The old filter
`r.need === "sales" || canFinancial` would show the stock and customer reports to every financial user. Replace it with the shared helper
(already exported from report-links.ts by WS-R):

```ts
import { REPORT_LINKS, canSeeReportLink } from "./reports/_components/report-links";
...
const reportAccess = {
  financial: canFinancial,
  stock: has(user, "stock") && can(user, "stock.view"),
  customers: can(user, "customer.view"),
};
const reportItems = REPORT_LINKS.filter((r) => canSeeReportLink(r, reportAccess)).map((r) => ({ href: r.href, label: r.title, group: r.group }));
```

Same rule as the hub (APP/reports/page.tsx). Until this is applied, `npm run build` still passes, but the drop-down offers the new links to
financial users who lack stock.view / customer.view (the page then shows a plain "your role does not include" message).

Note: the Reports hub and the drop-down only exist for people with `report.view_sales`. A chef who has `stock.view` but not `report.view_sales`
can open the three stock reports that do not need sales (stock-on-hand, stock-movement, wastage) by URL, but the hub is not shown to them.
If the owner wants a chef to find them, WS-I can add links to these pages from the Stock screen.
