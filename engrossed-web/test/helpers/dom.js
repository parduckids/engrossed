// Loads a fixture into a jsdom document and sets up the globals the extraction
// code expects in a browser, so extract.js can be tested unmodified.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

const here = path.dirname(fileURLToPath(import.meta.url));

// Readability is a classic script guarded by `typeof module === "object"`.
// Evaluating it in a function scope avoids renaming the vendored file or
// adding a package.json beside it just to satisfy the test runner.
function loadReadability() {
  const source = fs.readFileSync(path.join(here, "../../vendor/readability.js"), "utf8");
  const factory = new Function("module", "exports", `${source}\nreturn Readability;`);
  return factory({ exports: {} }, {});
}

const Readability = loadReadability();

export function loadFixture(name, url = "https://example.com/article") {
  const html = fs.readFileSync(path.join(here, "../fixtures", name), "utf8");
  const dom = new JSDOM(html, { url });

  globalThis.__engrossedReadability = Readability;
  globalThis.document = dom.window.document;
  globalThis.DOMParser = dom.window.DOMParser;
  globalThis.location = dom.window.location;
  globalThis.HTMLInputElement = dom.window.HTMLInputElement;

  return dom;
}
