import Foundation

enum FuzzySearch {
    static func rank(_ items: [SwitchItem], query: String) -> [SwitchItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return sortByRecency(items.enumerated().map { (item: $0.element, score: 0, index: $0.offset) })
        }
        let normalizedQuery = normalize(trimmedQuery)
        let queryTerms = normalizedQuery.split(separator: " ").map(String.init)

        let ranked = items
            .enumerated()
            .compactMap { index, item -> (item: SwitchItem, score: Int, index: Int)? in
                let candidate = SearchCandidate(item: item)
                guard let score = score(candidate: candidate, query: normalizedQuery, queryTerms: queryTerms) else {
                    return nil
                }
                return (item, score, index)
            }

        return sortByRecency(ranked)
    }

    private static func score(candidate: SearchCandidate, query: String, queryTerms: [String]) -> Int? {
        if candidate.fullText.contains(query) { return 120 }

        if !queryTerms.isEmpty && queryTerms.allSatisfy(candidate.matches(term:)) {
            let prefixMatches = queryTerms.filter(candidate.matchesPrefix(term:)).count
            return 90 + prefixMatches
        }

        if candidate.bundleID.contains(query) {
            return 55
        }

        return nil
    }

    fileprivate static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: " ",
                options: .regularExpression
            )
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func sortByRecency(_ rankedItems: [(item: SwitchItem, score: Int, index: Int)]) -> [SwitchItem] {
        rankedItems
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }

                let lhsLastActivated = RecentsStore.lastActivatedAt(for: lhs.item.recencyKey) ?? 0
                let rhsLastActivated = RecentsStore.lastActivatedAt(for: rhs.item.recencyKey) ?? 0
                if lhsLastActivated != rhsLastActivated {
                    return lhsLastActivated > rhsLastActivated
                }

                return lhs.index < rhs.index
            }
            .map(\.item)
    }
}

private struct SearchCandidate {
    let fullText: String
    let bundleID: String
    let terms: [String]

    init(item: SwitchItem) {
        let bundleID = FuzzySearch.normalize(item.appBundleID ?? "")
        let fullText = FuzzySearch.normalize("\(item.appName) \(item.title) \(item.subtitle ?? "") \(bundleID)")

        self.fullText = fullText
        self.bundleID = bundleID
        self.terms = fullText.split(separator: " ").map(String.init)
    }

    func matches(term: String) -> Bool {
        fullText.contains(term)
    }

    func matchesPrefix(term: String) -> Bool {
        terms.contains { $0.hasPrefix(term) }
    }
}
