// Reading preferences, with the same names, ranges and defaults as the app.
//
// These live in chrome.storage.sync so they follow you between machines. They
// are tiny — a dozen scalars — and well inside the sync quota.

export const DEFAULTS = {
  mode: "cards",        // cards | flow
  chunkSize: "standard", // cozy | standard | roomy
  theme: "paper",       // paper | warm | grey | dark
  font: "serif",        // serif | sans | rounded | mono
  fontSize: 20,         // 15 – 44
  lineSpacing: 1.5,     // 1.1 – 2.2
  lineWidth: 60,        // 34 – 86 characters
  fixationBolding: false,
  checkpoints: true,     // ask for a one-line recap at the end of each stretch
  rewindOnResume: true,  // back up one card when you come back to an article
  sprintEnabled: true,
  sprintMinutes: 20,     // 5 – 45
  speechRate: 1,         // 0.6 – 1.8
  voiceURI: "",          // "" means the automatic, on-device choice
};

export const LIMITS = {
  fontSize: [15, 44, 1],
  lineSpacing: [1.1, 2.2, 0.05],
  lineWidth: [34, 86, 1],
  sprintMinutes: [5, 45, 5],
  speechRate: [0.6, 1.8, 0.05],
};

export const THEMES = ["paper", "warm", "grey", "dark"];
export const THEME_LABELS = { paper: "Paper", warm: "Sepia", grey: "Slate", dark: "Night" };
export const FONTS = ["serif", "sans", "rounded", "mono"];
export const FONT_LABELS = { serif: "Serif", sans: "Sans", rounded: "Rounded", mono: "Mono" };
export const SIZE_LABELS = { cozy: "Small", standard: "Medium", roomy: "Large" };
export const SIZE_DETAIL = {
  cozy: "~25 words · a sentence or two",
  standard: "~45 words · a few sentences",
  roomy: "~70 words · a short paragraph",
};

const KEY = "settings";

function clamp(value, [low, high]) {
  return Math.min(high, Math.max(low, value));
}

function sanitise(raw) {
  const s = { ...DEFAULTS, ...(raw || {}) };
  s.fontSize = clamp(Number(s.fontSize) || DEFAULTS.fontSize, LIMITS.fontSize);
  s.lineSpacing = clamp(Number(s.lineSpacing) || DEFAULTS.lineSpacing, LIMITS.lineSpacing);
  s.lineWidth = clamp(Number(s.lineWidth) || DEFAULTS.lineWidth, LIMITS.lineWidth);
  if (!THEMES.includes(s.theme)) s.theme = DEFAULTS.theme;
  if (!FONTS.includes(s.font)) s.font = DEFAULTS.font;
  if (!["cozy", "standard", "roomy"].includes(s.chunkSize)) s.chunkSize = DEFAULTS.chunkSize;
  if (!["cards", "flow"].includes(s.mode)) s.mode = DEFAULTS.mode;
  s.fixationBolding = Boolean(s.fixationBolding);
  s.checkpoints = s.checkpoints !== false;
  s.rewindOnResume = s.rewindOnResume !== false;
  s.sprintEnabled = s.sprintEnabled !== false;
  s.sprintMinutes = clamp(Number(s.sprintMinutes) || DEFAULTS.sprintMinutes, LIMITS.sprintMinutes);
  s.speechRate = clamp(Number(s.speechRate) || DEFAULTS.speechRate, LIMITS.speechRate);
  s.voiceURI = typeof s.voiceURI === "string" ? s.voiceURI : "";
  return s;
}

export async function loadSettings() {
  try {
    const got = await chrome.storage.sync.get(KEY);
    return sanitise(got?.[KEY]);
  } catch {
    // Sync can be unavailable (policy, quota, a signed-out profile). Reading
    // should still work; it just will not follow you anywhere.
    return { ...DEFAULTS };
  }
}

let saveTimer = null;

// chrome.storage.sync allows 120 writes a minute. A slider drag fires an input
// event per frame, so writing on each one blows the quota in about a second and
// then throws for the rest of the minute. Settings are applied to the page
// immediately and persisted on a trailing debounce.
export function saveSettings(settings) {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => { flushSettings(settings); }, 400);
}

export async function flushSettings(settings) {
  clearTimeout(saveTimer);
  try {
    await chrome.storage.sync.set({ [KEY]: sanitise(settings) });
  } catch (error) {
    console.warn("Engrossed: could not save settings", error);
  }
}

export function resetTypography(settings) {
  return { ...settings, fontSize: 20, lineSpacing: 1.5, lineWidth: 60 };
}
