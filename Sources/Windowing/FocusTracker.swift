import AppKit
import ApplicationServices
import OSLog

// Tracks which window was focused when, across all apps, so the palette can
// open in true most-recently-used order: bare Option+Space, Enter flips to
// the previous window like Cmd-Tab, with no typing.
@MainActor
final class FocusTracker {
    static let shared = FocusTracker()
    private static let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "FocusTracker")

    // Most recent first. Ids use WindowScanner's scheme ("win:<pid>:<CFHash>"),
    // which is stable for a window's lifetime, so entries match scan items.
    private(set) var mruWindowIDs: [String] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var started = false
    private let maxEntries = 60

    private init() {}

    // Requires Accessibility trust — call only once granted.
    func start() {
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.watch(app)
                self?.noteFocusedWindow(of: app)
            }
        }
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.watch(app) }
        }
        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.unwatch(app.processIdentifier) }
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            watch(app)
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            noteFocusedWindow(of: front)
        }
    }

    // The window the user is in right now (or was, while our non-activating
    // palette is up) — the one place they never want to switch to.
    var currentWindowID: String? { mruWindowIDs.first }

    func mruRanks() -> [String: Int] {
        var ranks: [String: Int] = [:]
        for (index, id) in mruWindowIDs.enumerated() { ranks[id] = index }
        return ranks
    }

    // MARK: Private

    // App-activation notifications only fire on app switches; an AXObserver
    // per app catches window switches WITHIN an app (Cmd-` between windows).
    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, observers[pid] == nil else { return }

        var observer: AXObserver?
        let created = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
            // The observer's run loop source is on the main run loop.
            MainActor.assumeIsolated {
                tracker.handleFocusNotification()
            }
        }, &observer)
        guard created == .success, let observer else { return }

        let axApp = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func unwatch(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        mruWindowIDs.removeAll { $0.hasPrefix("win:\(pid):") }
    }

    private func handleFocusNotification() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        noteFocusedWindow(of: front)
    }

    private func noteFocusedWindow(of app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return }
        let window = unsafeBitCast(ref, to: AXUIElement.self)
        let id = "win:\(pid):\(CFHash(window))"
        mruWindowIDs.removeAll { $0 == id }
        mruWindowIDs.insert(id, at: 0)
        if mruWindowIDs.count > maxEntries {
            mruWindowIDs.removeLast(mruWindowIDs.count - maxEntries)
        }
        Self.logger.debug("focus → \(app.localizedName ?? "?", privacy: .public) \(id, privacy: .public) (mru: \(self.mruWindowIDs.count))")
    }
}
