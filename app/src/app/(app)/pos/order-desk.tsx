"use client";

import { useEffect, useRef, useState, type ComponentProps } from "react";
import { useRouter } from "next/navigation";
import { TableStrip } from "../floor/table-strip";
import type { FloorRow } from "@/lib/table-status";
import { deskUrl, destinationLabel, planSwitch, selectionKey } from "@/lib/order-desk";
import { useOnline } from "@/lib/use-online";
import { PosTerminal, type AddTo, type KotDone } from "./pos-terminal";
import { KotPrinter } from "./kot/[orderId]/kot-printer";
import { ScreenSwitch } from "./screen-switch";

type TerminalBase = Omit<ComponentProps<typeof PosTerminal>, "addTo" | "lockedTable" | "inline" | "onKotDone" | "askCovers" | "onCartCount" | "deskKey" | "deskTableId" | "stashRef">;

export type DeskSelection =
  | { kind: "counter" }
  | { kind: "table"; tableId: string; number: string; /** the table already has an open bill: this is a separate one */ separate: boolean }
  | { kind: "bill"; billId: string; tableId: string | null };

/** What a tap on a table / counter means for the cart that follows: the key of the next screen, whether it is a running bill, its name. */
type DeskSelectionTarget = {
  key: string;
  runningBill: boolean;
  label: Parameters<typeof destinationLabel>[0];
};

export type DeskTable = { id: string; number: string; seats: number | null; openBills: { id: string; billNumber: string; total: number }[] };

/**
 * The single order screen (/pos): the coloured table strip on top, the menu and the new items on the left (PosTerminal), and the
 * running bill of the chosen table on the right (`billPanel`, the server-rendered <BillScreen embedded>). It holds only the choice
 * of table / bill (in the address: ?table= / ?bill=) and the kitchen-ticket overlay; every amount, tax and payment is still worked
 * out by the same database functions as on the classic screens. On phones the two sides are tabs: Order | Bill.
 */
