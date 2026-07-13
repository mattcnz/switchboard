import AppKit
import Combine

@MainActor
final class AccessibilityPermissionManager: ObservableObject {
    static let shared = AccessibilityPermissionManager()

    @Published private(set) var isTrusted: Bool

    private init() {
        isTrusted = AXIsProcessTrusted()
    }

    func recheck() {
        isTrusted = AXIsProcessTrusted()
    }

    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
