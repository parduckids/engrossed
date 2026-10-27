// Where the ElevenLabs key is kept: the extension's own IndexedDB.
//
// Not chrome.storage. The reader is a content script inside someone else's
// page, and it uses chrome.storage.local itself for positions and sprints, so
// anything kept there can be read from that page's process (and every change
// to it is broadcast through storage.onChanged). IndexedDB belongs to an
// origin, and a content script works with the page's origin, so this database
// can be opened only by the extension's own pages and its service worker.
// It is never synced, and it goes when the extension is removed.
//
// Only the options page (which saves and removes the key) and the service
// worker (which reads it to make a request) import this file.

import { cleanKey } from "./eleven.js";

const DB_NAME = "engrossed";
const STORE = "secrets";
const RECORD = "elevenKey";

// Where an earlier build kept the key: chrome.storage.local, under this name.
export const LEGACY_LOCAL_KEY = "elevenKey";

function done(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function withStore(mode, use) {
  const opening = indexedDB.open(DB_NAME, 1);
  opening.onupgradeneeded = () => opening.result.createObjectStore(STORE);
  const db = await done(opening);
  try {
    const tx = db.transaction(STORE, mode);
    const committed = new Promise((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    });
    const [result] = await Promise.all([done(use(tx.objectStore(STORE))), committed]);
    return result;
  } finally {
    db.close();
  }
}

/** The saved key, trimmed, or "" if there is none or it cannot be read. */
export async function readKey() {
  try {
    return cleanKey(await withStore("readonly", (store) => store.get(RECORD)));
  } catch {
    return "";
  }
}

/** Saves a key. Throws if it is empty or cannot be stored. */
export async function saveKey(raw) {
  const key = cleanKey(raw);
  if (!key) throw new Error("No key to save.");
  await withStore("readwrite", (store) => store.put(key, RECORD));
}

/** Deletes the key. The record is gone, not blanked. */
export async function removeKey() {
  await withStore("readwrite", (store) => store.delete(RECORD));
}

/**
 * Moves a key saved by an earlier build out of chrome.storage.local, where the
 * reader could read it, and deletes it from there whatever happens.
 */
export async function moveLegacyKey(local) {
  try {
    const got = await local.get(LEGACY_LOCAL_KEY);
    const old = cleanKey(got?.[LEGACY_LOCAL_KEY]);
    if (old && !(await readKey())) await saveKey(old);
  } catch {
    /* nothing to move, or nowhere to move it */
  }
  try { await local.remove(LEGACY_LOCAL_KEY); } catch { /* ignore */ }
}
