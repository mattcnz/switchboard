import Foundation

enum RecentsStore {
    private static let key = "recents.lastActivatedByID"

    static func markActivated(_ itemID: String, at date: Date = Date(), defaults: UserDefaults = .standard) {
        var timestamps = defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
        timestamps[itemID] = date.timeIntervalSince1970
        defaults.set(timestamps, forKey: key)
    }

    static func lastActivatedAt(for itemID: String, defaults: UserDefaults = .standard) -> TimeInterval? {
        let timestamps = defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
        return timestamps[itemID]
    }
}
