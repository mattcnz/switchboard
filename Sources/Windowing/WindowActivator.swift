import AppKit

@MainActor
struct WindowActivator {
    func activate(_ item: SwitchItem) {
        RecentsStore.markActivated(item.recencyKey)

        switch item.kind {
        case .window:
            activateWindow(item)
        case .browserTab:
            activateBrowserTab(item)
        case .context:
            break
        }
    }

    private func activateWindow(_ item: SwitchItem) {
        guard let pid = item.pid else { return }
        if let window = item.axWindow {
            // Restore from the Dock first — raising a minimized window is a no-op.
            var minimizedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
               (minimizedRef as? Bool) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    private func activateBrowserTab(_ item: SwitchItem) {
        let parts = item.id.split(separator: ":")
        guard parts.count >= 4,
              let windowID = Int(parts[2]),
              let tabIndex = Int(parts[3]) else {
            return
        }

        let activated: Bool
        switch String(parts[1]) {
        case "chrome":
            let tabID = parts.count >= 5 ? Int(parts[4]) : nil
            activated = ChromeTabSource.activate(
                tabID: tabID, windowID: windowID, tabIndex: tabIndex, tabTitle: item.title
            )
        case "safari":
            activated = SafariTabSource.activate(windowID: windowID, tabIndex: tabIndex)
        case "terminal":
            let tty = parts.count >= 5 ? String(parts[4]) : nil
            activated = TerminalTabSource.activate(tty: tty, windowID: windowID, tabIndex: tabIndex)
        default:
            return
        }

        if !activated {
            // Palette is already closed; a beep is the honest cheap signal
            // that the tab is gone rather than silently doing nothing.
            NSSound.beep()
        }
    }
}
