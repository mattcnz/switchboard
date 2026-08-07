import Foundation

// Reads are cached in memory: the palette used to deep-cast these UserDefaults
// dictionaries on every keystroke, and they only change on activation.
@MainActor
enum RecentsStore {
    private static let activationsKey = "recents.activationsByKey"
    private static let legacyKey = "recents.lastActivatedByID"
    private static let queryChoicesKey = "recents.queryChoices"
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    private static let maxTimestampsPerKey = 10
    private static let maxQueryChoices = 300

    private static var activationsCache: [String: [TimeInterval]]?
    private static var queryChoicesCache: [String: String]?

    // MARK: Activations → frecency

    static func markActivated(_ key: String, at date: Date = Date(), defaults: UserDefaults = .standard) {
        var activations = allActivations(defaults: defaults)
        var stamps = activations[key] ?? []
        stamps.append(date.timeIntervalSince1970)
        if stamps.count > maxTimestampsPerKey {
            stamps.removeFirst(stamps.count - maxTimestampsPerKey)
        }
        activations[key] = stamps

        // Prune stale entries so the dictionary doesn't grow without bound.
        let cutoff = date.timeIntervalSince1970 - maxAge
        activations = activations.compactMapValues { timestamps in
            let kept = timestamps.filter { $0 >= cutoff }
            return kept.isEmpty ? nil : kept
        }
        defaults.set(activations, forKey: activationsKey)
        activationsCache = activations
    }

    // Frequency weighted by age: a window you jump to constantly outranks one
    // you touched once more recently, but everything decays over days.
    static func frecencyScores(now: Date = Date(), defaults: UserDefaults = .standard) -> [String: Double] {
        let nowTimestamp = now.timeIntervalSince1970
        return allActivations(defaults: defaults).mapValues { timestamps in
            timestamps.reduce(0) { $0 + weight(age: nowTimestamp - $1) }
        }
    }

    private static func weight(age: TimeInterval) -> Double {
        switch age {
        case ..<3600: return 100          // past hour
        case ..<86400: return 60          // past day
        case ..<(3 * 86400): return 30    // past 3 days
        case ..<(7 * 86400): return 10    // past week
        default: return 3
        }
    }

    private static func allActivations(defaults: UserDefaults) -> [String: [TimeInterval]] {
        if let activationsCache { return activationsCache }

        if let dict = defaults.dictionary(forKey: activationsKey) as? [String: [TimeInterval]] {
            activationsCache = dict
            return dict
        }
        // One-time migration from the single-timestamp format.
        if let legacy = defaults.dictionary(forKey: legacyKey) as? [String: TimeInterval] {
            let migrated = legacy.mapValues { [$0] }
            defaults.set(migrated, forKey: activationsKey)
            defaults.removeObject(forKey: legacyKey)
            activationsCache = migrated
            return migrated
        }
        activationsCache = [:]
        return [:]
    }

    // MARK: Query learning ("you typed this and picked that")

    static func recordQueryChoice(query: String, key: String, at date: Date = Date(), defaults: UserDefaults = .standard) {
        guard !query.isEmpty else { return }
        var choices = defaults.dictionary(forKey: queryChoicesKey) as? [String: [String: Any]] ?? [:]
        choices[query] = ["key": key, "at": date.timeIntervalSince1970]

        if choices.count > maxQueryChoices {
            let oldestFirst = choices.sorted {
                (($0.value["at"] as? TimeInterval) ?? 0) < (($1.value["at"] as? TimeInterval) ?? 0)
            }
            for (staleQuery, _) in oldestFirst.prefix(choices.count - maxQueryChoices) {
                choices.removeValue(forKey: staleQuery)
            }
        }
        defaults.set(choices, forKey: queryChoicesKey)
        queryChoicesCache = nil
    }

    // Flattened query -> recencyKey, cached: the stored form is a nested
    // dictionary whose deep cast is far too expensive to repeat per keystroke.
    static func allQueryChoices(defaults: UserDefaults = .standard) -> [String: String] {
        if let queryChoicesCache { return queryChoicesCache }

        let stored = defaults.dictionary(forKey: queryChoicesKey) as? [String: [String: Any]] ?? [:]
        let flattened = stored.compactMapValues { $0["key"] as? String }
        queryChoicesCache = flattened
        return flattened
    }
}
