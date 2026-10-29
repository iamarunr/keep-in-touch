# Handoff: Keep in Touch

Status as of **2026-10-29**. Read this first when picking the project back up.

## What this is

A personal keep-in-touch app, based on Derek Sivers' "Stay in touch with hundreds of people" (https://sive.rs/hundreds) and "Why you need a database" (https://sive.rs/dbt). People go in tiers: **A** every 3 weeks, **B** every 2 months, **C** every 6 months, **D** once a year. The app shows who's due, lets you log a check-in, and sets the next date from the tier.

- **Live:** https://keep-in-touch-d58.pages.dev/ (Cloudflare Pages, auto-deploys on push to `main`)
- **Repo:** https://github.com/iamarunr/keep-in-touch
- **Version shown in Settings:** 7 (`APP_VERSION` in index.html, `VERSION` in sw.js is `kit-v7`)

## How we got here

1. **Idea.** Went through sive.rs for buildable ideas; the keep-in-touch system won.
2. **v0: claude.ai artifact.** First built as a hosted Claude artifact using claude.ai's storage. It still exists but is **retired**; its data is separate and not synced with this one.
3. **Standalone app.** Rebuilt as an installable web app (PWA), on purpose with **no server**:
   - Storage is **on the device** (IndexedDB via `store.js`). There's no account and no sync.
   - Moving between devices is done with **backup and restore** (JSON). Settings can share a backup straight to Drive (Web Share API) where supported.
4. **Phone contacts.**
   - Android Chrome uses the **Contact Picker API**, so the app only gets the people you pick.
   - iPhone Safari doesn't ship that API (it's behind an experimental flag), so iPhone users export a **vCard** from Contacts and upload it on Import.
5. **Hosting.** First set up for GitHub Pages, then moved to **Cloudflare Pages** (static, no build step).
6. **Fixes after real-device testing:**
   - **Offline on Cloudflare:** Pages redirects `/index.html` to `/`, and a redirected response can't answer a navigation. The service worker now caches the shell under `./`. `_headers` sets `Cache-Control: no-cache` on `sw.js`.
   - **Install button:** it used to show only when `beforeinstallprompt` fired (Chrome only). Now it always shows and falls back to per-browser steps. It hides when running as an installed app.
   - **iPhone import:** after picking a file, the preview and its Import button rendered below the fold, so imports looked done but weren't saved. The Import button now sits above the preview, with a "Not saved yet" note, and the page auto-scrolls to it.
   - **Updates:** installed apps needed two launches to pick up a new version. The app now reloads once on `controllerchange`, so one launch is enough.

## Architecture

```
index.html             The whole UI: CSS + one script. Views: #today #upcoming #people #add #import #prefs
store.js               LocalDB: IndexedDB-backed document store (doc/collection/get/set/update/delete/onSnapshot/limit).
                       Same API shape the claude.ai version used, so the UI code didn't change. Syncs tabs via BroadcastChannel.
sw.js                  Service worker: cache-first app shell with background refresh. Bump VERSION on every release.
                       Also catches the share-target POST (see below).
manifest.webmanifest   Installability (name, icons, standalone, shortcuts)
_headers               Cloudflare Pages headers (sw.js no-cache, manifest content type)
icons/                 SVG source + PNGs (192, 512, maskable 512, apple-touch 180)
tests/                 Playwright end-to-end tests + a local server that mimics Cloudflare's redirect
```

**Data model** (one document per person, under `data/users/local/crm/contacts/<id>`):

```
name, tier (A|B|C|D), email, phone, city, tags[], notes,
lastContact (YYYY-MM-DD|null), nextContact (YYYY-MM-DD), metOn (YYYY-MM-DD|null),
log[] (newest first, max 150: {date, channel, note}), createdAt
```

Settings are stored at `data/users/local/crm` as `{settings: {cad: {A,B,C,D days}, goal}}`. The last backup date is stored at `data/users/local/meta`.

**Key rules in the code:**
- Logging a check-in sets `lastContact = today` and `nextContact = today + cadence(tier)`.
- Changing a tier in the contact panel recalculates the next date from `lastContact`, never earlier than today.
- Imports can spread first check-ins randomly across each tier's cycle, so a big import doesn't all come due at once.
- Duplicate detection on import matches email first, then exact name.
- Writes to the same document are serialized through a per-document queue (`write()`), with retry on transient errors.

## Gotchas learned on real devices

- **Storage is per browser and per address.** Each of these has its own separate data:
  - Safari vs. the iPhone Home Screen app
  - in-app browsers (Gmail, Messages, Slack)
  - private tabs
  - Cloudflare's per-deploy preview addresses (`<hash>.keep-in-touch-d58.pages.dev`)

  Use only the installed app on the main address. Preview addresses show a banner saying so.
- **iOS Safari can evict site storage** after about 7 days without a visit. Home Screen apps are exempt, which is another reason to install.
- **Releases:** bump both `APP_VERSION` (index.html) and `VERSION` (sw.js) on each release. That's how installed copies notice an update and how you confirm which build is running (Settings shows "Version N").

## Running and testing locally

```bash
python3 tests/serve.py              # http://127.0.0.1:8766/ (mimics Cloudflare's /index.html redirect)
npm install && npx playwright install chromium
npm test                            # runs all end-to-end tests in tests/
```

Tests cover:
- add and fill-from-phone (mocked Contact Picker)
- multi-select import and vCard/CSV parsing
- data surviving a reload
- service worker and offline load
- backup → restore onto a fresh profile
- tab sync
- install button text per browser and hidden in standalone mode
- iPhone-size vCard import with the button visible
- one-launch updates
- sharing a `.vcf` to the app (multipart POST to the share target, through the service worker) → Import preview → saved
- preview-address banner (shown on `<hash>.keep-in-touch-d58.pages.dev`, not on the main address or localhost)

Screenshots go to `tests/output/` (gitignored).

**Not yet verified on a real device:**
- the Android Contact Picker (it's mocked in tests)
- sharing a `.vcf` from another Android app (Web Share Target; simulated with a form POST in tests). Only works once the app is installed.
- the one-launch update path on iOS
- WebKit (Playwright's WebKit wasn't available in the build environment, so iPhone was emulated with Chromium)

## Open items / next steps

- [ ] Confirm on iPhone: Settings shows **Version 5**, and a vCard import now saves.
- [ ] Try the real Contact Picker on the Pixel (Import → Choose contacts).
- [x] Warn when the app is opened on a Cloudflare preview address (`<hash>.keep-in-touch-d58.pages.dev`), since data there is separate. (Version 6: a banner links to the main address; `isPreviewHost()` in index.html, tests set `window.KIT_TEST_HOST`.)
- [ ] Optional **sync**: Cloudflare Worker (static assets) + D1 with a private passphrase. `store.js` is the single seam to swap or extend.
- [x] Web Share Target so a `.vcf` shared from another app opens straight into Import (Android). (Version 7: `share_target` in the manifest POSTs to `./share-target`; `sw.js` keeps the file in the `kit-share` cache and 303s to `./#import`, where `takeSharedFile()` feeds it into the normal vCard import.) **Still needs checking on a real Android device:** install the app, then share a contact from Contacts and pick Keep in Touch.
- [ ] Optional: per-person "check-in message" templates or reminders (notifications would need a server or periodic background sync).
- [ ] Optional: custom domain on Cloudflare.
