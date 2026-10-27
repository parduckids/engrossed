// Just enough of IndexedDB for src/keystore.js, which node does not have.
// Every request answers on a later task, as the real one does, and a
// transaction completes after its request.

export function fakeIndexedDB() {
  const stores = new Map();
  const later = (fn) => setTimeout(fn, 0);

  const db = {
    createObjectStore(name) { stores.set(name, new Map()); },
    close() {},
    transaction(name, mode) {
      const data = stores.get(name);
      if (!data) throw new Error(`No object store ${name}`);
      const tx = { oncomplete: null, onerror: null, onabort: null, error: null };
      const ask = (run) => {
        const request = { result: undefined, error: null, onsuccess: null, onerror: null };
        later(() => {
          try {
            request.result = run();
            request.onsuccess?.();
            later(() => tx.oncomplete?.());
          } catch (error) {
            request.error = tx.error = error;
            request.onerror?.();
            tx.onabort?.();
          }
        });
        return request;
      };
      const writable = () => { if (mode !== "readwrite") throw new Error("ReadOnlyError"); };
      tx.objectStore = () => ({
        get: (key) => ask(() => data.get(key)),
        put: (value, key) => ask(() => { writable(); data.set(key, value); return key; }),
        delete: (key) => ask(() => { writable(); data.delete(key); }),
      });
      return tx;
    },
  };

  return {
    stores,
    open() {
      const request = { result: null, error: null, onsuccess: null, onerror: null, onupgradeneeded: null };
      later(() => {
        request.result = db;
        if (!stores.size) request.onupgradeneeded?.();
        request.onsuccess?.();
      });
      return request;
    },
  };
}
