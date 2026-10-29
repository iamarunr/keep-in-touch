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

## Install it on your phone

Open the site in Chrome on Android, then tap **Install app** in the header (or ⋮ → *Add to Home screen*). On iPhone, use Safari → Share → *Add to Home Screen*.

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
sw.js                  service worker for offline use (bump VERSION to refresh caches)
manifest.webmanifest   makes it installable
icons/                 app icons
```

No build step and no dependencies. Serve the folder with any static host. To run it locally: `python3 -m http.server` and open http://localhost:8000.
