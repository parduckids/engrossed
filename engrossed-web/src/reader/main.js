// The reader overlay.
//
// Mounted into a shadow root on the page itself rather than a separate tab, so
// the URL stays put — which is what makes "your place, per article" work
// without a side table mapping reader pages back to their sources.
//
// Movement has exactly three entry points, and each one saves your place:
//   step()   a deliberate move: Next, Back, a key, a click, a contents jump
//   advance() Next, but it stops for a checkpoint at the end of a stretch
//   drift()  the reader scrolled in Flow. Saves, but is not a step: no sprint
//            credit for text that swept past, and no checkpoint
// The app once had Flow writing the index directly, which skipped the save.
// An hour of reading in Flow was lost on closing. Keeping the index private to
// these functions is what stops that from happening again.

import { chunk, OPTIONS } from "./chunker.js";
import { extract, extractFallback } from "./extract.js";
import {
  loadSettings, saveSettings, flushSettings, resetTypography, LIMITS,
  THEMES, THEME_LABELS, FONTS, FONT_LABELS, SIZE_LABELS, SIZE_DETAIL,
} from "./settings.js";
import * as position from "./position.js";
import { fixationBolded } from "./fixation.js";
import { Sprint, loadSprint, saveSprint } from "./sprint.js";
import { Narrator, speechAvailable, voicesFor } from "./speech.js";
import {
  ElevenNarrator, elevenStatus, openElevenOptions, isSpoken, nextSpokenIndex,
} from "./eleven-speech.js";

const HOST_ID = "engrossed-root";
// Below this many sections a checkpoint is friction rather than help: a short
// article is over before there is anything to recall.
const MIN_SECTIONS_FOR_CHECKPOINTS = 3;
// Flow lays out the whole article when it can. Web articles are tens or
// hundreds of cards, not the thousands that forced the app to render a window.
const FLOW_FULL_RENDER_LIMIT = 1500;

let state = null;

function el(tag, props = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2).toLowerCase(), value);
    else if (value !== null && value !== undefined && value !== false) node.setAttribute(key, value);
  }
  for (const child of [].concat(children)) {
    if (child) node.appendChild(typeof child === "string" ? document.createTextNode(child) : child);
  }
  return node;
}

const docLang = () => document.documentElement.lang || navigator.language || "en";
const reducedMotion = () => window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

// ---------- open / close ----------

