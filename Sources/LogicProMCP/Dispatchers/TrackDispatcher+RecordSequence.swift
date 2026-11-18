import AppKit
import Foundation
import MCP

/// One fail-closed observation of a relocation candidate. Tests use the explicit token; production
/// observations retain the exact AX track binding so an owned, append-only import can renew the
/// same physical target without reducing identity to an ordinal or display name.
struct RecordSequenceRelocationTrackObservation: @unchecked Sendable {
    let index: Int
    let name: String
    let type: TrackType
    let physicalBinding: AXTrackBinding.Binding?
    let testIdentity: String?
    let selectionReadback: Bool?

    init(index: Int, name: String, type: TrackType, testIdentity: String, selectionReadback: Bool? = nil) {
        self.index = index
        self.name = name
        self.type = type
        physicalBinding = nil
        self.testIdentity = testIdentity
        self.selectionReadback = selectionReadback
    }

    init(track: TrackState) {
        index = track.id
        name = track.name
        type = track.type
        physicalBinding = track.physicalBinding
        testIdentity = nil
        selectionReadback = track.selectionReadback
    }

    /// Proof of a selected, qualified instrument on the original physical track.
    /// The Inspector is only authoritative while this track owns selection.
    func hasSelectedLogic13QualifiedInstrument() -> Bool {
        guard let binding = physicalBinding, selectionReadback == true,
              binding.currentIndex() == index,
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(
                in: binding.window, runtime: binding.runtime),
              headers.indices.contains(index), CFEqual(binding.header, headers[index]),
              headers.enumerated().allSatisfy({
                  AXValueExtractors.extractSelectedState($0.element, runtime: binding.runtime.ax)
                      == ($0.offset == index)
              }),
              (AccessibilityChannel.logic13StudioGrandInspector(
                  named: name, in: binding.window, runtime: binding.runtime.ax)
               || RetroSynthSlot.acquire(physical: binding, index: index, name: name) != nil)
        else { return false }
        return binding.currentIndex() == index
    }

    func hasIdentity() -> Bool {
        (physicalBinding != nil) != (testIdentity != nil)
    }

    func hasCurrentIdentityAtIssuedIndex() -> Bool {
        if testIdentity != nil { return physicalBinding == nil }
        guard testIdentity == nil, let physicalBinding else { return false }
        return physicalBinding.currentIndex() == index
    }

    func hasSamePhysicalIdentity(as other: Self) -> Bool {
        if let testIdentity, let otherIdentity = other.testIdentity {
            return testIdentity == otherIdentity
        }
        guard testIdentity == nil, other.testIdentity == nil,
              let physicalBinding, let otherBinding = other.physicalBinding else { return false }
        return physicalBinding.matches(otherBinding)
    }

    /// The import is expected to append one track, which intentionally retires the baseline
    /// population shape. This narrower comparison is only for that owned append transition; later
    /// copy/paste boundaries must use `hasSamePhysicalIdentity` and current-index renewal.
    func hasSameIssuedCarrier(as other: Self) -> Bool {
        if let testIdentity, let otherIdentity = other.testIdentity {
            return testIdentity == otherIdentity
        }
        guard testIdentity == nil, other.testIdentity == nil,
              let physicalBinding, let otherBinding = other.physicalBinding else { return false }
        let sameExposure: Bool
        switch (physicalBinding.exposure, otherBinding.exposure) {
        case (nil, nil): sameExposure = true
        case (let first?, let second?): sameExposure = first === second
        default: sameExposure = false
        }
        return CFEqual(physicalBinding.window, otherBinding.window)
            && CFEqual(physicalBinding.header, otherBinding.header)
            && physicalBinding.document.utf8.elementsEqual(otherBinding.document.utf8)
            && sameExposure
    }
}

/// record_sequence SMF-import implementation, extracted from
/// TrackDispatcher.swift (pure move). handleRecordSequenceSMF generates a
/// Standard MIDI File from the notes spec, imports it via AX menu, and
/// verifies the imported region by AX readback. Helpers stay private to
/// this file; the nested RecordSequenceRegionReadback enum remains in the
/// core TrackDispatcher type.
extension TrackDispatcher {

    // MARK: - record_sequence SMF-import implementation

