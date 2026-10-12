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
        let termBytes = queryTerms.map { Array($0.utf8) }
        let learnedKey = context.queryChoices[normalizedQuery]

        return prepared
            .enumerated()
            .compactMap { index, candidate -> Row? in
                guard let score = score(candidate: candidate, query: normalizedQuery, queryTerms: queryTerms, termBytes: termBytes) else {
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

    private static func score(candidate: PreparedItem, query: String, queryTerms: [String], termBytes: [[UInt8]]) -> Int? {
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

        // Abbreviations ("chrm", "vsc", "gh pr"): every term must match as a
        // subsequence. Quality-scored, but always below the substring tiers.
        guard !termBytes.isEmpty else { return nil }
        var total = 0
        for term in termBytes {
            guard let match = fuzzyMatch(term, in: candidate.bytes) else { return nil }
            total += match.score
        }
        return min(total, fuzzyTierCeiling)
    }

    // MARK: Subsequence matching

    private static let fuzzyTierCeiling = 50
    private static let boundaryBonus = 8
    private static let consecutiveBonus = 4
    // Skipping letters inside one word is cheap ("grcr" → groceries);
    // jumping across words costs more, or a long title could collect word-start
    // bonuses from unrelated words and outrank a tight in-word match.
    private static let inWordGapPenalty = 1
    private static let crossWordGapPenalty = 4
    private static let space = UInt8(ascii: " ")

    // Best-scoring placement of `term` as a subsequence of `text`, preferring
    // word starts and runs of adjacent characters. Matches too scattered to
    // be intentional (score under 2 per character) are rejected outright —
    // short queries are a subsequence of nearly every long title.
    //
    // DP over (term char, text position). Gap penalties are flat per kind, so
    // the best gapped predecessors are running maxes and the pass is O(m·n).
    static func fuzzyMatch(
        _ term: [UInt8],
        in text: [UInt8],
        trackPositions: Bool = false
    ) -> (score: Int, positions: [Int])? {
        let m = term.count, n = text.count
        guard m > 0, m <= n, isSubsequence(term, of: text) else { return nil }

        // Int.min-ish sentinel instead of Int? cells: this is the hot loop.
        let none = Int.min / 2
        var prev = [Int](repeating: none, count: n)
        var cur = [Int](repeating: none, count: n)
        // parents[i][j]: text position of term[i-1] in the best path to (i, j).
        var parents = trackPositions ? [[Int]](repeating: [Int](repeating: -1, count: n), count: m) : []

        for i in 0..<m {
            let target = term[i]
            // Best prev[k] over k <= j-2, split by whether k is in the same
            // word as j (cheap gap) or an earlier word (expensive gap).
            var runWord = none, runWordAt = -1
            var runAny = none, runAnyAt = -1
            for j in 0..<n {
                let byte = text[j]
                var score = none
                if byte == target {
                    let charScore = 1 + ((j == 0 || text[j - 1] == space) ? boundaryBonus : 0)
                    if i == 0 {
                        score = charScore
                    } else {
                        var from = -1
                        if j > 0, prev[j - 1] > none {
                            score = prev[j - 1] + consecutiveBonus
                            from = j - 1
                        }
                        if runWord > none, runWord - inWordGapPenalty > score {
                            score = runWord - inWordGapPenalty
                            from = runWordAt
                        }
                        if runAny > none, runAny - crossWordGapPenalty > score {
                            score = runAny - crossWordGapPenalty
                            from = runAnyAt
                        }
                        if score > none {
                            score += charScore
                            if trackPositions { parents[i][j] = from }
                        }
                    }
                }
                cur[j] = score
                if j > 0, prev[j - 1] > runWord {
                    runWord = prev[j - 1]
                    runWordAt = j - 1
                }
                // Leaving a word: its candidates become cross-word from here on.
                if byte == space {
                    if runWord > runAny {
                        runAny = runWord
                        runAnyAt = runWordAt
                    }
                    runWord = none
                    runWordAt = -1
                }
            }
            swap(&prev, &cur)
        }

        var best = none
        var bestAt = -1
        for j in 0..<n where prev[j] > best {
            best = prev[j]
            bestAt = j
        }
        guard best >= 2 * m else { return nil }

        var positions: [Int] = []
        if trackPositions {
            var j = bestAt
            for i in stride(from: m - 1, through: 0, by: -1) {
                positions.append(j)
                j = parents[i][j]
            }
            positions.reverse()
        }
        return (best, positions)
    }

    private static func isSubsequence(_ term: [UInt8], of text: [UInt8]) -> Bool {
        var i = 0
        for byte in text where byte == term[i] {
            i += 1
            if i == term.count { return true }
        }
        return false
    }

    // MARK: Highlighting

    // Character offsets in `title` to emphasise for `query`. Each term is
    // matched against the title alone (not app name / bundle id), so a
    // result that matched elsewhere simply shows no highlight.
    static func highlightOffsets(in title: String, query: String) -> Set<Int> {
        let terms = normalize(query).split(separator: " ").map { Array($0.utf8) }
        guard !terms.isEmpty else { return [] }

        // One byte per Character so offsets map straight back to the title:
        // ASCII alphanumerics after folding, a space for everything else.
        let bytes: [UInt8] = title.map { character in
            let folded = String(character)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            guard folded.unicodeScalars.count == 1, let scalar = folded.unicodeScalars.first,
                  (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") else {
                return space
            }
            return UInt8(scalar.value)
        }

        var offsets = Set<Int>()
        for term in terms {
            if let range = firstRange(of: term, in: bytes) {
                offsets.formUnion(range)
            } else if let match = fuzzyMatch(term, in: bytes, trackPositions: true) {
                offsets.formUnion(match.positions)
            }
        }
        return offsets
    }

    private static func firstRange(of term: [UInt8], in text: [UInt8]) -> Range<Int>? {
        guard term.count <= text.count else { return nil }
        for start in 0...(text.count - term.count) where text[start..<(start + term.count)].elementsEqual(term) {
            return start..<(start + term.count)
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
