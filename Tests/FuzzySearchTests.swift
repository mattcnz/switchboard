import XCTest

@MainActor
final class FuzzySearchTests: XCTestCase {
    private func item(_ app: String, _ title: String, bundle: String? = nil, id: String? = nil) -> SwitchItem {
        SwitchItem(
            id: id ?? "\(app):\(title)",
            kind: .window,
            appName: app,
            appBundleID: bundle,
            title: title,
            icon: nil,
            pid: nil,
            axWindow: nil
        )
    }

    private let corpus: [SwitchItem] = [
        SwitchItem(id: "chrome", kind: .window, appName: "Google Chrome", appBundleID: "com.google.Chrome",
                   title: "Inbox — Gmail", icon: nil, pid: nil, axWindow: nil),
        SwitchItem(id: "code", kind: .window, appName: "Visual Studio Code", appBundleID: "com.microsoft.VSCode",
                   title: "FuzzySearch.swift — switchboard", icon: nil, pid: nil, axWindow: nil),
        SwitchItem(id: "pr", kind: .browserTab, appName: "Chrome", appBundleID: "com.google.Chrome",
                   title: "Add fuzzy matching · Pull Request #12 · mattcnz/switchboard", icon: nil, pid: nil, axWindow: nil),
        SwitchItem(id: "notes", kind: .window, appName: "Notes", appBundleID: "com.apple.Notes",
                   title: "Groceries", icon: nil, pid: nil, axWindow: nil),
        SwitchItem(id: "term", kind: .window, appName: "Terminal", appBundleID: "com.apple.Terminal",
                   title: "zsh — 80×24", icon: nil, pid: nil, axWindow: nil),
    ]

    private func rank(_ query: String, context: RankingContext = .empty) -> [String] {
        FuzzySearch.rank(SearchIndex.shared.prepare(corpus), query: query, context: context).map(\.id)
    }

    // MARK: Existing tiers

    func testSubstringMatchesRankFirst() {
        XCTAssertEqual(rank("groceries").first, "notes")
        XCTAssertEqual(rank("gmail").first, "chrome")
    }

    func testEmptyQueryReturnsEverything() {
        XCTAssertEqual(Set(rank("")), Set(corpus.map(\.id)))
    }

    func testNoMatchReturnsNothing() {
        XCTAssertEqual(rank("xylophone"), [])
    }

    // MARK: Fuzzy

    func testAbbreviationsMatch() {
        XCTAssertEqual(rank("chrm").first.map { ["chrome", "pr"].contains($0) }, true)
        XCTAssertEqual(rank("vsc").first, "code")
        XCTAssertEqual(rank("grcr").first, "notes")
    }

    func testMultiTermAbbreviation() {
        XCTAssertEqual(rank("pr swtch").first, "pr")
    }

    func testAcronymPrefersWordStarts() {
        // "gc" hits the word starts of "Google Chrome".
        XCTAssertEqual(rank("gc").first, "chrome")
    }

    func testSubstringOutranksFuzzy() {
        let items = [
            item("App", "s w i t c h scattered", id: "scattered"),
            item("App", "switch exact", id: "exact"),
        ]
        let ranked = FuzzySearch.rank(SearchIndex.shared.prepare(items), query: "switch", context: .empty)
        XCTAssertEqual(ranked.first?.id, "exact")
    }

    func testScatteredNoiseIsRejected() {
        // Every letter of "abc" appears, but only mid-word and far apart.
        let items = [item("Xyz", "xxaxxxxxxbxxxxxxxxcxx", id: "noise")]
        XCTAssertTrue(FuzzySearch.rank(SearchIndex.shared.prepare(items), query: "abc", context: .empty).isEmpty)
    }

    func testFuzzyMatchPrefersBoundariesAndRuns() {
        let text = Array("visual studio code".utf8)
        let match = FuzzySearch.fuzzyMatch(Array("vsc".utf8), in: text, trackPositions: true)
        XCTAssertEqual(match?.positions, [0, 7, 14])
    }

    func testFuzzyRankingStaysFastAtScale() {
        // ~5x a heavy real session (memory notes ~100 items typical).
        let words = ["project", "review", "github", "inbox", "terminal", "notes", "design", "budget", "meeting", "draft"]
        let items = (0..<500).map { i in
            item("App\(i % 17)", "\(words[i % 10]) \(words[(i * 7) % 10]) document \(i) — some longer window title text",
                 bundle: "com.example.app\(i % 17)", id: "i\(i)")
        }
        let prepared = SearchIndex.shared.prepare(items)
        let queries = ["p", "pr", "prj", "prjr", "prjrv", "gh in", "zzqx"]
        let start = DispatchTime.now()
        for query in queries { _ = FuzzySearch.rank(prepared, query: query, context: .empty) }
        let msPerKeystroke = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000 / Double(queries.count)
        print("fuzzy rank: \(String(format: "%.2f", msPerKeystroke))ms/keystroke over \(items.count) items")
        // Debug (-Onone) measures ~8ms here; Release ~2ms. The bound only
        // catches order-of-magnitude regressions, not noise.
        XCTAssertLessThan(msPerKeystroke, 25)
    }

    // MARK: Learning / recency

    func testLearnedChoiceWinsOutright() {
        let notesKey = corpus.first { $0.id == "notes" }!.recencyKey
        let context = RankingContext(frecency: [:], queryChoices: ["o": notesKey], mruRanks: [:], currentWindowID: nil)
        XCTAssertEqual(rank("o", context: context).first, "notes")
    }

    func testFrecencyBreaksTies() {
        let items = [item("App", "alpha one", id: "a"), item("App", "alpha two", id: "b")]
        let context = RankingContext(frecency: ["b": 100], queryChoices: [:], mruRanks: [:], currentWindowID: nil)
        let ranked = FuzzySearch.rank(SearchIndex.shared.prepare(items), query: "alpha", context: context)
        XCTAssertEqual(ranked.map(\.id), ["b", "a"])
    }

    func testEmptyQuerySinksCurrentWindow() {
        let context = RankingContext(frecency: [:], queryChoices: [:], mruRanks: ["notes": 0, "code": 1],
                                     currentWindowID: "notes")
        let ranked = rank("", context: context)
        XCTAssertEqual(ranked.first, "code")
        XCTAssertEqual(ranked.last, "notes")
    }

    // MARK: Highlighting

    func testHighlightSubstring() {
        XCTAssertEqual(FuzzySearch.highlightOffsets(in: "Inbox — Gmail", query: "gmail"), Set(8...12))
    }

    func testHighlightFuzzyAndDiacritics() {
        XCTAssertEqual(FuzzySearch.highlightOffsets(in: "Café Menu", query: "cfm"), [0, 2, 5])
    }

    func testHighlightIgnoresNonTitleMatches() {
        XCTAssertTrue(FuzzySearch.highlightOffsets(in: "Groceries", query: "notes").isEmpty)
    }
}
