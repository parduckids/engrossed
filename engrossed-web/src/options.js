// The options page: the one place an ElevenLabs key is entered.
//
// It is the extension's own page, so no website's scripts can see what is
// typed here. The reader overlay lives inside someone else's page, which is
// why it only has a button that opens this one.
//
// The key goes to the extension's own IndexedDB (src/keystore.js) and nowhere
// else: never chrome.storage, which the reader on the page can read, never
// sync, which leaves the device, and never shown back once saved. It is not
// tested on save. The first card read aloud reveals any problem, in plain words.

import { DEFAULT_VOICE, VOICE_PREFIX, cleanKey, uriFor, voiceChoices, voiceFromURI } from "./eleven.js";
import { readKey, removeKey, saveKey } from "./keystore.js";
import { loadSettings, flushSettings } from "./reader/settings.js";

const form = document.getElementById("key-form");
const input = document.getElementById("key");
const saved = document.getElementById("saved");
const remove = document.getElementById("remove");
const voiceSection = document.getElementById("voice");
const voices = document.getElementById("voices");
const status = document.getElementById("status");

const voiceButtons = voiceChoices().map(({ uri, label }) => {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = label;
  button.dataset.voice = uri;
  button.addEventListener("click", () => setVoice(uri));
  voices.appendChild(button);
  return button;
});

async function render() {
  const [key, settings] = await Promise.all([readKey(), loadSettings()]);
  const configured = Boolean(key);
  form.hidden = configured;
  saved.hidden = !configured;
  voiceSection.hidden = !configured;
  for (const button of voiceButtons) {
    button.setAttribute("aria-pressed", String(button.dataset.voice === settings.voiceURI));
  }
}

function say(text) {
  status.textContent = text;
}

async function setVoice(uri) {
  const settings = await loadSettings();
  settings.voiceURI = uri;
  await flushSettings(settings);
  render();
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const key = cleanKey(input.value);
  // Cleared straight away: the key is never shown back.
  input.value = "";
  if (!key) {
    say("Paste a key first.");
    input.focus();
    return;
  }
  try {
    await saveKey(key);
  } catch {
    say("Couldn't save the key. Try again.");
    return;
  }
  // Someone who adds a key wants to hear the voices, so read aloud switches to
  // one straight away. A Woman or Man already chosen is kept.
  const settings = await loadSettings();
  if (!voiceFromURI(settings.voiceURI)) {
    settings.voiceURI = uriFor(DEFAULT_VOICE);
    await flushSettings(settings);
  }
  say("Key saved.");
  render();
});

remove.addEventListener("click", async () => {
  try {
    await removeKey();
  } catch {
    say("Couldn't remove the key. Try again.");
    return;
  }
  const settings = await loadSettings();
  if (settings.voiceURI.startsWith(VOICE_PREFIX)) {
    settings.voiceURI = "";
    await flushSettings(settings);
  }
  say("Key removed.");
  // After render, which is what unhides the field.
  await render();
  input.focus();
});

// Kept in step with a voice picked in the reader, and with a key saved or
// removed in another window of this page.
chrome.storage.sync.onChanged.addListener((changes) => {
  if ("settings" in changes) render();
});
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) render();
});

render();
