import SwiftUI
import AppKit
import OSLog

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onUpArrow: () -> Void
    var onDownArrow: () -> Void
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
        field.placeholderString = "Search windows…"
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
        context.coordinator.onReturn = onReturn
        context.coordinator.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onUpArrow: onUpArrow, onDownArrow: onDownArrow,
                    onReturn: onReturn, onEscape: onEscape)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "SearchField")
        @Binding var text: String
        var onUpArrow: () -> Void
        var onDownArrow: () -> Void
        var onReturn: () -> Void
        var onEscape: () -> Void

        init(text: Binding<String>, onUpArrow: @escaping () -> Void,
             onDownArrow: @escaping () -> Void, onReturn: @escaping () -> Void,
             onEscape: @escaping () -> Void) {
            _text = text
            self.onUpArrow = onUpArrow
            self.onDownArrow = onDownArrow
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
        updateFiltered()
    }

    func moveUp() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
    }

    func moveDown() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = min(filteredItems.count - 1, selectedIndex + 1)
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
    let onDismiss: () -> Void

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

            resultsList
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    }

    @ViewBuilder
    private var resultsList: some View {
        if viewModel.allItems.isEmpty && viewModel.query.isEmpty {
            Text("Loading…")
                .foregroundColor(.secondary)
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
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredItems, id: \.id) { item in
                            SearchResultRow(item: item, isSelected: item.id == viewModel.selectedItemID)
                                .equatable()
                                .id(item.id)
                                .onTapGesture {
                                    viewModel.select(id: item.id)
                                    viewModel.activateSelected()
                                }
                        }
                    }
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
