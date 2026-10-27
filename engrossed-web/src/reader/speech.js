// Reading a card aloud, with the voices built into Chrome and the computer.
//
// The web version of Narrator.swift. Two things are different, and both are
// about Chrome rather than about reading:
//
// Chrome's speech engine is known to cut an utterance off after about fifteen
// seconds with some voices, which a long card can exceed. So a card is spoken
// one sentence at a time, using the same segmenter the chunker uses, which
// also means "Dr." is never read as the end of a sentence.
//
// Some of Chrome's voices are online voices: the text is sent to Google to be
// spoken. The extension otherwise sends nothing anywhere, so the automatic
// choice is always an on-device voice, and online ones are labelled.

import { splitSentences, OPTIONS } from "./chunker.js";

export function speechAvailable() {
  return typeof speechSynthesis !== "undefined" && typeof SpeechSynthesisUtterance !== "undefined";
}

/**
 * The voice to use: the one chosen, if it still exists; otherwise the first
 * on-device voice in the article's language; otherwise none, which lets Chrome
 * pick its default for that language.
 */
export function pickVoice(voices, voiceURI, lang) {
  if (voiceURI) {
    const chosen = voices.find((v) => v.voiceURI === voiceURI);
    if (chosen) return chosen;
  }
  const prefix = (lang || "en").slice(0, 2).toLowerCase();
  const inLanguage = voices.filter((v) => (v.lang || "").toLowerCase().startsWith(prefix));
  return inLanguage.find((v) => v.localService && v.default)
      || inLanguage.find((v) => v.localService)
      || null;
}

/** Voices for the settings list: the article's language first, on-device first. */
export function voicesFor(voices, lang) {
  const prefix = (lang || "en").slice(0, 2).toLowerCase();
  const inLanguage = voices.filter((v) => (v.lang || "").toLowerCase().startsWith(prefix));
  return (inLanguage.length ? inLanguage : voices).slice().sort((a, b) =>
    (Number(b.localService) - Number(a.localService)) || a.name.localeCompare(b.name));
}

export class Narrator {
  constructor() {
    // Each speak() takes a fresh token. cancel() fires onend and onerror on
    // whatever was queued, and without a token those stale callbacks would
    // advance the reader a card it never asked for.
    this.token = 0;
    this.speaking = false;
  }

  speak(text, { rate = 1, voiceURI = "", lang = "en" } = {}, onDone, onError) {
    this.stop();
    if (!speechAvailable()) { onError?.(); return; }
    const token = ++this.token;
    const sentences = splitSentences(text, OPTIONS.standard, lang).filter((s) => s.trim());
    if (!sentences.length) { onDone?.(); return; }

    const voice = pickVoice(speechSynthesis.getVoices(), voiceURI, lang);
    this.speaking = true;
    let i = 0;

    const next = () => {
      if (token !== this.token) return;
      if (i >= sentences.length) {
        this.speaking = false;
        onDone?.();
        return;
      }
      const utterance = new SpeechSynthesisUtterance(sentences[i++]);
      utterance.rate = rate;
      if (voice) { utterance.voice = voice; utterance.lang = voice.lang; } else { utterance.lang = lang; }
      utterance.onend = next;
      utterance.onerror = (event) => {
        if (token !== this.token) return;
        if (event.error === "interrupted" || event.error === "canceled") return;
        // A real failure stops reading rather than skipping on. Skipping would
        // race through the rest of the article in a second if no voice works.
        this.speaking = false;
        onError?.(event.error);
      };
      speechSynthesis.speak(utterance);
    };

    // Chrome drops a speak() issued in the same task as a cancel().
    setTimeout(next, 60);
  }

  stop() {
    this.token += 1;
    this.speaking = false;
    if (speechAvailable()) speechSynthesis.cancel();
  }
}
