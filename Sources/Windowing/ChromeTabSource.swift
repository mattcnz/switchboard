import AppKit
import Foundation
import OSLog

actor ChromeTabSource: SwitchItemSource {
    private static let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "ChromeTabSource")
    private var cache: [SwitchItem] = []
    private var lastFetch: Date = .distantPast
    private let cacheTTL: TimeInterval = 30

    func snapshot() async -> [SwitchItem] {
        guard isChromeRunning else { return [] }
        if !cache.isEmpty && Date().timeIntervalSince(lastFetch) < cacheTTL {
            return cache
        }
        await fetchAndCache()
        return cache
    }

    func freshSnapshot() async -> [SwitchItem] {
        guard isChromeRunning else { return [] }
        // Skip when snapshot() just fetched (cold cache) — nothing to refresh.
        if Date().timeIntervalSince(lastFetch) < 1 { return cache }
        await fetchAndCache()
        return cache
    }

    // MARK: Activation

    // Tab-id-first: cached indexes go stale within seconds when tabs are
    // opened/closed/reordered, and a stale index usually still resolves —
    // silently selecting the wrong tab. Tab ids are stable for the session
    // (even across window drags), so resolve the id live and derive the
    // index at activation time. `activate` runs LAST: running it first
    // fronts whichever Chrome window was already on top.
    @discardableResult
    static func activate(tabID: Int?, windowID: Int, tabIndex: Int, tabTitle: String) -> Bool {
        let idLookup = tabID.map { """
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        if id of t is \($0) then
                            set active tab index of w to (index of t)
                            set index of w to 1
                            activate
                            return "ok:id:" & (id of w)
                        end if
                    end repeat
                end try
            end repeat
        """ } ?? ""

        let script = """
        tell application "Google Chrome"
        \(idLookup)
            repeat with w in windows
                if id of w is \(windowID) then
                    if \(tabIndex) is not greater than (count of tabs of w) then
                        set active tab index of w to \(tabIndex)
                    end if
                    set index of w to 1
                    activate
                    return "ok:index-fallback"
                end if
            end repeat
            return "not-found"
        end tell
        """

        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            logger.error("Chrome activation failed: \(String(describing: err), privacy: .public)")
            return false
        }

        let marker = result?.stringValue ?? "nil"
        switch marker {
        case let m where m.hasPrefix("ok:id"):
            logger.debug("Chrome activation result: \(marker, privacy: .public)")
        case "ok:index-fallback":
            logger.info("Chrome tab id lookup missed; fell back to cached window/index")
        default:
            logger.error("Chrome activation could not find tab or window: \(marker, privacy: .public)")
            return false
        }

        // `set index of w to 1` often fails to actually raise the window in
        // Chrome; finish the job over AX (permission we already hold).
        raiseWindowViaAX(bundleID: "com.google.Chrome", titlePrefix: tabTitle)
        return true
    }

    private static func raiseWindowViaAX(bundleID: String, titlePrefix: String) {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return }
        defer { app.activate(options: []) }

        guard !titlePrefix.isEmpty else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }

        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String,
                  title.hasPrefix(titlePrefix) else { continue }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
    }

    // MARK: Startup permission warm-up

    // Call once at app startup (on main thread) so the "Switchboard wants to
    // control Google Chrome" dialog appears clearly before the palette opens.
    static func requestAutomationPermission() {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Google Chrome\" to return name")?
            .executeAndReturnError(&err)
    }

    // MARK: Private

    private func fetchAndCache() async {
        // ASCII 30 = Record Separator, ASCII 31 = Unit Separator.
        // Neither can appear in tab titles or URLs, so parsing is unambiguous.
        let script = """
        tell application "Google Chrome"
            set rs to (ASCII character 30)
            set us to (ASCII character 31)
            set output to ""
            repeat with w in windows
                try
                    set wid to id of w
                    set tabCount to count of tabs of w
                    repeat with tabIndex from 1 to tabCount
                        set t to tab tabIndex of w
                        try
                            set output to output & wid & us & tabIndex & us & (id of t) & us & (title of t) & us & (URL of t) & rs
                        end try
                    end repeat
                end try
            end repeat
            return output
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        guard err == nil, let raw = result?.stringValue else {
            cache = []
            return
        }

        let icon = chromeIcon
        let rs = "\u{1E}"
        let us = "\u{1F}"
        cache = raw
            .components(separatedBy: rs)
            .compactMap { record -> SwitchItem? in
                let fields = record.components(separatedBy: us)
                guard fields.count >= 5,
                      let wid = Int(fields[0]),
                      let tabIndex = Int(fields[1]),
                      let tid = Int(fields[2]) else { return nil }
                let title = fields[3]
                let url   = fields[4]
                let display = title.isEmpty ? url : title
                guard !display.isEmpty else { return nil }
                return SwitchItem(
                    id: "tab:chrome:\(wid):\(tabIndex):\(tid)",
                    kind: .browserTab,
                    appName: "Chrome",
                    appBundleID: "com.google.Chrome",
                    title: display,
                    icon: icon,
                    pid: nil,
                    axWindow: nil,
                    recencyKey: "tab:chrome:\(tid)",
                    subtitle: URL(string: url)?.host
                )
            }
        Self.logger.debug("Loaded \(self.cache.count) Chrome tabs")
        lastFetch = Date()
    }

    private var isChromeRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.google.Chrome"
        }
    }

    private var chromeIcon: NSImage? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.google.Chrome" }?
            .icon
    }
}
