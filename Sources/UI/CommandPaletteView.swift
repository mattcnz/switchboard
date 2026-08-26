import SwiftUI
import AppKit
import CoreGraphics
import OSLog

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onUpArrow: () -> Void
    var onDownArrow: () -> Void
    var onLeftArrow: () -> Void
    var onRightArrow: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        // The panel sits on `.ultraThinMaterial`, which shows whatever's on
        // the desktop through the blur — the system placeholder gray was
        // tuned for a solid background and washes out over light wallpaper.
        // labelColor at partial opacity tracks light/dark mode while still
        // reading clearly over the vibrancy.
        field.placeholderAttributedString = NSAttributedString(
            string: "Search windows…",
            attributes: [
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55),
                .font: NSFont.systemFont(ofSize: 17)
            ]
        )
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Keep closures fresh so the coordinator always calls current captures.
        context.coordinator.onUpArrow = onUpArrow
        context.coordinator.onDownArrow = onDownArrow
        context.coordinator.onLeftArrow = onLeftArrow
        context.coordinator.onRightArrow = onRightArrow
        context.coordinator.onReturn = onReturn
        context.coordinator.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onUpArrow: onUpArrow, onDownArrow: onDownArrow,
                    onLeftArrow: onLeftArrow, onRightArrow: onRightArrow,
                    onReturn: onReturn, onEscape: onEscape)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "SearchField")
        @Binding var text: String
        var onUpArrow: () -> Void
        var onDownArrow: () -> Void
        var onLeftArrow: () -> Void
        var onRightArrow: () -> Void
        var onReturn: () -> Void
        var onEscape: () -> Void

        init(text: Binding<String>, onUpArrow: @escaping () -> Void,
             onDownArrow: @escaping () -> Void, onLeftArrow: @escaping () -> Void,
             onRightArrow: @escaping () -> Void, onReturn: @escaping () -> Void,
             onEscape: @escaping () -> Void) {
            _text = text
            self.onUpArrow = onUpArrow
            self.onDownArrow = onDownArrow
            self.onLeftArrow = onLeftArrow
            self.onRightArrow = onRightArrow
            self.onReturn = onReturn
            self.onEscape = onEscape
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
            logger.debug("controlTextDidChange value='\(field.stringValue, privacy: .public)'")
        }

        // Called by the field editor for command selectors — this is the correct
        // intercept point because the field editor (NSTextView) is the actual
        // first responder while the text field is being edited, so keyDown on
        // the NSTextField subclass never fires.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):      onUpArrow();   return true
            case #selector(NSResponder.moveDown(_:)):    onDownArrow(); return true
            // Grid navigation takes ←/→; ⌥← and ⌘← still edit the query since
            // those arrive as different selectors.
            case #selector(NSResponder.moveLeft(_:)):    onLeftArrow();  return true
            case #selector(NSResponder.moveRight(_:)):   onRightArrow(); return true
            case #selector(NSResponder.insertTab(_:)):   onRightArrow(); return true
            case #selector(NSResponder.insertBacktab(_:)): onLeftArrow(); return true
            case #selector(NSResponder.insertNewline(_:)): onReturn();  return true
            case #selector(NSResponder.cancelOperation(_:)): onEscape(); return true
            default: return false
            }
        }
    }
}

