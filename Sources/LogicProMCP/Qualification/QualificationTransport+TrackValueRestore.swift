import Foundation

extension QualificationTransport {
    /// Read one track's mute state from the independent `logic://tracks` resource.
    ///
    /// The recipe below needs the SAME reading three times — before, after the write, and after the
    /// restore — and it must come from a source other than the write's own answer, or the cycle
    /// proves nothing. `logic://tracks` is that source.
    /// `awaiting` is the value the caller is WAITING FOR, and nil means "just read".
    ///
    /// A single refreshed read is enough for `mute` and `solo`, whose write and whose poller update
    /// land together. It is not enough for `arm`: measured 2026-09-14, once its write path finally
    /// worked, the cycle still refused with `isArmed did not move — observed false, expected true`
    /// while a manual drive of the same call moved the flag and read it back two seconds later.
    /// The write was fine and the reading was early.
    ///
    /// Waiting does not relax the assertion. The loop exits early ONLY on the value the caller has
    /// already decided is correct; a wrong value spends the whole budget and is returned as it is,
    /// to be judged by the guard that asked for it. Each attempt costs two ids, and the spent count
    /// is returned so the caller advances past them instead of reusing a later step's id.
    func observedTrackFlag(
        _ session: QualificationSubprocessSession,
        id: Int,
        trackIndex: Int,
        field: String,
        phase: String,
        awaiting: Bool? = nil
    ) throws -> (value: Bool, raw: String, spent: Int) {
        // REFRESH FIRST. `logic://tracks` is served from a poller-backed cache, and without this
        // the read after the write returns the pre-write value — measured 2026-09-14: mute moved
        // `true -> false` in Logic and three consecutive reads still answered `true`, while the
        // same sequence with a refresh between them reported `true -> false -> true`. A cycle built
        // on the unrefreshed read would have compared a write against its own stale precondition
        // and called it a failure; the guard below caught exactly that and refused, which is how
        // this was found.
        var spent = 0
        var last: (Bool, String)?
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
                  let rows = object["data"] as? [[String: Any]],
                  trackIndex < rows.count,
                  let value = rows[trackIndex][field] as? Bool else {
                throw QualificationTransportError.protocolViolation(
                    "\(phase): logic://tracks did not report \(field) for track \(trackIndex)"
                )
            }
            last = (value, raw)
            if awaiting == nil || value == awaiting { break }
        }
        guard let last else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks was never read for \(field)")
        }
        return (last.0, last.1, spent)
    }

    /// The index of the single selected track, or nil when none or more than one is selected.
    ///
    /// nil is the honest answer for "more than one", because a caller staging an EXCLUSIVE
    /// selection cannot restore a multi-selection it never captured.
    func observedSelectedTrackIndex(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (index: Int?, spent: Int) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(session, id: id + 1, uri: "logic://tracks", phase: phase)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks did not report any rows")
        }
        let selected = rows.enumerated().filter { ($0.element["isSelected"] as? Bool) == true }
        return (selected.count == 1 ? selected[0].offset : nil, 2)
    }

    /// #373 Phase B: the mutating operations whose recipe restores a VALUE rather than flipping a
    /// flag, and the `logic://tracks` field that independently reports each one.
    static let valueRestoreReadbackField: [OperationID: String] = [
        .mixerSetVolume: "volume",
        .mixerSetPan: "pan",
    ]

    /// The row's `track_ref` comes back with its value, and its absence is a refusal rather than a
    /// fallback. The cycle addresses the track by that reference; an index is a position, and the
    /// position of a row is not a property of the track sitting in it.
    private func observedTrackValue(
        _ session: QualificationSubprocessSession,
        id: Int,
        trackIndex: Int,
        field: String,
        phase: String
    ) throws -> (value: Double, raw: String, trackRef: String) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(session, id: id + 1, uri: "logic://tracks", phase: phase)
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]],
              trackIndex < rows.count,
              let value = rows[trackIndex][field] as? Double else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks did not report \(field) for track \(trackIndex)"
            )
        }
        guard let trackRef = rows[trackIndex]["track_ref"] as? String, !trackRef.isEmpty else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks row \(trackIndex) carries no track_ref, so this cycle has "
                    + "no identity to address. It does NOT fall back to the bare index: the index is "
                    + "what the identity exists to replace."
            )
        }
        return (value, raw, trackRef)
    }

    /// Put the value back after the cycle has failed somewhere between the write and its restore.
    ///
    /// Returns a sentence describing what happened, which the caller folds into the error it throws.
    /// A compensating restore that fails silently is worse than none: the sweep continues, the
    /// refusal is recorded, and nothing says the operator's mixer was left moved.
    private func compensateValue(
        _ session: QualificationSubprocessSession,
        spec: OperationSpec,
        field: String,
        trackIndex: Int,
        targetRef: String,
        value: Double,
        nextID: inout Int
    ) -> String {
        let callID = nextID
        nextID += 1
        do {
            let answer = try invoke(
                session, id: callID,
                tool: spec.tool.rawValue, command: spec.command,
                params: ["target_ref": targetRef, field: value],
                phase: "phase_b.compensate", timeout: spec.deadline.seconds + 5)
            if Self.mutationSaysItFailed(answer.text) {
                return "REFUSED, \(field) may still be moved: " + answer.text.prefix(200)
            }
            // RE-READ. "sent" is not "landed": State B is accepted-but-unverified and is not State
            // C, so without this a compensating write the server took but that moved nothing read
            // identically to one that worked -- which is the exact condition this helper exists to
            // stop the sweep from walking past.
            let confirmID = nextID
            nextID += 2
            do {
                let seen = try observedTrackValue(
                    session, id: confirmID, trackIndex: trackIndex, field: field,
                    phase: "phase_b.compensate_readback")
                if seen.trackRef != targetRef {
                    return "sent and re-read, but row \(trackIndex) now holds \(seen.trackRef) "
                        + "rather than \(targetRef), so this reading does not describe the track "
                        + "that was moved"
                }
                return seen.value == value
                    ? "LANDED, \(field) re-read at \(value)"
                    : "SENT BUT NOT LANDED, \(field) re-read at \(seen.value), wanted \(value)"
            } catch {
                return "sent, but the confirming read failed, so whether \(field) came back is "
                    + "unknown: \(error)"
            }
        } catch {
            return "THREW, \(field) may still be moved: \(error)"
        }
    }

    /// #373 Phase B for a continuous control: pre-state → move → readback → restore → readback.
    ///
    /// WHAT THIS DOES NOT ASSERT, and why. The observed value is NOT required to equal the
    /// requested one. Measured 2026-09-14: asking for volume `0.8579` lands `0.8636`, and pan
    /// `0.1079` lands `0.1654` — Logic exposes these faders in detents, and the operation reports
    /// `verified: true` against its own observation. Demanding equality here would fail a control
    /// that behaved correctly, which is a grader asserting something the surface never promised.
    ///
    /// What IS asserted is the pair that actually carries the claim:
    ///
    ///   * the value MOVED — an operation that did nothing cannot pass by agreeing with a stale
    ///     reading, which is the failure mode the boolean cycle found in the poller cache;
    ///   * the restore returns the pre-state EXACTLY, read back rather than assumed. Both measured
    ///     operations restore to the original bit pattern, so exactness is a real bar here and not
    ///     a hopeful one.
    func valueRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        readbackField: String
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        let trackIndex = 0
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let pre = try observedTrackValue(
            session, id: readStep(), trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.pre_state")
        // Move toward the middle of the range, so a control already at an extreme still has
        // somewhere to go. 0.1 is far enough to clear any detent the measurements showed.
        let target = pre.value > 0.5 ? max(0.1, pre.value - 0.1) : min(0.9, pre.value + 0.1)

        // Everything from here can leave the operator's mixer moved, INCLUDING a call that throws:
        // a timeout is a statement about the answer, not about the effect. So every exit between
        // this point and a verified restore compensates, and says in the thrown error whether the
        // compensation landed. Without this the sweep recorded a refusal and walked on with the
        // fader still at `target`.
        // Only true once a request that could MOVE something has been issued. A refusal carrying
        // `write_attempted: false` is the contract saying nothing was written, and compensating
        // that path is not harmless: the compensating write drives the fader to `pre.value`, which
        // came from the poller-backed cache, so on a stale read it moves a fader the product left
        // alone to a value neither the product nor the operator chose.
        var writeMayHaveLanded = false
        func failing(_ message: String) -> QualificationTransportError {
            guard writeMayHaveLanded else { return .protocolViolation(message) }
            let note = compensateValue(
                session, spec: spec, field: readbackField, trackIndex: trackIndex,
                targetRef: pre.trackRef, value: pre.value, nextID: &nextID)
            return .protocolViolation(message + " | compensating restore: " + note)
        }
        func writeAttemptedIsExplicitlyFalse(_ text: String) -> Bool {
            guard let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return false }
            return object["write_attempted"] as? Bool == false
        }

        do {
            // Set BEFORE the call, not after: a timeout is a statement about the answer, not about
            // the effect, so a throw here can still have moved the fader.
            writeMayHaveLanded = true
            let mutation = try invoke(
                session, id: step(), tool: spec.tool.rawValue, command: spec.command,
                params: ["target_ref": pre.trackRef, readbackField: target],
                phase: "phase_b.mutation", timeout: mutationReplyTimeout(spec))
            guard !Self.mutationSaysItFailed(mutation.text) else {
                // The refusal's own word for it. `write_attempted: false` is the fail-closed shape
                // this repository refuses with everywhere, and it is the one case where the answer
                // is authoritative that nothing moved.
                if writeAttemptedIsExplicitlyFalse(mutation.text) { writeMayHaveLanded = false }
                throw failing("phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
            }
            let after = try observedTrackValue(
                session, id: readStep(), trackIndex: trackIndex, field: readbackField,
                phase: "phase_b.readback")
            // The row at this index must still be the SAME track. Logic reorders on selection, and
            // a cycle that read one track, wrote to another and "restored" the first one's value
            // onto it would satisfy every comparison below while corrupting a track it never named.
            guard after.trackRef == pre.trackRef else {
                throw failing("phase_b.readback: row \(trackIndex) changed identity mid-cycle — "
                    + "pre \(pre.trackRef), now \(after.trackRef)")
            }
            guard after.value != pre.value else {
                throw failing("phase_b.readback: \(readbackField) did not move from \(pre.value)")
            }
            let restore = try invoke(
                session, id: step(), tool: spec.tool.rawValue, command: spec.command,
                params: ["target_ref": pre.trackRef, readbackField: pre.value],
                phase: "phase_b.restore", timeout: spec.deadline.seconds + 5)
            guard !Self.mutationSaysItFailed(restore.text) else {
                throw failing("phase_b.restore: \(spec.id.rawValue) refused the restore: "
                    + restore.text.prefix(220))
            }
            let restored = try observedTrackValue(
                session, id: readStep(), trackIndex: trackIndex, field: readbackField,
                phase: "phase_b.restore_readback")
            guard restored.trackRef == pre.trackRef else {
                throw failing("phase_b.restore_readback: row \(trackIndex) changed identity — "
                    + "pre \(pre.trackRef), now \(restored.trackRef)")
            }
            guard restored.value == pre.value else {
                throw failing("phase_b.restore_readback: \(readbackField) not restored — observed "
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
        } catch {
            // NOT `catch let error as QualificationTransportError`. `observedTrackValue` calls
            // `try JSONSerialization.jsonObject(...)`, which raises an NSError on a malformed
            // `logic://tracks` body -- and that is reached from BOTH post-write readbacks. Narrowed
            // to the transport's own error type, such a body let a landed write exit this function
            // with no compensation at all, and the sweep's untyped catch recorded a refusal with no
            // note. The universal in the comment above has to be enforced by the catch, not
            // asserted next to one that is narrower than it.
            if let transportError = error as? QualificationTransportError,
               case .protocolViolation(let text) = transportError,
               text.contains("compensating restore:") {
                throw error          // `failing()` already compensated for this one
            }
            guard writeMayHaveLanded else { throw error }
            let note = compensateValue(
                session, spec: spec, field: readbackField, trackIndex: trackIndex,
                targetRef: pre.trackRef, value: pre.value, nextID: &nextID)
            throw QualificationTransportError.protocolViolation(
                "\(error) | compensating restore: " + note)
        }
    }
}
