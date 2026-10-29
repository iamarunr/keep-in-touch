# Sync between devices: plan

Status: **plan only, nothing built.** Written 2026-10-29. Read `CLAUDE.md` and `HANDOFF.md` first.

Goal: the phone and the laptop show the same people without manual backup and restore. Sync uses a Cloudflare Worker (static assets + API) and D1, unlocked with a private passphrase. `store.js` stays the only data layer the UI talks to.

Sync goes against two of the repo's ground rules (no server, no third-party service), so nothing here ships until those are explicitly lifted. The decisions you need to make are collected in [Decisions needed](#decisions-needed) at the end.

---

## TL;DR

- **Hosting:** one Worker serves the static files (Workers static assets) and `/api/v1/*`. D1 holds one row per document. The address changes from `keep-in-touch-d58.pages.dev`, and IndexedDB doesn't follow a new address, so **put a custom domain on it now** so this is the last time the address changes.
- **Passphrase:** use **end-to-end encryption**. The device derives keys from the passphrase. The server stores only ciphertext, an auth-token hash and a wrapped data key. Any device that's still joined can recover a lost passphrase. If every device is gone and the passphrase is lost, the synced copy is unreadable, so JSON backups stay.
- **Sync model:** a server-assigned `rev` per document and a per-vault change cursor. The device keeps a dirty flag per document, which doubles as its offline queue. Push and pull happen in one request, with optimistic concurrency on `baseRev`. Conflicts are **three-way merged on the device** (the server can't read the data): the `log[]` arrays are unioned, other fields go to whoever changed them, and newest wins if both did. Deletes travel as tombstones, and **a missing document never counts as a delete**.
- **Cost:** fits comfortably in the free tiers for one person.
- **Open source:** self-hosting comes first. Sync stays optional, the protocol is written down in `docs/sync-protocol.md`, and the server is a platform-free core with thin D1 and SQLite adapters. Personal values become config, and the repo needs a license before anyone can reuse it. See [6. Open source](#6-open-source).
- **Rollout:** store.js bookkeeping (invisible) → server core + D1 → hidden sync flag, tested on your own two devices → opt-in "Sync (beta)" in Settings → move the address (or skip it with a Pages Function, 6.3) → publish.

---

## 1. Architecture

### 1.1 Cloudflare Pages → a Worker with static assets

```
Browser (index.html + store.js + sync.js + sw.js)
   │  static files ───────────────► Worker static assets (no Worker code runs, free)
   │  /api/v1/*   ───────────────► Worker (worker/index.js) ──► D1 (binding DB)
```

`wrangler.jsonc` (sketch):

```jsonc
{
  "name": "keep-in-touch",
  "main": "worker/index.js",
  "compatibility_date": "<date of first deploy>",
  "assets": {
    "directory": "./public",
    "binding": "ASSETS",
    "run_worker_first": ["/api/*"]   // only API calls wake the Worker; everything else is served as a static asset
  },
  "d1_databases": [
    { "binding": "DB", "database_name": "keep-in-touch", "database_id": "<id>", "migrations_dir": "migrations" }
  ],
  "vars": { "MAX_VAULTS": "3", "SYNC_MODE": "on" },  // SYNC_MODE: on | readonly | off (server kill switch)
  "preview_urls": false                               // see "Deploys" below
}
```

What changes:

| Area | Today (Pages) | With a Worker |
|---|---|---|
| **Served files** | The whole repo root is public (including `tests/`, `HANDOFF.md`, `node_modules/` if present) | Only `public/` is served. Moving the app files into `public/` makes the published set an allow-list, and keeps `worker/`, `migrations/` and `wrangler.jsonc` off the web. (The alternative, `.assetsignore` at the root, is a deny-list: any new file is published by default.) `tests/serve.py` then serves `public/`. |
| **`/index.html` → `/`** | Pages redirects it | Workers assets do the same by default (`html_handling: "auto-trailing-slash"`), so the service worker's rule stays correct: **the shell is cached under `./`, never `./index.html`.** |
| **`_headers`** | Read by Pages | Workers static assets read the same `_headers` file (it moves into `public/`). It applies **only to asset responses**. Worker responses set their own headers (`Cache-Control: no-store`, `Content-Type: application/json`, a strict CSP). Keep `/sw.js no-cache` and the manifest content type. |
| **Service worker** | Caches every same-origin GET | **It must skip `/api/`.** Today's fetch handler would cache-first a `GET /api/...` and give back stale data. Add `if (url.pathname.startsWith("/api/")) return;` before `respondWith`. Add `sync.js` to `SHELL`. Bump `VERSION` and `APP_VERSION` together, as on every release. |
| **Deploys** | Push to `main` → Pages build | Workers Builds (Git integration): push to `main` runs `npx wrangler d1 migrations apply DB --remote && npx wrangler deploy`. Migrations run first and must stay backward compatible (add columns, never rename). |
| **Preview addresses** | `<hash>.keep-in-touch-d58.pages.dev` | Worker preview URLs (`<version>-keep-in-touch.<sub>.workers.dev`) **share production bindings, so a preview would write to the real D1.** Turn `preview_urls` off, or give previews their own `env` with a separate D1. The preview-address banner's detection (another session is building it) needs updating for the new pattern. |
| **Address** | `keep-in-touch-d58.pages.dev` | `keep-in-touch.<sub>.workers.dev`, or a **custom domain (recommended)**. A new address means new, empty IndexedDB and a new Home Screen install. See [Migration](#5-migration-steps). |

**Alternative worth knowing:** keep Pages and add a **Pages Function** (`functions/api/[[path]].js`) with a D1 binding. The address doesn't change, so no device migration is needed, and the API and client designs below stay exactly the same. Cloudflare is steering new projects to Workers, and the brief asks for a Worker, so this plan assumes one. But if avoiding the address move matters more than following that direction, the Pages Function route is the lower-risk path.

**A Durable Object per vault (SQLite)** would make writes perfectly serialized without the batch tricks in 1.3. It's a fine alternative. D1 is simpler to inspect and is enough at this scale.

### 1.2 D1 schema

```sql
-- migrations/0001_init.sql
CREATE TABLE vaults (
  id           TEXT PRIMARY KEY,           -- random 128-bit, base32 (the "sync code")
  auth_hash    TEXT NOT NULL,              -- hex SHA-256(authKey); authKey itself is never stored
  kdf          TEXT NOT NULL,              -- JSON {alg:"PBKDF2-SHA256", iter:600000, salt:"<b64>"} (public)
  wrapped_dek  TEXT NOT NULL,              -- data key wrapped by the passphrase key (ciphertext)
  recovery_dek TEXT,                       -- optional: data key wrapped by a recovery key
  seq          INTEGER NOT NULL DEFAULT 0, -- last change number handed out in this vault
  created_at   INTEGER NOT NULL,           -- ms epoch
  updated_at   INTEGER NOT NULL
);

CREATE TABLE docs (
  vault_id   TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
  path       TEXT NOT NULL,                -- store.js path, e.g. data/users/local/crm/contacts/<id>
  rev        INTEGER NOT NULL,             -- vaults.seq at the time of this write
  deleted    INTEGER NOT NULL DEFAULT 0,   -- 1 = tombstone
  iv         TEXT,                         -- b64, NULL for tombstones
  ct         TEXT,                         -- b64 AES-GCM ciphertext, NULL for tombstones
  updated_at INTEGER NOT NULL,             -- server time
  PRIMARY KEY (vault_id, path)
);
CREATE INDEX docs_by_rev ON docs (vault_id, rev);
```

Notes:
- **Paths stay readable**, but they leak nothing useful: contact IDs are random, and the ciphertext count already reveals how many people there are. Each path is bound into the encryption (see 2.3), so the server can't swap one person's blob for another's.
- Sizes: a contact with a full 150-entry log is about 15 KB of plaintext, so 1,000 people come to about 20 MB of base64. That's well under D1's per-row and per-database limits.
- **Tombstones are kept for 180 days.** A device whose cursor is older than that does a full resync (see 3.5).

### 1.3 API surface

All under `/api/v1/`, JSON in and out, `Cache-Control: no-store`. Auth is `Authorization: Bearer <vaultId>.<authKey b64url>`: no cookies (so no CSRF). The API is same-origin by default, and cross-origin requests are allowed only from origins listed in `ALLOWED_ORIGINS` (6.2). The old Pages address goes on that list during migration.

| Method & path | Auth | Purpose |
|---|---|---|
| `GET  /status` | none | `{mode:"on"\|"readonly"\|"off", minClient:N}`: kill switch and forced upgrade. |
| `GET  /vaults/:id/kdf` | none | Public KDF parameters (salt, iterations), needed before a device can derive anything. Returns the same shape with fake values for unknown IDs, so it doesn't confirm which vaults exist. |
| `POST /vaults` | create token | `{id, kdf, authKey, wrappedDek, recoveryDek?}` creates a vault. The server stores `SHA-256(authKey)`. Refused once `MAX_VAULTS` exist, or without the `CREATE_TOKEN` Worker secret. This is a personal app and the endpoint is public, so this stops strangers filling D1. |
| `GET  /vault` | bearer | `{wrappedDek, recoveryDek?, kdf, seq}`, used when joining. |
| `POST /sync` | bearer | The single sync round trip (below). |
| `POST /vault/rekey` | bearer | `{kdf, authKey, wrappedDek}` atomically replaces the passphrase wrapping (passphrase change or recovery). |
| `DELETE /vault` | bearer | Deletes the vault and every document (the "Stop syncing and delete server copy" button). |

`POST /sync`:

```jsonc
// request
{ "cursor": 1234,                  // highest rev this device has applied
  "push": [ { "path": "...", "baseRev": 1200, "iv": "...", "ct": "..." },     // edit (baseRev 0 = new)
            { "path": "...", "baseRev": 1210, "deleted": true } ],            // delete
  "limit": 500 }
// response
{ "accepted":  [ { "path": "...", "rev": 1235 } ],
  "conflicts": [ { "path": "...", "rev": 1229, "deleted": false, "iv": "...", "ct": "..." } ],
  "changes":   [ { "path": "...", "rev": 1240, "deleted": false, "iv": "...", "ct": "..." } ], // rev > cursor, not counting this push's own writes
  "cursor": 1240, "more": false }
// 410 {"resync": true} when cursor is older than the tombstone horizon
```

Server write rule, one D1 `batch()` (a transaction) per request: for each pushed document, increment `vaults.seq` and upsert the document with `rev = seq`, **only if** the stored `rev` still equals `baseRev` (`INSERT … ON CONFLICT(vault_id, path) DO UPDATE … WHERE docs.rev = ?baseRev`). A rejected guard leaves a gap in `seq`, which is harmless. Afterwards, read back the pushed paths: the ones whose `rev` is new are accepted, and the rest are returned as conflicts with the server's current copy. Limits: 200 pushed documents and 5 MB per request. The client sends larger first-time uploads in chunks.

Rate limits: the Workers rate-limiting binding (or a small D1 counter) on `/vaults/:id/kdf` and on failed bearer checks. The auth key is high-entropy, but there's no reason to let anyone hammer the endpoint.

---

## 2. Passphrase design

### 2.1 Auth only vs. end-to-end encryption

| | Auth only (server reads plaintext) | **End-to-end (recommended)** |
|---|---|---|
| What Cloudflare/D1 can see | Everyone's names, phone numbers, emails, notes: **personal data about third parties** | Ciphertext, document count, sizes, edit times |
| Conflict merging | Can happen on the server | Must happen on the device (the server can't read the data) |
| Debugging | Can look at rows | Rows are opaque; debug from a device |
| Lost passphrase | Server copy can still be read (but there's no email, so no "reset" either) | Server copy can't be read unless a joined device or recovery key still exists |
| Extra code | ~0 | ~150 lines of WebCrypto (built in, no dependency) |

Today the data never leaves the device except in JSON backups, which you can share to Drive **in plain text**. E2EE sync keeps sync at least as private as today. Auth-only would be the least private thing the app has ever done. **Recommendation: end-to-end.**

### 2.2 Keys

All of this is WebCrypto, so it adds no dependency. (Argon2 isn't in WebCrypto, so the KDF is PBKDF2.)

```
passphrase ──PBKDF2-SHA256(salt 16 B, 600 000 iter)──► root (256 bit)
root ──HKDF("kit-auth-v1")──► authKey (32 B)   → sent as the bearer token; server keeps SHA-256(authKey)
root ──HKDF("kit-kek-v1")───► KEK (AES-KW 256) → wraps/unwraps DEK
DEK  = random AES-GCM-256, made once per vault; server stores wrap(KEK, DEK)
```

- **Why a separate data key (DEK)?** Changing the passphrase only re-wraps the DEK (one small `rekey` call) instead of re-encrypting every document.
- The KDF parameters live in the vault row, so the iteration count can be raised later (re-wrap on the next unlock).
- 600k PBKDF2 iterations take roughly 0.3 to 1 s on a phone. That only happens on enable, join and passphrase change, never on app open.
- **On the device**, the DEK is kept in IndexedDB as a **non-extractable `CryptoKey`** (IndexedDB can store `CryptoKey` objects), and `authKey` is kept as raw bytes, so the app doesn't ask for the passphrase on every open. Anyone holding the unlocked device can already read the plaintext contacts, so this adds no new exposure.
- **Passphrase strength:** the server stores `SHA-256(HKDF(PBKDF2(passphrase)))`, so a leaked D1 could be brute-forced offline at PBKDF2 speed. Offer a generated passphrase by default (e.g. 5 random words, or 4 groups of 5 base32 characters, about 100 bits), and require a minimum length or entropy estimate for a custom one. Tell the user to save it in their password manager.

### 2.3 Document encryption

- Plaintext is `JSON.stringify({ v: 1, data, updatedAt, deviceId })`. Putting `updatedAt` and `deviceId` inside the ciphertext gives merges a tie-breaker without telling the server when you edited what. (The server still sees write times.)
- `iv` is a random 12 bytes per write. Additional data is `"kit1|" + vaultId + "|" + path`, so a blob moved to another path or vault fails to decrypt.
- Remaining exposure, accepted for a personal app: the server could replay an *older* ciphertext of the same document (a rollback). Sizes reveal roughly how long each log is.

### 2.4 Setting up, adding a second device, losing the passphrase

- **Turn on sync (first device):** pick or generate a passphrase → the device creates the vault ID, salt and DEK → `POST /vaults` → every syncable document is marked dirty and pushed. Then show the **sync code** (the vault ID, e.g. `KIT-7Q3M-…`) and offer an optional **recovery key**: a random 128-bit key that wraps the DEK a second time, shown once to print or save.
- **Second device:** Settings → Sync → "Join". Enter the sync code and the passphrase, or open a join link `https://<app>/#join=<vaultId>` that the first device shares with the Web Share API. The link carries only the vault ID; the `#fragment` never reaches the server, and the passphrase is always typed. The device fetches the KDF parameters, derives the keys, gets the wrapped DEK, unwraps it (a wrong passphrase fails here, and the server also returns 401), then pulls everything and merges with whatever is already on the device (see 5.1).
- **Passphrase lost, a device is still joined:** that device holds the DEK and `authKey`, so it can set a new passphrase (`rekey`) **without knowing the old one**. The other devices re-join with the new passphrase.
- **Passphrase lost, no device joined, recovery key saved:** join with the recovery key, then set a new passphrase.
- **Passphrase lost, nothing else left:** the server copy can't be read by anyone, including Cloudflare. Delete the vault and start over from the newest JSON backup. **That's why the backup card and the backup nag stay**, and the nag can't be silenced just because sync is on.
- **Changing the passphrase** works like recovery (`rekey`). Other devices get 401 on their next sync and ask for the new passphrase.

---

## 3. Sync model on top of `store.js`

### 3.1 Where the code goes

- `store.js` keeps its public API (`doc/collection/get/set/update/delete/onSnapshot/limit`) unchanged, and **adds a `db.sync` object** so the UI never talks to the network itself:

  ```js
  db.sync.state()                 // {enabled, status:"off"|"idle"|"syncing"|"offline"|"error"|"locked", pending, lastSyncedAt, error}
  db.sync.onState(fn)             // returns an unsubscribe function, like onSnapshot
  db.sync.enable({passphrase})    // creates a vault; returns {vaultId, recoveryKey?}
  db.sync.join({vaultId, passphrase | recoveryKey, mode:"merge"|"replace"})
  db.sync.unlock({passphrase})    // after a 401 from a passphrase change
  db.sync.changePassphrase({passphrase})
  db.sync.now()                   // sync right away
  db.sync.disable({deleteServerCopy})
  ```
- The network, crypto and merge code lives in a new `sync.js`, which `store.js` loads **only when sync is enabled**. With sync off, behavior is byte-for-byte today's. `sync.js` goes into the service worker's `SHELL` so it works offline.
- Snapshot `metadata.hasPendingWrites` (already part of the snapshot shape, always `false` today) becomes "this document has unsynced changes". The UI can ignore it.

### 3.2 On-device bookkeeping (IndexedDB v1 → v2)

`openIDB()` moves to version 2. `onupgradeneeded` **adds** two object stores and leaves `docs` alone:

- `syncmeta`: path → `{ rev, dirty, lseq, deleted, base, updatedAt }`
  - `rev`: server rev last applied or acknowledged (0 = never synced)
  - `dirty`: has local changes not yet acknowledged. **This flag is the offline queue.** It's state-based, not an operation log, so ten edits while offline become one push.
  - `lseq`: increases on every local write. An acknowledgement only clears `dirty` if `lseq` hasn't moved since the push was built (otherwise an edit made mid-flight would be lost).
  - `base`: the plaintext as of `rev` (the common ancestor for three-way merges). It roughly doubles local storage. That's fine at this size, and it's what makes merges correct.
  - `deleted`: local tombstone, kept until acknowledged.
- `kv`: `deviceId`, `vaultId`, `cursor`, `enabled`, the DEK (`CryptoKey`), `authKey`, and local safety snapshots (3.7).

Bookkeeping data stays **out of the document values**, so backups, `S.contacts` and the UI never see it.

### 3.3 Which documents sync

Use an allow-list in `sync.js`:
- `data/users/local/crm`: settings (`cad`, `goal`)
- `data/users/local/crm/contacts/*`: people

Not synced: `data/users/local/meta` (`lastBackup` describes *this* device's backups), and anything new until it's added deliberately. Keeping the `local` user ID on every device is fine; the vault provides the separation.

### 3.4 The write path, and how it fits the existing queues

- **The UI's per-document `write()` queue in `index.html` stays.** It still serializes UI writes per contact and retries `unavailable`. Sync sits *below* it, inside `store.js`.
- `store.js`'s internal `write(path, value)` changes so that `persist()` updates `docs` **and** `syncmeta` (`dirty = true`, `lseq++`, `updatedAt = now`, `deleted` on delete) in **one IndexedDB transaction**, but only for syncable paths and only when sync is enabled. No half-recorded edits.
- **Remote changes** go through a new internal `applyRemote(path, value, rev)`. It writes `docs` and `syncmeta` (`dirty = false`, `rev`, `base = value`) in one transaction, updates `mem`, calls `notify(path)`, and posts `{path}` on the existing BroadcastChannel. **The existing `onmessage` handler already re-reads the document from IndexedDB and notifies**, so other tabs need no new code to see synced changes.
- **One tab syncs at a time:** a leader is chosen with `navigator.locks.request("kit-sync", …)` (Web Locks, Safari 15.4+). The other tabs still write locally, setting `dirty` in IndexedDB. The leader hears their BroadcastChannel `{path}` messages and schedules a push. If the leader tab closes, the lock passes to another tab.
- **When to sync:** on open, when `visibilitychange` makes the app visible, on `online`, 2 s after the last local write (debounced), and every 5 minutes while visible. Don't rely on Background Sync, which isn't on iOS.
- **Known race to fix in the UI, small:** `logContact()` builds the new `log` from `c.log` in `S.contacts`. If a remote check-in lands between render and tap, the update overwrites `log` without it, and because that's a plain local edit relative to `base`, the merge won't bring it back. Fix: build `log` inside the `write()` function from a fresh `await contactsCol.doc(c.id).get()`. Apply the same pattern anywhere the UI does read-modify-write on arrays.

### 3.5 Pull and push loop (leader only)

1. Collect dirty syncable paths (up to 200). For each, encrypt `{data, updatedAt, deviceId}` and send `baseRev = rev`, or `deleted: true`.
2. `POST /sync {cursor, push}`.
3. `accepted`: set `rev`, `base = sent plaintext`, and clear `dirty` if `lseq` is unchanged.
4. `conflicts`: decrypt the server copy, **merge** (3.6) with local and base, write the result locally (still dirty), set `rev` to the server's rev, and push again on the next loop.
5. `changes`: for each, skip it if its `rev` is already applied (echoes of our own writes). If the local copy is clean, `applyRemote`. If it's dirty, merge as in step 4.
6. Save `cursor`. If `more`, repeat. If 410 `resync`, run a full pull with cursor 0, merging every document, which is safe because merges are idempotent.
7. Errors: offline or 5xx → back off (2 s, 4 s … 5 min) and keep the dirty flags. 401 → status `locked`, ask for the passphrase. 429 or quota → back off and show "Sync paused". A decrypt failure on one document → skip it and report it, and don't stop the rest.

### 3.6 Conflict handling: three-way merge, not whole-document last-write-wins

Whole-document last-write-wins would silently drop a check-in logged on the phone when the laptop edited that person's notes. That's the most common real conflict this app would have. So merge per field, with `base` as the common ancestor:

| Field | Rule |
|---|---|
| Changed on one side only | Take that side. |
| `log[]` | **Union** of both sides, de-duplicated by `date + channel + note`, sorted newest first, capped at 150 (the app's existing cap). |
| `lastContact`, `nextContact` | A pair: take both from the side with the later `lastContact`. On a tie, take the later `nextContact` (a snooze on one side survives). |
| `tags[]` | Three-way set merge: additions and removals from both sides apply. |
| Any other scalar changed on both sides (`name`, `tier`, `notes`, `email`, `phone`, `city`, `metOn`, settings) | Newer `updatedAt` from the ciphertext wins. On a tie, the larger `deviceId` wins (deterministic). |
| Edit vs. delete | **Delete wins.** The user removed the person on purpose, and the backups exist. (The alternative, "an edit brings it back", loses nothing but resurrects people you deleted. This is a decision for you.) |
| Present on both sides with no base (first join) | See 5.1. |

The merge must be **deterministic and idempotent**: merging the same inputs on either device gives the same result. Unit-test it as a pure function.

Optional improvement later: give new log entries an `id`, so two identical entries logged on the same day aren't collapsed into one. Without IDs, dedup on content is acceptable; identical entries are almost always the same check-in.

### 3.7 Deletes, tombstones, and the "absence isn't deletion" rule

- A local `delete()` keeps a `syncmeta` tombstone (`deleted: true, dirty: true`) and pushes `deleted: true`. The server keeps the row with `deleted = 1` and no ciphertext.
- Server tombstones older than 180 days are removed (a cleanup query on each `/sync`, or a Cron Trigger). Devices behind that horizon get 410 and do a full resync.
- **A document missing from a device never means it was deleted.** Only an explicit tombstone does. That protects against the iOS eviction case (4.5), a new device, and a restore.
- **Safety snapshots:** before applying a batch that changes more than 20 documents, or deletes any, and at most once a day, the sync engine saves a JSON snapshot (the same format as a backup) into `kv`, keeping the last 7. A merge bug then can't destroy data everywhere without a way back. Restore uses the existing Restore code.

---

## 4. Trade-offs vs. today's backup and restore

### 4.1 Privacy
- **Today:** data stays on the device. Backups shared to Drive are plaintext JSON, held by Google.
- **E2EE sync:** Cloudflare holds ciphertext, plus metadata: number of documents, sizes, edit times, IP addresses. Arguably better than plaintext backups on Drive, but there is now a server that sees when you use the app.
- **Auth-only sync:** Cloudflare holds readable personal data about everyone in your contacts. Not recommended.

### 4.2 Cost and free-tier limits
For one person with two or three devices: about 300 to 1,000 `/sync` calls a day, a few hundred D1 rows written a day, and data in the tens of MB.
- Workers Free: 100,000 requests/day and 10 ms CPU per request. Static assets are free and don't count toward requests (`run_worker_first` is limited to `/api/*`). The server does no expensive crypto (one SHA-256 per request), so the CPU limit isn't a concern.
- D1 Free: about 5M rows read/day, 100k rows written/day, 5 GB storage. Pulls read only changed rows through `docs_by_rev`.
- **Expected cost: $0.** Check the current limits on Cloudflare's pricing pages before building; they change. Hitting a limit means 429s: the dirty queue waits and nothing is lost.

### 4.3 Complexity
- **Today:** no server code; `store.js` is about 200 lines.
- **With sync:** roughly a 250-line Worker, D1 migrations, a 400 to 500-line `sync.js` (crypto, loop, merge), IndexedDB v2 upgrade, Settings UI, two-device tests, and operations: wrangler, a D1 database, a `CREATE_TOKEN` secret, migration ordering, the kill switch. This is the biggest cost. It's also the end of "no server", which is a product decision as much as a technical one.

### 4.4 Failure modes

| Failure | What happens | Mitigation |
|---|---|---|
| Offline / server down | App works as today; "N changes waiting" | Dirty queue, backoff |
| Merge bug | Bad data spreads to every device | Pure, tested merge; local safety snapshots; D1 Time Travel (restores the whole database to a point in time, 7 days on Free and 30 on paid); the manual backup stays |
| Passphrase lost | See 2.4 | Joined device can rekey; recovery key; JSON backups |
| Passphrase changed on another device | 401 → "Enter your new passphrase" | `db.sync.unlock` |
| Clock skew between devices | Affects only both-sides-changed scalar tie-breaks | Server `rev` decides order everywhere else |
| Bad deploy | Clients break mid-sync | `GET /status` kill switch (`readonly`/`off`) and `minClient`; additive migrations only |
| Preview deploy writing to production | Corrupted vault | `preview_urls: false`, or a separate D1 for previews |
| Someone else creating vaults | D1 fills up | `CREATE_TOKEN` secret and `MAX_VAULTS` |
| Service worker caching the API | Stale pulls | `/api/` bypass in `sw.js`, with a test |

### 4.5 The iOS storage-eviction gotcha
- iOS Safari can evict site storage after about 7 days without a visit. Home Screen apps are exempt. Each of these has its own storage: Safari, the Home Screen app, in-app browsers, private tabs, preview addresses.
- **Sync helps:** if a copy is evicted, join again and everything comes back. Sync also removes the "which copy has my data?" problem across Safari and the Home Screen app, because each one can join.
- **Sync has to be careful:** eviction wipes `docs`, `syncmeta` and `kv` together (they're one origin), so an evicted device looks like a brand-new device. It doesn't send deletes, because absence isn't deletion (3.7). It also forgets the DEK, so **the user needs the passphrase again.** That's another reason to make saving it to a password manager part of setup.
- Keep calling `navigator.storage.persist()` (the app already does) and keep recommending the installed app.

---

## 5. Migration steps

### 5.1 Existing on-device data
- **Upgrade (invisible):** IndexedDB v1 → v2 adds `syncmeta` and `kv` and leaves `docs` untouched. Sync is off, so nothing else changes.
- **First device to turn on sync:** mark every syncable document dirty with `baseRev 0` and push in chunks. The progress shows in `db.sync.state().pending`.
- **Joining a device that already has data** (for example from an earlier Restore). Before doing anything, save a safety snapshot. Then ask:
  - **"Merge with what's on this device" (default):** pull everything. Documents only on the server are applied. Documents only on this device are pushed. Documents on both with the same ID are merged with an empty base: `log` union and the `lastContact` pair as in 3.6. For other fields, prefer the side with the later `lastContact`, then the server's copy. Identical copies (the usual case after a Restore) are a no-op.
  - **"Replace this device's data with the synced data":** the safety snapshot is offered as a download first, then local syncable documents are cleared and everything is pulled.
- **The same person under two IDs** (both devices imported the same vCard separately): ID-based sync won't merge them. A later "Possible duplicates" screen can reuse the import's email-then-name matching. Not in v1.
- **Restore while sync is on:** restored documents become local edits and sync out, merging with any newer changes on other devices. Say so in the Restore confirmation.

### 5.2 The retired claude.ai artifact data
It lives in claude.ai's storage, under a different origin, so the app can't reach it, and **nothing should be built for it.** If you want any of it, do a one-off move before turning on sync: get the data out of the artifact (by any export it offers, or by asking Claude in that conversation to print it as JSON). Then use **Settings → Restore from backup**, which accepts a bare array or `{contacts:[…]}`. Then turn on sync, and it travels with everything else. If you don't need it, leave it retired.

### 5.3 The address move (pages.dev → Worker)
IndexedDB is tied to the address, so moving hosts strands data. Use sync itself as the moving van:

1. Deploy the Worker (assets + API) on the custom domain while Pages stays production. The Worker allows CORS from `https://keep-in-touch-d58.pages.dev` for `/api/v1/*` only, temporarily.
2. Ship the sync client on **both** addresses. On the old Pages app, turn on sync, pointed at the Worker's API, which pushes the data.
3. Open the new address, install it to the Home Screen, and **join** with the sync code and passphrase. Everything arrives.
4. The old Pages app shows a banner: "Keep in Touch has moved to <new address>. Your data is synced; open the new one and remove this one from your Home Screen." **Don't hard-redirect** the old address: an installed copy that hasn't synced would lose access to its own data. (Without sync, the same move works with Backup → Restore.)
5. After a few weeks, once every device is on the new address, remove the CORS allowance and the Pages project.

### 5.4 Rollout order

Each step ships on its own and passes `npm test`. Bump `APP_VERSION` and `VERSION` together on every release.

1. **`store.js` bookkeeping:** IndexedDB v2, the `syncmeta` transaction in `persist`, the `applyRemote` path, and `hasPendingWrites`. No network, invisible. Fix the `logContact()` read-modify-write race at the same time.
2. **Server core + D1 + API** on the custom domain with `public/`, `_headers`, migrations, `CREATE_TOKEN`, `MAX_VAULTS`, the kill switch and `preview_urls: false`. Pages is still production. Build it as `server/core.js` plus the D1 adapter from the start (6.3). Write `docs/sync-protocol.md` alongside it, and commit `wrangler.example.jsonc` rather than real ids.
3. **`sync.js` + `sw.js` `/api/` bypass, behind a hidden flag** (below). Test on your own phone and laptop for a week or two.
4. **"Sync between devices (beta)"** card in Settings, off by default. Turning it on is the opt-in.
5. **Move the address** (5.3).
6. **Retire Pages;** update `HANDOFF.md`, `README.md` and the preview-address banner's pattern.
7. **Publish (6.4):** add the license, move `MAIN_HOST` into config, write "Deploy your own" in the README, add the SQLite adapter so the conformance suite runs without Cloudflare, scan history for secrets, and tag a release.

The license and the `MAIN_HOST` config can land any time, even before sync. They're small and independent of everything above.

### 5.5 Feature flag (opt-in)
- **Per device, local only:** `kv.enabled` (and `kv.vaultId`). Sync never turns on by itself and isn't synced between devices.
- **Visibility:** during step 3 the Settings card appears only after opening `#prefs?sync=1` once (remembered in `kv`). In step 4 it's always visible, still off by default.
- **Server kill switch:** `GET /status` → `mode: "off"` makes clients stop syncing and show "Sync is paused"; `readonly` allows pulls only. `minClient` forces "Update the app to keep syncing".
- **Off means off:** with sync disabled, `sync.js` isn't loaded and **no request goes to `/api/`** (tested).

### 5.6 Tests to add
Playwright, as today. The Worker side runs under `wrangler dev` with a local D1 (Miniflare), which adds `wrangler` as a devDependency only; there are still no runtime dependencies. `tests/run.sh` starts both servers.

- **Crypto:** derive → encrypt → decrypt round trip; wrong passphrase fails to unwrap and gets 401; changing the path or vault in the additional data fails to decrypt.
- **Server sees only ciphertext:** after a sync, read the local D1 and assert no contact name, email or note appears anywhere.
- **Two devices** (two browser contexts, two storages): enable on A, join on B, and a person added on A appears on B; a delete on A disappears from B.
- **Offline both sides:** A logs a check-in and B edits notes on the same person while offline; after reconnecting, both devices have the check-in **and** the note. The merge result is identical on both.
- **Scalar conflict:** both sides change `tier`; the newer `updatedAt` wins on both.
- **Edit vs. delete** follows the chosen rule.
- **Absence isn't deletion:** clear B's storage (simulated eviction), re-join, and nothing is deleted on A.
- **Join with existing data:** B restored the same backup earlier; merge is a no-op; "Replace" works and offers the snapshot.
- **Mid-flight edit:** a local edit made while a push is in flight is still dirty after the acknowledgement and gets pushed next.
- **Tabs:** with two tabs open, only the leader calls `/api`; a remote change shows up in both tabs.
- **Service worker:** with the SW active, `/api/v1/*` responses never come from the cache.
- **Flag off:** with a fresh profile and sync off, no requests go to `/api/`, and all existing tests still pass unchanged.
- **IndexedDB upgrade:** a v1 database with contacts opens as v2 with the data intact.
- **Passphrase change:** A changes it; B gets `locked`; B unlocks with the new one and syncs.
- **Tombstone horizon:** a cursor older than the horizon gets 410 and a full resync converges.
- **Merge unit tests:** the merge as a pure function with table-driven cases (`page.evaluate` or plain `node`).
- Per `CLAUDE.md`, add a regression test for every sync bug reported from a real device.
- **Protocol conformance suite:** the API tests drive `/api/v1/*` over plain HTTP against any base URL (`SYNC_TEST_URL`), with no Cloudflare-specific calls. The same suite then checks the Cloudflare server, a Node + SQLite server, or a server someone else writes (see 6.3).

---

## 6. Open source

The goal: build this for yourself first, then publish it so others can use it, **without a rewrite in between.** Most of what that needs is cheap if it's decided now, and expensive to retrofit.

### 6.1 Two ways others could use it

| | **Self-host (start here)** | **Hosted sync (maybe later)** |
|---|---|---|
| Who runs the server | Each person deploys the app and their own sync server to their own Cloudflare account | You run one server for everyone who wants it |
| Your cost and risk | None: you never hold anyone else's data | Bills, uptime, abuse, support, a privacy policy, deletion requests |
| Needs from this plan | Everything in 1–5 as written, plus 6.2–6.4 | Also 6.5 |

Self-hosting is the default for the first public release. Hosted sync is a separate decision you can make later, once people ask for it. Nothing in 6.2–6.4 rules it out.

### 6.2 Keep sync optional

- The app stays **fully usable with no server**. The static page alone, with on-device storage and backup/restore, is what most people would try first. It's also what anyone gets from a plain static host such as GitHub Pages, Netlify or any web server.
- "Off means off" (5.5) doubles as a promise to self-hosters: with sync disabled, the app makes no network requests apart from loading its own files and Google Fonts. Consider self-hosting the two font files too, so a privacy-minded user can verify that with zero third-party requests.
- The sync client talks to `SYNC_BASE`, which defaults to same-origin `/api/v1/`, the address where the app itself is served. Same-origin is the right default because a self-hoster deploys the app and the API together. A later "custom sync server" field in Settings would let someone use a hosted or separately run server. Bearer auth with no cookies makes cross-origin requests safe, and the server allows them only for origins in an `ALLOWED_ORIGINS` setting. That replaces the one-off CORS allowance in 1.3 and 5.3.

### 6.3 A small, written-down protocol and a portable server

The protocol, not the database, is what makes this portable. Once the API in 1.3 is written down, someone can run it on Supabase, Postgres, plain Node or anything else without touching the app.

- **`docs/sync-protocol.md`** becomes the source of truth: the endpoints, request and response shapes, the `baseRev` write rule, the tombstone horizon and 410, auth, limits, and the encryption envelope (2.2, 2.3) so other clients can interoperate. Version it with the `/api/v1/` path, and make new fields additive.
- **Split the server into a core and thin adapters:**
  ```
  server/core.js        handle(request, store) → response; all API logic, no platform calls
  server/store.d1.js    the store interface on D1 (batch() as the transaction)
  server/store.sqlite.js the same interface on node:sqlite or better-sqlite3 (self-host on any box, and fast local tests)
  worker/index.js       Cloudflare entry: export default { fetch } → core.handle(req, d1Store(env.DB))
  ```
  The store interface is small: one transaction that runs the conditional upsert and bumps `seq`, plus reads by `rev`. Use **plain SQLite SQL**: no D1-only features, and no Durable Objects (1.1), which only run on Cloudflare. The same migrations then run on D1, local SQLite and Turso.
- **Pages Function or Worker stops being either-or.** With logic in `core.js`, both entry points are a few lines each (`functions/api/[[path]].js` and `worker/index.js`). You can stay on a Pages Function at your current address, so you skip the move in 5.3, while the public "deploy your own" path uses a Worker. A fresh self-hoster has no old data to move. See decision 2.
- The conformance suite (5.6) is what other implementations test against.

### 6.4 Repo prep for going public

- **License.** The repo is public on GitHub but has no license, which legally means "all rights reserved", so nobody may reuse it. Choose before publishing:
  - **MIT:** anyone can use the code for anything. The simplest choice, with the most adoption.
  - **AGPL-3.0:** anyone who runs a modified version as a service has to publish their changes. It suits the server if you'd mind someone running a closed paid fork of it.
  - (Possible, but more to explain: MIT for the app and AGPL for `server/`.)
- **Config, not code.** Personal values that are in the code today:
  - `MAIN_HOST` in `index.html` (the preview-address banner) and its test in `tests/preview-banner.test.js`. Change it to "warn when `location.hostname` is a subdomain of a configured main host, and only if one is configured". For a self-hoster with no main host set, the banner never shows. Put the setting in one small config block at the top of the script.
  - The Cloudflare ids in `wrangler.jsonc` (`database_id`, account routes). Commit a `wrangler.example.jsonc` with placeholders, and gitignore the real one. `database_id` isn't a secret, but it's yours and won't work for anyone else.
  - Secrets (`CREATE_TOKEN`, any future ones) only ever via `wrangler secret put`, or `.dev.vars` locally. Gitignore `.dev.vars` and `.wrangler/` from the first server commit.
  - Docs that name your address (`CLAUDE.md`, `HANDOFF.md`, `README.md`) can keep it as "the author's instance", alongside instructions for deploying your own.
- **Defaults that suit a self-hoster:** `MAX_VAULTS` (1.3) defaults to a small number such as 3 (one person, a spare, and a test vault), and `CREATE_TOKEN` is required. A self-hosted server then can't be filled up by strangers who find the address.
- **README "Deploy your own":** fork, `npm i`, `wrangler d1 create`, `wrangler d1 migrations apply`, `wrangler secret put CREATE_TOKEN`, `wrangler deploy`, then enter the token once when turning on sync. Cloudflare's Deploy to Cloudflare button can cut this down further for Workers projects. Check how it handles D1 bindings and secrets when you get there.
- **Before flipping anything public:** scan the git history for secrets (there are none today, so keep it that way), and keep test fixtures fake. The only one today, `tests/fixtures/iphone-contact.vcf`, is "John Smith" with a 555 number, which is fine.
- **Attribution:** keep crediting Derek Sivers for the method, link to his posts, and keep the app's wording your own. Don't use his name in a way that suggests he endorses the app.
- **Nice to have, not blocking:** CONTRIBUTING (the no-build-step and no-runtime-dependencies rules are the main thing to explain), an issue template asking for browser, device and app version (Settings already shows it), and a short SECURITY.md describing the E2EE design and how to report a flaw.

### 6.5 If you ever host sync for others

Not for v1. It's listed here so v1 doesn't paint you into a corner.

- **Signup without `CREATE_TOKEN`** means anyone can create a vault. Add per-vault quotas (document count and total bytes), per-IP rate limits on `POST /vaults`, and expiry of vaults with no sync for, say, 12 months. Warn about that well in advance in the app. **E2EE cuts both ways here:** you can't read users' data, and you also can't tell contacts from someone using your D1 as free encrypted storage. That's why the byte caps matter.
- **Cost:** the free-tier numbers in 4.2 are per Cloudflare account, so they cover you, not hundreds of users. Expect the paid Workers plan at some point. Check current pricing first.
- **Privacy and legal:** contents are ciphertext, but IP addresses, timestamps and vault metadata are still personal data under laws like GDPR. You'd need a short privacy policy, a working "delete my server copy" (`DELETE /vault` already does this), and no analytics.
- **Operations:** the kill switch and `minClient` (5.5) become essential. Test D1 Time Travel restores, and keep a status page or at least a pinned issue for outages.
- Anyone who doesn't want to trust your server can still self-host, and the protocol (6.3) means their data format is the same either way.

---

## Decisions needed

1. **Lift the "no server / no third-party service" rule for sync?** Everything above depends on it.
2. **Worker with static assets (address move) or a Pages Function (no move)?** The plan assumes a Worker, per the brief. A Pages Function avoids 5.3 entirely. With the core/adapter split (6.3) you can have both: a Pages Function for your own instance, so your devices never move, and a Worker as the public deploy path.
3. **Custom domain:** which one? Do it in the same move so the address changes only once.
4. **E2EE (recommended) or auth-only?**
5. **Passphrase:** generated by default (recommended), or user-chosen with a strength check? Offer a recovery key?
6. **Edit vs. delete conflicts:** delete wins (recommended), or an edit brings the person back?
7. **License:** MIT (simplest, most reuse) or AGPL-3.0 (hosted forks must share their changes)? Needed before anyone can legally reuse the code.
8. **Hosted sync for others:** self-host only for now (recommended), or plan to run a public server later (6.5)?
