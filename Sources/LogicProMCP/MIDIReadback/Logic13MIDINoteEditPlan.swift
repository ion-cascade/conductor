import Foundation

/// Native Event List coordinates. Position is one-based and elapsed length is zero-based.
struct Logic13MIDINoteCoordinate: Hashable {
    let components: [Int]

    init?(_ text: String, length: Bool) {
        let fields = text.split(whereSeparator: { $0 == "." || $0.isWhitespace })
        let values = fields.compactMap { Int($0) }
        let minimum = length ? 0 : 1
        guard fields.count == 4, values.count == 4,
              (minimum...9999).contains(values[0]),
              values.dropFirst().allSatisfy({ (minimum...999).contains($0) }),
              !length || values.contains(where: { $0 != 0 }) else { return nil }
        components = values
    }

    var description: String { components.map(String.init).joined(separator: ".") }
}

struct Logic13MIDINoteValue: Equatable {
    let channel: Int
    var pitch: Int
    var velocity: Int
    var position: Logic13MIDINoteCoordinate
    var length: Logic13MIDINoteCoordinate

    var evidence: [String: Any] {
        ["channel": channel, "pitch": pitch, "velocity": velocity,
         "position": position.description, "length": length.description]
    }

    func hasSameIdentity(as other: Self) -> Bool {
        channel == other.channel && pitch == other.pitch && position == other.position
    }
}

struct Logic13MIDINoteEditPlan {
    enum Field {
        case pitch
        case velocity
        case position(Int)
        case length(Int)
    }

    struct Step {
        let field: Field
        let current: Logic13MIDINoteValue
        let expected: Logic13MIDINoteValue
        let target: Int
    }

    // Each native action is followed by a complete independent row read.
    static let maximumSteps = 48

    let steps: [Step]

    init?(before: Logic13MIDINoteValue, after: Logic13MIDINoteValue, peers: [Logic13MIDINoteValue]) {
        guard before.channel == after.channel, (1...16).contains(before.channel),
              (0...127).contains(before.pitch), (0...127).contains(after.pitch),
              (1...127).contains(before.velocity), (1...127).contains(after.velocity),
              !peers.contains(where: { before.hasSameIdentity(as: $0) }) else { return nil }

        let cost = abs(after.pitch - before.pitch) + abs(after.velocity - before.velocity) / 10
            + abs(after.velocity - before.velocity) % 10
            + zip(before.position.components, after.position.components).reduce(0) { $0 + abs($1.1 - $1.0) }
            + zip(before.length.components, after.length.components).reduce(0) { $0 + abs($1.1 - $1.0) }
        guard cost <= Self.maximumSteps else { return nil }

        var current = before
        var planned: [Step] = []
        func append(_ next: Logic13MIDINoteValue, field: Field, target: Int) {
            planned.append(.init(field: field, current: current, expected: next, target: target))
            current = next
        }

        while current.pitch != after.pitch {
            var next = current
            next.pitch += current.pitch < after.pitch ? 1 : -1
            append(next, field: .pitch, target: next.pitch)
        }

        while current.velocity != after.velocity {
            let distance = after.velocity - current.velocity
            let stride = abs(distance) >= 10 ? 10 : 1
            var next = current
            next.velocity += distance > 0 ? stride : -stride
            append(next, field: .velocity, target: next.velocity)
        }

        let lengthGrows = before.length.components.lexicographicallyPrecedes(after.length.components)
        for length in lengthGrows ? [false, true] : [true, false] {
            let target = length ? after.length : after.position
            var parts = length ? current.length.components : current.position.components
            for index in parts.indices {
                while parts[index] != target.components[index] {
                    parts[index] += parts[index] < target.components[index] ? 1 : -1
                    guard let coordinate = Logic13MIDINoteCoordinate(
                        parts.map(String.init).joined(separator: "."), length: length) else { return nil }
                    var next = current
                    if length { next.length = coordinate } else { next.position = coordinate }
                    append(next, field: length ? .length(index) : .position(index), target: parts[index])
                }
            }
        }

        guard current == after,
              planned.allSatisfy({ step in !peers.contains { step.expected.hasSameIdentity(as: $0) } })
        else { return nil }
        steps = planned
    }
}
