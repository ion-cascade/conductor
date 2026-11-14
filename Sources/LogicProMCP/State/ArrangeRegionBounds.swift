import Foundation

/// Logic 13 English Arrange help encodes musical positions with one-based
/// values and omits beats, divisions and ticks whose value is 1.
struct ArrangeRegionBounds: Equatable, Sendable {
    let start: String
    let end: String

    private static let position = #"([1-9][0-9]*) bars?(?:\s+([1-9][0-9]*) beats?)?(?:\s+([1-9][0-9]*) divisions?)?(?:\s+([1-9][0-9]*) ticks?)?"#
    private static let helpPattern = try? NSRegularExpression(
        pattern: #"\ARegion starts at\s+"# + position
            + #"\s+and ends at\s+"# + position + #"\s*(?:,|\z)"#
    )

    static func read(from help: String) -> Self? {
        guard let match = helpPattern?.firstMatch(in: help, range: NSRange(help.startIndex..., in: help))
        else { return nil }
        func components(first: Int) -> [Int]? {
            var values: [Int] = []
            for index in first..<(first + 4) {
                let capture = match.range(at: index)
                if capture.location == NSNotFound {
                    values.append(1)
                } else if let range = Range(capture, in: help), let value = Int(help[range]) {
                    values.append(value)
                } else {
                    return nil
                }
            }
            return values
        }
        guard let start = components(first: 1), let end = components(first: 5),
              start.lexicographicallyPrecedes(end) else { return nil }
        return Self(start: start.map(String.init).joined(separator: "."),
                    end: end.map(String.init).joined(separator: "."))
    }
}
