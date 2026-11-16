import ApplicationServices
import Foundation
import MCP

extension ProjectDispatcher {
    static func sessionPlayer(command: String, params: [String: Value], traceID: TraceID? = nil) async -> CallTool.Result {
        let operation = "project.\(command)"
        typealias Source = ProjectSessionPlayer.ChordSource
        func success(_ player: ProjectSessionPlayer, attempted: Bool) -> CallTool.Result {
            compositionResponse(operation, attempted: attempted, data: [
                "address": player.address, "player": "Keyboard Player",
                "complexity": player.complexity, "intensity": player.intensity,
                "complexity_range": [player.range.lowerBound, player.range.upperBound],
                "chord_source": player.chordSource.rawValue,
            ])
        }
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> CallTool.Result {
            compositionRefusal(operation, error: error, hint: hint)
        }

        let changing = command == "set_session_player_chord_source"
        var change: (address: [String: String], expected: Source, desired: Source)?
        if changing {
            guard params.count == 3, case .object(let address) = params["address"],
                  address.count == 4, address.values.allSatisfy({ $0.stringValue != nil }),
                  let expected = params["expected_chord_source"]?.stringValue.flatMap(Source.init(rawValue:)),
                  let desired = params["chord_source"]?.stringValue.flatMap(Source.init(rawValue:)) else {
                return refuse(.invalidParams, "Pass the Keyboard Player region address and current and desired chord sources.")
            }
            change = (address.compactMapValues(\.stringValue), expected, desired)
        } else if !params.isEmpty {
            return refuse(.invalidParams, "get_session_player takes no parameters.")
        }

        guard let first = ProjectSessionPlayer.read() else {
            return refuse(.readbackUnavailable, "Select one Keyboard Player region. Show its Session Player editor and expand General in the Region Inspector.")
        }
        guard let change else { return success(first, attempted: false) }
        guard first.address == change.address, first.chordSource == change.expected else {
            return refuse(.staleSnapshot, "The selected Keyboard Player region or its pitch source changed.")
        }
        if change.desired == first.chordSource { return success(first, attempted: false) }
        guard first.openChordMenu() else {
            return refuse(.readbackUnavailable, "Could not safely open the selected player’s Chords menu.")
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard let menu = first.chordMenu() else {
            _ = first.dismissChordMenu()
            return refuse(.readbackUnavailable, "The native Chords menu did not identify the current chord source.")
        }
        guard menu.selected == change.expected,
              menu.enabled.contains(change.desired), let item = menu.controls[change.desired],
              await recordWriteBoundary(traceID, deadlineStage: "session_player_chord_source"),
              let liveMenu = first.chordMenu(), CFEqual(liveMenu.menu, menu.menu),
              liveMenu.selected == change.expected,
              liveMenu.controls[change.desired].map({ CFEqual($0, item) }) == true else {
            _ = first.dismissChordMenu(menu)
            return refuse(.staleSnapshot, "The Chords menu no longer offers the requested change for this region.")
        }
        _ = AXHelpers.performAction(item, kAXPressAction)
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(200))
            if let observed = ProjectSessionPlayer.read(), observed.holdsSameAddress(as: first),
               observed.chordSource == change.desired, observed.complexity == first.complexity,
               observed.intensity == first.intensity, !observed.hasExposedChordMenu {
                return success(observed, attempted: true)
            }
        }
        _ = first.dismissChordMenu(menu)
        return compositionResponse(operation, attempted: true, data: nil)
    }

    static func chordTrack(command: String, params: [String: Value], traceID: TraceID? = nil) async -> CallTool.Result {
        let operation = "project.\(command)"
        func success(_ observed: ProjectChordTrack, attempted: Bool) -> CallTool.Result {
            return compositionResponse(operation, attempted: attempted, data: [
                "project_path": observed.projectPath, "events": observed.events.map(\.json),
            ])
        }
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> CallTool.Result {
            compositionRefusal(operation, error: error, hint: hint)
        }

        var change: (path: String, start: Int, end: Int, expected: String, quality: String)?
        if command == "set_chord_quality" {
            guard params.count == 5, let path = params["project_path"]?.stringValue, path.hasPrefix("/"),
                  let start = params["start_bar"]?.intValue, let end = params["end_bar"]?.intValue,
                  start > 0, end > start, let expected = params["expected_chord"]?.stringValue,
                  let quality = params["quality"]?.stringValue, ["major", "minor"].contains(quality) else {
                return refuse(.invalidParams, "Pass the project path, start and end bars, current chord and major or minor quality.")
            }
            change = (path, start, end, expected, quality)
        } else if !params.isEmpty {
            return refuse(.invalidParams, "get_chord_track takes no parameters.")
        }

        guard let before = ProjectChordTrack.read() else {
            return refuse(.readbackUnavailable, "Show the Chord Track in stopped Arrange with no more than 32 bar-aligned chords.")
        }
        guard let change else { return success(before, attempted: false) }
        guard before.projectPath == change.path, let index = before.events.firstIndex(where: {
            $0.startBar == change.start && $0.endBar == change.end && $0.chord == change.expected
        }) else { return refuse(.staleSnapshot, "Read the chord track again and pass the current event.") }
        let event = before.events[index]
        guard let quality = event.basicQuality else {
            return refuse(.readbackUnavailable, "Editing supports plain major and minor chords with natural roots.")
        }
        guard before.canEdit(eventAt: index) else {
            return refuse(.readbackUnavailable, "Select a standalone chord. Chord groups with multiple events are read-only.")
        }
        if quality == change.quality { return success(before, attempted: false) }
        guard let current = ProjectChordTrack.read(), current.holdsSameTrack(as: before), current.events == before.events,
              current.open(eventAt: index) else {
            return refuse(.staleSnapshot, "The chord moved or its editor could not be opened safely.")
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard let popover = current.popover() else {
            return refuse(.readbackUnavailable, "The native chord editor could not be verified.")
        }
        func closeEditor(commit: Bool) {
            guard current.ownsStoppedDocument(),
                  current.popover().map({ CFEqual(popover, $0) }) == true else { return }
            if commit {
                AXMouseHelper.pressReturn()
            } else {
                AXMouseHelper.pressEscape()
            }
        }
        let expectedText = event.chord.prefix(1).uppercased() + (quality == "minor" ? "m" : "")
        guard let existing = current.qualityControl(quality, in: popover),
              AXValueExtractors.extractButtonState(existing) == true,
              current.chordText(in: popover) == expectedText,
              let control = current.qualityControl(change.quality, in: popover),
              AXValueExtractors.extractButtonState(control) == false,
              await recordWriteBoundary(traceID, deadlineStage: "chord_quality") else {
            closeEditor(commit: false)
            return refuse(.staleSnapshot, "The open editor did not show the expected chord.")
        }
        let attempted = current.choose(control)
        try? await Task.sleep(for: .milliseconds(250))
        closeEditor(commit: attempted)
        var expected = before.events
        let newChord = String(event.chord.prefix(1)) + " " + change.quality
        expected[index] = .init(startBar: event.startBar, endBar: event.endBar, chord: newChord)
        if attempted {
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(180))
                if let after = ProjectChordTrack.read(), after.holdsSameTrack(as: before),
                   after.events == expected, after.popover() == nil {
                    return success(after, attempted: true)
                }
            }
        }
        return compositionResponse(operation, attempted: attempted, data: nil)
    }

    private static func compositionRefusal(
        _ operation: String, error: HonestContract.FailureError, hint: String
    ) -> CallTool.Result {
        toolTextResult(.error(HonestContract.encodeStateC(error: error, hint: hint,
            extras: ["operation": operation, "verified": false, "write_attempted": false])))
    }

    private static func compositionResponse(
        _ operation: String, attempted: Bool, data: [String: Any]?
    ) -> CallTool.Result {
        var result = data ?? ["reason": "The final native state could not be verified. Read it again before retrying."]
        result["operation"] = operation
        result["state"] = data == nil ? "B" : "A"
        result["verified"] = data != nil
        result["success"] = data != nil
        result["write_attempted"] = attempted
        return toolTextResult(ResourceHandlers.encodeJSONObject(result))
    }
}
