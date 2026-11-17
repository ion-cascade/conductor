import Foundation

/// Time for bounded AX polling. Operation deadlines and evidence timestamps
/// belong to their callers and use their own clocks.
struct AXPollingClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (Duration) async throws -> Void

    static let continuous = Self(
        now: { .now },
        sleep: { try await Task.sleep(for: $0) }
    )
}
