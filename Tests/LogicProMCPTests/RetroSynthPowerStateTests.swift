@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@MainActor
struct RetroSynthPowerStateTests {
    @Test(arguments: [false, true], ["checkbox", "button_absent", "button_unsupported", "button_readable"])
    func boundSlotDeterminesEnabledAndReadableHeaderMustAgree(_ bypassed: Bool, _ style: String) throws {
        let f = fixture(bypassed: bypassed, style: style)
        #expect(try RetroSynthPowerState.observe(boundInstrumentGroup: f.group,
            editorChildren: f.header, runtime: f.runtime) == !bypassed)
        #expect(f.builder.actionCalls.isEmpty && f.builder.setCalls.isEmpty)
    }

    @Test(arguments: ["missing_slot", "duplicate_slot", "wrong_parent", "mixed_slot", "slot_transport",
                      "missing_header", "duplicate_header", "wrong_header_role", "checkbox_absent",
                      "mixed_header", "contradictory_header", "header_transport", "button_contradiction",
                      "button_mixed", "button_transport"])
    func incompleteOrContradictoryStateNeverFallsBackToAGuess(_ fault: String) {
        let f = fixture(bypassed: false, style: "checkbox", fault: fault)
        #expect(throws: (any Error).self) {
            try RetroSynthPowerState.observe(boundInstrumentGroup: f.group,
                editorChildren: f.header, runtime: f.runtime)
        }
        #expect(f.builder.actionCalls.isEmpty && f.builder.setCalls.isEmpty)
    }

    private struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let group: AXUIElement
        let header: [AXUIElement]
        let runtime: AXHelpers.Runtime
    }

    private func fixture(bypassed: Bool, style: String, fault: String = "") -> Fixture {
        let b = FakeAXRuntimeBuilder()
        let group = b.element(1_991_100), slot = b.element(1_991_101), power = b.element(1_991_102)
        b.setRole(group, kAXGroupRole as String)
        b.setRole(slot, kAXCheckBoxRole as String)
        b.setAttribute(slot, kAXDescriptionAttribute as String, "bypass")
        b.setAttribute(slot, kAXValueAttribute as String, fault == "mixed_slot" ? NSNumber(value: 2) : NSNumber(value: bypassed))
        var slots = fault == "missing_slot" ? [] : [slot]
        if fault == "duplicate_slot" {
            let other = b.element(1_991_103)
            b.setRole(other, kAXCheckBoxRole as String)
            b.setAttribute(other, kAXDescriptionAttribute as String, "bypass")
            slots.append(other)
        }
        b.setChildren(group, slots)
        if fault == "wrong_parent" { b.setAttribute(slot, kAXParentAttribute as String, b.element(1_991_104)) }
        let isButton = style.hasPrefix("button") || fault.hasPrefix("button")
        b.setRole(power, fault == "wrong_header_role" ? kAXStaticTextRole as String :
                    (isButton ? kAXButtonRole as String : kAXCheckBoxRole as String))
        b.setAttribute(power, kAXDescriptionAttribute as String, "bypass")
        if !["button_absent", "button_unsupported"].contains(style) && fault != "checkbox_absent" {
            let value: NSNumber
            if ["mixed_header", "button_mixed"].contains(fault) { value = NSNumber(value: 2) }
            else { value = NSNumber(value: ["contradictory_header", "button_contradiction"].contains(fault) ? bypassed : !bypassed) }
            b.setAttribute(power, kAXValueAttribute as String, value)
        }
        var header = fault == "missing_header" ? [] : [power]
        if fault == "duplicate_header" {
            let other = b.element(1_991_105)
            b.setRole(other, kAXButtonRole as String)
            b.setAttribute(other, kAXDescriptionAttribute as String, "bypass")
            header.append(other)
        }
        let runtime = b.makeAXRuntime(attributeValueResultHandler: { element, attribute in
            guard attribute == kAXValueAttribute as String else { return nil }
            let id = b.elementID(element)
            if (id == 1_991_101 && fault == "slot_transport") ||
                (id == 1_991_102 && ["header_transport", "button_transport"].contains(fault)) {
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }
            if id == 1_991_102 && style == "button_unsupported" {
                return .failure(.init(raw: AXError.attributeUnsupported.rawValue))
            }
            return nil
        }, setAttributeHandler: nil, performActionHandler: nil)
        return .init(builder: b, group: group, header: header, runtime: runtime)
    }
}
