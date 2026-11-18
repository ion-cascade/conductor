import Foundation

enum RetroSynthReport {
    static func parameters(_ snapshot: RetroSynthSnapshot, optionsFor: String?) throws -> [[String: Any]] {
        try RetroSynthProfile.parameters.map { parameter in
            let observation = try snapshot.observation(parameter)
            var row = observation.json
            row["param"] = parameter.id
            row["native_label"] = parameter.label
            row["value_precision"] = "native_display"
            row["supported_units"] = Array(Set(parameter.choices.map(\.unit))).sorted()
            switch parameter.kind {
            case let .linear(maximum, stepsPerUnit, offset):
                row["minimum"] = offset
                row["maximum"] = Double(maximum + offset * stepsPerUnit) / Double(stepsPerUnit)
                row["step"] = 1 / Double(stepsPerUnit)
            case .choices:
                row["choices"] = parameter.choices.compactMap(\.text)
            case .sync, .filterState: break
            default:
                row["quantization"] = "native_display_choices"
                let values = parameter.choices.filter { $0.unit == observation.unit }.compactMap(\.number)
                if let minimum = values.min(), let maximum = values.max() {
                    row["minimum"] = minimum
                    row["maximum"] = maximum
                }
            }
            if optionsFor == parameter.id {
                var seen = Set<String>()
                row["supported_values"] = parameter.choices.filter { choice in
                    let key = choice.unit + "|" + String(describing: choice.number) + "|" + String(describing: choice.text) + "|" + String(describing: choice.boolean)
                    return seen.insert(key).inserted
                }.map(\.json)
            }
            return row
        }
    }

    static func nearest(_ parameter: RetroSynthProfile.Parameter, input: RetroSynthProfile.Input, unit: String) -> [[String: Any]] {
        guard case .number(let requested) = input, requested.isFinite else { return [] }
        var seen = Set<Double>()
        return parameter.choices.filter { choice in
            guard choice.unit == unit, let number = choice.number else { return false }
            return seen.insert(number).inserted
        }.sorted { abs(($0.number ?? 0) - requested) < abs(($1.number ?? 0) - requested) }
            .prefix(3).map(\.json)
    }
}
