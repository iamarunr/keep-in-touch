/*
 * LocalDB: a tiny on-device document store backed by IndexedDB.
 * It mirrors the small slice of the document-store API the app uses:
 *   db.doc(path) / db.collection(path) / ref.collection(sub)
 *   get, set, update, delete, onSnapshot, limit
 * Paths: even segment count = document, odd = collection.
 * Other open tabs of the app stay in sync through BroadcastChannel.
 */
(function () {
  "use strict";
  const DB_NAME = "keep-in-touch";
  const STORE = "docs";

  function openIDB() {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, 1);
      req.onupgradeneeded = () => req.result.createObjectStore(STORE);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  function err(code, message) { return { code, message }; }
  const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
  const parentOf = (p) => p.split("/").slice(0, -1).join("/");
  const segs = (p) => p.split("/").filter(Boolean).length;
  const newId = () =>
    (crypto.randomUUID ? crypto.randomUUID().replace(/-/g, "") : Date.now().toString(36) + Math.random().toString(36).slice(2)).slice(0, 20);

  async function create() {
    const idb = await openIDB();
    const mem = new Map(); // path -> data (source of truth in memory, mirrored to IndexedDB)

    await new Promise((resolve, reject) => {
      const req = idb.transaction(STORE).objectStore(STORE).openCursor();
      req.onsuccess = () => {
        const c = req.result;
        if (c) { mem.set(c.key, c.value); c.continue(); } else resolve();
      };
      req.onerror = () => reject(req.error);
    });

    function persist(path, value) {
      return new Promise((resolve, reject) => {
        const tx = idb.transaction(STORE, "readwrite");
        const st = tx.objectStore(STORE);
        if (value === undefined) st.delete(path); else st.put(value, path);
        tx.oncomplete = () => resolve();
        tx.onabort = tx.onerror = () => {
          const e = tx.error;
          reject(e && e.name === "QuotaExceededError" ? err("quota_exceeded", "Device storage is full") : err("unavailable", String(e)));
        };
      });
    }

    const docListeners = new Map(); // path -> Set(fn)
    const colListeners = new Map(); // collection path -> Set({fn, limit})

    const docSnap = (path) => {
      const d = mem.get(path);
      return {
        id: path.split("/").pop(),
        exists: d !== undefined,
        data: () => clone(d),
        metadata: { fromCache: false, hasPendingWrites: false },
      };
    };
    const querySnap = (col, limit) => {
      const docs = [...mem.keys()]
        .filter((k) => parentOf(k) === col)
        .sort()
        .slice(0, limit || Infinity)
        .map(docSnap);
      return { docs, size: docs.length, empty: !docs.length, docChanges: () => [], metadata: { fromCache: false, hasPendingWrites: false } };
    };

    let pending = new Set();
    let scheduled = false;
    function notify(path) {
      pending.add(path);
      if (scheduled) return;
      scheduled = true;
      queueMicrotask(() => {
        scheduled = false;
        const paths = pending; pending = new Set();
        const cols = new Set();
        for (const p of paths) {
          (docListeners.get(p) || []).forEach((fn) => fn(docSnap(p)));
          cols.add(parentOf(p));
        }
        for (const c of cols) (colListeners.get(c) || []).forEach((l) => l.fn(querySnap(c, l.limit)));
      });
    }

    const channel = "BroadcastChannel" in window ? new BroadcastChannel("keep-in-touch") : null;
    if (channel) {
      channel.onmessage = async (e) => {
        const path = e.data && e.data.path;
        if (!path) return;
        const value = await new Promise((resolve) => {
          const req = idb.transaction(STORE).objectStore(STORE).get(path);
          req.onsuccess = () => resolve(req.result);
          req.onerror = () => resolve(undefined);
        });
        if (value === undefined) mem.delete(path); else mem.set(path, value);
        notify(path);
      };
    }

    async function write(path, value) {
      const prev = mem.get(path);
      if (value === undefined) mem.delete(path); else mem.set(path, value);
      try {
        await persist(path, value);
      } catch (e) {
        if (prev === undefined) mem.delete(path); else mem.set(path, prev);
        notify(path);
        throw e;
      }
      notify(path);
      if (channel) channel.postMessage({ path });
    }

    function mergeDeep(base, patch) {
      const out = Array.isArray(base) ? base.slice() : { ...base };
      for (const [k, v] of Object.entries(patch)) {
        if (v && typeof v === "object" && !Array.isArray(v) && out[k] && typeof out[k] === "object" && !Array.isArray(out[k])) out[k] = mergeDeep(out[k], v);
        else out[k] = v;
      }
      return out;
    }

    function docRef(path) {
      if (segs(path) % 2 !== 0) throw new TypeError("Document paths need an even number of segments: " + path);
      return {
        id: path.split("/").pop(),
        path,
        get: async () => docSnap(path),
        set: async (data) => write(path, clone(data)),
        update: async (data) => {
          if (!mem.has(path)) throw err("invalid_argument", "Document does not exist: " + path);
          return write(path, mergeDeep(mem.get(path), clone(data)));
        },
        delete: async () => write(path, undefined),
        onSnapshot(next) {
          if (!docListeners.has(path)) docListeners.set(path, new Set());
          docListeners.get(path).add(next);
          setTimeout(() => next(docSnap(path)), 0);
          return () => docListeners.get(path).delete(next);
        },
        collection: (sub) => colRef(path + "/" + sub),
      };
    }

    function query(col, limit) {
      return {
        limit: (n) => query(col, n),
        where: () => { throw new Error("where() is not supported by LocalDB"); },
        orderBy: () => { throw new Error("orderBy() is not supported by LocalDB"); },
        get: async () => querySnap(col, limit),
        onSnapshot(next) {
          const l = { fn: next, limit };
          if (!colListeners.has(col)) colListeners.set(col, new Set());
          colListeners.get(col).add(l);
          setTimeout(() => next(querySnap(col, limit)), 0);
          return () => colListeners.get(col).delete(l);
        },
      };
    }

    function colRef(path) {
      if (segs(path) % 2 !== 1) throw new TypeError("Collection paths need an odd number of segments: " + path);
      return Object.assign(query(path), {
        path,
        doc: (id) => docRef(path + "/" + (id || newId())),
        add: async (data) => { const r = docRef(path + "/" + newId()); await r.set(data); return r; },
      });
    }

    return { doc: docRef, collection: colRef };
  }

  window.LocalDB = { create };
})();
