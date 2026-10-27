// ElevenLabs voices: the optional paid read-aloud.
//
// Pure logic, no chrome.* anywhere, so the node tests can import it. The
// service worker is the only place that makes a request, and the options page
// is the only place a key is typed. The reader on the page never sees the key
// and cannot read where it is kept: it sends the card's text to the service
// worker and gets audio back.
//
// Both voice ids live here and nowhere else. They are permanent library voices,
// which need a paid ElevenLabs plan.

export const VOICES = Object.freeze({
  woman: Object.freeze({ id: "WQP7cQUF5aAS6Axh5yaa", label: "Woman" }), // Elara, "Crisp Pro Narrator"
  man: Object.freeze({ id: "gOupLcAkjEnguROwi4oS", label: "Man" }),     // Darian, "Warm Grounded Storyteller"
});

// The reader's settings.voiceURI holds "eleven:woman" or "eleven:man" for these.
// Settings sync between machines, so a machine with no key sees an id that
// matches no built-in voice and falls back to the automatic one.
export const VOICE_PREFIX = "eleven:";
export const DEFAULT_VOICE = "woman";

// The key itself is kept by src/keystore.js, in the extension's own IndexedDB:
// never chrome.storage, which the reader on the page can read, and never sync,
// which leaves the device.

// Flash, not multilingual_v2: flash reads Hungarian, multilingual_v2 does not.
export const MODEL_ID = "eleven_flash_v2_5";
export const OUTPUT_FORMAT = "mp3_44100_64";
const ENDPOINT = "https://api.elevenlabs.io/v1/text-to-speech/";

// ElevenLabs refuses a speed outside this range (400 invalid_voice_settings).
// The reader's own rate goes 0.6 to 1.8, so it is clamped before every request.
export const SPEED_RANGE = Object.freeze([0.7, 1.2]);

export const MESSAGES = Object.freeze({
  badKey: "ElevenLabs didn't accept that key.",
  noPermission: "That key isn't allowed to make speech. Give it Text to Speech access in ElevenLabs.",
  needsPaidPlan: "These voices need a paid ElevenLabs plan.",
  noVoice: "That voice isn't available on your ElevenLabs account.",
  busy: "ElevenLabs is out of credits or busy right now.",
  unreachable: "Couldn't reach ElevenLabs.",
});

export function isVoice(name) {
  return typeof name === "string" && Object.hasOwn(VOICES, name);
}

export function uriFor(name) {
  return VOICE_PREFIX + name;
}

/** "eleven:woman" gives "woman"; anything else, including a built-in voice, gives null. */
export function voiceFromURI(voiceURI) {
  if (typeof voiceURI !== "string" || !voiceURI.startsWith(VOICE_PREFIX)) return null;
  const name = voiceURI.slice(VOICE_PREFIX.length);
  return isVoice(name) ? name : null;
}

/** The entries for a voice list. Labels only: the ids stay in this file. */
export function voiceChoices() {
  return Object.entries(VOICES).map(([name, voice]) => ({ uri: uriFor(name), label: voice.label }));
}

/** The reader's rate (0.6 to 1.8, default 1) as a speed ElevenLabs accepts. */
export function speedFor(rate) {
  const n = typeof rate === "number" ? rate : Number.parseFloat(rate);
  const value = Number.isFinite(n) ? n : 1;
  const [low, high] = SPEED_RANGE;
  return Math.round(Math.min(high, Math.max(low, value)) * 100) / 100;
}

export function cleanKey(raw) {
  return typeof raw === "string" ? raw.trim() : "";
}

// Empty or whitespace-only text is answered with a 200 and still costs credits.
export function speakable(text) {
  return typeof text === "string" && text.trim().length > 0;
}

/**
 * The fetch() arguments for one card. Throws rather than build a request that
 * would cost credits for nothing: no key, an unknown voice, or no text.
 * The key goes in a header only, never in the URL or the body.
 */
export function buildRequest(key, voice, text, speed) {
  const apiKey = cleanKey(key);
  if (!apiKey) throw new Error("No ElevenLabs key is saved.");
  if (!isVoice(voice)) throw new Error("Unknown ElevenLabs voice.");
  if (!speakable(text)) throw new Error("Nothing to read aloud.");

  return {
    url: `${ENDPOINT}${encodeURIComponent(VOICES[voice].id)}?output_format=${OUTPUT_FORMAT}`,
    init: {
      method: "POST",
      headers: {
        "xi-api-key": apiKey,
        "Content-Type": "application/json",
        Accept: "audio/mpeg",
      },
      body: JSON.stringify({
        text: text.trim(),
        model_id: MODEL_ID,
        voice_settings: { stability: 0.5, similarity_boost: 0.75, speed: speedFor(speed) },
      }),
      credentials: "omit",
      cache: "no-store",
      referrerPolicy: "no-referrer",
    },
  };
}

/** The `detail.status` of an ElevenLabs error body, or "" if it has none. */
export function detailStatusOf(body) {
  try {
    const parsed = typeof body === "string" ? JSON.parse(body) : body;
    const status = parsed?.detail?.status;
    return typeof status === "string" ? status : "";
  } catch {
    return "";
  }
}

/** What to tell the reader about a failed request. Status 0 means it never got an answer. */
export function messageFor(status, detailStatus) {
  if (status === 429) return MESSAGES.busy;
  if (status === 401 && detailStatus === "invalid_api_key") return MESSAGES.badKey;
  if (status === 401 && detailStatus === "missing_permissions") return MESSAGES.noPermission;
  // ElevenLabs answers 401 rather than 429 when the account has run out of characters.
  if (status === 401 && detailStatus === "quota_exceeded") return MESSAGES.busy;
  if (status === 402 && detailStatus === "payment_required") return MESSAGES.needsPaidPlan;
  if (status === 404 && detailStatus === "voice_not_found") return MESSAGES.noVoice;
  return MESSAGES.unreachable;
}

// Extension messaging is JSON, so an ArrayBuffer does not survive the trip.
// Chunked, because String.fromCharCode(...bytes) overflows the stack on a
// buffer of a few hundred kilobytes.
export function toBase64(buffer) {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}
