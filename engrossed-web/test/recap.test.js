import { test } from "node:test";
import assert from "node:assert/strict";
import { loadFixture } from "./helpers/dom.js";
import { extract } from "../src/reader/extract.js";
import { chunk, OPTIONS } from "../src/reader/chunker.js";
import {
  QUESTIONS, headingFor, questionFor, openingLines, tallyFor, checkInKey, CHECK_IN_ARM_MS,
} from "../src/reader/recap.js";

const prose = (text, startsParagraph = true) =>
  ({ kind: "prose", text, startsParagraph, wordCount: text.split(/\s+/).length });
const heading = (text) => ({ kind: "heading", text, level: 2, startsParagraph: true, wordCount: 1 });
const words = (n, word = "word") => Array(n).fill(word).join(" ");
const part = (firstChunk, lastChunk, id = 0, wordCount = 0) => ({ id, firstChunk, lastChunk, wordCount });

// ---------- the question ----------

test("the question names the heading the part sits under", () => {
  const chunks = [heading("Why we drift"), prose(words(80)), prose(words(80), false)];
  assert.equal(headingFor(chunks, part(0, 2)), "Why we drift");
  assert.equal(questionFor(part(0, 2), "Why we drift"), "What was “Why we drift” about?");
});

test("a part that starts mid-section still finds the heading above it", () => {
  const chunks = [heading("Tides"), prose(words(50)), prose(words(80)), prose(words(80))];
  assert.equal(headingFor(chunks, part(2, 3)), "Tides");
});

test("a part split between two sections names neither", () => {
  // Half under one heading and half under the next: naming either would ask
  // about something the reader only saw half of.
  const chunks = [heading("One"), prose(words(60)), heading("Two"), prose(words(60))];
  assert.equal(headingFor(chunks, part(0, 3)), null);
  const mostlyTwo = [heading("One"), prose(words(20)), heading("Two"), prose(words(100))];
  assert.equal(headingFor(mostlyTwo, part(0, 3)), "Two");
});

test("a lone line the chunker showed as a heading is not a topic", () => {
  // "* * *" or "II" between paragraphs becomes a heading card, but the page
  // never called it a heading, so it has no level.
  const chunks = [heading("Tides"), prose(words(40)),
    { kind: "heading", text: "* * *", startsParagraph: true, wordCount: 3 }, prose(words(80))];
  assert.equal(headingFor(chunks, part(0, 3)), "Tides");
});

test("Chinese and Japanese headings are measured in characters", () => {
  const chunks = [heading("潮だまりの生き物たち"), prose(words(80))];
  assert.equal(headingFor(chunks, part(0, 1)), "潮だまりの生き物たち");
  const long = [heading("潮だまりの生き物たちが毎日どのように暮らしているのかについての長い説明"), prose(words(80))];
  assert.equal(headingFor(long, part(0, 1)), null);
});

test("a heading that is already a question is asked as it is", () => {
  assert.equal(questionFor(part(0, 0), "Why do we drift?"), "Why do we drift?");
});

test("long headings and trailing colons are handled", () => {
  const long = [heading(words(14, "long")), prose(words(80))];
  assert.equal(headingFor(long, part(0, 1)), null);
  const colon = [heading("Background:"), prose(words(80))];
  assert.equal(headingFor(colon, part(0, 1)), "Background");
});

test("without a heading the question changes from part to part, and stays put for each", () => {
  const asked = [0, 1, 2, 3].map((id) => questionFor(part(0, 0, id), null));
  assert.equal(new Set(asked).size, QUESTIONS.length);
  assert.equal(questionFor(part(0, 0, 5), null), questionFor(part(0, 0, 5), null));
  assert.equal(questionFor(part(0, 0, 0), null), "In one line, what was that about?");
});

test("on a real article, a heading is only named when the part is mostly under it", () => {
  // The demo article's sections are about 150 words each, so every part spans
  // several of them and none should be named.
  loadFixture("../../store/demo/long.html");
  const short = extract();
  const { chunks, sections } = chunk(short.blocks, OPTIONS.standard, "en");
  assert.ok(sections.length >= 3);
  assert.deepEqual(sections.map((s) => headingFor(chunks, s)), sections.map(() => null));

  // One long section, read in small parts, names it every time.
  const blocks = [{ kind: "heading", text: "Vegetation zones", level: 2 }];
  for (let i = 0; i < 12; i += 1) {
    blocks.push({ kind: "paragraph", text: `Plants sort themselves into bands by how long they sit under water each day. ${words(60, "marsh")}.` });
  }
  const long = chunk(blocks, OPTIONS.cozy, "en");
  assert.ok(long.sections.length >= 2);
  for (const s of long.sections) assert.equal(headingFor(long.chunks, s), "Vegetation zones");
});