export async function open() {
  if (document.getElementById(HOST_ID)) return;

  // Whether this computer has an ElevenLabs key. The answer is a yes or no;
  // the key itself stays in the service worker.
  const [settings, eleven] = await Promise.all([loadSettings(), elevenStatus()]);
  const article = extract() || extractFallback();

  // A <dialog> opened with showModal() rather than a plain fixed-position div.
  // Any ancestor with a transform, filter or contain:paint becomes the
  // containing block for position:fixed, so a "full screen" overlay can end up
  // boxed inside someone's carousel. The top layer escapes all of that, along
  // with the entire z-index stack, and inerts the page behind us for free.
  //
  // The dialog cannot hold the shadow root itself: attachShadow only works on
  // a short list of elements, and <dialog> is not on it. Making it the host
  // threw on the first line of this function, so the reader never appeared at
  // all. The dialog supplies the top layer; a div inside it holds the shadow.
  const host = el("dialog", { id: HOST_ID });
  // Styled through the CSSOM, which a page's style-src CSP does not govern, and
  // marked important so a site stylesheet that targets `dialog` cannot box us.
  const reset = {
    position: "fixed", inset: "0", width: "100vw", height: "100vh",
    "max-width": "none", "max-height": "none", margin: "0", padding: "0",
    border: "0", background: "transparent", overflow: "hidden", color: "inherit",
  };
  for (const [property, value] of Object.entries(reset)) {
    host.style.setProperty(property, value, "important");
  }
  const mount = el("div");
  mount.style.setProperty("width", "100%", "important");
  mount.style.setProperty("height", "100%", "important");
  host.appendChild(mount);
  const shadow = mount.attachShadow({ mode: "open" });

  // adoptedStyleSheets rather than a <style> tag: a page with a strict
  // style-src CSP can block inline styles even inside a shadow root.
  try {
    const css = await fetch(chrome.runtime.getURL("src/reader/reader.css")).then((r) => r.text());
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(css);
    shadow.adoptedStyleSheets = [sheet];
  } catch (error) {
    console.warn("Engrossed: could not load styles", error);
  }

  // documentElement, not body: a framework re-rendering its root can wipe a
  // child of body, but nothing touches a sibling of body.
  document.documentElement.appendChild(host);
  try { host.showModal(); } catch { /* already open, or not supported */ }

  // Stop the page scrolling behind us, and put it back exactly as it was.
  // Sites differ in which element actually scrolls, so lock both.
  const scrollY = window.scrollY;
  const previous = {
    htmlOverflow: document.documentElement.style.overflow,
    bodyOverflow: document.body?.style.overflow ?? "",
  };
  document.documentElement.style.overflow = "hidden";
  if (document.body) document.body.style.overflow = "hidden";

  state = {
    host, shadow, settings, article,
    chunks: [], sections: [], index: 0,
    // The real saved index while we are showing the card before it.
    resumeIndex: null,
    overlay: null,          // null | settings | contents | checkpoint | break
    previous, scrollY,
    saveTimer: null,
    observer: null,
    flow: null,
    footerEl: null,
    pillEl: null,
    narrator: new Narrator(),
    elevenNarrator: new ElevenNarrator(),
    eleven,                 // { configured, voices }: never the key
    // After any ElevenLabs failure the rest of this session uses the built-in
    // voice, so a broken key costs one request rather than one per card.
    elevenFailed: false,
    elevenNotice: "",
    voicePickedAt: 0,
    listening: false,
    speechTimer: null,
    sprint: null,
    sprintUserPaused: false,
    sprintSaveCount: 0,
  };

  // If the page tears its own DOM down, put ourselves back rather than
  // vanishing mid-sentence.
  state.observer = new MutationObserver(() => {
    if (!document.documentElement.contains(host)) {
      document.documentElement.appendChild(host);
      try { host.showModal(); } catch { /* ignore */ }
    }
  });
  state.observer.observe(document.documentElement, { childList: true });

  // Esc is delivered as `cancel` once the dialog is modal.
  host.addEventListener("cancel", (event) => {
    event.preventDefault();
    if (!state) return;
    if (state.overlay) { state.overlay = null; render(); return; }
    persist();
    close();
  });

  if (article) {
    rechunk();
    const saved = await position.load();
    const resolved = position.resolve(saved, state.chunks);
    state.index = resolved;
    // Back up one card so you land in context rather than mid-thought. The
    // real place is kept separately and that is what gets saved, or every
    // visit would quietly cost you a card.
    if (saved && resolved > 0 && settings.rewindOnResume) {
      state.resumeIndex = resolved;
      state.index = resolved - 1;
    }
    if (settings.sprintEnabled) await startSprint();
  }

  window.__engrossedClose = close;
  // Capture phase on window, so keys are taken before the page's own handlers
  // see them. Sites that register a capture listener earlier than us still win,
  // which is why clicking the card is the primary way to advance and the
  // keyboard is the convenience.
  window.addEventListener("keydown", onKey, true);
  document.addEventListener("visibilitychange", onVisibility);
  if (speechAvailable()) speechSynthesis.addEventListener("voiceschanged", onVoices);
  // sync only, never chrome.storage.onChanged: that one also carries changes
  // to storage.local, which is where the ElevenLabs key is kept.
  chrome.storage?.sync?.onChanged?.addListener(onSyncChanged);
  render();
}

function close() {
  if (!state) return;
  stopSpeech();
  state.elevenNarrator.close();
  if (state.sprint) { state.sprint.pause(); saveSprint(state.sprint); }
  flushSettings(state.settings);
  window.removeEventListener("keydown", onKey, true);
  document.removeEventListener("visibilitychange", onVisibility);
  if (speechAvailable()) speechSynthesis.removeEventListener("voiceschanged", onVoices);
  chrome.storage?.sync?.onChanged?.removeListener(onSyncChanged);
  state.observer?.disconnect();
  document.documentElement.style.overflow = state.previous.htmlOverflow;
  if (document.body) document.body.style.overflow = state.previous.bodyOverflow;
  try { state.host.close(); } catch { /* ignore */ }
  state.host.remove();
  window.scrollTo(0, state.scrollY);
  delete window.__engrossedClose;
  state = null;
}

function rechunk() {
  const options = OPTIONS[state.settings.chunkSize] || OPTIONS.standard;
  const result = chunk(state.article.blocks, options, docLang());
  state.chunks = result.chunks;
  state.sections = result.sections;
}

// ---------- movement ----------

const sectionOf = (index) =>
  state.sections.find((s) => index >= s.firstChunk && index <= s.lastChunk);

const checkpointsOn = () =>
  state.settings.checkpoints && state.sections.length >= MIN_SECTIONS_FOR_CHECKPOINTS;

function step(next, { credit = true, rerender = false } = {}) {
  if (!state.chunks.length) return;
  const clamped = Math.min(Math.max(0, next), state.chunks.length - 1);
  const moved = clamped !== state.index || state.resumeIndex !== null;
  if (!moved && !rerender) return;

  if (credit && clamped > state.index) state.sprint?.record(state.chunks[state.index].wordCount);
  state.index = clamped;
  state.resumeIndex = null;

  if (!rerender && state.settings.mode === "flow" && state.flow?.scroller.isConnected && !state.overlay) {
    updateFlow({ scroll: true });
  } else {
    render();
  }
  schedulePersist();
  if (state.listening) speakCurrent();
}