    /// Generate a Standard MIDI File from the notes spec, write to a private temp dir,
    /// then import into the current project via AX menu navigation. Logic always
    /// creates a NEW MIDI track for the imported content (verified OQ-3).
    static func handleRecordSequenceSMF(
        params: [String: MCP.Value],
        router: ChannelRouter,
        cache: StateCache,
        traceID: TraceID? = nil,
        trackHeaderCount: @escaping @Sendable () -> Int = { AXLogicProElements.allTrackHeaders().count },
        trackNameAt: @escaping @Sendable (Int) -> String? = { AXLogicProElements.trackName(at: $0) },
        relocationTrackInventory: @escaping @Sendable () -> [RecordSequenceRelocationTrackObservation]? = {
            let runtime = AXLogicProElements.Runtime.production
            if ProcessInfo.processInfo.environment["LOGIC_MCP_LOGIC13_TRACKS"] == "1" {
                guard case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                      case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime)
                else { return nil }
                return AccessibilityChannel.readTrackStates(from: headers, in: window, runtime: runtime,
                    readingTypeHelp: false, stoppingWhen: { Task.isCancelled }).states?
                    .map(RecordSequenceRelocationTrackObservation.init(track:))
            }
            return AccessibilityChannel.defaultGetTrackStates()?.map(RecordSequenceRelocationTrackObservation.init(track:))
        },
        readRegions: @escaping @Sendable () -> RecordSequenceRegionReadback = {
            switch AccessibilityChannel.enumerateRegionItems() {
            case .success(let result):
                return .success(
                    result.regions.map { $0.info },
                    complete: result.coversWholeArrangement
                )
            case .failure(let error):
                return .failure(error.message)
            }
        },
        settleReadback: @escaping @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 150_000_000) },
        selectFullPositionDisplay: @escaping @Sendable () -> ControlBarDisplayMode.Switch = {
            ControlBarDisplayMode.selectBeats()
        },
        restorePositionDisplay: @escaping @Sendable (ControlBarDisplayMode.Lease) -> ControlBarDisplayMode.Restore = {
            ControlBarDisplayMode.restore($0)
        }
    ) async -> CallTool.Result {
        // T5 — record_sequence does not support `port` (no keycmd alternative
        // for SMF-import + AX menu navigation). Reject up-front rather than
        // silently dropping the argument, so a caller who mistakenly thinks
        // `port:"keycmd"` would route this op gets an actionable hint instead
        // of a misleading success at the wrong transport.
        if params["port"] != nil {
            return toolInvalidParamsResult(
                "port parameter not supported for record_sequence"
            )
        }
        let bar: Int
        if params["bar"] != nil {
            guard let parsed = intParamOrNil(params, "bar"),
                  (1...9999).contains(parsed) else {
                return toolInvalidParamsResult(
                    "record_sequence 'bar' must be an integer in 1..9999"
                )
            }
            bar = parsed
        } else {
            bar = 1
        }
        let notes: String
        if let rawNotes = params["notes"] {
            guard let parsed = rawNotes.stringValue, !parsed.isEmpty else {
                return toolInvalidParamsResult(
                    "record_sequence requires 'notes' as a non-empty string"
                )
            }
            notes = parsed
        } else {
            return toolInvalidParamsResult(
                "record_sequence requires 'notes' (semicolon-separated 'pitch,offsetMs,durMs[,vel[,ch]]')"
            )
        }
        let requestedTempo: Double?
        if params["tempo"] != nil {
            guard let parsed = doubleParamOrNil(params, "tempo"), (5.0...999.0).contains(parsed) else {
                return toolInvalidParamsResult(
                    "record_sequence 'tempo' must be numeric in 5..999"
                )
            }
            requestedTempo = parsed
        } else {
            requestedTempo = nil
        }
        // Opt-in GM Device relocation: Logic 12.4 imports every SMF onto a new GM Device /
        // External MIDI lane regardless of program changes or the selected track. When the
        // caller names an existing Software Instrument track, the imported region is copied
        // onto it (never cut, so a failed paste cannot lose the take). The index is
        // corroborated by name, like delete/duplicate/set_instrument.
        let relocationTarget: (index: Int, expectedName: String)?
        if params["target_track"] != nil || params["target_expected_name"] != nil {
            guard let index = intParamOrNil(params, "target_track"), index >= 0 else {
                return toolInvalidParamsResult(
                    "record_sequence 'target_track' must be a non-negative integer track index"
                )
            }
            guard let expectedName = params["target_expected_name"]?.stringValue,
                  !expectedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return toolInvalidParamsResult(
                    "record_sequence 'target_track' requires 'target_expected_name' (the track name you expect at that index)"
                )
            }
            relocationTarget = (index, expectedName)
        } else {
            relocationTarget = nil
        }

        guard await cache.getHasDocument() else {
            return toolTextResult("record_sequence: No project open", isError: true)
        }

        let project = await cache.getProject()
        let cacheTempo = project.tempo > 0 ? project.tempo : 120.0
        let tempo = requestedTempo ?? cacheTempo
        // T3 — strict whole-parse-fail. The previous silent-skip parser left
        // callers unable to distinguish "user typed garbage" from "all
        // segments happened to be invalid", so the error wording was vague
        // ("could not parse any valid notes"). The new Result API surfaces
        // the specific failure (channel out of range, malformed segment,
        // etc.) so the LLM agent can self-correct on the next call.
        let events: [SMFWriter.NoteEvent]
        switch parseNotesToSMFEvents(notes: notes, tempo: tempo) {
        case .success(let parsed):
            events = parsed
        case .failure(let error):
            return toolTextResult(
                "record_sequence: invalid 'notes' — \(error.message)",
                isError: true
            )
        }
        guard !events.isEmpty else {
            return toolTextResult(
                "record_sequence: 'notes' parsed to zero events (input: '\(notes)')",
                isError: true
            )
        }
        // v3.1.2 P1-4 — enforce the 1024-note SMF-import upper bound that
        // `NoteSequenceParser`'s docstring already advertises. Without this
        // guard, a malformed (or adversarial) caller could hand SMFWriter an
        // arbitrarily large event list, which would produce an oversize
        // .mid file and slow Logic's MIDI File Import dialog enough to
        // appear hung. The 1024 limit matches the documented upper bound and
        // leaves a comfortable margin under SMFWriter's tick-encoding bounds.
        guard events.count <= 1024 else {
            return toolTextResult(
                "record_sequence: too many notes (\(events.count) > 1024 max for SMF import)",
                isError: true
            )
        }

        // A relocation refusal must precede every Logic write, including the bar-1 seek. Capture a
        // complete physical population now; an index/name pair alone cannot distinguish an Audio,
        // Aux, External MIDI, duplicate, reordered, or replaced target.
        let logic13Targeting = ProcessInfo.processInfo.environment["LOGIC_MCP_LOGIC13_TRACKS"] == "1"
        let relocationBaseline: [RecordSequenceRelocationTrackObservation]?
        if let relocationTarget {
            var refusal: [String: Any] = [
                "success": false,
                "verified": false,
                "write_attempted": false,
                "failure_stage": "relocation_preflight",
                "target_track": relocationTarget.index,
                "target_expected_name": relocationTarget.expectedName,
            ]
            guard let inventory = relocationTrackInventory(),
                  relocationInventoryIsExact(inventory) else {
                refusal["error"] = "target_inventory_unreadable"
                refusal["hint"] = "record_sequence could not acquire one complete physical Arrange-track inventory before any write."
                return jsonToolTextResult(refusal, isError: true)
            }
            refusal["track_count_before"] = inventory.count
            guard inventory.indices.contains(relocationTarget.index),
                  inventory[relocationTarget.index].index == relocationTarget.index else {
                refusal["error"] = "target_track_not_found"
                return jsonToolTextResult(refusal, isError: true)
            }
            let target = inventory[relocationTarget.index]
            refusal["observed_target_name"] = target.name
            refusal["observed_target_type"] = target.type.rawValue
            guard target.name.utf8.elementsEqual(relocationTarget.expectedName.utf8) else {
                refusal["error"] = "target_name_mismatch"
                return jsonToolTextResult(refusal, isError: true)
            }
            guard inventory.filter({ $0.name.utf8.elementsEqual(relocationTarget.expectedName.utf8) }).count == 1 else {
                refusal["error"] = "target_name_ambiguous"
                refusal["hint"] = "target_expected_name must identify exactly one Arrange track before any write."
                return jsonToolTextResult(refusal, isError: true)
            }
            let verifiedInstrument = logic13Targeting
                ? target.hasSelectedLogic13QualifiedInstrument() : target.type == .softwareInstrument
            guard verifiedInstrument else {
                refusal["error"] = "target_not_software_instrument"
                refusal["hint"] = logic13Targeting
                    ? "Select the requested Studio Grand or Retro Synth track before import so its Inspector can verify the instrument."
                    : "target_track must be positively observed as a Software Instrument track."
                return jsonToolTextResult(refusal, isError: true)
            }
            relocationBaseline = inventory
        } else {
            relocationBaseline = nil
        }

        let tempFile: SMFWriter.TemporaryMIDIFile
        do {
            tempFile = try SMFWriter.temporaryMIDIFile()
        } catch {
            return toolTextResult("record_sequence: temporary SMF path failed: \(error)", isError: true)
        }
        let path = tempFile.fileURL.path
        defer {
            SMFWriter.cleanupTemporaryMIDIFile(tempFile)
        }

        // Logic's MIDI File import strips leading empty delta before the first
        // channel event (region gets placed at bar 1 regardless of SMF offset).
        // SMFWriter counters this by emitting a padding CC#110 @ tick 0 when
        // bar > 1, so the first note lands at the requested bar inside a
        // region that spans bar 1 → bar+length. The region is cosmetically
        // longer than the notes, but note timing is exact with zero drift.
        do {
            let data = try SMFWriter.generate(
                events: events,
                bar: bar,
                tempo: tempo,
                timeSignature: (4, 4)
            )
            try data.write(to: tempFile.fileURL, options: .atomic)
        } catch {
            return toolTextResult("record_sequence: SMF generation failed: \(error)", isError: true)
        }

        // Logic Pro's MIDI File Import anchors the imported region to the
        // CURRENT playhead position. SMF Strategy D encodes the bar offset
        // inside the file (relative to tick 0), so the playhead must be at
        // bar 1 before import — otherwise notes land at playhead + offset,
        // not at the requested bar. A silent failure here would produce a
        // success response with content at the wrong position, so the goto
        // is a hard precondition: hasDocument is already true (guarded
        // above), so the goto-dialog is enabled on any non-empty project,
        // and on an empty project the playhead is already at bar 1 and the
        // slider fallback succeeds trivially.
        // Use the public seek's fresh pre/readback contract, not a raw channel acknowledgement.
        // Ordinary dialog OK is State B until its observed transition verifies; an indeterminate
        // global-input target must stay unverified even if the playhead happens to match.
        var preparationWriteAttempted = false
        var beforePosition = await TransportDispatcher.liveTransportState(router: router, cache: cache)
        // #1420 — the seek can only reach State A when the control bar shows all four position
        // components, and Logic's default display mode ("Beats & Project") shows bar and beat. A
        // bar-and-beat reading cannot see a sub-beat offset, and the region check after the import
        // compares bars only, so it is no substitute: switch to Beats for the seek, read the
        // position again in that mode, and put the original mode back once the seek is verified or
        // refused. The display mode moves no position, so restoring it keeps the verified anchor;
        // the import waits until the restore is confirmed.
        var displayModeFields: [String: Any] = [:]
        var displayModeLease: ControlBarDisplayMode.Lease?
        var displayModeSwitchFailure: String?
        if let observed = beforePosition?.positionReadback?.observedComponents,
           !observed.isEmpty, observed.count < TransportPositionComponent.allCases.count {
            // Selecting a menu item is this operation's first write, and it bypasses ChannelRouter.
            guard await recordWriteBoundary(
                traceID,
                deadlineStage: "position_display_switch"
            ) else {
                return recordSequenceDeadlineBoundaryRefusal("position_display_switch")
            }
            preparationWriteAttempted = true
            switch selectFullPositionDisplay() {
            case .switched(let lease):
                displayModeLease = lease
                displayModeFields["display_mode_switched_from"] = lease.original
                // The Playhead Position group gains its division and tick sliders after the popup
                // reads Beats (see `ControlBarDisplayMode.positionComponentsTimeout`), so reread
                // until all four are exposed; past the deadline, one fresh reading decides.
                let deadline = Date().addingTimeInterval(ControlBarDisplayMode.positionComponentsTimeout)
                repeat {
                    beforePosition = await TransportDispatcher.liveTransportState(router: router, cache: cache)
                    if beforePosition?.positionReadback?.observedComponents.count
                        == TransportPositionComponent.allCases.count { break }
                    let remaining = deadline.timeIntervalSinceNow
                    if remaining <= 0 {
                        beforePosition = await TransportDispatcher.liveTransportState(router: router, cache: cache)
                        break
                    }
                    try? await Task.sleep(nanoseconds: UInt64(
                        min(ControlBarDisplayMode.positionComponentsPollInterval, remaining) * 1_000_000_000))
                } while true
            case .unavailable(let reason):
                displayModeFields["display_mode_switch_unavailable"] = reason
            case .unsettled(let lease, let reason):
                displayModeSwitchFailure = reason
                displayModeFields["display_mode_switch_unsettled"] = reason
                if let lease {
                    displayModeFields["display_mode_switched_from"] = lease.original
                    guard OperationTraceContext.claimDeadlineEffect("position_display_restore") else {
                        return recordSequenceDeadlineBoundaryRefusal("position_display_restore")
                    }
                    switch restorePositionDisplay(lease) {
                    case .restored:
                        displayModeFields["display_mode_restored"] = true
                    case .refused(let restoreReason):
                        displayModeFields["display_mode_restored"] = false
                        displayModeFields["display_mode_restore_refused"] = restoreReason
                    }
                }
            }
        }
        if let displayModeSwitchFailure {
            var failure: [String: Any] = [
                "success": false,
                "verified": false,
                "error": "display_mode_switch_unsettled",
                "failure_stage": "display_mode_switch",
                "bar": bar,
                "note_count": events.count,
                "method": "smf_import",
                "hint": "record_sequence stopped before moving the playhead because the control-bar display-mode action did not settle: \(displayModeSwitchFailure)",
            ]
            failure.merge(displayModeFields) { current, _ in current }
            return jsonToolTextResult(failure, isError: true)
        }
        let gotoResult: CallTool.Result
        if let unchanged = TransportDispatcher.gotoPositionUnchangedResult(
            requestedPosition: "1.1.1.1", beforeTransport: beforePosition
        ) {
            gotoResult = unchanged
        } else {
            preparationWriteAttempted = true
            let routedGoto = await withWriteBoundaryArmed(
                traceID,
                deadlineStage: "playhead_preparation"
            ) {
                await router.route(operation: "transport.goto_position", params: ["bar": "1"])
            }
            gotoResult = await TransportDispatcher.finalizeGotoPositionResult(
                routedGoto, requestedPosition: "1.1.1.1", beforeTransport: beforePosition,
                router: router, cache: cache
            )
        }
        if let lease = displayModeLease {
            guard OperationTraceContext.claimDeadlineEffect("position_display_restore") else {
                return recordSequenceDeadlineBoundaryRefusal("position_display_restore")
            }
            switch restorePositionDisplay(lease) {
            case .restored:
                displayModeFields["display_mode_restored"] = true
            case .refused(let reason):
                displayModeFields["display_mode_restored"] = false
                displayModeFields["display_mode_restore_refused"] = reason
            }
        }
        guard !(gotoResult.isError ?? false) else {
            var positionDetail: String
            if case .text(let text, _, _) = gotoResult.content.first {
                positionDetail = text
                if !displayModeFields.isEmpty, var detail = importMessageJSON(text) {
                    detail.merge(displayModeFields) { current, _ in current }
                    if JSONSerialization.isValidJSONObject(detail),
                       let data = try? JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys]),
                       let merged = String(data: data, encoding: .utf8) {
                        positionDetail = merged
                    }
                }
            } else {
                positionDetail = "position verification unavailable"
            }
            return toolTextResult(
                "record_sequence failed to reset playhead to bar 1 (required for accurate import): \(positionDetail)",
                isError: true
            )
        }

        if displayModeFields["display_mode_restored"] as? Bool == false {
            var failure: [String: Any] = [
                "success": false,
                "verified": false,
                "error": "display_mode_restore_unverified",
                "failure_stage": "display_mode_restore",
                "bar": bar,
                "note_count": events.count,
                "method": "smf_import",
                "hint": "record_sequence verified the playhead at 1.1.1.1 in the Beats display mode but could not confirm restoring the control bar's original display mode, so it did not import.",
            ]
            failure.merge(displayModeFields) { current, _ in current }
            return jsonToolTextResult(failure, isError: true)
        }

        // The seek/display preparation can yield to Logic and other clients. Revalidate the exact
        // pre-import population before creating the otherwise unavoidable GM lane.
        if let relocationTarget, let relocationBaseline {
            guard let renewed = relocationTrackInventory(),
                  relocationInventoriesMatch(relocationBaseline, renewed),
                  !logic13Targeting || renewed[relocationTarget.index].hasSelectedLogic13QualifiedInstrument() else {
                return jsonToolTextResult([
                    "success": false,
                    "verified": false,
                    "write_attempted": preparationWriteAttempted,
                    "error": "target_changed",
                    "failure_stage": "relocation_preimport",
                    "target_track": relocationTarget.index,
                    "target_expected_name": relocationTarget.expectedName,
                    "hint": "The exact target population changed after playhead preparation, so record_sequence did not import or paste.",
                ], isError: true)
            }
        }

        let preImportRegions: [RegionInfo]?
        switch readRegions() {
        case .success(let regions, let complete):
            preImportRegions = logic13Targeting && relocationTarget != nil && !complete ? nil : regions
        case .failure:
            preImportRegions = nil
        }

        if logic13Targeting, relocationTarget != nil, preImportRegions == nil {
            return jsonToolTextResult([
                "success": false, "verified": false, "error": "unreadable_readback",
                "failure_stage": "relocation_preimport", "write_attempted": preparationWriteAttempted,
                "hint": "The Arrange region census could not be completed before import."
            ], isError: true)
        }

        // v3.1.2 (P0-2) — verify track creation against LIVE AX, not the
        // 3-second StatePoller cache. The previous cache-poll loop (2s
        // window, 100ms granularity) was strictly shorter than the poller
        // interval (3s, see ServerConfig.statePollingIntervalNs), so on a
        // healthy import the track count delta would not propagate to
        // `cache.getTracks()` until *after* the verification deadline,
        // false-failing every successful run on first call. Live-witnessed
        // 3× in production sessions.
        //
        // The downstream import handler (AccessibilityChannel
        // `defaultImportMIDIFile`) already validates the count delta against
        // live AX before returning success, so an `importResult.isSuccess`
        // proves a new track was created. We still re-read live track headers
        // here to discover the new track index and then verify the imported
        // region on that specific track.
        let tracksBefore = relocationBaseline?.count ?? trackHeaderCount()
        let importResult = await router.route(
            operation: "midi.import_file",
            params: ["path": path]
        )
        guard importResult.isSuccess else {
            // #140 — surface the import handler's dialog-seen flags at the top
            // level (not only buried in `detail`) so callers can distinguish an
            // occluded session (no file-open sheet ever appeared) from a real
            // import miss. The flags originate in
            // `AccessibilityChannel.defaultImportMIDIFile`.
            var failure: [String: Any] = [
                "success": false,
                "verified": false,
                "error": "import_failure",
                "failure_stage": "midi.import_file",
                "bar": bar,
                "note_count": events.count,
                "method": "smf_import",
                "detail": importResult.message,
                "hint": "record_sequence failed at midi.import_file: \(importResult.message)",
            ]
            if let inner = importMessageJSON(importResult.message) {
                for key in [
                    "file_open_dialog_seen", "tempo_dialog_seen", "missing_element", "osascript_stderr",
                    "permission", "safe_to_retry",
                    "automatic_permission_attempts_exhausted", "terminal", "terminal_scope",
                    "human_intervention_required", "human_intervention_requests",
                    "human_dependent_transitions",
                ] {
                    if let value = inner[key] { failure[key] = value }
                }
                if let innerWriteAttempted = inner["write_attempted"] as? Bool {
                    failure["write_attempted"] = preparationWriteAttempted || innerWriteAttempted
                } else if preparationWriteAttempted {
                    failure["write_attempted"] = true
                }
                if let innerError = inner["error"] as? String {
                    failure["import_error"] = innerError
                    if innerError == HonestContract.FailureError.systemEventsAutomationDenied.rawValue {
                        failure["error"] = innerError
                        if let hint = inner["hint"] as? String {
                            failure["hint"] = hint
                        }
                    }
                }
            }
            failure.merge(displayModeFields) { current, _ in current }
            return jsonToolTextResult(failure, isError: true)
        }

        if logic13Targeting, let relocationTarget, let relocationBaseline, let preImportRegions,
           let inner = importMessageJSON(importResult.message), inner["verified"] as? Bool == true {
            return await relocateImportedRegion(
                importDetail: inner, target: relocationTarget, baseline: relocationBaseline,
                tracksBefore: tracksBefore, requestedBar: bar, events: events, router: router, cache: cache,
                traceID: traceID, relocationTrackInventory: relocationTrackInventory,
                readRegions: readRegions, settleReadback: settleReadback,
                logic13: true, preImportRegions: preImportRegions,
                selectFullPositionDisplay: selectFullPositionDisplay, restorePositionDisplay: restorePositionDisplay)
        }

        if let inner = importMessageJSON(importResult.message),
           (inner["verified"] as? Bool) == false {
            let reason = (inner["reason"] as? String) ?? "import_unverified"
            let audibilityDowngrade = reason == HonestContract.UncertainReason.importedAsGMDevice.rawValue
            if audibilityDowngrade, let relocationTarget, let relocationBaseline {
                return await relocateImportedRegion(
                    importDetail: inner,
                    target: relocationTarget,
                    baseline: relocationBaseline,
                    tracksBefore: tracksBefore,
                    requestedBar: bar,
                    events: events,
                    router: router,
                    cache: cache,
                    traceID: traceID,
                    relocationTrackInventory: relocationTrackInventory,
                    readRegions: readRegions,
                    settleReadback: settleReadback
                )
            }
            var failure: [String: Any] = [
                "success": false,
                "verified": false,
                "error": audibilityDowngrade ? "audibility_unverified" : "import_unverified",
                "failure_stage": "midi.import_file",
                "import_reason": reason,
                "bar": bar,
                "note_count": events.count,
                "method": "smf_import",
                "detail": importResult.message,
                "hint": audibilityDowngrade
                    ? "record_sequence imported GM Device / external-MIDI lane(s); region readback cannot prove audible routing, so the take is blocked before a silent Logic Bounce can be claimed."
                    : "record_sequence import returned an unverified State B result; refusing to promote it to a verified take.",
            ]
            for key in [
                "audible",
                "gm_device_lanes",
                "imported_lanes",
                "track_count_before",
                "track_count_after",
                "observed_delta",
                "file_open_dialog_seen",
                "tempo_dialog_seen",
            ] {
                if let value = inner[key] { failure[key] = value }
            }
            failure.merge(displayModeFields) { current, _ in current }
            return jsonToolTextResult(failure, isError: true)
        }

        if logic13Targeting, relocationTarget != nil {
            return jsonToolTextResult([
                "success": false, "verified": false, "error": "import_receipt_unverified",
                "failure_stage": "relocation_postimport", "write_attempted": true, "safe_to_retry": false,
                "hint": "The import receipt did not establish an owned source lane. Inspect the arrangement before issuing another import."
            ], isError: true)
        }

        // Re-read live AX to confirm the new track index. Import handler has
        // already verified the delta, so we expect tracksAfter > tracksBefore
        // immediately; the small retry loop is purely defensive against AX
        // tree settle latency on slow machines (≤500ms total).
        var tracksAfter = trackHeaderCount()
        for _ in 0..<5 {
            if tracksAfter > tracksBefore { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            tracksAfter = trackHeaderCount()
        }
        guard tracksAfter > tracksBefore else {
            var failure: [String: Any] = [
                "success": false,
                "verified": false,
                "error": "import_failure",
                "failure_stage": "track_creation",
                "bar": bar,
                "note_count": events.count,
                "method": "smf_import",
                "track_count_before": tracksBefore,
                "track_count_after": tracksAfter,
                "terminal": true,
                "terminal_scope": "mcp_request_only",
                "human_intervention_required": false,
                "human_intervention_requests": 0,
                "human_dependent_transitions": 0,
                "safe_to_retry": false,
                "automatic_precondition_attempts_exhausted": true,
                "hint": "record_sequence: import handler reported success but the bounded live AX census still shows \(tracksBefore) tracks. No further write was issued; the import effect remains unverified.",
            ]
            failure.merge(displayModeFields) { current, _ in current }
            return jsonToolTextResult(failure, isError: true)
        }

        let createdTrack = tracksAfter - 1

        // v3.0.8 — instrument auto-load has been REMOVED from record_sequence.
        //
        // Prior versions (v3.0.2 – v3.0.7) auto-routed `track.set_instrument`
        // on the just-created track, defaulted `instrument_path` to
        // `"Synthesizer/Bass"`, and reported `"instrument":"loaded:..."` based
        // on `setResult.isSuccess`. Live testing on v3.0.7 + v3.0.8-draft
        // revealed two compounding bugs that made that path untrustworthy:
        //
        //   1. `LibraryAccessor.selectPath`'s AXPress on the preset leaf
        //      returns `.success` when the AX action is *delivered*, not when
        //      Logic's handler actually swaps the channel-strip instrument.
        //      `selectCategory` unconditionally returns `true` once the
        //      AXStaticText element is found, whether or not the AX write
        //      committed.
        //   2. `AXLogicProElements.selectTrackViaAX(at:)` is silently unable
        //      to change selection on a freshly-created track header on the
        //      first run-loop tick after SMF import. AXPress, AXSelected,
        //      child AXPress, and coord-click ALL get dropped; the header is
        //      visible in the AX tree and `findTrackHeader` resolves it, but
        //      selection never moves off the previously-selected track. The
        //      downstream `selectPath` then loads the preset onto whichever
        //      track was already selected — which can CORRUPT a pre-existing
        //      track's patch. Observed live: `record_sequence` with
        //      `instrument_path: "Electronic Drums/Brooklyn Borough"` on a
        //      project with a pre-existing `Deluxe Classic` (Electric Piano)
        //      track silently replaced `Deluxe Classic`'s patch with the
        //      Brooklyn Borough drum kit, while the new MIDI-imported track
        //      kept its default `Studio Grand` piano.
        //
        // v3.0.9 note — the `selectTrackViaAX` primitive itself is now fixed
        // (switched to AXSelectedChildren on the parent "Tracks header" group,
        // which is what Library preset selection already used). Callers of
        // `track.set_instrument { index: N }` now consistently target track N.
        // The record_sequence internal auto-load is STILL removed, however:
        // bundling two separate live Logic ops inside one dispatcher call
        // creates ordering dependencies that are hard to reason about, and
        // Isaac's policy on this ("decouple") stands. Callers who want a
        // specific patch after `record_sequence` should call `track.select`
        // + `track.set_instrument` explicitly on the returned track index.
        let instrumentPath = stringParam(params, "instrument_path", "instrument")
        let instrumentStatus: String
        if instrumentPath.isEmpty {
            instrumentStatus = "not-attempted"
        } else {
            instrumentStatus = "ignored:\(instrumentPath) (v3.0.8: internal auto-load removed to prevent corrupting a pre-existing track — call set_instrument explicitly; see CHANGELOG v3.0.8 for the selectTrackViaAX limitation on fresh SMF-created tracks)"
        }

        return await verifyRecordSequenceImport(
            createdTrack: createdTrack,
            targetTrackName: trackNameAt(createdTrack),
            requestedBar: bar,
            noteCount: events.count,
            instrumentStatus: instrumentStatus,
            events: events,
            preImportRegions: preImportRegions,
            readRegions: readRegions,
            settleReadback: settleReadback,
            displayModeFields: displayModeFields
        )
    }

    private static func recordSequenceDeadlineBoundaryRefusal(_ stage: String) -> CallTool.Result {
        jsonToolTextResult([
            "success": false,
            "verified": false,
            "error": HonestContract.FailureError.cancelled.rawValue,
            "failure_stage": stage,
            "write_attempted": false,
            "hint": "record_sequence stopped because its request deadline won before this write boundary.",
        ], isError: true)
    }

    /// Copies a single-lane GM Device import onto a caller-named Software Instrument track.
    ///
    /// Measured on Logic 12.4 (build 6707): File > Import > MIDI File always creates a new GM Device
    /// lane, even with a GM program change in the file and a Software Instrument track selected.
    /// Selecting a track selects its regions, so select source > copy > select target > playhead at
    /// bar 1 > paste puts the region on the target at the same bars (the bar offset is inside the
    /// region, as for the import itself). Copy, not cut: until the paste is read back, the take
    /// stays on the GM lane, so no failure below can lose it. The GM lane is never deleted here;
    /// the result names it so the caller can remove it with a corroborated `tracks.delete`.
    private static func relocateImportedRegion(
        importDetail: [String: Any],
        target: (index: Int, expectedName: String),
        baseline: [RecordSequenceRelocationTrackObservation],
        tracksBefore: Int,
        requestedBar: Int,
        events: [SMFWriter.NoteEvent],
        router: ChannelRouter,
        cache: StateCache,
        traceID: TraceID?,
        relocationTrackInventory: @escaping @Sendable () -> [RecordSequenceRelocationTrackObservation]?,
        readRegions: @escaping @Sendable () -> RecordSequenceRegionReadback,
        settleReadback: @escaping @Sendable () async -> Void,
        logic13: Bool = false,
        preImportRegions: [RegionInfo] = [],
        selectFullPositionDisplay: @Sendable () -> ControlBarDisplayMode.Switch = { .unavailable("unsupported") },
        restorePositionDisplay: @Sendable (ControlBarDisplayMode.Lease) -> ControlBarDisplayMode.Restore = {
            _ in .refused("unsupported")
        }
    ) async -> CallTool.Result {
        let expectedEndBar = recordSequenceExpectedEndBar(for: events, requestedBar: requestedBar)
        let gmLanes = (importDetail["gm_device_lanes"] as? [String]) ?? []
        guard let afterImport = relocationTrackInventory() else {
            return jsonToolTextResult([
                "success": false, "verified": false, "error": "target_inventory_unreadable",
                "failure_stage": "relocation_postimport",
                "write_attempted": true,
                "hint": "The imported take remains in Logic, but the exact post-import track population could not be read; nothing was copied or pasted.",
            ], isError: true)
        }
        let tracksAfter = afterImport.count
        let sourceIndex = tracksAfter - 1
        let sourceName = afterImport.last?.name ?? ""
        let sourceLabel = logic13 ? "import lane" : "GM Device lane"
        var base: [String: Any] = [
            "bar": requestedBar,
            "note_count": events.count,
            "method": "smf_import",
            "relocation": logic13 ? "import_lane_to_instrument_copy" : "gm_device_to_instrument_copy",
            "source_track_index": sourceIndex,
            "source_track_name": sourceName,
            "target_track_index": target.index,
            "target_track_name": target.expectedName,
            "expected_start_bar": 1,
            "expected_end_bar": expectedEndBar,
            "track_count_before": tracksBefore,
            "track_count_after": tracksAfter,
            "write_attempted": true,
        ]
        if !logic13 {
            base["gm_device_lane_index"] = sourceIndex
            base["gm_device_lane_name"] = sourceName
        }
        var keyboardScope: Logic13ArrangeKeyboardScope?
        var requestedLibraryClose = false
        var verifiedLibraryClosed = false

        func restoreLibrary(into payload: inout [String: Any]) async {
            guard requestedLibraryClose, let keyboardScope else { return }
            if keyboardScope.libraryIsOpen == true {
                payload["library_restored"] = true
                return
            }
            guard verifiedLibraryClosed, keyboardScope.requestLibrary(open: true) else {
                payload["library_restored"] = false
                return
            }
            payload["library_restored"] = await keyboardScope.waitForLibrary(open: true, settle: settleReadback)
        }

        func failure(_ error: String, stage: String, hint: String, extras: [String: Any] = [:]) async -> CallTool.Result {
            var payload = base.merging(extras) { _, new in new }
            payload["success"] = false
            payload["verified"] = false
            payload["error"] = error
            payload["failure_stage"] = stage
            payload["terminal"] = true
            payload["terminal_scope"] = "mcp_request_only"
            payload["human_intervention_required"] = false
            payload["human_intervention_requests"] = 0
            payload["human_dependent_transitions"] = 0
            payload["safe_to_retry"] = false
            payload["automatic_precondition_attempts_exhausted"] = true
            payload["hint"] = hint + " The imported take is still on \(sourceLabel) \(sourceIndex) ('\(sourceName)')."
            await restoreLibrary(into: &payload)
            return jsonToolTextResult(payload, isError: true)
        }

        // Only the shape that was measured is supported: one new lane, recognisably GM Device,
        // appended after the existing tracks, with the target still where the preflight saw it.
        let observedImportLane = logic13
            ? importDetail["imported_region_count"] as? Int == 1
            : gmLanes.count == 1 && afterImport.last?.type == .externalMIDI
                && !AccessibilityChannel.gmDeviceLanesAmongNewTracks(names: [sourceName], beforeCount: 0).isEmpty
        guard observedImportLane, tracksAfter == tracksBefore + 1,
              relocationInventoryIsOwnedAppend(baseline: baseline, current: afterImport),
              afterImport.last?.index == sourceIndex else {
            return await failure(
                "relocation_unsupported", stage: "relocation_preflight",
                hint: "Relocation requires exactly one verified imported lane and an unchanged pre-existing track population.",
                extras: ["gm_device_lanes": gmLanes]
            )
        }
        guard afterImport.indices.contains(target.index),
              afterImport[target.index].name.utf8.elementsEqual(target.expectedName.utf8),
              logic13 || afterImport[target.index].type == .softwareInstrument else {
            return await failure(
                "target_changed", stage: "relocation_postimport",
                hint: "The exact Software Instrument target did not survive the owned GM-lane append unchanged."
            )
        }

        guard let sourceRegion = await pollRegionReadback(
            readRegions: readRegions, settleReadback: settleReadback,
            match: { preferredRecordSequenceRegion(from: $0.filter { $0.trackIndex == sourceIndex }) }
        ) else {
            return await failure(
                "unreadable_readback", stage: "relocation_source",
                hint: "No MIDI region could be read on the GM Device lane, so nothing was copied."
            )
        }
        let regionsBeforePaste: [RegionInfo]
        if case .success(let regions, complete: true) = readRegions(),
           !logic13 || exactSingleRegionAddition(before: preImportRegions, after: regions)
            .map({ recordSequenceRegionKey($0) == recordSequenceRegionKey(sourceRegion) }) == true {
            regionsBeforePaste = regions
        } else {
            return await failure(
                "unreadable_readback", stage: "relocation_source",
                hint: "The pre-paste region census did not cover the whole arrangement, so a paste could not be told apart from other changes."
            )
        }

        if logic13 {
            guard let binding = afterImport[target.index].physicalBinding,
                  let scope = Logic13ArrangeKeyboardScope(binding: binding),
                  let libraryOpen = scope.libraryIsOpen else {
                return await failure("arrange_unverified", stage: "relocation_keyboard_scope",
                    hint: "The current Arrange window and Library state could not be verified.")
            }
            keyboardScope = scope
            if libraryOpen {
                requestedLibraryClose = scope.requestLibrary(open: false)
                if requestedLibraryClose {
                    verifiedLibraryClosed = await scope.waitForLibrary(open: false, settle: settleReadback)
                }
                guard verifiedLibraryClosed else {
                    return await failure("arrange_unverified", stage: "relocation_keyboard_scope",
                        hint: "Logic did not confirm the Library was closed before keyboard editing.")
                }
            }
        }

        let selectSource = await withWriteBoundaryArmed(
            traceID,
            deadlineStage: "relocation_select_source"
        ) {
            await router.route(operation: "track.select", params: ["index": String(sourceIndex)])
        }
        guard channelResultIsVerified(selectSource) else {
            return await failure("select_failed", stage: "relocation_select_source",
                           hint: "Could not verify exclusive selection of the GM Device lane: \(selectSource.message).")
        }
        guard let copyBoundary = relocationTrackInventory(),
              relocationInventoriesMatch(afterImport, copyBoundary),
              relocationInventoryConfirmsExclusiveSelection(copyBoundary, selectedIndex: sourceIndex),
              !logic13 || AccessibilityChannel.selectedRegionInfos().map({
                  $0.map(recordSequenceRegionKey) == [recordSequenceRegionKey(sourceRegion)]
              }) == true else {
            return await failure(
                "source_changed", stage: "relocation_copy_boundary",
                hint: "The exact GM Device source was no longer the sole selected track immediately before copy; nothing was copied."
            )
        }
        let clipboardBefore = logic13 ? await MainActor.run { NSPasteboard.general.changeCount } : nil
        let copy: ChannelResult? = await withWriteBoundaryArmed(traceID, deadlineStage: "relocation_copy") {
            guard !logic13 || keyboardScope?.hasArrangeFocus() == true else { return nil }
            return await router.route(operation: "edit.copy")
        }
        guard let copy else {
            return await failure("arrange_focus_unverified", stage: "relocation_copy",
                hint: "Keyboard focus was outside the verified Tracks area. Copy was withheld.")
        }
        guard copy.isSuccess else {
            return await failure("copy_failed", stage: "relocation_copy", hint: "Copy was not delivered: \(copy.message).")
        }
        var copiedClipboard: Int?
        if let clipboardBefore {
            for _ in 0..<8 {
                let observed = await MainActor.run { NSPasteboard.general.changeCount }
                if observed != clipboardBefore {
                    copiedClipboard = observed
                    break
                }
                await settleReadback()
            }
            guard copiedClipboard != nil else {
                return await failure("copy_unverified", stage: "relocation_copy", hint: "Logic did not publish a new clipboard item.")
            }
        }
        let selectTarget = await withWriteBoundaryArmed(
            traceID,
            deadlineStage: "relocation_select_target"
        ) {
            await router.route(operation: "track.select", params: ["index": String(target.index)])
        }
        guard channelResultIsVerified(selectTarget) else {
            return await failure("select_failed", stage: "relocation_select_target",
                           hint: "Could not verify exclusive selection of target track \(target.index): \(selectTarget.message). Nothing was pasted.")
        }

        // The import already left the playhead at bar 1; confirm it rather than assume it.
        let beforePosition = await TransportDispatcher.liveTransportState(router: router, cache: cache)
        if logic13 {
            let anchored = await verifyLogic13RelocationAnchor(
                beforePosition: beforePosition, router: router, cache: cache, traceID: traceID,
                selectDisplay: selectFullPositionDisplay, restoreDisplay: restorePositionDisplay)
            guard anchored else {
                return await failure("playhead_unverified", stage: "relocation_playhead",
                    hint: "The exact bar-one paste position could not be verified.")
            }
        } else if TransportDispatcher.gotoPositionUnchangedResult(
            requestedPosition: "1.1.1.1", beforeTransport: beforePosition
        ) == nil {
            let routedGoto = await withWriteBoundaryArmed(
                traceID,
                deadlineStage: "relocation_playhead"
            ) {
                await router.route(operation: "transport.goto_position", params: ["bar": "1"])
            }
            let gotoResult = await TransportDispatcher.finalizeGotoPositionResult(
                routedGoto, requestedPosition: "1.1.1.1", beforeTransport: beforePosition,
                router: router, cache: cache
            )
            guard !(gotoResult.isError ?? false) else {
                return await failure("playhead_unverified", stage: "relocation_playhead",
                               hint: "The playhead could not be verified at bar 1, so nothing was pasted.")
            }
        }

        // This is the final decision read before paste. Source selection, copy, target selection,
        // and an optional seek all yield. Any replacement/reorder/type/name/population drift, or an
        // unconfirmed target selection, closes the boundary without consuming the clipboard.
        guard let pasteBoundary = relocationTrackInventory(),
              relocationInventoriesMatch(afterImport, pasteBoundary),
              pasteBoundary.indices.contains(target.index),
              pasteBoundary[target.index].name.utf8.elementsEqual(target.expectedName.utf8),
              logic13 ? pasteBoundary[target.index].hasSelectedLogic13QualifiedInstrument()
                  : pasteBoundary[target.index].type == .softwareInstrument else {
            return await failure(
                "target_changed", stage: "relocation_paste_boundary",
                hint: "The exact selected Software Instrument target changed or could not be renewed immediately before paste. Nothing was pasted."
            )
        }
        guard relocationInventoryConfirmsExclusiveSelection(
            pasteBoundary, selectedIndex: target.index
        ) else {
            return await failure(
                "target_changed", stage: "relocation_paste_boundary",
                hint: "The exact Software Instrument target was not the sole selected track immediately before paste. Nothing was pasted."
            )
        }

        if logic13, await MainActor.run(body: { NSPasteboard.general.changeCount }) != copiedClipboard {
            return await failure("clipboard_changed", stage: "relocation_paste_boundary", hint: "The clipboard changed after the owned copy.")
        }
        let paste: ChannelResult? = await withWriteBoundaryArmed(traceID, deadlineStage: "relocation_paste") {
            guard !logic13 || keyboardScope?.hasArrangeFocus() == true else { return nil }
            return await router.route(operation: "edit.paste")
        }
        guard let paste else {
            return await failure("arrange_focus_unverified", stage: "relocation_paste",
                hint: "Keyboard focus was outside the verified Tracks area. Paste was withheld.")
        }
        guard paste.isSuccess else {
            return await failure("paste_failed", stage: "relocation_paste", hint: "Paste was not delivered: \(paste.message).")
        }

        guard let pasted = await pollStableRegionReadback(
            readRegions: readRegions, settleReadback: settleReadback,
            match: { regions in
                guard let added = exactSingleRegionAddition(
                    before: regionsBeforePaste, after: regions
                ), added.trackIndex == target.index else { return nil }
                return added
            }
        ) else {
            return await failure("paste_unverified", stage: "relocation_verify",
                           hint: "The bounded readback did not prove exactly one new region on target track \(target.index) while preserving every prior region; no further write was issued.")
        }
        guard pasted.startBar == sourceRegion.startBar, pasted.endBar == sourceRegion.endBar,
              pasted.startBar == 1, pasted.endBar == expectedEndBar else {
            var observed = recordSequenceRegionFields(pasted, prefix: "observed_")
            observed["observed_track_index"] = pasted.trackIndex
            return await failure("timing_mismatch", stage: "relocation_verify",
                           hint: "A region was pasted on track \(target.index) but its bars do not match the import.",
                           extras: observed)
        }

        var payload = base.merging(recordSequenceRegionFields(pasted)) { _, new in new }
        payload["success"] = true
        payload["verified"] = true
        payload["verify_source"] = "ax_region_delta"
        payload["recorded_to_track"] = target.index
        payload["instrument"] = "existing_target_track"
        payload["source_track_retained"] = true
        if !logic13 { payload["gm_device_lane_retained"] = true }
        payload["cleanup_hint"] = "The original take is still on \(sourceLabel) \(sourceIndex). Identify it by a fresh track reference before removing it."
        await restoreLibrary(into: &payload)
        return jsonToolTextResult(payload)
    }

    private static func verifyLogic13RelocationAnchor(
        beforePosition: TransportState?, router: ChannelRouter, cache: StateCache, traceID: TraceID?,
        selectDisplay: @Sendable () -> ControlBarDisplayMode.Switch,
        restoreDisplay: @Sendable (ControlBarDisplayMode.Lease) -> ControlBarDisplayMode.Restore
    ) async -> Bool {
        if TransportDispatcher.gotoPositionUnchangedResult(
            requestedPosition: "1.1.1.1", beforeTransport: beforePosition) != nil { return true }
        guard await recordWriteBoundary(traceID, deadlineStage: "relocation_display_switch") else { return false }
        let lease: ControlBarDisplayMode.Lease
        switch selectDisplay() {
        case .switched(let observed):
            lease = observed
        case .unsettled(let observed, _):
            if let observed, OperationTraceContext.claimDeadlineEffect("relocation_display_restore") {
                _ = restoreDisplay(observed)
            }
            return false
        case .unavailable:
            return false
        }
        let deadline = Date().addingTimeInterval(ControlBarDisplayMode.positionComponentsTimeout)
        var anchored = false
        repeat {
            let state = await TransportDispatcher.liveTransportState(router: router, cache: cache)
            anchored = TransportDispatcher.gotoPositionUnchangedResult(
                requestedPosition: "1.1.1.1", beforeTransport: state) != nil
            if anchored { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline && !Task.isCancelled
        guard OperationTraceContext.claimDeadlineEffect("relocation_display_restore") else { return false }
        let restoration = restoreDisplay(lease)
        return anchored && restoration == .restored
    }

    private static func relocationInventoryIsExact(
        _ inventory: [RecordSequenceRelocationTrackObservation]
    ) -> Bool {
        guard !inventory.isEmpty,
              inventory.enumerated().allSatisfy({
                  $0.offset == $0.element.index
                      && $0.element.hasIdentity()
                      && $0.element.hasCurrentIdentityAtIssuedIndex()
              })
        else { return false }
        for first in inventory.indices {
            for second in inventory.indices where first < second {
                if inventory[first].hasSamePhysicalIdentity(as: inventory[second]) { return false }
            }
        }
        return true
    }

    private static func relocationInventoryHadExactIssuedStructure(
        _ inventory: [RecordSequenceRelocationTrackObservation]
    ) -> Bool {
        guard !inventory.isEmpty,
              inventory.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.hasIdentity() })
        else { return false }
        for first in inventory.indices {
            for second in inventory.indices where first < second {
                if inventory[first].hasSameIssuedCarrier(as: inventory[second]) { return false }
            }
        }
        return true
    }

    private static func relocationInventoriesMatch(
        _ expected: [RecordSequenceRelocationTrackObservation],
        _ observed: [RecordSequenceRelocationTrackObservation]
    ) -> Bool {
        guard expected.count == observed.count,
              relocationInventoryIsExact(expected), relocationInventoryIsExact(observed) else { return false }
        return zip(expected, observed).allSatisfy { prior, current in
            prior.index == current.index
                && prior.name.utf8.elementsEqual(current.name.utf8)
                && prior.type == current.type
                && prior.hasSamePhysicalIdentity(as: current)
        }
    }

    private static func relocationInventoryIsOwnedAppend(
        baseline: [RecordSequenceRelocationTrackObservation],
        current: [RecordSequenceRelocationTrackObservation]
    ) -> Bool {
        guard current.count == baseline.count + 1,
              relocationInventoryHadExactIssuedStructure(baseline), relocationInventoryIsExact(current) else { return false }
        return zip(baseline, current.prefix(baseline.count)).allSatisfy { prior, observed in
            prior.index == observed.index
                && prior.name.utf8.elementsEqual(observed.name.utf8)
                && prior.type == observed.type
                && prior.hasSameIssuedCarrier(as: observed)
        }
    }

    private static func relocationInventoryConfirmsExclusiveSelection(
        _ inventory: [RecordSequenceRelocationTrackObservation],
        selectedIndex: Int
    ) -> Bool {
        guard inventory.indices.contains(selectedIndex) else { return false }
        return inventory.enumerated().allSatisfy { index, observation in
            observation.selectionReadback == (index == selectedIndex)
        }
    }

    private static func exactSingleRegionAddition(
        before: [RegionInfo],
        after: [RegionInfo]
    ) -> RegionInfo? {
        var remaining = Dictionary(
            before.map { (recordSequenceRegionKey($0), 1) },
            uniquingKeysWith: +
        )
        var added: [RegionInfo] = []
        for region in after {
            let key = recordSequenceRegionKey(region)
            if let count = remaining[key], count > 0 {
                if count == 1 {
                    remaining.removeValue(forKey: key)
                } else {
                    remaining[key] = count - 1
                }
            } else {
                added.append(region)
            }
        }
        guard remaining.isEmpty, added.count == 1 else { return nil }
        return added[0]
    }

    /// Reads regions until `match` finds something, giving Logic's AX tree the same settle budget
    /// as the import verification.
    private static func pollRegionReadback(
        attempts: Int = 10,
        readRegions: @Sendable () -> RecordSequenceRegionReadback,
        settleReadback: @Sendable () async -> Void,
        match: ([RegionInfo]) -> RegionInfo?
    ) async -> RegionInfo? {
        for attempt in 0..<attempts {
            if case .success(let regions, _) = readRegions(), let found = match(regions) {
                return found
            }
            if attempt < attempts - 1 {
                await settleReadback()
            }
        }
        return nil
    }

    /// A relocation success is stronger than finding one matching AX snapshot: Logic can expose
    /// the expected paste before a second selected lane finishes redrawing. Require the same
    /// complete whole-arrangement population twice with a settle boundary between the reads.
    private static func pollStableRegionReadback(
        attempts: Int = 10,
        readRegions: @Sendable () -> RecordSequenceRegionReadback,
        settleReadback: @Sendable () async -> Void,
        match: ([RegionInfo]) -> RegionInfo?
    ) async -> RegionInfo? {
        var previousPopulation: [String: Int]?
        for attempt in 0..<attempts {
            if case .success(let regions, complete: true) = readRegions(),
               let found = match(regions) {
                let population = Dictionary(
                    regions.map { (recordSequenceRegionKey($0), 1) },
                    uniquingKeysWith: +
                )
                if previousPopulation == population {
                    return found
                }
                previousPopulation = population
            } else {
                previousPopulation = nil
            }
            if attempt < attempts - 1 {
                await settleReadback()
            }
        }
        return nil
    }

    private enum RecordSequenceReadbackStatus {
        case verified([String: Any])
        case failed([String: Any])
        case pending
    }

    /// Parse the `midi.import_file` envelope (a JSON string carried in
    /// `ChannelResult.message`) so record_sequence can lift specific fields
    /// (e.g. #140 dialog-seen flags) to its own top-level envelope. Returns nil
    /// for non-JSON/free-form messages.
    private static func importMessageJSON(_ message: String) -> [String: Any]? {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func jsonToolTextResult(_ object: [String: Any], isError: Bool = false) -> CallTool.Result {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return toolTextResult("record_sequence: failed to encode JSON response", isError: true)
        }
        return toolTextResult(text, isError: isError)
    }

    private static func verifyRecordSequenceImport(
        createdTrack: Int,
        targetTrackName: String?,
        requestedBar: Int,
        noteCount: Int,
        instrumentStatus: String,
        events: [SMFWriter.NoteEvent],
        preImportRegions: [RegionInfo]?,
        readRegions: @escaping @Sendable () -> RecordSequenceRegionReadback,
        settleReadback: @escaping @Sendable () async -> Void,
        displayModeFields: [String: Any] = [:]
    ) async -> CallTool.Result {
        let expectedStartBar = 1
        let expectedEndBar = recordSequenceExpectedEndBar(for: events, requestedBar: requestedBar)
        var base: [String: Any] = [
            "bar": requestedBar,
            "created_track": createdTrack,
            "recorded_to_track": createdTrack,
            "target_track_index": createdTrack,
            "target_track_name": targetTrackName ?? "",
            "note_count": noteCount,
            "method": "smf_import",
            "instrument": instrumentStatus,
            "expected_start_bar": expectedStartBar,
            "expected_end_bar": expectedEndBar,
        ]
        base.merge(displayModeFields) { current, _ in current }
        let preRegionKeys = Set((preImportRegions ?? []).map(recordSequenceRegionKey))
        let hasPreImportSnapshot = preImportRegions != nil
        let verifySource = hasPreImportSnapshot ? "ax_region_delta" : "ax_region_readback"

        var bestFailure: [String: Any]?
        var lastReadbackError: String?
        var lastRegionCount = 0
        var lastNewRegionCount = 0

        for attempt in 0..<10 {
            switch readRegions() {
            case .failure(let error):
                lastReadbackError = error
            case .success(let regions, _):
                lastRegionCount = regions.count
                lastNewRegionCount = hasPreImportSnapshot
                    ? regions.filter { !preRegionKeys.contains(recordSequenceRegionKey($0)) }.count
                    : 0

                switch diagnoseRecordSequenceReadback(
                    postImportRegions: regions,
                    hasPreImportSnapshot: hasPreImportSnapshot,
                    preImportRegionKeys: preRegionKeys,
                    createdTrack: createdTrack,
                    expectedStartBar: expectedStartBar,
                    expectedEndBar: expectedEndBar,
                    base: base,
                    verifySource: verifySource
                ) {
                case .verified(let payload):
                    return jsonToolTextResult(payload)
                case .failed(let payload):
                    if shouldPreferRecordSequenceFailure(candidate: payload, over: bestFailure) {
                        bestFailure = payload
                    }
                case .pending:
                    break
                }
            }

            if attempt < 9 {
                await settleReadback()
            }
        }

        if var bestFailure {
            bestFailure["region_count"] = lastRegionCount
            bestFailure["new_region_count"] = lastNewRegionCount
            if let lastReadbackError {
                bestFailure["readback_error"] = lastReadbackError
            }
            return jsonToolTextResult(bestFailure, isError: true)
        }

        var payload = base
        payload["success"] = false
        payload["verified"] = false
        payload["error"] = "unreadable_readback"
        payload["verify_source"] = verifySource
        payload["region_count"] = lastRegionCount
        payload["new_region_count"] = lastNewRegionCount
        payload["hint"] = lastReadbackError.map {
            "record_sequence region readback failed: \($0)"
        } ?? "record_sequence imported a new track but no MIDI region could be verified from AX readback"
        if let lastReadbackError {
            payload["readback_error"] = lastReadbackError
        }
        return jsonToolTextResult(payload, isError: true)
    }

    private static func diagnoseRecordSequenceReadback(
        postImportRegions: [RegionInfo],
        hasPreImportSnapshot: Bool,
        preImportRegionKeys: Set<String>,
        createdTrack: Int,
        expectedStartBar: Int,
        expectedEndBar: Int,
        base: [String: Any],
        verifySource: String
    ) -> RecordSequenceReadbackStatus {
        let newRegions = hasPreImportSnapshot
            ? postImportRegions.filter { !preImportRegionKeys.contains(recordSequenceRegionKey($0)) }
            : []
        let targetRegions = postImportRegions.filter { $0.trackIndex == createdTrack }

        if let targetRegion = preferredRecordSequenceRegion(from: targetRegions) {
            var payload = base
            payload["verify_source"] = verifySource
            for (key, value) in recordSequenceRegionFields(targetRegion) {
                payload[key] = value
            }
            if targetRegion.startBar < 0 || targetRegion.endBar < 0 {
                payload["success"] = false
                payload["verified"] = false
                payload["error"] = "unreadable_readback"
                payload["hint"] = "record_sequence found a region on the created track, but AX did not expose readable start/end bars"
                return .failed(payload)
            }
            if targetRegion.startBar == expectedStartBar && targetRegion.endBar == expectedEndBar {
                payload["success"] = true
                payload["verified"] = true
                return .verified(payload)
            }
            payload["success"] = false
            payload["verified"] = false
            payload["error"] = "timing_mismatch"
            payload["hint"] = "record_sequence region readback did not match the expected bar envelope"
            return .failed(payload)
        }

        if let wrongTrackRegion = preferredRecordSequenceRegion(from: newRegions.filter { $0.trackIndex >= 0 && $0.trackIndex != createdTrack }) {
            var payload = base
            payload["success"] = false
            payload["verified"] = false
            payload["error"] = "wrong_track_import"
            payload["verify_source"] = verifySource
            payload["hint"] = "record_sequence imported a region, but AX readback placed it on track \(wrongTrackRegion.trackIndex) instead of the newly created track \(createdTrack)"
            for (key, value) in recordSequenceRegionFields(wrongTrackRegion, prefix: "observed_") {
                payload[key] = value
            }
            return .failed(payload)
        }

        if postImportRegions.isEmpty {
            return .pending
        }

        var payload = base
        payload["success"] = false
        payload["verified"] = false
        payload["error"] = "unreadable_readback"
        payload["verify_source"] = verifySource
        payload["hint"] = "record_sequence imported a new track but no MIDI region could be verified on the created track"
        return .failed(payload)
    }

    private static func shouldPreferRecordSequenceFailure(
        candidate: [String: Any],
        over current: [String: Any]?
    ) -> Bool {
        guard let current else { return true }
        return recordSequenceFailurePriority(candidate) > recordSequenceFailurePriority(current)
    }

    private static func recordSequenceFailurePriority(_ payload: [String: Any]) -> Int {
        switch payload["error"] as? String {
        case "wrong_track_import":
            return 3
        case "timing_mismatch":
            return 2
        case "unreadable_readback":
            return 1
        default:
            return 0
        }
    }

    /// The bar Logic will report as the region's end.
    ///
    /// Logic numbers a region's end as the bar line it stops on: a region filling exactly bar 1 is
    /// "1 to 2". The previous integer division added 2 unconditionally, which pushed a sequence
    /// ending exactly ON a bar line into the next bar. Measured live at 120 BPM 4/4, four quarter
    /// notes — the most ordinary sequence there is — produced expected 3 against Logic's observed 2
    /// and the write was reported as `timing_mismatch`; shortening the last note by 100 ms made the
    /// same sequence verify. Rounding up and adding one matches Logic in both cases and for
    /// multi-bar sequences.
    static func recordSequenceExpectedEndBar(
        for events: [SMFWriter.NoteEvent],
        requestedBar: Int,
        timeSignatureNumerator: Int = 4,
        ticksPerQuarter: Int = 480
    ) -> Int {
        let ticksPerBar = timeSignatureNumerator * ticksPerQuarter
        guard ticksPerBar > 0 else { return 2 }
        let maxEndTicks = events.map { $0.offsetTicks + $0.durationTicks }.max() ?? 0
        let absoluteEndTicks = maxEndTicks + max(0, requestedBar - 1) * ticksPerBar
        let barsSpanned = (absoluteEndTicks + ticksPerBar - 1) / ticksPerBar
        return max(2, barsSpanned + 1)
    }

    private static func recordSequenceRegionKey(_ region: RegionInfo) -> String {
        [
            region.name,
            String(region.trackIndex),
            String(region.startBar),
            String(region.endBar),
            region.kind,
        ].joined(separator: "|")
    }

    private static func preferredRecordSequenceRegion(from regions: [RegionInfo]) -> RegionInfo? {
        regions.max { lhs, rhs in
            if lhs.trackIndex != rhs.trackIndex { return lhs.trackIndex < rhs.trackIndex }
            if lhs.endBar != rhs.endBar { return lhs.endBar < rhs.endBar }
            if lhs.startBar != rhs.startBar { return lhs.startBar < rhs.startBar }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func recordSequenceRegionFields(
        _ region: RegionInfo,
        prefix: String = ""
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "\(prefix)region_name": region.name,
            "\(prefix)start_bar": region.startBar,
            "\(prefix)end_bar": region.endBar,
            "\(prefix)region_kind": region.kind,
        ]
        if !prefix.isEmpty {
            payload["\(prefix)track_index"] = region.trackIndex
        }
        if let rawHelp = region.rawHelp, !rawHelp.isEmpty {
            payload["\(prefix)raw_help"] = rawHelp
        }
        return payload
    }

    private static func parseNotesToSMFEvents(
        notes: String,
        tempo: Double
    ) -> Result<[SMFWriter.NoteEvent], RecordSequenceNoteValidationError> {
        switch NoteSequenceParser.parse(notes) {
        case .failure(let error):
            return .failure(RecordSequenceNoteValidationError(message: error.hint))
        case .success(let parsed):
            if let violation = NoteSequenceParser.smfTimingViolation(in: parsed) {
                return .failure(RecordSequenceNoteValidationError(message: violation))
            }
            return .success(parsed.map { note in
                let ticks = SMFWriter.msToTicks(
                    offsetMs: note.offsetMs,
                    durationMs: note.durationMs,
                    tempo: tempo
                )
                return SMFWriter.NoteEvent(
                    pitch: note.pitch,
                    offsetTicks: ticks.offsetTicks,
                    durationTicks: ticks.durationTicks,
                    velocity: note.velocity,
                    channel: note.channel
                )
            })
        }
    }

    private struct RecordSequenceNoteValidationError: Error {
        let message: String
    }

}
