# Switchboard

A fast, keyboard-driven window switcher for macOS. Press a hotkey, fuzzy-search across every open window and browser tab, hit Enter to jump straight to it

## Features

- **Universal search** — fuzzy-matches by app name and window title across all your open windows
- **Browser tab search** — searches Chrome and Safari tabs alongside windows, and jumps straight to the matching tab
- **Terminal tab search** — same for Terminal.app tabs
- **Live window previews** — see a thumbnail of each window before you switch
- **Recency-aware ranking** — windows and tabs you actually use rise to the top over time
- **Global hotkey** — `Option + Space` by default, rebindable in Settings

## Privacy

Switchboard makes no network calls. There is no telemetry, no analytics, no update-checker phoning home — the binary is entirely local-only. Everything it reads (window titles, tab titles, tab URLs) stays on your machine and is used only to build the search index in memory.

## Permissions

Switchboard asks for a few macOS permissions on first launch. Each one maps to a specific feature — you can decline any of them and the rest of the app still works:

| Permission | Why |
|---|---|
| **Accessibility** | Lists your open windows and focuses the one you pick |
| **Automation** (Apple Events) | Reads and switches tabs in Chrome, Safari, and Terminal |
| **Screen Recording** | Generates the live window preview thumbnails |

## Installation

1. Download the latest `Switchboard.dmg` from [Releases](../../releases)
2. Open the DMG and drag Switchboard into `/Applications`
3. Launch it — since it's a menu-bar-less background app (`LSUIElement`), it won't show a Dock icon or window on its own
4. Grant permissions when prompted
5. Press `Option + Space` to open the palette

Switchboard is signed with a Developer ID certificate and notarized by Apple, so Gatekeeper should let it run without extra steps.

## Building from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
make run     # generates the Xcode project, builds Debug, launches it
make build   # build only
make logs    # stream the app's unified-logging output
```

Release builds (Developer ID signing, notarization, DMG packaging) are also driven by the `Makefile`, but require your own Developer ID certificate and notarization credentials — see the comments in [`Makefile`](Makefile).

## Stack

Swift + SwiftUI + AppKit, targeting macOS 14+. The only external dependency is [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus (MIT licensed) for global hotkey registration.

## License

MIT — see [LICENSE](LICENSE).
