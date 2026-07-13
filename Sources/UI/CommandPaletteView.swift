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
        didSet {
            logger.debug("query updated='\(self.query, privacy: .public)'")
            updateFiltered()
        }
    }
    @Published private(set) var allItems: [SwitchItem] = [] {
        didSet { updateFiltered() }
    }
    @Published private(set) var filteredItems: [SwitchItem] = []
    @Published var selectedIndex: Int = 0

    private let sources: [any SwitchItemSource]
    let onActivate: (SwitchItem) -> Void

    init(sources: [any SwitchItemSource], onActivate: @escaping (SwitchItem) -> Void) {
        self.sources = sources
        self.onActivate = onActivate
    }

    func loadItems() async {
        allItems = []
        var itemsBySource: [Int: [SwitchItem]] = [:]

        func rebuildAllItems() {
            var seenIDs = Set<String>()
            allItems = sources.indices
                .flatMap { itemsBySource[$0] ?? [] }
                .filter { seenIDs.insert($0.id).inserted }
        }

        // Phase 1: cached snapshots render instantly. Phase 2: fresh data
        // replaces each source's slice as it lands, so stale entries never
        // outlive one palette open.
        for phase in [true, false] {
            await withTaskGroup(of: (Int, [SwitchItem]).self) { group in
                for (index, source) in sources.enumerated() {
                    group.addTask {
                        (index, phase ? await source.snapshot() : await source.freshSnapshot())
                    }
                }
                for await (index, items) in group {
                    itemsBySource[index] = items
                    rebuildAllItems()
                    logger.debug("source \(index) \(phase ? "cached" : "fresh"): \(items.count) items, total=\(self.allItems.count)")
                }
            }
        }
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
        onActivate(filteredItems[selectedIndex])
    }

    private func updateFiltered() {
        filteredItems = FuzzySearch.rank(allItems, query: query)
        selectedIndex = 0
        logger.debug("filtered query='\(self.query, privacy: .public)' all=\(self.allItems.count) matches=\(self.filteredItems.count)")
    }
}

struct CommandPaletteView: View {
    @ObservedObject var viewModel: PaletteViewModel
    let onDismiss: () -> Void

    private var resultsListID: String {
        viewModel.query + ":" + viewModel.filteredItems.map(\.id).joined(separator: "|")
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
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.filteredItems.enumerated()), id: \.element.id) { index, item in
                            SearchResultRow(item: item, isSelected: index == viewModel.selectedIndex)
                                .id(index)
                                .onTapGesture {
                                    viewModel.selectedIndex = index
                                    viewModel.activateSelected()
                                }
                        }
                    }
                }
                .id(resultsListID)
                .onChange(of: viewModel.selectedIndex) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
    }
}
