import AppKit
import Foundation
import OSLog

actor SafariTabSource: SwitchItemSource {
    private let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "SafariTabSource")
    private var cache: [SwitchItem] = []
    private var lastFetch: Date = .distantPast
    private let cacheTTL: TimeInterval = 10

    func snapshot() async -> [SwitchItem] {
        guard isSafariRunning else { return [] }
        if !cache.isEmpty && Date().timeIntervalSince(lastFetch) < cacheTTL {
            return cache
        }

        await fetchAndCache()
        return cache
    }

    static func activate(windowID: Int, tabIndex: Int) {
        let script = """
        tell application "Safari"
            activate
            repeat with w in windows
                if id of w is \(windowID) then
                    set index of w to 1
                    set current tab of w to tab \(tabIndex) of w
                    exit repeat
                end if
            end repeat
        end tell
        """

        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }

    static func requestAutomationPermission() {
        var err: NSDictionary?
        NSAppleScript(source: "if application \"Safari\" is running then tell application \"Safari\" to return name")?
            .executeAndReturnError(&err)
    }

    private func fetchAndCache() async {
        let script = """
        tell application "Safari"
            set rs to (ASCII character 30)
            set us to (ASCII character 31)
            set output to ""
            repeat with w in windows
                set wid to id of w
                set tabCount to count of tabs of w
                repeat with tabIndex from 1 to tabCount
                    set t to tab tabIndex of w
                    try
                        set tabTitle to name of t
                    on error
                        set tabTitle to ""
                    end try
                    try
                        set tabURL to URL of t
                    on error
                        set tabURL to ""
                    end try
                    set output to output & wid & us & tabIndex & us & tabTitle & us & tabURL & rs
                end repeat
            end repeat
            return output
        end tell
        """

        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        guard err == nil, let raw = result?.stringValue else {
            logger.error("Safari AppleScript failed: \(String(describing: err), privacy: .public)")
            cache = []
            return
        }

        let icon = safariIcon
        let rs = "\u{1E}"
        let us = "\u{1F}"
        cache = raw
            .components(separatedBy: rs)
            .compactMap { record in
                let fields = record.components(separatedBy: us)
                guard fields.count >= 4,
                      let windowID = Int(fields[0]),
                      let tabIndex = Int(fields[1]) else {
                    return nil
                }

                let title = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let url = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = title.isEmpty ? url : title
                guard !displayTitle.isEmpty else { return nil }

                return SwitchItem(
                    id: "tab:safari:\(windowID):\(tabIndex)",
                    kind: .browserTab,
                    appName: "Safari",
                    appBundleID: "com.apple.Safari",
                    title: displayTitle,
                    icon: icon,
                    pid: nil,
                    axWindow: nil
                )
            }
        logger.debug("Loaded \(self.cache.count) Safari tabs")
        lastFetch = Date()
    }

    private var isSafariRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Safari"
        }
    }

    private var safariIcon: NSImage? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.Safari" }?
            .icon
    }
}
