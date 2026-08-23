import AppKit

enum SwitchItemKind {
    case window, browserTab, context
}

struct SwitchItem: Identifiable, Hashable, @unchecked Sendable {
    let id: String
    let kind: SwitchItemKind
    let appName: String
    let appBundleID: String?
    let title: String
    let icon: NSImage?
    let pid: pid_t?
    let axWindow: AXUIElement?
    // Stable across relaunches and tab reorders, unlike `id` (which carries
    // volatile pids/CFHashes/tab indexes). Used for recency ranking.
    let recencyKey: String
    // Secondary display/search text: URL host for browser tabs, tty for
    // Terminal tabs.
    let subtitle: String?
    // ScreenCaptureKit's window identity, for previews. Windows only.
    let cgWindowID: CGWindowID?
    // Tab sources only: a browser/Terminal window renders just its active tab,
    // so only that tab may claim the window's preview.
    let isActiveTab: Bool

    init(
        id: String,
        kind: SwitchItemKind,
        appName: String,
        appBundleID: String?,
        title: String,
        icon: NSImage?,
        pid: pid_t?,
        axWindow: AXUIElement?,
        recencyKey: String? = nil,
        subtitle: String? = nil,
        cgWindowID: CGWindowID? = nil,
        isActiveTab: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.appName = appName
        self.appBundleID = appBundleID
        self.title = title
        self.icon = icon
        self.pid = pid
        self.axWindow = axWindow
        self.recencyKey = recencyKey ?? id
        self.subtitle = subtitle
        self.cgWindowID = cgWindowID
        self.isActiveTab = isActiveTab
    }

    static func == (lhs: SwitchItem, rhs: SwitchItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension SwitchItem {
    // VS Code titles its windows "file — project" (unlike most apps, which
    // put the project/document first); flip it for display so results scan
    // the same way regardless of editor. Search/recency still use the raw
    // AX title untouched.
    private static let vsCodeBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss",
    ]

    var displayTitle: String {
        guard let appBundleID, Self.vsCodeBundleIDs.contains(appBundleID),
              let range = title.range(of: " — ") else { return title }
        let file = title[..<range.lowerBound]
        let project = title[range.upperBound...]
        // More than one separator means an unusual custom title format —
        // don't guess at its structure, just leave it alone.
        guard !project.contains(" — ") else { return title }
        return "\(project) — \(file)"
    }
}
