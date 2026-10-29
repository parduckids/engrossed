// Turns the page into typed blocks for the chunker.
//
// This is the part the Swift app has to work hardest for. There, paragraphs are
// reconstructed from the coordinates of individual glyph boxes, headings are
// inferred from modal x-height, and the printed contents page has to be
// recognised by the density of its numbering. Here the page simply says <p> and
// <h2>, so almost all of that disappears. What is left is choosing which
// elements are worth reading and which should be offered to skim.

const SKIP = new Set([
  "SCRIPT", "STYLE", "NOSCRIPT", "IFRAME", "SVG", "CANVAS", "FORM",
  "NAV", "FOOTER", "BUTTON", "SELECT", "INPUT", "TEXTAREA", "VIDEO", "AUDIO",
]);
const HEADINGS = new Set(["H1", "H2", "H3", "H4", "H5", "H6"]);
// Set apart rather than read out: code, data and tabular layout are not prose,
// and feeding them to someone a sentence at a time is actively unpleasant.
const ALWAYS_ASIDE = new Set(["PRE", "TABLE", "CODE", "SAMP", "KBD"]);
const PARAGRAPHS = new Set(["P", "BLOCKQUOTE", "LI", "DD", "DT"]);

function clean(text) {
  return (text || "").replace(/\s+/g, " ").trim();
}

// Page furniture set as a heading. Promoting these produces cards that read
// "NEW SECTION / Sign up for our newsletter", and the chunker deliberately
// exempts headings from the fragment test, so nothing downstream catches them.
const JUNK_HEADING = new RegExp(
  "^(related|more (from|on|like)|share|comments?|advertis|sponsored|sign up|" +
  "subscribe|newsletter|read (next|more|also)|most (popular|read)|trending|" +
  "support us|follow us|you (might|may) also|recommended|up next|" +
  "in this article|table of contents|contents|tags?|categor(y|ies)|" +
  "about the author|newsletter signup|popular posts)\\b", "i");

function isJunkHeading(text) {
  if (!text) return true;
  if (text.length > 120) return true;        // a paragraph wearing a heading tag
  return JUNK_HEADING.test(text);
}

// Removes citation markers, so "across.[1] Many" reads "across. Many".
//
// The app strips footnote markers for the same reason: a bracketed number in
// the middle of a sentence is a speed bump on every line. Not every <sup> is a
// citation, though. "10<sup>6</sup>" is a number, and deleting that sup would
// silently change what the text says. So only two shapes go: a bracketed
// marker ("[1]", "[a]", "[citation needed]"), and a short sup that is nothing
// but a link to somewhere else on the same page, which is what a footnote is.
function stripCitations(root) {
  for (const sup of [...root.querySelectorAll("sup")]) {
    const text = clean(sup.textContent);
    const bracketed = /^\[[^\]]*\]$/.test(text);
    const links = sup.querySelectorAll("a");
    const footnoteLink = links.length === 1 && text.length <= 6
      && (links[0].getAttribute("href") || "").startsWith("#");
    if (bracketed || footnoteLink) sup.remove();
  }
}

// About twice the widest the reading column gets, for a sharp picture on a
// high-resolution screen. Anything bigger is download for nothing.
const SHARP_ENOUGH = 1400;

// The best copy of a picture the page offers. `src` is usually a thumbnail
// sized for the page's own narrow column: on Wikipedia it is 330 pixels wide,
// which looked tiny and soft in the reader. srcset and <picture> list sharper
// copies of the same picture, which is what the browser itself would pick.
export function bestSource(img) {
  const base = Number(img.getAttribute("width")) || 300;
  const candidates = [];
  const add = (url, width) => {
    if (url && !url.startsWith("data:")) candidates.push({ url, width });
  };
  add(img.getAttribute("src") || img.getAttribute("data-src"), base);

  const sets = [img.getAttribute("srcset"), img.getAttribute("data-srcset")];
  if (img.parentElement?.tagName === "PICTURE") {
    for (const source of img.parentElement.querySelectorAll("source")) {
      sets.push(source.getAttribute("srcset"), source.getAttribute("data-srcset"));
    }
  }
  for (const set of sets.filter(Boolean)) {
    // A comma followed by a space separates candidates; a bare comma can be
    // part of a URL.
    for (const candidate of set.trim().split(/,\s+/)) {
      const [url, descriptor = "1x"] = candidate.trim().split(/\s+/);
      const n = parseFloat(descriptor);
      if (!n) continue;
      add(url, descriptor.endsWith("w") ? n : n * base);
    }
  }
  if (!candidates.length) return "";
  candidates.sort((a, b) => a.width - b.width);
  const pick = candidates.find((c) => c.width >= SHARP_ENOUGH) || candidates[candidates.length - 1];
  return pick.url;
}

