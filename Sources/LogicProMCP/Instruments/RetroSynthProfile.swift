import Foundation

/// The observed Analog Controls profile. Cutoff is a native normalized value;
/// the host does not publish its frequency in Hz through this control.
enum RetroSynthProfile {
    static let id = "logic13.retro_synth.analog.controls.v1"
    static let logicVersion = "13.0"
    static let logicBuild = "7801"

    enum Input: Sendable {
        case number(Double)
        case text(String)
        case boolean(Bool)
    }

    enum Kind: Sendable {
        case linear(maximum: Int, scale: Double, offset: Double)
        case curve([String])
        case choices([String])
        case lfoRate
        case sync
    }

    struct Choice: Sendable, Equatable {
        let position: Int?
        let number: Double?
        let text: String?
        let boolean: Bool?
        let unit: String
        let display: String
        let sync: Bool?

        var json: [String: Any] {
            var result: [String: Any] = ["unit": unit, "native_display": display]
            if let number { result["value"] = number }
            if let text { result["value"] = text }
            if let boolean { result["value"] = boolean }
            if let position { result["native_step"] = position }
            if let sync { result["lfo_sync"] = sync }
            return result
        }
    }

    struct Parameter: Sendable {
        let id: String
        let label: String
        let unit: String
        let kind: Kind

        var choices: [Choice] {
            switch kind {
            case let .linear(maximum, scale, offset):
                return (0...maximum).map { position in
                    let value = Double(position) * scale + offset
                    return Choice(position: position, number: value, text: nil, boolean: nil,
                                  unit: unit, display: "", sync: nil)
                }
            case let .curve(values):
                return values.enumerated().compactMap { index, display in
                    guard let value = Self.number(display, unit: unit) else { return nil }
                    return Choice(position: index, number: value, text: nil, boolean: nil,
                                  unit: unit, display: display, sync: nil)
                }
            case let .choices(values):
                return values.map { Choice(position: nil, number: nil, text: $0, boolean: nil,
                                           unit: unit, display: $0, sync: nil) }
            case .sync:
                return [false, true].map { Choice(position: nil, number: nil, text: nil, boolean: $0,
                                                 unit: "bool", display: String($0), sync: $0) }
            case .lfoRate:
                let free = RetroSynthMeasuredValues.lfoFree.enumerated().compactMap { index, display -> Choice? in
                    guard let value = Self.number(display, unit: "Hz") else { return nil }
                    return Choice(position: index, number: value, text: nil, boolean: nil,
                                  unit: "Hz", display: display, sync: false)
                }
                let synced = RetroSynthMeasuredValues.lfoSync.enumerated().map { index, display in
                    Choice(position: index, number: nil, text: display, boolean: nil,
                           unit: "division", display: display, sync: true)
                }
                return free + synced
            }
        }

        /// The first native position is the canonical choice when display
        /// rounding aliases positions. The chosen position is returned explicitly.
        func resolve(value: Input, unit requestedUnit: String) -> Choice? {
            choices.first { choice in
                guard choice.unit == requestedUnit else { return false }
                if let expected = choice.boolean {
                    guard case .boolean(let actual) = value else { return false }
                    return actual == expected
                }
                if let expected = choice.text {
                    guard case .text(let actual) = value else { return false }
                    return actual == expected
                }
                let actual: Double
                switch value {
                case .number(let number): actual = number
                default: return false
                }
                guard actual.isFinite, let expected = choice.number else { return false }
                return abs(actual - expected) <= 0.000_000_001
            }
        }

        static func number(_ display: String, unit: String) -> Double? {
            var text = display.trimmingCharacters(in: .whitespacesAndNewlines)
            var multiplier = 1.0
            if unit == "ms", text.hasSuffix(" ms") { text.removeLast(3) }
            else if unit == "ms", text.hasSuffix(" s") { text.removeLast(2); multiplier = 1000 }
            else if unit == "Hz", text.hasSuffix(" Hz") { text.removeLast(3) }
            else if unit == "semitones", text.hasSuffix(" s") { text.removeLast(2) }
            else if unit == "cents", text.hasSuffix(" c") { text.removeLast(2) }
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
            return number * multiplier
        }
    }

    static let parameters: [Parameter] = [
        .init(id: "osc1_waveform", label: "Oscillator 1 Waveform:", unit: "waveform", kind: .choices(["Noise", "Sawtooth", "Square"])),
        .init(id: "osc2_waveform", label: "Oscillator 2 Waveform:", unit: "waveform", kind: .choices(["Triangle", "Sawtooth", "Square"])),
        .init(id: "oscillator_mix", label: "Oscillator Mix:", unit: "normalized", kind: .linear(maximum: 100, scale: 0.01, offset: 0)),
        .init(id: "osc2_semitones", label: "Oscillator 2 Semitone:", unit: "semitones", kind: .linear(maximum: 48, scale: 1, offset: -24)),
        .init(id: "osc2_detune", label: "Oscillator 2 Detune:", unit: "cents", kind: .linear(maximum: 100, scale: 1, offset: -50)),
        .init(id: "filter_cutoff", label: "Cutoff:", unit: "normalized", kind: .linear(maximum: 500, scale: 0.002, offset: 0)),
        .init(id: "filter_resonance", label: "Resonance:", unit: "normalized", kind: .linear(maximum: 100, scale: 0.01, offset: 0)),
        .init(id: "filter_envelope_depth", label: "Cutoff by Env:", unit: "normalized", kind: .linear(maximum: 200, scale: 0.01, offset: -1)),
        .init(id: "filter_lfo_depth", label: "Cutoff by LFO:", unit: "normalized", kind: .linear(maximum: 100, scale: 0.01, offset: 0)),
        .init(id: "lfo_waveform", label: "LFO Waveform:", unit: "waveform", kind: .choices(["Sawtooth Down", "Sawtooth Up", "Triangle", "Rectangle Bipolar", "Rectangle Unipolar"])),
        .init(id: "lfo_rate", label: "LFO Rate:", unit: "Hz", kind: .lfoRate),
        .init(id: "lfo_sync", label: "LFO Sync:", unit: "bool", kind: .sync),
        .init(id: "lfo_via_amount", label: "LFO Via Amount:", unit: "normalized", kind: .linear(maximum: 100, scale: 0.01, offset: 0)),
        .init(id: "amp_attack", label: "Amp Env Attack:", unit: "ms", kind: .curve(RetroSynthMeasuredValues.attack)),
        .init(id: "amp_decay", label: "Amp Env Decay:", unit: "ms", kind: .curve(RetroSynthMeasuredValues.decay)),
        .init(id: "amp_sustain", label: "Amp Env Sustain:", unit: "normalized", kind: .curve(RetroSynthMeasuredValues.sustain)),
        .init(id: "amp_release", label: "Amp Env Release:", unit: "ms", kind: .curve(RetroSynthMeasuredValues.release)),
        .init(id: "filter_attack", label: "Filter Env Attack:", unit: "ms", kind: .curve(RetroSynthMeasuredValues.attack)),
        .init(id: "filter_decay", label: "Filter Env Decay:", unit: "ms", kind: .curve(RetroSynthMeasuredValues.decay)),
        .init(id: "filter_sustain", label: "Filter Env Sustain:", unit: "normalized", kind: .curve(RetroSynthMeasuredValues.sustain)),
        .init(id: "filter_release", label: "Filter Env Release:", unit: "ms", kind: .curve(RetroSynthMeasuredValues.release)),
    ]

    static func parameter(_ id: String) -> Parameter? { parameters.first { $0.id == id } }
}
