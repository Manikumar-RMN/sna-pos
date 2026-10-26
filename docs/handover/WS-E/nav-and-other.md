# Nothing needed in nav / layout / sections for WS-E

The three new reports are listed through `reports/_components/report-links.ts` (owned by WS-E): the Reports drop-down and the hub pick them up
automatically (Cover analysis and Tips under Sales, Reprints under Audit). `layout.tsx` / `nav-links.tsx` need no change.
Permissions: Cover analysis and Reprints need `report.view_sales`; Tips needs `report.view_sales` + `report.view_financial`
(the hub hides financial links for people without it). Cover analysis hides the money columns for people without `report.view_financial`.

# e2e-ui note (WS-F)
If the 44-screen sweep in `app/e2e-ui/screens.ui.test.ts` lists report routes, add `/reports/covers`, `/reports/reprints`, `/reports/tips`.

# Daily email (F10)
Covers and tips lines were NOT added to `app.report_summary` / `lib/report-email.ts`. `app.report_summary` is a large function defined in 081 and
rewritten in 089; adding lines means replacing it whole (and a matching `ReportSummary` type + cleanSummary + text and HTML bodies),
which is not a small safe change. Do it later as its own change after 133 and 138 are live.