// Next, except at the end of a stretch, where it asks for a one-line recap.
function advance() {
  const { index, chunks } = state;
  if (index >= chunks.length - 1) return false;
  const section = sectionOf(index);
  if (checkpointsOn() && section && index === section.lastChunk) {
    stopSpeech({ keepListening: true });
    state.overlay = "checkpoint";
    render();
    return true;
  }
  step(index + 1);
  return true;
}

// The reader scrolled. Saves the place; deliberately not a step.
function drift(id) {
  if (id === state.index) return;
  state.index = id;
  state.resumeIndex = null;
  // Scrolling takes over from listening: carrying on reading aloud from a
  // place the reader has scrolled away from would be worse than stopping.
  if (state.listening) { state.listening = false; stopSpeech(); }
  updateFlow({ scroll: false });
  schedulePersist();
}

// Saving on every card would write to storage dozens of times a minute for no
// benefit, so it is debounced. The one that matters is the write on the way
// out, which is not debounced at all.
function schedulePersist() {
  clearTimeout(state.saveTimer);
  state.saveTimer = setTimeout(persist, 400);
}

function persist() {
  if (!state?.chunks.length) return;
  const index = state.resumeIndex ?? state.index;
  const current = state.chunks[index];
  position.save({
    chunkIndex: index,
    blockIndex: current.blockIndex,
    blockHash: current.blockHash,
    snippet: position.snippetOf(current.text),
    total: state.chunks.length,
    title: state.article?.title || document.title,
  });
}

function onKey(event) {
  if (!state) return;
  const key = event.key;
  // stopImmediatePropagation, not just stopPropagation: a page listening on the
  // same target must not also see the key.
  const handled = () => {
    event.preventDefault();
    event.stopImmediatePropagation();
  };

  // Esc arrives as the dialog's `cancel` event; let that handle it.
  if (key === "Escape") return;
  // Never swallow keys while the reader is typing or choosing in a control.
  if (event.target instanceof HTMLInputElement || event.target instanceof HTMLSelectElement) return;

  if (state.overlay === "checkpoint" && (key === " " || key === "Enter")) {
    handled(); keepGoing(); return;
  }
  if (state.overlay) return;

  if (key === " " || key === "ArrowRight" || key === "ArrowDown" || key === "j") {
    handled(); advance();
  } else if (key === "ArrowLeft" || key === "ArrowUp" || key === "k") {
    handled(); step(state.index - 1, { credit: false });
  } else if (key === "Home") {
    handled(); step(0, { credit: false });
  } else if (key === "End") {
    handled(); step(state.chunks.length - 1, { credit: false });
  }
}

// ---------- read aloud ----------

function toggleListening() {
  if (state.listening) {
    state.listening = false;
    stopSpeech();
  } else {
    state.listening = true;
    // This click is the user gesture Chrome needs before Web Audio may play.
    if (elevenVoice()) state.elevenNarrator.unlock();
    speakCurrent();
  }
  refreshFooter();
}

// The ElevenLabs voice to read with, or null for the built-in voices: no key on
// this computer, a built-in voice chosen, or ElevenLabs already failed once.
function elevenVoice() {
  if (!state.eleven.configured || state.elevenFailed) return null;
  const uri = state.settings.voiceURI;
  return state.eleven.voices.some((v) => v.uri === uri) ? uri : null;
}

function speakCurrent() {
  const current = state.chunks[state.index];
  if (!current) return;
  stopSpeech({ keepListening: true });

  // Asides and figures are not read out — "reading a table of numbers aloud
  // helps nobody", as the app puts it. Pause for a beat and move past them.
  if (!isSpoken(current)) {
    state.speechTimer = setTimeout(continueListening, 400);
    return;
  }

  const voice = elevenVoice();
  if (!voice) { speakBuiltIn(current.text); return; }

  const after = nextSpokenIndex(state.chunks, state.index, (i) => {
    const section = sectionOf(i);
    return checkpointsOn() && Boolean(section) && i === section.lastChunk;
  });
  state.elevenNarrator.speak(
    current.text,
    { voice, rate: state.settings.speechRate, next: after >= 0 ? state.chunks[after].text : null },
    continueListening,
    (message) => {
      // Never stuck, never silent: this card goes to the built-in voice, and so
      // does the rest of the session. The message is shown once. A move or a
      // stop has already dropped this callback (the narrator's token), so the
      // only check needed is that the reader is still open and listening.
      if (!state?.listening) return;
      state.elevenFailed = true;
      state.elevenNotice = message || "";
      refreshFooter();
      speakBuiltIn(current.text);
    },
  );
}

function speakBuiltIn(text) {
  state.narrator.speak(
    text,
    { rate: state.settings.speechRate, voiceURI: state.settings.voiceURI, lang: docLang() },
    continueListening,
    () => { if (state) { state.listening = false; refreshFooter(); } },
  );
}

function continueListening() {
  if (!state?.listening) return;
  if (state.index >= state.chunks.length - 1) {
    state.listening = false;
    refreshFooter();
    return;
  }
  // advance() may stop for a checkpoint. Listening stays on, so "keep going"
  // carries on reading from the next card.
  advance();
}

