import Foundation

enum FuzzySearch {
    static func rank(
        _ items: [SwitchItem],
        query: String,
        mruRanks: [String: Int] = [:],
        currentWindowID: String? = nil
    ) -> [SwitchItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let frecency = RecentsStore.frecencyScores()

        guard !trimmedQuery.isEmpty else {
            return sortForEmptyQuery(
                items, mruRanks: mruRanks, currentWindowID: currentWindowID, frecency: frecency
            )
        }

        let normalizedQuery = normalize(trimmedQuery)
        let queryTerms = normalizedQuery.split(separator: " ").map(String.init)
        let learnedKey = RecentsStore.learnedChoice(for: normalizedQuery)

        return items
            .enumerated()
            .compactMap { index, item -> (item: SwitchItem, score: Int, index: Int)? in
                let candidate = SearchCandidate(item: item)
                guard let score = score(candidate: candidate, query: normalizedQuery, queryTerms: queryTerms) else {
                    return nil
                }
                return (item, score, index)
            }
            .sorted { lhs, rhs in
                // What you picked last time you typed exactly this wins outright.
                let lhsLearned = lhs.item.recencyKey == learnedKey
                let rhsLearned = rhs.item.recencyKey == learnedKey
                if lhsLearned != rhsLearned { return lhsLearned }

                if lhs.score != rhs.score { return lhs.score > rhs.score }

                let lhsFrecency = frecency[lhs.item.recencyKey] ?? 0
                let rhsFrecency = frecency[rhs.item.recencyKey] ?? 0
                if lhsFrecency != rhsFrecency { return lhsFrecency > rhsFrecency }

                let lhsMRU = mruRanks[lhs.item.id] ?? Int.max
                let rhsMRU = mruRanks[rhs.item.id] ?? Int.max
                if lhsMRU != rhsMRU { return lhsMRU < rhsMRU }

                return lhs.index < rhs.index
            }
            .map(\.item)
    }

    // Cmd-Tab semantics: the previous window is first (bare Enter flips back
    // to it), other windows follow in MRU order, non-window items and
    // never-focused windows rank by frecency, and the window you're in right
    // now sinks to the bottom — you never switch to where you already are.
    private static func sortForEmptyQuery(
        _ items: [SwitchItem],
        mruRanks: [String: Int],
        currentWindowID: String?,
        frecency: [String: Double]
    ) -> [SwitchItem] {
        items
            .enumerated()
            .sorted { lhs, rhs in
                let lhsCurrent = lhs.element.id == currentWindowID
                let rhsCurrent = rhs.element.id == currentWindowID
                if lhsCurrent != rhsCurrent { return rhsCurrent }

                let lhsMRU = mruRanks[lhs.element.id] ?? Int.max
                let rhsMRU = mruRanks[rhs.element.id] ?? Int.max
                if lhsMRU != rhsMRU { return lhsMRU < rhsMRU }

                let lhsFrecency = frecency[lhs.element.recencyKey] ?? 0
                let rhsFrecency = frecency[rhs.element.recencyKey] ?? 0
                if lhsFrecency != rhsFrecency { return lhsFrecency > rhsFrecency }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
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

    static func normalize(_ value: String) -> String {
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
