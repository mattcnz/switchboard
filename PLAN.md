# Switchboard

Native macOS keyboard-driven window switcher. Long-term differentiator: project-aware context switching across apps, windows, browser tabs, and saved contexts. Conceptually similar to TabTab and Contexts.

This doc covers the MVP and the architecture it should grow into. Future features are sketched but deliberately out of scope.

## MVP

One milestone, one user-visible feature: **press a hotkey, fuzzy-search open windows, press Enter to focus the chosen window.**

User flow:
1. Launch app. App checks Accessibility permission; if missing, show onboarding with a button to open System Settings and a recheck button.
2. Press `Option+Space` (default). A floating, frosted command palette appears centered on the active screen.
3. Search field is auto-focused. Each row shows app icon, app name, and window title.
4. Typing fuzzy-filters by app name + window title. Arrow keys move selection. `Enter` activates the window. `Esc` closes the palette.

Done means all of the above works without crashing when an app denies AX, the palette doesn't steal app activation while open, and the binary stays local-only (no network, no telemetry).

## Out of scope for MVP
Listed so we don't get pulled in:
- Browser tab search (Chrome/Safari AppleScript adapters)
- Saved contexts / workspaces
- Recency or frequency ranking
- Ignore rules / hidden apps
- Settings UI beyond the permission onboarding
- Launch at login, Sparkle updates, signing/notarization, licensing

## Stack
- **Swift + SwiftUI** for views, **AppKit** for the floating panel and anything SwiftUI can't reach
- **macOS Accessibility (AX) APIs** for window discovery and activation
- **[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)** by Sindre Sorhus for the global hotkey
- Local-only storage (UserDefaults is enough for MVP); no backend, no Electron

## Architecture

Modules are small and single-purpose so a second source (browser tabs, contexts) can plug in without rewrites.

```
App/
  SwitchboardApp.swift          // @main, app lifecycle
  AppCoordinator.swift          // wires hotkey → panel → scanner → activator

UI/
  CommandPaletteView.swift      // SwiftUI search field + result list
  SearchResultRow.swift
  OnboardingView.swift          // AX permission screen

Windowing/
  FloatingPanelController.swift // NSPanel host for the SwiftUI palette
  AccessibilityPermissionManager.swift
  WindowScanner.swift           // [SwitchItem] from AX
  WindowActivator.swift         // focus a SwitchItem

Search/
  SwitchItem.swift              // model
  FuzzySearch.swift             // ranking

Hotkeys/
  HotkeyManager.swift           // KeyboardShortcuts wrapper, toggles panel
```

### Core model

```swift
enum SwitchItemKind { case window, browserTab, context }   // .browserTab / .context unused in MVP

struct SwitchItem: Identifiable, Hashable {
    let id: String              // stable per source; e.g. "win:<pid>:<axHandle>"
    let kind: SwitchItemKind
    let appName: String
    let appBundleID: String?
    let title: String
    let icon: NSImage?
    let pid: pid_t?
    let axWindow: AXUIElement?  // not Hashable; exclude from synthesized impls
}
```

`AXUIElement` is a CFType — wrap or exclude it from `Hashable`/`Equatable` synthesis. Compare by `id`.

### Source protocol (for future tab/context providers)

```swift
protocol SwitchItemSource {
    func snapshot() async -> [SwitchItem]
}
```

`WindowScanner` is the only concrete source for MVP. Browser/context sources land later behind the same protocol.

### Module responsibilities

