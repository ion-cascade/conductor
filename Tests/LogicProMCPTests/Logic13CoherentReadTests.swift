import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

struct Logic13CoherentReadTests {
    @Test func unreadTransportDefaultsAreNotObservations() throws {
        var state = TransportState()
        state.tempo = 140
        state.isPlaying = true
        let text = ResourceHandlers.transportWireJSON(state, observationsOnly: true)
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["sampleRate"] == nil)
        #expect(object["timePosition"] == nil)
        #expect(object["tempo"] as? Int == 140)
        #expect(object["isPlaying"] as? Bool == true)
        #expect(object["unavailable_fields"] as? [String] == ["sampleRate", "timePosition"])
    }
    @Test func legacyTransportWireRemainsCompatible() throws {
        let text = ResourceHandlers.transportWireJSON(TransportState(), observationsOnly: false)
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["sampleRate"] as? Int == 44100)
        #expect(object["timePosition"] as? String == "00:00:00.000")
    }
    @Test func searchSelectionRequiresOneExactNumberedName() {
        #expect(AXLogicProElements.searchTrackResultMatches(["2\tBass"], number: 2, name: "Bass"))
        #expect(!AXLogicProElements.searchTrackResultMatches(["12\tBass"], number: 2, name: "Bass"))
        #expect(!AXLogicProElements.searchTrackResultMatches(["2\tBass", "2\tBass"], number: 2, name: "Bass"))
        #expect(!AXLogicProElements.searchTrackResultMatches(["2\tOther"], number: 2, name: "Bass"))
        #expect(!AXLogicProElements.searchTrackResultMatches([], number: 2, name: "Bass"))
    }
}

@Test("Track search requires current keyboard ownership even when AX focus is unreadable",
      arguments: ["unread_focus", "matched_focus", "foreign_owner", "focus_mismatch", "missing_windows", "different_logic_pid"])
func trackSearchKeyboardOwnershipGate(scenario: String) {
    let pid: pid_t = 672
    let owner: pid_t = scenario == "foreign_owner" ? 900 : scenario == "different_logic_pid" ? 673 : pid
    let windows: [[String: Any]] = scenario == "missing_windows" ? [] : [
        [kCGWindowOwnerPID as String: owner, kCGWindowLayer as String: 0]
    ]
    let focus: pid_t? = scenario == "unread_focus" ? nil : scenario == "focus_mismatch" ? 900 : owner
    let observation = ProcessUtils.keyboardOwnershipObservation(
        windows: windows, focusedApplicationPID: focus,
        bundleIDForPID: { $0 == 900 ? "com.apple.finder" : "com.apple.logic10" }
    )
    let b = FakeAXRuntimeBuilder()
    let runtime = AXLogicProElements.Runtime(
        logicProPID: { pid }, ax: b.makeAXRuntime(),
        focusedApplicationPID: { nil }, observeFrontmost: { observation }
    )
    #expect(AXLogicProElements.selectionKeyboardOwnerIsCurrent(pid, runtime: runtime)
        == ["unread_focus", "matched_focus"].contains(scenario))
    #expect(b.actionCalls.isEmpty)
    #expect(b.setCalls.isEmpty)
}

@Test("Track search test runtimes never consult the live desktop for missing focus", arguments: [false, true])
func trackSearchWithoutWindowServerObservationRequiresExplicitFocus(matched: Bool) {
    let b = FakeAXRuntimeBuilder()
    let runtime = AXLogicProElements.Runtime(
        logicProPID: { 672 }, ax: b.makeAXRuntime(), focusedApplicationPID: { matched ? 672 : nil }
    )
    #expect(AXLogicProElements.selectionKeyboardOwnerIsCurrent(672, runtime: runtime) == matched)
}
