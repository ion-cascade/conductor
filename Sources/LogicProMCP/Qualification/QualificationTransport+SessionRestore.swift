import Foundation

extension QualificationTransport {
    /// #373 Phase B for a STRING field on a track — `tracks.rename` today.
    ///
    /// The probe name is deliberately unlikely and the restore writes the original back verbatim,
    /// so a failure between the two leaves a track called `qualification_phase_b_probe` rather
    /// than a plausible-looking wrong name. A cycle that renames and cannot put it back should be
    /// obvious in the project, not camouflaged.
    func trackStringRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        readbackField: String
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }
        let probeValue = "qualification_phase_b_probe"

        let pre = try observedTrackString(
            session, id: readStep(), trackIndex: 0, field: readbackField,
            phase: "phase_b.pre_state")
        guard pre.value != probeValue else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.pre_state: the track already carries the probe value — an earlier run "
                    + "left it behind and this cycle cannot tell a move from a no-op")
        }
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["target_ref": pre.trackRef, readbackField: probeValue], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        var needsRestore = true
        var nameCustodyLost = false
        defer {
            if needsRestore && !nameCustodyLost {
                var cleanupID = nextID + 900
                for _ in 0..<4 {
                    guard let current = try? observedTrackString(
                        session, id: cleanupID, trackIndex: 0, field: readbackField,
                        phase: "phase_b.cleanup_preflight"),
                        current.trackRef == pre.trackRef, current.value == probeValue else { break }
                    cleanupID += 2
                    guard let cleanup = try? invoke(
                        session, id: cleanupID, tool: spec.tool.rawValue, command: spec.command,
                        params: ["target_ref": pre.trackRef, readbackField: pre.value], phase: "phase_b.cleanup",
                        timeout: spec.deadline.seconds + 5) else { break }
                    cleanupID += 1
                    if let delay = Self.cleanupGateReclaimDelay(cleanup) {
                        cleanupSleep(delay)
                        continue
                    }
                    guard let seen = try? observedTrackString(
                        session, id: cleanupID, trackIndex: 0, field: readbackField,
                        phase: "phase_b.cleanup_readback") else { break }
                    cleanupID += 2
                    guard seen.trackRef == pre.trackRef else { break }
                    if seen.value == pre.value { break }
                }
            }
        }
        nameCustodyLost = true
        let after = try observedTrackString(
            session, id: readStep(), trackIndex: 0, field: readbackField,
            phase: "phase_b.readback")
        guard after.trackRef == pre.trackRef else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: track identity changed; inverse and cleanup withheld")
        }
        nameCustodyLost = false
        guard after.value == probeValue else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: \(readbackField) is \(after.value), expected the probe value")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["target_ref": pre.trackRef, readbackField: pre.value], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the restore: "
                    + restore.text.prefix(220))
        }
        nameCustodyLost = true
        let restored = try observedTrackString(
            session, id: readStep(), trackIndex: 0, field: readbackField,
            phase: "phase_b.restore_readback")
        guard restored.trackRef == pre.trackRef else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: track identity changed; cleanup withheld")
        }
        nameCustodyLost = false
        guard restored.value == pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: \(readbackField) is \(restored.value), expected "
                    + "\(pre.value)")
        }
        needsRestore = false
        return (
            QualificationMutationRestoreRecord(
                operationID: spec.id.rawValue,
                preState: pre.raw,
                mutation: mutation.text,
                readback: after.raw,
                restore: restore.text,
                restoreReadback: restored.raw
            ),
            nextID
        )
    }

    private func observedTrackString(
        _ session: QualificationSubprocessSession,
        id: Int,
        trackIndex: Int,
        field: String,
        phase: String
    ) throws -> (value: String, trackRef: String, raw: String) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(session, id: id + 1, uri: "logic://tracks", phase: phase)
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]],
              trackIndex < rows.count,
              let value = rows[trackIndex][field] as? String,
              let trackRef = rows[trackIndex]["track_ref"] as? String, !trackRef.isEmpty,
              rows.filter({ $0["track_ref"] as? String == trackRef }).count == 1 else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks did not report \(field) and a unique track_ref for track \(trackIndex)")
        }
        return (value, trackRef, raw)
    }

    /// Which half of the undo stack a `historyRestoreCycle` run is exercising.
    enum HistoryDirection: Sendable {
        case undo
        case redo
    }

    /// #373 Phase B for `edit.undo` and `edit.redo`.
    ///
    /// These are the clearest case the whole mode exists for. Measured 2026-09-14: `edit.undo`
    /// reverses a track rename and reports **State B** for it —
    /// `reason: noop_unobservable`, `verify_source: ax_edit_menu_entry`, with the detail that "the
    /// Edit menu names the same entry before and after, so this surface cannot separate a stack
    /// that moved from one that did not". The operation is right to refuse: the menu entry genuinely
    /// cannot tell it. `logic://tracks` can, and supplying the confirmation the operation could not
    /// obtain is precisely what a Phase B recipe is.
    ///
    /// The cycle manufactures its own undoable edit rather than undoing whatever the operator did
    /// last. Pressing undo against an unknown stack top is not a qualification; it is an edit to
    /// somebody else's project whose effect this recipe could not even name.
    func historyRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        direction: HistoryDirection
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        let trackIndex = 0
        let probeName = "qualification_phase_b_probe"
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let original = try observedTrackString(
            session, id: readStep(), trackIndex: trackIndex, field: "name",
            phase: "phase_b.stage_precondition")
        guard original.value != probeName else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage_precondition: track \(trackIndex) is already called \(probeName) "
                    + "— an earlier run left it, and this cycle cannot tell its own edit from that "
                    + "one")
        }
        // Arm the exact-reference cleanup BEFORE staging. The server can apply the rename and then
        // return an operation-timeout response, or the client can reach its own deadline before the
        // response arrives. In either case the first throwing exit is already past the write even
        // though this function has not received a successful reply yet.
        //
        // The cleanup preflight distinguishes a refused zero-write request from that late write:
        // the original value needs no action, while only this cycle's probe value may be restored.
        // It never guesses through a changed reference or a third-party value.
        let nameNeedsRestoring = true
        var nameCustodyLost = false
        defer {
            if nameNeedsRestoring && !nameCustodyLost {
                var cleanupID = nextID + 900
                for _ in 0..<4 {
                    guard let seen = try? observedTrackString(
                        session, id: cleanupID, trackIndex: trackIndex, field: "name",
                        phase: "phase_b.cleanup_readback") else { break }
                    cleanupID += 2
                    guard seen.trackRef == original.trackRef else { break }
                    if seen.value == original.value { break }
                    guard seen.value == probeName else { break }
                    guard let cleanup = try? invoke(
                        session, id: cleanupID, tool: "logic_tracks", command: "rename",
                        params: ["target_ref": original.trackRef, "name": original.value],
                        phase: "phase_b.cleanup",
                        timeout: spec.deadline.seconds + 5) else { break }
                    cleanupID += 1
                    if let delay = Self.cleanupGateReclaimDelay(cleanup) {
                        cleanupSleep(delay)
                    }
                }
            }
        }
        let staged = try invoke(
            session, id: step(), tool: "logic_tracks", command: "rename",
            params: ["target_ref": original.trackRef, "name": probeName], phase: "phase_b.stage",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(staged.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage: rename refused, so there is no edit for \(spec.id.rawValue) to "
                    + "move over: " + staged.text.prefix(220))
        }
        nameCustodyLost = true
        let renamed = try observedTrackString(
            session, id: readStep(), trackIndex: trackIndex, field: "name",
            phase: "phase_b.stage_readback")
        guard renamed.trackRef == original.trackRef else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage_readback: track identity changed; history and cleanup withheld")
        }
        nameCustodyLost = false
        guard renamed.value == probeName else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage_readback: track \(trackIndex) reads \(renamed.value), so the edit "
                    + "this cycle meant to stage is not on the stack")
        }
        if direction == .redo {
            // `redo` needs something to redo, so the staged edit is undone FIRST. That undo is
            // arrangement, not evidence: it is not what the record reports on, and if it fails the
            // cycle refuses rather than reporting a redo that had nothing to move.
            _ = try invoke(
                session, id: step(), tool: spec.tool.rawValue, command: "undo", params: [:],
                phase: "phase_b.stage_undo")
            nameCustodyLost = true
            let reverted = try observedTrackString(
                session, id: readStep(), trackIndex: trackIndex, field: "name",
                phase: "phase_b.stage_undo_readback")
            guard reverted.trackRef == original.trackRef else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.stage_undo_readback: track identity changed; history and cleanup withheld")
            }
            nameCustodyLost = false
            guard reverted.value == original.value else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.stage_undo_readback: track \(trackIndex) reads \(reverted.value), "
                        + "so there is nothing for redo to move forward to")
            }
        }

        let expectedAfter = direction == .undo ? original.value : probeName
        let expectedRestored = direction == .undo ? probeName : original.value
        let restoreCommand = direction == .undo ? "redo" : "undo"

        nameCustodyLost = true
        let pre = try observedTrackString(
            session, id: readStep(), trackIndex: trackIndex, field: "name",
            phase: "phase_b.pre_state")
        guard pre.trackRef == original.trackRef else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.pre_state: track identity changed; history and cleanup withheld")
        }
        nameCustodyLost = false
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command, params: [:],
            phase: "phase_b.mutation", timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        nameCustodyLost = true
        let after = try observedTrackString(
            session, id: readStep(), trackIndex: trackIndex, field: "name",
            phase: "phase_b.readback")
        guard after.trackRef == original.trackRef else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: track identity changed; inverse and cleanup withheld")
        }
        nameCustodyLost = false
        guard after.value == expectedAfter else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: track \(trackIndex) reads \(after.value), expected "
                    + "\(expectedAfter)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: restoreCommand, params: [:],
            phase: "phase_b.restore")
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(restoreCommand) refused the restore: "
                    + restore.text.prefix(220))
        }
        nameCustodyLost = true
        let restored = try observedTrackString(
            session, id: readStep(), trackIndex: trackIndex, field: "name",
            phase: "phase_b.restore_readback")
        guard restored.trackRef == original.trackRef else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: track identity changed; cleanup withheld")
        }
        nameCustodyLost = false
        guard restored.value == expectedRestored else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: track \(trackIndex) reads \(restored.value), expected "
                    + "\(expectedRestored)")
        }
        // The cycle is closed and the track may still be called `probeName` — for `undo` the
        // restore is a redo, which puts the staged name back. The cleanup below is what returns the
        // fixture, and the flag stays set so it runs.
        _ = nameNeedsRestoring
        return (
            QualificationMutationRestoreRecord(
                operationID: spec.id.rawValue,
                preState: pre.raw,
                mutation: mutation.text,
                readback: after.raw,
                restore: restore.text,
                restoreReadback: restored.raw
            ),
            nextID
        )
    }

    /// #373 Phase B for a PARAMETERLESS toggle, where the same call is both the mutation and the
    /// restore.
    ///
    /// `transport.toggle_cycle` takes nothing and flips a flag, so unlike `tracks.mute` there is no
    /// value to ask for — the second call is what puts it back. That makes the restore assertion
    /// carry more weight here, not less: if the operation is not idempotent in the way its name
    /// claims, the flag ends up somewhere other than where it started and the cycle refuses.
    func parameterlessToggleRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        readbackField: String
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let pre = try observedTransportFlag(
            session, id: readStep(), field: readbackField, phase: "phase_b.pre_state", deadline: spec.deadline)
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: [:], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTransportFlag(
            session, id: readStep(), field: readbackField, phase: "phase_b.readback", deadline: spec.deadline)
        guard after.value == !pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: \(readbackField) is \(after.value), expected \(!pre.value)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: [:], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
        guard restore.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the second call")
        }
        let restored = try observedTransportFlag(
            session, id: readStep(), field: readbackField, phase: "phase_b.restore_readback", deadline: spec.deadline)
        guard restored.value == pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: \(readbackField) is \(restored.value), expected "
                    + "\(pre.value) — the second call did not put it back")
        }
        return (
            QualificationMutationRestoreRecord(
                operationID: spec.id.rawValue,
                preState: pre.raw,
                mutation: mutation.text,
                readback: after.raw,
                restore: restore.text,
                restoreReadback: restored.raw
            ),
            nextID
        )
    }

    private func observedTransportFlag(
        _ session: QualificationSubprocessSession,
        id: Int,
        field: String,
        phase: String,
        deadline: DeadlineClass
    ) throws -> (value: Bool, raw: String) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(
            session, id: id + 1, uri: "logic://transport/state", phase: phase)
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let state = payload["state"] as? [String: Any],
              let value = state[field] as? Bool else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://transport/state did not report \(field)")
        }
        // A current observation is required before staging or reversing a toggle,
        // even when the operation's ordinary verification policy is best effort.
        let freshness = QualificationReadbackFreshness.verdict(
            for: data, uri: "logic://transport/state", verification: .readbackRequired, deadline: deadline)
        guard object["unverified"] as? Bool != true, freshness.isAdmissible else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): transport flag observation refused: \(freshness.refusalReason ?? "readback_unverified")")
        }
        return (value, raw)
    }

    /// Parameterless transport toggles and the transport-state flag each one flips.
    ///
    /// `transport.record` is deliberately ABSENT. It reaches State A and moves `isRecording`, so it
    /// would qualify — and it also records into the project, which makes its restore an undo of a
    /// region rather than a second toggle. That belongs to the destructive phase with a disposable
    /// fixture, not here, and adding it would have bought a passing count at the price of editing
    /// the project this recipe is supposed to leave alone.
    static let parameterlessToggleField: [OperationID: String] = [
        .transportToggleCycle: "isCycleEnabled",
        .transportToggleMetronome: "isMetronomeEnabled",
        .transportToggleCountIn: "isCountInEnabled",
        .transportToggleAutopunch: "isAutopunchEnabled",
    ]
}
