import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleSwitchboard = Self("toggleSwitchboard", default: .init(.space, modifiers: .option))
}

@MainActor
final class HotkeyManager {
    private let onToggle: @MainActor () -> Void

    init(onToggle: @escaping @MainActor () -> Void) {
        self.onToggle = onToggle
        KeyboardShortcuts.onKeyUp(for: .toggleSwitchboard) { [weak self] in
            self?.onToggle()
        }
    }
}
