// What the check-in says at the end of a part.
//
// The check-in works because you try to recall the part before you see any of
// it again. So it asks first, and "Remind me" only gives the skeleton: how
// each paragraph opened. Nothing here summarises, because a summary would let
// you skip the thinking. The iOS app does the same, in Core/Recap.swift.

// Scripts written without spaces between words: Thai, Lao, Myanmar, Khmer,
// kana and CJK ideographs. Hangul is left out, because Korean does put spaces
// between words.
const UNSPACED = /[\u0e00-\u0eff\u1000-\u109f\u1780-\u17ff\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/;

// Cut by what a reader sees as one character, not by code point, so an accent
// or a Thai vowel mark is never split from its letter. Swift's String does the
// same, which keeps the two apps' lines identical.
let graphemeSegmenter = null;
const graphemes = (text) => {
  graphemeSegmenter ??= new Intl.Segmenter(undefined, { granularity: "grapheme" });
  return [...graphemeSegmenter.segment(text)].map((g) => g.segment);
};

// Asked in turn when the part has no heading to ask about, picked by the part's
// number so the same part always gets the same question.
export const QUESTIONS = [
  "In one line, what was that about?",
  "What’s the main point of that part?",
  "What would you tell a friend about that bit?",
  "What stuck with you from that part?",
];

// The explanation is only worth reading once. After that it is a wall of text
// between the reader and the buttons, so later check-ins say the short version.
export const FIRST_BODY =
  "Don’t write it down. Just say it to yourself. If nothing comes, that’s the useful part. " +
  "It means the last few minutes didn’t land, and it’s cheaper to re-read now than to find out in twenty pages.";
export const SHORT_BODY = "Just say it to yourself. If nothing comes, read it again.";
export const AGAIN_BODY = "Second time through. Is it clearer now?";

// The heading the part sits under: the one whose section makes up most of it.
// A part often starts at the end of one section and runs into the next, and
// the question should be about the one you spent most of the part in. When no
// heading covers most of it, there is nothing honest to name.
//
// Only headings the page marked up as headings count. The chunker also shows
// a lone short line ("* * *", "II", "Advertisement") as a heading card, and
// quoting one of those as the topic would be nonsense.
const isTitle = (c) => c.kind === "heading" && Boolean(c.level);

export function headingFor(chunks, section) {
  let current = null;
  for (let i = section.firstChunk - 1; i >= 0; i -= 1) {
    if (isTitle(chunks[i])) { current = chunks[i]; break; }
  }
  const words = new Map();
  let total = 0;
  for (let i = section.firstChunk; i <= section.lastChunk; i += 1) {
    const c = chunks[i];
    if (isTitle(c)) { current = c; continue; }
    if (c.kind !== "prose") continue;
    total += c.wordCount;
    if (current) words.set(current, (words.get(current) || 0) + c.wordCount);
  }
  let best = null;
  let most = 0;
  for (const [heading, count] of words) {
    if (count > most) { best = heading; most = count; }
  }
  if (!best || most < total * 0.6) return null;
  const text = best.text.trim().replace(/[.:;,]+$/, "");
  // A long heading is a sentence in disguise, and reads badly inside quotes.
  if (!text || tooLong(text)) return null;
  return text;
}

function tooLong(heading) {
  return UNSPACED.test(heading) ? graphemes(heading).length > 24 : heading.split(/\s+/).length > 10;
}

export function questionFor(section, heading) {
  if (heading) {
    // A heading that is already a question is the best question there is.
    if (/[?？]$/.test(heading)) return heading;
    return `What was “${heading}” about?`;
  }
  return QUESTIONS[section.id % QUESTIONS.length];
}

// The opening words of each paragraph in the part.
export function openingLines(chunks, section, { limit = 6, words = 9 } = {}) {
  const lines = [];
  for (let i = section.firstChunk; i <= section.lastChunk && lines.length < limit; i += 1) {
    const c = chunks[i];
    if (c.kind === "prose" && c.startsParagraph) lines.push(opening(c.text, words));
  }
  return lines;
}

function opening(text, count) {
  const trimmed = text.trim();
  let out;
  let cut;
  if (UNSPACED.test(trimmed)) {
    // Chinese and Japanese have no spaces, so nine "words" can be the whole
    // paragraph. Cut those by characters instead.
    const chars = graphemes(trimmed);
    out = chars.slice(0, 30).join("");
    cut = chars.length > 30;
  } else {
    const parts = trimmed.split(/\s+/);
    out = parts.slice(0, count).join(" ");
    cut = parts.length > count;
  }
  // Nine words that happen to end a sentence are a whole thought already.
  if (!cut || /[.!?。！？]["”’)]?$/.test(out)) return out;
  return `${out.replace(/[,;:]+$/, "")}…`;
}

export function tallyFor(section) {
  const words = section.wordCount;
  const about = words >= 100 ? Math.round(words / 10) * 10 : words;
  const minutes = Math.max(1, Math.round(words / 220));
  return `That part was about ${about.toLocaleString("en")} words, roughly ${minutes} ` +
         `minute${minutes === 1 ? "" : "s"} of reading.`;
}

// What a key does while the check-in is up. Space is how people move through
// the cards, so at the end of a part the very next press used to close the
// check-in before anyone had read it. Now the keys that move you on only show
// a hint, and Enter only works once the check-in has been up for a second and
// the key is not being held down. Clicking is never delayed: a click is
// deliberate.
//   "continue"  carry on to the next part
//   "native"    a check-in button has focus: let the key press it
//   "hint"      say how to carry on
//   "ignore"    swallow the key
//   "pass"      not ours
export const CHECK_IN_ARM_MS = 1000;
const NEXT_KEYS = new Set([" ", "ArrowRight", "ArrowDown", "j", "PageDown"]);

export function checkInKey(key, { repeat = false, shownFor = Infinity, onButton = false } = {}) {
  const ready = !repeat && shownFor >= CHECK_IN_ARM_MS;
  if (key === "Enter") {
    if (!ready) return "ignore";
    return onButton ? "native" : "continue";
  }
  // Space presses a focused button when it is let go, so a held Space is
  // still one press. Only the first second is guarded.
  if (key === " " && onButton) return shownFor >= CHECK_IN_ARM_MS ? "native" : "hint";
  if (NEXT_KEYS.has(key)) return "hint";
  return "pass";
}
