# Keep in Touch

A tiny personal CRM for keeping in touch with people, based on Derek Sivers' [Stay in touch with hundreds of people](https://sive.rs/hundreds):

| Tier | Who | Check in every |
|---|---|---|
| **A** | Very important people | 3 weeks |
| **B** | Important people | 2 months |
| **C** | Most people | 6 months |
| **D** | Demoted people | once a year |

When you check in, just find out how they're doing and see if you can help.

## What it does

- **Today:** who's due, sorted by tier, then by how overdue they are. Log a check-in (message, call, email, in person) with a note, and their next date is set from their tier.
- **Upcoming:** the next 30 days of check-ins.
- **People:** search by name, notes, email, tag or place ("everyone I know in Chicago").
- **Add / Import:** add people by hand, pick them from your phone's contacts (Chrome on Android), paste a list, or upload a CSV (Google Contacts, Outlook) or vCard (iPhone/Mac). First check-ins can be spread across each tier's cycle so a big import doesn't all come due on day one.
- **Weekly goal:** counts new people met this week (Sivers' "meet three new people every week").
- **Backup & restore:** one-tap JSON backup (share it straight to Google Drive on Android), restore on any device, and CSV export.

Live at **https://keep-in-touch-d58.pages.dev/** (Cloudflare Pages, deploys on every push to `main`).

## Install it on your phone

Open the site and tap **Install app** in the header. It uses the browser's install prompt where there is one, and otherwise shows the steps for your browser:
- **Android Chrome:** ⋮ → *Add to Home screen* → *Install*.
- **iPhone:** Share → *Add to Home Screen*.

On iPhone, the Home Screen app keeps its own data, separate from Safari, so use only one of them.

## Where the data lives

Everything is stored **on your device** in the browser's IndexedDB. There's no server or account, and it works offline. Because of that:

- Contacts don't sync between devices by themselves. Use **Settings → Backup** on one device and **Restore** on the other.
- Back up regularly. The app reminds you if it's been more than 30 days.
- Installing the app helps the browser treat its storage as persistent.

Picking phone contacts uses the browser's [Contact Picker API](https://developer.mozilla.org/en-US/docs/Web/API/Contact_Picker_API). It only ever sees the contacts you choose, and it's available in Chrome on Android. On iPhone, export a vCard from Contacts and upload it on the Import screen.

## Files

```
index.html             the whole app (HTML, CSS, JS)
store.js               on-device document store on top of IndexedDB
sw.js                  service worker for offline use
manifest.webmanifest   makes it installable
_headers               Cloudflare Pages headers
icons/                 app icons
tests/                 Playwright end-to-end tests + local server
HANDOFF.md             project history, architecture, open items
```

No build step and no runtime dependencies. Run it locally with `python3 tests/serve.py`, then open http://127.0.0.1:8766/.

Run the tests with `npm install && npx playwright install chromium && npm test`.

For each release, bump `APP_VERSION` in index.html and `VERSION` in sw.js. Settings shows the running version.
