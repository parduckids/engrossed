// Turns extracted blocks into reading cards.
//
// A port of Chunker.swift from the Engrossed app. The rules are the same ones
// measured against a 23-document corpus there, and the reasoning behind each is
// kept with it, because every one of them exists to stop a card ending in the
// middle of a sentence. That is the single promise the reader makes.

export const SENTENCE_ENDERS = new Set([
  ".", "!", "?",
  "。",   // 。 ideographic full stop
  "！",   // ！ fullwidth exclamation
  "？",   // ？ fullwidth question
  "⁉",   // ⁉
  "।",   // । Devanagari danda, for Hindi and its neighbours
  "॥",   // ॥ double danda
  "։",   // ։ Armenian full stop
  "۔",   // ۔ Urdu full stop
  "؟",   // ؟ Arabic question mark
]);
// Note: 、 is deliberately absent. It is a comma, not a full stop, and treating
// it as one would end cards in the middle of a sentence in Japanese and
// Chinese. It belongs in the clause breakers used to split a run-on, and it is
// already there.

export const OPTIONS = {
  // targetWords: what we aim for per card, small enough to take in at a glance.
  // maxWords: the hard ceiling before we stop adding sentences.
  // runOnWords: a single sentence longer than this is split at clause boundaries.
  // sectionWords: roughly three minutes of reading at a calm pace.
  cozy:     { targetWords: 28, maxWords: 50,  runOnWords: 70,  sectionWords: 450 },
  standard: { targetWords: 45, maxWords: 80,  runOnWords: 90,  sectionWords: 650 },
  roomy:    { targetWords: 70, maxWords: 120, runOnWords: 130, sectionWords: 900 },
};

