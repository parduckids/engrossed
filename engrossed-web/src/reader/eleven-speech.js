// Reading a card aloud with an ElevenLabs voice, for a reader who saved a key.
//
// This runs inside the reader on someone else's page, so it never holds the
// key. It sends the card's text to the service worker, which reads the key from
// chrome.storage.local and makes the request, and it gets the MP3 back as
// base64. Nothing here touches chrome.* until a method is called.
//
// Playback is Web Audio rather than an <audio> element. A page's media-src CSP
// can block blob: and data: URLs; Web Audio is not governed by it.
//
// Billing: one request per card spoken, and at most one card fetched ahead.
// Every answer is kept (about twenty cards), so Back and "Read it again" do
// not pay twice, and a failure is kept too, so nothing is ever asked twice.

// The same words as MESSAGES.unreachable in src/eleven.js, which the reader
// cannot import: it is not web-accessible, and does not need to be.
export const UNREACHABLE = "Couldn't reach ElevenLabs.";

const CACHE_SIZE = 20;
// A card that is not cached waits this long before it is asked for, so
// stepping quickly through cards while listening does not pay for each one.
const SETTLE_MS = 250;
// The next card is asked for once this one has been playing a moment, for the
// same reason. Never later than halfway through, so it is ready in time.
const PREFETCH_AFTER_MS = 1200;
// The service worker gives up on ElevenLabs after 20 seconds. This is the
// backstop in case the worker itself never answers.
const REPLY_TIMEOUT_MS = 25_000;

/** Cards the reader does not speak: asides, figures, and anything empty. */
export function isSpoken(chunk) {
  return Boolean(chunk) && chunk.kind !== "aside" && chunk.kind !== "figure" && Boolean(chunk.text?.trim());
}

/**
 * The card that will actually be spoken after `index`, or -1. Asides and
 * figures are passed over, as listening passes over them. A checkpoint in
 * between stops the search: the reader may choose to read the stretch again.
 */
export function nextSpokenIndex(chunks, index, checkpointAfter = () => false) {
  for (let i = index + 1; i < chunks.length; i += 1) {
    if (checkpointAfter(i - 1)) return -1;
    if (isSpoken(chunks[i])) return i;
  }
  return -1;
}

function sendToWorker(message) {
  return chrome.runtime.sendMessage(message);
}

function within(promise, ms, fallback) {
  let timer;
  return Promise.race([
    Promise.resolve(promise).finally(() => clearTimeout(timer)),
    new Promise((resolve) => { timer = setTimeout(() => resolve(fallback), ms); }),
  ]);
}

function fromBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** Whether this computer has a key, and the voices to list. Never the key. */
export async function elevenStatus(send = sendToWorker) {
  try {
    const reply = await within(send({ type: "eleven:status" }), 2000, null);
    const voices = Array.isArray(reply?.voices)
      ? reply.voices.filter((v) => typeof v?.uri === "string" && typeof v?.label === "string")
      : [];
    return { configured: reply?.configured === true && voices.length > 0, voices };
  } catch {
    return { configured: false, voices: [] };
  }
}

/** Asks the service worker to open the options page, where the key is entered. */
export function openElevenOptions(send = sendToWorker) {
  try { Promise.resolve(send({ type: "eleven:options" })).catch(() => {}); } catch { /* ignore */ }
}

export class ElevenNarrator {
  constructor({ send = sendToWorker, createContext = () => new AudioContext() } = {}) {
    this.send = send;
    this.createContext = createContext;
    // The same token pattern as the built-in Narrator: each speak() takes a
    // fresh one, and an answer or an `ended` for an older one is dropped. A
    // late answer must never start playing over the card the reader moved to.
    this.token = 0;
    this.context = null;
    this.source = null;
    this.timer = null;
    this.prefetchTimer = null;
    this.cache = new Map();
  }

  // Called from the Listen click. Chrome only lets an AudioContext start in
  // response to the reader doing something.
  unlock() {
    try {
      if (!this.context) this.context = this.createContext();
      if (this.context.state === "suspended") Promise.resolve(this.context.resume()).catch(() => {});
    } catch {
      this.context = null;
    }
  }