- **HotkeyManager** — registers `Option+Space` via KeyboardShortcuts, toggles the panel. No other state.
- **FloatingPanelController** — owns an `NSPanel` subclass with `canBecomeKey = true`, `styleMask = [.nonactivatingPanel, .titled, .fullSizeContentView]`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`. Hosts the SwiftUI `CommandPaletteView` via `NSHostingView`. Centers on the screen with the mouse / key window. Hides on Esc, on selection, and on resignKey.
- **AccessibilityPermissionManager** — `AXIsProcessTrusted()` for status checks (no prompt); `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` only when the user clicks the onboarding button. Re-polls when the app becomes active, since macOS does not notify on grant.
- **WindowScanner** — enumerates `NSWorkspace.shared.runningApplications` filtered to `.regular` activation policy, builds `AXUIElementCreateApplication(pid)`, reads `kAXWindowsAttribute`, and per window reads `kAXTitleAttribute`. Drops empty titles and minimized/zero-size windows. Runs off the main thread; returns `[SwitchItem]` to the UI via async/await. Defensive: every AX call's failure is logged and skipped, never thrown.
- **WindowActivator** — `NSRunningApplication(processIdentifier:)?.activate(options: [])` first, then `AXUIElementPerformAction(window, kAXRaiseAction as CFString)`. Closes the panel on success.
- **FuzzySearch** — exact substring matches rank highest, then subsequence matches, then per-app fallbacks. Match against `"\(appName) \(title)"`. Stable ordering when scores tie. Pure function, easy to unit-test.

## macOS footguns (worth pinning down before code)

- **NSPanel focus**: a default `NSPanel` won't accept keyboard input. Subclass and override `canBecomeKey` → `true`. Include `.nonactivatingPanel` in styleMask so showing the panel doesn't deactivate the foreground app — otherwise activation order on `Enter` gets weird.
- **AX trust is stale**: `AXIsProcessTrusted()` does not push a notification when the user grants permission in System Settings. Re-check on `NSApplication.didBecomeActiveNotification` and on a recheck-button tap.
- **AX calls block**: reading `kAXWindowsAttribute` and `kAXTitleAttribute` for many apps can cost 100ms+. Do scans on a background queue, hand results to the UI on main. Cache the last snapshot and refresh on hotkey-press, not on every keystroke.
- **Activation order**: activate the app first, then raise the window. Reversed, focus can land on the wrong window.
- **LSUIElement**: set `LSUIElement = true` in Info.plist so the app has no Dock icon and no menu bar. Global hotkeys still work fine; this does not interfere with KeyboardShortcuts.
- **Empty/system windows**: the AX tree includes invisible helper windows. Filter by non-empty `kAXTitleAttribute`; optionally also require non-zero size via `kAXSizeAttribute`.
- **Hotkey conflicts**: `Option+Space` is unused by macOS by default but some users rebind input sources to it. KeyboardShortcuts surfaces conflicts; make the binding user-configurable from day one even if the settings UI is minimal.

## Implementation sequence

Each step ends with something demoable.

1. **App shell + onboarding** — SwiftUI `@main`, `LSUIElement = true`, an onboarding view gated by `AXIsProcessTrusted()`. Demo: launch app, see the onboarding screen, click through to System Settings.
2. **Floating panel** — `FloatingPanelController` shows an empty palette on a temporary menu-bar item click. Demo: panel floats above other apps, accepts text input, dismisses on Esc.
3. **Window scanner** — `WindowScanner.snapshot()` returns `[SwitchItem]`, wired to populate the palette list. Demo: open palette, see a list of every window on the system.
4. **Fuzzy search** — `FuzzySearch.rank(items, query:)` filters as you type. Demo: filter narrows visibly with sensible ordering.
5. **Window activator** — Enter focuses the selected window and closes the palette. Demo: full keyboard flow works end-to-end.
6. **Global hotkey** — KeyboardShortcuts replaces the menu-bar trigger with `Option+Space`. Demo: hotkey toggles the palette from anywhere.
7. **Polish** — defensive AX error handling, app icons in rows, frosted material background, focus states. Tests for `FuzzySearch` ranking.

## Acceptance criteria
- Builds in Xcode with no warnings beyond unavoidable AX/CF bridging.
- AX permission status is detected correctly in all three states (granted, denied, never asked).
- `Option+Space` opens a centered, focusable, frosted palette above any app, including full-screen apps.
- Palette lists windows from other regular apps; empty/system windows are filtered.
- Typing filters; arrows move selection; Enter focuses the right window; Esc closes.
- App does not crash when an app denies AX or returns errors mid-scan.
- No network calls. No data leaves the machine.

## Design direction
Premium native Mac utility, not a SaaS dashboard. Frosted/translucent panel, large rounded corners, generous padding, single accent color for selection. Strong keyboard focus state on the selected row. App icons rendered at native resolution. No empty states beyond a short "No matches" line. No onboarding past the permission screen.

## Future direction (sketch only)
- Browser tabs via AppleScript adapters (Chrome, Safari, Brave, Edge)
- AX-based adapters for VS Code, Finder, Figma, Notion (project / document level)
- Saved contexts: capture set of windows/tabs, name it, reopen later
- Recency + frequency ranking
- Ignore rules
- Launch at login, Sparkle updates, Developer ID signing, paid Pro tier
