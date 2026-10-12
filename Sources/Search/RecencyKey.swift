import Foundation
import CoreGraphics

// Recency keys outlive the items they describe: frecency and learned query
// choices are stored under them for weeks. They must therefore survive what
// actually changes day to day — tab ids reset when a browser restarts, and
// window titles change with every document, page or unread count.
enum RecencyKey {
    // Bump when the key scheme changes; RecentsStore migrates stored keys.
    static let version = 2

    // MARK: Tabs

    // Keyed by URL, so a tab keeps its history across browser restarts and
    // when it's closed and reopened. Non-web URLs (new tab pages, about:blank)
    // would all collide on one key, so those keep the per-session fallback.
    static func tab(browser: String, url: String, fallback: String) -> String {
        guard let normalized = normalizedURL(url) else { return fallback }
        return "tab:\(browser):url:\(normalized)"
    }

    static func normalizedURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }

        // Fragments and campaign tags don't change what the page is.
        components.fragment = nil
        components.queryItems = components.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bareHost + path + query
    }

    // MARK: Windows

    // Browsers and terminals title their windows after whatever tab/command
    // is active, so the title says nothing durable about the window; those
    // are keyed by window id (stable for the session) instead.
    static let volatileTitleBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.vivaldi.Vivaldi",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    ]

    static let projectLastBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    static func window(bundleID: String?, appName: String, title: String, cgWindowID: CGWindowID?) -> String {
        let app = bundleID ?? appName
        if let bundleID, volatileTitleBundleIDs.contains(bundleID), let cgWindowID {
            return "win:\(app):#\(cgWindowID)"
        }
        return "win:\(app):\(titleStem(title, bundleID: bundleID))"
    }

    // The durable part of a window title: no unread counters, dirty markers
    // or "Edited" suffixes, and for editors that title "file — project", just
    // the project. Falls back to the raw title rather than ever returning "".
    static func titleStem(_ title: String, bundleID: String?) -> String {
        var stem = title.trimmingCharacters(in: .whitespaces)

        if let bundleID, projectLastBundleIDs.contains(bundleID),
           let range = stem.range(of: " — ", options: .backwards) {
            stem = String(stem[range.upperBound...])
        }

        // "(3) Inbox" → "Inbox"
        if let match = stem.range(of: #"^\(\d+\+?\)\s*"#, options: .regularExpression) {
            stem.removeSubrange(match)
        }
        // "● file.swift", "* notes.txt"
        while let first = stem.first, "●•*".contains(first) {
            stem.removeFirst()
            stem = stem.trimmingCharacters(in: .whitespaces)
        }
        for suffix in [" — Edited", " - Edited", " (Edited)", " ●", "*"] where stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
        }
        stem = stem.trimmingCharacters(in: .whitespaces)

        return stem.isEmpty ? title : stem
    }

    // MARK: Migration

    // Rewrites a version-1 key ("win:<app>:<raw title>") to its current form.
    // Everything else passes through unchanged: v1 tab keys never stored the
    // URL and v1 volatile-title window keys never stored the window id, so
    // they can't be upgraded — left alone, they still match until their
    // session ends, then age out of the store.
    static func migrateV1(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "win" else { return key }
        let app = String(parts[1])
        if volatileTitleBundleIDs.contains(app) { return key }
        let bundleID = app.contains(".") ? app : nil
        return "win:\(app):\(titleStem(String(parts[2]), bundleID: bundleID))"
    }
}