function imageFrom(element) {
  const img = element.tagName === "IMG" ? element : element.querySelector("img");
  if (!img) return null;
  const src = bestSource(img);
  if (!src) return null;
  const caption = element.tagName === "FIGURE"
    ? clean(element.querySelector("figcaption")?.textContent)
    : "";
  return {
    kind: "figure",
    src: new URL(src, document.baseURI).href,
    alt: clean(img.getAttribute("alt")),
    caption,
  };
}

function walk(node, out) {
  for (const child of node.children) {
    const tag = child.tagName;
    if (SKIP.has(tag)) continue;

    if (HEADINGS.has(tag)) {
      const text = clean(child.textContent);
      if (text && !isJunkHeading(text)) {
        out.push({ kind: "heading", text, level: Number(tag[1]) });
      }
      continue;
    }

    if (tag === "FIGURE" || tag === "PICTURE" || tag === "IMG") {
      const figure = imageFrom(child);
      if (figure) out.push(figure);
      continue;
    }

    if (ALWAYS_ASIDE.has(tag)) {
      const text = clean(child.textContent);
      // Keep the newlines in a code block; they are most of its meaning.
      const body = tag === "PRE" ? (child.textContent || "").replace(/\n{3,}/g, "\n\n").trim() : text;
      if (body) out.push({ kind: "paragraph", text: body, forceAside: true });
      continue;
    }

    if (PARAGRAPHS.has(tag)) {
      // A paragraph that is really just a wrapper around an image.
      const figure = child.children.length === 1 ? imageFrom(child) : null;
      if (figure && !clean(child.textContent)) {
        out.push(figure);
        continue;
      }
      const text = clean(child.textContent);
      if (text) out.push({ kind: "paragraph", text });
      continue;
    }

    // Containers: div, section, article, ul, ol, main. Keep going down.
    walk(child, out);
  }
}

/**
 * Returns { title, byline, siteName, blocks } or null when the page is not an
 * article at all.
 */
export function extract(doc = document) {
  const Readability = globalThis.__engrossedReadability;
  if (!Readability) throw new Error("Readability was not loaded");

  // Parse a clone: Readability mutates the document it is given, and mutating
  // the page the reader is sitting on would be unforgivable.
  const clone = doc.cloneNode(true);
  hoistHeadings(clone);

  let article = null;
  try {
    article = new Readability(clone, { charThreshold: 250 }).parse();
  } catch (error) {
    console.warn("Engrossed: Readability failed", error);
  }

  if (!article?.content) return null;

  // DOMParser rather than innerHTML, so nothing in the extracted markup can
  // run even if Readability's sanitising were to miss something.
  const parsed = new DOMParser().parseFromString(article.content, "text/html");
  stripCitations(parsed.body);
  const blocks = [];
  walk(parsed.body, blocks);
  prune(blocks, clean(article.title));
  demoteApparatus(blocks);

  if (!blocks.some((b) => b.kind === "paragraph")) return null;

  return {
    title: clean(article.title) || clean(doc.title),
    byline: clean(article.byline),
    siteName: clean(article.siteName) || location.hostname,
    blocks,
  };
}

// Lifts each heading out of a wrapper that holds nothing else of substance.
//
// Many sites put a heading in a div beside an anchor or an "[edit]" link.
// Readability's boilerplate cleaner sees a block that is mostly link, and
// removes the whole wrapper, heading and all. On Wikipedia that deleted every
// section title in the article. Lifting the heading out first leaves the
// wrapper as nothing but the link, which is exactly what should go. Measured on
// a real article: every paragraph and list item survives, and the only words
// gained are the headings themselves.
function hoistHeadings(root) {
  for (const heading of root.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
    const wrapper = heading.parentElement;
    if (!wrapper || !["DIV", "SPAN", "HGROUP", "HEADER"].includes(wrapper.tagName)) continue;
    const extra = clean(wrapper.textContent.replace(heading.textContent, ""));
    if (extra.length < 20) wrapper.replaceWith(heading);
  }
}

