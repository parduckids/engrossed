// The options page: the one place an ElevenLabs key is entered.
//
// It is the extension's own page, so no website's scripts can see what is
// typed here. The reader overlay lives inside someone else's page, which is
// why it only has a button that opens this one.
//
// The key goes to chrome.storage.local and nowhere else: never sync, which
// leaves the device, and never shown back once saved. It is not tested on
// save. The first card read aloud reveals any problem, in plain words.

import { DEFAULT_VOICE, KEY_STORAGE, VOICE_PREFIX, cleanKey, uriFor, voiceChoices } from "./eleven.js";
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

async function hasKey() {
  try {
    const got = await chrome.storage.local.get(KEY_STORAGE);
    return Boolean(cleanKey(got?.[KEY_STORAGE]));
  } catch {
    return false;
  }
}

async function render() {
  const [configured, settings] = await Promise.all([hasKey(), loadSettings()]);
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
    await chrome.storage.local.set({ [KEY_STORAGE]: key });
  } catch {
    say("Couldn't save the key. Try again.");
    return;
  }
  // Someone who adds a key wants to hear it, so the automatic voice becomes
  // an ElevenLabs one. A built-in voice they chose on purpose is left alone.
  const settings = await loadSettings();
  if (!settings.voiceURI) {
    settings.voiceURI = uriFor(DEFAULT_VOICE);
    await flushSettings(settings);
  }
  say("Key saved.");
  render();
});

remove.addEventListener("click", async () => {
  try {
    await chrome.storage.local.remove(KEY_STORAGE);
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
  render();
  input.focus();
});

// Kept in step with a change made in another window, or in the reader.
chrome.storage.onChanged.addListener((changes, area) => {
  if ((area === "local" && KEY_STORAGE in changes) || (area === "sync" && "settings" in changes)) render();
});

render();
