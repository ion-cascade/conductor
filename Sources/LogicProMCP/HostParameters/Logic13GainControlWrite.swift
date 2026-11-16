import ApplicationServices
import Foundation

enum Logic13GainControlWrite {
    static let method = "ax_controls_view_gain_walk"

    enum Outcome {
        case verified(before: Int, observed: Int, steps: Int)
        case unavailable
        case uncertain(lastVerified: Int)
    }

    static func rawValue(for decibels: Double) -> Int? {
        guard decibels.isFinite, (-6...0).contains(decibels) else { return nil }
        let tenths = decibels * 10
        let rounded = tenths.rounded()
        guard abs(tenths - rounded) < 0.000_000_001, let integralTenths = Int(exactly: rounded) else { return nil }
        return 960 + integralTenths
    }

    static func display(raw: Int) -> String {
        String(format: "%.1f dB", locale: Locale(identifier: "en_US_POSIX"), Double(raw - 960) / 10)
    }

    /// This host exposes a display-bearing slider, a raw-only sibling and a
    /// value indicator. Gain's native actions move a single dB or one tenth.
    static func apply(
        requested: Double, in window: AXUIElement,
        runtime: AXHelpers.Runtime, contextIsCurrent: () -> Bool
    ) async -> Outcome {
        guard let destination = rawValue(for: requested), contextIsCurrent() else { return .unavailable }
        func reading() -> (control: AXUIElement, raw: Int)? {
            guard case let .read(value, shown) = ControlsViewParameterReader.observe(
                kind: .numericDisplay, label: "Gain:", in: window, runtime: runtime),
                let number = value as? Double, let raw = Int(exactly: number), (900...960).contains(raw),
                shown == display(raw: raw),
                case let .success(controls) = ControlsViewBooleanParameterWriter.rowControls(
                    label: "Gain:", in: window, runtime: runtime)
            else { return nil }
            let matches = controls.filter {
                AXHelpers.getRole($0, runtime: runtime) == kAXSliderRole as String
                    && (AXHelpers.getAttribute($0, kAXValueDescriptionAttribute as String, runtime: runtime) as String?) == shown
                    && (AXHelpers.getAttribute($0, kAXValueAttribute as String, runtime: runtime) as Int?) == raw
            }
            guard matches.count == 1 else { return nil }
            return (matches[0], raw)
        }
        guard let initial = reading(), contextIsCurrent() else { return .unavailable }
        var raw = initial.raw
        var steps = 0
        while raw != destination {
            guard contextIsCurrent(), let fresh = reading(), fresh.raw == raw,
                  CFEqual(fresh.control, initial.control), contextIsCurrent() else {
                return steps == 0 ? .unavailable : .uncertain(lastVerified: raw)
            }
            let remaining = destination - raw
            let step = (remaining > 0 ? 1 : -1) * (abs(remaining) >= 10 ? 10 : 1)
            let action = step > 0 ? kAXIncrementAction : kAXDecrementAction
            let canMove = abs(step) == 10
                ? AXHelpers.getActionNames(fresh.control, runtime: runtime).contains(action)
                : AXHelpers.isAttributeSettable(fresh.control, kAXValueAttribute, runtime: runtime) == true
            guard canMove, contextIsCurrent(), OperationTraceContext.claimDeadlineEffect("stock_gain_control_walk") else {
                return steps == 0 ? .unavailable : .uncertain(lastVerified: raw)
            }
            let expected = raw + step
            let accepted = abs(step) == 10
                ? AXHelpers.performAction(fresh.control, action, runtime: runtime)
                : AXHelpers.setAttribute(fresh.control, kAXValueAttribute, NSNumber(value: expected), runtime: runtime)
            for _ in 0..<5 {
                do { try await Task.sleep(for: .milliseconds(80)) }
                catch { return .uncertain(lastVerified: raw) }
                guard contextIsCurrent() else { return .uncertain(lastVerified: raw) }
                guard let observed = reading(), CFEqual(observed.control, initial.control) else { continue }
                if observed.raw == expected, contextIsCurrent() {
                    raw = expected
                    steps += 1
                    break
                }
                if !accepted || observed.raw != raw { break }
            }
            guard raw == expected else { return .uncertain(lastVerified: raw) }
        }
        return .verified(before: initial.raw, observed: raw, steps: steps)
    }
}
