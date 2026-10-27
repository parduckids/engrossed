# Engrossed

A reader for people who lose the thread on a full page of text. PDF and EPUB.
SwiftUI, one codebase for macOS 14+ and iOS 17+.

Open a book and it is cut into **cards** — two or three whole sentences each,
alone on screen. Your place is saved constantly; closing the app mid-sentence and
reopening it puts you back on that card.

```bash
open Engrossed.xcodeproj
```

Store listing copy and the privacy policy live in `store/`.

Xcode is installed but not selected on this machine, so command-line builds need:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme Engrossed -destination 'platform=macOS' build
```

## What the evidence supports, and what it doesn't

The design leans on the parts of the reading literature that hold up, and is
explicit where something is popular but unsupported.

| Feature | Standing |
| --- | --- |
| **Cards** — text cut at sentence boundaries | Supported. Segmenting text lowers executive load; chunks never end mid-sentence, because a fragment held in working memory is the cost we're trying to remove. |
| **Checkpoints** — "in one line, what was that about?" | The best-supported thing here. Metacognitive scaffolding closed the comprehension gap between ADHD and non-ADHD adults, and held comprehension up when mind-wandering was high. |
| **Line width 50–70 chars, line height 1.4–1.6** | Supported by accessibility guidance; both sliders start there. |
| **Pace (RSVP)** — one word at a time | Partly. Comprehension survives to ~350 wpm and degrades above it, so the slider stops at 350. Blocking regressions measurably hurts comprehension, so the passage stays on screen underneath and back always works. |
| **Fixation bolding** ("bionic reading") | **Not supported.** A 2,074-person test found no speed gain, eye-tracking found no change in fixation pattern, and comprehension on easy text dropped slightly. Shipped off by default, labelled honestly in Settings. |
| **Per-word gaze highlighting** | Not planned. Front-camera gaze estimation is accurate to roughly a centimetre — nowhere near a word — and there is no evidence the highlight would help even if it were. |

Sources: [metacognitive scaffolding and mind-wandering](https://www.sciencedirect.com/science/article/abs/pii/S0959475224001786) ·
[mitigating mind-wandering while reading](https://files.eric.ed.gov/fulltext/ED596617.pdf) ·
[RSVP and regressions](https://www.tsw.it/wp-content/uploads/Rapid-serial-visual-presentation-in-reading-The-case-of-Spritz-1.pdf) ·
[bionic reading, n=2,074](https://blog.readwise.io/bionic-reading-results/) ·
[bionic reading, eye-tracking](https://www.sciencedirect.com/science/article/pii/S0001691824001811)

## Reading modes

- **Cards** — one chunk at a time, with a faded tail of the previous one for continuity.
- **Flow** — continuous text with everything but the current spot dimmed.
- **Pace** — word-at-a-time at a fixed point, capped at 350 wpm, full passage visible below.

## Getting around

- **Contents** (⌘T in the reader) lists the book's chapters, collapsed. Only the chapter you are
  inside opens automatically, so a 240-entry outline arrives as ~22 chapter names rather than a
  database dump. Built from the PDF's own outline, falling back to detected headings.
- **Go to page** takes the number *printed on the page*, not its position in the file — so "37"
  in a book whose front matter is numbered in roman numerals lands on the right page.
- **Figures zoom.** Tap one for a full-screen viewer: pinch or the +/− buttons, drag to pan,
  double-tap to toggle. Zooming re-renders the region from the PDF at a higher resolution rather
  than magnifying the bitmap, so vector diagrams stay sharp and their labels become readable.

## The bits that took the most work

**Getting prose out of a PDF.** `page.string` throws away the indent and the
extra leading that mark a paragraph, so paragraphs merge and cards end up holding
the tail of one thought and the head of the next. The extractor works from layout
geometry instead — character bounding boxes grouped into lines, with paragraph
breaks inferred from vertical gaps, first-line indents, and short final lines. It
handles hanging indents, mirrored page margins, hyphens broken across lines, and
paragraphs that run over a page boundary. On a 244-page book, 2% of prose cards
end without terminal punctuation, and most of those are code snippets and URLs
that genuinely have none.

**Knowing what isn't prose.** Real documents are full of tables, equations,
author lists and bibliographies. Those are detected and grouped into single
skippable cards rather than dribbled out one table row at a time.

**Figures.** Bands of a page with no text but actual ink are found, trimmed to
their ink bounding box, and re-rendered from the PDF at reading width. On the
Transformer paper this finds exactly the five figures the paper has.

**Mapping an outline onto cards.** An outline entry points at a *page*; the reader's position is a
*card*. A paper can open three sections on page one, so the page alone is ambiguous. Matching each
entry's own words against the cards on its page resolves it — measured at 262 of 262 entries across
a 244-page book and a paper.

**Not losing your place.** Position is stored with the page number and the words
that were on screen, not just a chunk index — an index only means something for
one version of the chunker, so an app update that changes how cards are cut would
otherwise silently move everyone. The library file decodes leniently for the same
reason: adding one field to a saved format shouldn't empty your shelf.

## The guide

`Engrossed/Guide.pdf` is a short bundled book that explains the app. It is not an overlay of coach
marks: it is a real document read in the real reader, so you learn the app by using it. It carries
its own outline so the contents list works, a vector figure so zooming works, and enough words to
reach one checkpoint. It is generated, not hand-drawn: see the script in the scratchpad notes, or
regenerate from `store/`.

It installs on first launch and opens straight away, it is marked `isGuide` so it does **not**
consume the free book slot, and it never reinstalls once removed. Settings has a button to put it
back.

## Price

One book at a time is free, forever. No time limit, no page limit, no feature held back: the whole
app works on that book. Delete it and add another as often as you like, still free. The bundled
guide does not count towards it.

The unlock is offered at the moment someone reaches for a second book, on the Add button itself,
rather than after they have chosen a file and had it refused.

Keeping several books on the shelf at once is a single non-consumable purchase. Not a subscription,
because the app costs nothing to run: no server, no account, no network calls of our own, so there is
nothing to rent. `Core/Store.swift` is the whole of it.

The gate lives in one place, `Library.importPDF(from:)`, because the file importer, drag and drop
and Open With all funnel through it, and gating at the call sites would let a multi-file selection
slip several books past a one-book limit. Someone who already has several books keeps all of them
even if they are not entitled, for instance after a refund: only adding another is blocked. Taking
books off a reader who is halfway through one would be hostile.

### Testing the purchase

`Engrossed.storekit` holds a local StoreKit configuration, attached to the shared scheme, so the
product exists before it exists in App Store Connect. It only applies when the app is launched
from Xcode: running the app any other way shows the paywall's offline state, which is itself worth
looking at. Real sandbox testing needs a Sandbox Apple Account from App Store Connect.

## Roadmap

Nothing here is finished, and some of it may not happen.

- **A voice that reads along with you.** Not a separate audiobook: the same card, spoken, with the
  sentence you are hearing lit up as it goes. Reading and hearing the same words together is a
  common way to keep attention from sliding off the page.
- **A real recap at the end of a stretch.** Today "Remind me" shows the opening words of each card.
  It could be a proper summary of what you read. It would stay behind that button rather than
  appearing automatically: having a go at recalling it first is the part that makes the checkpoint
  work, and a summary handed to you up front quietly removes it. This is also the first feature
  with a real per-user cost, which is what would justify a subscription tier.
- **EPUB, web pages and papers.** Drop in an EPUB, paste a link to an article or an arXiv page, and
  get the same cards. Reflowable formats are easier than PDF, with no layout to reverse-engineer.
- **Search.** Find a phrase inside a book and jump to that card, or search the whole shelf for the
  thing you half remember reading.
- **Import from anywhere.** The share sheet on iPhone, Open With on the Mac, and a watched folder.
- **Noticing when you have drifted.** The front camera can tell roughly whether you are looking at
  the screen. That is enough to pause a moving card when you look away, but nowhere near enough to
  know which word you are on. Per-word gaze highlighting is not honest on a phone, so it is not
  planned. See the evidence table above.

## EPUB

EPUB turns out to be much kinder than PDF: it is a ZIP of XHTML, so paragraphs are marked up
rather than inferred from ink on a page. There is no geometry to reverse-engineer, no hyphens to
heal, no running heads to strip. A "page" is one spine document, usually a chapter, which keeps
the contents list and the saved position working unchanged.

Foundation has no ZIP reader, so `Core/ZipArchive.swift` is a small bounds-checked one: find the
central directory, inflate entries with the Compression framework. `Core/EPUBExtractor.swift`
reads the package document for reading order and metadata, and either the EPUB 3 nav document or
the EPUB 2 NCX for contents. The markup is stripped by hand rather than XML-parsed, because real
EPUB content is only approximately well formed and a strict parser refuses whole chapters over a
stray attribute.

Measured on four Project Gutenberg books: **0.0% to 0.3%** of cards cut mid-sentence.

## Tested against

21 documents, every one asserted for contiguous card ids, sections covering every card, and a
contents list that is in range and never runs backwards.

| Document | Cards | Contents | Cut mid-sentence |
| --- | --- | --- | --- |
| Think Python, 244pp | 3,043 | 240 | 0.5% |
| SICP, 883pp | 5,817 | 140 | 7.9% |
| Euclid, 228pp | 3,595 | 150 | 2.2% |
| Higgs discovery paper, two-column | 793 | 31 | 3.6% |
| Attention Is All You Need | 194 | 22 | 4.7% |
| Bitcoin whitepaper | 115 | 11 | 0.0% |
| Pride and Prejudice (EPUB) | 3,333 | 63 | 0.3% |
| Frankenstein (EPUB) | 1,688 | 32 | 0.1% |
| Sherlock Holmes (EPUB) | 3,123 | 18 | 0.0% |
| Japanese, Chinese and Korean | 24 | - | 12.5% |

The percentages count any prose card not ending in punctuation, so they overstate the problem:
in Think Python only 11 of 64 are genuine sentence cuts, the rest end in code or a URL, which
have no punctuation to end with. SICP is roughly 40% Scheme.

### Telling a heading from a line that is merely tall

Chapter titles have to be found, or a book with no PDF outline has no contents list and every
chapter starts welded onto its first sentence. The only signal in the geometry is that a title is
set in a larger font, and the only way to measure a font from glyph boxes is to compare a line's
letters against the body's. Two measurements looked right and are not:

The line's own box is the union of its glyphs, so it reaches full height only when something on it
has a descender. "Properties of Water" measures 25% taller than "Water Is Cohesive" in the same
font, purely because of the "p" — a bigger difference than the one between a heading and body text.
The tallest glyph fails too, because brackets are drawn taller than any letter, so an ordinary
sentence with a citation in it reads as a title.

The modal glyph height is immune to both, and is what the extractor uses. But it is x-height only
while lowercase letters are the majority: on a line of code, capitals or display algebra the mode
rises to cap height in the very same font. That was measured across the corpus as a **55%
false-positive rate**, and a false heading is worse than a missed one, because it forces a
paragraph break and so cuts a sentence in half — 182 of them did.

What separates the two populations is that a line set in a larger font has *no* body-sized letters
left on it, while a line that merely contains something tall keeps plenty. Requiring under 15% of a
line's glyphs to be body-sized, plus a letter-density floor and a capitalised first letter, took
SICP's headings from 705 to 509 and its mid-sentence cuts from 8.1% back to 7.9%, which is the rate
it had before headings were detected at all.

### Books that number themselves in roman

Euclid's Elements has no PDF outline, and its 7 books and 197 propositions are labelled "BOOK IV."
and "PROP. XLVII.—Theorem." The contents builder read arabic digits only, so every one of them was
invisible and the list fell back to scraping whatever else looked like a heading: 150 entries of
which 35 were structural and 37 contained an equals sign.

Reading a labelled roman numeral fixes that, but only with three guards, each of which was added
after it broke something measurable. Depth comes from **containment** — whether the inner label's
numbering actually restarts under the outer one — and not from which label is rarer, because a
novel with four plates and sixteen chapters nests every chapter under a plate caption. The pass
must carry at least a quarter of the document's headings before it may displace the general scrape,
because four "Fig. I." captions in a report otherwise replace its twenty real section titles. And
the 150-entry cap thins the deepest level first, so trimming a long list costs propositions rather
than whole books.

Euclid's contents list is now 150 entries, all of them structural: 7 books at their real openings
and 143 propositions nested under them.

### Where the page number lives

A fixed fraction of the page height is not enough to find the running furniture: books set their
folios at very different distances from the trim. One 228-page book put 164 page numbers just
inside the band, and every one became a reading card that said, in full, "11". A bare number is
now also treated as furniture when it is simply the topmost or bottommost line on its page,
whatever the margin happens to be. That took those 164 cards to zero and improved the same book's
mid-sentence cuts from 2.8% to 2.2%.

### Languages without spaces

Japanese and Chinese put no spaces between words and end sentences with an ideographic full stop.
Three separate things assumed otherwise: the word counter (so a 164-character card counted as
"7 words" and the chunker kept pouring text in), the prose test (so every page of those languages
was classified as "not prose" and buried in skippable cards), and the line joiner (which inserted
spaces into the middle of words). Fixing the last of these, a selection probe that stopped one
glyph short of the line end, also recovered trailing punctuation in Latin text: the Higgs paper
improved from 4.2% to 3.7% as a side effect.

Handled without crashing, each with its own honest message: a password-protected PDF, a scanned
PDF with no selectable text, a file that is not a PDF at all, a zero-byte EPUB, a truncated
EPUB, a ZIP that is not an EPUB, a blank page between two full ones, a one-sentence document,
and a PDF renamed `.epub` (which opens anyway, because the format is sniffed from the file rather
than trusted from its name).

## Layout

```
Engrossed/
  Models/Book.swift          Book, Chunk, Section, saved position
  Core/TextExtractor.swift   PDF geometry → paragraphs and figure regions
  Core/Chunker.swift         paragraphs → cards, sections, asides
  Core/FigureRenderer.swift  page region → image, cached
  Core/ContentsBuilder.swift outline or nav → contents entries mapped onto cards
  Core/ZipArchive.swift      minimal read-only ZIP, because EPUB is one
  Core/EPUBExtractor.swift   EPUB → the same blocks the chunker takes from a PDF
  Core/EPUBParsing.swift     package document, navigation, and markup to paragraphs
  Core/Store.swift           the one purchase, StoreKit 2
  Core/Library.swift         the shelf, the files, the saved places
  Core/ReadingSettings.swift every preference
  Views/                     reader, modes, checkpoint, contents, figure viewer, paywall, settings
```
