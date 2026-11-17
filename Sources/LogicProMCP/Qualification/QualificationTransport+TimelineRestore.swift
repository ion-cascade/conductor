import Foundation

extension QualificationTransport {
    /// #373 Phase B: transport operations whose effect is a boolean the transport resource reports,
    /// mapped to the state each one is supposed to leave behind.
    static let transportExpectedPlaying: [OperationID: Bool] = [
        .transportPlay: true,
        .transportStop: false,
        // Pause leaves Play ON with the playhead stationary. The cycle below distinguishes
        // that mode with two independent, tempo-separated position reads, not this bit alone.
        // `record` is deliberately NOT
        // here: its readback would be the same flag, and running it would write audio into the
        // fixture, which belongs to Phase C-live with a disposable project.
        .transportPause: true,
    ]

    enum TransportMotion: Equatable {
        case stopped, paused, moving

        var policyValue: QualificationMutationRestorePolicy.Motion {
            switch self {
            case .stopped: .stopped
            case .paused: .paused
            case .moving: .moving
            }
        }

        var restoreCommand: String {
            switch self {
            case .stopped: "stop"
            case .paused: "pause"
            case .moving: "play"
            }
        }
    }

    /// Record-local evidence only; a single Play-on snapshot cannot answer the motion question.
    static func recordedTransportMotion(_ raw: String) -> TransportMotion? {
        guard let data = raw.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = envelope["data"] as? [String: Any],
              let state = payload["state"] as? [String: Any],
              let playing = state["isPlaying"] as? Bool else { return nil }
        if !playing { return .stopped }
        guard let samples = envelope["qualification_motion_samples"] as? [[String: Any]],
              samples.count == 2,
              let gap = envelope["qualification_motion_gap_ms"] as? Double else { return nil }
        var positions: [String] = []
        var tempos: [Double] = []
        var cycles: [Bool?] = []
        for sample in samples {
            guard sample["source"] as? String == "ax_live",
                  sample["unverified"] as? Bool != true,
                  sample["ax_occluded"] as? Bool != true,
                  let body = sample["data"] as? [String: Any],
                  let value = body["state"] as? [String: Any],
                  value["isPlaying"] as? Bool == true,
                  let tempo = sample["observed_tempo"] as? Double,
                  let position = value["position"] as? String, !position.isEmpty,
                  let witness = value["positionReadback"] as? [String: Any],
                  witness["value"] as? String == position,
                  let components = witness["observedComponents"] as? [String],
                  components.starts(with: ["bar", "beat"]) else { return nil }
            positions.append(position)
            tempos.append(tempo)
            cycles.append(value["observedCycleEnabled"] as? Bool)
        }
        guard tempos[0] == tempos[1], envelope["observed_tempo"] as? Double == tempos[1],
              state["position"] as? String == positions[1],
              let required = TransportDispatcher.pauseStillnessGapNanoseconds(tempo: tempos[0]),
              gap >= Double(required) / 1_000_000 else { return nil }
        if positions[0] == positions[1] {
            // A loop can alias two sampled positions. Missing/ON Cycle is not proof of pause.
            guard cycles.allSatisfy({ cycle in
                guard let cycle else { return false }
                return !cycle
            }) else { return nil }
            return .paused
        }
        return .moving
    }