// ViewModel for the palette.
@MainActor
final class PaletteViewModel: ObservableObject {
    private let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "PaletteViewModel")
    @Published var query: String = "" {
        didSet { updateFiltered() }
    }
    @Published private(set) var allItems: [SwitchItem] = []
    @Published private(set) var filteredItems: [SwitchItem] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var thumbnailIDs: [String: CGWindowID] = [:]

    private let sources: [any SwitchItemSource]
    let onActivate: (SwitchItem) -> Void
    private var prepared: [PreparedItem] = []
    // Snapshotted once per open. The panel is non-activating, so focus can't
    // change while it's up — reading this live would be wrong, not just slow.
    private let context: RankingContext

    var selectedItemID: String? {
        filteredItems.indices.contains(selectedIndex) ? filteredItems[selectedIndex].id : nil
    }

    init(sources: [any SwitchItemSource], onActivate: @escaping (SwitchItem) -> Void) {
        self.sources = sources
        self.onActivate = onActivate
        self.context = RankingContext(
            frecency: RecentsStore.frecencyScores(),
            queryChoices: RecentsStore.allQueryChoices(),
            mruRanks: FocusTracker.shared.mruRanks,
            currentWindowID: FocusTracker.shared.currentWindowID
        )
    }

    func loadItems() async {
        var itemsBySource: [Int: [SwitchItem]] = [:]

        func merged() -> [SwitchItem] {
            var seenIDs = Set<String>()
            return sources.indices
                .flatMap { itemsBySource[$0] ?? [] }
                .filter { seenIDs.insert($0.id).inserted }
        }

        // Phase 1: cached snapshots render instantly, applied per source so
        // results appear progressively. Phase 2: fresh data lands in one
        // atomic apply, so stale entries never outlive one palette open.
        for phase in [true, false] {
            await withTaskGroup(of: (Int, [SwitchItem]).self) { group in
                for (index, source) in sources.enumerated() {
                    group.addTask {
                        (index, phase ? await source.snapshot() : await source.freshSnapshot())
                    }
                }
                for await (index, items) in group {
                    itemsBySource[index] = items
                    if phase { applyItems(merged()) }
                }
            }
            if !phase { applyItems(merged()) }
        }
    }

    private func applyItems(_ items: [SwitchItem]) {
        // Phase 2 usually returns exactly what phase 1 did; re-filtering that
        // is pure waste, and it would stomp the selection mid-typing.
        guard items.map(\.id) != allItems.map(\.id) else { return }
        allItems = items
        prepared = SearchIndex.shared.prepare(items)
        thumbnailIDs = ThumbnailResolver.map(items)
        updateFiltered()
    }

    // Grid navigation: ←/→ step one cell, ↑/↓ jump a row. Clamped, no wrap.
    func moveLeft() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
    }

    func moveRight() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = min(filteredItems.count - 1, selectedIndex + 1)
    }

    func moveUp() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - PaletteLayout.columns)
    }

    func moveDown() {
        guard !filteredItems.isEmpty else { return }
        let next = selectedIndex + PaletteLayout.columns
        // From a partial last row, land on the final item rather than nothing.
        selectedIndex = next < filteredItems.count ? next : filteredItems.count - 1
    }

    func activateSelected() {
        guard selectedIndex < filteredItems.count else { return }
        let item = filteredItems[selectedIndex]
        let normalizedQuery = FuzzySearch.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if !normalizedQuery.isEmpty {
            RecentsStore.recordQueryChoice(query: normalizedQuery, key: item.recencyKey)
        }
        onActivate(item)
    }

    func select(id: String) {
        guard let index = filteredItems.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
    }

    private func updateFiltered() {
        let start = DispatchTime.now()
        filteredItems = FuzzySearch.rank(prepared, query: query, context: context)
        // @Published has no equality check; assigning 0 to an already-0 index
        // costs a second full body evaluation.
        if selectedIndex != 0 { selectedIndex = 0 }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        logger.debug("filter q='\(self.query, privacy: .public)' items=\(self.prepared.count) matches=\(self.filteredItems.count) \(ms, format: .fixed(precision: 2))ms")
    }
}

struct CommandPaletteView: View {
    @ObservedObject var viewModel: PaletteViewModel
    @ObservedObject var screenPermission: ScreenRecordingPermissionManager
    @ObservedObject var metrics: PaletteMetrics
    let previewsRequested: Bool
    let thumbnailProvider: WindowThumbnailProvider
    let onDismiss: () -> Void

    private var previewsEnabled: Bool {
        previewsRequested && screenPermission.isGranted && !screenPermission.needsRelaunch
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 16, weight: .medium))
                SearchField(
                    text: $viewModel.query,
                    onUpArrow: { viewModel.moveUp() },
                    onDownArrow: { viewModel.moveDown() },
                    onLeftArrow: { viewModel.moveLeft() },
                    onRightArrow: { viewModel.moveRight() },
                    onReturn: { viewModel.activateSelected() },
                    onEscape: { onDismiss() }
                )
                .frame(height: 24)

                SettingsLink {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Open Settings")
                .simultaneousGesture(TapGesture().onEnded {
                    onDismiss()
                })
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .opacity(0.5)

            resultsGrid

            if previewsRequested && !previewsEnabled {
                // Not a button: the panel hides on resignKey, so anything
                // clickable here would dismiss itself. Settings and the menu
                // bar carry the actionable version.
                Text(screenPermission.needsRelaunch
                     ? "Relaunch Switchboard to enable previews (menu bar → Relaunch)"
                     : "Previews need Screen Recording access — enable it in Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    }

    @ViewBuilder
    private var resultsGrid: some View {
        if viewModel.allItems.isEmpty && viewModel.query.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading windows…").foregroundColor(.secondary)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredItems.isEmpty {
            Text("No matches")
                .foregroundColor(.secondary)
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: PaletteLayout.spacing),
                            count: PaletteLayout.columns
                        ),
                        spacing: PaletteLayout.spacing
                    ) {
                        ForEach(viewModel.filteredItems, id: \.id) { item in
                            SwitchItemCell(
                                item: item,
                                cgWindowID: viewModel.thumbnailIDs[item.id],
                                isSelected: item.id == viewModel.selectedItemID,
                                previewsEnabled: previewsEnabled,
                                captureWidth: metrics.thumbnailWidth,
                                provider: thumbnailProvider
                            )
                            .equatable()
                            .id(item.id)
                            .onTapGesture {
                                viewModel.select(id: item.id)
                                viewModel.activateSelected()
                            }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: viewModel.selectedItemID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
                .onChange(of: viewModel.query) { _, _ in
                    // Unanimated: this fires on every keystroke.
                    if let first = viewModel.filteredItems.first?.id {
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
            }
        }
    }
}
