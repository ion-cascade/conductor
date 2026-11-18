import ApplicationServices
import Foundation

/// Read only after the physical RetroSynthSlot and editor custody are held.
/// The Inspector's checkbox reports BYPASSED; the editor's toggle, when it
/// exposes a value, reports ENABLED. Logic can expose that editor control as
/// a plain button without AXValue after reconnecting. Its role is never a state.
enum RetroSynthPowerState {
    static func observe(boundInstrumentGroup group: AXUIElement,
                        editorChildren: [AXUIElement], runtime: AXHelpers.Runtime) throws -> Bool {
        typealias Failure = RetroSynthSnapshot.Failure
        guard case .success(let children) = AXHelpers.childrenResult(group, runtime: runtime) else {
            throw Failure.unavailable("instrument_slot_power_children")
        }
        let toggles = children.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXCheckBoxRole
                && AXHelpers.getDescription($0, runtime: runtime) == "bypass"
        }
        guard toggles.count == 1, let toggle = toggles.first,
              let parent: AXUIElement = AXHelpers.getAttribute(toggle, kAXParentAttribute, runtime: runtime),
              CFEqual(parent, group),
              case .success(.some(let bypassed)) = AXValueExtractors.extractButtonStateResult(toggle, runtime: runtime) else {
            throw Failure.unavailable("instrument_slot_power_unreadable")
        }
        let enabled = !bypassed
        let header = editorChildren.filter { AXHelpers.getDescription($0, runtime: runtime) == "bypass" }
        guard header.count == 1, let power = header.first,
              let role = AXHelpers.getRole(power, runtime: runtime),
              role == kAXCheckBoxRole || role == kAXButtonRole else {
            throw Failure.unavailable("instrument_editor_power_address")
        }
        // Only the measured plain-button/absent-value variant may omit the
        // second observation. Transport errors, mixed values and contradictory
        // readable states always refuse, including on a plain button.
        switch AXHelpers.getAttributeResult(power, kAXValueAttribute, runtime: runtime)
            as Result<AnyObject?, AXHelpers.AXStatusError> {
        case .success(.none):
            guard role == kAXButtonRole else { throw Failure.unavailable("instrument_editor_power_absent") }
        case .failure(let error) where error.isDefinitiveAbsence:
            guard role == kAXButtonRole else { throw Failure.unavailable("instrument_editor_power_absent") }
        case .failure:
            throw Failure.unavailable("instrument_editor_power_unreadable")
        case .success(.some(_)):
            guard case .success(.some(let observed)) = AXValueExtractors.extractButtonStateResult(power, runtime: runtime),
                  observed == enabled else { throw Failure.unavailable("instrument_power_observations_disagree") }
        }
        return enabled
    }
}
