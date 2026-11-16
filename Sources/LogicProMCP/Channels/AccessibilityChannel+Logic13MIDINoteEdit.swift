@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    func logic13MIDINoteOperation(
        parameters: [String: String], writing: Bool, runtime: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let operation = writing ? "midi.edit_region_note" : "midi.get_region_notes"
        let reference = parameters["target_ref"] ?? ""
        let ax = runtime.ax

        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: error, hint: hint, extras: [
                "operation": operation, "target_ref": reference, "write_attempted": false,
            ]))
        }

        guard let snapshot = regionScan, ContinuousClock.now < snapshot.expires,
              let held = snapshot.targets[reference] else {
            return refuse(.staleTargetReference, "Scan and use a current ordinary MIDI region reference.")
        }
        guard held.info.kind == "midi", Self.isOrdinaryRegion(held.info),
              let scope = ArrangeRegionScope(runtime: runtime),
              scope.document == snapshot.document, CFEqual(scope.window, snapshot.window),
              scope.headers.indices.contains(held.info.trackIndex),
              CFEqual(scope.headers[held.info.trackIndex], held.header),
              AXTrackBinding.presentation(of: held.header, runtime: ax) == held.headerPresentation,
              let initialRegions = Self.regionEditCensus(scope: scope) else {
            return refuse(.staleTargetReference, "Use the visible referenced MIDI region in the stopped project.")
        }
        func ownsRegion(_ regions: [EditRegionRow]) -> Bool {
            let selected = regions.filter { $0.info.isSelected == true }
            return scope.holdsArrange() && scope.holdsHeaders() && scope.selectionIsOriginal()
                && regions.allSatisfy { $0.info.isSelected != nil }
                && regions.filter { $0.info.name == held.info.name }.count == 1
                && selected.count == 1 && selected.allSatisfy {
                    Self.sameRegionObservation(held, item: $0.item, info: $0.info)
                }
        }
        guard ownsRegion(initialRegions) else {
            return refuse(.unsupportedState, "Select only the visible MIDI region and give it a unique name.")
        }
        guard let eventList = Logic13MIDINoteEventList.find(in: scope.window, regionName: held.info.name, ax: ax),
              EventListReadbackCollector.requireLogic13NoteDisplay(in: eventList.pane, runtime: ax),
              let checkedRegions = Self.regionEditCensus(scope: scope), ownsRegion(checkedRegions),
              let before = eventList.rows(), let stable = eventList.rows(),
              before.map(.signature) == stable.map(.signature) else {
            return refuse(.readbackUnavailable, "Show the unfiltered Event List for the selected region with absolute musical positions and elapsed lengths.")
        }

        let notes = stable.compactMap(.note)
        var evidence: [String: Any] = [
            "operation": operation, "target_ref": reference, "write_attempted": false,
            "region": held.info.name, "verify_source": "logic13_ax_event_list",
            "event_count": stable.count,
        ]
        guard writing else {
            evidence["notes"] = notes.map(.evidence)
            return .success(HonestContract.encodeStateA(extras: evidence))
        }
        guard let expected = Self.midiEditValue(parameters, prefix: "expected_"),
              let desired = Self.midiEditValue(parameters, prefix: "", defaultValue: expected) else {
            return refuse(.invalidParams, "Supply the exact previous note values and the requested new values.")
        }
        let targetedRows = stable.filter { $0.note?.hasSameIdentity(as: expected) == true }
        guard targetedRows.count == 1, let target = targetedRows.first, target.note == expected else {
            return refuse(.staleSnapshot, "Re-read the region. The expected note must match exactly one row.")
        }
        let peers = stable.filter { !CFEqual($0.element, target.element) }
        guard !target.locked, eventList.selectionPermits(target.element),
              let plan = Logic13MIDINoteEditPlan(before: expected, after: desired, peers: peers.compactMap(.note)),
              Self.midiEditFitsRegion(plan: plan, held: held) else {
            return refuse(.unsupportedState, "The unlocked note must be uniquely addressable, inside its region and within the write step limit.")
        }

        func verifiedTarget(_ rows: [Logic13MIDINoteEventList.Row], note: Logic13MIDINoteValue) -> Logic13MIDINoteEventList.Row? {
            let candidates = rows.filter { $0.note?.hasSameIdentity(as: note) == true }
            guard candidates.count == 1, let candidate = candidates.first, candidate.note == note,
                  !candidate.locked else { return nil }
            var remaining = rows.filter { !CFEqual($0.element, candidate.element) }.map(.signature)
            for peer in peers {
                guard let match = remaining.firstIndex(of: peer.signature) else { return nil }
                remaining.remove(at: match)
            }
            return remaining.isEmpty ? candidate : nil
        }

        var latest = target
        var emitted = 0
        var verifiedSteps = 0
        func unresolved(_ stage: String) -> ChannelResult {
            if emitted == 0 { return refuse(.readbackUnavailable, "The bound MIDI note is no longer ready for the edit.") }
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: [
                "operation": operation, "target_ref": reference, "stage": stage, "write_attempted": true,
                "safe_to_retry": false, "effect_unknown": true, "verified_steps": verifiedSteps,
            ]))
        }
        for step in plan.steps {
            guard !Task.isCancelled,
                  let currentRegions = Self.regionEditCensus(scope: scope), ownsRegion(currentRegions),
                  Self.sameRegionPeers(initialRegions, currentRegions, ignoring: held.item),
                  let rows = eventList.rows(), let current = verifiedTarget(rows, note: step.current),
                  current.signature == latest.signature, eventList.selectionPermits(current.element) else {
                return unresolved("event_list_before_action")
            }
            let action = eventList.write(step, row: current) {
                guard scope.holdsArrange(), OperationTraceContext.claimDeadlineEffect("midi_note_event_action") else {
                    return false
                }
                regionScan = nil
                emitted += 1
                return true
            }
            guard action else { return unresolved("event_list_action") }
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return unresolved("event_list_cancelled") }

            guard let observed = eventList.rows(), let changed = verifiedTarget(observed, note: step.expected),
                  let afterRegions = Self.regionEditCensus(scope: scope), ownsRegion(afterRegions),
                  Self.sameRegionPeers(initialRegions, afterRegions, ignoring: held.item) else {
                return unresolved("event_list_readback")
            }
            let modifiedColumn: Int
            switch step.field {
            case .position: modifiedColumn = 2
            case .pitch: modifiedColumn = 5
            case .velocity: modifiedColumn = 6
            case .length: modifiedColumn = 7
            }
            guard current.signature.indices.allSatisfy({ $0 == modifiedColumn || current.signature[$0] == changed.signature[$0] })
            else { return unresolved("event_list_note_peer_fields") }
            latest = changed
            verifiedSteps += 1
        }
        evidence["write_attempted"] = emitted > 0
        evidence["before"] = expected.evidence
        evidence["observed"] = desired.evidence
        evidence["unchanged"] = emitted == 0
        evidence["verified_steps"] = verifiedSteps
        evidence["peer_events_verified"] = peers.count
        return .success(HonestContract.encodeStateA(extras: evidence))
    }

    private static func midiEditValue(_ parameters: [String: String], prefix: String,
                                     defaultValue: Logic13MIDINoteValue? = nil) -> Logic13MIDINoteValue? {
        guard let channel = parameters[prefix + "channel"].flatMap(Int.init) ?? defaultValue?.channel,
              let pitch = parameters[prefix + "pitch"].flatMap(Int.init) ?? defaultValue?.pitch,
              let velocity = parameters[prefix + "velocity"].flatMap(Int.init) ?? defaultValue?.velocity,
              let position = (parameters[prefix + "position"] ?? defaultValue?.position.description)
                .flatMap({ Logic13MIDINoteCoordinate($0, length: false) }),
              let length = (parameters[prefix + "length"] ?? defaultValue?.length.description)
                .flatMap({ Logic13MIDINoteCoordinate($0, length: true) }) else { return nil }
        return Logic13MIDINoteValue(channel: channel, pitch: pitch, velocity: velocity, position: position, length: length)
    }

    private static func midiEditFitsRegion(plan: Logic13MIDINoteEditPlan, held: HeldRegion) -> Bool {
        guard let regionStart = held.info.startPosition.flatMap(ProjectBounceRange.position),
              let regionEnd = held.info.endPosition.flatMap(ProjectBounceRange.position) else { return false }
        // Bound start changes to the held region. Duration is verified independently
        // against the Event List and the retained Arrange extent after every edit.
        return plan.steps.allSatisfy {
            let start = $0.expected.position.components
            return !start.lexicographicallyPrecedes(regionStart) && start.lexicographicallyPrecedes(regionEnd)
        }
    }
}