// A 32-bit hash of a paragraph's normalised text (FNV-1a). Used to recognise
// the same paragraph again after the article around it has been edited, which
// is what lets a saved place survive a site appending a correction.
export function hashOf(text) {
  const normalised = (text || "").toLowerCase().replace(/\s+/g, " ").trim();
  let hash = 0x811c9dc5;
  for (let i = 0; i < normalised.length; i += 1) {
    hash ^= normalised.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(36);
}

// Ranges where one character is one word: kana, CJK ideographs, hangul.
const IDEOGRAPHIC = [
  [0x3040, 0x30ff], [0x3400, 0x4dbf], [0x4e00, 0x9fff],
  [0xf900, 0xfaff], [0xac00, 0xd7af],
];

function isIdeographic(codePoint) {
  for (const [low, high] of IDEOGRAPHIC) {
    if (codePoint >= low && codePoint <= high) return true;
  }
  return false;
}

// Japanese and Chinese put no spaces between words, so splitting on whitespace
// counts a whole paragraph as one word and every card comes out enormous.
export function wordCount(text) {
  let count = 0;
  let inWord = false;
  for (const character of text) {
    const codePoint = character.codePointAt(0);
    if (isIdeographic(codePoint)) {
      count += 1;
      inWord = false;
    } else if (/\s/.test(character)) {
      inWord = false;
    } else if (!inWord) {
      inWord = true;
      count += 1;
    }
  }
  return count;
}

export function letterDensity(text) {
  let good = 0;
  let total = 0;
  for (const character of text) {
    if (/\s/.test(character)) continue;
    total += 1;
    if (/\p{L}/u.test(character) || ",.'’".includes(character)) good += 1;
  }
  return total > 0 ? good / total : 0;
}

// The run of dots in a printed contents line.
function hasDotLeader(text) {
  let run = 0;
  for (const character of text) {
    if (character === ".") {
      run += 1;
      if (run >= 4) return true;
    } else if (character === " ") {
      continue;
    } else {
      run = 0;
    }
  }
  return false;
}

// Whether a paragraph is prose, or something that only looks like it.
//
// Reading a table of numbers aloud one sentence at a time helps nobody, so
// anything this rejects is shown as an aside to skim rather than metered out.
export function isFragment(paragraph) {
  const trimmed = paragraph.trim();
  if (!trimmed) return true;
  const words = wordCount(trimmed);

  if (hasDotLeader(trimmed)) return true;

  // No sentence-ending punctuation anywhere in it. Index entries, table rows
  // and contents lines all look like this; prose essentially never does.
  let hasEnder = false;
  for (const character of trimmed) {
    if (SENTENCE_ENDERS.has(character)) { hasEnder = true; break; }
  }
  if (!hasEnder) return true;

  // Mostly symbols and digits: a stripped equation, a table row, a data line.
  if (words < 60 && letterDensity(trimmed) < 0.62) return true;

  if (words >= 14) return false;

  // A properly finished sentence is prose even when it is short. "Try one now."
  // is a sentence; six words was too high a bar in the app, and the short ones
  // were being glued onto the heading that followed them.
  const last = [...trimmed].pop();
  if (SENTENCE_ENDERS.has(last) && words >= 3) return false;
  return true;
}

// Abbreviations that end in a full stop without ending a sentence.
const ABBREVIATIONS = new Set([
  "dr", "mr", "mrs", "ms", "prof", "rev", "hon", "st", "mt",
  "fig", "figs", "no", "nos", "vs", "v", "ed", "eds", "vol", "vols",
  "pp", "al", "etc", "cf", "ca", "approx", "est",
  "inc", "ltd", "co", "corp", "dept", "univ",
  "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sept", "sep", "oct", "nov", "dec",
  "jr", "sr", "sq", "ft", "in", "lb", "oz", "ml", "cm", "mm", "km", "kg",
]);

// Whether a segment is an abbreviation that the segmenter mistook for the end
// of a sentence.
//
// Intl.Segmenter handles Japanese and Chinese exactly as well as Apple's
// NLTokenizer does, which is the thing that mattered most. English
// abbreviations it does not: measured on ordinary prose it strands "Dr." as its
// own sentence, and turns "J. R. R. Tolkien" into four of them. A stranded
// "Dr." becomes a card that ends mid-sentence, which is the one failure this
// whole module exists to prevent.
//
// The test is on the segment's LAST token rather than the whole segment, which
// is what catches "Compare v." and "2.1 with v." alike.
function isStranded(segment) {
  const trimmed = segment.trim();
  if (!trimmed.endsWith(".")) return false;
  const tokens = trimmed.split(/\s+/);
  const last = tokens[tokens.length - 1].replace(/^[("'‘“]+/, "");
  const bare = last.slice(0, -1).toLowerCase();
  // A single letter is an initial: "J. R. R. Tolkien". Dotted letters are an
  // abbreviation too: "U.S.", "D.C.", "U.K.", "e.g.", "i.e.", "a.m.", "p.m.".
  return ABBREVIATIONS.has(bare) || /^\p{L}$/u.test(bare) || /^(\p{L}\.)+\p{L}$/u.test(bare);
}

const segmenters = new Map();
function segmenterFor(locale) {
  if (!segmenters.has(locale)) {
    segmenters.set(locale, new Intl.Segmenter(locale, { granularity: "sentence" }));
  }
  return segmenters.get(locale);
}

export function splitSentences(text, options = OPTIONS.standard, locale = "en") {
  const raw = [...segmenterFor(locale).segment(text)]
    .map((s) => s.segment)
    .filter((s) => s.trim());

  // Merging a stranded abbreviation forward is deliberately the safe direction.
  // Over-merging costs nothing, because sentences are packed up to the word
  // target anyway; under-merging is the broken card.
  const sentences = [];
  let buffer = "";
  for (const piece of raw) {
    buffer += (buffer ? " " : "") + piece.trim();
    if (!isStranded(piece)) {
      sentences.push(buffer);
      buffer = "";
    }
  }
  if (buffer) sentences.push(buffer);

  if (sentences.length === 0) {
    const trimmed = text.trim();
    if (trimmed) sentences.push(trimmed);
  }
  return sentences.flatMap((s) => splitRunOn(s, options.runOnWords));
}

// One sentence longer than the limit is broken at a clause, because a card that
// is nothing but half a sentence is no easier to read than the page was.
function splitRunOn(sentence, limit) {
  if (wordCount(sentence) <= limit) return [sentence];

  const breakers = [";", ":", "—", "；", "：", "、"];
  const parts = [];
  let current = "";
  let currentWords = 0;

  // Split on spaces where there are spaces, and on characters where there are
  // not, so a long CJK sentence can still be broken at a clause.
  const hasSpaces = sentence.includes(" ");
  const pieces = hasSpaces ? sentence.split(" ").filter(Boolean) : [...sentence];

  for (const word of pieces) {
    current += (current === "" || !hasSpaces ? "" : " ") + word;
    currentWords += 1;
    const last = word[word.length - 1];
    const isBreaker = breakers.includes(last);
    const isComma = last === ",";
    if (currentWords >= limit / 2 && (isBreaker || (isComma && currentWords >= limit))) {
      parts.push(current);
      current = "";
      currentWords = 0;
    }
  }
  if (current) parts.push(current);
  return parts.length ? parts : [sentence];
}

// Runs of non-prose collapse into one card instead of thirty.
function asideBlocks(fragments, options) {
  if (fragments.length === 1 && wordCount(fragments[0]) <= 10) {
    return [{ text: fragments[0], kind: "heading" }];
  }

  const blocks = [];
  let lines = [];
  let words = 0;
  const lineLimit = 12;

  const flush = () => {
    if (!lines.length) return;
    blocks.push({ text: lines.join("\n"), kind: "aside" });
    lines = [];
    words = 0;
  };

  for (const fragment of fragments) {
    const count = wordCount(fragment);
    if (lines.length && (lines.length >= lineLimit || words + count > options.maxWords * 2)) {
      flush();
    }
    lines.push(fragment);
    words += count;
  }
  flush();
  return blocks;
}

/**
 * blocks: [{ kind: "paragraph"|"heading"|"figure", text?, src?, alt?, caption? }]
 * returns { chunks, sections }
 */
export function chunk(blocks, options = OPTIONS.standard, locale = "en") {
  const chunks = [];
  let fragments = [];
  // The ordinal of the source block. This is the only coordinate that survives
  // a change of card size, which is what makes it the right thing to anchor a
  // saved position to: chunk indices are renumbered by the very change you are
  // trying to recover from.
  let blockIndex = 0;
  let blockHash = "";

  const push = (c) => {
    chunks.push({ id: chunks.length, blockIndex, blockHash, ...c });
  };

  const flushFragments = () => {
    if (!fragments.length) return;
    for (const block of asideBlocks(fragments, options)) {
      push({ text: block.text, kind: block.kind, startsParagraph: true,
             wordCount: wordCount(block.text) });
    }
    fragments = [];
  };

  for (const [ordinal, block] of blocks.entries()) {
    blockIndex = ordinal;
    blockHash = hashOf(block.text || block.caption || block.src || "");
    if (block.kind === "heading") {
      flushFragments();
      push({ text: block.text, kind: "heading", level: block.level || 2,
             startsParagraph: true, wordCount: wordCount(block.text) });
      continue;
    }

    if (block.kind === "figure") {
      flushFragments();
      push({ text: block.caption || block.alt || "", kind: "figure",
             startsParagraph: true, wordCount: 0,
             figure: { src: block.src, alt: block.alt || "", caption: block.caption || "" } });
      continue;
    }

    const paragraph = (block.text || "").trim();
    if (!paragraph) continue;

    if (block.forceAside || isFragment(paragraph)) {
      fragments.push(paragraph);
      continue;
    }
    flushFragments();

    const sentences = splitSentences(paragraph, options, locale);
    let buffer = [];
    let bufferWords = 0;
    let isFirstOfParagraph = true;

    const flush = () => {
      if (!buffer.length) return;
      push({ text: buffer.join(" "), kind: "prose",
             startsParagraph: isFirstOfParagraph, wordCount: bufferWords });
      isFirstOfParagraph = false;
      buffer = [];
      bufferWords = 0;
    };

    for (const sentence of sentences) {
      const words = wordCount(sentence);
      if (buffer.length && bufferWords + words > options.maxWords) flush();
      buffer.push(sentence);
      bufferWords += words;
      if (bufferWords >= options.targetWords) flush();
    }
    flush();
  }
  flushFragments();

  return { chunks, sections: assignSections(chunks, options) };
}

// Sections exist so progress means something: "1 of 23 in this stretch" is a
// number you can hold, where "chunk 1,847 of 5,817" is not.
export function assignSections(chunks, options = OPTIONS.standard) {
  const sections = [];
  if (!chunks.length) return sections;

  let sectionIndex = 0;
  let first = 0;
  let words = 0;

  for (let i = 0; i < chunks.length; i += 1) {
    chunks[i].section = sectionIndex;
    words += chunks[i].wordCount;

    const isLast = i === chunks.length - 1;
    // Prefer to break where a new paragraph starts, so a section is a whole
    // thought rather than a word count.
    const atNaturalBreak = isLast || (i + 1 < chunks.length && chunks[i + 1].startsParagraph);
    const longEnough = words >= options.sectionWords;
    const wayTooLong = words >= options.sectionWords * 2;

    if (isLast || (longEnough && atNaturalBreak) || wayTooLong) {
      sections.push({ id: sectionIndex, firstChunk: first, lastChunk: i, wordCount: words });
      sectionIndex += 1;
      first = i + 1;
      words = 0;
    }
  }
  return sections;
}
