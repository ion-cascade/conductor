import Foundation

extension QualificationTransport {
    /// #373 Phase B for a CREATE, whose restore is a delete.
    ///
    /// The other machines move something that already exists and put it back. This one brings
    /// something into being and must remove it, which makes the restore the part that matters: a
    /// cycle that created a marker and left it behind would have changed the project while
    /// reporting success.
    func markerCreateRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        let probeName = "qualification_phase_b_probe"
        let pre = try observedMarkerCount(
            session, id: nextID, settling: .read, phase: "phase_b.pre_state")
        guard markerIndex(named: probeName, in: pre.raw) == nil else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.pre_state: a marker named \(probeName) is already in the project — an "
                    + "earlier run left it, and this cycle cannot tell its own marker from that one")
        }
        nextID += pre.spent
        let mutation = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: spec.command,
            params: ["name": probeName], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        // FROM HERE ON A MARKER EXISTS, so every exit has to remove it. Measured 2026-09-14: a run
        // whose cycle refused after the create left `qualification_phase_b_probe` in the project,
        // and the NEXT run's `create_marker` then refused because of it — one failure became a
        // permanent one, and the fixture needed manual cleaning. A create-shaped recipe that can
        // throw between the create and the delete is a recipe that edits the project on failure.
        var createdMarkerNeedsRemoval = true
        defer {
            if createdMarkerNeedsRemoval {
                // THE CLEANUP VERIFIES. A first version issued one best-effort delete and moved on,
                // and a live run still left `qualification_phase_b_probe` in the project —
                // the marker list settles slowly enough that a single unchecked delete is not a
                // removal, it is a request. An unverified cleanup is the same shape as the
                // unverified success claims this whole change exists to remove, so it retries until
                // the count is back where it started or its budget runs out.
                var cleanupID = nextID + 900
                for _ in 0..<4 {
                    guard let seen = try? observedMarkerCount(
                        session, id: cleanupID, settling: .read, phase: "phase_b.cleanup_readback"
                    ) else { break }
                    cleanupID += seen.spent
                    guard let index = markerIndex(named: probeName, in: seen.raw) else { break }
                    _ = try? invoke(
                        session, id: cleanupID, tool: spec.tool.rawValue, command: "delete_marker",
                        params: ["index": index], phase: "phase_b.cleanup")
                    cleanupID += 1
                }
            }
        }

        let after = try observedMarkerCount(
            session, id: nextID, settling: .names(present: [probeName], absent: []),
            phase: "phase_b.readback")
        nextID += after.spent
        guard after.count == pre.count + 1 else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: marker count is \(after.count), expected \(pre.count + 1)")
        }
        // Delete the one just added, found BY NAME. See `markerIndex(named:in:)`.
        guard let createdIndex = markerIndex(named: probeName, in: after.raw) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: the marker count rose but no row carries \(probeName) — the "
                    + "cycle cannot identify what it created and will not delete by guess")
        }
        let restore = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: "delete_marker",
            params: ["index": createdIndex], phase: "phase_b.restore")
        nextID += 1
        guard restore.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: delete_marker refused — the probe marker is still in the project")
        }
        let restored = try observedMarkerCount(
            session, id: nextID, settling: .names(present: [], absent: [probeName]),
            phase: "phase_b.restore_readback")
        nextID += restored.spent
        guard restored.count == pre.count, markerIndex(named: probeName, in: restored.raw) == nil else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: marker count is \(restored.count), expected "
                    + "\(pre.count), and \(probeName) must be absent — a balanced count is not "
                    + "proof the right marker went")
        }
        // The restore is confirmed, so the cleanup above has nothing left to do. Clearing the flag
        // here rather than earlier keeps the window it covers exactly the window where a marker
        // exists and has not been proven gone.
        createdMarkerNeedsRemoval = false
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

    /// #373 Phase B for the two marker operations that need a marker to already be there:
    /// `navigate.rename_marker` and `navigate.delete_marker`.
    ///
    /// Both are run against a marker this cycle STAGES, never against one the project came with.
    /// That is the difference between qualifying an operation and editing the user's arrangement to
    /// do it: a rename cycle that borrowed an existing marker would be correct on paper — it puts
    /// the name back — and would still have written to something it did not own, with a window
    /// where a crash leaves that marker called `qualification_phase_b_probe`.
    ///
    /// The staged marker means the record's `preState` is the list AFTER staging, which is the
    /// honest pre-state OF THE MUTATION rather than of the run. The staging create and the final
    /// removal both sit outside the record, and the removal is verified on every exit for the
    /// reason `markerCreateRestoreCycle` records: an unverified cleanup is a request.
    func markerStagedRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        mode: MarkerStagedMode
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        let probeName = "qualification_phase_b_probe"
        let renamedName = "qualification_phase_b_renamed"

        let original = try observedMarkerCount(
            session, id: nextID, settling: .read, phase: "phase_b.stage_precondition")
        nextID += original.spent
        for leftover in [probeName, renamedName] where markerIndex(named: leftover, in: original.raw) != nil {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage_precondition: a marker named \(leftover) is already in the project "
                    + "— an earlier run left it, and this cycle cannot tell its own marker from "
                    + "that one")
        }
        let staged = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: "create_marker",
            params: ["name": probeName], phase: "phase_b.stage")
        nextID += 1
        guard !Self.mutationSaysItFailed(staged.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage: create_marker refused, so there is nothing to exercise "
                    + "\(spec.id.rawValue) against: " + staged.text.prefix(220))
        }
        // A MARKER NOW EXISTS under one of two names, and every exit from here has to remove it.
        // `let` for the same reason as the history cycle: the staged marker is still there when the
        // record closes, because that is what "restored" means for a rename or a delete.
        let stagedMarkerNeedsRemoval = true
        defer {
            if stagedMarkerNeedsRemoval {
                var cleanupID = nextID + 900
                for _ in 0..<6 {
                    guard let seen = try? observedMarkerCount(
                        session, id: cleanupID, settling: .read, phase: "phase_b.cleanup_readback"
                    ) else { break }
                    cleanupID += seen.spent
                    // The mutation under test may have renamed it, so the cleanup looks for BOTH
                    // names. A cleanup that only knew the name it staged would leave the marker
                    // behind exactly when the rename half-succeeded.
                    let index = markerIndex(named: probeName, in: seen.raw)
                        ?? markerIndex(named: renamedName, in: seen.raw)
                    guard let index else { break }
                    _ = try? invoke(
                        session, id: cleanupID, tool: spec.tool.rawValue, command: "delete_marker",
                        params: ["index": index], phase: "phase_b.cleanup")
                    cleanupID += 1
                }
            }
        }

        let pre = try observedMarkerCount(
            session, id: nextID, settling: .names(present: [probeName], absent: []),
            phase: "phase_b.pre_state")
        nextID += pre.spent
        guard let stagedIndex = markerIndex(named: probeName, in: pre.raw) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.pre_state: the staged marker \(probeName) is not in the list, so the "
                    + "cycle has no target it can name")
        }

        let mutationParams: [String: Any] = switch mode {
        case .rename: ["index": stagedIndex, "name": renamedName]
        case .delete: ["index": stagedIndex]
        }
        let mutation = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: spec.command,
            params: mutationParams, phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }

        // WAIT ON THE NAME, not the length. A rename leaves the count where it was, so a
        // count-settled read is satisfied by the list as it stood BEFORE the write and the cycle
        // then refuses a rename Logic actually performed — measured 2026-09-14, on this recipe's
        // first live run.
        let afterSettle: MarkerSettle = switch mode {
        case .rename: .names(present: [renamedName], absent: [probeName])
        case .delete: .names(present: [], absent: [probeName])
        }
        let after = try observedMarkerCount(
            session, id: nextID, settling: afterSettle, phase: "phase_b.readback")
        nextID += after.spent
        switch mode {
        case .rename:
            guard after.count == pre.count,
                  markerIndex(named: probeName, in: after.raw) == nil,
                  markerIndex(named: renamedName, in: after.raw) != nil else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: after rename_marker the list must carry \(renamedName) and "
                        + "not \(probeName), at an unchanged count of \(pre.count); it reports "
                        + "\(after.count)")
            }
        case .delete:
            guard after.count == pre.count - 1,
                  markerIndex(named: probeName, in: after.raw) == nil else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: after delete_marker \(probeName) must be absent at a count "
                        + "of \(pre.count - 1); the list reports \(after.count)")
            }
        }

        // The restore's target is resolved AGAIN from the readback rather than reused from the
        // pre-state. A delete shifts every later row down, so an index captured before the mutation
        // names a different marker afterwards — the mistake that made an earlier version of the
        // create cycle delete other people's markers while the count balanced.
        let restoreCommand: String
        let resolvedRestoreParams: [String: Any]
        switch mode {
        case .rename:
            guard let renamedIndex = markerIndex(named: renamedName, in: after.raw) else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: \(renamedName) is not in the list, so the restore has no "
                        + "target it can name")
            }
            restoreCommand = spec.command
            resolvedRestoreParams = ["index": renamedIndex, "name": probeName]
        case .delete:
            restoreCommand = "create_marker"
            resolvedRestoreParams = ["name": probeName]
        }
        let restore = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: restoreCommand,
            params: resolvedRestoreParams, phase: "phase_b.restore")
        nextID += 1
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(restoreCommand) refused the restore: "
                    + restore.text.prefix(220))
        }
        let restored = try observedMarkerCount(
            session, id: nextID,
            settling: .names(present: [probeName], absent: [renamedName]),
            phase: "phase_b.restore_readback")
        nextID += restored.spent
        guard restored.count == pre.count,
              markerIndex(named: probeName, in: restored.raw) != nil,
              markerIndex(named: renamedName, in: restored.raw) == nil else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: the list must be back to \(pre.count) rows carrying "
                    + "\(probeName) and not \(renamedName); it reports \(restored.count)")
        }

        // The staged marker is still there — it is what "restored" means for these two — so the
        // cleanup above is still owed, and the flag stays set. The record closes here; removing the
        // staging is not part of what the operation is being qualified for.
        _ = stagedMarkerNeedsRemoval
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

    /// #373 Phase C: the track operations that are each other's restore.
    ///
    /// **NOT ENABLED, and the reason is a defect in this cycle's own verification.** It compares
    /// TRACK COUNTS, and a count is not a stable quantity here: `logic://tracks` reports the rows
    /// the arrange rail is showing, so expanding a track stack changes what the number counts
    /// without changing the project. Measured 2026-09-15 on the operator's project — before a
    /// sweep, 19 rows, `complete: false`, `collapsed_track_stack`, first row `Absolute Zero`;
    /// after, 19 rows, `complete: true`, first row `오디오 1`. The count matched and the content
    /// did not: the stack had expanded and a track this cycle created was still there. The
    /// count-based leak check passed a run that had left a track behind.
    ///
    /// The cycle's own reference checks are right — it deletes the `track_ref` that was not there
    /// before, and verifies that reference is gone. What is wrong is the SURROUNDING claim that a
    /// matching count means nothing was left. Fixing that means verifying against the reference SET
    /// rather than its size, and refusing outright when `complete` changes between the two reads,
    /// because then the two readings are not of the same thing.
    ///
    /// `create_audio` and `create_instrument` add a track; `delete` removes one. That makes a
    /// create-then-delete a COMPLETE cycle on the operator's own project — the same shape
    /// `markerCreateRestoreCycle` already proved — and it means these three do not have to wait for
    /// a disposable-project phase to carry evidence. The destructive operations that genuinely need
    /// one are the ones with no inverse.
    ///
    /// The created track is identified by its `track_ref`, never by an index. A delete addressed by
    /// position is the mistake that made an earlier marker cycle remove somebody else's marker
    /// while its count still balanced, and a track is a more expensive thing to lose.
    func trackCreateRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        cleanup: PhaseCCleanupWitness
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id

        let pre = try observedTrackInventory(session, id: nextID, phase: "phase_c.pre_state")
        nextID += pre.spent
        let mutation = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: spec.command, params: [:],
            phase: "phase_c.mutation", timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        // A TRACK NOW EXISTS and every exit has to remove it. A create cycle that can throw between
        // the create and the delete is a cycle that edits the project on failure — the lesson the
        // marker cycle paid for, and a track costs more than a marker.
        var createdNeedsRemoval = true
        // THE HANDLE THE CYCLE OWNS. Set once, at the instant the new track is unambiguous, and
        // read by the cleanup below. Asking again later is what failed: by the time the cleanup
        // runs, the only question it could ask was "what did the create say it made", and a create
        // whose modal reconciliation came back incomplete says nothing at all.
        var createdHandle: String?
        defer {
            if createdNeedsRemoval {
                var cleanupID = nextID + 900
                cleanup.note("entered")
                for attempt in 0..<3 {
                    cleanup.note("attempt \(attempt)")
                    // WAIT for the extra track before concluding there is none. The first version
                    // read ONCE with no settle and `break`ed when it saw nothing extra — so a
                    // create that landed AFTER the readback budget was never cleaned up. Measured
                    // 2026-09-15: two sweeps later the operator's project carried a leaked
                    // `오디오 2` and a pre-state of 22 tracks where the live project has 19. This
                    // is the same class the marker cycle paid for, and it bit again because a
                    // track create is slower than a marker create.
                    guard let seen = try? observedTrackInventory(
                        session, id: cleanupID, awaitingCount: pre.count + 1,
                        phase: "phase_c.cleanup_readback") else {
                        cleanup.note("inventory read FAILED")
                        break
                    }
                    cleanupID += seen.spent
                    cleanup.note("saw \(seen.count) rows complete=\(String(describing: seen.complete))")
                    // The SAME narrow rule the readback uses: the created name AND a reference
                    // that is new, with exactly one match. A cleanup allowed to delete "anything
                    // new" is the hazard, not the safety net — under a stack expansion every newly
                    // visible child looks new.
                    // THREE WAYS TO NAME IT, in order of how much the cycle controls them, and a
                    // refusal when none answers. The carried handle is the cycle's own and needs no
                    // one else's readback; the create's reported name is what the first version
                    // relied on ALONE, and a run that landed carried none of it; the selection is
                    // re-derived here for the case where the handle was never set because the
                    // readback itself threw.
                    let byHandle = createdHandle.flatMap { seen.refs.contains($0) ? $0 : nil }
                    let byName = Self.soleCreatedTrack(
                        named: Self.createdTrackName(from: mutation.text),
                        in: seen.rows, excluding: pre.refs)
                    let bySelection = Self.soleNewlySelectedTrack(
                        in: seen.rows, excluding: pre.refs)
                    guard let extra = byHandle ?? byName ?? bySelection else {
                        cleanup.note("no handle: carried="
                            + (createdHandle ?? "<none>")
                            + " name=" + (Self.createdTrackName(from: mutation.text) ?? "<none reported>")
                            + " selection=<none sole> — nothing deleted")
                        break
                    }
                    cleanup.note("deleting \(extra) via "
                        + (byHandle != nil ? "carried handle"
                            : byName != nil ? "reported name" : "selection"))
                    _ = try? invoke(
                        session, id: cleanupID, tool: "logic_tracks", command: "delete",
                        params: ["target_ref": extra], phase: "phase_c.cleanup")
                    cleanupID += 1
                    // AND VERIFY IT WENT. An unverified delete is a request, not a removal — the
                    // sentence the marker cycle already carries, applied to a costlier object.
                    guard let after = try? observedTrackInventory(
                        session, id: cleanupID, awaitingCount: pre.count,
                        phase: "phase_c.cleanup_verify") else {
                        cleanup.note("verify read FAILED — removal unconfirmed")
                        break
                    }
                    cleanupID += after.spent
                    if !after.refs.contains(extra) {
                        cleanup.note("confirmed gone")
                        break
                    }
                    cleanup.note("still present after delete")
                }
            }
        }

        let after = try observedTrackInventory(
            session, id: nextID, awaitingCount: pre.count + 1, phase: "phase_c.readback")
        nextID += after.spent
        // A COUNT IS NOT A STABLE QUANTITY HERE. `logic://tracks` reports the rows the arrange rail
        // is SHOWING, so expanding a track stack changes what the number counts without changing
        // the project. Measured 2026-09-15: a run this check called clean had swapped the
        // operator's first track for one of its own — 19 rows before and 19 after, `complete`
        // false then true. Two readings taken at different completeness are not readings of the
        // same thing, and the cycle refuses rather than comparing them.
        guard after.complete == pre.complete else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: the track rail's completeness changed between readings "
                    + "(\(String(describing: pre.complete)) -> \(String(describing: after.complete))), "
                    + "so the before and after are not readings of the same thing")
        }
        guard Set(after.refs).isSuperset(of: pre.refs), after.count == pre.count + 1 else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: the pre-state references must all still be present and exactly "
                    + "one must be added; count is \(after.count), expected \(pre.count + 1); "
                    + "the operation answered: " + mutation.text.prefix(220))
        }
        // The created track must match BOTH what the operation says it made and a reference that
        // was not in the pre-state, and there must be exactly one such track. "Any new reference"
        // is not safe: under a stack expansion every newly visible child is new.
        // The created track must be identified by something OBSERVED, and the first version of this
        // accepted exactly one source: the name the create reported. Measured 2026-09-15, a create
        // that landed reported no name at all, so the cycle had nothing to remove and left the
        // track in the operator's project. Logic SELECTS a newly created track and it is the only
        // selected one, so the selection answers where the report does not — and neither source is
        // allowed to point at a reference that was already there.
        let createdName = Self.createdTrackName(from: mutation.text)
        let named = Self.soleCreatedTrack(named: createdName, in: after.rows, excluding: pre.refs)
        let selected = Self.soleNewlySelectedTrack(in: after.rows, excluding: pre.refs)
        guard let createdRef = named ?? selected else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: \(spec.id.rawValue) left exactly one new track but the cycle "
                    + "cannot say which: the reported name is "
                    + (createdName.map { "'\($0)'" } ?? "absent")
                    + " and no single new row is selected — it will not delete by guess")
        }
        // Two sources that answer with DIFFERENT tracks is not a tie to break. One of them is wrong
        // and the cycle does not know which, so it removes nothing.
        if let named, let selected, named != selected {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: the reported name points at \(named) and the selection at "
                    + "\(selected); the cycle deletes only what both agree on or what only one "
                    + "of them can see")
        }
        createdHandle = createdRef
        let restore = try invoke(
            session, id: nextID, tool: "logic_tracks", command: "delete",
            params: ["target_ref": createdRef], phase: "phase_c.restore",
            timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore: delete refused — the created track is still in the project: "
                    + restore.text.prefix(220))
        }
        let restored = try observedTrackInventory(
            session, id: nextID, awaitingCount: pre.count, phase: "phase_c.restore_readback")
        nextID += restored.spent
        guard restored.complete == pre.complete else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore_readback: the track rail's completeness changed "
                    + "(\(String(describing: pre.complete)) -> \(String(describing: restored.complete))), "
                    + "so this reading cannot be compared with the pre-state")
        }
        // THE SET, not its size. A balanced count is not proof the right track went — and on a
        // project with a track stack it is not even proof the same rows are being counted.
        guard Set(restored.refs) == Set(pre.refs) else {
            let lost = Set(pre.refs).subtracting(restored.refs)
            let extra = Set(restored.refs).subtracting(pre.refs)
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore_readback: the project did not come back — "
                    + "\(lost.count) reference(s) missing, \(extra.count) left behind")
        }
        createdNeedsRemoval = false
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

    /// #373 Phase C for `tracks.delete`, against a track the cycle STAGES.
    ///
    /// Deleting one of the operator's tracks to prove a delete works would be the worst trade in
    /// this file. So the cycle creates its own, deletes that, and puts a track of the same kind
    /// back — and the restore is honest about what it restores: the COUNT and the KIND, not the
    /// identity. A created track has no prior identity to return to, and saying otherwise in a
    /// record that exists to be trusted would be worse than the gap it papers over.
    func trackStagedDeleteCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        let original = try observedTrackInventory(session, id: nextID, phase: "phase_c.stage_precondition")
        nextID += original.spent

        let staged = try invoke(
            session, id: nextID, tool: "logic_tracks", command: "create_audio", params: [:],
            phase: "phase_c.stage", timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(staged.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.stage: create_audio refused, so there is nothing for \(spec.id.rawValue) "
                    + "to delete: " + staged.text.prefix(220))
        }
        // A TRACK NOW EXISTS. Every exit removes it, waiting for it to appear first and verifying
        // that it went — the shape the create cycle had to learn after it leaked one.
        var stagedNeedsRemoval = true
        // The handle the cycle owns, set the moment the staged track is unambiguous. It is
        // reassigned after the restore, because by then the track this cleanup must remove is the
        // REPLACEMENT and not the one that was staged.
        var stagedHandle: String?
        defer {
            if stagedNeedsRemoval {
                var cleanupID = nextID + 900
                for _ in 0..<3 {
                    guard let seen = try? observedTrackInventory(
                        session, id: cleanupID, awaitingCount: original.count + 1,
                        phase: "phase_c.cleanup_readback") else { break }
                    cleanupID += seen.spent
                    let byHandle = stagedHandle.flatMap { seen.refs.contains($0) ? $0 : nil }
                    guard let extra = byHandle
                        ?? Self.soleCreatedTrack(
                            named: Self.createdTrackName(from: staged.text),
                            in: seen.rows, excluding: original.refs)
                        ?? Self.soleNewlySelectedTrack(in: seen.rows, excluding: original.refs)
                    else { break }
                    _ = try? invoke(
                        session, id: cleanupID, tool: "logic_tracks", command: "delete",
                        params: ["target_ref": extra], phase: "phase_c.cleanup")
                    cleanupID += 1
                    guard let after = try? observedTrackInventory(
                        session, id: cleanupID, awaitingCount: original.count,
                        phase: "phase_c.cleanup_verify") else { break }
                    cleanupID += after.spent
                    if !after.refs.contains(extra) { break }
                }
            }
        }

        let pre = try observedTrackInventory(
            session, id: nextID, awaitingCount: original.count + 1, phase: "phase_c.pre_state")
        nextID += pre.spent
        let stagedName = Self.createdTrackName(from: staged.text)
        let stagedByName = Self.soleCreatedTrack(
            named: stagedName, in: pre.rows, excluding: original.refs)
        let stagedBySelection = Self.soleNewlySelectedTrack(
            in: pre.rows, excluding: original.refs)
        guard let stagedRef = stagedByName ?? stagedBySelection else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.pre_state: create_audio left exactly one new track but the cycle cannot "
                    + "say which: the reported name is "
                    + (stagedName.map { "'\($0)'" } ?? "absent")
                    + " and no single new row is selected — it will not delete by guess")
        }
        if let stagedByName, let stagedBySelection, stagedByName != stagedBySelection {
            throw QualificationTransportError.protocolViolation(
                "phase_c.pre_state: the reported name points at \(stagedByName) and the selection "
                    + "at \(stagedBySelection); the cycle deletes only what both agree on or what "
                    + "only one of them can see")
        }
        stagedHandle = stagedRef
        let mutation = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: spec.command,
            params: ["target_ref": stagedRef], phase: "phase_c.mutation",
            timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTrackInventory(
            session, id: nextID, awaitingCount: original.count, phase: "phase_c.readback")
        nextID += after.spent
        guard after.complete == original.complete else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: the track rail's completeness changed between readings, so the "
                    + "before and after are not readings of the same thing")
        }
        guard Set(after.refs) == Set(original.refs), !after.refs.contains(stagedRef) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: the staged track must be gone at a count of \(original.count); "
                    + "the list reports \(after.count) and the reference is "
                    + (after.refs.contains(stagedRef) ? "still there" : "absent"))
        }
        stagedNeedsRemoval = false
        let restore = try invoke(
            session, id: nextID, tool: "logic_tracks", command: "create_audio", params: [:],
            phase: "phase_c.restore", timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore: create_audio refused the restore: " + restore.text.prefix(220))
        }
        stagedNeedsRemoval = true
        // THE STAGED REFERENCE IS DEAD HERE — the readback above proved it is gone. Leaving it in
        // the handle would point the cleanup at a track that no longer exists and, worse, make it
        // look like the cleanup had an answer. Clear it before the restore's own track appears.
        stagedHandle = nil
        let restored = try observedTrackInventory(
            session, id: nextID, awaitingCount: original.count + 1,
            phase: "phase_c.restore_readback")
        nextID += restored.spent
        guard restored.complete == original.complete else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore_readback: the track rail's completeness changed, so this reading "
                    + "cannot be compared with the pre-state")
        }
        // Every reference that was there before must still be there, plus exactly one new one —
        // the replacement. The restore returns the COUNT and the KIND, never the identity.
        guard Set(restored.refs).isSuperset(of: original.refs),
              restored.count == original.count + 1 else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore_readback: the pre-state references must all still be present with "
                    + "exactly one replacement added; count is \(restored.count), expected "
                    + "\(original.count + 1)")
        }
        // The replacement is what the cleanup must now remove. Same two sources, same refusal when
        // they disagree — and when neither answers the cleanup re-derives, which is why clearing
        // the dead handle above matters more than setting this one.
        let replacementByName = Self.soleCreatedTrack(
            named: Self.createdTrackName(from: restore.text),
            in: restored.rows, excluding: original.refs)
        let replacementBySelection = Self.soleNewlySelectedTrack(
            in: restored.rows, excluding: original.refs)
        if replacementByName == nil || replacementBySelection == nil
            || replacementByName == replacementBySelection {
            stagedHandle = replacementByName ?? replacementBySelection
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

    /// The reference of the sole SELECTED row whose reference is new, or nil when that is not
    /// exactly one row.
    ///
    /// The cycle cannot rely on the create to name what it created: measured 2026-09-15, a create
    /// that LANDED reported no `observed_track_name` because its own modal reconciliation came back
    /// incomplete, and the cleanup then had nothing it could safely delete. Logic selects a newly
    /// created track and it is the only selected one — measured the same day, twice — so the cycle
    /// takes THAT as its handle, once and immediately, and carries the reference rather than asking
    /// again later.
    ///
    /// The handle is a reference, never a row position. Renaming the track to a name the cycle owns
    /// would be a second identity, but `tracks.rename` is driven by a bare `index`
    /// (`AccessibilityChannel+Tracks.swift:1714`), so taking that route would put positional
    /// targeting back inside the harness to remove a dependency on a readback. The reference is
    /// already an identity the cycle controls; a second one is not worth that.
    static func soleNewlySelectedTrack(
        in rows: [[String: Any]],
        excluding preStateRefs: [String]
    ) -> String? {
        let known = Set(preStateRefs)
        let matches = rows.compactMap { row -> String? in
            guard (row["isSelected"] as? Bool) == true,
                  let ref = row["track_ref"] as? String,
                  !known.contains(ref) else { return nil }
            return ref
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// What a Phase C cleanup actually did, written as it happens so a refusal can carry it.
    ///
    /// The cleanup runs in a `defer`, after the error that triggered it was already built, so its
    /// story cannot go into that message directly. Without a witness the only thing a leak leaves
    /// behind is the leak — which is how four of them in a row got diagnosed by guesswork.
    final class PhaseCCleanupWitness: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [String] = []

        func note(_ step: String) {
            lock.lock(); defer { lock.unlock() }
            steps.append(step)
        }

        var summary: String {
            lock.lock(); defer { lock.unlock() }
            return steps.isEmpty ? "cleanup did not run" : steps.joined(separator: " -> ")
        }
    }

    /// The single track a Phase C cycle is allowed to delete, or nil when that is not exactly one.
    ///
    /// Both conditions, never one: the row carries the name the create REPORTED, and its reference
    /// was not in the pre-state. "A reference that is new" alone is unsafe — if the track stack
    /// expands mid-run every newly visible child is new, and the rule would then be free to name
    /// one of the operator's tracks.
    ///
    /// nil means REFUSE. Zero matches and several matches are both answers the caller must not
    /// paper over with a guess, and they are deliberately not distinguished here: neither one
    /// licenses a delete.
    static func soleCreatedTrack(
        named createdName: String?,
        in rows: [[String: Any]],
        excluding preStateRefs: [String]
    ) -> String? {
        guard let createdName,
              !createdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let known = Set(preStateRefs)
        let matches = rows.compactMap { row -> String? in
            guard (row["name"] as? String) == createdName,
                  let ref = row["track_ref"] as? String,
                  !known.contains(ref) else { return nil }
            return ref
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The name the create operation says it made, or nil when it could not read one.
    ///
    /// The cycles identify what they created by this name AND by a reference that was not in the
    /// pre-state — both, and exactly one candidate — instead of by "any reference that is new".
    /// Measured 2026-09-15: if the track stack EXPANDS mid-run, every newly visible child is a
    /// reference that was not in the pre-state, so the looser rule can name one of the OPERATOR'S
    /// tracks. Narrowing it is what makes that unreachable; refusing when the name is absent is
    /// what keeps a guess from filling the gap.
    private static func createdTrackName(from envelope: String) -> String? {
        guard let data = envelope.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["observed_track_name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return name
    }

    /// The track references currently in the project, with the raw body they were read from.
    ///
    /// `awaitingCount` is what the caller is waiting FOR; nil means "just read". Same discipline as
    /// the marker settle: waiting is not relaxing the assertion, the loop exits early only on the
    /// count the caller already decided is correct.
    private func observedTrackInventory(
        _ session: QualificationSubprocessSession,
        id: Int,
        awaitingCount: Int? = nil,
        phase: String
    ) throws -> (count: Int, refs: [String], rows: [[String: Any]], complete: Bool?, raw: String, spent: Int) {
        var spent = 0
        var last: (Int, [String], [[String: Any]], Bool?, String)?
        for attempt in 0..<6 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.8) }
            _ = try? invoke(
                session, id: id + spent, tool: "logic_system", command: "refresh_cache",
                params: [:], phase: "\(phase).refresh")
            spent += 1
            let data = try resourceReadback(
                session, id: id + spent, uri: "logic://tracks", phase: phase)
            spent += 1
            let raw = String(decoding: data, as: UTF8.self)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["data"] as? [[String: Any]] else {
                throw QualificationTransportError.protocolViolation(
                    "\(phase): logic://tracks did not report any rows")
            }
            let refs = rows.compactMap { $0["track_ref"] as? String }
            last = (rows.count, refs, rows, object["complete"] as? Bool, raw)
            if awaitingCount == nil || rows.count == awaitingCount { break }
        }
        guard let last else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks was never read")
        }
        return (last.0, last.1, last.2, last.3, last.4, spent)
    }

    /// #373 Phase C: the track creations whose restore is a delete of what they made.
    ///
    /// **EMPTY ON PURPOSE — the cycle is written, measured and NOT enabled.** It completes when
    /// driven on its own (create State A, delete State A, count back where it started), and a
    /// sweep driven from the CLI left the project at the count it found. A sweep driven from the
    /// live-gate test then left a track behind anyway, a second time, and the difference between
    /// those two runs is not understood.
    ///
    /// A recipe that can add a track to the operator's project and not remove it does not belong
    /// in a run that touches the operator's project, whatever its evidence would be worth. It
    /// re-enters this set when a run that leaks is understood and a run that does not is
    /// reproducible — not before, and not on the strength of one clean measurement.
    ///
    /// Membership here is what a sweep executes; the cycle below stays so the next attempt starts
    /// from measured code rather than from a description of it.
    /// ONE switch for every Phase C track cycle, because two switches is how the last leak got
    /// out: the create cycle was disabled and the staged-DELETE cycle — which stages by creating a
    /// track — was not, so it kept running and kept leaking. A kill switch that does not cover
    /// every path that writes is not a kill switch.
    ///
    /// **false** until a leaking run is explained AND a clean one is reproducible. The reference-set
    /// verification and the completeness refusal below are necessary and are not, on their own,
    /// that proof.
    static let phaseCTrackCyclesEnabled = false

    static let trackCreateRestoreOperations: Set<OperationID> = [
        .tracksCreateAudio,
        .tracksCreateInstrument,
    ]
}