export function OrderDesk({
  terminal,
  currency,
  tables,
  floor,
  showStrip,
  selection,
  addTo,
  billPanel,
  canOpenPrice,
  kotMeta,
}: {
  terminal: TerminalBase;
  currency: string;
  tables: DeskTable[];
  floor: FloorRow[];
  showStrip: boolean;
  selection: DeskSelection;
  addTo: AddTo | null;
  /** The server-rendered bill beside the menu (null: no bill is chosen). */
  billPanel: React.ReactNode;
  canOpenPrice: boolean;
  kotMeta: { timezone: string; printMm: number; largePrint: boolean };
}) {
  const router = useRouter();
  const online = useOnline();
  const hasBill = selection.kind === "bill" && !!billPanel;
  const selKey = selectionKey(selection);
  const currentUrl = deskUrl(selection.kind === "counter" ? { kind: "counter" } : selection.kind === "table" ? { kind: "table", tableId: selection.tableId } : { kind: "bill", billId: selection.billId });

  const [tab, setTab] = useState<"order" | "bill">(hasBill ? "bill" : "order");
  const [cartCount, setCartCount] = useState(0);
  const [nonce, setNonce] = useState(0);
  const [kot, setKot] = useState<KotDone | null>(null);
  /** The terminal offers a function that keeps the unsent cart for the next selection. */
  const stashRef = useRef<((destKey: string, toRunningBill: boolean) => "kept" | "empty" | "busy") | null>(null);
  /** "Order moved to Table 4": set when the items followed, cleared after a few seconds, on the next change or on send. */
  const [notice, setNotice] = useState<string | null>(null);
  const carriedHere = useRef(false);

  // A new table or bill chosen: phones show the bill first when there is one (the order first when items followed).
  useEffect(() => {
    setTab(hasBill && !carriedHere.current ? "bill" : "order");
    carriedHere.current = false;
    setCartCount(0);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selKey]);

  // "+ Add items" in the bill panel: show the menu.
  useEffect(() => {
    const show = () => {
      setTab("order");
      document.getElementById("order-menu")?.scrollIntoView({ behavior: "smooth", block: "start" });
    };
    window.addEventListener("sna-desk-order", show);
    return () => window.removeEventListener("sna-desk-order", show);
  }, []);

  // Fresh tables and bill every 20 seconds, only while the screen is visible and the device has internet (a refresh that
  // cannot reach the server would make the browser reload the page and lose the items in the cart).
  useEffect(() => {
    const t = setInterval(() => {
      if (document.visibilityState === "visible" && navigator.onLine && !kot) router.refresh();
    }, 20_000);
    return () => clearInterval(t);
  }, [router, kot]);

  useEffect(() => {
    if (!notice) return;
    const t = setTimeout(() => setNotice(null), 8000);
    return () => clearTimeout(t);
  }, [notice]);

  /**
   * Moves to another table / bill / counter at any time. Unsent items follow (the terminal keeps them in this tab's sessionStorage and
   * the next screen takes them once): nothing is saved before Send KOT, so nothing is moved or doubled on the server. Only without
   * internet (the other table cannot load) is staff asked first.
   */
  function go(url: string, target: DeskSelectionTarget) {
    if (url === currentUrl) return;
    const plan = planSwitch({ itemsInCart: cartCount, online, destLabel: destinationLabel(target.label) });
    if (plan.action === "confirm") {
      if (!window.confirm(plan.question)) return;
      router.push(url);
      return;
    }
    if (plan.action === "carry") {
      const kept = stashRef.current?.(target.key, target.runningBill) ?? "empty";
      if (kept === "busy") {
        setNotice("This order is being sent. Wait a moment, then pick the table.");
        return;
      }
      if (kept === "kept") {
        carriedHere.current = true;
        setNotice(plan.notice);
      }
    } else setNotice(null);
    router.push(url);
  }

  const selectedTableId = selection.kind === "table" ? selection.tableId : selection.kind === "bill" ? selection.tableId : null;
  const classicAfter = selection.kind === "bill" ? `/bills/${selection.billId}` : "/pos";

  return (
    <div>
      <div className="no-print mb-3 flex flex-wrap items-center justify-between gap-2">
        <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
          {!online && (
            <span className="rounded-full px-2.5 py-0.5 font-bold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
              No internet: open bills and tables need the connection. Counter bills paid at once still work.
            </span>
          )}
        </div>
        <ScreenSwitch to="classic" after={classicAfter} />
      </div>

      {showStrip && (
        <div className="mb-4 max-h-60 overflow-y-auto">
          <TableStrip
            tables={tables}
            floor={floor}
            currency={currency}
            compact
            selectedTableId={selectedTableId}
            selectedBillId={selection.kind === "bill" ? selection.billId : null}
            refreshMs={0}
            onSelect={(tableId, billId) => {
              const t = tables.find((x) => x.id === tableId);
              const label = { kind: "table", number: t?.number ?? "" } as const;
              if (billId) go(deskUrl({ kind: "bill", billId }), { key: selectionKey({ kind: "bill", billId }), runningBill: true, label: { kind: "bill", tableNumber: t?.number ?? null } });
              else go(deskUrl({ kind: "table", tableId }), { key: selectionKey({ kind: "table", tableId }), runningBill: false, label });
            }}
            counter={{ selected: selection.kind === "counter", onSelect: () => go("/pos", { key: "counter", runningBill: false, label: { kind: "counter" } }) }}
          />
        </div>
      )}

      {notice && (
        <div role="status" aria-live="polite" className="no-print mb-3 rounded-lg px-3 py-2 text-sm font-bold" style={{ background: "var(--color-brand-soft)", color: "var(--color-ink)" }}>
          {notice}
        </div>
      )}

      {hasBill && (
        <div className="no-print mb-3 grid grid-cols-2 gap-2 lg:hidden" role="tablist" aria-label="Order or bill">
          {(["order", "bill"] as const).map((k) => (
            <button
              key={k}
              role="tab"
              aria-selected={tab === k}
              onClick={() => setTab(k)}
              className="btn border text-sm"
              style={{
                borderColor: tab === k ? "var(--color-brand)" : "var(--color-line)",
                background: tab === k ? "var(--color-brand)" : "var(--color-surface)",
                color: tab === k ? "#fff" : "var(--color-ink-2)",
              }}
            >
              {k === "order" ? `Order${cartCount > 0 ? ` (${cartCount})` : ""}` : "Bill"}
            </button>
          ))}
        </div>
      )}

      <div className={hasBill ? "grid gap-4 lg:grid-cols-[400px_minmax(0,1fr)]" : ""}>
        <div id="order-menu" className={hasBill && tab !== "order" ? "hidden lg:block" : undefined}>
          <PosTerminal
            key={`${selKey}:${nonce}`}
            {...terminal}
            addTo={addTo}
            lockedTable={selection.kind === "table" ? { id: selection.tableId, number: selection.number, separate: selection.separate } : null}
            inline
            askCovers
            canOpenPrice={canOpenPrice}
            onCartCount={setCartCount}
            deskKey={selKey}
            deskTableId={selection.kind === "bill" ? selection.tableId : null}
            stashRef={stashRef}
            onKotDone={setKot}
          />
        </div>
        {hasBill && (
          <aside className={`${tab === "bill" ? "" : "hidden"} lg:order-first lg:block lg:sticky lg:top-4 lg:max-h-[calc(100vh-2rem)] lg:self-start lg:overflow-y-auto`} aria-label="Running bill">
            {billPanel}
          </aside>
        )}
      </div>

      {kot && (
        <KotPrinter
          key={kot.orderId}
          embedded
          orderId={kot.orderId}
          billNumber={kot.billNumber}
          where={kot.where}
          token={kot.token}
          backToBill={kot.kind === "add"}
          timezone={kotMeta.timezone}
          printMm={kotMeta.printMm}
          largePrint={kotMeta.largePrint}
          onDone={() => {
            const done = kot;
            setKot(null);
            setNotice(null);
            // A fresh order form (the sent items are on the bill now), and the bill beside it with the new total.
            setNonce((n) => n + 1);
            setCartCount(0);
            setTab("bill");
            if (done) router.replace(deskUrl({ kind: "bill", billId: done.orderId }));
            router.refresh();
          }}
        />
      )}
    </div>
  );
}
