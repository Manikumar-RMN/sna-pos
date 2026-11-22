"use client";

import { useEffect, useState, type ReactNode } from "react";

/**
 * On the single order screen a table order is a waiter's screen until the bill is made: sent KOTs, the order so far and
 * "+ Add items". The billing options (customer tax number, loyalty, charge to account, preview, settle) show once the
 * cashier presses Bill, or once the order has a real bill number. Elsewhere (not embedded) everything shows as before.
 */
export function useBillingMode(orderId: string, billed: boolean, embedded: boolean): boolean {
  const [on, setOn] = useState(billed);
  useEffect(() => {
    setOn(billed);
  }, [orderId, billed]);
  useEffect(() => {
    if (!embedded) return;
    const open = () => setOn(true);
    const numbered = (e: Event) => {
      const d = (e as CustomEvent<{ orderId?: string }>).detail;
      if (!d?.orderId || d.orderId === orderId) setOn(true);
    };
    window.addEventListener("sna-desk-check", open);
    window.addEventListener("sna-bill-numbered", numbered);
    return () => {
      window.removeEventListener("sna-desk-check", open);
      window.removeEventListener("sna-bill-numbered", numbered);
    };
  }, [orderId, embedded]);
  return !embedded || on;
}

/**
 * Hides its content before the bill is made. The content stays on the page (hidden, still printable) because the Bill
 * screen's Print, Estimate and Company buttons talk to the panels inside it.
 */
export function BillingOnly({ orderId, billed, embedded, always = false, children }: { orderId: string; billed: boolean; embedded: boolean; always?: boolean; children: ReactNode }) {
  const show = useBillingMode(orderId, billed, embedded);
  return <div className={show || always ? "contents" : "hidden print:contents"}>{children}</div>;
}
