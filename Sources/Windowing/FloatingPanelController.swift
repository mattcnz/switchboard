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

    init(sourceProvider: @escaping () -> [any SwitchItemSource], activator: WindowActivator) {
        self.sourceProvider = sourceProvider
        self.activator = activator
    }

    func toggle() {
        if let p = panel, p.isVisible {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        let viewModel = PaletteViewModel(sources: sourceProvider()) { [weak self] item in
            self?.activate(item)
        }

        let contentView = CommandPaletteView(
            viewModel: viewModel,
            onDismiss: { [weak self] in self?.hide() }
        )

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
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
    }

    private func activate(_ item: SwitchItem) {
        hide()
        activator.activate(item)
    }

    private func centerPanel(_ panel: NSPanel) {
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main ?? NSScreen.screens[0]

        let sf = screen.visibleFrame
        let pw = panel.frame.width
        let ph = panel.frame.height
        let x = sf.midX - pw / 2
        let y = sf.midY - ph / 2 + sf.height * 0.08
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
