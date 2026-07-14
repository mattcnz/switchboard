import AppKit
import SwiftUI
import Combine
import OSLog

@MainActor
final class AppCoordinator: NSObject {
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
    private var statusItem: NSStatusItem?
    private var trustPollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        logger.info("Switchboard starting, binary built \(BuildInfo.builtAtDescription, privacy: .public)")
        setupStatusItem()

        // Single path for reacting to trust: fires with the current value on
        // subscribe, and again whenever the poll/recheck flips it.
        permissionManager.$isTrusted
            .removeDuplicates()
            .sink { [weak self] trusted in
                Task { @MainActor [weak self] in self?.trustDidChange(trusted) }
            }
            .store(in: &cancellables)

        if !permissionManager.isTrusted {
            showOnboarding()
            startTrustPolling()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.permissionManager.recheck()
            }
        }
    }

    private func trustDidChange(_ trusted: Bool) {
        guard trusted else { return }
        stopTrustPolling()
        onboardingWindow?.close()
        onboardingWindow = nil
        if hotkeyManager == nil {
            setupHotkey()
        }
    }

    // macOS doesn't notify when the user flips the Accessibility toggle, so
    // poll while ungranted — the onboarding window closes itself the moment
    // access appears instead of making the user hunt for a Recheck button.
    private func startTrustPolling() {
        guard trustPollTimer == nil else { return }
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.permissionManager.recheck() }
        }
    }

    private func stopTrustPolling() {
        trustPollTimer?.invalidate()
        trustPollTimer = nil
    }

    // MARK: Status bar

    // The app is LSUIElement (no Dock icon), so without this there is no way
    // to reach Settings or onboarding once their windows close.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: "Switchboard"
        )

        let menu = NSMenu()

        let open = NSMenuItem(title: "Open Palette", action: #selector(openPaletteFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let permissions = NSMenuItem(title: "Permissions…", action: #selector(showPermissionsFromMenu), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Switchboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    @objc private func openPaletteFromMenu() {
        permissionManager.recheck()
        if let panelController, permissionManager.isTrusted {
            panelController.toggle()
        } else {
            showOnboarding()
        }
    }

    @objc private func showPermissionsFromMenu() {
        permissionManager.recheck()
        showOnboarding()
        if !permissionManager.isTrusted {
            startTrustPolling()
        }
    }

    @objc private func openSettingsFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if !opened {
            // Fallback: the onboarding window carries a SettingsLink.
            showOnboarding()
        }
    }

    // MARK: Hotkey + sources

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
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

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
