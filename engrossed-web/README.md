# Engrossed for the web

A Chrome extension that turns any article into small reading cards: one or two
whole sentences at a time, nothing else on screen, and your place saved per
article.

It is the reading experience of the [Engrossed](../Engrossed) iOS and macOS app,
pointed at the web instead of at books. Separate codebase, same rules.

## Install it (unpacked)

1. Open `chrome://extensions`
2. Turn on **Developer mode** (top right)
3. **Load unpacked**, and choose this folder
4. Open any article and click the toolbar button, or press `⌘⇧E`

`Esc` closes it. Click the card or press `Space` to go on, `←` to go back.

## How it works

| | |
|---|---|
| `src/background.js` | service worker; the toolbar click injects the reader, and it makes the ElevenLabs requests |
| `src/reader/extract.js` | page → typed blocks, via Mozilla Readability |
| `src/reader/chunker.js` | blocks → cards. **A port of the app's `Chunker.swift`** |
| `src/reader/position.js` | your place, per article |
| `src/reader/main.js` | the overlay: cards, flow, settings |
| `src/reader/eleven-speech.js` | plays a card in an ElevenLabs voice; never holds the key |
| `src/eleven.js` | ElevenLabs request, the two voice ids, error messages |
| `src/keystore.js` | the ElevenLabs key, in the extension's own IndexedDB |
| `src/options.html` | where an ElevenLabs key is pasted or removed |
| `vendor/readability.js` | Mozilla Readability, Apache-2.0, unmodified |

The hard part of the app did not need porting. `TextExtractor.swift` is ~700
lines of glyph geometry, font-size heading detection and mirrored page margins,
and it exists only because a PDF has no structure. A web page already says `<p>`
and `<h2>`. What did need porting is the chunker, which is pure string logic.

### Permissions

`activeTab`, `storage`, `scripting` — and no host permissions, so Chrome shows
**no install warning at all**. Nothing runs on any page until you click the
button. Nothing derived from page content is ever written to `storage.sync`,
which is the store that leaves the device; positions and titles are local only.

### Two things that differ from the app, deliberately

**Sentence segmentation.** The app uses Apple's `NLTokenizer`. The web has
`Intl.Segmenter`, which handles Japanese and Chinese identically — it splits on
`。` and never on `、` — but mis-splits English abbreviations, stranding `Dr.` as
its own sentence and turning `J. R. R. Tolkien` into four. Measured: 3 of 10
ordinary sentences. A stranded `Dr.` is a card that ends mid-sentence, so
`chunker.js` adds a merge pass the Swift version does not need. Measured at
10 of 10 after the fix.

**Position anchoring.** The app re-anchors a saved place within ±1 PDF page,
because a 40-character prefix is not unique in a book. The web has no pages, so
every chunk carries the ordinal and a hash of the paragraph it came from.
Anchoring on the paragraph rather than the card index means changing card size
is exact rather than approximate, and a position survives the site inserting a
correction above what you were reading.

## Tests

```bash
npm test
```

20 tests over the chunker and the full extract-to-cards pipeline, modelled on
the app's 23-document corpus discipline. The invariants:

- **a card boundary always falls on a sentence boundary** (the one promise)
- no card ends on a stranded abbreviation or initial
- code blocks and tables never become prose cards
- chunk ids contiguous; sections cover every chunk with no gap or overlap
- Japanese splits on `。`, never on `、`
- changing card size lands you on the same paragraph
- a saved place survives a paragraph being inserted above it

`jsdom` is a test-only dependency. Nothing is bundled; the extension ships as
plain ES modules.

## What it does

- **Cards** and **Flow**, matching the app. In Flow, scrolling saves your place.
- **Checkpoints**: at the end of each stretch, "In one line, what was that about?"
  Only on articles with three stretches or more; on a short piece it is friction.
- **Rewind on resume**: coming back backs up one card so you land in context. The
  real place is what gets saved, so a visit never quietly costs you a card.
- **Sprints**: a countdown in the top bar (click to pause), then a break. A sprint
  carries over to the next article within ten minutes, since on the web people
  hop between short pieces and the break would otherwise never come.
- **Contents**: jump to any section of a long article, nested by heading level.
- **Read aloud**: Chrome's built-in voices, a sentence at a time, moving on by
  itself. The automatic voice is always an on-device one; online voices send
  text to Google and are labelled as such.
- **ElevenLabs voices (optional)**: paste your own ElevenLabs API key on the
  options page and choose Woman or Man. The key is kept in the extension's own
  IndexedDB, never in `chrome.storage` (the reader on the page can read that)
  and never synced; only the service worker reads it. If ElevenLabs fails, that
  card is read with the built-in voice and so is the rest of the session.
- Four themes, four fonts, three card sizes, fixation bolding.

## Not in this version

Pace mode (RSVP), a shelf listing the articles you have read, and figure zoom.
None of them change the architecture.
