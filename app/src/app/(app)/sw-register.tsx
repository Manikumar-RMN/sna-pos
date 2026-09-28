"use client";

import { useEffect } from "react";

/** Lets the billing screen open again after a refresh with no internet. */
export function SwRegister() {
  useEffect(() => {
    if (!("serviceWorker" in navigator)) return;
    navigator.serviceWorker.register("/sw.js").catch(() => {});
  }, []);
  return null;
}
