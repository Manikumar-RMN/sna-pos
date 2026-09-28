"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { removePushSubscription, savePushSubscription } from "./actions";

export function LiveRefresh({ seconds }: { seconds: number }) {
  const router = useRouter();
  useEffect(() => {
    const t = setInterval(() => document.visibilityState === "visible" && router.refresh(), seconds * 1000);
    return () => clearInterval(t);
  }, [router, seconds]);
  return null;
}

type InstallEvent = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> };

/** "Install app" on Android/desktop Chrome; on iPhone, a hint to use Share → Add to Home Screen. */
export function InstallButton() {
  const [evt, setEvt] = useState<InstallEvent | null>(null);
  const [ios, setIos] = useState(false);
  const [installed, setInstalled] = useState(false);
  useEffect(() => {
    setInstalled(window.matchMedia("(display-mode: standalone)").matches);
    setIos(/iphone|ipad|ipod/i.test(navigator.userAgent));
    const h = (e: Event) => {
      e.preventDefault();
      setEvt(e as InstallEvent);
    };
    window.addEventListener("beforeinstallprompt", h);
    return () => window.removeEventListener("beforeinstallprompt", h);
  }, []);
  if (installed) return null;
  if (evt)
    return (
      <button className="btn btn-pay h-10 min-h-0 px-4 text-sm" onClick={() => evt.prompt().then(() => setEvt(null))}>
        Install app
      </button>
    );
  if (ios) return <span className="max-w-[10rem] text-right text-xs" style={{ color: "var(--color-ink-3)" }}>To install: Share → Add to Home Screen</span>;
  return null;
}

function urlB64ToUint8Array(b64: string) {
  const pad = "=".repeat((4 - (b64.length % 4)) % 4);
  const raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
}

/** Turns phone alerts on or off for this device. */
export function AlertsSwitch({ vapidKey }: { vapidKey: string }) {
  const [state, setState] = useState<"unknown" | "off" | "on" | "blocked" | "unsupported">("unknown");
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!("serviceWorker" in navigator) || !("PushManager" in window) || !vapidKey) return setState("unsupported");
    if (Notification.permission === "denied") return setState("blocked");
    navigator.serviceWorker.ready.then((reg) => reg.pushManager.getSubscription()).then((s) => setState(s ? "on" : "off"));
  }, [vapidKey]);

  async function turnOn() {
    setMsg(null);
    try {
      const perm = await Notification.requestPermission();
      if (perm !== "granted") return setState("blocked");
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlB64ToUint8Array(vapidKey) });
      const j = sub.toJSON() as { endpoint: string; keys: { p256dh: string; auth: string } };
      const r = await savePushSubscription(j.endpoint, j.keys.p256dh, j.keys.auth);
      if (!r.ok) {
        await sub.unsubscribe();
        return setMsg(r.error);
      }
      setState("on");
    } catch (e) {
      setMsg((e as Error).message);
    }
  }
  async function turnOff() {
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    if (sub) {
      await removePushSubscription(sub.endpoint);
      await sub.unsubscribe();
    }
    setState("off");
  }

  return (
    <section className="card flex flex-wrap items-center justify-between gap-2 p-4">
      <div className="text-sm">
        <b>Alerts on this phone</b>
        <div style={{ color: "var(--color-ink-3)" }}>
          {state === "on" && "On — you will get voids, refunds, discounts, cash differences and day close."}
          {state === "off" && "Off."}
          {state === "blocked" && "Blocked in this browser's settings. Allow notifications for this site, then try again."}
          {state === "unsupported" && "This browser cannot show alerts. On iPhone, install the app first (Share → Add to Home Screen)."}
        </div>
      </div>
      {state === "off" && <button className="btn btn-primary" onClick={turnOn}>Turn on</button>}
      {state === "on" && <button className="btn border" style={{ borderColor: "var(--color-line)" }} onClick={turnOff}>Turn off</button>}
      {msg && <p role="alert" className="w-full text-sm font-semibold" style={{ color: "var(--color-bad)" }}>{msg}</p>}
    </section>
  );
}
