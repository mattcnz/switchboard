import SwiftUI
import AppKit
import KeyboardShortcuts
import ServiceManagement

@main
struct SwitchboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var permissionManager = AccessibilityPermissionManager.shared
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager.shared

    var body: some Scene {
        // No windows — all UI is managed by AppCoordinator.
        Settings {
            AppSettingsView(
                settings: settings,
                permissionManager: permissionManager,
                launchAtLoginManager: launchAtLoginManager,
                screenPermission: .shared
            )
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = AppCoordinator()
        coordinator = c
        Task { @MainActor in c.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

enum BuildInfo {
    static let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    // Executable mtime — can't go stale the way a hardcoded string could.
    static let builtAt: Date? = {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }()

    static var builtAtDescription: String {
        guard let builtAt else { return "unknown" }
        return builtAt.formatted(date: .abbreviated, time: .shortened)
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var includeWindows: Bool {
        didSet { UserDefaults.standard.set(includeWindows, forKey: Keys.includeWindows) }
    }

    @Published var includeChromeTabs: Bool {
        didSet { UserDefaults.standard.set(includeChromeTabs, forKey: Keys.includeChromeTabs) }
    }

    @Published var includeSafariTabs: Bool {
        didSet { UserDefaults.standard.set(includeSafariTabs, forKey: Keys.includeSafariTabs) }
    }

    @Published var includeTerminalTabs: Bool {
        didSet { UserDefaults.standard.set(includeTerminalTabs, forKey: Keys.includeTerminalTabs) }
    }

    @Published var showPreviews: Bool {
        didSet { UserDefaults.standard.set(showPreviews, forKey: Keys.showPreviews) }
    }

    private enum Keys {
        static let includeWindows = "settings.includeWindows"
        static let includeChromeTabs = "settings.includeChromeTabs"
        static let includeSafariTabs = "settings.includeSafariTabs"
        static let includeTerminalTabs = "settings.includeTerminalTabs"
        static let showPreviews = "settings.showPreviews"
    }

    private init(defaults: UserDefaults = .standard) {
        includeWindows = defaults.object(forKey: Keys.includeWindows) as? Bool ?? true
        includeChromeTabs = defaults.object(forKey: Keys.includeChromeTabs) as? Bool ?? true
        includeSafariTabs = defaults.object(forKey: Keys.includeSafariTabs) as? Bool ?? true
        includeTerminalTabs = defaults.object(forKey: Keys.includeTerminalTabs) as? Bool ?? true
        showPreviews = defaults.object(forKey: Keys.showPreviews) as? Bool ?? true
    }
}

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled = false
    @Published private(set) var statusMessage = "Unavailable"
    @Published private(set) var errorMessage: String?

    private init() {
        refresh()
    }

    func refresh(clearError: Bool = false) {
        if clearError {
            errorMessage = nil
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            statusMessage = "Enabled"
        case .notRegistered:
            isEnabled = false
            statusMessage = "Disabled"
        case .requiresApproval:
            isEnabled = false
            statusMessage = "Requires approval in System Settings"
        case .notFound:
            isEnabled = false
            statusMessage = "App service not found"
        @unknown default:
            isEnabled = false
            statusMessage = "Unknown status"
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh(clearError: true)
        } catch {
            errorMessage = error.localizedDescription
            refresh()
        }
    }
}

struct AppSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissionManager: AccessibilityPermissionManager
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    @ObservedObject var screenPermission: ScreenRecordingPermissionManager

    var body: some View {
        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Open Switchboard", name: .toggleSwitchboard)
                Text("Pick the global shortcut that toggles the palette.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Sources") {
                Toggle("Open windows", isOn: $settings.includeWindows)
                Toggle("Chrome tabs", isOn: $settings.includeChromeTabs)
                Toggle("Safari tabs", isOn: $settings.includeSafariTabs)
                Toggle("Terminal tabs", isOn: $settings.includeTerminalTabs)
                Text("Tab sources may prompt for Automation access the first time they are used.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Previews") {
                Toggle("Show window previews", isOn: $settings.showPreviews)
                Text("Previews need Screen Recording access. Windows without one — minimized, on another Space, or browser tabs that aren't active — show their app icon.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Startup") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { launchAtLoginManager.setEnabled($0) }
                    )
                )
                Text(launchAtLoginManager.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let errorMessage = launchAtLoginManager.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    Text(permissionManager.isTrusted ? "Granted" : "Not granted")
                        .foregroundColor(permissionManager.isTrusted ? .green : .secondary)
                }

                HStack(spacing: 12) {
                    Button("Open System Settings") {
                        permissionManager.requestPermission()
                    }

                    Button("Recheck") {
                        permissionManager.recheck()
                    }
                }

                HStack {
                    Text("Screen Recording")
                    Spacer()
                    Text(screenPermission.isGranted ? "Granted" : "Not granted")
                        .foregroundColor(screenPermission.isGranted ? .green : .secondary)
                }

                HStack(spacing: 12) {
                    Button("Grant Screen Recording") {
                        screenPermission.request()
                    }

                    if screenPermission.needsRelaunch {
                        Button("Relaunch Switchboard") {
                            screenPermission.relaunch()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if screenPermission.needsRelaunch {
                    Text("macOS applies a new Screen Recording grant only after the app restarts.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                HStack(spacing: 12) {
                    Button("Request Chrome Access") {
                        ChromeTabSource.requestAutomationPermission()
                    }

                    Button("Request Safari Access") {
                        SafariTabSource.requestAutomationPermission()
                    }

                    Button("Request Terminal Access") {
                        TerminalTabSource.requestAutomationPermission()
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(BuildInfo.version)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Built")
                    Spacer()
                    Text(BuildInfo.builtAtDescription)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 540)
        .onAppear {
            permissionManager.recheck()
            screenPermission.recheck()
            launchAtLoginManager.refresh()
        }
    }
}
