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

    // MARK: Activation

    static func activate(windowID: Int, tabIndex: Int, tabID: Int?) {
        let script = """
        tell application "Google Chrome"
            activate
            repeat with w in windows
                if id of w is \(windowID) then
                    set index of w to 1
                    try
                        set active tab index of w to \(tabIndex)
                        return "ok:index"
                    on error
                    end try
        \(tabID.map { """
                    try
                        repeat with t in tabs of w
                            if id of t is \($0) then
                                set active tab index of w to (index of t)
                                return "ok:id"
                            end if
                        end repeat
                    on error
                    end try
        """ } ?? "")
                    return "window-found-tab-missing"
                end if
            end repeat
            return "window-missing"
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            logger.error("Chrome activation failed: \(String(describing: err), privacy: .public)")
            return
        }
        logger.debug("Chrome activation result: \(result?.stringValue ?? "nil", privacy: .public)")
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
                    axWindow: nil
                )
            }
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
