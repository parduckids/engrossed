import { test } from "node:test";
import assert from "node:assert/strict";
import {
  chunk, splitSentences, isFragment, wordCount, letterDensity,
  assignSections, OPTIONS, SENTENCE_ENDERS,
} from "../src/reader/chunker.js";

const para = (text) => ({ kind: "paragraph", text });

// A card may legitimately end on a closing quote or bracket after the stop.
function endsCleanly(text) {
  const trimmed = text.trim();
  if (!trimmed) return true;
  const stripped = trimmed.replace(/[)\]"'’”]+$/, "");
  const last = [...stripped].pop();
  return SENTENCE_ENDERS.has(last);
}

test("counts each CJK character as one word", () => {
  assert.equal(wordCount("The quick brown fox jumps over the lazy dog"), 9);
  assert.equal(wordCount("これは最初の文です"), 9);
  assert.equal(wordCount(""), 0);
  assert.equal(wordCount("   spaced   out   "), 2);
});

test("letter density separates prose from a table row", () => {
  assert.ok(letterDensity("This is an ordinary sentence.") > 0.8);
  assert.ok(letterDensity("| 12 | 4.7 | 9 | 0.3 |") < 0.62);
});

test("isFragment rejects non-prose, keeps short real sentences", () => {
  assert.equal(isFragment("Chapter One . . . . . . . . 14"), true, "dot leader");
  assert.equal(isFragment("Introduction to Ecology"), true, "no sentence ender");
  assert.equal(isFragment("x = 2y + 3z - 4"), true, "equation");
  assert.equal(isFragment("Try one now."), false, "short but finished");
  assert.equal(
    isFragment("Ecology is the study of the relationships between organisms and their environment."),
    false,
  );
});

// The reason this module exists.
test("a stranded abbreviation never ends a sentence", () => {
  const cases = [
    ["Dr. Smith went to Washington. He arrived late.", 2],
    ["J. R. R. Tolkien wrote it. He was a professor.", 2],
    ["Compare v. 2.1 with v. 3.0. They differ.", 2],
    ["See Fig. 3 for the result. It is clear.", 2],
    ["Use a hash map, e.g. a dictionary. That is faster.", 2],
    ["She has a Ph.D. in physics. She teaches now.", 2],
    ["It cost $4.99 today. A bargain.", 2],
    ["Smith et al. 2019 found no effect. We agree.", 2],
    ["He lived on Main St. in Boston. Later he moved.", 2],
    ["Stop. Think about it. Then act.", 3],
  ];
  for (const [text, expected] of cases) {
    const sentences = splitSentences(text);
    assert.equal(sentences.length, expected, `wrong split: ${JSON.stringify(sentences)}`);
    for (const sentence of sentences) {
      assert.ok(endsCleanly(sentence), `ends mid-sentence: ${JSON.stringify(sentence)}`);
      assert.ok(
        !/\s(Dr|Mr|Fig|St|v|al|vs)\.$/i.test(sentence.trim()),
        `stranded abbreviation: ${JSON.stringify(sentence)}`,
      );
    }
  }
});

test("Japanese splits on the ideographic full stop and never on the comma", () => {
  const ja = "これは最初の文です。次に、長い文があります、しかし、読点では切れません。最後の文です。";
  const sentences = splitSentences(ja, OPTIONS.standard, "ja");
  assert.equal(sentences.length, 3);
  for (const sentence of sentences) {
    assert.ok(!sentence.trim().endsWith("、"), `split on a comma: ${sentence}`);
    assert.ok(sentence.trim().endsWith("。"), `did not end on a full stop: ${sentence}`);
  }
});

test("cards never end mid-sentence", () => {
  const text =
    "Ecology is the study of the relationships between organisms and their environment. " +
    "It is unusual among the sciences in that its questions are almost always about more " +
    "than one thing at a time, which is what makes it difficult. Dr. Smith showed that " +
    "cohesion is the tendency of like molecules to stick to one another. Surface tension " +
    "is the visible face of cohesion, and it sets a hard limit on how small a drop can be.";

  for (const [name, options] of Object.entries(OPTIONS)) {
    const { chunks } = chunk([para(text)], options);
    const prose = chunks.filter((c) => c.kind === "prose");
    assert.ok(prose.length > 0, `${name}: produced no prose`);
    for (const card of prose) {
      // A card that ends its paragraph is a sentence boundary whatever its
      // final punctuation; anything else must end a sentence outright.
      const lastOfBlock = chunks.filter((c) => c.blockIndex === card.blockIndex).pop();
      const ok = endsCleanly(card.text) || lastOfBlock?.id === card.id;
      assert.ok(ok, `${name}: card ends mid-sentence: ${JSON.stringify(card.text)}`);
    }
  }
});

