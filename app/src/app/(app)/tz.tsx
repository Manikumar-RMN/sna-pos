"use client";

import { createContext, useContext } from "react";

const TzContext = createContext<string>("UTC");

/** Makes the restaurant's own time zone (Settings -> Company) available to every screen inside the app. */
export function TzProvider({ timezone, children }: { timezone: string; children: React.ReactNode }) {
  return <TzContext.Provider value={timezone || "UTC"}>{children}</TzContext.Provider>;
}

/** The restaurant's time zone: times are shown, and "today" is worked out, in this zone, never the device's. */
export function useTz(): string {
  return useContext(TzContext);
}
