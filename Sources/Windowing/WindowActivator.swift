import AppKit

@MainActor
struct WindowActivator {
    func activate(_ item: SwitchItem) {
        RecentsStore.markActivated(item.id)

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
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        if let window = item.axWindow {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    private func activateBrowserTab(_ item: SwitchItem) {
        let parts = item.id.split(separator: ":")
        guard parts.count >= 4,
              let windowID = Int(parts[2]) else {
            return
        }

        switch String(parts[1]) {
        case "chrome":
            guard let tabIndex = Int(parts[3]) else { return }
            let tabID = parts.count >= 5 ? Int(parts[4]) : nil
            ChromeTabSource.activate(windowID: windowID, tabIndex: tabIndex, tabID: tabID)
        case "safari":
            guard let tabID = Int(parts[3]) else { return }
            SafariTabSource.activate(windowID: windowID, tabIndex: tabID)
        case "terminal":
            guard let tabID = Int(parts[3]) else { return }
            TerminalTabSource.activate(windowID: windowID, tabIndex: tabID)
        default:
            return
        }
    }
}
