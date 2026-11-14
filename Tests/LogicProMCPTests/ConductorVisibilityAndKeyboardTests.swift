@preconcurrency import ApplicationServices
import Foundation
import Dispatch
import Testing
@testable import LogicProMCP

struct ConductorVisibilityAndKeyboardTests {
    private final class ConcurrentEntryGauge: @unchecked Sendable {
        let lock = NSLock()
        var active = 0
        var peak = 0
        var count = 0
        func enter() { lock.withLock { active += 1; peak = max(peak, active); count += 1 } }
        func leave() { lock.withLock { active -= 1 } }
    }

    @Test func nativeInputSourceAccessIsExclusiveAcrossWorkerThreads() {
        let gauge = ConcurrentEntryGauge()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            NativeInputSources.withExclusiveAccess {
                gauge.enter()
                defer { gauge.leave() }
                // Reentrant diagnostic reads use the same native framework.
                NativeInputSources.withExclusiveAccess { Thread.sleep(forTimeInterval: 0.001) }
            }
        }
        #expect(gauge.count == 32 && gauge.active == 0 && gauge.peak == 1)
    }

    @Test(arguments: [AXError.noValue.rawValue, AXError.cannotComplete.rawValue])
    func arrangeRegionReadDistinguishesAnEmptyLaneFromReadFailure(status: Int32) {
        let b = FakeAXRuntimeBuilder()
        let content = b.element(951000)
        let empty = b.element(951001)
        let occupied = b.element(951002)
        let region = b.element(951003)
        b.setRole(content, kAXGroupRole as String)
        b.setRole(empty, kAXLayoutAreaRole as String)
        b.setRole(occupied, kAXLayoutAreaRole as String)
        b.setRole(region, kAXLayoutItemRole as String)
        b.setChildren(content, [empty, occupied])
        b.setChildren(occupied, [region])
        let runtime = b.makeAXRuntime(
            childrenResultHandler: { element in
                guard CFEqual(element, empty) else { return nil }
                return .failure(.init(raw: status))
            },
            setAttributeHandler: nil, performActionHandler: nil)
        let items = AXLogicProElements.logic13RegionItems(in: content, runtime: runtime)
        if status == AXError.noValue.rawValue {
            #expect(items?.count == 1)
            #expect(items?.first.map { CFEqual($0, region) } == true)
        } else {
            #expect(items == nil)
        }
    }

    @Test func arrangeRegionBindingUsesTheNumberedLaneDespiteRepeatedTrackNames() {
        let b = FakeAXRuntimeBuilder()
        let content = b.element(951010)
        let lane = b.element(951011)
        let region = b.element(951012)
        let first = b.element(951013)
        let second = b.element(951014)
        b.setRole(lane, kAXLayoutAreaRole as String)
        b.setChildren(content, [lane])
        b.setChildren(lane, [region])
        b.setAttribute(lane, kAXDescriptionAttribute as String, "Track 2 “Studio Grand”")
        b.setAttribute(first, kAXDescriptionAttribute as String, "Track 1 “Studio Grand”")
        b.setAttribute(second, kAXDescriptionAttribute as String, "Track 2 “Studio Grand”")
        let runtime = b.makeAXRuntime()
        #expect(AXLogicProElements.logic13RegionTrackIndex(region, in: content,
            headers: [first, second], runtime: runtime) == 1)
        b.setAttribute(first, kAXDescriptionAttribute as String, "Track 2 “Studio Grand”")
        #expect(AXLogicProElements.logic13RegionTrackIndex(region, in: content,
            headers: [first, second], runtime: runtime) == nil)
    }

    @Test(arguments: ["shown", "hidden", "absent", "unreadable", "duplicate", "unmeasured_legend"])
    func hideViewAbsenceRequiresACompleteMeasuredLegend(scenario: String) {
        let b = FakeAXRuntimeBuilder()
        func node(_ id: Int, _ role: String) -> AXUIElement {
            let e = b.element(id); b.setRole(e, role); b.setChildren(e, []); return e
        }
        let window = node(950000, kAXWindowRole as String)
        let split = node(950001, kAXSplitGroupRole as String)
        let headerSplit = node(950002, kAXSplitGroupRole as String)
        let scroll = node(950003, kAXScrollAreaRole as String)
        let rail = node(950004, kAXGroupRole as String)
        b.setAttribute(rail, kAXDescriptionAttribute as String, "Tracks header")
        let header = node(950005, kAXLayoutItemRole as String)
        b.setChildren(window, [split]); b.setChildren(split, [headerSplit])
        b.setChildren(headerSplit, [scroll]); b.setChildren(scroll, [rail]); b.setChildren(rail, [header])
        let legendSplit = node(950006, kAXSplitGroupRole as String)
        let legend = node(950007, kAXGroupRole as String)
        b.setAttribute(legend, kAXDescriptionAttribute as String, scenario == "unmeasured_legend" ? "Other" : "Tracks legend")
        b.setChildren(split, [headerSplit, legendSplit]); b.setChildren(legendSplit, [legend])
        if scenario != "absent" && scenario != "unmeasured_legend" {
            let control = node(950008, kAXCheckBoxRole as String)
            b.setAttribute(control, kAXDescriptionAttribute as String, "Show/Hide Hidden Tracks   H")
            b.setAttribute(control, kAXWindowAttribute as String, window)
            if scenario != "unreadable" { b.setAttribute(control, kAXValueAttribute as String, scenario == "hidden" ? 0 : 1) }
            b.setChildren(legend, [control])
            if scenario == "duplicate" {
                let other = node(950009, kAXCheckBoxRole as String)
                b.setAttribute(other, kAXDescriptionAttribute as String, "Show/Hide Hidden Tracks   H")
                b.setChildren(legend, [control, other])
            }
        }
        let result = AXLogicProElements.hiddenTrackViewObservation(headers: [header], in: window, runtime: b.makeLogicRuntime())
        switch result {
        case .observed(let reading):
            #expect(scenario == "shown" || scenario == "hidden")
            #expect(reading.shown == (scenario == "shown"))
        case .absent: #expect(scenario == "absent")
        case .unavailable: #expect(["unreadable", "duplicate", "unmeasured_legend"].contains(scenario))
        }
        #expect(b.actionCalls.isEmpty && b.setCalls.isEmpty)
    }

    @MainActor @Test(arguments: ["ABC", "US", "British", "wrong_mapping", "unavailable", "disabled"])
    func goToFolderUsesTheVerifiedKeyMappingWithoutChangingInputSources(scenario: String) {
        let runtime = CGEventChannel.Runtime(
            isLogicProRunning: { true }, logicProPID: { 4242 },
            postKeyEvent: { _, _, _ in false }, sleepMicros: { _ in },
            asciiCapableLayoutID: { scenario == "unavailable" ? nil : "com.apple.keylayout.\(scenario)" },
            layoutLetter: { _, key in key == 5 && scenario != "wrong_mapping" ? "g" : "q" },
            layoutIsEnabled: { _ in scenario != "disabled" }
        )
        #expect(MIDITrackExportPanel.Keyboard.goToFolderKeyIsMapped(using: runtime)
            == ["ABC", "US", "British"].contains(scenario))
    }

    @Test func hiddenViewNeverActuatesAnotherForegroundApplication() async throws {
        let b = FakeAXRuntimeBuilder()
        let runtime = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: b.makeAXRuntime(), focusedApplicationPID: { 9999 })
        let result = await AccessibilityChannel.setHiddenTrackViewVisibility(true, runtime: runtime, sleep: { _ in })
        let payload = try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
        #expect(payload["state"] as? String == "C")
        #expect(payload["write_attempted"] as? Bool == false)
        #expect(b.actionCalls.isEmpty && b.setCalls.isEmpty)
    }
}
