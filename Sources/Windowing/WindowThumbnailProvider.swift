import AppKit
import ScreenCaptureKit
import OSLog

// Captures live window previews via ScreenCaptureKit.
//
// An actor rather than a @MainActor class: it owns mutable state (cache,
// in-flight table, concurrency permits) touched by many concurrent capture
// tasks, and capture must stay off the main thread so typing never stalls.
actor WindowThumbnailProvider {
    private static let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "Thumbnails")
    private static let freshFor: TimeInterval = 5
    private static let maxCacheEntries = 80
    private static let maxConcurrentCaptures = 5
    private static let maxFailuresPerSession = 2

    private struct Entry {
        let image: NSImage
        let capturedAt: Date
    }

    private var shareable: [CGWindowID: SCWindow] = [:]
    private var shareableFetchedAt: Date = .distantPast
    private var cache: [CGWindowID: Entry] = [:]
    private var lru: [CGWindowID] = []
    private var inFlight: [CGWindowID: Task<NSImage?, Never>] = [:]
    private var failures: [CGWindowID: Int] = [:]
    private var permits = WindowThumbnailProvider.maxConcurrentCaptures
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var priorityWaiters: [CheckedContinuation<Void, Never>] = []
    private var sessionCaptures = 0
    private var sessionHits = 0
    private var sessionFailures = 0

    // Called as the palette opens: refreshes the window list and resets
    // per-session failure counters so a closed-then-reopened window retries.
    func beginSession() async {
        failures.removeAll()
        sessionCaptures = 0
        sessionHits = 0
        sessionFailures = 0
        await refreshShareableContent()
    }

    func endSession() {
        guard sessionCaptures + sessionHits + sessionFailures > 0 else { return }
        Self.logger.debug("thumb session: \(self.sessionCaptures) captured, \(self.sessionHits) cache hits, \(self.sessionFailures) failed")
    }

    func thumbnail(for windowID: CGWindowID, width: CGFloat, priority: Bool) async -> NSImage? {
        // Never trigger a surprise permission prompt from a keystroke.
        guard CGPreflightScreenCaptureAccess() else { return nil }

        if let entry = cache[windowID] {
            touch(windowID)
            if Date().timeIntervalSince(entry.capturedAt) < Self.freshFor {
                sessionHits += 1
                return entry.image
            }
            // Stale-while-revalidate: show the old frame now, refresh behind it.
            if inFlight[windowID] == nil {
                let task = captureTask(for: windowID, width: width, priority: false)
                inFlight[windowID] = task
            }
            sessionHits += 1
            return entry.image
        }

        if let existing = inFlight[windowID] {
            return await existing.value
        }
        guard (failures[windowID] ?? 0) < Self.maxFailuresPerSession else { return nil }

        let task = captureTask(for: windowID, width: width, priority: priority)
        inFlight[windowID] = task
        return await task.value
    }

    // MARK: Private

    // Unstructured on purpose: a cell scrolling away cancels its SwiftUI task,
    // but a nearly-done capture should still land in the cache for next time.
    private func captureTask(for windowID: CGWindowID, width: CGFloat, priority: Bool) -> Task<NSImage?, Never> {
        Task { [weak self] in
            guard let self else { return nil }
            return await self.performCapture(windowID: windowID, width: width, priority: priority)
        }
    }

    private func performCapture(windowID: CGWindowID, width: CGFloat, priority: Bool) async -> NSImage? {
        defer { inFlight[windowID] = nil }

        if shareable.isEmpty || Date().timeIntervalSince(shareableFetchedAt) > Self.freshFor {
            await ensureShareableContentFresh()
        }
        guard let scWindow = shareable[windowID] else {
            // Minimized or on another Space: not capturable, but a previously
            // captured frame is still the most useful thing we can show.
            return cache[windowID]?.image
        }

        await acquirePermit(priority: priority)
        defer { releasePermit() }

        let start = DispatchTime.now()
        let scale = 2.0
        let aspect = scWindow.frame.width > 0 ? scWindow.frame.height / scWindow.frame.width : 0.625
        let config = SCStreamConfiguration()
        config.width = Int(width * scale)
        config.height = max(1, Int(width * aspect * scale))
        config.showsCursor = false
        config.scalesToFit = true

        do {
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            store(image, for: windowID)
            sessionCaptures += 1
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Self.logger.debug("thumb capture wid=\(windowID) \(cgImage.width)x\(cgImage.height) in \(ms, format: .fixed(precision: 1))ms")
            return image
        } catch {
            failures[windowID, default: 0] += 1
            sessionFailures += 1
            Self.logger.debug("thumb capture failed wid=\(windowID): \(error.localizedDescription, privacy: .public)")
            return cache[windowID]?.image
        }
    }

    // On a cold cache, every visible cell hits this at once. Without
    // coalescing, each one sees `shareable.isEmpty` before any of the others
    // finish awaiting and fires its own redundant SCShareableContent fetch —
    // observed as 9 concurrent fetches on a single palette open, each slower
    // than the last from contention, delaying every capture behind them.
    private var refreshTask: Task<Void, Never>?

    private func ensureShareableContentFresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await self.refreshShareableContent() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func refreshShareableContent() async {
        guard CGPreflightScreenCaptureAccess() else {
            shareable = [:]
            return
        }
        let start = DispatchTime.now()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            shareable = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
            shareableFetchedAt = Date()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Self.logger.debug("thumb shareable: \(self.shareable.count) windows in \(ms, format: .fixed(precision: 1))ms")
        } catch {
            shareable = [:]
            Self.logger.error("thumb shareable failed: \(error.localizedDescription, privacy: .public)")
            // Preflight said yes but SCK refused — the classic "granted but not
            // yet applied to this process" state.
            await MainActor.run { ScreenRecordingPermissionManager.shared.noteCaptureDeniedByFramework() }
        }
    }

    private func store(_ image: NSImage, for windowID: CGWindowID) {
        cache[windowID] = Entry(image: image, capturedAt: Date())
        touch(windowID)
        while lru.count > Self.maxCacheEntries, let evict = lru.first {
            lru.removeFirst()
            cache.removeValue(forKey: evict)
        }
    }

    private func touch(_ windowID: CGWindowID) {
        lru.removeAll { $0 == windowID }
        lru.append(windowID)
    }

    // MARK: Concurrency permits

    private func acquirePermit(priority: Bool) async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            if priority {
                priorityWaiters.append(continuation)
            } else {
                waiters.append(continuation)
            }
        }
    }

    private func releasePermit() {
        if !priorityWaiters.isEmpty {
            priorityWaiters.removeFirst().resume()
        } else if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            permits += 1
        }
    }
}
