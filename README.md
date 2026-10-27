# Engrossed

Read long texts without losing focus: a few sentences at a time, with your place saved.

| Folder | What it is |
|---|---|
| [`Engrossed/`](Engrossed/) | The iPhone, iPad and Mac app (SwiftUI). Open `Engrossed/Engrossed.xcodeproj`. |
| [`engrossed-web/`](engrossed-web/) | The Chrome extension (Manifest V3). See its README to load and test it. |
| [`docs/`](docs/) | The public web pages, published with GitHub Pages: privacy policies and support. |

Only `docs/` is public. The rest of the repository is private.

## Building

The app needs Xcode. On this machine `xcode-select` points at the Command Line Tools,
so command-line builds need:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The extension has no build step. `npm test` runs its tests and `npm run package` makes the
Chrome Web Store zip in `engrossed-web/dist/`.
