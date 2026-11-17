import Foundation
@testable import LogicProMCP

/// Move this fixture's polling clock through every interval without waiting
/// on the host. A cancelled polling call still throws like the live clock.
final class AXTestPollingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var clock: AXPollingClock {
        AXPollingClock(
            now: { self.lock.withLock { self.instant } },
            sleep: { interval in
                self.lock.withLock { self.instant += interval }
                try Task.checkCancellation()
            }
        )
    }
}
