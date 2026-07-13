import AppKit
import Foundation
import OSLog

actor TerminalTabSource: SwitchItemSource {
    private let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "TerminalTabSource")
    private var cache: [SwitchItem] = []
    private var lastFetch: Date = .distantPast
    private let cacheTTL: TimeInterval = 10

    func snapshot() async -> [SwitchItem] {
        guard isTerminalRunning else { return [] }
        if !cache.isEmpty && Date().timeIntervalSince(lastFetch) < cacheTTL {
            return cache
        }

        await fetchAndCache()
        return cache
    }

    static func activate(windowID: Int, tabIndex: Int) {
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                if id of w is \(windowID) then
                    set index of w to 1
                    set selected tab of w to tab \(tabIndex) of w
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
        NSAppleScript(source: "if application \"Terminal\" is running then tell application \"Terminal\" to return name")?
            .executeAndReturnError(&err)
    }

    private func fetchAndCache() async {
        let script = """
        tell application "Terminal"
            set rs to (ASCII character 30)
            set us to (ASCII character 31)
            set output to ""
            repeat with w in windows
                set wid to id of w
                set tabCount to count of tabs of w
                repeat with tabIndex from 1 to tabCount
                    set t to tab tabIndex of w
                    try
                        set tabTitle to custom title of t
                    on error
                        set tabTitle to ""
                    end try
                    try
                        set tabTTY to tty of t
                    on error
                        set tabTTY to ""
                    end try
                    try
                        set tabProcesses to processes of t
                    on error
                        set tabProcesses to {}
                    end try
                    set processText to ""
                    repeat with processName in tabProcesses
                        set processText to processText & processName & " "
                    end repeat
                    set output to output & wid & us & tabIndex & us & tabTitle & us & tabTTY & us & processText & rs
                end repeat
            end repeat
            return output
        end tell
        """

        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        guard err == nil, let raw = result?.stringValue else {
            logger.error("Terminal AppleScript failed: \(String(describing: err), privacy: .public)")
            cache = []
            return
        }

        let icon = terminalIcon
        let rs = "\u{1E}"
        let us = "\u{1F}"
        cache = raw
            .components(separatedBy: rs)
            .compactMap { record in
                let fields = record.components(separatedBy: us)
                guard fields.count >= 5,
                      let windowID = Int(fields[0]),
                      let tabIndex = Int(fields[1]) else {
                    return nil
                }

                let customTitle = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let tty = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
                let processes = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)

                let titleParts = [customTitle, tty, processes].filter { !$0.isEmpty }
                let displayTitle = titleParts.isEmpty ? "Terminal Tab" : titleParts.joined(separator: " — ")

                return SwitchItem(
                    id: "tab:terminal:\(windowID):\(tabIndex)",
                    kind: .browserTab,
                    appName: "Terminal",
                    appBundleID: "com.apple.Terminal",
                    title: displayTitle,
                    icon: icon,
                    pid: nil,
                    axWindow: nil
                )
            }
        logger.debug("Loaded \(self.cache.count) Terminal tabs")
        lastFetch = Date()
    }

    private var isTerminalRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Terminal"
        }
    }

    private var terminalIcon: NSImage? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.Terminal" }?
            .icon
    }
}
