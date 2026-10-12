import Foundation

// NSAppleScript is not thread-safe, and the tab sources are separate actors
// that fetch concurrently (plus activations on main). Every script goes
// through this one lock so at most one executes at a time.
enum AppleScriptRunner {
    private static let lock = NSLock()

    @discardableResult
    static func run(_ source: String, error: inout NSDictionary?) -> NSAppleEventDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}
