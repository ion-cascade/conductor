import Foundation

struct QualificationDriveRequest: Sendable {
    let executableURL: URL
    let environment: [String: String]
    let expectedOperationCount: Int
    let operations: [OperationSpec]
    let expectedExecutableSHA256: String?

    init(
        executableURL: URL,
        environment: [String: String],
        expectedOperationCount: Int,
        operations: [OperationSpec] = [],
        expectedExecutableSHA256: String? = nil
    ) {
        self.executableURL = executableURL
        self.environment = environment
        self.expectedOperationCount = expectedOperationCount
        self.operations = operations
        self.expectedExecutableSHA256 = expectedExecutableSHA256
    }
}

struct QualificationWireFrame: Codable, Equatable, Sendable {
    enum Direction: String, Codable, Hashable, Sendable {
        case request
        case response
        case notification
    }

    let sequence: Int
    let direction: Direction
    let operationID: String
    let payload: String

    enum CodingKeys: String, CodingKey {
        case sequence
        case direction
        case operationID = "operation_id"
        case payload
    }
}

struct QualificationTransport: Sendable {
    let handshakeTimeout: TimeInterval
    let requestTimeout: TimeInterval
    let shutdownGrace: TimeInterval
    let mutationReplyTimeout: @Sendable (OperationSpec) -> TimeInterval
    let midiPortReadback: @Sendable () throws -> Data
    let libraryPanelReadback: @Sendable () throws -> Data
    let cleanupSleep: @Sendable (TimeInterval) -> Void
    let supportBundleRoot: @Sendable () -> URL
    let supportBundleQuiescer: @Sendable (
        QualificationSubprocessSession
    ) throws -> QualificationSubprocessSession.ShutdownOutcome
    let supportBundleRemover: @Sendable (URL, SecureFD.Identity) throws -> String

    init(
        handshakeTimeout: TimeInterval = 45,
        requestTimeout: TimeInterval = 10,
        shutdownGrace: TimeInterval = 1,
        mutationReplyTimeout: @escaping @Sendable (OperationSpec) -> TimeInterval =
            QualificationTransport.operationRequestTimeout(for:),
        midiPortReadback: @escaping @Sendable () throws -> Data = {
            try QualificationTransport.coreMIDIPortReadback()
        },
        libraryPanelReadback: @escaping @Sendable () throws -> Data = {
            try QualificationLibraryPanelReader.read()
        },
        cleanupSleep: @escaping @Sendable (TimeInterval) -> Void = {
            Thread.sleep(forTimeInterval: $0)
        },
        supportBundleRoot: @escaping @Sendable () -> URL = {
            SystemDispatcher.supportBundleRoot
        },
        supportBundleQuiescer: @escaping @Sendable (
            QualificationSubprocessSession
        ) throws -> QualificationSubprocessSession.ShutdownOutcome = {
            try $0.shutdown()
        },
        supportBundleRemover: @escaping @Sendable (URL, SecureFD.Identity) throws -> String = {
            try QualificationTransport.removeOwnedSupportBundle(at: $0, expectedIdentity: $1)
        }
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.requestTimeout = requestTimeout
        self.shutdownGrace = shutdownGrace
        self.mutationReplyTimeout = mutationReplyTimeout
        self.midiPortReadback = midiPortReadback
        self.libraryPanelReadback = libraryPanelReadback
        self.cleanupSleep = cleanupSleep
        self.supportBundleRoot = supportBundleRoot
        self.supportBundleQuiescer = supportBundleQuiescer
        self.supportBundleRemover = supportBundleRemover
    }

