import Testing
@testable import LogicProMCP

struct ProjectLiveLoopsTests {
    @Test func nativeWriteCanChangeOnlyTheBoundRowActivity() throws {
        let before = grid(peer: "deactivate track", target: "deactivate track")
        let launched = grid(peer: "deactivate track", target: "stop")
        #expect(launched.preservesPeers(of: before, track: "Piano"))
        #expect(try launched.snapshot() != before.snapshot())

        let unexpectedPeer = grid(peer: "activate track", target: "stop")
        #expect(!unexpectedPeer.preservesPeers(of: before, track: "Piano"))

        let changedContent = grid(peer: "deactivate track", target: "stop", region: "Other")
        #expect(!changedContent.preservesPeers(of: before, track: "Piano"))

        let transportStopped = grid(peer: "deactivate track", target: "stop", playing: false)
        #expect(!transportStopped.preservesPeers(of: before, track: "Piano"))
    }

    private func grid(
        peer: String, target: String, region: String = "Phrase", playing: Bool = true
    ) -> ProjectLiveLoops.Grid {
        .init(project_path: "/tmp/Loops.logicx", quantize_start: "1 Bar", transport_playing: playing,
              rows: [.init(track: "Bass", activity: peer), .init(track: "Piano", activity: target)],
              cells: [.init(cell_ref: "cell_phrase", scene: "scene 1", track: "Piano", name: region,
                            mode: "Looping, Start/Stop")], selected_cell_ref: "cell_phrase")
    }
}