function stopSpeech({ keepListening = false } = {}) {
  if (!state) return;
  clearTimeout(state.speechTimer);
  state.speechTimer = null;
  state.narrator.stop();
  state.elevenNarrator.stop();
  if (!keepListening) {
    state.listening = false;
    state.elevenNotice = "";
  }
}

function onVoices() {
  if (state?.overlay === "settings") render();
}

// Asked again whenever the reader might have just been to the options page.
async function refreshEleven() {
  const status = await elevenStatus();
  if (!state) return;
  const before = JSON.stringify(state.eleven);
  state.eleven = status;
  if (JSON.stringify(status) !== before && state.overlay === "settings") render();
}

// The options page picks an ElevenLabs voice when a key is saved, and puts the
// automatic one back when the key is removed. Taking that change here stops
// this reader's next save from writing the old choice back over it.
function onSyncChanged(changes) {
  const voiceURI = changes?.settings?.newValue?.voiceURI;
  if (!state || typeof voiceURI !== "string" || voiceURI === state.settings.voiceURI) return;
  // Just picked in this reader: what arrives now is the echo of an older save.
  if (Date.now() - state.voicePickedAt < 2000) return;
  state.settings.voiceURI = voiceURI;
  // A voice chosen on purpose, often with a new key: ElevenLabs gets another
  // go, as it does when the voice is chosen again in this reader.
  state.elevenFailed = false;
  state.elevenNotice = "";
  state.elevenNarrator.forgetFailures();
  refreshEleven();
  if (state.overlay === "settings") render();
  else refreshFooter();
}

// ---------- sprints ----------

async function startSprint() {
  state.sprint = await loadSprint(state.settings.sprintMinutes);
  state.sprint.onTick = () => {
    updatePill();
    // Save now and then so a sprint survives hopping to the next article.
    if (++state.sprintSaveCount % 10 === 0) saveSprint(state.sprint);
  };
  state.sprint.onFinish = onSprintFinished;
  if (!document.hidden) state.sprint.start();
}

function stopSprint() {
  if (!state.sprint) return;
  state.sprint.pause();
  saveSprint(state.sprint);
  state.sprint = null;
}

function onSprintFinished() {
  if (!state) return;
  stopSpeech();
  saveSprint(state.sprint);
  state.overlay = "break";
  render();
}

function onVisibility() {
  if (!state) return;
  if (!document.hidden) refreshEleven();
  if (!state.sprint) return;
  // A sprint measures time spent reading, not time the tab was open. Listening
  // in the background still counts as reading.
  if (document.hidden && !state.listening) state.sprint.pause();
  else if (!document.hidden && !state.sprintUserPaused) state.sprint.start();
}

function toggleSprintPause() {
  if (!state.sprint || state.sprint.finished) return;
  if (state.sprint.running) { state.sprint.pause(); state.sprintUserPaused = true; }
  else { state.sprint.start(); state.sprintUserPaused = false; }
  updatePill();
}

function updatePill() {
  if (!state?.pillEl || !state.sprint) return;
  state.pillEl.textContent = state.sprint.remainingText;
  state.pillEl.dataset.paused = String(!state.sprint.running);
  state.pillEl.title = state.sprint.running ? "Sprint time left. Click to pause." : "Sprint paused. Click to carry on.";
}

// ---------- checkpoint actions ----------

function keepGoing() {
  state.overlay = null;
  step(state.index + 1, { rerender: true });
}

function readAgain() {
  const section = sectionOf(state.index);
  state.overlay = null;
  step(section ? section.firstChunk : state.index, { credit: false, rerender: true });
}

// ---------- rendering ----------

function render() {
  const { shadow, settings } = state;
  // A re-render must not throw the reader back to the top of a long sheet
  // every time they flip a toggle.
  const sheetScroll = shadow.querySelector(".sheet")?.scrollTop || 0;
  shadow.querySelector(".root")?.remove();
  state.flow = null;
  state.footerEl = null;
  state.pillEl = null;

  const root = el("div", {
    class: "root",
    "data-theme": settings.theme,
    "data-font": settings.font,
  });
  applyVars(root);

  root.appendChild(topBar());

  if (!state.article) {
    root.appendChild(emptyState());
  } else {
    root.appendChild(settings.mode === "flow" ? flowView() : cardsView());
    state.footerEl = footer();
    root.appendChild(state.footerEl);
  }

  if (state.overlay === "settings") root.appendChild(settingsSheet());
  if (state.overlay === "contents") root.appendChild(contentsSheet());
  if (state.overlay === "checkpoint") root.appendChild(checkpointPanel());
  if (state.overlay === "break") root.appendChild(breakPanel());
  shadow.appendChild(root);

  const sheet = shadow.querySelector(".sheet");
  if (sheet && sheetScroll) sheet.scrollTop = sheetScroll;
  updatePill();
}

