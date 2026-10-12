import XCTest

@MainActor
final class RecencyKeyTests: XCTestCase {
    // MARK: Tabs

    func testTabKeyIgnoresFragmentTrackingAndTrailingSlash() {
        let a = RecencyKey.tab(browser: "chrome", url: "https://www.GitHub.com/mattcnz/switchboard/?utm_source=x#readme", fallback: "f")
        let b = RecencyKey.tab(browser: "chrome", url: "https://github.com/mattcnz/switchboard", fallback: "f")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "tab:chrome:url:github.com/mattcnz/switchboard")
    }

    func testTabKeyKeepsMeaningfulQuery() {
        let a = RecencyKey.tab(browser: "chrome", url: "https://youtube.com/watch?v=abc", fallback: "f")
        let b = RecencyKey.tab(browser: "chrome", url: "https://youtube.com/watch?v=xyz", fallback: "f")
        XCTAssertNotEqual(a, b)
    }

    func testNonWebTabsUseFallback() {
        XCTAssertEqual(RecencyKey.tab(browser: "chrome", url: "chrome://newtab/", fallback: "tab:chrome:42"), "tab:chrome:42")
        XCTAssertEqual(RecencyKey.tab(browser: "safari", url: "", fallback: "tab:safari:Start"), "tab:safari:Start")
    }

    // MARK: Windows

    func testTitleStemStripsVolatileDecorations() {
        XCTAssertEqual(RecencyKey.titleStem("(3) Inbox", bundleID: nil), "Inbox")
        XCTAssertEqual(RecencyKey.titleStem("● notes.txt", bundleID: nil), "notes.txt")
        XCTAssertEqual(RecencyKey.titleStem("Report.pages — Edited", bundleID: nil), "Report.pages")
        XCTAssertEqual(RecencyKey.titleStem("Groceries", bundleID: nil), "Groceries")
    }

    func testEditorWindowsKeyByProject() {
        let a = RecencyKey.window(bundleID: "com.microsoft.VSCode", appName: "Code",
                                  title: "FuzzySearch.swift — switchboard", cgWindowID: 1)
        let b = RecencyKey.window(bundleID: "com.microsoft.VSCode", appName: "Code",
                                  title: "● Makefile — switchboard", cgWindowID: 2)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "win:com.microsoft.VSCode:switchboard")
    }

    func testBrowserWindowsKeyByWindowID() {
        let a = RecencyKey.window(bundleID: "com.google.Chrome", appName: "Chrome", title: "Gmail", cgWindowID: 77)
        let b = RecencyKey.window(bundleID: "com.google.Chrome", appName: "Chrome", title: "YouTube", cgWindowID: 77)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "win:com.google.Chrome:#77")
    }

    func testStemNeverEmpty() {
        XCTAssertEqual(RecencyKey.titleStem("●", bundleID: nil), "●")
    }

    // MARK: Migration

    func testMigrationMergesCollapsedKeysAndRewritesQueryChoices() {
        let suite = "switchboard.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set([
            "win:com.apple.TextEdit:● notes.txt": [1.0, 3.0],
            "win:com.apple.TextEdit:notes.txt": [2.0],
            "tab:chrome:12345": [4.0],
            "win:com.google.Chrome:Gmail": [5.0],
        ], forKey: "recents.activationsByKey")
        defaults.set(["notes": ["key": "win:com.apple.TextEdit:● notes.txt", "at": 1.0]], forKey: "recents.queryChoices")

        RecentsStore.migrateKeysIfNeeded(defaults: defaults)

        let activations = defaults.dictionary(forKey: "recents.activationsByKey") as? [String: [TimeInterval]]
        XCTAssertEqual(activations?["win:com.apple.TextEdit:notes.txt"], [1.0, 2.0, 3.0])
        XCTAssertNil(activations?["win:com.apple.TextEdit:● notes.txt"])
        XCTAssertEqual(activations?["tab:chrome:12345"], [4.0])
        XCTAssertEqual(activations?["win:com.google.Chrome:Gmail"], [5.0])

        let choices = defaults.dictionary(forKey: "recents.queryChoices") as? [String: [String: Any]]
        XCTAssertEqual(choices?["notes"]?["key"] as? String, "win:com.apple.TextEdit:notes.txt")
        XCTAssertEqual(defaults.integer(forKey: "recents.keyVersion"), RecencyKey.version)

        // Idempotent: a second run must not touch anything.
        defaults.set(["win:com.apple.TextEdit:● x": [9.0]], forKey: "recents.activationsByKey")
        RecentsStore.migrateKeysIfNeeded(defaults: defaults)
        XCTAssertNotNil((defaults.dictionary(forKey: "recents.activationsByKey") as? [String: [TimeInterval]])?["win:com.apple.TextEdit:● x"])
    }
}
