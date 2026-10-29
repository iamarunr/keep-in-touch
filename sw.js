/* Service worker: makes the app open instantly and work offline.
 * App files: served from cache, refreshed in the background (stale-while-revalidate).
 * Bump VERSION whenever you want every installed copy to drop its old cache. */
const VERSION = "kit-v7";
// Files shared to the app (Android share sheet) wait here until the Import screen picks them up.
// Its own cache, so a version bump in between doesn't drop a share.
const SHARE_CACHE = "kit-share";
const SHARED_KEY = "./shared-contacts";
const SHELL = [
  "./",
  "./store.js",
  "./manifest.webmanifest",
  "./icons/icon.svg",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/maskable-512.png",
  "./icons/apple-touch-icon.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== VERSION && k !== SHARE_CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);
  // Web Share Target: there's no server, so take the POSTed file here, keep it for the page,
  // and send the browser on to Import. A 303 turns the POST into a plain GET of the app,
  // which the shell below answers.
  if (req.method === "POST" && url.origin === self.location.origin && url.pathname.endsWith("/share-target")) {
    event.respondWith((async () => {
      try {
        const form = await req.formData();
        const texts = await Promise.all(form.getAll("contacts").filter((f) => f && f.text).map((f) => f.text()));
        if (texts.length) {
          const cache = await caches.open(SHARE_CACHE);
          await cache.put(SHARED_KEY, new Response(texts.join("\n"), { headers: { "Content-Type": "text/vcard" } }));
        }
      } catch (e) {}
      return Response.redirect(new URL("./#import", self.registration.scope).href, 303);
    })());
    return;
  }
  if (req.method !== "GET") return;
  const sameOrigin = url.origin === self.location.origin;
  const isFont = url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com";
  if (!sameOrigin && !isFont) return;

  event.respondWith(
    caches.open(VERSION).then(async (cache) => {
      // Navigations (opening the app, with or without #hash) all resolve to the app shell.
      // Keyed on "./" rather than "./index.html": hosts like Cloudflare Pages redirect
      // /index.html to /, and a redirected response can't answer a navigation.
      const key = req.mode === "navigate" ? "./" : req;
      const cached = await cache.match(key, { ignoreSearch: req.mode === "navigate" });
      const network = fetch(req)
        .then((res) => {
          if (res && (res.ok || res.type === "opaque")) cache.put(key, res.clone());
          return res;
        })
        .catch(() => cached);
      return cached || network;
    })
  );
});
