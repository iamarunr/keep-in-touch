# Sync between devices: plan

Status: **plan only, nothing built. Decisions settled 2026-10-29** (see [Decisions](#decisions)). Read `CLAUDE.md` and `HANDOFF.md` first.

Goal: the phone and the laptop show the same people without manual backup and restore. Sync runs as a **Cloudflare Pages Function with D1**, on the existing Pages project, and is unlocked with a private passphrase. Everything is **end-to-end encrypted** on the device. `store.js` stays the only data layer the UI talks to.

Sync is the one approved exception to the repo's "no server" rule. It's opt-in per device, and with sync off the app behaves exactly as it does today.

---

## TL;DR

- **Hosting:** keep Cloudflare Pages. Add a Pages Function at `/api/v1/*` with a D1 binding. Static files are served as today. Your subdomain is added as a custom domain on the same Pages project, so both addresses serve the same app and the same database.
- **Address move:** IndexedDB doesn't follow a new address, so each device moves once **using sync itself**: turn sync on at `keep-in-touch-d58.pages.dev`, then join from the subdomain. The old address shows a "we've moved" note and is never force-redirected.
- **Passphrase:** end-to-end encryption. The app generates a strong passphrase (you save it in your password manager) and a one-time **recovery key**. The server stores only ciphertext, an auth-token hash and wrapped data keys.
- **Sync model:** a server-assigned `rev` per document and a per-vault change cursor. The device keeps a dirty flag per document, which doubles as its offline queue. Push and pull happen in one request, with optimistic concurrency on `baseRev`. Conflicts are **three-way merged on the device**: `log[]` arrays are unioned, other fields go to whoever changed them, and newest wins if both did. **A delete beats an edit.** **A missing document never counts as a delete.**
- **Cost:** fits in the free tiers for one person.
- **Audience:** just you. Vault creation is locked behind your secret. The repo goes **MIT** so others can deploy their own copy.
- **Rollout:** store.js bookkeeping (invisible) → Pages Function + D1 → hidden sync flag, tested on your two devices → opt-in "Sync (beta)" in Settings → move to the subdomain → publish.

---

## 1. Architecture

### 1.1 Pages + a Pages Function

```
Browser (index.html + store.js + sync.js + sw.js)
   │  static files ──► Cloudflare Pages static hosting (as today, free, unmetered)
   │  /api/v1/*   ──► Pages Function functions/api/[[path]].js ──► server/core.js ──► D1 (binding DB)
```

Repo layout after the change:

```
public/                 everything the browser loads: index.html, store.js, sync.js, sw.js,
                        manifest.webmanifest, _headers, _routes.json, icons/
functions/api/[[path]].js   Pages Function entry: onRequest(ctx) → core.handle(ctx.request, d1Store(ctx.env.DB), ctx.env)
server/core.js          all API logic, no platform calls (6.3)
server/store.d1.js      the small storage interface on D1
migrations/0001_init.sql
wrangler.toml           pages_build_output_dir = "public", D1 binding (real ids gitignored; see 6.4)
```

`wrangler.toml` (sketch):

```toml
name = "keep-in-touch"
pages_build_output_dir = "./public"
compatibility_date = "<date of first deploy>"

[[d1_databases]]
binding = "DB"
database_name = "keep-in-touch"
database_id = "<id>"
migrations_dir = "migrations"

[vars]
MAX_VAULTS = "3"
SYNC_MODE = "on"          # on | readonly | off (server kill switch)

[env.preview]             # preview deploys get their own throwaway database, never production
[[env.preview.d1_databases]]
binding = "DB"
database_name = "keep-in-touch-preview"
database_id = "<preview id>"
```

What changes:

| Area | Today | With the Pages Function |
|---|---|---|
| **Served files** | The whole repo root is public (`tests/`, `HANDOFF.md`, …) | Only `public/` is served (`pages_build_output_dir`). That keeps `functions/`, `server/`, `migrations/` and `wrangler.toml` off the web. `tests/serve.py` then serves `public/`. Once `wrangler.toml` exists, Pages reads its settings (output dir, bindings) from the file rather than the dashboard. So the move to `public/` and adding the file must land **in one commit**. |
| **Which requests run code** | None | `public/_routes.json` = `{"version":1,"include":["/api/*"],"exclude":[]}`. Only API calls invoke the Function and count toward the Workers request quota. Everything else stays free static hosting. |
| **`/index.html` → `/`** | Pages redirects it | Unchanged. The service worker rule stays: **the shell is cached under `./`, never `./index.html`.** |
| **`_headers`** | Read by Pages | Unchanged (moves into `public/`). It applies only to static files. Function responses set their own headers (`Cache-Control: no-store`, `Content-Type: application/json`). |
| **Service worker** | Caches every same-origin GET | **It must skip `/api/`.** Today's fetch handler would cache-first a `GET /api/...` and serve stale data. Add `if (url.pathname.startsWith("/api/")) return;` before `respondWith`. Add `sync.js` to `SHELL`. Bump `VERSION` and `APP_VERSION` together, as on every release. |
| **Deploys** | Push to `main` → Pages | Unchanged: push to `main` deploys app and Function together. **D1 migrations don't run on deploy.** Run `npm run db:migrate` (`wrangler d1 migrations apply DB --remote`) from the laptop *before* pushing code that needs them. Migrations are additive only (add columns or tables, never rename or drop), so old code keeps working against a new schema. |
| **Preview addresses** | `<hash>.keep-in-touch-d58.pages.dev` | Pattern unchanged, so the preview-address banner still works. Previews use the `env.preview` database, so a preview can never touch your real vault. |
| **Address** | `keep-in-touch-d58.pages.dev` | Your subdomain added under Pages → Custom domains. If its DNS is on Cloudflare, that's one click. Otherwise it's a CNAME to `keep-in-touch-d58.pages.dev`. **Both addresses keep serving the same deployment and the same API**, which is what makes the move in 5.3 simple. |

**Why not a Worker with static assets?** It's where Cloudflare is steering new projects. But it would have meant a new address *and* a new deploy setup, and it would have needed CORS during the move. Because the logic lives in `server/core.js` (6.3), a Worker entry is about 5 lines if it's ever wanted.

**Why not a Durable Object per vault?** It would serialize writes more simply than the D1 batch rule in 1.3, but it only runs on Cloudflare, and D1 is easier to inspect. D1 is enough at this scale.

### 1.2 D1 schema

```sql
-- migrations/0001_init.sql
CREATE TABLE vaults (
  id           TEXT PRIMARY KEY,           -- random 128-bit, base32 (the "sync code")
  auth_hash    TEXT NOT NULL,              -- hex SHA-256(authKey); authKey itself is never stored
  kdf          TEXT NOT NULL,              -- JSON {alg:"PBKDF2-SHA256", iter:600000, salt:"<b64>"} (public)
  wrapped_dek  TEXT NOT NULL,              -- data key wrapped by the passphrase key (ciphertext)
  recovery_dek TEXT NOT NULL,              -- data key wrapped by the recovery key (ciphertext)
  recovery_auth_hash TEXT NOT NULL,        -- hex SHA-256(recoveryAuthKey), so the recovery key can authenticate too
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
- **Paths stay readable**, but they leak nothing useful: contact IDs are random, and the ciphertext count already reveals how many people there are. Each path is bound into the encryption (2.3), so the server can't swap one person's blob for another's.
- Sizes: a contact with a full 150-entry log is about 15 KB of plaintext, so 1,000 people come to about 20 MB of base64, well under D1's limits.
- **Tombstones are kept for 180 days.** A device whose cursor is older than that does a full resync (3.5).
- Plain SQLite SQL only, so the same migrations run on local SQLite in tests (6.3).

### 1.3 API surface

All under `/api/v1/`, JSON in and out, `Cache-Control: no-store`, **same-origin only**. There's no CORS: both of your addresses serve the API themselves. Auth is `Authorization: Bearer <vaultId>.<key b64url>`, with no cookies (so no CSRF). The server accepts a key whose SHA-256 matches either `auth_hash` or `recovery_auth_hash`.

| Method & path | Auth | Purpose |
|---|---|---|
| `GET  /status` | none | `{mode:"on"\|"readonly"\|"off", minClient:N}`: kill switch and forced upgrade. |
| `GET  /vaults/:id/kdf` | none | Public KDF parameters (salt, iterations), needed before a device can derive anything. Unknown IDs get the same shape with fake values, so it doesn't confirm which vaults exist. |
| `POST /vaults` | `CREATE_TOKEN` | `{id, kdf, authKey, wrappedDek, recoveryAuthKey, recoveryDek}` creates a vault. The server stores only the hashes of the two keys. Refused without the `CREATE_TOKEN` secret (set with `wrangler pages secret put`) or once `MAX_VAULTS` exist. You enter the token once, when turning sync on for the first time. |
| `GET  /vault` | bearer | `{wrappedDek, recoveryDek, kdf, seq}`, used when joining. |
| `POST /sync` | bearer | The single sync round trip (below). |
| `POST /vault/rekey` | bearer | `{kdf, authKey, wrappedDek}` atomically replaces the passphrase wrapping (passphrase change or recovery). The recovery wrapping is left alone. |
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

**Exception, because a delete beats an edit (3.6):** a pushed edit whose document is a server tombstone is always returned as a conflict, and the device applies the delete. A pushed delete is accepted whatever its `baseRev`.

Rate limits: a small D1 counter on `/vaults/:id/kdf` and on failed bearer checks. The keys are high-entropy, but there's no reason to let anyone hammer the endpoint.

---

## 2. Passphrase design (decided: end-to-end)

### 2.1 Why end-to-end

With auth only, Cloudflare would store readable names, phone numbers, emails and notes about everyone in your contacts. With end-to-end encryption it stores ciphertext plus document count, sizes and edit times. Today the data only leaves the device as JSON backups, which are plaintext on Drive. E2EE sync keeps sync at least that private. The costs: merging has to happen on the device, server rows are opaque when debugging, and about 150 lines of WebCrypto (built in, no dependency).

### 2.2 Keys

All WebCrypto, so no dependency. (Argon2 isn't in WebCrypto, so the KDF is PBKDF2.)

```
passphrase ──PBKDF2-SHA256(salt 16 B, 600 000 iter)──► root (256 bit)
root ──HKDF("kit-auth-v1")──► authKey (32 B)   → bearer token; server keeps SHA-256(authKey)
root ──HKDF("kit-kek-v1")───► KEK (AES-KW 256) → wraps the DEK

recoveryKey (random 128 bit, shown once)
recoveryKey ──HKDF("kit-rauth-v1")──► recoveryAuthKey → server keeps SHA-256(recoveryAuthKey)
recoveryKey ──HKDF("kit-rkek-v1")───► recovery KEK    → wraps the same DEK

DEK = random AES-GCM-256, made once per vault; the server stores both wrappings
```

- **Why a separate data key (DEK)?** Changing the passphrase only re-wraps the DEK (one small `rekey` call) instead of re-encrypting every document.
- The recovery key is already 128 random bits, so it needs no slow KDF; HKDF is enough.
- KDF parameters live in the vault row, so the iteration count can be raised later (re-wrap on the next unlock).
- 600k PBKDF2 iterations take roughly 0.3 to 1 s on a phone. That only happens on enable, join and passphrase change, never on app open.
- **On the device**, the DEK is kept in IndexedDB as a **non-extractable `CryptoKey`**, and `authKey` as raw bytes, so the app doesn't ask for the passphrase on every open. Anyone holding the unlocked device can already read the plaintext contacts, so this adds no new exposure.
- **The passphrase is generated:** 6 random words from a built-in word list (the EFF short list, about 1,300 words and a few KB, or a similar one), which is about 62 bits. That's strong at 600k PBKDF2 iterations even if D1 leaked. Show it with a Copy button and "Save this in your password manager". There's no custom-passphrase option in v1, which removes the need for a strength meter. It can be added later with a minimum-strength rule if you miss it.
- **The recovery key** is shown once at setup as 26 base32 characters in groups (`KITR-XXXXX-XXXXX-…`), with Copy and Download buttons. The user ticks "I've saved it" before continuing.

### 2.3 Document encryption

- Plaintext is `JSON.stringify({ v: 1, data, updatedAt, deviceId })`. Putting `updatedAt` and `deviceId` inside the ciphertext gives merges a tie-breaker without telling the server when you edited what. (The server still sees write times.)
- `iv` is a random 12 bytes per write. Additional data is `"kit1|" + vaultId + "|" + path`, so a blob moved to another path or vault fails to decrypt.
- Remaining exposure, accepted for a personal app: the server could replay an *older* ciphertext of the same document (a rollback). Sizes reveal roughly how long each log is.

### 2.4 Setting up, adding a second device, losing the passphrase

- **Turn on sync (first device):** enter the `CREATE_TOKEN` once → the app generates the passphrase, recovery key, vault ID, salt and DEK → you save the passphrase and recovery key → `POST /vaults` → every syncable document is marked dirty and pushed. The **sync code** (the vault ID, e.g. `KIT-7Q3M-…`) is shown in Settings from then on.
- **Second device:** Settings → Sync → "Join". Enter the sync code and passphrase, or open a join link `https://<app>/#join=<vaultId>` that the first device shares with the Web Share API. The link carries only the vault ID; the `#fragment` never reaches the server, and the passphrase is always entered by hand (pasting from the password manager is fine). The device fetches the KDF parameters, derives the keys, fetches and unwraps the DEK (a wrong passphrase fails here, and the server also returns 401), then pulls everything and merges with whatever is already on the device (5.1).
- **Passphrase lost, a device is still joined:** that device holds the DEK and `authKey`, so it can generate a new passphrase (`rekey`) **without knowing the old one**. The other devices re-join with the new passphrase.
- **Passphrase lost, no device joined:** "Join with recovery key" → unwrap the DEK with the recovery KEK → generate a new passphrase (`rekey`, authenticated with the recovery auth key).
- **Passphrase and recovery key both lost, no device joined:** nobody can read the server copy, including Cloudflare. Delete the vault and start over from the newest JSON backup. **That's why the backup card and backup nag stay.** The nag keeps showing even with sync on, just less often (every 30 days instead of 7).
- **Generating a new passphrase** is the same `rekey` call. Other devices get 401 on their next sync and ask for the new passphrase.

---

## 3. Sync model on top of `store.js`

### 3.1 Where the code goes

- `store.js` keeps its public API (`doc/collection/get/set/update/delete/onSnapshot/limit`) unchanged, and **adds a `db.sync` object**, so the UI never talks to the network itself:

  ```js
  db.sync.state()                 // {enabled, status:"off"|"idle"|"syncing"|"offline"|"error"|"locked", pending, lastSyncedAt, error}
  db.sync.onState(fn)             // returns an unsubscribe function, like onSnapshot
  db.sync.enable({createToken})   // creates a vault; returns {vaultId, passphrase, recoveryKey} to show once
  db.sync.join({vaultId, passphrase | recoveryKey, mode:"merge"|"replace"})
  db.sync.unlock({passphrase})    // after a 401 from a passphrase change
  db.sync.newPassphrase()         // rekey; returns the new passphrase to show once
  db.sync.now()                   // sync right away
  db.sync.disable({deleteServerCopy})
  ```
- Network, crypto and merge code lives in a new `sync.js`, which `store.js` loads **only when sync is enabled**. With sync off, behavior is byte-for-byte today's. `sync.js` goes into the service worker's `SHELL` so it works offline.
- Snapshot `metadata.hasPendingWrites` (already in the snapshot shape, always `false` today) becomes "this document has unsynced changes". The UI can ignore it.

### 3.2 On-device bookkeeping (IndexedDB v1 → v2)

`openIDB()` moves to version 2. `onupgradeneeded` **adds** two object stores and leaves `docs` alone:

- `syncmeta`: path → `{ rev, dirty, lseq, deleted, base, updatedAt }`
  - `rev`: server rev last applied or acknowledged (0 = never synced)
  - `dirty`: has local changes not yet acknowledged. **This flag is the offline queue.** It records state, not operations, so ten edits while offline become one push.
  - `lseq`: increases on every local write. An acknowledgement only clears `dirty` if `lseq` hasn't moved since the push was built, so an edit made mid-flight isn't lost.
  - `base`: the plaintext as of `rev` (the common ancestor for three-way merges). It roughly doubles local storage, which is fine at this size, and it's what makes merges correct.
  - `deleted`: local tombstone, kept until acknowledged.
- `kv`: `deviceId`, `vaultId`, `cursor`, `enabled`, `syncUI` (5.5), the DEK (`CryptoKey`), `authKey`, and local safety snapshots (3.7).

Bookkeeping stays **out of the document values**, so backups, `S.contacts` and the UI never see it.

### 3.3 Which documents sync

Allow-list in `sync.js`:
- `data/users/local/crm`: settings (`cad`, `goal`)
- `data/users/local/crm/contacts/*`: people

Not synced: `data/users/local/meta` (`lastBackup` describes *this* device's backups), and anything new until it's added deliberately. Keeping the `local` user ID on every device is fine; the vault provides the separation.

### 3.4 The write path, and how it fits the existing queues

- **The UI's per-document `write()` queue in `index.html` stays.** It still serializes UI writes per contact and retries `unavailable`. Sync sits *below* it, inside `store.js`.
- `store.js`'s internal `write(path, value)` changes so that `persist()` updates `docs` **and** `syncmeta` (`dirty = true`, `lseq++`, `updatedAt = now`, `deleted` on delete) in **one IndexedDB transaction**, for syncable paths and only when sync is enabled. No half-recorded edits.
- **Remote changes** go through a new internal `applyRemote(path, value, rev)`. It writes `docs` and `syncmeta` (`dirty = false`, `rev`, `base = value`) in one transaction, updates `mem`, calls `notify(path)`, and posts `{path}` on the existing BroadcastChannel. **The existing `onmessage` handler already re-reads the document from IndexedDB and notifies**, so other tabs see synced changes without new code.
- **One tab syncs at a time:** a leader is chosen with `navigator.locks.request("kit-sync", …)` (Web Locks, Safari 15.4+). The other tabs still write locally, setting `dirty` in IndexedDB. The leader hears their BroadcastChannel `{path}` messages and schedules a push. If the leader tab closes, the lock passes to another tab.
- **When to sync:** on open, when `visibilitychange` makes the app visible, on `online`, 2 s after the last local write (debounced), and every 5 minutes while visible. Don't rely on Background Sync, which isn't on iOS.
- **Known race to fix in the UI, small:** `logContact()` builds the new `log` from `c.log` in `S.contacts`. If a remote check-in lands between render and tap, the update overwrites `log` without it, and because that's a plain local edit relative to `base`, the merge won't bring it back. Fix: build `log` inside the `write()` function from a fresh `await contactsCol.doc(c.id).get()`. Use the same pattern anywhere the UI does read-modify-write on arrays.

### 3.5 Pull and push loop (leader only)

1. Collect dirty syncable paths (up to 200). For each, encrypt `{data, updatedAt, deviceId}` and send `baseRev = rev`, or `deleted: true`.
2. `POST /sync {cursor, push}`.
3. `accepted`: set `rev`, `base = sent plaintext`, and clear `dirty` if `lseq` is unchanged.
4. `conflicts`: if the server copy is a tombstone, apply the delete locally (3.6). Otherwise decrypt it, **merge** (3.6) with local and base, write the result locally (still dirty), set `rev` to the server's rev, and push again on the next loop.
5. `changes`: skip any whose `rev` is already applied (echoes of our own writes). If the local copy is clean, `applyRemote`. If it's dirty, handle it as in step 4.
6. Save `cursor`. If `more`, repeat. If 410 `resync`, run a full pull with cursor 0, merging every document, which is safe because merges are idempotent.
7. Errors: offline or 5xx → back off (2 s, 4 s … 5 min) and keep the dirty flags. 401 → status `locked`, ask for the passphrase. 429 or quota → back off and show "Sync paused". A decrypt failure on one document → skip it and report it, and don't stop the rest.

### 3.6 Conflict handling: three-way merge, not whole-document last-write-wins

Whole-document last-write-wins would silently drop a check-in logged on the phone when the laptop edited that person's notes. That's the most common real conflict this app would have. So merge per field, with `base` as the common ancestor:

| Field | Rule |
|---|---|
| Changed on one side only | Take that side. |
| `log[]` | **Union** of both sides, de-duplicated by `date + channel + note`, sorted newest first, capped at 150 (the app's existing cap). |
| `lastContact`, `nextContact` | A pair: take both from the side with the later `lastContact`. On a tie, take the later `nextContact`, so a snooze on one side survives. |
| `tags[]` | Three-way set merge: additions and removals from both sides apply. |
| Any other scalar changed on both sides (`name`, `tier`, `notes`, `email`, `phone`, `city`, `metOn`, settings) | Newer `updatedAt` from the ciphertext wins. On a tie, the larger `deviceId` wins (deterministic). |
| **Edit vs. delete** | **The delete wins** (decided). Deleted people stay deleted, and the other device's edit to that person is dropped. The safety snapshot (3.7) taken before applying deletes is the way back from a mistake. |
| Present on both sides with no base (first join) | See 5.1. |

The merge must be **deterministic and idempotent**: merging the same inputs on either device gives the same result. Unit-test it as a pure function.

Optional improvement later: give new log entries an `id`, so two identical entries logged on the same day aren't collapsed into one. Without IDs, dedup on content is acceptable; identical entries are almost always the same check-in.

### 3.7 Deletes, tombstones, and the "absence isn't deletion" rule

- A local `delete()` keeps a `syncmeta` tombstone (`deleted: true, dirty: true`) and pushes `deleted: true`. The server keeps the row with `deleted = 1` and no ciphertext.
- Server tombstones older than 180 days are removed by a cleanup query that runs on `/sync` at most once a day. (Pages Functions have no Cron Triggers.) Devices behind that horizon get 410 and do a full resync.
- **A document missing from a device never means it was deleted.** Only an explicit tombstone does. That protects against iOS eviction (4.5), a new device, and a restore.
- **Safety snapshots:** before applying a batch that changes more than 20 documents, or deletes any, and at most once a day, the sync engine saves a JSON snapshot (the same format as a backup) into `kv`, keeping the last 7. A merge bug or a wrong delete then can't destroy data everywhere without a way back. Restoring uses the existing Restore code, and Settings gets a "Restore an automatic snapshot" link.

---

## 4. Trade-offs vs. today's backup and restore

### 4.1 Privacy
- **Today:** data stays on the device. Backups shared to Drive are plaintext JSON, held by Google.
- **With E2EE sync:** Cloudflare holds ciphertext, plus metadata: number of documents, sizes, edit times, IP addresses. That's arguably better than plaintext backups on Drive, but there's now a server that sees when you use the app.

### 4.2 Cost and free-tier limits
For one person with two or three devices: about 300 to 1,000 `/sync` calls a day, a few hundred D1 rows written a day, and data in the tens of MB.
- Pages static requests are free and unmetered. Pages Function calls count toward the Workers Free quota: 100,000 requests/day and 10 ms CPU per request. `_routes.json` keeps that to `/api/*`. The server does no expensive crypto (one SHA-256 per request), so the CPU limit isn't a concern.
- D1 Free: about 5M rows read/day, 100k rows written/day, 5 GB storage. Pulls read only changed rows through `docs_by_rev`.
- **Expected cost: $0.** Check the current limits on Cloudflare's pricing pages before building; they change. Hitting a limit means 429s: the dirty queue waits and nothing is lost.

### 4.3 Complexity
- **Today:** no server code; `store.js` is about 200 lines.
- **With sync:** a roughly 250-line `server/core.js` plus a small D1 adapter, migrations, a 400 to 500-line `sync.js` (crypto, loop, merge), the IndexedDB v2 upgrade, Settings UI, two-device tests, and operations: a D1 database, a `CREATE_TOKEN` secret, running migrations before pushing, the kill switch. This is the biggest cost.

### 4.4 Failure modes

| Failure | What happens | Mitigation |
|---|---|---|
| Offline / server down | App works as today; "N changes waiting" | Dirty queue, backoff |
| Merge bug | Bad data spreads to every device | Pure, tested merge; local safety snapshots; D1 Time Travel (restores the whole database to a point in time, 7 days on Free and 30 on paid); the manual backup stays |
| Accidental delete | Spreads to every device (a delete beats an edit) | Safety snapshot before applying deletes; JSON backups |
| Passphrase lost | See 2.4 | Joined device can generate a new one; recovery key; JSON backups |
| New passphrase generated on another device | 401 → "Enter your new passphrase" | `db.sync.unlock` |
| Clock skew between devices | Affects only both-sides-changed scalar tie-breaks | Server `rev` decides order everywhere else |
| Bad deploy | Clients break mid-sync | `GET /status` kill switch (`readonly`/`off`) and `minClient`; additive migrations only |
| Code pushed before its migration | API errors until the migration is applied | Run `npm run db:migrate` first; additive migrations; the client's backoff hides the gap |
| Preview deploy writing to production | Can't happen | Previews bind `keep-in-touch-preview` |
| Someone else creating vaults | D1 fills up | `CREATE_TOKEN` secret and `MAX_VAULTS` |
| Service worker caching the API | Stale pulls | `/api/` bypass in `sw.js`, with a test |

### 4.5 The iOS storage-eviction gotcha
- iOS Safari can evict site storage after about 7 days without a visit. Home Screen apps are exempt. Each of these has its own storage: Safari, the Home Screen app, in-app browsers, private tabs, preview addresses, and **each of your two addresses**.
- **Sync helps:** if a copy is evicted, join again and everything comes back. Sync also removes the "which copy has my data?" problem, because each copy can join.
- **Sync has to be careful:** eviction wipes `docs`, `syncmeta` and `kv` together (they're one origin), so an evicted device looks brand new. It doesn't send deletes, because absence isn't deletion (3.7). It also forgets the DEK, so **you need the passphrase again**, which is why setup insists on saving it to the password manager.
- Keep calling `navigator.storage.persist()` (the app already does) and keep recommending the installed app.

---

## 5. Migration steps

### 5.1 Existing on-device data
- **Upgrade (invisible):** IndexedDB v1 → v2 adds `syncmeta` and `kv` and leaves `docs` untouched. Sync is off, so nothing else changes.
- **First device to turn on sync:** mark every syncable document dirty with `baseRev 0` and push in chunks. Progress shows in `db.sync.state().pending`.
- **Joining a device that already has data** (for example from an earlier Restore). Save a safety snapshot first, then ask:
  - **"Merge with what's on this device" (default):** pull everything. Documents only on the server are applied. Documents only on this device are pushed. Documents on both with the same ID are merged with an empty base: `log` union and the `lastContact` pair as in 3.6. For other fields, prefer the side with the later `lastContact`, then the server's copy. Identical copies (the usual case after a Restore) are a no-op.
  - **"Replace this device's data with the synced data":** the safety snapshot is offered as a download first, then local syncable documents are cleared and everything is pulled.
- **The same person under two IDs** (both devices imported the same vCard separately): ID-based sync won't merge them. A later "Possible duplicates" screen can reuse the import's email-then-name matching. Not in v1.
- **Restore while sync is on:** restored documents become local edits and sync out, merging with any newer changes on other devices. Say so in the Restore confirmation.

### 5.2 The retired claude.ai artifact data
It lives in claude.ai's storage, under a different origin, so the app can't reach it, and **nothing should be built for it.** If you want any of it, do a one-off move before turning on sync: get the data out of the artifact (by any export it offers, or by asking Claude in that conversation to print it as JSON). Then use **Settings → Restore from backup**, which accepts a bare array or `{contacts:[…]}`. If you don't need it, leave it retired.

### 5.3 The address move (pages.dev → your subdomain), using sync
Both addresses serve the same Pages deployment, Function and D1, so there's no CORS and no second server.

1. Add the subdomain under Pages → Custom domains, and wait until it serves the app over HTTPS.
2. Add `MAIN_HOST` config (6.4) with two values: `host` = the subdomain, and `legacyHosts` = `["keep-in-touch-d58.pages.dev"]`.
3. **On each device, at the old address:** turn sync on (first device) or join (other devices), and let it finish (`pending` = 0).
4. **On each device, at the subdomain:** open it, install it to the Home Screen, and **join**. Everything arrives.
5. The old address shows a banner when `location.hostname` is one of `legacyHosts`: "Keep in Touch has moved to <subdomain>." The banner shows a sync status ("Your data is synced" or "N changes not synced yet") and a "Remove this copy from your Home Screen" hint. **Don't hard-redirect:** an installed copy that hasn't synced would lose access to its own data.
6. Once every device runs from the subdomain, turn sync off on the old copies (without deleting the server copy) and remove them from the Home Screen. The pages.dev address keeps working indefinitely; nothing needs retiring.

The preview-address banner keeps working: previews stay on `<hash>.keep-in-touch-d58.pages.dev`. Its check becomes "a subdomain of any of `host` or `legacyHosts`".

### 5.4 Rollout order

Each step ships on its own and passes `npm test`. Bump `APP_VERSION` and `VERSION` together on every release.

0. **Any time, independent:** add the MIT `LICENSE` and the `MAIN_HOST` config block (6.4).
1. **`store.js` bookkeeping:** IndexedDB v2, the `syncmeta` transaction in `persist`, the `applyRemote` path, and `hasPendingWrites`. No network, invisible. Fix the `logContact()` read-modify-write race at the same time.
2. **Move app files to `public/` and add `wrangler.toml`**, `_routes.json`, `functions/api/[[path]].js`, `server/core.js`, `server/store.d1.js`, migrations, `CREATE_TOKEN`, `MAX_VAULTS`, the kill switch and the preview database, all in **one commit**. Write `docs/sync-protocol.md` alongside it, and commit `wrangler.example.toml` rather than real ids. Run the migration before pushing.
3. **`sync.js` + `sw.js` `/api/` bypass, behind the hidden flag** (5.5). Use it on your own phone and laptop for a week or two, at the pages.dev address.
4. **"Sync between devices (beta)"** card in Settings, off by default. Turning it on is the opt-in.
5. **Move to the subdomain** (5.3).
6. **Publish (6.4):** README "Deploy your own", the SQLite adapter if wanted for tests, a scan of history for secrets, and a tagged release. Update `HANDOFF.md` and `README.md`.

### 5.5 Feature flag (opt-in)
- **Per device, local only:** `kv.enabled` (and `kv.vaultId`). Sync never turns on by itself and isn't synced between devices.
- **Visibility:** during step 3 the Settings card appears only after opening `#prefs?sync=1` once (remembered in `kv.syncUI`). From step 4 it's always visible, still off by default.
- **Server kill switch:** `GET /status` → `mode: "off"` makes clients stop syncing and show "Sync is paused"; `readonly` allows pulls only. `minClient` forces "Update the app to keep syncing".
- **Off means off:** with sync disabled, `sync.js` isn't loaded and **no request goes to `/api/`** (tested).

### 5.6 Tests to add
Playwright, as today. The server side runs under `wrangler pages dev public` with a local D1, which adds `wrangler` as a devDependency only; there are still no runtime dependencies. `tests/run.sh` starts it alongside (or instead of) `tests/serve.py`.

- **Crypto:** derive → encrypt → decrypt round trip; a wrong passphrase fails to unwrap and gets 401; changing the path or vault in the additional data fails to decrypt; the recovery key unwraps the same DEK.
- **Server sees only ciphertext:** after a sync, read the local D1 and assert no contact name, email or note appears anywhere.
- **Two devices** (two browser contexts, two storages): enable on A, join on B, and a person added on A appears on B; a delete on A disappears from B.
- **Offline both sides:** A logs a check-in and B edits notes on the same person while offline; after reconnecting, both devices have the check-in **and** the note. The merge result is identical on both.
- **Scalar conflict:** both sides change `tier`; the newer `updatedAt` wins on both.
- **Edit vs. delete:** A deletes and B edits the same person offline; after sync the person is gone on both, and A's safety snapshot contains them.
- **Absence isn't deletion:** clear B's storage (simulated eviction), re-join, and nothing is deleted on A.
- **Join with existing data:** B restored the same backup earlier; merge is a no-op; "Replace" works and offers the snapshot.
- **Mid-flight edit:** a local edit made while a push is in flight is still dirty after the acknowledgement and gets pushed next.
- **Tabs:** with two tabs open, only the leader calls `/api`; a remote change shows up in both tabs.
- **Service worker:** with the SW active, `/api/v1/*` responses never come from the cache.
- **Flag off:** with a fresh profile and sync off, no requests go to `/api/`, and all existing tests still pass unchanged.
- **IndexedDB upgrade:** a v1 database with contacts opens as v2 with the data intact.
- **Passphrase recovery:** generate a new passphrase on A without the old one; B gets `locked`, unlocks with the new one, and syncs. Joining a fresh device with only the recovery key works.
- **Tombstone horizon:** a cursor older than the horizon gets 410 and a full resync converges.
- **Address move:** two contexts on two hostnames pointed at the same local server (e.g. `127.0.0.1` and `localhost`) act as old and new addresses. Sync on the old one, join on the new one, and the data matches; the moved banner shows only on the legacy host.
- **Merge unit tests:** the merge as a pure function with table-driven cases (`page.evaluate` or plain `node`).
- **Protocol conformance:** the API tests drive `/api/v1/*` over plain HTTP against any base URL (`SYNC_TEST_URL`), so the same suite can check a self-hoster's deploy.
- Per `CLAUDE.md`, add a regression test for every sync bug reported from a real device.

---

## 6. Open source (decided: MIT, self-host only)

The code is published so others can deploy **their own copy**. You don't run sync for anyone else.

### 6.1 Keep sync optional
- The app stays **fully usable with no server**. The static `public/` folder alone, with on-device storage and backup/restore, works on any static host (GitHub Pages, Netlify, any web server).
- "Off means off" (5.5) doubles as a promise to self-hosters: with sync disabled, the app makes no network requests apart from loading its own files and Google Fonts. Consider self-hosting the two font files too, so that's verifiably zero third-party requests.
- The sync client talks to same-origin `/api/v1/`. A self-hoster deploys the app and the API together, so there's no "server address" setting in v1.

### 6.2 A written-down protocol
- **`docs/sync-protocol.md`** is the source of truth: endpoints, request and response shapes, the `baseRev` write rule and the tombstone override, the tombstone horizon and 410, auth, limits, and the encryption envelope (2.2, 2.3). Version it with the `/api/v1/` path and keep new fields additive.

### 6.3 A portable server core
```
server/core.js          handle(request, store, env) → response; all API logic, no platform calls
server/store.d1.js      the store interface on D1 (batch() as the transaction)
functions/api/[[path]].js   Pages entry: a few lines
```
- The store interface is small: one transaction that runs the conditional upsert and bumps `seq`, plus reads by `rev`. Plain SQLite SQL, no D1-only features.
- Optional later: `server/store.sqlite.js` on `node:sqlite` for fast tests without wrangler, or a Worker entry (`worker/index.js`) if Cloudflare retires Pages Functions. Both are a few lines on top of `core.js`.

### 6.4 Repo prep
- **License: MIT** (decided). Add `LICENSE` with the copyright holder's name and year. The README says "MIT licensed".
- **Config, not code.** One small config block at the top of the script in `index.html`:
  ```js
  const CONFIG = { host: null, legacyHosts: [] };   // the author's instance sets these
  ```
  - The preview-address banner warns only when `CONFIG.host` is set and `location.hostname` is a subdomain of `host` or a `legacyHosts` entry. For a self-hoster with nothing set, it never shows. Update `tests/preview-banner.test.js` to match.
  - The "moved" banner (5.3) shows only on a `legacyHosts` entry.
  - Cloudflare ids: commit `wrangler.example.toml` with placeholders and gitignore the real `wrangler.toml`, or keep it committed. `database_id` isn't a secret, but it's yours and won't work for anyone else, so the example file is cleaner.
  - Secrets (`CREATE_TOKEN`) only via `wrangler pages secret put`, or `.dev.vars` locally. Gitignore `.dev.vars` and `.wrangler/` from the first server commit.
  - Docs that name your address (`CLAUDE.md`, `HANDOFF.md`, `README.md`) can keep it as "the author's instance", next to instructions for deploying your own.
- **Defaults that suit a self-hoster:** `MAX_VAULTS` = 3 (one person, a spare, a test vault), and `CREATE_TOKEN` required, so a server can't be filled by strangers who find its address.
- **README "Deploy your own":** fork; create a Pages project from the fork; `npx wrangler d1 create keep-in-touch`; put the id in `wrangler.toml`; `npx wrangler d1 migrations apply DB --remote`; `npx wrangler pages secret put CREATE_TOKEN`; push. Enter the token once when turning on sync.
- **Before announcing anything:** scan the git history for secrets (there are none today, so keep it that way), and keep test fixtures fake. `tests/fixtures/iphone-contact.vcf` is "John Smith" with a 555 number, which is fine.
- **Attribution:** keep crediting Derek Sivers for the method and linking his posts, keep the app's wording your own, and don't imply he endorses it.
- **Nice to have, not blocking:** CONTRIBUTING (mainly the no-build-step and no-runtime-dependencies rules), an issue template asking for browser, device and app version, and a short SECURITY.md describing the E2EE design and how to report a flaw.
- **Hosted sync for others** is out of scope. If that ever changes, it needs signup without `CREATE_TOKEN`, per-vault byte quotas, rate limits on `POST /vaults`, expiry of idle vaults, a privacy policy, and probably the paid Workers plan. Nothing in this plan blocks it.

---

## Decisions

Settled with the user on 2026-10-29:

| # | Question | Decision |
|---|---|---|
| 1 | Add a server for sync? | **Yes**, sync only, opt-in per device. Sync is the one exception to `CLAUDE.md`'s "no server" rule. |
| 2 | Hosting | **Pages Function + D1** on the existing Pages project. No Worker. |
| 3 | Custom domain | **Yes, a subdomain of your own domain** (name not chosen yet). Move to it **together with sync**, using sync to carry each device's data (5.3). |
| 4 | Encryption | **End-to-end.** The server only sees ciphertext. |
| 5 | Passphrase | **Generated by the app, plus a one-time recovery key.** |
| 6 | Edit vs. delete | **The delete wins.** |
| 7 | License | **MIT.** |
| 8 | Who the server is for | **Just you.** Others self-host. |

Still open, and not blocking the early steps:
- **The subdomain's name**, and whether its DNS is on Cloudflare (one click) or elsewhere (a CNAME). Needed at step 5.
- **The name on the MIT copyright line.** Needed at step 0.
