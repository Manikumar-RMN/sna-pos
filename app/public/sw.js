/* SNA POS service worker: keeps the Billing and Kitchen screens usable when the internet drops.
   Screens are always fetched fresh when online; the last copy is used only when offline. */
const PAGES = "sna-pages-v1";
const STATIC = "sna-static-v1";
const OFFLINE_PAGES = ["/pos", "/kitchen"];

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => ![PAGES, STATIC].includes(k)).map((k) => caches.delete(k)))).then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Built app files never change once published: cache them.
  if (url.pathname.startsWith("/_next/static/")) {
    event.respondWith(
      caches.open(STATIC).then(async (c) => {
        const hit = await c.match(req);
        if (hit) return hit;
        const res = await fetch(req);
        if (res.ok) c.put(req, res.clone());
        return res;
      }),
    );
    return;
  }

  // Screens: network first; keep a copy of Billing and Kitchen for when the internet is down.
  if (req.mode === "navigate") {
    // Only the plain screen is kept: "/pos?add=…" (adding to one bill) must not replace the offline copy of Billing.
    const keep = url.search === "" && OFFLINE_PAGES.some((p) => url.pathname === p);
    event.respondWith(
      fetch(req)
        .then((res) => {
          if (keep && res.ok && !res.redirected) caches.open(PAGES).then((c) => c.put(url.pathname, res.clone()));
          return res;
        })
        .catch(async () => {
          const c = await caches.open(PAGES);
          return (
            (await c.match(url.pathname)) ||
            (await c.match("/pos")) ||
            new Response("<h1>No internet</h1><p>Open Billing once while online so it works offline next time.</p>", {
              headers: { "Content-Type": "text/html" },
            })
          );
        }),
    );
  }
});

/* Owner alerts: show the push message and open the owner screen when tapped. */
self.addEventListener("push", (event) => {
  let d = {};
  try {
    d = event.data ? event.data.json() : {};
  } catch (e) {
    d = { title: "SNA POS", body: event.data ? event.data.text() : "" };
  }
  event.waitUntil(
    self.registration.showNotification(d.title || "SNA POS", {
      body: d.body || "",
      icon: "/icon-192.png",
      badge: "/icon-192.png",
      data: { url: d.url || "/owner" },
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || "/owner";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if (new URL(c.url).pathname === url && "focus" in c) return c.focus();
      }
      return self.clients.openWindow(url);
    }),
  );
});
