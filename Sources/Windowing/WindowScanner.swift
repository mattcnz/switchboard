import AppKit
import OSLog

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
    private static let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "WindowScanner")
    private var lastSnapshot: [SwitchItem] = []
    private var lastScan: Date = .distantPast

    init() {
        // Process-global AX message timeout: without it a hung app blocks
        // the default 6s per attribute read, stalling the whole scan.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    func snapshot() async -> [SwitchItem] {
        if !lastSnapshot.isEmpty { return lastSnapshot }
        return await freshSnapshot()
    }

    func freshSnapshot() async -> [SwitchItem] {
        // Skip when snapshot() just scanned (cold cache) — nothing to refresh.
        if Date().timeIntervalSince(lastScan) < 1 { return lastSnapshot }

        let start = Date()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        var itemsByApp: [pid_t: [SwitchItem]] = [:]
        await withTaskGroup(of: (pid_t, [SwitchItem]).self) { group in
            for app in apps {
                group.addTask { (app.processIdentifier, Self.scanApp(app)) }
            }
            for await (pid, items) in group {
                itemsByApp[pid] = items
            }
        }
        // Deterministic order (task completion order isn't).
        let items = apps.flatMap { itemsByApp[$0.processIdentifier] ?? [] }

        lastSnapshot = items
        lastScan = Date()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        Self.logger.debug("scanned \(apps.count) apps, \(items.count) windows in \(ms)ms")
        return items
    }

    private nonisolated static func scanApp(_ app: NSRunningApplication) -> [SwitchItem] {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        let windows = windows(for: axApp)
        guard !windows.isEmpty else { return [] }

        let icon = app.icon
        let appName = app.localizedName ?? "Unknown"
        let bundleID = app.bundleIdentifier

        var items: [SwitchItem] = []
        for window in windows {
            var titleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            // Empty titles happen on Electron apps whose AX tree populates
            // lazily — fall back to the app name rather than hiding the window.
            let axTitle = (titleRef as? String) ?? ""
            let title = axTitle.isEmpty ? appName : axTitle

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
        return items
    }

    private nonisolated static func windows(for app: AXUIElement) -> [AXUIElement] {
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

    private nonisolated static func copyWindows(from app: AXUIElement, attribute: CFString) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private nonisolated static func copyWindow(from app: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute, &value) == .success else {
            return nil
        }
        guard let value else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
