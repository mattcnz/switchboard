import AppKit
import Combine
import CoreGraphics

@MainActor
final class ScreenRecordingPermissionManager: ObservableObject {
    static let shared = ScreenRecordingPermissionManager()

    @Published private(set) var isGranted: Bool
    // macOS applies a new Screen Recording grant only to a freshly launched
    // process, so a grant mid-session needs an explicit relaunch.
    @Published private(set) var needsRelaunch = false

    private let grantedAtLaunch: Bool

    private init() {
        let granted = CGPreflightScreenCaptureAccess()
        isGranted = granted
        grantedAtLaunch = granted
    }

    func recheck() {
        isGranted = CGPreflightScreenCaptureAccess()
        if isGranted && !grantedAtLaunch {
            needsRelaunch = true
        }
    }

    func request() {
        if !CGRequestScreenCaptureAccess() {
            openSystemSettings()
        }
        recheck()
    }

    // Second, empirical signal: capture refused even though preflight said yes.
    func noteCaptureDeniedByFramework() {
        needsRelaunch = true
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
