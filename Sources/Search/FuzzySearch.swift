import Foundation

// Everything ranking needs, snapshotted once per palette open. Passing this in
// keeps FuzzySearch a pure function — no UserDefaults reads per keystroke.
struct RankingContext {
    let frecency: [String: Double]          // recencyKey -> score
    let queryChoices: [String: String]      // normalized query -> recencyKey
    let mruRanks: [String: Int]             // item.id -> rank (0 = most recent)
    let currentWindowID: String?

    static let empty = RankingContext(
        frecency: [:], queryChoices: [:], mruRanks: [:], currentWindowID: nil
    )
}

enum FuzzySearch {
    // Precomputed sort keys: comparators run O(m log m) times, so they compare
    // stored values rather than re-hashing dictionary keys.
    private struct Row {
        let item: SwitchItem
        let learned: Bool       // previously chosen for this exact query
        let isCurrent: Bool     // the window the user is already in
        let score: Int
        let frecency: Double
        let mru: Int
        let index: Int
    }

    static func rank(
        _ prepared: [PreparedItem],
        query: String,
        context: RankingContext
    ) -> [SwitchItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return sortForEmptyQuery(prepared, context: context)
        }

        let normalizedQuery = normalize(trimmedQuery)
        let queryTerms = normalizedQuery.split(separator: " ").map(String.init)
        let learnedKey = context.queryChoices[normalizedQuery]

        return prepared
            .enumerated()
            .compactMap { index, candidate -> Row? in
                guard let score = score(candidate: candidate, query: normalizedQuery, queryTerms: queryTerms) else {
                    return nil
                }
                let item = candidate.item
                return Row(
                    item: item,
                    learned: learnedKey != nil && item.recencyKey == learnedKey,
                    isCurrent: false,
                    score: score,
                    frecency: context.frecency[item.recencyKey] ?? 0,
                    mru: context.mruRanks[item.id] ?? Int.max,
                    index: index
                )
            }
            .sorted { lhs, rhs in
                // What you picked last time you typed exactly this wins outright.
                if lhs.learned != rhs.learned { return lhs.learned }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.frecency != rhs.frecency { return lhs.frecency > rhs.frecency }
                if lhs.mru != rhs.mru { return lhs.mru < rhs.mru }
                return lhs.index < rhs.index
            }
            .map(\.item)
    }

    // Cmd-Tab semantics: the previous window is first (bare Enter flips back
    // to it), other windows follow in MRU order, non-window items and
    // never-focused windows rank by frecency, and the window you're in right
    // now sinks to the bottom — you never switch to where you already are.
    private static func sortForEmptyQuery(
        _ prepared: [PreparedItem],
        context: RankingContext
    ) -> [SwitchItem] {
        prepared
            .enumerated()
            .map { index, candidate -> Row in
                let item = candidate.item
                return Row(
                    item: item,
                    learned: false,
                    isCurrent: item.id == context.currentWindowID,
                    score: 0,
                    frecency: context.frecency[item.recencyKey] ?? 0,
                    mru: context.mruRanks[item.id] ?? Int.max,
                    index: index
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return rhs.isCurrent }
                if lhs.mru != rhs.mru { return lhs.mru < rhs.mru }
                if lhs.frecency != rhs.frecency { return lhs.frecency > rhs.frecency }
                return lhs.index < rhs.index
            }
            .map(\.item)
    }

    private static func score(candidate: PreparedItem, query: String, queryTerms: [String]) -> Int? {
        if candidate.fullText.contains(query) { return 120 }

        if !queryTerms.isEmpty && queryTerms.allSatisfy({ candidate.fullText.contains($0) }) {
            let prefixMatches = queryTerms.filter { term in
                candidate.terms.contains { $0.hasPrefix(term) }
            }.count
            return 90 + prefixMatches
        }

        if candidate.bundleID.contains(query) {
            return 55
        }

        return nil
    }

    // Case/diacritic-folded, with every run of non-alphanumerics collapsed to a
    // single space. Hand-rolled rather than regex: this runs over every item's
    // text at load time, and NSRegularExpression dominated that cost.
    static func normalize(_ value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        var out = ""
        out.reserveCapacity(folded.count)
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }
}
