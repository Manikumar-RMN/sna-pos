import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { signOut } from "@/app/login/actions";
import { lockCounter } from "@/app/counter/actions";
import { NavLinks, NavRail, type NavItem } from "./nav-links";
import { ModuleSidebar, type SideGroup } from "./module-sidebar";
import { REPORT_LINKS, REPORT_SECTIONS, canSeeReportLink, groupReportLinks, sectionKey } from "./reports/_components/report-links";
import { IdleLock } from "./idle-lock";
import { OfflineSync } from "./offline-sync";
import { SwRegister } from "./sw-register";
import { OutletSwitcher, type OutletInfo } from "./outlet/outlet-switcher";
import { cookies } from "next/headers";
import { isLang, type LangCode } from "@/lib/i18n";
import { Dual, LangProvider } from "./lang";
import { TzProvider } from "./tz";
import { getLicence, licenceDate } from "@/lib/licence";
import { LicenceGate, LicenceNotice } from "./licence-notice";
import { SNA_CONTACT_EMAIL } from "@/lib/sna-contact";
import { AccountDate } from "./account-date";
import { readAccountDate } from "./account-date-action";

/** SNA POS mark: a steaming bowl on a saffron plate. */
function Mark({ size = 48 }: { size?: number }) {
  return (
    <span
      className="grid shrink-0 place-items-center rounded-full"
      style={{ width: size, height: size, background: "var(--color-accent)", boxShadow: "0 0 0 4px rgba(255,176,32,0.25)" }}
    >
      <svg width={size * 0.58} height={size * 0.58} viewBox="0 0 24 24" fill="none" stroke="#1B1208" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M3 12h18a9 6 0 0 1-18 0z" />
        <path d="M8 8c0-2 1.5-3 1.5-4.5M12 8c0-2 1.5-3 1.5-4.5M16 8c0-2 1.5-3 1.5-4.5" />
      </svg>
    </span>
  );
}

