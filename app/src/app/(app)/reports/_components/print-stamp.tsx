"use client";

import { useEffect, useState } from "react";

/**
 * "Printed on ..." time for the print header. Worked out in the browser when the page opens and again just
 * before printing, so the time is the real print time and not the time the page was built on the server.
 */
export function PrintStamp({ timezone }: { timezone: string }) {
  const [text, setText] = useState("");
  useEffect(() => {
    const stamp = () => {
      try {
        setText(new Date().toLocaleString("en-IN", { timeZone: timezone, day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" }));
      } catch {
        setText(new Date().toLocaleString("en-IN"));
      }
    };
    stamp();
    window.addEventListener("beforeprint", stamp);
    return () => window.removeEventListener("beforeprint", stamp);
  }, [timezone]);
  return <span>{text}</span>;
}