test("chunk ids are contiguous from zero", () => {
  const blocks = [
    { kind: "heading", text: "Introduction" },
    para("This is a complete sentence. So is this one."),
    { kind: "figure", src: "a.png", alt: "A diagram", caption: "Figure 1" },
    para("| 1 | 2 | 3 |"),
    para("And a final paragraph that is unmistakably prose."),
  ];
  const { chunks } = chunk(blocks);
  chunks.forEach((c, i) => assert.equal(c.id, i));
});

test("sections cover every chunk with no gap or overlap", () => {
  const blocks = Array.from({ length: 80 }, (_, i) =>
    para(`This is paragraph number ${i}. It contains a second sentence so that it counts as prose.`));
  const { chunks, sections } = chunk(blocks);
  assert.ok(sections.length > 1, "expected more than one section");

  let covered = 0;
  for (const section of sections) {
    assert.equal(section.firstChunk, covered, "section does not start where the last ended");
    covered = section.lastChunk + 1;
  }
  assert.equal(covered, chunks.length, "sections do not cover every chunk");
  chunks.forEach((c) => assert.ok(typeof c.section === "number"));
});

test("non-prose is classified as an aside, not fed out as prose", () => {
  const blocks = [
    para("A real paragraph of prose, with a full stop at the end."),
    { kind: "paragraph", text: "const x = foo(bar);", forceAside: true },
    { kind: "paragraph", text: "let y = x * 2;", forceAside: true },
  ];
  const { chunks } = chunk(blocks);
  const asides = chunks.filter((c) => c.kind === "aside");
  assert.equal(asides.length, 1, "consecutive non-prose should collapse into one card");
  assert.ok(asides[0].text.includes("const x"));
  assert.ok(chunks.some((c) => c.kind === "prose"));
});

test("a lone short fragment becomes a heading rather than an aside", () => {
  const { chunks } = chunk([
    para("Opening prose with a full stop."),
    { kind: "paragraph", text: "Properties of Water" },
    para("More prose follows here, ending properly."),
  ]);
  assert.ok(chunks.some((c) => c.kind === "heading" && c.text === "Properties of Water"));
});

test("a run-on sentence is broken at a clause, not mid-word", () => {
  const runOn = Array.from({ length: 40 }, (_, i) => `clause ${i} of the thing;`).join(" ");
  const sentences = splitSentences(runOn + ".", OPTIONS.cozy);
  assert.ok(sentences.length > 1, "run-on was not split");
  for (const s of sentences) {
    assert.ok(wordCount(s) <= OPTIONS.cozy.runOnWords + 5, `piece too long: ${wordCount(s)}`);
  }
});

test("empty and degenerate input does not throw", () => {
  assert.deepEqual(chunk([]).chunks, []);
  assert.deepEqual(assignSections([]), []);
  assert.deepEqual(chunk([para("   ")]).chunks, []);
});

test("does not split after a dotted abbreviation such as U.S.", () => {
  const text = "The bill reached the floor of the U.S. Senate on Tuesday, where it passed.";
  assert.deepEqual(splitSentences(text), [text]);
  for (const abbreviation of ["D.C.", "U.K.", "e.g.", "i.e.", "a.m.", "p.m."]) {
    const sentence = `They met at 9 ${abbreviation} Then they left.`;
    assert.equal(splitSentences(sentence).length, 1, abbreviation);
  }
  assert.equal(splitSentences("Stop. Think about it. Then act.").length, 3);
});

// The titles the app's tokenizer was measured stranding. Both chunkers carry
// the same list, so the same text makes the same cards in either.
test("does not split after a title such as Gen. or Sen.", () => {
  for (const title of ["Gen.", "Capt.", "Sgt.", "Col.", "Lt.", "Gov.", "Sen.", "Rev.", "Hon."]) {
    const text = `It was ${title} Grant who spoke first. Nobody else did.`;
    const sentences = splitSentences(text);
    assert.equal(sentences.length, 2, `${title}: ${JSON.stringify(sentences)}`);
    assert.ok(sentences[0].startsWith("It was") && sentences[0].endsWith("spoke first."), title);
  }
});
