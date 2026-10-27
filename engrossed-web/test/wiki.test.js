// Regression tests for three bugs found by running the reader on a real
// Wikipedia article in Chrome. None of them showed up on the first fixture,
// because it did not have Wikipedia's markup.

import { test } from "node:test";
import assert from "node:assert/strict";
import { loadFixture } from "./helpers/dom.js";
import { extract } from "../src/reader/extract.js";
import { chunk, OPTIONS } from "../src/reader/chunker.js";

function read() {
  loadFixture("wiki.html", "https://encyclopedia.example/wiki/Salt_marsh");
  const article = extract();
  assert.ok(article, "extraction returned nothing");
  return article;
}

const headings = (article) =>
  article.blocks.filter((b) => b.kind === "heading").map((b) => b.text);

test("headings inside an [edit] wrapper survive Readability", () => {
  // Readability removed every wrapper div as link-heavy boilerplate, taking the
  // heading with it. On the real article that deleted all eleven section titles.
  const found = headings(read());
  assert.ok(found.includes("Formation"), `lost Formation: ${JSON.stringify(found)}`);
  assert.ok(found.includes("Sediment supply"));
  assert.ok(found.includes("Vegetation zones"));
  assert.ok(!found.some((h) => /edit/i.test(h)), "kept the [edit] link text");
});

test("a section heading followed straight by its subsection is kept", () => {
  // "Formation" has no prose of its own before "Sediment supply". Treating
  // that as an empty nav label deleted every parent section on the page.
  const article = read();
  const found = headings(article);
  const formation = found.indexOf("Formation");
  assert.ok(formation >= 0, "parent heading was pruned");
  assert.equal(found[formation + 1], "Sediment supply", "nesting order changed");
});

test("citation markers are removed, real superscripts are not", () => {
  const article = read();
  const text = article.blocks.map((b) => b.text || "").join(" ");

  assert.ok(!/\[\s*\d+\s*\]/.test(text), "a [n] marker survived");
  assert.ok(!text.includes("citation needed"), "kept [citation needed]");
  assert.ok(!/accelerating the process\.\s*3\b/.test(text), "kept a footnote link");

  // 10<sup>6</sup> is a number. Removing that sup would change what the text says.
  assert.ok(/10\s*6\s+individual/.test(text) || text.includes("106 individual"),
            `lost a real exponent: ${text.match(/more than .{0,30}/)?.[0]}`);
});

test("references and see-also are offered to skim, not served as reading", () => {
  const article = read();
  const { chunks } = chunk(article.blocks, OPTIONS.standard);

  const referencesAt = chunks.findIndex((c) => c.kind === "heading" && c.text === "References");
  assert.ok(referencesAt >= 0, "References heading disappeared entirely");

  const after = chunks.slice(referencesAt + 1);
  assert.ok(after.length > 0, "the references themselves disappeared");
  assert.equal(after.filter((c) => c.kind === "prose").length, 0,
               "a citation was served as a prose card");
  assert.ok(after.some((c) => c.kind === "aside" && c.text.includes("Saltmarsh Ecology")),
            "the reference list is not available to skim");

  // And the real article before it is still prose.
  const body = chunks.slice(0, referencesAt).filter((c) => c.kind === "prose");
  assert.ok(body.some((c) => c.text.includes("biologically productive")));
});

test("the page around the article is left out", () => {
  const text = read().blocks.map((b) => b.text || "").join(" ");
  assert.ok(!text.includes("Random"), "kept site navigation");
  assert.ok(!text.includes("Privacy policy"), "kept the footer");
});