function applyVars(root = state.shadow.querySelector(".root")) {
  if (!root) return;
  const s = state.settings;
  root.style.setProperty("--size", s.fontSize);
  root.style.setProperty("--leading", s.lineSpacing);
  root.style.setProperty("--measure", `${Math.round(s.lineWidth * s.fontSize * 0.5)}px`);
}

function topBar() {
  const { settings, article } = state;
  const modes = el("div", { class: "seg" }, ["cards", "flow"].map((mode) =>
    el("button", {
      text: mode === "cards" ? "Cards" : "Flow",
      "aria-pressed": String(settings.mode === mode),
      onclick: () => {
        if (settings.mode === mode) return;
        settings.mode = mode;
        saveSettings(settings);
        if (state.listening) { state.listening = false; stopSpeech(); }
        render();
      },
    })));

  const headingCount = state.chunks.filter((c) => c.kind === "heading").length;

  if (state.sprint) {
    state.pillEl = el("button", { class: "pill", onclick: toggleSprintPause });
  }

  return el("div", { class: "bar" }, [
    el("button", { class: "quiet", text: "Close", title: "Close (Esc)", onclick: () => { persist(); close(); } }),
    el("div", { class: "title", text: article?.title || "" }),
    el("div", { class: "spacer" }),
    state.pillEl,
    article ? modes : null,
    article && headingCount >= 2 ? el("button", {
      class: "quiet", text: "Contents", title: "Jump to a section",
      onclick: () => { state.overlay = "contents"; render(); },
    }) : null,
    el("button", {
      class: "quiet", text: "Aa", title: "Reading preferences",
      onclick: () => { state.overlay = "settings"; render(); refreshEleven(); },
    }),
  ]);
}

function emptyState() {
  return el("div", { class: "empty" }, [
    el("p", { text: "This page does not look like an article, so there is nothing to lay out as cards." }),
    el("p", { text: "Try it on a blog post, a news story or a documentation page." }),
    el("button", { class: "prominent", text: "Close", onclick: close }),
  ]);
}

function cardBody(chunk) {
  const { settings } = state;
  if (chunk.kind === "heading") {
    return el("div", { class: "card heading" }, [
      el("div", { class: "label", text: "NEW SECTION" }),
      el("div", { class: "text", text: chunk.text }),
    ]);
  }
  if (chunk.kind === "aside") {
    return el("div", { class: "card aside" }, [
      el("div", { class: "box" }, [
        el("div", { class: "label", text: "NOT PROSE · SKIM OR SKIP" }),
        el("div", { class: "text", text: chunk.text }),
      ]),
    ]);
  }
  if (chunk.kind === "figure") {
    const figure = el("figure", { class: "card figure" }, [
      el("img", { src: chunk.figure.src, alt: chunk.figure.alt, loading: "lazy" }),
    ]);
    const caption = chunk.figure.caption || chunk.figure.alt;
    if (caption) figure.appendChild(el("figcaption", { text: caption }));
    return figure;
  }

  const card = el("div", { class: "card prose" });
  if (settings.fixationBolding) card.appendChild(fixationBolded(chunk.text));
  else card.textContent = chunk.text;
  return card;
}

// The faded last words of the previous card. Just enough thread to pick the
// sentence back up without the whole paragraph competing for attention.
function tailOf(text) {
  const words = text.split(/\s+/).filter(Boolean);
  if (words.length <= 14) return text;
  return "… " + words.slice(-14).join(" ");
}

function cardsView() {
  const current = state.chunks[state.index];
  const previous = state.index > 0 ? state.chunks[state.index - 1] : null;
  const column = el("div", { class: "column" });

  if (state.resumeIndex !== null) {
    column.appendChild(el("div", { class: "resumed", text: "Backed up one card so you land in context" }));
  } else if (previous && previous.kind === "prose" && current?.kind === "prose") {
    column.appendChild(el("div", { class: "tail", text: tailOf(previous.text) }));
  }
  if (current) column.appendChild(cardBody(current));

  return el("div", {
    class: "stage",
    onclick: () => {
      // A click on the card itself should still select text, so only advance
      // when nothing is selected.
      if (!String(window.getSelection() || "")) advance();
    },
  }, [column]);
}

// ---------- flow ----------

function flowView() {
  const total = state.chunks.length;
  const windowed = total > FLOW_FULL_RENDER_LIMIT;
  const low = windowed ? Math.max(0, state.index - 200) : 0;
  const high = windowed ? Math.min(total, state.index + 200) : total;

  const column = el("div", { class: "column" });
  const paras = new Map();
  for (let i = low; i < high; i += 1) {
    const para = el("div", { class: "para", onclick: () => step(i) }, [cardBody(state.chunks[i])]);
    paras.set(i, para);
    column.appendChild(para);
  }

  const scroller = el("div", { class: "flow" }, [column]);
  state.flow = { scroller, paras, low, high, windowed, suppressUntil: Infinity, raf: 0 };
  applyFlowStyles();

  scroller.addEventListener("scroll", onFlowScroll, { passive: true });
  // A programmatic scroll fires the same events as the reader's own, and
  // treating those as drift would move the index that triggered the scroll.
  scroller.addEventListener("scrollend", () => {
    if (state?.flow) state.flow.suppressUntil = 0;
  });

  requestAnimationFrame(() => {
    if (!state?.flow) return;
    state.flow.suppressUntil = performance.now() + 400;
    paras.get(state.index)?.scrollIntoView({ block: "center", behavior: "auto" });
  });
  return scroller;
}

