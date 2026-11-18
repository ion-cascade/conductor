import Foundation

/// The measured Controls slider has coarse ten-position actions and a fine
/// one-position attribute action. Acknowledgment alone never advances the walk.
@MainActor
enum RetroSynthWalk {
    enum Outcome: Equatable {
        case verified(steps: Int)
        case refused
        case uncertain
    }

    static func apply(
        destination: Int,
        read: () throws -> Int,
        permitted: () -> Bool,
        actuate: (_ next: Int, _ coarse: Bool) throws -> Void,
        afterFirstEffect: () async -> Void,
        pause: () async throws -> Void
    ) async -> Outcome {
        guard (0...500).contains(destination), permitted(), let initial = try? read(),
              (0...500).contains(initial) else { return .refused }
        var current = initial
        var steps = 0
        while current != destination {
            guard steps < 120, !Task.isCancelled, permitted(), (try? read()) == current else {
                return steps == 0 ? .refused : .uncertain
            }
            let delta = destination - current
            let amount = abs(delta) >= 10 ? 10 : 1
            let next = current + (delta > 0 ? amount : -amount)
            do { try actuate(next, amount == 10) }
            catch { return steps == 0 ? .refused : .uncertain }
            steps += 1
            if steps == 1 { await afterFirstEffect() }
            var verified = false
            for _ in 0..<6 {
                do { try await pause() }
                catch { return .uncertain }
                guard permitted(), !Task.isCancelled else { return .uncertain }
                guard let observed = try? read() else { continue }
                if observed == next { current = next; verified = true; break }
                if observed != current { return .uncertain }
            }
            guard verified else { return .uncertain }
        }
        guard permitted(), (try? read()) == destination else { return steps == 0 ? .refused : .uncertain }
        return .verified(steps: steps)
    }
}
