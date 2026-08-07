import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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

        let contentView = CommandPaletteView(
            viewModel: viewModel,
            screenPermission: .shared,
            previewsRequested: previewsRequested(),
            thumbnailProvider: thumbnailProvider,
            onDismiss: { [weak self] in self?.hide() }
        )

        let screen = targetScreen()
        let visible = screen.visibleFrame
        let panel = FloatingPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: min(900, visible.width - 80),
                height: min(600, visible.height - 120)
            ),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
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