function applyFlowStyles() {
  for (const [id, para] of state.flow.paras) {
    const distance = Math.abs(id - state.index);
    para.style.opacity = distance === 0 ? 1 : distance === 1 ? 0.42 : distance === 2 ? 0.26 : 0.16;
    para.dataset.current = String(id === state.index);
  }
}

function updateFlow({ scroll }) {
  const flow = state.flow;
  if (flow.windowed && (state.index < flow.low + 20 || state.index > flow.high - 20)) {
    render();
    return;
  }
  applyFlowStyles();
  refreshFooter();
  if (scroll) {
    flow.suppressUntil = performance.now() + 1500;
    flow.paras.get(state.index)?.scrollIntoView({
      block: "center", behavior: reducedMotion() ? "auto" : "smooth",
    });
  }
}

function onFlowScroll() {
  const flow = state?.flow;
  if (!flow || flow.raf) return;
  flow.raf = requestAnimationFrame(() => {
    flow.raf = 0;
    if (!state?.flow || performance.now() < flow.suppressUntil) return;
    drift(chunkAtCentre());
  });
}

// The paragraph crossing the middle of the view. Paragraphs are laid out in
// order, so a binary search over their offsets finds it without measuring
// every one on every frame.
function chunkAtCentre() {
  const { scroller, paras, low, high } = state.flow;
  const target = scroller.scrollTop + scroller.clientHeight / 2;
  let lo = low;
  let hi = high - 1;
  let best = low;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (paras.get(mid).offsetTop <= target) { best = mid; lo = mid + 1; } else { hi = mid - 1; }
  }
  return best;
}

// ---------- footer ----------

function refreshFooter() {
  if (!state?.footerEl) return;
  const next = footer();
  state.footerEl.replaceWith(next);
  state.footerEl = next;
}

function footer() {
  const section = sectionOf(state.index);
  const within = section ? state.index - section.firstChunk + 1 : state.index + 1;
  const total = section ? section.lastChunk - section.firstChunk + 1 : state.chunks.length;

  const dots = el("div", { class: "dots" });
  const shown = Math.min(total, 16);
  for (let i = 0; i < shown; i += 1) {
    const on = Math.round((within - 1) / Math.max(total - 1, 1) * (shown - 1)) === i;
    dots.appendChild(el("div", { class: "dot", "data-on": String(on) }));
  }

  const fraction = state.chunks.length > 1 ? state.index / (state.chunks.length - 1) : 0;
  const atEnd = state.index >= state.chunks.length - 1;

  return el("div", { class: "foot" }, [
    el("div", { class: "controls" }, [
      el("button", {
        class: "quiet", text: "← Back", disabled: state.index === 0,
        onclick: () => step(state.index - 1, { credit: false }),
      }),
      speechAvailable() || elevenVoice() ? el("button", {
        class: state.listening ? "quiet listening" : "quiet",
        text: state.listening ? "■ Stop" : "▶ Listen",
        title: state.listening ? "Stop reading aloud" : "Read aloud from here",
        onclick: toggleListening,
      }) : null,
      // Why the voice changed, if ElevenLabs could not read a card.
      state.listening && state.elevenNotice
        ? el("div", { class: "voice-note", role: "status", text: state.elevenNotice })
        : null,
      el("div", { class: "spacer" }),
      el("button", {
        class: "prominent",
        text: state.chunks[state.index]?.kind === "aside" ? "Skip this →" : "Next →",
        disabled: atEnd,
        onclick: advance,
      }),
    ]),
    el("div", { class: "progress" }, [
      el("div", { class: "counter", text: `${within} of ${total} in this stretch` }),
      dots,
    ]),
    el("div", { class: "bar-track" }, [
      el("div", { class: "bar-fill", style: `width:${(fraction * 100).toFixed(1)}%` }),
    ]),
  ]);
}

// ---------- panels ----------

function checkpointPanel() {
  return el("div", { class: "panel" }, [
    el("div", { class: "inner" }, [
      el("div", { class: "label", text: "END OF A STRETCH" }),
      el("div", { class: "question", text: "In one line, what was that about?" }),
      el("div", {
        class: "body",
        text: "Don’t write it down. Just say it to yourself. If nothing comes, that’s the useful part. " +
              "It means the last few minutes didn’t land, and it’s cheaper to re-read now than to find out in twenty pages.",
      }),
      el("div", { class: "actions" }, [
        el("button", { class: "prominent", text: "Got it, keep going", onclick: keepGoing }),
        el("button", { text: "Read it again", onclick: readAgain }),
      ]),
    ]),
  ]);
}