    /// Environment the same-artifact qualification drives the server with.
    ///
    /// #394: ADR-002 target_ref ships DEFAULT ON — the server reads an ABSENT
    /// `LOGIC_MCP_ADR002_TARGET_REF` as ON (`!= "0"`). Qualification therefore
    /// attests the SHIPPED DEFAULT by leaving the variable ABSENT (even if the
    /// base inherited a pin), exactly what a default deployment runs — rather
    /// than pinning the `=0` kill-switch, which diverged from the shipped
    /// default. The session-random target/trace IDs this surfaces are
    /// ID-normalized by `QualificationTranscriptNormalizer` before the transcript
    /// is emitted (cross-run ID stability). The `=0` kill-switch is the operator
    /// rollback config — it is NOT run as a secondary same-artifact qualification
    /// drive; it is exercised only by a FeatureFlags env-contract UNIT test (via
    /// `adr002KillSwitchEnvironment`, alongside the absent / `=0` / `=1` cases in
    /// `FeatureFlagEnvironmentTests`).
    ///
    /// ADR-003 strict params and ADR-005 tracing are pinned to their shipped
    /// default ("1" reads identically to the default-ON `!= "0"`), so
    /// qualification and production agree on those too.
    static func qualificationEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "LOGIC_MCP_ADR002_TARGET_REF")
        environment["LOGIC_MCP_ADR003_STRICT_PARAMS"] = "1"
        environment["LOGIC_MCP_ADR005_OPERATION_TRACE"] = "1"
        return environment
    }

    /// The `=0` kill-switch environment — the operator's documented ADR-002
    /// rollback. Consumed by a FeatureFlags env-contract UNIT test, NOT by a
    /// secondary same-artifact qualification drive, so the rollback config stays
    /// exercised now that the PRIMARY qualification attests the shipped default
    /// (absent = ON) instead of this config.
    static func adr002KillSwitchEnvironment(base: [String: String]) -> [String: String] {
        var environment = qualificationEnvironment(base: base)
        environment["LOGIC_MCP_ADR002_TARGET_REF"] = "0"
        return environment
    }

    static func qualificationLocaleIdentifier(_ identifier: String) -> String {
        switch Locale(identifier: identifier).language.languageCode?.identifier.lowercased() {
        case "en": QualificationLocale.enUS.rawValue
        case "ko": QualificationLocale.koKR.rawValue
        default: identifier.replacingOccurrences(of: "_", with: "-")
        }
    }

    func drive(_ request: QualificationDriveRequest) throws -> QualificationDriveResult {
        // #399 (CEO audit P0) — the fault-injection probe timeout only applies in
        // debug, where the seam exists. A release build has no
        // `QualificationFaultInjection`, so `faultActive` is a constant false and
        // the probe uses its normal request timeout.
        #if FAULT_TEST_SEAM
        let faultActive = QualificationFaultInjection(environment: request.environment) != nil
        #else
        let faultActive = false
        #endif
        let session = QualificationSubprocessSession(
            request: request,
            requestTimeout: requestTimeout,
            shutdownGrace: shutdownGrace
        )
        try session.start()

        do {
            let handshake = try initialize(session)
            // The UI locale comes from a MENU-BAR read (`AXLogicProElements+Menu.swift:25`): the
            // observed top-level titles must contain one language's full set. That read is
            // TRANSIENTLY EMPTY -- measured, three consecutive fresh processes reported `unknown`
            // and two reads seconds later reported `en-US`, with Logic untouched between them.
            //
            // Sampling it once meant a single unreadable read aborted the entire run, and the guard
            // downstream reported it as a locale MISMATCH for a locale that was correct. That
            // message cost eight wrong explanations before the mechanism was found.
            //
            // Retried ONLY while the value is unrecognised. A recognised locale -- en-US or ko-KR --
            // stops immediately even when it is the WRONG one, because that is a real mismatch and
            // must still fail closed. Retrying an unrecognised value cannot convert a genuine
            // ko-KR run into an en-US pass: ko-KR is recognised and exits the loop on the first read.
            var healthBefore = try health(session, id: 2, phase: "health_before")
            var localeRetryID = 900
            while QualificationLocale(rawValue: healthBefore.value.logicProUILocale) == nil,
                  localeRetryID < 906 {
                Thread.sleep(forTimeInterval: 1.5)
                healthBefore = try health(session, id: localeRetryID, phase: "health_before_retry")
                localeRetryID += 1
            }
            let catalogBefore = try catalog(session, id: 3, phase: "catalog_before")
            let baselineTraceList = try traces(session, id: 4)
            let baselineTraceIDs = Set(baselineTraceList.traces.map(\.traceID))
            let traceSeedBody = try traceSeed(session, id: 5)
            let traceList = try traces(session, id: 6)
            let seededTraces = traceList.traces.filter {
                !baselineTraceIDs.contains($0.traceID)
                    && $0.operationID == OperationID.systemSagaExecute.rawValue
                    && $0.phaseCount > 0
                    && TraceID.isValid($0.traceID)
            }
            guard seededTraces.count == 1, let traceSummary = seededTraces.first else {
                throw QualificationTransportError.protocolViolation(
                    "trace_roundtrip: expected one new traced operation with events"
                )
            }
            let traceDetail = try trace(session, id: 7, traceID: traceSummary.traceID)
            guard traceDetail.traceID == traceSummary.traceID,
                  traceDetail.operationID == traceSummary.operationID,
                  traceDetail.phases.first == TracePhase.requestReceived.rawValue,
                  traceDetail.phases.last == TracePhase.resultEmitted.rawValue else {
                throw QualificationTransportError.protocolViolation(
                    "trace_roundtrip: trace identity or events mismatch"
                )
            }
            let negativeBody = try negative(session, id: 8)
            // #373 Phase A: seed a saga JOURNAL record so `system.saga_status` has something to
            // report. Exactly the shape `traceSeed` above already establishes -- the transport
            // arranges the state a read-only probe needs, then probes it. Nothing new is being
            // decided here; `probeParams` has handed `systemGetTrace` a seeded `trace_id` since
            // this file was written.
            //
            // The seed is a REFUSED saga (`feature_disabled`), so no step ever executes and nothing
            // is mutated -- but the journal still records the outcome, which is what
            // `saga_status` reads. A zero-write seed.
            _ = try? sagaSeed(session, id: 9)
            var nextID = 10
            // The trace id the next `system.get_trace` probe should ask for. It starts as the one
            // the round-trip above proved, and is replaced whenever a reader re-seeds.
            var seededTraceID = traceSummary.traceID
            // #373 Phase B: the verified write-and-restore cycles this run produced. Empty until a
            // recipe exists for an operation, which is the honest shape — the artifact has always
            // been emitted and has always been empty.
            var mutationRestoreRecords: [QualificationMutationRestoreRecord] = []
            var operationResults: [String: QualificationOperationResult] = [:]
            var preparedReadParams: [OperationID: [String: Any]] = [:]
            var readProbePreparationFailures: [OperationID: String] = [:]
            let requestedIDs = Set(request.operations.map(\.id))
            let requestedMixerReads = Self.mixerReadProbeOperationIDs.intersection(requestedIDs)
            let requestedPluginReads = Self.pluginReadProbeOperationIDs.intersection(requestedIDs)
            let readPreparation = Self.prepareRequestedReadProbeParams(
                requestedMixerReads: requestedMixerReads,
                requestedPluginReads: requestedPluginReads,
                refresh: { timeout in
                    let refreshID = nextID
                    nextID += 1
                    return try invoke(
                        session, id: refreshID, tool: "logic_system", command: "refresh_cache",
                        params: [:], phase: "read_probe_refresh", timeout: timeout)
                },
                pluginPreparation: {
                    try Self.preparePluginReadProbeParams(
                        tracksRead: {
                            let tracksReadID = nextID
                            nextID += 1
                            return try resourceReadback(
                                session, id: tracksReadID, uri: "logic://tracks",
                                phase: "plugin_read_probe_tracks")
                        },
                        inventoryRead: { track in
                            let inventoryID = nextID
                            nextID += 1
                            return try pluginInventory(
                                session, id: inventoryID, track: track,
                                phase: "plugin_read_probe_inventory.\(track)"
                            )
                        }
                    )
                }
            )
            preparedReadParams.merge(readPreparation.params) { current, _ in current }
            readProbePreparationFailures.merge(readPreparation.failures) { current, _ in current }
            for spec in request.operations {
                var response: (text: String, isError: Bool)?
                var responseRequestID: String?
                var responseFailure: String? = readProbePreparationFailures[spec.id]
                var liveFixturePrecondition: QualificationLiveFixturePrecondition?
                if responseFailure == nil,
                   requestedPluginReads.contains(spec.id),
                   preparedReadParams[spec.id] == nil {
                    liveFixturePrecondition = switch spec.id {
                    case .pluginsGetHostParameterManifest: .pluginHostManifestTarget
                    case .pluginsGetParamVerified: .pluginReadableParameter
                    case .pluginsGetChannelEQStateVerified: .pluginChannelEQ
                    case .pluginsPlanParameterChanges: .pluginPlannableParameter
                    default: nil
                    }
                }
                let exportStatusProbe: QualificationExportStatusProbe?
                if spec.id == .projectExportStatus {
                    do {
                        let probe = try QualificationExportStatusProbe()
                        exportStatusProbe = probe
                        preparedReadParams[spec.id] = probe.params
                    } catch {
                        exportStatusProbe = nil
                        responseFailure = Self.observedFailureReason(from: error, during: "export status fixture")
                    }
                } else {
                    exportStatusProbe = nil
                }
                var phaseBRecord: QualificationMutationRestoreRecord?
                var phaseBRefusal: String?
                // `tracks.rename` reuses the negative probe's response below and never reaches the
                // normal dispatch, so its recipe runs HERE rather than inside that branch. Putting
                // it with the others cost a run to find out: the recipe was written, compiled, and
                // silently never fired.
                if spec.id == .tracksRename {
                    do {
                        let cycle = try trackStringRestoreCycle(
                            session, startingAt: nextID, spec: spec, readbackField: "name")
                        mutationRestoreRecords.append(cycle.record)
                        phaseBRecord = cycle.record
                        nextID = cycle.nextID
                    } catch {
                        phaseBRefusal = Self.observedFailureReason(
                            from: error, during: "phase_b recipe")
                        nextID += 20
                    }
                }
                do {
                    if spec.id == .systemSagaExecute {
                        responseRequestID = "5"
                        response = (traceSeedBody.text, traceSeedBody.toolIsError)
                    } else if spec.id == .tracksRename {
                        responseRequestID = "8"
                        response = (negativeBody.text, negativeBody.toolIsError)
                    } else {
                        // #373 Phase A: RE-SEED the trace store immediately before the two
                        // operations that read it.
                        //
                        // The sweep does not run in registry-declaration order — measured
                        // 2026-09-14, it probed `system.clear_traces` (readback-145) BEFORE
                        // `system.get_trace` (149) and `system.list_recent_traces` (155), so the
                        // clear wiped the store and both readers then read an empty one:
                        // `{"traces":[]}` and `element_not_found: No operation trace exists for the
                        // requested trace_id`. Both came back `not_qualified`, and the cause was
                        // the recipe's ordering rather than anything about the operations.
                        //
                        // Fixing the ORDER would work until the order changes again. Seeding here
                        // makes each reader arrange the state it needs, which is the pattern the
                        // trace seed above already establishes and is indifferent to sweep order.
                        // The seed is a REFUSED `saga_execute` — a typed zero-write refusal — so it
                        // records a trace without mutating anything.
                        // `tracks.list_library` is deliberately not seeded with a library scan.
                        // Its qualification readback comes from the separate read-only host AX
                        // panel census, not from the product cache or a scan that changes state.
                        // #373 Phase B: operations with a write-and-restore recipe run it here.
                        // A refusal inside the cycle is NOT swallowed into a pass — the record is
                        // simply absent and the operation falls through to the existing zero-write
                        // deferral, which is what "no evidence" should look like.
                        if spec.id == .transportSetTempo {
                            do {
                                let cycle = try tempoRestoreCycle(
                                    session, startingAt: nextID, spec: spec)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 14
                            }
                        }
                        // Two operations move the playhead by bar number and read it back out of
                        // the same transport resource: `navigate.goto_bar` and
                        // `transport.goto_position`. `goto_position` also accepts a `position`
                        // string, and the cycle deliberately drives the `bar` form — that is the
                        // shape both share, so one machine covers both without the recipe having to
                        // know which dispatcher it landed in.
                        if Self.playheadRestoreOperations.contains(spec.id) {
                            do {
                                let cycle = try playheadRestoreCycle(
                                    session, startingAt: nextID, spec: spec)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 14
                            }
                        }
                        if spec.id == .systemExportSupportBundle {
                            do {
                                let cycle = try supportBundleArtifactRestoreCycle(
                                    session, startingAt: nextID, spec: spec)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch let error as QualificationTransportError
                                where error.requiresDriveAbort {
                                throw error
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                // The recipe sends one MCP request. Reserve a few IDs on refusal
                                // so a future extra deciding read cannot collide with the sweep.
                                nextID += 4
                            }
                        }
                        if let direction = Self.playheadStepDirections[spec.id] {
                            do {
                                let cycle = try playheadStepRestoreCycle(
                                    session, startingAt: nextID, spec: spec, direction: direction)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(from: error, during: "phase_b recipe")
                                nextID += 24
                            }
                        }
                        if let field = Self.parameterlessToggleField[spec.id] {
                            do {
                                let cycle = try parameterlessToggleRestoreCycle(
                                    session, startingAt: nextID, spec: spec, readbackField: field)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 12
                            }
                        }
                        if Self.phaseCTrackCyclesEnabled, spec.id == .tracksDelete {
                            do {
                                let cycle = try trackStagedDeleteCycle(
                                    session, startingAt: nextID, spec: spec)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_c recipe")
                                nextID += 60
                            }
                        }
                        if Self.phaseCTrackCyclesEnabled,
                           Self.trackCreateRestoreOperations.contains(spec.id) {
                            let cleanupWitness = PhaseCCleanupWitness()
                            do {
                                let cycle = try trackCreateRestoreCycle(
                                    session, startingAt: nextID, spec: spec, cleanup: cleanupWitness)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_c recipe")
                                    + "; cleanup: " + cleanupWitness.summary
                                nextID += 40
                            }
                        }
                        if let direction = Self.historyRestoreDirection[spec.id] {
                            do {
                                let cycle = try historyRestoreCycle(
                                    session, startingAt: nextID, spec: spec, direction: direction)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 40
                            }
                        }
                        if spec.id == .navigateGotoMarker {
                            do {
                                let cycle = try markerNavigationRestoreCycle(
                                    session, startingAt: nextID, spec: spec)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 60
                            }
                        }
                        if let mode = Self.markerStagedRestoreMode[spec.id] {
                            do {
                                let cycle = try markerStagedRestoreCycle(
                                    session, startingAt: nextID, spec: spec, mode: mode)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 60
                            }
                        }
                        if spec.id == .navigateCreateMarker {
                            do {
                                let cycle = try markerCreateRestoreCycle(
                                    session, startingAt: nextID, spec: spec)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 40
                            }
                        }
                        if let expected = Self.transportExpectedPlaying[spec.id] {
                            do {
                                let cycle = try transportRestoreCycle(
                                    session, startingAt: nextID, spec: spec,
                                    expectedPlaying: expected)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 32
                            }
                        }
                        if spec.id == .tracksSelect {
                            do {
                                let cycle = try selectionRestoreCycle(
                                    session, startingAt: nextID, spec: spec)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 14
                            }
                        }
                        if let field = Self.valueRestoreReadbackField[spec.id] {
                            do {
                                let cycle = try valueRestoreCycle(
                                    session, startingAt: nextID, spec: spec, readbackField: field)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 12
                            }
                        }
                        if let field = Self.booleanToggleReadbackField[spec.id] {
                            do {
                                let cycle = try booleanToggleRestoreCycle(
                                    session, startingAt: nextID, spec: spec, readbackField: field)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                // A recipe that ran and REFUSED is not the same fact as no recipe,
                                // and the old `try?` made them identical — both arrived as the
                                // generic "live mutation requires an operation-specific recipe".
                                // Measured 2026-09-14: `tracks.arm` answers State B with
                                // `verified:false` and `logic://tracks` shows `isArmed` unmoved, so
                                // the cycle refused for a reason worth reading. Carrying it turns a
                                // silent skip into a diagnosis.
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 12
                            }
                        }
                        if spec.id == .systemGetTrace || spec.id == .systemListRecentTraces {
                            let seedID = nextID
                            nextID += 1
                            _ = try? traceSeed(session, id: seedID)
                            // Read the id back rather than take it from the seed's own envelope.
                            // The refusal `saga_execute` emits carries no `trace_id`, so trusting
                            // its body left `seededTraceID` holding the pre-sweep value that
                            // `clear_traces` had already wiped — `get_trace` then asked for a trace
                            // that no longer existed and was refused, which is the same failure
                            // wearing a different cause. The listing is the authority on what the
                            // store currently holds.
                            let listID = nextID
                            nextID += 1
                            if let listed = try? traces(session, id: listID),
                               let newest = listed.traces.first {
                                seededTraceID = newest.traceID
                            }
                        }
                        var seededSessionSnapshotID: String?
                        if spec.id == .projectPlanSessionRepair {
                            let seedID = nextID
                            // Reserve the optional fresh-read retry's ID even when the first
                            // seed succeeds. No retry may collide with the planner probe.
                            nextID += 2
                            // A failed seed sends no handle, so the planner's refusal is recorded
                            // as the failure it is rather than skipped.
                            seededSessionSnapshotID = try? sessionInspectionSeed(
                                session, startingAt: seedID, purpose: .planner)
                        }
                        if responseFailure == nil, requestedMixerReads.contains(spec.id) {
                            let mixerInspectionID = nextID
                            // This seed can navigate to establish physical track/strip association
                            // custody, so it is deliberately one-shot. A second request after any
                            // false refusal could repeat UI effects that the refusal failed to report.
                            nextID += 1
                            do {
                                let inspection = try sessionInspectionSeedPayload(
                                    session, startingAt: mixerInspectionID, purpose: .mixerRead)
                                guard let admissible = Self.validatedMixerReadProbeParams(
                                    from: inspection.responseData
                                ) else {
                                    throw QualificationTransportError.protocolViolation(
                                        "mixer_read_probe_inspection: response was not a current request-owned read-only strip census"
                                    )
                                }
                                let current = admissible.filter {
                                    requestedMixerReads.contains($0.key)
                                }
                                for requestedID in requestedMixerReads {
                                    preparedReadParams.removeValue(forKey: requestedID)
                                }
                                preparedReadParams.merge(current) { _, fresh in fresh }
                                if preparedReadParams[spec.id] == nil {
                                    liveFixturePrecondition = switch spec.id {
                                    case .mixerGetOutputVerified: .mixerOutputTarget
                                    case .mixerGetInputBusVerified: .mixerInputBusTarget
                                    case .mixerGetSendDestinationVerified, .mixerGetSendBypassVerified:
                                        .mixerOccupiedSend
                                    default: nil
                                    }
                                }
                            } catch {
                                preparedReadParams.removeValue(forKey: spec.id)
                                responseFailure = Self.observedFailureReason(
                                    from: error, during: "fresh mixer read-probe inspection")
                            }
                        }
                        if spec.id == .tracksGetPanAutomation || spec.id == .tracksGetVolumeAutomation {
                            let trackReadID = nextID
                            nextID += 1
                            let tracks = try resourceReadback(session, id: trackReadID,
                                uri: "logic://tracks", phase: "automation_read_probe_track")
                            if let reference = Self.selectedAutomationTarget(from: tracks, deadline: spec.deadline) {
                                preparedReadParams[spec.id] = ["target_ref": reference]
                            }
                        }
                        let responseID = nextID
                        nextID += 1
                        responseRequestID = String(responseID)
                        let probeTimeout: TimeInterval? = faultActive && spec.id == .transportPlay
                            ? spec.deadline.seconds + 5
                            : nil
                        response = try operation(
                            session,
                            id: responseID,
                            spec: spec,
                            traceID: seededTraceID,
                            sessionSnapshotID: seededSessionSnapshotID,
                            preparedReadParams: preparedReadParams,
                            timeout: probeTimeout
                        )
                    }
                } catch let error as QualificationTransportError
                    where error.requiresDriveAbort {
                    throw error
                } catch {
                    responseFailure = responseFailure ?? Self.observedFailureReason(
                        from: error,
                        during: "operation request"
                    )
                }
                var readbackSource = Self.readbackSource(for: spec)
                var readbackRequestID: String?
                var readbackData: Data?
                var readbackFailure: String?
                do {
                    if let exportStatusProbe {
                        readbackSource = QualificationExportStatusProbe.source
                        readbackRequestID = "operation-readback-\(nextID)"
                        nextID += 1
                        readbackData = try exportStatusProbe.readback()
                    } else if SemanticOracleTable.conductorReceiptOnlyReadIDs.contains(spec.id) {
                        readbackSource = QualificationSemanticReadbackValidator.responseOnlySource
                        readbackRequestID = "operation-readback-\(nextID)"
                        nextID += 1
                        readbackData = QualificationSemanticReadbackValidator.responseOnlyRecord
                    } else if spec.id == .systemExportSupportBundle, let phaseBRecord {
                        // The recipe already read the exact verifier-owned directory through
                        // no-follow descriptors and verified every published digest. Re-reading
                        // `logic://system/health` says nothing about that artifact and, because it
                        // is not an AX state resource, cannot satisfy this operation's freshness
                        // contract. Bind the operation result to the independent host observation
                        // that actually decided the cycle instead.
                        readbackSource = QualificationReadbackFreshness
                            .ownedSupportBundleReadbackSource
                        readbackRequestID = "operation-readback-\(nextID)"
                        nextID += 1
                        readbackData = Data(phaseBRecord.readback.utf8)
                    } else if spec.id == .midiListPorts {
                        // The resource endpoint dispatches the same server handler as the tool,
                        // so equality there is circular. Enumerate CoreMIDI from this separate
                        // qualification process while the candidate is alive instead.
                        readbackRequestID = "operation-readback-\(nextID)"
                        nextID += 1
                        readbackData = try midiPortReadback()
                    } else if spec.id == .tracksListLibrary {
                        // The cache resource does not independently establish the visible panel.
                        // Read the exact Library browser from this qualification process instead.
                        readbackRequestID = "operation-readback-\(nextID)"
                        nextID += 1
                        readbackData = try libraryPanelReadback()
                    } else {
                        readbackData = try Self.independentResourceReadback(
                            source: readbackSource,
                            nextRequestID: &nextID,
                            refresh: { refreshID, timeout in
                                return try invoke(
                                    session,
                                    id: refreshID,
                                    tool: "logic_system",
                                    command: "refresh_cache",
                                    params: [:],
                                    phase: "independent_readback_refresh.\(spec.id.rawValue)",
                                    timeout: timeout
                                )
                            },
                            read: { readID in
                                let phase = "operation-readback-\(readID)"
                                readbackRequestID = phase
                                return try resourceReadback(
                                    session,
                                    id: readID,
                                    uri: readbackSource,
                                    phase: phase
                                )
                            }
                        )
                    }
                } catch {
                    readbackFailure = Self.observedFailureReason(
                        from: error,
                        during: "independent readback"
                    )
                }
                let typed = response.flatMap {
                    try? Self.decodeInner(
                        $0.text,
                        phase: "operation_probe.\(spec.id.rawValue)"
                    ) as OperationProbeResult
                }
                operationResults[spec.id.rawValue] = QualificationOperationResult(
                    operationID: spec.id.rawValue,
                    tool: spec.tool.rawValue,
                    command: spec.command,
                    mutability: spec.mutability,
                    requestID: responseRequestID,
                    responseData: response.map { Data($0.text.utf8) },
                    isError: response?.isError,
                    state: typed?.state,
                    error: typed?.error,
                    hint: typed?.hint,
                    reason: typed?.reason,
                    writeAttempted: typed?.writeAttempted,
                    rowSelectionWriteAttempted: typed?.rowSelectionWriteAttempted,
                    rowSelectionRestored: typed?.rowSelectionRestored,
                    readbackSource: readbackSource,
                    readbackRequestID: readbackRequestID,
                    readbackData: readbackData,
                    verification: spec.verification,
                    deadline: spec.deadline,
                    failureReason: responseFailure ?? readbackFailure,
                    liveFixturePrecondition: liveFixturePrecondition,
                    mutationRestore: phaseBRecord,
                    mutationRestoreRefusal: phaseBRefusal
                )
            }
            let healthAfter = try health(session, id: nextID, phase: "health_after")
            nextID += 1
            let catalogAfter = try catalog(session, id: nextID, phase: "catalog_after")
            let negative = QualificationNegativeResult(
                toolIsError: negativeBody.toolIsError,
                state: negativeBody.body.state,
                error: negativeBody.body.error,
                writeAttempted: negativeBody.body.writeAttempted,
                healthBefore: healthBefore.stableData,
                healthAfter: healthAfter.stableData,
                catalogBefore: catalogBefore.stableData,
                catalogAfter: catalogAfter.stableData
            )
            let outcome = try session.shutdown()
            guard !outcome.forced else {
                throw QualificationTransportError.shutdownTimeout
            }
            guard outcome.status == 0 else {
                throw QualificationTransportError.nonZeroExit(
                    status: outcome.status,
                    stderr: session.stderrTail
                )
            }
            return QualificationDriveResult(
                handshake: handshake,
                health: healthBefore.value,
                catalog: catalogBefore.value,
                expectedOperationCount: request.expectedOperationCount,
                traceList: traceList,
                traceDetail: traceDetail,
                negative: negative,
                observedLocale: healthBefore.value.logicProUILocale,
                operationResults: operationResults,
                wireFrames: session.transcriptFrames,
                mutationRestoreRecords: mutationRestoreRecords,
                failureReason: nil
            )
        } catch let error as QualificationTransportError where error.requiresDriveAbort {
            // The support-bundle path has already decided whether cleanup was safe. Preserve its
            // quiescence/residual diagnosis even when the stopped candidate exited nonzero.
            _ = try? session.shutdown()
            throw error
        } catch {
            let outcome: QualificationSubprocessSession.ShutdownOutcome
            do {
                outcome = try session.shutdown()
            } catch {
                throw error
            }
            if !outcome.forced, outcome.status != 0 {
                throw QualificationTransportError.nonZeroExit(
                    status: outcome.status,
                    stderr: session.stderrTail
                )
            }
            throw error
        }
    }
}