  /**
   * Reads one card. onDone when it finishes; onError(message) if ElevenLabs
   * could not read it, so the caller can use the built-in voice instead.
   * `next` is the text of the card that will be read after this one.
   */
  speak(text, { voice, rate = 1, next = null } = {}, onDone, onError) {
    this.stop();
    const token = ++this.token;
    if (!isSpoken({ text })) { onDone?.(); return; }
    const key = cacheKey(voice, rate, text);

    const run = async () => {
      this.timer = null;
      if (token !== this.token) return;
      const result = await this.fetch(key, text, voice, rate);
      if (token !== this.token) return;
      if (!result.ok) { onError?.(result.message); return; }

      let buffer;
      try {
        buffer = await this.decode(result.bytes);
      } catch {
        if (token === this.token) onError?.(UNREACHABLE);
        return;
      }
      if (token !== this.token) return;

      try {
        this.play(buffer, token, onDone);
      } catch {
        onError?.(UNREACHABLE);
        return;
      }

      if (next && isSpoken({ text: next })) {
        const nextKey = cacheKey(voice, rate, next);
        const delay = Math.min(PREFETCH_AFTER_MS, (buffer.duration || 0) * 500);
        this.prefetchTimer = setTimeout(() => {
          this.prefetchTimer = null;
          if (token === this.token && !this.cache.has(nextKey)) this.fetch(nextKey, next, voice, rate);
        }, delay);
      }
    };

    if (this.cache.has(key)) run();
    else this.timer = setTimeout(run, SETTLE_MS);
  }

  stop() {
    this.token += 1;
    clearTimeout(this.timer);
    clearTimeout(this.prefetchTimer);
    this.timer = null;
    this.prefetchTimer = null;
    const source = this.source;
    this.source = null;
    if (source) {
      // stop() fires `ended`, which must not count as the card finishing.
      source.onended = null;
      try { source.stop(); } catch { /* not started */ }
      try { source.disconnect(); } catch { /* ignore */ }
    }
  }

  close() {
    this.stop();
    this.cache.clear();
    const context = this.context;
    this.context = null;
    try { Promise.resolve(context?.close()).catch(() => {}); } catch { /* ignore */ }
  }

  // One request per card, ever. The promise is cached as soon as it is made,
  // so a card asked for while its prefetch is still in flight waits for that
  // rather than paying again.
  fetch(key, text, voice, rate) {
    const cached = this.cache.get(key);
    if (cached) {
      this.cache.delete(key);
      this.cache.set(key, cached);
      return cached;
    }
    let pending;
    try {
      pending = within(this.send({ type: "eleven:speak", text, voice, speed: rate }), REPLY_TIMEOUT_MS, null);
    } catch {
      pending = Promise.resolve(null);
    }
    const result = pending.then(
      (reply) => {
        if (reply?.ok === true && typeof reply.audio === "string" && reply.audio) {
          return { ok: true, bytes: fromBase64(reply.audio) };
        }
        // An empty message means no key on this computer: fall back quietly.
        return { ok: false, message: typeof reply?.message === "string" ? reply.message : UNREACHABLE };
      },
      () => ({ ok: false, message: UNREACHABLE }),
    ).catch(() => ({ ok: false, message: UNREACHABLE }));

    this.cache.set(key, result);
    while (this.cache.size > CACHE_SIZE) this.cache.delete(this.cache.keys().next().value);
    return result;
  }

  async decode(bytes) {
    this.unlock();
    const context = this.context;
    if (!context) throw new Error("No audio output.");
    if (context.state !== "running") await within(context.resume(), 1000, null);
    // A context that will not start would play nothing and never end, which
    // would leave the reader waiting in silence. Better the built-in voice.
    if (context.state !== "running") throw new Error("Audio did not start.");
    // decodeAudioData takes ownership of the buffer it is given, and the cached
    // copy has to survive for Back.
    return context.decodeAudioData(bytes.slice().buffer);
  }

  play(buffer, token, onDone) {
    const context = this.context;
    const source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(context.destination);
    source.onended = () => {
      if (token !== this.token || this.source !== source) return;
      this.source = null;
      onDone?.();
    };
    this.source = source;
    source.start();
  }
}

// Voice, rate and text. Never the key.
function cacheKey(voice, rate, text) {
  return `${voice}\u0000${rate}\u0000${text}`;
}