function breakPanel() {
  const sprint = state.sprint;
  return el("div", { class: "panel" }, [
    el("div", { class: "inner" }, [
      el("div", { class: "label", text: "SPRINT DONE" }),
      el("div", {
        class: "question",
        text: `${state.settings.sprintMinutes} minutes. ${(sprint?.chunks ?? 0).toLocaleString()} cards, ` +
              `${(sprint?.words ?? 0).toLocaleString()} words.`,
      }),
      el("div", {
        class: "body",
        text: "Stand up, look at something far away, get water. Five minutes. " +
              "The next sprint goes better if this one actually ends.",
      }),
      el("div", { class: "actions" }, [
        el("button", {
          class: "prominent", text: "Another sprint",
          onclick: () => {
            state.sprint?.restart();
            state.sprintUserPaused = false;
            state.overlay = null;
            render();
          },
        }),
        el("button", { text: "Done for now", onclick: () => { persist(); close(); } }),
      ]),
    ]),
  ]);
}

function contentsSheet() {
  const headings = state.chunks.filter((c) => c.kind === "heading");
  const here = [...headings].reverse().find((h) => h.id <= state.index);
  const minLevel = Math.min(...headings.map((h) => h.level || 2));

  return el("div", { class: "sheet" }, [
    el("div", { class: "row" }, [
      el("h2", { text: "Contents" }),
      el("div", { style: "flex:1" }),
      el("button", { text: "Done", onclick: () => { state.overlay = null; render(); } }),
    ]),
    el("div", { class: "contents" }, headings.map((h) => el("button", {
      class: h === here ? "entry here" : "entry",
      style: `padding-left:${12 + ((h.level || 2) - minLevel) * 18}px`,
      onclick: () => {
        state.overlay = null;
        step(h.id, { credit: false, rerender: true });
      },
    }, [
      el("span", { text: h.text }),
      h === here ? el("span", { class: "marker", text: "you are here" }) : null,
    ]))),
  ]);
}

// ---------- settings ----------

