import { test } from "node:test";
import assert from "node:assert/strict";
import { loadFixture } from "./helpers/dom.js";
import { extract } from "../src/reader/extract.js";
import { chunk, OPTIONS, SENTENCE_ENDERS } from "../src/reader/chunker.js";
import { resolve, snippetOf } from "../src/reader/position.js";

// The promise is that a card never cuts a sentence in half. That is not the
// same as "every card ends in a full stop": a paragraph can legitimately end on
// a colon introducing a code block, or on a dash. So a card is well-formed when
// it ends a sentence, OR it is the last card of its source paragraph — which is
// a sentence boundary by definition.
function wellFormed(card, chunks) {
  const stripped = card.text.trim().replace(/[)\]"'’”]+$/, "");
  if (SENTENCE_ENDERS.has([...stripped].pop())) return true;
  const last = chunks.filter((c) => c.blockIndex === card.blockIndex).pop();
  return last?.id === card.id;
}

function read(name = "article.html") {
  loadFixture(name);
  const article = extract();
  assert.ok(article, "extraction returned nothing");
  return article;
}

test("extracts the article and leaves the page furniture behind", () => {
  const article = read();
  const text = article.blocks.map((b) => b.text || "").join(" ");

  assert.match(article.title, /tide leaves behind/i);
  assert.ok(text.includes("rehearsal for the whole ocean"), "lost the opening");
  assert.ok(text.includes("photograph"), "lost the closing");

  // Chrome that must not survive.
  assert.ok(!text.includes("Subscribe to the newsletter"), "kept the promo bar");
  assert.ok(!/All rights reserved/i.test(text), "kept the footer");
});

test("maps elements to the right kinds", () => {
  const article = read();
  const kinds = article.blocks.reduce((acc, b) => {
    acc[b.kind] = (acc[b.kind] || 0) + 1;
    return acc;
  }, {});

  assert.ok(kinds.paragraph >= 6, `too few paragraphs: ${JSON.stringify(kinds)}`);
  assert.ok(kinds.heading >= 2, `lost the subheadings: ${JSON.stringify(kinds)}`);
  assert.equal(kinds.figure, 1, "lost the figure");

  const figure = article.blocks.find((b) => b.kind === "figure");
  assert.match(figure.src, /quadrat\.jpg$/);
  assert.match(figure.caption, /Carrick Point/);

  // Code and tables are marked as never-prose at the source, so no heuristic
  // downstream has to recognise them.
  const forced = article.blocks.filter((b) => b.forceAside);
  assert.ok(forced.length >= 2, "code block and table were not marked aside");
  assert.ok(forced.some((b) => b.text.includes("carrying_capacity")));
});

test("code and tables never end up as prose cards", () => {
  const article = read();
  const { chunks } = chunk(article.blocks);
  const prose = chunks.filter((c) => c.kind === "prose");

  for (const card of prose) {
    assert.ok(!card.text.includes("carrying_capacity"), "code leaked into prose");
    assert.ok(!/\|\s*\d{4}\s*\|/.test(card.text), "table row leaked into prose");
  }
  assert.ok(chunks.some((c) => c.kind === "aside"), "nothing was offered to skim");
});

test("no card from a real article ends mid-sentence", () => {
  const article = read();
  for (const [name, options] of Object.entries(OPTIONS)) {
    const { chunks } = chunk(article.blocks, options);
    const prose = chunks.filter((c) => c.kind === "prose");
    assert.ok(prose.length > 3, `${name}: suspiciously few cards`);
    for (const card of prose) {
      assert.ok(wellFormed(card, chunks),
                `${name}: cut mid-sentence: ${JSON.stringify(card.text.slice(-70))}`);
    }
  }
});

test("the abbreviation in the fixture does not strand a card", () => {
  const article = read();
  const { chunks } = chunk(article.blocks, OPTIONS.cozy);
  for (const card of chunks) {
    assert.ok(!/\bDr\.$/.test(card.text.trim()), "stranded 'Dr.'");
    assert.ok(!/\bFig\.$/.test(card.text.trim()), "stranded 'Fig.'");
  }
  // And the sentence survived intact somewhere.
  assert.ok(chunks.some((c) => c.text.includes("Dr. Aleen Vasquez")));
});

test("structure is internally consistent", () => {
  const article = read();
  const { chunks, sections } = chunk(article.blocks);

  chunks.forEach((c, i) => {
    assert.equal(c.id, i, "chunk ids are not contiguous");
    assert.equal(typeof c.blockIndex, "number", "chunk lost its block anchor");
    assert.ok(c.blockHash, "chunk lost its block hash");
  });

  let covered = 0;
  for (const section of sections) {
    assert.equal(section.firstChunk, covered, "gap or overlap between sections");
    covered = section.lastChunk + 1;
  }
  assert.equal(covered, chunks.length, "sections do not cover every chunk");
});

test("changing card size lands you on the same sentence", () => {
  const article = read();
  const standard = chunk(article.blocks, OPTIONS.standard);

  // Read to a card in the middle, then change how much is shown at a time.
  for (const index of [2, 5, 9]) {
    if (index >= standard.chunks.length) continue;
    const current = standard.chunks[index];
    const saved = {
      chunkIndex: index,
      blockIndex: current.blockIndex,
      blockHash: current.blockHash,
      snippet: snippetOf(current.text),
      total: standard.chunks.length,
    };

    for (const size of ["cozy", "roomy"]) {
      const next = chunk(article.blocks, OPTIONS[size]);
      const landed = resolve(saved, next.chunks);
      assert.equal(
        next.chunks[landed].blockIndex, current.blockIndex,
        `${size}: landed in a different paragraph (card ${index})`,
      );
    }
  }
});

test("a position survives the article gaining a paragraph", () => {
  const article = read();
  const before = chunk(article.blocks, OPTIONS.standard);
  const index = Math.min(6, before.chunks.length - 1);
  const current = before.chunks[index];
  const saved = {
    chunkIndex: index,
    blockIndex: current.blockIndex,
    blockHash: current.blockHash,
    snippet: snippetOf(current.text),
    total: before.chunks.length,
  };

  // The site appends a correction at the top, shifting every block ordinal.
  const edited = [
    { kind: "paragraph", text: "Correction: an earlier version misspelled a name." },
    ...article.blocks,
  ];
  const after = chunk(edited, OPTIONS.standard);
  const landed = resolve(saved, after.chunks);

  assert.equal(after.chunks[landed].blockHash, current.blockHash,
               "lost the place when a paragraph was inserted above it");
});
