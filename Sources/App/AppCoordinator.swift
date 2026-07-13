import AppKit
import SwiftUI
import OSLog

@MainActor
final class AppCoordinator {
    private let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "AppCoordinator")
    private let permissionManager = AccessibilityPermissionManager.shared
    private let settings = AppSettings.shared
    private let windowScanner = WindowScanner()
    private let chromeTabSource = ChromeTabSource()
    private let safariTabSource = SafariTabSource()
    private let terminalTabSource = TerminalTabSource()
    private let activator = WindowActivator()
    private var panelController: FloatingPanelController?
    private var hotkeyManager: HotkeyManager?
    private var onboardingWindow: NSWindow?

    func start() {
        logger.info("Switchboard starting, binary built \(BuildInfo.builtAtDescription, privacy: .public)")
        if permissionManager.isTrusted {
            setupHotkey()
        } else {
            showOnboarding()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleBecomeActive()
            }
        }
    }

    private func handleBecomeActive() {
        permissionManager.recheck()
        if permissionManager.isTrusted && hotkeyManager == nil {
            onboardingWindow?.close()
            onboardingWindow = nil
            setupHotkey()
        }
    }

    private func setupHotkey() {
        // Trigger "Switchboard wants to control Google Chrome" dialog now,
        // clearly at startup, rather than buried inside a search later.
        if settings.includeChromeTabs {
            ChromeTabSource.requestAutomationPermission()
        }
        if settings.includeSafariTabs {
            SafariTabSource.requestAutomationPermission()
        }
        if settings.includeTerminalTabs {
            TerminalTabSource.requestAutomationPermission()
        }

        let ctrl = FloatingPanelController(
            sourceProvider: { [weak self] in self?.activeSources() ?? [] },
            activator: activator
        )
        panelController = ctrl
        hotkeyManager = HotkeyManager { ctrl.toggle() }
    }

    private func activeSources() -> [any SwitchItemSource] {
        var sources: [any SwitchItemSource] = []

        if settings.includeWindows {
            sources.append(windowScanner)
        }
        if settings.includeChromeTabs {
            sources.append(chromeTabSource)
        }
        if settings.includeSafariTabs {
            sources.append(safariTabSource)
        }
        if settings.includeTerminalTabs {
            sources.append(terminalTabSource)
        }

        return sources
    }

    private func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Switchboard"
        window.center()
        window.contentView = NSHostingView(
            rootView: OnboardingView(permissionManager: permissionManager)
        )
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }
}
