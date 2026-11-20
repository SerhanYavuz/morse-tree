# Morse Tree

Learn Morse code as a tree: every letter is a path from the antenna. Go right for a dot,
left for a dash, and read the path to get the code.

- App Store: *Morse Tree: Learn Morse Code* (iPhone, iPad, Mac)
- Try it in your browser: https://ta2syw.com/morsetree/app/
- Website, privacy policy and support: https://ta2syw.com/morsetree/

## Features

- Learn on the tree: tap a letter to hear it and watch its path light up
- Key with one key (tap · / hold −), two paddles, or on a Mac with left click · / right click −
- Quizzes for letters, numbers, words and Q codes, with a per-letter heat map
- Practise any text at correct Morse spacing
- Glossary of Q codes, prosigns, abbreviations and RST reports
- Radio mode: Morse and push-to-talk voice to nearby phones over Bluetooth, no internet

## Layout

| Path | What it is |
|---|---|
| `App/Web/index.html` | The whole UI: tree, keyer, quizzes, glossary (HTML, CSS, JS in one file) |
| `App/MorseTreeApp.swift` | SwiftUI shell hosting the page in a `WKWebView`, haptics, storage, right-click keying on Mac |
| `App/Radio.swift` | Bluetooth LE radio mode |
| `App/Voice.swift` | Push-to-talk audio, compressed with Codec2 700C |
| `Vendor/codec2/` | The Codec2 files the app compiles (LGPL-2.1) |
| `project.yml` | XcodeGen spec; `MorseTree.xcodeproj` is generated from it |

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open MorseTree.xcodeproj
```

Set your own development team in `project.yml` (`DEVELOPMENT_TEAM`) before building for a device.

The web version runs as-is: open `App/Web/index.html` in a browser (radio mode needs the native app).

Screenshot mode for App Store images: launch with `-shot learn|key|quiz|gloss|text|radio`.

## Licence

Morse Tree's own code is MIT licensed (see `LICENSE`).

Push-to-talk uses [Codec2](https://github.com/drowe67/codec2) by David Rowe and contributors,
licensed under the GNU LGPL 2.1 (`Vendor/codec2/COPYING`). Its source is included in
`Vendor/codec2/`, so you can modify Codec2 and rebuild the app with your version using the steps above.

73 de TA2SYW
