import CryptoKit
import Foundation

/// Semantic value projection of one complete measured Controls table. Physical
/// elements remain in the native acquisition and are never serialized as identity.
struct RetroSynthSnapshot: Codable, Equatable, Sendable {
    enum Scalar: Codable, Equatable, Sendable {
        case number(Double)
        case text(String)
        case boolean(Bool)
    }

    struct Control: Codable, Equatable, Sendable {
        let role: String
        let value: Scalar
        let display: String
    }

    struct Row: Codable, Equatable, Sendable {
        let label: String?
        let controls: [Control]
    }

    enum Failure: Error { case unavailable(String) }

    let preset: String
    let rows: [Row]
    let enabled: Bool

    init(preset: String, rows: [Row], enabled: Bool = true) {
        self.preset = preset
        self.rows = rows
        self.enabled = enabled
    }

    var fingerprint: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
        }
    }

    func validateLayout() throws {
        var roles = RetroSynthFactoryBaseline.roles
        for oscillator in [1, 2] where try text("Oscillator \(oscillator) Waveform:") == "Square" {
            let index = oscillator == 1 ? 34 : 36
            roles[index] = ["AXSlider", "AXSlider", "AXValueIndicator"]
        }
        guard rows.count == 83, rows.map(\.label) == RetroSynthFactoryBaseline.labels,
              rows.map({ $0.controls.map(\.role).sorted() }) == roles else {
            throw Failure.unavailable("controls_layout")
        }
        let labels = rows.compactMap(\.label)
        guard Set(labels).count == labels.count else { throw Failure.unavailable("duplicate_labels") }
        guard try text("Oscillator Type:") == "Analog",
              try text("Filter Type:") == "LP 24dB Lush" else {
            throw Failure.unavailable("unsupported_synthesis_profile")
        }
    }

    func row(_ label: String) throws -> Row {
        let found = rows.filter { $0.label == label }
        guard found.count == 1, let row = found.first else { throw Failure.unavailable("parameter_row") }
        return row
    }

    func text(_ label: String) throws -> String {
        let row = try row(label)
        guard row.controls.count == 1, row.controls[0].role == "AXPopUpButton",
              case .text(let value) = row.controls[0].value, !value.isEmpty else {
            throw Failure.unavailable("popup_readback")
        }
        return value
    }

    func boolean(_ label: String) throws -> Bool {
        let row = try row(label)
        guard row.controls.count == 1, row.controls[0].role == "AXCheckBox",
              case .boolean(let value) = row.controls[0].value else {
            throw Failure.unavailable("checkbox_readback")
        }
        return value
    }

    func scalar(_ label: String) throws -> (position: Int, display: String) {
        let controls = try row(label).controls
        guard controls.count == 3, controls.filter({ $0.role == "AXSlider" }).count == 2,
              controls.filter({ $0.role == "AXValueIndicator" }).count == 1 else {
            throw Failure.unavailable("scalar_shape")
        }
        let numbers = controls.compactMap { control -> Double? in
            if case .number(let number) = control.value, number.isFinite { return number }
            return nil
        }
        let displayed = controls.filter { !$0.display.isEmpty }
        guard numbers.count == 3, Set(numbers).count == 1, let first = numbers.first,
              let position = Int(exactly: first), displayed.count == 1,
              displayed[0].role == "AXSlider" else {
            throw Failure.unavailable("inconsistent_scalar_readback")
        }
        return (position, displayed[0].display)
    }

    func observation(_ parameter: RetroSynthProfile.Parameter) throws -> RetroSynthProfile.Choice {
        switch parameter.kind {
        case .choices:
            let value = try text(parameter.label)
            guard let choice = parameter.choices.first(where: { $0.text == value }) else {
                throw Failure.unavailable("unsupported_popup_value")
            }
            return choice
        case .sync:
            let value = try boolean(parameter.label)
            guard let choice = parameter.choices.first(where: { $0.boolean == value }) else {
                throw Failure.unavailable("unsupported_boolean_value")
            }
            return choice
        default:
            let observed = try scalar(parameter.label)
            let mode: Bool? = parameter.id == "lfo_rate" ? try boolean("LFO Sync:") : nil
            guard let choice = parameter.choices.first(where: {
                $0.position == observed.position && ($0.sync == nil || $0.sync == mode)
            }) else { throw Failure.unavailable("unsupported_scalar_position") }
            if !choice.display.isEmpty {
                guard observed.display == choice.display else { throw Failure.unavailable("scalar_display_mismatch") }
            } else {
                guard let nativeValue = RetroSynthProfile.Parameter.number(observed.display, unit: choice.unit),
                      let expected = choice.number, abs(nativeValue - expected) <= 0.000_000_001 else {
                    throw Failure.unavailable("scalar_unit_mismatch")
                }
            }
            return .init(position: choice.position, number: choice.number, text: choice.text,
                         boolean: choice.boolean, unit: choice.unit, display: observed.display, sync: choice.sync)
        }
    }

    func preservesPeers(of before: Self, changing labels: Set<String>) -> Bool {
        guard enabled == before.enabled, rows.map(\.label) == before.rows.map(\.label),
              preset == before.preset || preset == "Manual" else { return false }
        return zip(before.rows, rows).allSatisfy { old, new in
            if old.label.map(labels.contains) == true || old == new { return true }
            for oscillator in [1, 2] where labels.contains("Oscillator \(oscillator) Waveform:") {
                if old.label == "Oscillator \(oscillator)  Pulse Width:",
                   let a = Self.pulseWidthValue(old), let b = Self.pulseWidthValue(new) {
                    return a == b
                }
            }
            return false
        }
    }

    /// Square enables a three-control pulse-width row. Other waveforms expose
    /// one disabled slider. Preserve both native value and display across that
    /// presentation transition; it grants no pulse-width editing authority.
    private static func pulseWidthValue(_ row: Row) -> Control? {
        let roles = row.controls.map(\.role).sorted()
        guard roles == ["AXSlider"] || roles == ["AXSlider", "AXSlider", "AXValueIndicator"] else { return nil }
        let displayed = row.controls.filter { !$0.display.isEmpty }
        guard displayed.count == 1, displayed[0].role == "AXSlider",
              case .number(let number) = displayed[0].value, number.isFinite,
              row.controls.allSatisfy({ $0.value == displayed[0].value }) else { return nil }
        return displayed[0]
    }

    var isFactoryInitialized: Bool {
        guard (try? validateLayout()) != nil else { return false }
        return rows.allSatisfy { row in
            guard let label = row.label, !row.controls.isEmpty else { return row.controls.isEmpty }
            return row.controls == RetroSynthFactoryBaseline.values[label]
        }
    }
}
