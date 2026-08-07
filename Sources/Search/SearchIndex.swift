import Foundation
import OSLog

// An item with its searchable text already normalized. Building these is the
// expensive part of filtering, so it happens once per item, not per keystroke.
struct PreparedItem {
    let item: SwitchItem
    let fullText: String
    let bundleID: String
    let terms: [String]
    let contentHash: Int
}

@MainActor
final class SearchIndex {
    static let shared = SearchIndex()
    private static let logger = Logger(subsystem: "com.mattmilliken.switchboard", category: "SearchIndex")
    private static let maxEntries = 600

    private var cache: [String: PreparedItem] = [:]

    private init() {}

    func prepare(_ items: [SwitchItem]) -> [PreparedItem] {
        let start = DispatchTime.now()
        var misses = 0

        let prepared = items.map { item -> PreparedItem in
            let hash = Self.contentHash(of: item)
            // Ids are stable for a window's lifetime but titles change under
            // them, so a cache hit is only valid when the text still matches.
            if let cached = cache[item.id], cached.contentHash == hash {
                return cached
            }
            misses += 1
            let bundleID = FuzzySearch.normalize(item.appBundleID ?? "")
            let fullText = FuzzySearch.normalize(
                "\(item.appName) \(item.title) \(item.subtitle ?? "") \(bundleID)"
            )
            let entry = PreparedItem(
                item: item,
                fullText: fullText,
                bundleID: bundleID,
                terms: fullText.split(separator: " ").map(String.init),
                contentHash: hash
            )
            cache[item.id] = entry
            return entry
        }

        pruneIfNeeded(keeping: items)

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        Self.logger.debug("index prepared \(items.count) items (\(misses) new) in \(ms, format: .fixed(precision: 2))ms")
        return prepared
    }

    private func pruneIfNeeded(keeping items: [SwitchItem]) {
        guard cache.count > Self.maxEntries else { return }
        let live = Set(items.map(\.id))
        cache = cache.filter { live.contains($0.key) }
    }

    private static func contentHash(of item: SwitchItem) -> Int {
        var hasher = Hasher()
        hasher.combine(item.appName)
        hasher.combine(item.title)
        hasher.combine(item.subtitle)
        hasher.combine(item.appBundleID)
        return hasher.finalize()
    }
}