// ---------- remind me ----------

test("remind me lists how each paragraph opened, and nothing else", () => {
  const chunks = [
    heading("A heading"),
    prose("When your mind wanders it usually happens without you noticing at all."),
    prose("This card carries on the same paragraph.", false),
    { kind: "aside", text: "x = 1", startsParagraph: true, wordCount: 3 },
    prose("Short one."),
    prose("Most advice about reading assumes the problem is time. It is not."),
  ];
  assert.deepEqual(openingLines(chunks, part(0, 5)), [
    "When your mind wanders it usually happens without you…",
    "Short one.",
    "Most advice about reading assumes the problem is time.",
  ]);
});

test("long English words are never cut in half", () => {
  const text = "Neurodevelopmental characteristics notwithstanding, comprehension-monitoring interventions demonstrably " +
    "outperformed conventional instructional methodologies across heterogeneous populations.";
  const [line] = openingLines([prose(text)], part(0, 0));
  assert.equal(line, text.split(" ").slice(0, 9).join(" ") + "…");
});

test("remind me stops at six lines", () => {
  const chunks = Array.from({ length: 10 }, (_, i) => prose(`Paragraph ${i} opens here.`));
  assert.equal(openingLines(chunks, part(0, 9)).length, 6);
});

test("text without spaces is cut by characters", () => {
  const japanese = "注意がそれるのは、たいてい気づかないうちに起こる。".repeat(5);
  const [line] = openingLines([prose(japanese)], part(0, 0));
  assert.equal([...line].length, 31, line);
  assert.ok(line.endsWith("…"));
});

test("Thai is cut by characters, and never through a vowel mark", () => {
  const thai = "ความสนใจของเราล่องลอยไปโดยไม่รู้ตัวเสมอเมื่ออ่านหน้ากระดาษที่แน่นไปด้วยตัวอักษร";
  const [line] = openingLines([prose(thai)], part(0, 0));
  assert.ok(line.endsWith("…"), line);
  const segments = [...new Intl.Segmenter("th", { granularity: "grapheme" }).segment(line.slice(0, -1))];
  assert.equal(segments.length, 30);
  assert.ok(thai.startsWith(line.slice(0, -1)));
});

test("the tally rounds to something you can say", () => {
  assert.equal(tallyFor({ wordCount: 643 }), "That part was about 640 words, roughly 3 minutes of reading.");
  assert.equal(tallyFor({ wordCount: 90 }), "That part was about 90 words, roughly 1 minute of reading.");
});

// ---------- keys ----------

test("Space never skips the check-in", () => {
  // People press Space to move through the cards, so the press after the last
  // card of a part used to close the check-in before it was read.
  assert.equal(checkInKey(" ", { shownFor: 50 }), "hint");
  assert.equal(checkInKey(" ", { shownFor: 60_000 }), "hint");
  assert.equal(checkInKey("ArrowRight", { shownFor: 60_000 }), "hint");
});

test("Enter carries on, but not in the first second or while held down", () => {
  assert.equal(checkInKey("Enter", { shownFor: CHECK_IN_ARM_MS - 1 }), "ignore");
  assert.equal(checkInKey("Enter", { shownFor: CHECK_IN_ARM_MS }), "continue");
  assert.equal(checkInKey("Enter", { shownFor: 60_000, repeat: true }), "ignore");
});

test("a focused button can still be pressed from the keyboard", () => {
  // Someone who tabbed to "Read it again" must get "Read it again".
  assert.equal(checkInKey("Enter", { shownFor: 5000, onButton: true }), "native");
  assert.equal(checkInKey(" ", { shownFor: 5000, onButton: true }), "native");
  assert.equal(checkInKey(" ", { shownFor: 100, onButton: true }), "hint");
  // A held Space on a button is still one press, made when it is let go.
  assert.equal(checkInKey(" ", { shownFor: 5000, onButton: true, repeat: true }), "native");
});

test("other keys are left alone", () => {
  assert.equal(checkInKey("ArrowLeft", { shownFor: 5000 }), "pass");
  assert.equal(checkInKey("Tab", { shownFor: 5000 }), "pass");
});