function settingsSheet() {
  const { settings } = state;

  const change = (patch, needsRechunk = false) => {
    Object.assign(settings, patch);
    saveSettings(settings);
    if (needsRechunk) {
      // Anchor on the paragraph, not the card index: changing card size
      // renumbers every card, so the index is the one thing that cannot be
      // trusted across this change.
      const current = state.chunks[state.resumeIndex ?? state.index];
      const anchor = {
        chunkIndex: state.index,
        blockIndex: current?.blockIndex,
        blockHash: current?.blockHash,
        snippet: position.snippetOf(current?.text || ""),
        total: state.chunks.length,
      };
      rechunk();
      state.index = position.resolve(anchor, state.chunks);
      state.resumeIndex = null;
    }
    if ("sprintEnabled" in patch) {
      if (patch.sprintEnabled && !state.sprint) startSprint().then(() => state && render());
      if (!patch.sprintEnabled) stopSprint();
    }
    render();
  };

  const segmented = (values, labels, current, onPick) =>
    el("div", { class: "seg" }, values.map((value) =>
      el("button", {
        text: labels[value], "aria-pressed": String(current === value),
        onclick: () => onPick(value),
      })));

  // Sliders update in place. Re-rendering on each input event rebuilt the
  // sheet and destroyed the slider under the reader's finger, so a drag
  // stopped after a single step.
  const slider = (label, key, display, onLive) => {
    const [min, max, step] = LIMITS[key];
    const readout = el("div", { class: "readout", text: display(settings[key]) });
    return el("div", { class: "row" }, [
      el("label", { text: label }),
      el("input", {
        type: "range", min, max, step, value: settings[key],
        oninput: (e) => {
          settings[key] = Number(e.target.value);
          readout.textContent = display(settings[key]);
          saveSettings(settings);
          applyVars();
          onLive?.();
        },
      }),
      readout,
    ]);
  };

  const toggle = (label, key, note) => el("div", { class: "group-item" }, [
    el("label", { class: "switch" }, [
      el("input", {
        type: "checkbox", checked: settings[key] ? "" : null,
        onchange: (e) => change({ [key]: e.target.checked }),
      }),
      label,
    ]),
    note ? el("div", { class: "caption", text: note }) : null,
  ]);

  // The key is never typed here. This sheet lives inside someone else's page,
  // whose scripts can watch keystrokes and read an open shadow root, so the
  // key is entered on the extension's own options page instead.
  const elevenButton = () => el("button", {
    class: "quiet", text: "ElevenLabs voices (optional)",
    onclick: () => openElevenOptions(),
  });

  const voiceGroup = () => {
    // Only listed when this computer has a key. Settings sync, so the choice
    // can arrive on a machine without one; it then reads with the built-in voice.
    const elevenChoices = state.eleven.configured ? state.eleven.voices : [];
    if (!speechAvailable() && !elevenChoices.length) {
      return el("div", { class: "group-item" }, [
        el("div", { class: "caption", text: "This browser has no built-in voices." }),
        elevenButton(),
      ]);
    }
    const option = (value, text) => el("option", {
      value, text, selected: value === settings.voiceURI ? "" : null,
    });
    const builtIn = (speechAvailable() ? voicesFor(speechSynthesis.getVoices(), docLang()) : [])
      .map((v) => option(v.voiceURI, `${v.name}${v.localService ? "" : " (online)"}`));
    const select = el("select", {
      onchange: (e) => {
        const value = e.target.value;
        state.voicePickedAt = Date.now();
        if (elevenChoices.some((v) => v.uri === value)) {
          // Choosing it again is a deliberate retry after a failure, and this
          // change is the user gesture Web Audio needs. The card that failed
          // is asked for once more, rather than failing again from the cache.
          state.elevenFailed = false;
          state.elevenNotice = "";
          state.elevenNarrator.forgetFailures();
          state.elevenNarrator.unlock();
        }
        change({ voiceURI: value });
      },
    }, [
      el("option", { value: "", text: "Automatic (on this computer)" }),
      ...(elevenChoices.length
        ? [
            el("optgroup", { label: "ElevenLabs" }, elevenChoices.map((v) => option(v.uri, v.label))),
            builtIn.length ? el("optgroup", { label: "Built in" }, builtIn) : null,
          ]
        : builtIn),
    ]);
    return el("div", { class: "group-item" }, [
      el("div", { class: "row" }, [el("label", { text: "Voice" }), select]),
      slider("Speed", "speechRate", (v) => `${v.toFixed(2)}×`),
      el("div", {
        class: "caption",
        text: "Uses the voices built into Chrome and your computer. Voices marked online send the text to Google to be spoken; the others never leave this computer.",
      }),
      elevenChoices.length
        ? el("div", {
            class: "caption",
            text: "While an ElevenLabs voice is reading, the text of each card is sent to ElevenLabs with your key. Nothing else is sent.",
          })
        : null,
      elevenButton(),
    ]);
  };

  return el("div", { class: "sheet" }, [
    el("div", { class: "row" }, [
      el("h2", { text: "Reading" }),
      el("div", { style: "flex:1" }),
      el("button", { text: "Done", onclick: () => { state.overlay = null; render(); } }),
    ]),
    el("div", { class: "group" }, [
      el("div", { class: "label", text: "HOW MUCH AT A TIME" }),
      segmented(["cozy", "standard", "roomy"], SIZE_LABELS, settings.chunkSize,
                (v) => change({ chunkSize: v }, true)),
      el("div", { class: "caption", text: SIZE_DETAIL[settings.chunkSize] }),
    ]),
    el("div", { class: "group" }, [
      el("div", { class: "label", text: "LOOK" }),
      segmented(THEMES, THEME_LABELS, settings.theme, (v) => change({ theme: v })),
      segmented(FONTS, FONT_LABELS, settings.font, (v) => change({ font: v })),
      slider("Text size", "fontSize", (v) => `${Math.round(v)} pt`),
      slider("Line spacing", "lineSpacing", (v) => v.toFixed(2)),
      slider("Line width", "lineWidth", (v) => `${Math.round(v)} ch`),
      el("button", {
        class: "quiet", text: "Reset to those defaults",
        onclick: () => change(resetTypography(settings)),
      }),
    ]),
    el("div", { class: "group" }, [
      el("div", { class: "label", text: "FOCUS" }),
      toggle("Checkpoint at the end of each stretch", "checkpoints",
             "A one-line recap prompt. Only on longer articles, three stretches or more."),
      toggle("Back up one card when you come back", "rewindOnResume", null),
    ]),
    el("div", { class: "group" }, [
      el("div", { class: "label", text: "SPRINTS" }),
      toggle("Time-boxed sprints", "sprintEnabled",
             "A sprint carries on into the next article if you open it within ten minutes."),
      settings.sprintEnabled
        ? slider("Sprint length", "sprintMinutes", (v) => `${Math.round(v)} min`, () => {
            if (state.sprint) { state.sprint.targetMinutes = settings.sprintMinutes; updatePill(); }
          })
        : null,
    ]),
    el("div", { class: "group" }, [
      el("div", { class: "label", text: "READ ALOUD" }),
      voiceGroup(),
    ]),
    el("div", { class: "group" }, [
      el("div", { class: "label", text: "EXTRAS" }),
      toggle("Bold the start of each word", "fixationBolding",
             "Off by default. Some people find it steadies the eye; others find it worse."),
    ]),
    el("div", { class: "group" }, [
      el("div", { class: "label", text: "THIS ARTICLE" }),
      el("button", {
        text: "Start this article over",
        onclick: async () => {
          await position.clear();
          state.index = 0;
          state.resumeIndex = null;
          state.overlay = null;
          render();
        },
      }),
    ]),
  ]);
}
