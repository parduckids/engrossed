# App Store listing

Everything here is a draft to paste into App Store Connect. Character limits are Apple's.

> **Reserve the name first.** App names are first come, first served, and you reserve one by
> creating the app record in App Store Connect. "Reader" is in the name on purpose: there is an
> unrelated focus-timer app called "Engross", and the name makes clear this is a different kind
> of app. Keep "Engross", "focus timer", "Pomodoro" and "to-do" out of the name, subtitle and
> keywords. The home screen still just says "Engrossed".

---

## Name (30 max)

```
Engrossed: PDF & EPUB Reader
```

28 characters.

## Subtitle (30 max)

```
Read without losing focus
```

Same line as the Chrome extension, so the two read as one product. Alternatives, all within 30:
`A few sentences at a time` · `PDFs without the wall of text` · `A calmer way to read PDFs`

## Promotional text (170 max, editable any time without review)

```
A page of text gives your eyes a hundred places to land. Engrossed gives them one. Your place is kept exactly, even if you close it mid-sentence.
```

## Keywords (100 max, comma separated, no spaces after commas)

```
adhd,autism,attention,reading,study,textbook,dyslexia,neurodivergent,calm,ebook,books,papers
```

That is 92 characters. "pdf", "epub" and "reader" are left out because the name has them, and "focus" because the subtitle does. Do not repeat words already in the name or subtitle, Apple indexes those
separately. Do not put competitor names in here, Apple rejects for it.

## Description (4000 max)

```
A page full of text gives your eyes a hundred places to land. Engrossed gives them one.

Open a PDF or an EPUB and it shows you two or three whole sentences at a time, alone on the
screen, with nothing else competing for your attention. Close the app in the middle of a sentence
and it reopens at that exact spot.

Built for people who lose the thread on a full page. If you have ever read the same paragraph
four times, or opened a 200 page document and closed it again immediately, this is for you.


WHAT IT DOES

A few sentences at a time. Text is cut at sentence boundaries, never mid-thought. A few lines
you can finish are a completely different thing from a page you cannot.

Keeps your place, exactly. Close it anywhere. It reopens there and steps back a little, so you
land inside the thought instead of at a cold edge.

Three ways to read. Cards, a few sentences at a time. Flow, continuous text with everything but your current
spot dimmed. Pace, a word at a time at a speed you set.

Check-ins. At the end of each part it asks what you just read, about that section by name when
it can. If nothing comes to mind, that is worth knowing now rather than twenty pages later, and
"Remind me" shows how each paragraph began.

Sprints. A bounded session with a visible end, and a real break when it finishes.

Chapters and pages. Jump to any chapter. In a PDF you can also jump to a page by the number
printed on it.

Figures you can see. In a PDF, diagrams and charts are pulled out of the document and redrawn
sharp when you zoom in, so the small print in a figure is actually readable.

Typography that follows accessibility guidance: line length, line spacing, four themes, four
typefaces, and text size you control.

Read aloud, if a second channel helps you hold on. It uses your device's own voices, or
ElevenLabs voices if you have an ElevenLabs account and paste in your own key.


HONEST ABOUT WHAT WORKS

Most reading apps promise to double your speed. This one tells you which of its features have
evidence behind them and which do not, in the settings, next to the switch.

Cutting text into sentence sized pieces, asking you to recall what you read, and sensible line
length and spacing are all supported. Word at a time reading only holds up to about 350 words a
minute, so the slider stops there, and the passage stays on screen so you can always look back.
Bolding the starts of words is included because some people like how it looks, and the app says
plainly that controlled tests found no benefit.


PRIVACY

No account. No sign up. No servers of our own. No analytics. No adverts. Your books and your
places never leave your device. The app talks to Apple's App Store for the one-time purchase,
and to ElevenLabs only if you choose to add your own ElevenLabs key, and then only the few
sentences being read aloud.


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
questionnaire. This is true: the app collects nothing and has no servers of its own.

- StoreKit, for the one-time purchase: data Apple collects through StoreKit is Apple's to
  declare, not yours.
- ElevenLabs: Apple counts data as collected when it reaches you or a partner whose code you put
  in the app. ElevenLabs is neither. There is no ElevenLabs SDK in the app, it is off unless the
  reader pastes in their own key, and the text goes to the reader's own ElevenLabs account under
  their own agreement with ElevenLabs. You never receive it. The privacy policy says all this.

If you would rather over-declare than argue it, the honest alternative is: User Content, Other
User Content, not linked to the user, not used for tracking, purpose App Functionality. Either
way, do not let a third-party SDK creep in later without revisiting this. It is a legal
declaration, and `Engrossed/PrivacyInfo.xcprivacy` says the same thing inside the app.

| URL field | Value |
| --- | --- |
| Privacy Policy URL | `https://parduckids.github.io/engrossed/privacy/app.html` |
| Support URL | `https://parduckids.github.io/engrossed/` |
| Marketing URL (optional) | leave empty, or the support URL |

### Notes for App Review

```
Engrossed reads PDF and EPUB files that the user imports from their own device. It requires no
account. Network activity is StoreKit, for the one-time purchase, and one optional feature
described at the end.

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

Optional ElevenLabs voices: Settings > Read aloud has a field where a user can paste their own
ElevenLabs API key to use two ElevenLabs voices instead of the built-in system voices. It is off
by default and not needed for anything. Nothing is sold or unlocked through it: the user pays
ElevenLabs directly under their own ElevenLabs account, and the app takes no part in that. With
no key, read aloud uses the system's built-in voices.

Settings > Also for Chrome links to a page about our free Chrome browser extension, for reading
web articles on a computer. It is not a purchase and unlocks nothing in the app.
```

---

## Screenshots

Required: 6.9" iPhone (1320 x 2868) and 13" iPad (2064 x 2752). Apple scales these down for the
smaller sizes. The Mac version needs its own set: 2880 x 1800 is the safest size.
Up to 10 each. Good order, most important first:

1. A card in the reader, Paper theme. The core idea in one image.
2. The checkpoint. "In one line, what was that about?"
3. Contents, showing chapters.
4. A figure, zoomed and sharp.
5. Settings, showing the honest evidence notes. This is the differentiator.
6. The shelf.
7. Night theme.

The iPhone 17 Pro Max and iPad Pro 13-inch (M5) simulators produce exactly those sizes:

```bash
xcrun simctl io "iPhone 17 Pro Max" screenshot --type=png shot.png
```

Add a short caption above each in a plain layout. Do not clutter them.

## Mac App Store

Same app record, separate submission. macOS builds need notarisation if you ever distribute
outside the store. The Mac build is already sandboxed with read-only access to user-selected
files, which is the minimum entitlement and the easiest to get approved.
