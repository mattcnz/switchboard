import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PaletteMetrics: ObservableObject {
    @Published var thumbnailWidth: CGFloat
    init(thumbnailWidth: CGFloat) {
        self.thumbnailWidth = thumbnailWidth
    }
}

// User-resized panel dimensions, so a drag-resize survives close/reopen.
private enum PanelSizeStore {
    private static let widthKey = "panel.width"
    private static let heightKey = "panel.height"

    static func load(defaults: UserDefaults = .standard) -> NSSize? {
        let width = defaults.double(forKey: widthKey)
        let height = defaults.double(forKey: heightKey)
        guard width > 0, height > 0 else { return nil }
        return NSSize(width: width, height: height)
    }

    static func save(_ size: NSSize, defaults: UserDefaults = .standard) {
        defaults.set(size.width, forKey: widthKey)
        defaults.set(size.height, forKey: heightKey)
    }
}

@MainActor
final class FloatingPanelController {
    private var panel: FloatingPanel?
    private let sourceProvider: () -> [any SwitchItemSource]
    private let activator: WindowActivator
    private let thumbnailProvider: WindowThumbnailProvider
    private let previewsRequested: () -> Bool

    init(
        sourceProvider: @escaping () -> [any SwitchItemSource],
        activator: WindowActivator,
        thumbnailProvider: WindowThumbnailProvider,
        previewsRequested: @escaping () -> Bool
    ) {
        self.sourceProvider = sourceProvider
        self.activator = activator
        self.thumbnailProvider = thumbnailProvider
        self.previewsRequested = previewsRequested
    }

    func toggle() {
        if let p = panel, p.isVisible {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        // Warm the window list before the first cell asks for a thumbnail.
        let provider = thumbnailProvider
        Task { await provider.beginSession() }

        let viewModel = PaletteViewModel(sources: sourceProvider()) { [weak self] item in
            self?.activate(item)
        }

        let screen = targetScreen()
        let visible = screen.visibleFrame
        let defaultSize = NSSize(width: min(900, visible.width - 80), height: min(600, visible.height - 120))
        // Small enough that 4 columns still fit sanely; large enough that the
        // search bar and "no matches" text don't cramp.
        let minSize = NSSize(width: 640, height: 420)
        let maxSize = NSSize(width: visible.width - 40, height: visible.height - 40)

        var size = PanelSizeStore.load() ?? defaultSize
        size.width = min(max(size.width, minSize.width), maxSize.width)
        size.height = min(max(size.height, minSize.height), maxSize.height)

        let metrics = PaletteMetrics(thumbnailWidth: PaletteLayout.thumbnailWidth(forPanelWidth: size.width))

        let contentView = CommandPaletteView(
            viewModel: viewModel,
            screenPermission: .shared,
            metrics: metrics,
            previewsRequested: previewsRequested(),
            thumbnailProvider: thumbnailProvider,
            onDismiss: { [weak self] in self?.hide() }
        )

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = minSize
        panel.maxSize = maxSize
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // shadow handled in SwiftUI view
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: contentView)
        hosting.layer?.cornerRadius = 16
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        centerPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hide()
            }
        }

        // Only on drag-resize completion, not continuously mid-drag — firing
        // a recapture on every intermediate frame would hammer ScreenCaptureKit.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak panel] _ in
            guard let panel else { return }
            let newSize = panel.frame.size
            Task { @MainActor in
                PanelSizeStore.save(newSize)
                metrics.thumbnailWidth = PaletteLayout.thumbnailWidth(forPanelWidth: newSize.width)
            }
        }

        Task {
            await viewModel.loadItems()
        }
    }

    func hide() {
        panel?.close()
        panel = nil
        let provider = thumbnailProvider
        Task { await provider.endSession() }
    }

    private func activate(_ item: SwitchItem) {
        hide()
        activator.activate(item)
    }

    private func targetScreen() -> NSScreen {
        NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func centerPanel(_ panel: NSPanel) {
        let sf = targetScreen().visibleFrame
        let pw = panel.frame.width
        let ph = panel.frame.height
        let x = sf.midX - pw / 2
        let y = sf.midY - ph / 2 + sf.height * 0.08
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
