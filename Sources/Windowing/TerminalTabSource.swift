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

    // tty-first: a tab's tty is stable for its lifetime, while cached
    // window/index pairs go stale as tabs open/close/reorder. `activate`
    // runs LAST so Terminal doesn't front the wrong window first.
    @discardableResult
    static func activate(tty: String?, windowID: Int, tabIndex: Int) -> Bool {
        let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "TerminalTabSource")
        let ttyLookup = (tty?.isEmpty == false ? tty : nil).map { """
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        if tty of t is "\($0)" then
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return "ok:tty"
                        end if
                    end repeat
                end try
            end repeat
        """ } ?? ""

        let script = """
        tell application "Terminal"
        \(ttyLookup)
            repeat with w in windows
                if id of w is \(windowID) then
                    if \(tabIndex) is not greater than (count of tabs of w) then
                        set selected tab of w to tab \(tabIndex) of w
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
            logger.error("Terminal activation failed: \(String(describing: err), privacy: .public)")
            return false
        }
        switch result?.stringValue {
        case "ok:tty":
            return true
        case "ok:index-fallback":
            logger.info("Terminal tty lookup missed; fell back to cached window/index")
            return true
        default:
            logger.error("Terminal activation could not find tab or window: \(result?.stringValue ?? "nil", privacy: .public)")
            return false
        }
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
                    id: "tab:terminal:\(windowID):\(tabIndex):\(tty)",
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
