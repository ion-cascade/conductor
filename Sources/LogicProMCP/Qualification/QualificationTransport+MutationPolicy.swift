import Foundation

extension QualificationTransport {
    static func mutationRestorePolicy(
        for operation: OperationID
    ) -> QualificationMutationRestorePolicy? {
        if trackCreateRestoreOperations.contains(operation) { return .trackCreate }
        if operation == .tracksDelete { return .trackDelete }
        if let field = valueRestoreReadbackField[operation] { return .trackNumeric(field: field) }
        if let field = booleanToggleReadbackField[operation] { return .trackBoolean(field: field) }
        if operation == .tracksRename || historyRestoreDirection[operation] != nil { return .trackName }
        if operation == .tracksSelect { return .trackSelection }
        if transportExpectedPlaying[operation] != nil {
            if operation == .transportPause { return .transportMotion(expected: .paused) }
            return .transportMotion(expected: operation == .transportPlay ? .moving : .stopped)
        }
        if let field = parameterlessToggleField[operation] { return .transportToggle(field: field) }
        if operation == .transportSetTempo { return .tempo }
        if let direction = playheadStepDirections[operation] { return .playheadStep(direction: direction) }
        if operation == .systemExportSupportBundle { return .ownedFileArtifact }
        if playheadRestoreOperations.contains(operation) || operation == .navigateGotoMarker {
            return .playheadPosition
        }
        if operation == .navigateCreateMarker || markerStagedRestoreMode[operation] != nil {
            return .markerNames
        }
        return nil
    }

    /// Which staged-marker shape a `markerStagedRestoreCycle` run is exercising.
    enum MarkerStagedMode: Sendable {
        /// `navigate.rename_marker`: write a new name, read it back, write the old one.
        case rename
        /// `navigate.delete_marker`: remove the staged marker, read its absence, re-create it.
        case delete
    }

    /// ADR-001-c / #373 Phase B: the write-and-readback cycle, on one operation.
    ///
    /// The issue's own status line said Phase B "needs a write-and-read-back qualification mode,
    /// which does not exist" — and the record type for it DID exist, with exactly these five
    /// fields, while nothing in the tree constructed one. This is that constructor.
    ///
    /// `tracks.set_mute` is the first operation to get a recipe because it is the safest shape the
    /// registry has: `Mutability.mutating`, reversible by definition, and with an independent
    /// readback (`logic://tracks`) that is not the write's own answer. The cycle is
    /// pre-state → mutation → readback → restore → restore-readback, and EVERY step is checked:
    ///
    ///   * the mutation must actually flip the observed state, or an operation that did nothing
    ///     would pass by agreeing with a stale reading;
    ///   * the restore must return it to the pre-state EXACTLY, read back rather than assumed.
    ///
    /// A record is returned ONLY when all of that held. There is no failure case in the record
    /// type, and that absence is the guard: a cycle that did not verify produces no evidence, so
    /// `status` cannot see one.
    func booleanToggleRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        readbackField: String
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        let trackIndex = 0
        var nextID = id
        // Each observation spends TWO ids — a refresh and the resource read — so the step counter
        // advances by two for reads and one for writes.
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        // STAGE THE PRECONDITION the actuator documents, and put the selection back afterwards.
        // The prior selection is read first so the restore returns the operator's own row rather
        // than one this recipe manufactured.
        var priorSelection: Int?
        if Self.requiresExclusiveSelection.contains(spec.id) {
            let before = try observedSelectedTrackIndex(
                session, id: nextID, phase: "phase_b.selection_precondition")
            nextID += before.spent
            priorSelection = before.index
            if before.index != trackIndex {
                _ = try invoke(
                    session, id: step(), tool: spec.tool.rawValue, command: "select",
                    params: ["index": trackIndex], phase: "phase_b.selection_precondition",
                    timeout: spec.deadline.seconds + 5)
                let staged = try observedSelectedTrackIndex(
                    session, id: nextID, phase: "phase_b.selection_precondition_readback")
                nextID += staged.spent
                guard staged.index == trackIndex else {
                    throw QualificationTransportError.protocolViolation(
                        "phase_b.selection_precondition: track \(trackIndex) is not the selected "
                            + "row (\(staged.index.map(String.init) ?? "none")), and "
                            + "\(spec.id.rawValue) refuses to write onto a selection it does not own")
                }
            }
        }
        defer {
            if let priorSelection, priorSelection != trackIndex {
                _ = try? invoke(
                    session, id: nextID + 800, tool: spec.tool.rawValue, command: "select",
                    params: ["index": priorSelection], phase: "phase_b.selection_restore")
            }
        }

        // A POLLED read spends more than two ids, so each one advances `nextID` by what it
        // actually spent. Keeping `readStep()`'s fixed two here would hand a later step an id this
        // read had already used, and the transport matches responses by id.
        let pre = try observedTrackFlag(
            session, id: nextID, trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.pre_state")
        nextID += pre.spent
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": trackIndex, "enabled": !pre.value], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTrackFlag(
            session, id: nextID, trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.readback", awaiting: !pre.value)
        nextID += after.spent
        guard after.value == !pre.value else {
            // CARRY THE OPERATION'S OWN ANSWER. Without it this refusal says only that a field did
            // not move and discards the one thing that says WHY — measured 2026-09-14, when
            // `tracks.arm` failed here inside the sweep while the identical call moved the flag in
            // a standalone drive, and the envelope that would have separated the two was gone.
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: \(readbackField) did not move — observed \(after.value), "
                    + "expected \(!pre.value); the operation answered: "
                    + mutation.text.prefix(300))
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": trackIndex, "enabled": pre.value], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the restore: "
                    + restore.text.prefix(220))
        }
        let restored = try observedTrackFlag(
            session, id: nextID, trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.restore_readback", awaiting: pre.value)
        nextID += restored.spent
        guard restored.value == pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: \(readbackField) not restored — observed "
                    + "\(restored.value), expected \(pre.value); the restore answered: "
                    + restore.text.prefix(300))
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
}
