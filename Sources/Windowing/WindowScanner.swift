import AppKit

protocol SwitchItemSource {
    // Fast path — may serve a cached snapshot so the palette renders instantly.
    func snapshot() async -> [SwitchItem]
    // Force a refetch from the live source.
    func freshSnapshot() async -> [SwitchItem]
}

extension SwitchItemSource {
    func freshSnapshot() async -> [SwitchItem] { await snapshot() }
}

actor ComposedSource: SwitchItemSource {
    private let sources: [any SwitchItemSource]
    init(sources: [any SwitchItemSource]) { self.sources = sources }

    func snapshot() async -> [SwitchItem] {
        var all: [SwitchItem] = []
        for source in sources {
            all.append(contentsOf: await source.snapshot())
        }
        return all
    }
}

actor WindowScanner: SwitchItemSource {
    func snapshot() async -> [SwitchItem] {
        var items: [SwitchItem] = []

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in apps {
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            let windows = windows(for: axApp)
            guard !windows.isEmpty else { continue }

            let icon = app.icon
            let appName = app.localizedName ?? "Unknown"
            let bundleID = app.bundleIdentifier

            for window in windows {
                var titleRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                      let title = titleRef as? String,
                      !title.isEmpty else { continue }

                var minimizedRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                   (minimizedRef as? Bool) == true { continue }

                let id = "win:\(pid):\(CFHash(window))"
                items.append(SwitchItem(
                    id: id,
                    kind: .window,
                    appName: appName,
                    appBundleID: bundleID,
                    title: title,
                    icon: icon,
                    pid: pid,
                    axWindow: window
                ))
            }
        }

        return items
    }

    private func windows(for app: AXUIElement) -> [AXUIElement] {
        var seen = Set<CFHashCode>()
        var result: [AXUIElement] = []

        func appendWindow(_ window: AXUIElement) {
            let hash = CFHash(window)
            guard seen.insert(hash).inserted else { return }
            result.append(window)
        }

        if let windows = copyWindows(from: app, attribute: kAXWindowsAttribute as CFString) {
            for window in windows {
                appendWindow(window)
            }
        }

        if let mainWindow = copyWindow(from: app, attribute: kAXMainWindowAttribute as CFString) {
            appendWindow(mainWindow)
        }

        if let focusedWindow = copyWindow(from: app, attribute: kAXFocusedWindowAttribute as CFString) {
            appendWindow(focusedWindow)
        }

        return result
    }

    private func copyWindows(from app: AXUIElement, attribute: CFString) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private func copyWindow(from app: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute, &value) == .success else {
            return nil
        }
        guard let value else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
