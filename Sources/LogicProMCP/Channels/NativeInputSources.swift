import Foundation

/// HIToolbox aborts a command-line process when TIS/TSM is entered concurrently
/// from different threads. Keep every native input-source read/selection under
/// the same process-wide lock, including failure-diagnostic reads.
enum NativeInputSources {
    private static let lock = NSRecursiveLock()

    static func withExclusiveAccess<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
