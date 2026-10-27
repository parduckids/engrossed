# App Store listing

Everything here is a draft to paste into App Store Connect. Character limits are Apple's.

> **Check the name first.** Search the App Store for "Engrossed" before you commit to it. App
> names are first come, first served, and you reserve it by creating the app record in App Store
> Connect. If it is taken, "Engrossed Reader" is the obvious fallback.

---

## Name (30 max)

```
Engrossed
```

## Subtitle (30 max)

```
Books, one card at a time
```

Alternatives, all within 30: `One card at a time` · `PDFs without the wall of text` · `A calmer way to read PDFs`

## Promotional text (170 max, editable any time without review)

```
A page of text gives your eyes a hundred places to land. Engrossed gives them one. Your place is kept exactly, even if you close it mid-sentence.
```

## Keywords (100 max, comma separated, no spaces after commas)

```
pdf,epub,reader,focus,adhd,attention,reading,study,textbook,dyslexia,neurodivergent,calm,ebook
```

That is 93 characters. Do not repeat words already in the name or subtitle, Apple indexes those
separately. Do not put competitor names in here, Apple rejects for it.

## Description (4000 max)

```
A page full of text gives your eyes a hundred places to land. Engrossed gives them one.

Open a PDF or an EPUB and it is cut into cards: two or three whole sentences, alone on the screen, with
nothing else competing for your attention. Close the app in the middle of a sentence and it
reopens on that exact card.

Built for people who lose the thread on a full page. If you have ever read the same paragraph
four times, or opened a 200 page document and closed it again immediately, this is for you.


WHAT IT DOES

Cards. Text is cut at sentence boundaries, never mid-thought. A card you can finish is a
completely different thing from a page you cannot.

Keeps your place, exactly. Close it anywhere. It reopens on that card and steps back one, so you
land inside the thought instead of at a cold edge.

Three ways to read. Cards, one at a time. Flow, continuous text with everything but your current
spot dimmed. Pace, a word at a time at a speed you set.

Checkpoints. At the end of each stretch it asks what you just read. If nothing comes to mind,
that is worth knowing now rather than twenty pages later.

Sprints. A bounded session with a visible end, and a real break when it finishes.

Chapters and pages. Jump to any chapter. In a PDF you can also jump to a page by the number
printed on it.

Figures you can see. In a PDF, diagrams and charts are pulled out of the document and redrawn
sharp when you zoom in, so the small print in a figure is actually readable.

Typography that follows accessibility guidance: line length, line spacing, four themes, four
typefaces, and text size you control.

Read aloud, if a second channel helps you hold on.


HONEST ABOUT WHAT WORKS

Most reading apps promise to double your speed. This one tells you which of its features have
evidence behind them and which do not, in the settings, next to the switch.

Cutting text into sentence sized pieces, asking you to recall what you read, and sensible line
length and spacing are all supported. Word at a time reading only holds up to about 350 words a
minute, so the slider stops there, and the passage stays on screen so you can always look back.
Bolding the starts of words is included because some people like how it looks, and the app says
plainly that controlled tests found no benefit.


PRIVACY

No account. No sign up. No servers of our own. No analytics. No adverts. The only thing the app
talks to is Apple's App Store, and only for the one-time purchase. Your books and your places
never leave your device.


PRICE

One book at a time is free, forever. Finish it, delete it, add another, still free.
If you want a shelf with several books on it at once, that is a single payment. Once. Yours.
No subscription.


Reads PDF and EPUB. Works on iPhone, iPad and Mac.
```

## What's New (4000 max, version 1.0)

```
First release.
```

---

## App Store Connect settings

| Field | Value |
| --- | --- |
| Primary category | Productivity |
| Secondary category | Education |
| Age rating | 4+ |
| Price | Free, with one In-App Purchase |
| In-App Purchase | Non-consumable, "Full shelf", 4.99 (Tier 5), **Family Sharing ON** |
| Content rights | Contains no third-party content |
| Copyright | 2026 Adam Vörös |
| Bundle ID | `com.lowshelf.engrossed` (permanent once shipped) |
| IAP product ID | `com.lowshelf.engrossed.fullshelf` (permanent once sold) |

> **Family Sharing must be switched on when you first submit the purchase.** The paywall promises
> it in writing, and `Engrossed.storekit` sets `familyShareable` for local testing, but the real
> setting lives only in App Store Connect. Turning it on later is allowed but is **not retroactive**
> for anyone who bought before the change.

### Privacy nutrition label

Answer **"No, we do not collect data from this app."** to the first question, which ends the
questionnaire. This is true: the app collects nothing and has no servers of its own. Its only
network use is StoreKit, for the one-time purchase, and data Apple collects through StoreKit is
Apple's to declare, not yours. Do not let a third-party SDK creep in later without revisiting
this, it is a legal declaration.

A privacy policy URL is required even when you collect nothing. `store/PRIVACY.md` is the text.
Host it anywhere public (a GitHub Pages page or a Gist is fine) and paste the URL in.

### Notes for App Review

```
Engrossed reads PDF and EPUB files that the user imports from their own device. It requires no
account. The only network activity is StoreKit, for the one-time purchase.

On first launch the app installs a short bundled guide and opens it, so the reader is visible
immediately with no setup. Tap, or press space, to advance a card.

To test with your own file: tap the + on the shelf and choose any PDF or EPUB from Files. The
document is copied into the app and cut into cards.

Password-protected PDFs, scanned PDFs with no selectable text, and damaged files are all
detected and explained rather than failing silently.

In-App Purchase: one book at a time is free with no limit on time, pages or features. The
purchase ("Full shelf", non-consumable, family shareable) removes the one-book-at-a-time limit.
Deleting a book and importing a different one is always free and unlimited. The bundled guide
does not count towards the limit.
```

---

## Screenshots

Required: 6.9" iPhone and 13" iPad. Apple will reuse the iPhone set for smaller sizes.
Up to 10 each. Good order, most important first:

1. A card in the reader, Paper theme. The core idea in one image.
2. The checkpoint. "In one line, what was that about?"
3. Contents, showing chapters.
4. A figure, zoomed and sharp.
5. Settings, showing the honest evidence notes. This is the differentiator.
6. The shelf.
7. Night theme.

Take them with the simulator at the exact required sizes:

```bash
xcrun simctl io "iPhone 17 Pro Max" screenshot --type=png shot.png
```

Add a short caption above each in a plain layout. Do not clutter them.

## Mac App Store

Same app record, separate submission. macOS builds need notarisation if you ever distribute
outside the store. The Mac build is already sandboxed with read-only access to user-selected
files, which is the minimum entitlement and the easiest to get approved.
