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