// Two cheap structural passes that no per-element test can do.
function prune(blocks, title) {
  const key = (s) => s.toLowerCase().replace(/[^a-z0-9]/g, "");

  // The article title, repeated as the first heading, is already in the bar.
  const first = blocks.findIndex((b) => b.kind !== "figure");
  if (first >= 0 && blocks[first].kind === "heading"
      && title && key(blocks[first].text) === key(title)) {
    blocks.splice(first, 1);
  }

  // A heading with no prose in its own section is a nav label, or the start of
  // the page's footer. Its section runs until the next heading at the same
  // level or above: a subsection heading straight after it is its content, not
  // a sign that it is empty. Without that distinction, every "Zones" followed
  // directly by "High tide zone" would be deleted.
  for (let i = blocks.length - 1; i >= 0; i -= 1) {
    if (blocks[i].kind !== "heading") continue;
    const level = blocks[i].level || 2;
    let hasProse = false;
    for (let j = i + 1; j < blocks.length; j += 1) {
      const next = blocks[j];
      if (next.kind === "heading" && (next.level || 2) <= level) break;
      if (next.kind === "paragraph" && !next.forceAside) { hasProse = true; break; }
    }
    if (!hasProse) blocks.splice(i, 1);
  }
}

// Sections that hold apparatus rather than reading.
//
// Ported from the app, where it was added after a reader said, about a
// textbook, "it wants me to read all references". A reference list is the
// worst possible thing to meter out a card at a time: every entry is its own
// unrelated fragment and there can be hundreds. They stay in the article, set
// apart to skim, from the heading until the next heading at its level or above.
const APPARATUS = new Set([
  "references", "reference", "bibliography", "bibliographies", "workscited",
  "literaturecited", "citations", "sources", "notes", "endnotes", "footnotes",
  "reading", "readings", "seealso", "externallinks", "links",
  "attribution", "attributions", "credits", "licensing", "license",
  "acknowledgments", "acknowledgements", "index",
]);

function isApparatusHeading(text) {
  let key = text.toLowerCase().replace(/[^a-z]/g, "");
  for (const filler of ["selected", "further", "additional", "and", "the"]) {
    key = key.replaceAll(filler, "");
  }
  return APPARATUS.has(key);
}

function demoteApparatus(blocks) {
  let apparatusLevel = null;
  for (const block of blocks) {
    if (block.kind === "heading") {
      const level = block.level || 2;
      if (apparatusLevel !== null && level <= apparatusLevel) apparatusLevel = null;
      if (apparatusLevel === null && isApparatusHeading(block.text)) apparatusLevel = level;
      continue;
    }
    if (apparatusLevel !== null && block.kind === "paragraph") block.forceAside = true;
  }
}

/**
 * The fallback for pages Readability declines: take the densest block of text
 * on the page and read that. Worse than the real thing, but far better than
 * telling someone their page cannot be read when it plainly can.
 */
export function extractFallback(doc = document) {
  const candidates = [...doc.querySelectorAll("article, main, [role=main], div, section")];
  let best = null;
  let bestScore = 0;

  for (const element of candidates) {
    const paragraphs = element.querySelectorAll("p");
    if (paragraphs.length < 3) continue;
    let score = 0;
    for (const p of paragraphs) score += clean(p.textContent).length;
    // Prefer the tightest container holding the text, not the body wrapping it.
    score /= Math.sqrt(element.querySelectorAll("*").length || 1);
    if (score > bestScore) { bestScore = score; best = element; }
  }

  if (!best) return null;
  // A copy: this path has no Readability clone to work on, and stripping
  // citations out of the live page would visibly change it under the reader.
  const copy = best.cloneNode(true);
  stripCitations(copy);
  const blocks = [];
  walk(copy, blocks);
  prune(blocks, clean(doc.title));
  demoteApparatus(blocks);
  if (!blocks.some((b) => b.kind === "paragraph")) return null;

  return {
    title: clean(doc.title),
    byline: "",
    siteName: location.hostname,
    blocks,
    approximate: true,
  };
}
