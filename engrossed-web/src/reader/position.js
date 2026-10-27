// Where you got to, per article.
//
// This is the whole promise of Engrossed: come back tomorrow and be exactly
// where you were. It is also the part that is easiest to get subtly wrong, so
// the recovery rules here are the ones the app arrived at after getting them
// wrong first.

const KEY = "positions";
const LIMIT = 500;

// Tracking parameters change between visits to the same article, so leaving
// them in the key means every share link is a different "article" and your
// place is lost. The hash goes too, for the same reason.
const JUNK = /^(utm_|fbclid$|gclid$|mc_cid$|mc_eid$|ref$|ref_src$|igshid$|si$|at_)/i;

export function keyFor(url = location.href) {
  try {
    const parsed = new URL(url);
    // A plain "#section-3" is a scroll target and is noise in the key. But
    // "#/posts/42" and "#!/article" ARE the route on older single-page sites,
    // and stripping those collapses every article on the site to one key.
    if (!/^#[/!]/.test(parsed.hash)) parsed.hash = "";
    const params = [...parsed.searchParams.keys()];
    for (const name of params) if (JUNK.test(name)) parsed.searchParams.delete(name);
    parsed.searchParams.sort();
    return parsed.toString();
  } catch {
    return url;
  }
}

// The first twelve words of the card, exactly as the app records it. Enough to
// find the place again, short enough to store a few hundred of them.
export function snippetOf(text) {
  return (text || "").split(/\s+/).filter(Boolean).slice(0, 12).join(" ");
}

async function all() {
  try {
    const got = await chrome.storage.local.get(KEY);
    return got?.[KEY] || {};
  } catch {
    return {};
  }
}

export async function save({ chunkIndex, blockIndex, blockHash, snippet, total, title }) {
  const store = await all();
  store[keyFor()] = {
    chunkIndex, blockIndex, blockHash, snippet, total, title, updatedAt: Date.now(),
  };

  // Keep the most recent few hundred. Unbounded growth in a synced-adjacent
  // store is how an extension ends up quietly costing someone megabytes.
  const entries = Object.entries(store);
  if (entries.length > LIMIT) {
    entries.sort((a, b) => (b[1].updatedAt || 0) - (a[1].updatedAt || 0));
    const trimmed = {};
    for (const [k, v] of entries.slice(0, LIMIT)) trimmed[k] = v;
    try { await chrome.storage.local.set({ [KEY]: trimmed }); } catch { /* full */ }
    return;
  }

  try { await chrome.storage.local.set({ [KEY]: store }); } catch { /* full */ }
}

export async function load() {
  const store = await all();
  return store[keyFor()] || null;
}

export async function clear() {
  const store = await all();
  delete store[keyFor()];
  try { await chrome.storage.local.set({ [KEY]: store }); } catch { /* ignore */ }
}

/**
 * Works out which card a saved position refers to now.
 *
 * The saved chunk index is only meaningful while the chunking is unchanged.
 * Change card size, or let the site re-edit the article, and it means nothing.
 * So the real anchor is the source BLOCK — the paragraph — which survives
 * re-chunking intact, plus a hash of its text, which survives the paragraphs
 * around it being added to or removed.
 *
 * Anchoring on a window of chunk indices instead would be anchoring in the one
 * coordinate system that just changed: switching from large cards to small ones
 * moves every index by a factor of two and a half, so the window either misses
 * or lands on the wrong paragraph entirely. The app had the same problem and
 * solved it with the PDF page number; a block ordinal is the web's version of
 * that, and a finer one.
 */
export function resolve(saved, chunks) {
  if (!saved || !chunks.length) return 0;
  const clamped = Math.min(Math.max(0, saved.chunkIndex | 0), chunks.length - 1);

  // 1. Nothing changed at all.
  if (saved.total === chunks.length
      && chunks[clamped]?.blockIndex === saved.blockIndex) {
    return clamped;
  }

  // 2. The same paragraph, wherever it has moved to. This is what survives the
  //    site inserting a correction above what you were reading.
  if (saved.blockHash) {
    const byHash = chunks.findIndex((c) => c.blockHash === saved.blockHash);
    if (byHash >= 0) return byHash;
  }

  // 3. The same block ordinal, re-chunked. Exact for a card-size change.
  if (typeof saved.blockIndex === "number") {
    const byBlock = chunks.findIndex((c) => c.blockIndex === saved.blockIndex);
    if (byBlock >= 0) return byBlock;
    const after = chunks.findIndex((c) => c.blockIndex > saved.blockIndex);
    if (after >= 0) return after;
  }

  // 4. The words themselves, near where they were. A forty-character prefix is
  //    not unique in a long document, so this only runs close to the old place.
  const snippet = (saved.snippet || "").trim();
  if (snippet.length > 12) {
    const head = snippet.slice(0, 40);
    const low = Math.max(0, clamped - 20);
    const high = Math.min(chunks.length - 1, clamped + 20);
    for (let i = low; i <= high; i += 1) {
      if (chunks[i].text?.startsWith(head)) return i;
    }
  }

  // 5. Keep the proportional place rather than starting the article over.
  if (saved.total > 0) {
    return Math.min(chunks.length - 1,
                    Math.round((clamped / saved.total) * chunks.length));
  }
  return clamped;
}
