"use client";

import { useSyncExternalStore } from "react";

function subscribe(onChange: () => void) {
  window.addEventListener("online", onChange);
  window.addEventListener("offline", onChange);
  return () => {
    window.removeEventListener("online", onChange);
    window.removeEventListener("offline", onChange);
  };
}

/**
 * Whether this device says it has internet. The server render and the first paint say "online" (so nothing flashes disabled);
 * the browser's own answer follows at once. The browser only knows the device is connected, not that the server answers, so
 * the actions themselves still handle a failed call.
 */
export function useOnline(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => navigator.onLine,
    () => true,
  );
}
