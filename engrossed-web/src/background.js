// The service worker. Its main job is to put the reader into the current tab
// when the toolbar button is clicked. Its other job is the optional ElevenLabs
// voices: it is the one place that reads the key and makes the request, so the
// reader, which runs inside someone else's page, never holds the key.
//
// Nothing is injected until that click. The extension asks for `activeTab`
// rather than host permissions, so it cannot read any page until you point it
// at one, and installing it shows no "read your data on all websites" warning.
// In MV3 this worker is terminated whenever Chrome feels like it, so it holds
// no state at all: everything that must survive lives in chrome.storage, or,
// for the ElevenLabs key, in the extension's own IndexedDB (src/keystore.js).

import {
  MESSAGES, buildRequest, detailStatusOf, messageFor, speakable, toBase64,
  voiceChoices, voiceFromURI,
} from "./eleven.js";
import { moveLegacyKey, readKey } from "./keystore.js";

// Pages Chrome forbids every extension from touching. The New Tab page is the
// one that matters most: it is where a first click is likely to land, and a
// click that does nothing there reads as "the extension is broken".
const BLOCKED = /^(chrome|edge|about|devtools|view-source|chrome-extension|chrome-search):/i;
const WEB_STORE = /^https:\/\/(chromewebstore\.google\.com|chrome\.google\.com\/webstore)/i;

// Listeners are registered at the top level, never inside a callback. In MV3 a
// listener added asynchronously is missing when Chrome wakes the worker for an
// event, and the click is silently dropped.
chrome.runtime.onInstalled.addListener(({ reason }) => {
  if (reason === "install") openWelcome();
  // An earlier build kept the ElevenLabs key in chrome.storage.local, which
  // the reader on the page can read. Take it out of there.
  moveLegacyKey(chrome.storage.local);
});

chrome.action.onClicked.addListener(async (tab) => {
  if (!tab?.id) return;

  if (!tab.url || BLOCKED.test(tab.url) || WEB_STORE.test(tab.url)) {
    openWelcome("blocked");
    return;
  }

  try {
    // If the reader is already up, this toggles it back off.
    const [already] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => Boolean(document.getElementById("engrossed-root")),
    });

    if (already?.result) {
      await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: () => window.__engrossedClose?.(),
      });
      return;
    }

    // Readability first: it declares a top-level function, which lands in the
    // isolated world's global scope where the bootstrap can pick it up.
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      files: ["vendor/readability.js", "src/reader/inject.js"],
    });
  } catch (error) {
    // Injection itself was refused. Chrome's PDF viewer is the common case,
    // and the one worth a specific answer: PDFs are what the app is for.
    console.warn("Engrossed could not open on this page:", error);
    openWelcome(/\.pdf($|[?#])/i.test(tab.url) ? "pdf" : "blocked");
  }
});

// Messages from the reader and the options page. Only this extension's own
// contexts are answered. The page itself cannot send these: the reader's
// content script runs in an isolated world, and there is no externally
// connectable entry in the manifest.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id || typeof message?.type !== "string") return false;

  if (message.type === "eleven:status") {
    readKey().then((key) => sendResponse({ configured: Boolean(key), voices: voiceChoices() }));
    return true;
  }
  if (message.type === "eleven:speak") {
    speakWithEleven(message).then(sendResponse, () => sendResponse({ ok: false, message: MESSAGES.unreachable }));
    return true;
  }
  if (message.type === "eleven:options") {
    // Content scripts cannot call this themselves.
    Promise.resolve(chrome.runtime.openOptionsPage()).catch(() => {});
    sendResponse({ ok: true });
    return false;
  }
  return false;
});

// ElevenLabs gets this long before the built-in voice takes the card.
const ELEVEN_TIMEOUT_MS = 20_000;

// One card, one request. No retries: on any failure the reader reads that card
// with the built-in voice and stays on it, so a broken key costs one request.
// Nothing here is logged. The key must never reach a console, a message or a URL.
async function speakWithEleven({ text, voice, speed }) {
  const name = voiceFromURI(voice);
  if (!name || !speakable(text)) return { ok: false, message: MESSAGES.unreachable };

  const key = await readKey();
  // Settings sync, so the voice can be chosen on a machine with no key. That
  // is not a fault: the built-in voice reads instead, without a message.
  if (!key) return { ok: false, message: "" };

  let response;
  try {
    const { url, init } = buildRequest(key, name, text, speed);
    response = await fetch(url, { ...init, signal: AbortSignal.timeout(ELEVEN_TIMEOUT_MS) });
  } catch {
    return { ok: false, message: MESSAGES.unreachable };
  }

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    return { ok: false, message: messageFor(response.status, detailStatusOf(body)) };
  }
  const audio = await response.arrayBuffer().catch(() => null);
  if (!audio?.byteLength) return { ok: false, message: MESSAGES.unreachable };
  return { ok: true, audio: toBase64(audio) };
}

function openWelcome(reason) {
  const page = chrome.runtime.getURL("src/welcome.html") + (reason ? `?${reason}` : "");
  chrome.tabs.create({ url: page });
}
