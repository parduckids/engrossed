# Chrome Web Store listing

Everything here is ready to paste into the Developer Dashboard. Limits are the store's.

---

## Store listing tab

### Name
```
Engrossed
```
Comes from `manifest.json`. Search the store for "Engrossed" first; if it is taken,
"Engrossed Reader" is the fallback, and the manifest `name` must change to match.

### Summary (132 max)
```
Shows long articles a few sentences at a time, so you stay focused and never lose your place.
```
93 characters. This also comes from the manifest `description`, so the two always agree.

Lead with what it does in plain words. "Card" is the app's word for a few sentences on screen, and
a stranger reading the store page has no reason to know that, so it doesn't appear until the
description has explained it.

### Description
```
Long articles are hard to stay with. Your eyes drift, you lose your place, and you end up reading the same paragraph three times.

Engrossed shows an article a few sentences at a time, with nothing else on the screen. Read them, click or press Space, and the next few appear. It never cuts a sentence in half, so you are never holding half a thought.

Close it whenever you like. Your place is saved for every article, so tomorrow you carry on from the same sentence.

Made for anyone whose mind wanders while reading, including people with ADHD and autistic readers.

WHAT IT DOES
• A few sentences at a time, with the last words of the previous ones faded above, so you never lose the thread.
• Or the whole article as one page, with everything except the part you're reading dimmed.
• Every few minutes, a moment to say in one line what you just read. If nothing comes, you know to reread it now rather than twenty pages later.
• An optional reading timer, then a reminder to take a break.
• A list of the article's sections, to jump straight to the one you want.
• Read aloud with the voices built into Chrome, which carries on by itself. You can also paste your own ElevenLabs key for more natural voices.
• Code, tables and reference lists are set aside to skim instead of being read out sentence by sentence.
• Light and dark themes, four fonts, and adjustable text size, spacing and line width.

PRIVATE BY DESIGN
Engrossed only runs when you click its button, and only on that tab. It has no account, no servers and no analytics, and your reading positions stay on your computer. Chrome shows no "read your data on all websites" warning when you install it, because it doesn't ask for that.

Works on blog posts, news, documentation and Wikipedia. Chrome doesn't allow extensions on its own pages or in its PDF viewer. For PDFs and ebooks, an Engrossed app for iPhone, iPad and Mac is coming soon.
```

### Category
**Accessibility** (under "Make Chrome Yours"). "Education" is the alternative.

### Language
English

### Graphics
| Asset | Size | File |
|---|---|---|
| Store icon | 128 × 128 | `icons/icon128.png` |
| Screenshots (1 to 5) | 1280 × 800 | `store/screenshot-*.png` |
| Small promo tile | 440 × 280 | `store/promo-440x280.png` |
| Marquee (optional) | 1400 × 560 | `store/marquee-1400x560.png` |

---

## Privacy practices tab

### Single purpose
```
Engrossed shows the article on the current tab a few sentences at a time, so it is easier to stay focused, and remembers the reader's place in it.
```

### Permission justifications

**activeTab**
```
Reads the article on the tab where the user clicks the Engrossed button, so it can be shown a few sentences at a time. It has no access to any other tab, and none until the button is clicked.
```

**scripting**
```
Shows the reader on that tab after the user clicks the button. Nothing is injected into any page until then.
```

**storage**
```
Saves the reader's place in each article and their reading preferences on their own computer.
```

**Host permissions**: none requested.

### Remote code
**No, I am not using remote code.** Every script ships inside the package, including Mozilla
Readability, which is vendored in `vendor/`.

### Data usage

Tick these two, and only these two:

- **Website content**: only when the user chooses an ElevenLabs voice. The few sentences
  being read aloud is then sent to ElevenLabs, using the user's own key, to be turned into speech.
- **Authentication information**: the user's own ElevenLabs API key, if they add one. It is stored
  on their computer and sent only to ElevenLabs, as part of each request.

Without an ElevenLabs key nothing leaves the computer at all, but the form is about what the
extension *can* do, so both must be declared. Under-declaring is the thing reviewers reject for.

Then tick all three certifications:
- I do not sell or transfer user data to third parties outside the approved use cases
- I do not use or transfer user data for purposes unrelated to my item's single purpose
- I do not use or transfer user data to determine creditworthiness or for lending purposes

### Privacy policy URL
Host `store/privacy.html` somewhere public and paste its address. Fill in the contact line first.

---

## Distribution tab

Start **Unlisted**: only people with the link can install it. Try it with a few people,
then switch to **Public**. Changing visibility later does not need a new review.
