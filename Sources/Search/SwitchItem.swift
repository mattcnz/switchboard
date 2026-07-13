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

    static func == (lhs: SwitchItem, rhs: SwitchItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
