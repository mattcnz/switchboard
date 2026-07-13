import Foundation

enum RecentsStore {
    private static let key = "recents.lastActivatedByID"

    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    static func markActivated(_ itemID: String, at date: Date = Date(), defaults: UserDefaults = .standard) {
        var timestamps = defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
        timestamps[itemID] = date.timeIntervalSince1970
        // Prune stale entries (incl. old volatile-id keys) so the dictionary
        // doesn't grow without bound.
        let cutoff = date.timeIntervalSince1970 - maxAge
        timestamps = timestamps.filter { $0.value >= cutoff }
        defaults.set(timestamps, forKey: key)
    }

    static func lastActivatedAt(for itemID: String, defaults: UserDefaults = .standard) -> TimeInterval? {
        let timestamps = defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
        return timestamps[itemID]
    }
}