    private func observedPlaying(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (playing: Bool, raw: String) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(
            session, id: id + 1, uri: "logic://transport/state", phase: phase)
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["source"] as? String == "ax_live",
              object["unverified"] as? Bool != true,
              object["ax_occluded"] as? Bool != true,
              let payload = object["data"] as? [String: Any],
              let state = payload["state"] as? [String: Any],
              let playing = state["isPlaying"] as? Bool else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://transport/state did not report observed isPlaying")
        }
        return (playing, raw)
    }

    private func observedTransportMotion(
        _ session: QualificationSubprocessSession,
        nextID: inout Int,
        phase: String
    ) throws -> (motion: TransportMotion, raw: String) {
        let first = try observedPlaying(session, id: nextID, phase: phase)
        nextID += 2
        if !first.playing { return (.stopped, first.raw) }
        guard let data = first.raw.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tempo = envelope["observed_tempo"] as? Double,
              let gap = TransportDispatcher.pauseStillnessGapNanoseconds(tempo: tempo) else {
            throw QualificationTransportError.protocolViolation("\(phase): transport motion tempo unavailable")
        }
        Thread.sleep(forTimeInterval: Double(gap) / 1_000_000_000)
        let second = try observedPlaying(session, id: nextID, phase: "\(phase).motion_confirming")
        nextID += 2
        guard second.playing,
              let secondData = second.raw.data(using: .utf8),
              var secondEnvelope = try JSONSerialization.jsonObject(with: secondData) as? [String: Any] else {
            throw QualificationTransportError.protocolViolation("\(phase): Play changed while observing motion")
        }
        secondEnvelope["qualification_motion_samples"] = [envelope, secondEnvelope]
        secondEnvelope["qualification_motion_gap_ms"] = Double(gap) / 1_000_000
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: secondEnvelope,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        guard let motion = Self.recordedTransportMotion(raw) else {
            throw QualificationTransportError.protocolViolation("\(phase): transport position motion unavailable")
        }
        return (motion, raw)
    }

    /// #373 Phase B for transport. Same five steps, with one extra obligation the others do not
    /// have: the operation must have somewhere to GO.
    ///
    /// `transport.play` proves nothing if the transport is already playing, and `stop` proves
    /// nothing if it is already stopped — the readback would agree without the operation doing
    /// anything, which is the exact shape the poller cache produced for mute. So the precondition
    /// is forced with the INVERSE operation first, and the session's real pre-state is recorded
    /// before any of that so the restore returns to where the operator actually was, not to the
    /// state this recipe manufactured.
    func transportRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        expectedPlaying: Bool
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func step() -> Int { defer { nextID += 1 }; return nextID }
        let expected: TransportMotion = spec.id == .transportPause ? .paused : (expectedPlaying ? .moving : .stopped)
        let inverse = expected == .moving ? "stop" : "play"

        let pre = try observedTransportMotion(session, nextID: &nextID, phase: "phase_b.pre_state")
        var needsRestore = false
        defer {
            if needsRestore {
                // A staged precondition is acquired work too. A later refused mutation/readback
                // must not leave it behind; failure still carries no verified cycle record.
                _ = try? invoke(session, id: nextID + 900, tool: spec.tool.rawValue,
                    command: pre.motion.restoreCommand, params: [:],
                    phase: "phase_b.cleanup", timeout: spec.deadline.seconds + 5)
            }
        }
        if pre.motion == expected || (expected == .paused && pre.motion != .moving) {
            needsRestore = true
            _ = try invoke(
                session, id: step(), tool: spec.tool.rawValue, command: inverse,
                params: [:], phase: "phase_b.precondition")
            let staged = try observedTransportMotion(
                session, nextID: &nextID, phase: "phase_b.precondition_readback")
            guard staged.motion == (expected == .moving ? .stopped : .moving) else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.precondition: could not stage independent transport motion")
            }
        }
        needsRestore = true
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: [:], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTransportMotion(session, nextID: &nextID, phase: "phase_b.readback")
        guard after.motion == expected else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: independent transport motion differs from requested mode")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue,
            command: pre.motion.restoreCommand, params: [:], phase: "phase_b.restore")
        let restored = try observedTransportMotion(
            session, nextID: &nextID, phase: "phase_b.restore_readback")
        guard restored.motion == pre.motion else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: independent transport motion was not restored")
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

    /// #373 Phase B for `tracks.select`. The moved thing is WHICH row carries `isSelected`, so the
    /// cycle checks both ends: the new row gained it and the old row lost it. Checking only the new
    /// row would pass a selection that added rather than moved.
    func selectionRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        // Each read advances `nextID` by what it SPENT — a polled read costs more than two ids.
        let pre = try observedTrackFlag(
            session, id: nextID, trackIndex: 0, field: "isSelected",
            phase: "phase_b.pre_state")
        nextID += pre.spent
        // Select row 1 when row 0 holds the selection, and row 0 otherwise — always a real move.
        let target = pre.value ? 1 : 0
        let original = pre.value ? 0 : 1
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": target], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let gained = try observedTrackFlag(
            session, id: nextID, trackIndex: target, field: "isSelected",
            phase: "phase_b.readback", awaiting: true)
        nextID += gained.spent
        let lost = try observedTrackFlag(
            session, id: nextID, trackIndex: original, field: "isSelected",
            phase: "phase_b.readback_other", awaiting: false)
        nextID += lost.spent
        guard gained.value, !lost.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: selection did not MOVE — target \(gained.value), "
                    + "original \(lost.value)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": original], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
        let restored = try observedTrackFlag(
            session, id: nextID, trackIndex: original, field: "isSelected",
            phase: "phase_b.restore_readback", awaiting: true)
        nextID += restored.spent
        guard restored.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: original row did not regain the selection")
        }
        return (
            QualificationMutationRestoreRecord(
                operationID: spec.id.rawValue,
                preState: pre.raw,
                mutation: mutation.text,
                readback: gained.raw,
                restore: restore.text,
                restoreReadback: restored.raw
            ),
            nextID
        )
    }

    /// The index of the marker carrying `name`, or nil. Marker indices are NOT append order: the
    /// list is sorted by POSITION and `create_marker` places its marker at the playhead, so a new
    /// marker lands wherever its bar sorts to. Assuming it arrives last is what made an earlier
    /// version of this recipe delete SOMEBODY ELSE'S marker while its count check still balanced —
    /// the cycle passed and the project lost a marker it was supposed to leave alone.
    func markerIndex(named name: String, in raw: String) -> Int? {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { return nil }
        return rows.firstIndex { ($0["name"] as? String) == name }
    }

    /// What a marker-list read is waiting FOR, and therefore when it may stop polling early.
    ///
    /// A count was the only condition this poll knew, and that is wrong for a rename: the list
    /// length does not move, so the first — stale — read satisfies it and the recipe judges the
    /// operation against a list taken before the write settled. Measured 2026-09-14:
    /// `rename_marker` was refused by its own cycle for a name change that Logic had in fact made.
    /// The settle condition has to name the thing the mutation actually changed.
    enum MarkerSettle: Sendable {
        /// Read once; the caller is not waiting for anything.
        case read
        /// Wait until the list holds exactly this many rows.
        case count(Int)
        /// Wait until every `present` name is in the list and no `absent` name is.
        case names(present: [String], absent: [String])
    }

    func observedMarkerCount(
        _ session: QualificationSubprocessSession,
        id: Int,
        settling: MarkerSettle,
        phase: String
    ) throws -> (count: Int, raw: String, spent: Int) {
        // POLLS rather than reads once. The marker list settles more slowly than the other
        // resources this file reads: measured 2026-09-14, a delete that had actually taken effect
        // still read as present immediately after `refresh_cache`, and answered correctly a couple
        // of seconds later. Reading once would make this recipe flaky and — worse — would report a
        // working operation as one that did nothing.
        //
        // `settling` is what the caller is waiting FOR, and `.read` means "just read". Waiting is
        // not relaxing the assertion: the loop exits early only on the state the caller already
        // decided is correct, and a wrong state simply runs out the budget and is returned as it
        // is, to be judged by the guard that asked.
        var spent = 0
        var last: (Int, String) = (-1, "")
        for attempt in 0..<6 {
            // WAIT between attempts. The first version polled with no delay, so six attempts
            // finished in well under a second — far too fast for this list. Measured 2026-09-14: a
            // `delete_marker` at the correct index still showed the marker 1.8 s later and was gone
            // by 3 s. A poll that spins is not waiting; it is reading the same stale answer six
            // times and then reporting it as the truth.
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.8) }
            _ = try? invoke(
                session, id: id + spent, tool: "logic_system", command: "refresh_cache",
                params: [:], phase: "\(phase).refresh")
            spent += 1
            let data = try resourceReadback(
                session, id: id + spent, uri: "logic://markers", phase: phase)
            spent += 1
            let raw = String(decoding: data, as: UTF8.self)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let rows = (object?["data"] as? [[String: Any]]) ?? []
            last = (rows.count, raw)
            let names = Set(rows.compactMap { $0["name"] as? String })
            let settled: Bool = switch settling {
            case .read: true
            case .count(let expected): rows.count == expected
            case .names(let present, let absent):
                present.allSatisfy(names.contains) && !absent.contains(where: names.contains)
            }
            if settled { break }
        }
        return (last.0, last.1, spent)
    }

    /// #373 Phase B for the project tempo.
    ///
    /// `transport.set_tempo` refuses when the project holds more than one tempo event — Logic
    /// answers that edit with a modal alert and the operation reports
    /// `readback_lost_after_write` (#304). That refusal arrives here as a State C mutation and the
    /// cycle declines, which is the right outcome: a fixture with a tempo map cannot qualify this
    /// operation through the control bar, and pretending otherwise would be the grader looking
    /// away.
    func tempoRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        func tempo(of raw: String, phase: String) throws -> Double {
            guard let data = raw.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let payload = object["data"] as? [String: Any],
                  let state = payload["state"] as? [String: Any],
                  let value = state["tempo"] as? Double else {
                throw QualificationTransportError.protocolViolation(
                    "\(phase): logic://transport/state did not report tempo")
            }
            return value
        }

        let pre = try observedTransportPosition(session, id: readStep(), phase: "phase_b.pre_state")
        let preTempo = try tempo(of: pre.raw, phase: "phase_b.pre_state")
        // A few BPM away, inside the operation's own 5...990 range and far enough that the
        // readback cannot agree by rounding.
        let target = preTempo > 100 ? preTempo - 6 : preTempo + 6
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["bpm": target], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        var needsRestore = true
        defer {
            if needsRestore {
                _ = try? invoke(
                    session, id: nextID + 900, tool: spec.tool.rawValue, command: spec.command,
                    params: ["bpm": preTempo], phase: "phase_b.cleanup",
            timeout: spec.deadline.seconds + 5)
            }
        }
        let after = try observedTransportPosition(session, id: readStep(), phase: "phase_b.readback")
        let afterTempo = try tempo(of: after.raw, phase: "phase_b.readback")
        guard afterTempo != preTempo else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: tempo did not move from \(preTempo)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["bpm": preTempo], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the restore: "
                    + restore.text.prefix(220))
        }
        let restored = try observedTransportPosition(
            session, id: readStep(), phase: "phase_b.restore_readback")
        let restoredTempo = try tempo(of: restored.raw, phase: "phase_b.restore_readback")
        guard restoredTempo == preTempo else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: tempo is \(restoredTempo), expected \(preTempo)")
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

    /// #373 Phase B for the playhead — `navigate.goto_bar` today.
    ///
    /// The restore target is read out of the pre-state's own position string rather than assumed,
    /// so the playhead goes back to the bar the operator was actually on. How many components that
    /// string carries depends on the control bar's display mode (#304), so only the leading BAR is
    /// parsed and compared — the finer components are whatever the mode happens to expose and
    /// comparing them would make this recipe fail on a display setting rather than on the operation.
    /// The bar number the transport reports, out of a `logic://transport/state` body.
    private func observedBar(of raw: String, phase: String) throws -> Int {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let state = payload["state"] as? [String: Any],
              let position = state["position"] as? String,
              let leading = position.split(separator: ".").first,
              let value = Int(leading) else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): could not read a bar out of the transport position")
        }
        return value
    }

    /// #373 Phase B for `navigate.goto_marker`.
    ///
    /// The operation needs a marker to go TO, and it must be somewhere the playhead is not, or the
    /// readback would agree without the operation having moved anything. So the cycle stages both:
    /// it parks the playhead at a bar of its own choosing, drops a marker there, brings the
    /// playhead back, and only then asks `goto_marker` to find it.
    ///
    /// The marker is identified BY NAME in the request as well as in the cleanup — `goto_marker`
    /// accepts an index, and using one would make the cycle depend on the position-sorted order
    /// that has already caused one destructive defect in this file.
    func markerNavigationRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        let probeName = "qualification_phase_b_probe"
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let origin = try observedTransportPosition(
            session, id: readStep(), phase: "phase_b.stage_precondition")
        let originBar = try observedBar(of: origin.raw, phase: "phase_b.stage_precondition")
        let markerBar = originBar > 4 ? originBar - 3 : originBar + 3

        let existing = try observedMarkerCount(
            session, id: nextID, settling: .read, phase: "phase_b.stage_precondition")
        nextID += existing.spent
        guard markerIndex(named: probeName, in: existing.raw) == nil else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage_precondition: a marker named \(probeName) is already in the "
                    + "project — an earlier run left it, and this cycle cannot tell its own marker "
                    + "from that one")
        }
        _ = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: "goto_bar",
            params: ["bar": markerBar], phase: "phase_b.stage")
        let parked = try observedTransportPosition(session, id: readStep(), phase: "phase_b.stage")
        guard try observedBar(of: parked.raw, phase: "phase_b.stage") == markerBar else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage: could not park the playhead at bar \(markerBar), so a marker "
                    + "dropped here would not be where this cycle thinks it is")
        }
        let staged = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: "create_marker",
            params: ["name": probeName], phase: "phase_b.stage")
        guard !Self.mutationSaysItFailed(staged.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage: create_marker refused, so there is nothing for "
                    + "\(spec.id.rawValue) to navigate to: " + staged.text.prefix(220))
        }
        // A MARKER NOW EXISTS. Every exit removes it, and the removal is verified — see
        // `markerCreateRestoreCycle` for why an unchecked delete is not a removal.
        defer {
            var cleanupID = nextID + 900
            for _ in 0..<6 {
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
        let listed = try observedMarkerCount(
            session, id: nextID, settling: .names(present: [probeName], absent: []),
            phase: "phase_b.stage_readback")
        nextID += listed.spent
        guard markerIndex(named: probeName, in: listed.raw) != nil else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage_readback: \(probeName) never appeared in the marker list")
        }
        _ = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: "goto_bar",
            params: ["bar": originBar], phase: "phase_b.stage_return")
        let pre = try observedTransportPosition(session, id: readStep(), phase: "phase_b.pre_state")
        let preBar = try observedBar(of: pre.raw, phase: "phase_b.pre_state")
        guard preBar != markerBar else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.pre_state: the playhead is already at the marker's bar \(markerBar), so "
                    + "arriving there would prove nothing")
        }

        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["name": probeName], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTransportPosition(session, id: readStep(), phase: "phase_b.readback")
        let afterBar = try observedBar(of: after.raw, phase: "phase_b.readback")
        guard afterBar == markerBar else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: playhead is at bar \(afterBar), expected the marker's bar "
                    + "\(markerBar)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: "goto_bar",
            params: ["bar": preBar], phase: "phase_b.restore")
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: goto_bar refused the restore: " + restore.text.prefix(220))
        }
        let restored = try observedTransportPosition(
            session, id: readStep(), phase: "phase_b.restore_readback")
        let restoredBar = try observedBar(of: restored.raw, phase: "phase_b.restore_readback")
        guard restoredBar == preBar else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: playhead is at bar \(restoredBar), expected \(preBar)")
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

    func playheadRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let pre = try observedTransportPosition(session, id: readStep(), phase: "phase_b.pre_state")
        let preBar = try observedBar(of: pre.raw, phase: "phase_b.pre_state")
        // Somewhere else in the arrangement, and never bar 0 — `goto_bar` counts from 1.
        let target = preBar > 4 ? preBar - 3 : preBar + 3
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["bar": target], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTransportPosition(session, id: readStep(), phase: "phase_b.readback")
        let afterBar = try observedBar(of: after.raw, phase: "phase_b.readback")
        guard afterBar == target else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: playhead is at bar \(afterBar), expected \(target)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["bar": preBar], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the restore: "
                    + restore.text.prefix(220))
        }
        let restored = try observedTransportPosition(
            session, id: readStep(), phase: "phase_b.restore_readback")
        let restoredBar = try observedBar(of: restored.raw, phase: "phase_b.restore_readback")
        guard restoredBar == preBar else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: playhead is at bar \(restoredBar), expected \(preBar)")
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

    /// Complete observed musical position only: never append unobserved subdivision or ticks.
    static func recordedExactStepPosition(_ envelope: [String: Any]) -> String? {
        guard let data = envelope["data"] as? [String: Any],
              let fields = data["state"] as? [String: Any],
              fields["isPlaying"] as? Bool == false, fields["isRecording"] as? Bool == false,
              fields["observedCycleEnabled"] as? Bool == false,
              let raw = fields["positionReadback"] as? [String: Any],
              let bytes = try? JSONSerialization.data(withJSONObject: raw),
              let readback = try? JSONDecoder().decode(TransportPositionReadback.self, from: bytes)
        else { return nil }
        var state = TransportState()
        state.positionReadback = readback
        guard let complete = TransportDispatcher.completeObservedMusicalPosition(state),
              !complete.value.contains(":"), TransportDispatcher.isValidPositionString(complete.value)
        else { return nil }
        return complete.value
    }

    static func freshRecordedExactStepPosition(_ raw: String) -> String? {
        guard let bytes = raw.data(using: .utf8),
              QualificationReadbackFreshness.verdict(
                for: bytes, uri: "logic://transport/state",
                verification: .readbackRequired, deadline: .short
              ).isAdmissible,
              let envelope = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return nil }
        return recordedExactStepPosition(envelope)
    }

    static func stepPosition(from position: String, direction: Int) -> String? {
        var components = position.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // Off-boundary keyboard stepping snaps differently; its exact formula is not qualified.
        guard components.count == 4, components.dropFirst().allSatisfy({ $0 == "1" }),
              let bar = Int(components[0]) else { return nil }
        components[0] = String(bar + direction)
        let target = components.joined(separator: ".")
        return TransportDispatcher.isValidPositionString(target) ? target : nil
    }

    static func barBoundary(from position: String) -> String {
        String(position.split(separator: ".")[0]) + ".1.1.1"
    }

    static func verifiedPlayheadGotoReply(_ raw: String, expectedPosition: String) -> Bool {
        guard let bytes = raw.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
        guard fields["state"] as? String == "A", fields["verified"] as? Bool == true,
              fields["write_attempted"] as? Bool != false,
              fields["unchanged"] as? Bool != true,
              !playheadStepWriteWasIndeterminate(raw)
        else { return false }
        if fields["write_attempted"] as? Bool == true { return true }

        let complete = Set(["bar", "beat", "subdivision", "tick"])
        guard fields["verification_source"] as? String == "transport_state",
              fields["requested"] as? String == expectedPosition,
              fields["observed"] as? String == expectedPosition,
              let observedBefore = fields["observed_before"] as? String,
              observedBefore != expectedPosition,
              TransportDispatcher.isValidPositionString(observedBefore),
              Set(fields["observed_before_position_components"] as? [String] ?? []) == complete,
              Set(fields["observed_position_components"] as? [String] ?? []) == complete,
              (fields["unobserved_position_components"] as? [String])?.isEmpty == true
        else { return false }
        return true
    }

    /// A matching post-read may be another actor's movement. Only a receipt that says this call
    /// attempted/delivered the step can acquire cleanup custody or persisted qualification credit.
    static func playheadStepMutationWasAttempted(_ raw: String) -> Bool {
        guard let bytes = raw.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              fields["state"] as? String != "C",
              fields["success"] as? Bool != false,
              fields["write_attempted"] as? Bool != false,
              fields["unchanged"] as? Bool != true,
              !playheadStepWriteWasIndeterminate(raw)
        else { return false }
        return fields["write_attempted"] as? Bool == true || fields["sent"] as? Bool == true
    }

    /// A coincident landing cannot qualify input whose own target was explicitly unknown.
    static func playheadStepWriteWasIndeterminate(_ raw: String) -> Bool {
        guard let bytes = raw.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return true }
        return fields["fallback_unsafe"] as? Bool == true
            || fields["write_attempted_indeterminate"] as? Bool == true
            || fields["dialog_input_target"] as? String == "unknown"
            || ["fallback_unsafe", "write_attempted_indeterminate", "dialog_input_target"]
                .contains(fields["verification_withheld"] as? String ?? "")
    }

    /// Independent project-reference bookends and a fresh full position precede each dependent write.
    func playheadStepRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        direction: Int
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        var ownedStagedPosition: String?
        func step() -> Int { defer { nextID += 1 }; return nextID }
        func project(_ phase: String) throws -> (ref: String, path: String) {
            let bytes = try resourceReadback(session, id: step(), uri: "logic://project/info", phase: phase)
            guard let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let data = envelope["data"] as? [String: Any],
                  let ref = data["project_ref"] as? String, ref.hasPrefix("prj_"),
                  let path = data["filePath"] as? String, !path.isEmpty,
                  envelope["identity_source"] as? String == "current_document_project_file",
                  let fetched = envelope["identity_fetched_at"] as? String,
                  let date = ISO8601DateFormatter.cacheFormatter.date(from: fetched),
                  Date().timeIntervalSince(date) >= 0, Date().timeIntervalSince(date) <= spec.deadline.seconds,
                  QualificationReadbackFreshness.verdict(for: bytes, uri: "logic://project/info",
                    verification: .readbackRequired, deadline: spec.deadline).isAdmissible
            else { throw QualificationTransportError.protocolViolation("\(phase): current project identity unavailable") }
            return (ref, path)
        }
        func read(_ phase: String, expectedProject: (ref: String, path: String)? = nil) throws
            -> (raw: String, position: String, project: (ref: String, path: String)) {
            // A failed deciding read cannot renew an earlier precondition's inverse authority.
            ownedStagedPosition = nil
            _ = try? invoke(session, id: step(), tool: "logic_system", command: "refresh_cache",
                params: [:], phase: "\(phase).refresh")
            let before = try project("\(phase).project_before")
            if let expectedProject, before != expectedProject {
                throw QualificationTransportError.protocolViolation("\(phase): project changed; dependent write withheld")
            }
            let bytes = try resourceReadback(session, id: step(), uri: "logic://transport/state", phase: phase)
            guard let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  envelope["unverified"] as? Bool != true,
                  QualificationReadbackFreshness.verdict(for: bytes, uri: "logic://transport/state",
                    verification: .readbackRequired, deadline: spec.deadline).isAdmissible,
                  let position = Self.recordedExactStepPosition(envelope)
            else { throw QualificationTransportError.protocolViolation("\(phase): fresh stopped full position unavailable") }
            let after = try project("\(phase).project_after")
            guard before == after else {
                throw QualificationTransportError.protocolViolation("\(phase): project changed during read; dependent write withheld")
            }
            return (String(decoding: bytes, as: UTF8.self), position, after)
        }
        let pre = try read("phase_b.pre_state")
        let boundary = Self.barBoundary(from: pre.position)
        guard let target = Self.stepPosition(from: boundary, direction: direction) else {
            throw QualificationTransportError.protocolViolation("phase_b.pre_state: current bar's step leaves the supported range; staging withheld")
        }
        var stageWrite: String?
        var stageReading: String?
        do {
            if pre.position != boundary {
                let stage = try invoke(session, id: step(), tool: "logic_transport", command: "goto_position",
                    params: ["position": boundary], phase: "phase_b.stage", timeout: spec.deadline.seconds + 5)
                guard !stage.isError, Self.verifiedPlayheadGotoReply(stage.text, expectedPosition: boundary) else {
                    throw QualificationTransportError.protocolViolation("phase_b.stage: exact boundary staging was not verified A")
                }
                let staged = try read("phase_b.stage_readback", expectedProject: pre.project)
                guard staged.position == boundary else {
                    throw QualificationTransportError.protocolViolation("phase_b.stage_readback: boundary was not observed")
                }
                stageWrite = stage.text; stageReading = staged.raw
                ownedStagedPosition = boundary
            }
            // Dispatch can throw without telling us whether the step was issued. Retire the
            // staged inverse before crossing that boundary, not only after parsing a reply.
            ownedStagedPosition = nil
            let mutation = try invoke(session, id: step(), tool: spec.tool.rawValue, command: spec.command,
                params: [:], phase: "phase_b.mutation", timeout: mutationReplyTimeout(spec))
            if stageWrite != nil,
               !Self.playheadStepWriteWasIndeterminate(mutation.text),
               let bytes = mutation.text.data(using: .utf8),
               let reply = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               (reply["write_attempted"] as? Bool == false
                    || reply["unchanged"] as? Bool == true) {
                let current = try read("phase_b.refused_step_readback", expectedProject: pre.project)
                if current.position == boundary { ownedStagedPosition = boundary }
            }
            guard !Self.mutationSaysItFailed(mutation.text),
                  Self.playheadStepMutationWasAttempted(mutation.text) else {
                throw QualificationTransportError.protocolViolation("phase_b.mutation: step refused")
            }
            let after = try read("phase_b.readback", expectedProject: pre.project)
            if after.position == target {
                ownedStagedPosition = target
            } else if stageWrite != nil, after.position == boundary {
                ownedStagedPosition = after.position
            }
            guard after.position == target else {
                throw QualificationTransportError.protocolViolation("phase_b.readback: exact directional step mismatch")
            }
            let lastOwned = ownedStagedPosition
            ownedStagedPosition = nil
            let restore = try invoke(session, id: step(), tool: "logic_transport", command: "goto_position",
                params: ["position": pre.position], phase: "phase_b.restore", timeout: spec.deadline.seconds + 5)
            if Self.mutationSaysItFailed(restore.text),
               !Self.playheadStepWriteWasIndeterminate(restore.text),
               let bytes = restore.text.data(using: .utf8),
               let reply = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               reply["write_attempted"] as? Bool == false {
                ownedStagedPosition = lastOwned
            }
            guard !restore.isError, !Self.mutationSaysItFailed(restore.text),
                  Self.verifiedPlayheadGotoReply(restore.text, expectedPosition: pre.position) else {
                throw QualificationTransportError.protocolViolation("phase_b.restore: exact position restore refused or unverified")
            }
            let restored = try read("phase_b.restore_readback", expectedProject: pre.project)
            guard restored.position == pre.position else {
                throw QualificationTransportError.protocolViolation("phase_b.restore_readback: exact position was not restored")
            }
            return (.init(operationID: spec.id.rawValue, preState: pre.raw, mutation: mutation.text,
                readback: after.raw, restore: restore.text, restoreReadback: restored.raw,
                stagingMutation: stageWrite, stagingReadback: stageReading), nextID)
        } catch {
            guard let owned = ownedStagedPosition else { throw error }
            let cause = String(describing: error)
            do {
                let current = try read("phase_b.cleanup_pre_state", expectedProject: pre.project)
                guard current.position == owned else {
                    throw QualificationTransportError.protocolViolation("staged cleanup withheld: position no longer owned")
                }
                let cleanup = try invoke(session, id: step(), tool: "logic_transport", command: "goto_position",
                    params: ["position": pre.position], phase: "phase_b.cleanup", timeout: spec.deadline.seconds + 5)
                guard !cleanup.isError,
                      Self.verifiedPlayheadGotoReply(cleanup.text, expectedPosition: pre.position) else {
                    throw QualificationTransportError.protocolViolation("staged cleanup was not verified A")
                }
                let restored = try read("phase_b.cleanup_readback", expectedProject: pre.project)
                guard restored.position == pre.position else {
                    throw QualificationTransportError.protocolViolation("staged cleanup did not restore original position")
                }
            } catch {
                throw QualificationTransportError.protocolViolation(cause + " | " + String(describing: error))
            }
            throw QualificationTransportError.protocolViolation(cause + " | staged cleanup independently restored original position")
        }
    }

    private func observedTransportPosition(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (raw: String, spent: Int) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(
            session, id: id + 1, uri: "logic://transport/state", phase: phase)
        return (String(decoding: data, as: UTF8.self), 2)
    }
}
