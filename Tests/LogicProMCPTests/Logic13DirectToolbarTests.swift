@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("Logic13 direct toolbar diagnostic")
struct Logic13DirectToolbarTests {
    @Test(arguments: ["valid", "duplicate_play", "duplicate_toolbar", "missing_record"])
    func boundedLookupRefusesAmbiguousControlsAndToolbars(scenario: String) throws {
        let b = FakeAXRuntimeBuilder()
        let window = b.element(940100)
        let bar = b.element(940101)
        b.setRole(window, kAXWindowRole as String)
        b.setRole(bar, kAXToolbarRole as String)
        b.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
        func checkbox(_ id: Int, _ label: String) -> AXUIElement {
            let element = b.element(id)
            b.setRole(element, kAXCheckBoxRole as String)
            b.setAttribute(element, kAXDescriptionAttribute as String, label)
            b.setChildren(element, [])
            return element
        }
        let play = checkbox(940102, "Play")
        var controls = [play]
        if scenario != "missing_record" { controls.append(checkbox(940103, "Record")) }
        if scenario == "duplicate_play" { controls.append(checkbox(940104, "Play")) }
        b.setChildren(bar, controls)
        var children = [bar]
        if scenario == "duplicate_toolbar" {
            let other = b.element(940105)
            b.setRole(other, kAXToolbarRole as String)
            b.setAttribute(other, kAXDescriptionAttribute as String, "Control Bar")
            b.setChildren(other, [])
            children.append(other)
        }
        b.setChildren(window, children)
        let result = AXLogicProElements.directLogic13Toolbar(in: window, runtime: b.makeAXRuntime())
        if scenario == "valid" { #expect(result != nil && CFEqual(result!, bar)) }
        else { #expect(result == nil) }
        #expect(b.setCalls.isEmpty && b.actionCalls.isEmpty)
    }
    @Test(arguments: [1, 2, 0])
    func mixerControlRequiresExactlyOne(count: Int) {
        let b = FakeAXRuntimeBuilder()
        let bar = b.element(940200)
        b.setRole(bar, kAXToolbarRole as String)
        var children: [AXUIElement] = []
        for index in 0..<count {
            let control = b.element(940201 + index)
            b.setRole(control, kAXCheckBoxRole as String)
            b.setAttribute(control, kAXDescriptionAttribute as String, "Mixer")
            b.setChildren(control, [])
            children.append(control)
        }
        b.setChildren(bar, children)
        let result = AXLogicProElements.directToolbarControl(AXLocalePolicy.controlBarMixerToggle,
            in: bar, runtime: b.makeAXRuntime())
        #expect((result != nil) == (count == 1))
        #expect(b.setCalls.isEmpty && b.actionCalls.isEmpty)
    }
}