export default async function AppLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const user = await requireUser();
  const isCounter = !!user.device_name;
  // On a counter, opening a screen counts as activity (the database ends a PIN
  // session after 10 minutes without any).
  if (isCounter) await (await createClient()).rpc("pin_touch");

  // Show only the screens this role can use. The database enforces the real
  // rules; this just keeps the menu honest.
  const shiftsOn = !!(await (await createClient()).from("branch_settings").select("shifts_enabled").eq("branch_id", user.branch_id).maybeSingle()).data?.shifts_enabled;
  const canFinancial = can(user, "report.view_financial");
  // The Reports drop-down lists the same pages the Reports hub shows this role.
  const reportAccess = {
    financial: canFinancial,
    stock: has(user, "stock") && (can(user, "stock.view") || can(user, "stock.manage")),
    customers: can(user, "customer.view"),
    loyalty: has(user, "loyalty") && can(user, "customer.view"),
  };
  const reportItems = REPORT_LINKS.filter((r) => canSeeReportLink(r, reportAccess)).map((r) => ({ href: r.href, label: r.title, group: r.group }));
  // Modules the client bought: POS and Reports/MIS are switchable like the others.
  const posOn = has(user, "pos");
  const misOn = has(user, "reports_mis");
  const visibleLinksAll = [
    { href: "/dashboard", label: "Home", show: true },
    { href: "/owner", label: "Owner", show: misOn && (has(user, "owner_app") && can(user, "report.view_sales")) },
    { href: "/pos", label: "Bill", show: posOn && (can(user, "order.create")) },
    { href: "/captain", label: "Captain", show: posOn && (can(user, "order.create")) },
    { href: "/preorders", label: "Pre-orders", show: posOn && (can(user, "order.create")) },
    { href: "/deliveries", label: "Deliveries", show: posOn && (can(user, "order.create")) },
    { href: "/online-orders", label: "Online orders", show: posOn && (can(user, "order.create") && has(user, "open_api")) },
    { href: "/accounts", label: "Accounts", show: posOn && (can(user, "payment.take") || can(user, "customer.manage")) },
    { href: "/customers", label: "Customers", show: posOn && (can(user, "customer.view") || can(user, "customer.manage")) },
    { href: "/bills", label: "Bills", show: posOn && (true) },
    { href: "/kitchen", label: "Kitchen", show: posOn && (true) },
    { href: "/table-orders", label: "Table orders", show: posOn && (can(user, "order.create") && has(user, "qr_ordering")) },
    { href: "/shift", label: shiftsOn ? "Shift" : "Day close", show: posOn && (can(user, "shift.open") || can(user, "shift.close") || can(user, "cash.movement") || can(user, "day.close")) },
    { href: "/reports", label: "Reports", show: misOn && (can(user, "report.view_sales")) },
    { href: "/stock", label: "Stock", show: (can(user, "stock.manage") || can(user, "stock.view") || can(user, "stock.adjust")) && has(user, "stock") },
    { href: "/purchases", label: "Purchases", show: can(user, "stock.manage") && has(user, "stock") },
    { href: "/reservations", label: "Bookings", show: posOn && (can(user, "order.create") && has(user, "reservations")) },
    { href: "/loyalty", label: "Loyalty", show: posOn && (has(user, "loyalty") && (can(user, "payment.take") || can(user, "settings.manage"))) },
    { href: "/timesheets", label: "Timesheets", show: has(user, "timesheets") },
    // Menu, users and security profiles live inside Settings.
    { href: "/settings", label: "Settings", show: true },
    { href: "/help", label: "Help", show: true },
  ];
  const visibleLinks = visibleLinksAll.filter((l) => l.show);
  const links = visibleLinks.map(({ href, label }): NavItem => (href === "/reports" ? { href, label, children: reportItems } : { href, label }));

  // Everyone but a shared counter tablet gets the grouped side menu: one block per module they bought.
  const hospitality = !isCounter;
  const pick = (hrefs: string[]) => visibleLinks.filter((l) => hrefs.includes(l.href)).map(({ href, label }) => ({ href, label }));
  const sideGroups: SideGroup[] = [
    { key: "home", title: "Home", icon: "home", items: [{ href: "/dashboard", label: "Home" }] },
    {
      key: "pos", title: "POS", icon: "pos",
      items: pick(["/pos", "/captain", "/table-orders", "/kitchen", "/bills", "/preorders", "/deliveries", "/online-orders", "/accounts", "/customers", "/reservations", "/loyalty", "/shift", "/timesheets"]),
    },
    { key: "inventory", title: "Purchase and inventory", icon: "inventory", items: pick(["/stock", "/purchases"]) },
    {
      key: "reports", title: "Reports", icon: "reports",
      items: [
        ...pick(["/owner"]),
        ...(visibleLinks.some((l) => l.href === "/reports")
          ? REPORT_SECTIONS.filter((s) => groupReportLinks(reportAccess, s.key).length > 0).map((s) => ({
              href: s.href,
              label: s.title,
              // Every report page of this section lights this menu item.
              also: REPORT_LINKS.filter((r) => r.href !== "/reports" && sectionKey(r) === s.key).map((r) => r.href),
            }))
          : []),
      ],
    },
    { key: "setup", title: "Setup", icon: "setup", items: pick(["/settings"]) },
    { key: "help", title: "Help", icon: "help", items: pick(["/help"]) },
  ].filter((g) => g.items.length > 0);

  // The licence: a reminder from 15 days before the end date, read-only after it.
  const licence = await getLicence();
  const licenceEnds = licenceDate(licence.ends);

  const initial = (user.full_name || "?").trim().charAt(0).toUpperCase();
  // Second language under the English words: this device's choice, else the restaurant's.
  const deviceLang = (await cookies()).get("sna_lang2")?.value;
  const lang: LangCode | null = deviceLang === "none" ? null : isLang(deviceLang) ? deviceLang : isLang(user.second_language) ? user.second_language : null;
  // Several outlets: a picker in the header decides which outlet you are working in.
  const outlets =
    user.outlet_count > 1 ? ((await (await createClient()).rpc("my_outlets")).data as unknown as OutletInfo | null) : null;
  // The business date the next bill goes on, shown at the top right.
  const accountDate = await readAccountDate();

  const actions = (onGreen: boolean) =>
    isCounter ? (
      <>
        {outlets && <OutletSwitcher info={outlets} onGreen={onGreen} />}
        <IdleLock minutes={10} />
        <form action={lockCounter}>
          <button type="submit" className="btn btn-pay h-11 min-h-0 px-5 text-sm">
            <Dual text="Lock" />
          </button>
        </form>
      </>
    ) : (
      <>
        {outlets && <OutletSwitcher info={outlets} onGreen={onGreen} />}
        <Link
          href="/account/password"
          className="hidden text-xs font-semibold sm:inline"
          style={{ color: onGreen ? "rgba(255,255,255,0.8)" : "var(--color-ink-3)" }}
        >
          Change password
        </Link>
        <form action={signOut}>
          <button
            type="submit"
            className="min-h-11 rounded-xl border px-3.5 text-xs font-bold"
            style={
              onGreen
                ? { borderColor: "rgba(255,255,255,0.3)", color: "#fff" }
                : { borderColor: "var(--color-line)", background: "var(--color-surface)", color: "var(--color-ink)" }
            }
          >
            <Dual text="Sign out" />
          </button>
        </form>
      </>
    );

  return (
    <TzProvider timezone={user.timezone}>
    <LangProvider lang={lang}>
    <div className="min-h-screen md:flex md:gap-3 md:p-3">
      {/* Tablet and desktop: green icon rail */}
      <aside
        className={`kolam sticky top-3 hidden h-[calc(100vh-24px)] shrink-0 flex-col items-center gap-3 overflow-y-auto rounded-[22px] py-3.5 md:flex ${hospitality ? "w-[236px] px-2" : "w-[76px]"}`}
        style={{ background: "var(--color-brand)" }}
      >
        <Link href="/dashboard" aria-label="SNA POS home" className="mb-1">
          <Mark />
        </Link>
        {hospitality ? <ModuleSidebar groups={sideGroups} /> : <NavRail links={links} />}
        <div className="flex-1" />
        <div
          className="grid h-11 w-11 shrink-0 place-items-center rounded-full font-display font-bold text-white"
          style={{ background: "rgba(255,255,255,0.14)" }}
          title={`${user.full_name} · ${user.role_name}`}
        >
          {initial}
        </div>
      </aside>

      <div className="min-w-0 flex-1">
        {/* Phone: green top bar with the menu */}
        <header className="kolam rounded-b-[22px] px-4 pb-2 pt-3 text-white md:hidden" style={{ background: "var(--color-brand)" }}>
          <div className="flex items-center gap-3 pb-2">
            <Link href="/dashboard" className="flex items-center gap-2.5">
              <Mark size={36} />
              <div className="leading-tight">
                <div className="font-display text-sm font-bold">SNA POS</div>
                <div className="text-[11px]" style={{ color: "rgba(255,255,255,0.75)" }}>
                  {user.trading_name}
                </div>
              </div>
            </Link>
            <div className="ml-auto flex items-center gap-2">
              <AccountDate initial={accountDate} onGreen />
              {actions(true)}
            </div>
          </div>
          <NavLinks links={links} />
        </header>

        {/* Tablet and desktop: restaurant name and who is signed in */}
        <header className="hidden items-center gap-3 px-1 pb-1 pt-1 md:flex">
          <div className="leading-tight">
            <div className="font-display text-xl font-bold">{user.trading_name}</div>
            <div className="text-[13px] font-semibold" style={{ color: "var(--color-ink-3)" }}>
              {user.full_name} · {user.role_name}
              {isCounter ? ` · ${user.device_name}` : ""}
            </div>
          </div>
          <div className="ml-auto flex items-center gap-3">
            <AccountDate initial={accountDate} onGreen={false} />
            {actions(false)}
          </div>
        </header>

        <main className="px-4 py-5 md:px-1 md:py-3">
          <OfflineSync />
          <SwRegister />
          <LicenceNotice
            state={licence.state}
            reason={licence.reason ?? null}
            endsText={licenceEnds}
            daysLeft={licence.days_left ?? null}
            remind={!!licence.remind}
            restaurantId={user.restaurant_id}
            contact={SNA_CONTACT_EMAIL}
          />
          <LicenceGate locked={licence.state === "locked"} reason={licence.reason ?? null} endsText={licenceEnds} contact={SNA_CONTACT_EMAIL}>
            {children}
          </LicenceGate>
        </main>
      </div>
    </div>
    </LangProvider>
    </TzProvider>
  );
}
