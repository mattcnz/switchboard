import Foundation
import CoreGraphics

// Maps items to the window whose preview represents them.
//
// Windows carry their own CGWindowID. A browser/Terminal window renders only
// its ACTIVE tab, so only that tab may inherit the window's preview — the
// others would all show the same misleading picture. Active tabs are matched
// to their window by title: Chrome titles its window "<active tab> - Google
// Chrome", Safari and Terminal use the tab title verbatim.
enum ThumbnailResolver {
    static func map(_ items: [SwitchItem]) -> [String: CGWindowID] {
        var result: [String: CGWindowID] = [:]

        var windowsByBundle: [String: [(title: String, id: CGWindowID)]] = [:]
        for item in items where item.kind == .window {
            guard let windowID = item.cgWindowID else { continue }
            result[item.id] = windowID
            if let bundleID = item.appBundleID {
                windowsByBundle[bundleID, default: []].append((item.title, windowID))
            }
        }

        for item in items where item.kind == .browserTab && item.isActiveTab {
            guard let bundleID = item.appBundleID,
                  let candidates = windowsByBundle[bundleID] else { continue }
            let match = candidates.first { $0.title == item.title }
                ?? candidates.first { $0.title.hasPrefix(item.title) }
                ?? candidates.first { item.title.hasPrefix($0.title) }
            if let match {
                result[item.id] = match.id
            }
        }

        return result
    }
}
