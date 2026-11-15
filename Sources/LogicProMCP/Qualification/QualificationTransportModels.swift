import Foundation

struct QualificationHandshake: Equatable, Sendable {
    let protocolVersion: String
    let serverName: String
    let serverVersion: String

    var isValid: Bool {
        !protocolVersion.isEmpty && !serverName.isEmpty && !serverVersion.isEmpty
    }
}

struct QualificationHealth: Equatable, Sendable {
    let logicProRunning: Bool
    let logicProVersion: String
    let logicProBundleID: String
    let logicProVariant: String
    let logicProUILocale: String
    let processMetadataResolved: Bool
    let variants: [QualificationVariantAvailability]

    var isValid: Bool {
        !logicProVersion.isEmpty
            && !logicProVariant.isEmpty
            && QualificationLocale(rawValue: logicProUILocale) != nil
            && availabilityObservation != nil
    }

    var identifiesLiveLogic: Bool {
        logicProRunning && processMetadataResolved && logicProVersion != "unknown"
    }

    var availabilityObservation: QualificationAvailabilityObservation? {
        guard let activeVariant = Self.qualificationVariant(logicProVariant),
              let uiLocale = QualificationLocale(rawValue: logicProUILocale),
              variants.contains(where: {
                  $0.variant == activeVariant
                      && $0.bundleID == logicProBundleID
                      && $0.running
              }) else {
            return nil
        }
        return QualificationAvailabilityObservation(
            activeBundleID: logicProBundleID,
            activeVariant: activeVariant,
            logicUILocale: uiLocale,
            variants: variants
        )
    }

    private static func qualificationVariant(_ value: String) -> LogicVariant? {
        switch value {
        case LogicProVariant.desktop.rawValue: .desktop
        case LogicProVariant.creatorStudio.rawValue: .creatorStudio
        default: nil
        }
    }
}

struct QualificationTraceEntry: Equatable, Sendable {
    let traceID: String
    let operationID: String
    let phaseCount: Int
    let readbackState: String?
}

struct QualificationTraceList: Equatable, Sendable {
    let traces: [QualificationTraceEntry]
}

struct QualificationTraceDetail: Equatable, Sendable {
    let traceID: String
    let operationID: String
    let phases: [String]
}

/// A live read was prepared from admissible, request-owned evidence, but that evidence did not
/// contain the physical target the operation requires. This marker is internal transport state,
/// not something an operation response can claim for itself.
enum QualificationLiveFixturePrecondition: Equatable, Sendable {
    case mixerOutputTarget
    case mixerInputBusTarget
    case mixerOccupiedSend
    case pluginHostManifestTarget
    case pluginReadableParameter
    case pluginChannelEQ
    case pluginPlannableParameter

    var reason: String {
        switch self {
        case .mixerOutputTarget:
            "requires a current physical Mixer target with a typed output observation"
        case .mixerInputBusTarget:
            "requires a current physical Mixer target with a typed bus-input observation"
        case .mixerOccupiedSend:
            "requires an occupied Send in the fresh read-only strip census"
        case .pluginHostManifestTarget:
            "requires an occupied catalog-supported plug-in insert in the current Logic project"
        case .pluginReadableParameter:
            "requires an occupied plug-in insert with a catalog-backed readable parameter"
        case .pluginChannelEQ:
            "requires an occupied Channel EQ insert in the current Logic project"
        case .pluginPlannableParameter:
            "requires an occupied plug-in insert with a catalog-backed plannable parameter"
        }
    }
}

struct QualificationOperationResult: Equatable, Sendable {
    let operationID: String
    let tool: String
    let command: String
    let mutability: Mutability
    let requestID: String?
    let responseData: Data?
    let isError: Bool?
    let state: String?
    let error: String?
    /// The refusal's actionable half. Captured because the deferral used to guess a cause the
    /// operation had already named -- see `operationUnavailable` below.
    let hint: String?
    let reason: String?
    let writeAttempted: Bool?
    let rowSelectionWriteAttempted: Bool?
    let rowSelectionRestored: Bool?
    let readbackSource: String?
    let readbackRequestID: String?
    let readbackData: Data?
    /// The operation contract is carried with the captured readback so that an independent read
    /// can apply a live-freshness requirement only when this operation actually promises one.
    let verification: VerificationPolicy
    let deadline: DeadlineClass
    let failureReason: String?
    let liveFixturePrecondition: QualificationLiveFixturePrecondition?
    /// ADR-001-c / #373 Phase B evidence: the verified write-and-restore cycle for a MUTATING
    /// operation, or nil when no recipe ran. Each recipe refuses rather than returning a record
    /// for a cycle whose own checks did not verify; `verifiedCycleShape` rechecks its recorded proof.
    let mutationRestore: QualificationMutationRestoreRecord?
    /// Why a Phase-B recipe that RAN produced no record. Nil when no recipe exists for the
    /// operation — the two are different facts and the deferral below says which.
    let mutationRestoreRefusal: String?

    init(
        operationID: String,
        tool: String,
        command: String,
        mutability: Mutability,
        requestID: String?,
        responseData: Data?,
        isError: Bool?,
        state: String?,
        error: String?,
        hint: String?,
        reason: String? = nil,
        writeAttempted: Bool?,
        rowSelectionWriteAttempted: Bool? = nil,
        rowSelectionRestored: Bool? = nil,
        readbackSource: String?,
        readbackRequestID: String?,
        readbackData: Data?,
        verification: VerificationPolicy = .none,
        deadline: DeadlineClass = .short,
        failureReason: String?,
        liveFixturePrecondition: QualificationLiveFixturePrecondition? = nil,
        mutationRestore: QualificationMutationRestoreRecord? = nil,
        mutationRestoreRefusal: String? = nil
    ) {
        self.operationID = operationID
        self.tool = tool
        self.command = command
        self.mutability = mutability
        self.requestID = requestID
        self.responseData = responseData
        self.isError = isError
        self.state = state
        self.error = error
        self.hint = hint
        self.reason = reason
        self.writeAttempted = writeAttempted
        self.rowSelectionWriteAttempted = rowSelectionWriteAttempted
        self.rowSelectionRestored = rowSelectionRestored
        self.readbackSource = readbackSource
        self.readbackRequestID = readbackRequestID
        self.readbackData = readbackData
        self.verification = verification
        self.deadline = deadline
        self.failureReason = failureReason
        self.liveFixturePrecondition = liveFixturePrecondition
        self.mutationRestore = mutationRestore
        self.mutationRestoreRefusal = mutationRestoreRefusal
    }

    var responseArtifactData: Data? {
        guard let requestID,
              let responseData,
              let isError,
              let payload = String(data: responseData, encoding: .utf8) else {
            return nil
        }
        return Self.encoded(QualificationOperationResponseArtifact(
            operationID: operationID,
            tool: tool,
            command: command,
            requestID: requestID,
            isError: isError,
            payload: payload
        ))
    }

    var responseSHA256: String? {
        responseArtifactData.map(SupportBundleBuilder.sha256)
    }

    var readbackArtifactData: Data? {
        guard let readbackSource,
              let readbackRequestID,
              let readbackData,
              let payload = String(data: readbackData, encoding: .utf8) else {
            return nil
        }
        return Self.encoded(QualificationReadbackArtifact(
            source: readbackSource,
            requestID: readbackRequestID,
            payload: payload
        ))
    }

    var readback: QualificationReadbackEvidence? {
        guard let readbackSource, let readbackRequestID, let readbackArtifactData else { return nil }
        return QualificationReadbackEvidence(
            source: readbackSource,
            requestID: readbackRequestID,
            // A mutating deferral (e.g. a consent-gated zero-write refusal, #413)
            // must NOT claim its nested readback verified — only a passed
            // qualification does.
            verified: status == .passed,
            sha256: SupportBundleBuilder.sha256(readbackArtifactData)
        )
    }

    /// The case's statement of this operation's write cycle (#984), or nil when no record exists.
    ///
    /// `verified` is true when the restore was READ BACK and MATCHED the original under the
    /// recipe's comparison rule. Not `status == .passed`,
    /// which is what `readback` uses: a cycle whose restore verified is still that when the
    /// operation's own readback was inadmissible, and the credit rule checks the status itself.
    var restore: QualificationRestoreEvidence? {
        guard let record = mutationRestore,
              let digest = try? QualificationRunner.recordDigest(record) else { return nil }
        return QualificationRestoreEvidence(
            recordSHA256: digest,
            verified: record.verifiedCycleShape
        )
    }

    var status: QualificationStatus {
        if failureReason != nil || responseData == nil || readbackArtifactData == nil {
            return .failed
        }
        switch mutability {
        case .readOnly:
            guard readbackFreshness.isAdmissible else { return .notQualified }
            guard isError == false else { return .notQualified }
            switch semanticReadbackValidated {
            case .some(true): return .passed
            case .some(false): return .notQualified
            case .none: return .protocolSmoke
            }
        case .mutating:
            // ADR-001-c / #373 Phase B. A verified write-and-restore cycle is the ONLY thing that
            // promotes a mutating operation here, and `mutationRestore` is non-nil only when every
            // step of that cycle held: the mutation moved the independently observed state, and the
            // restore returned it exactly, both read back from `logic://tracks` rather than from
            // the write's own answer. The record type has no failure case, so a cycle that did not
            // verify produces nothing for this branch to see.
            // No `record.operationID == operationID` check here, deliberately. It was written and
            // then removed: a mutation that dropped it left every test green, because a foreign
            // record cannot be attached in the first place — `phaseBRecord` is declared inside one
            // sweep iteration and written only by that iteration's own recipe. A guard nothing can
            // trip is not a guard, and defending it in a comment is worse than the structure that
            // actually holds. If records ever arrive from somewhere other than the sweep, this is
            // the line to add back WITH a seam that can exercise it.
            //
            // THE OPERATION'S OWN PROBE IS CHECKED FIRST, and getting this order wrong was the
            // defect. A Phase-B record used to promote the operation before anything looked at the
            // probe, so an injected fault — a timeout, a partial state — was LAUNDERED by a recipe
            // that happened to succeed beside it: the recipe's own play/stop calls are unaffected
            // by a fault armed for the no-write probe, so the record existed and the operation read
            // `.passed` while its own answer was State C. Four fault-injection tests caught it.
            //
            // A recipe can supply evidence the probe never had. It cannot vouch for the probe.
            guard expectedZeroWriteRefusalObserved else { return .failed }
            // A successful write that carries an inadmissible live readback has not been
            // confirmed. Keep the existing no-write deferrals untouched.
            if isError == false, !readbackFreshness.isAdmissible { return .notQualified }
            // Freshness is required of the recipe's readback too: a cycle read through a stale or
            // partial resource is the same unverified claim with more steps.
            //
            // And freshness is not enough on its own. `readbackFreshness` is computed from the
            // operation's LATER readback and returns `.admissible` unconditionally for any policy
            // that is not `.readbackRequired` — `transport.toggle_cycle` and `transport.set_tempo`
            // among them. So the record's own readings are inspected here for whether a reading
            // happened at all, which is a question freshness never asks. The recorded restore is
            // compared with the pre-state under the recipe's observable as well.
            if let record = mutationRestore, readbackFreshness.isAdmissible {
                return record.verifiedCycleShape ? .passed : .notQualified
            }
            return .notQualified
        }
    }

    /// Scope is an operation property, not a verdict from this particular run.
    ///
    /// The live probe deliberately sends `__adr001b_no_write_probe` for every
    /// mutating operation. It can observe the fail-closed refusal, but it
    /// cannot establish that the operation's success path works.
    var liveGateScope: QualificationLiveGateScope {
        switch mutability {
        case .readOnly: .inScope
        case .mutating: .outOfScope
        }
    }

    /// The observed zero-write refusal expected from a mutating probe.
    ///
    /// Kept available to the live-gate report so a missing refusal is reported
    /// as the reason for failure rather than as an unexplained operation ID.
    var expectedZeroWriteRefusalObserved: Bool {
        let expectedError: Bool
        if let id = OperationID(rawValue: operationID),
           QualificationTransport.consentFirstMutationProbeOperationIDs.contains(id) {
            expectedError = error == "consent_required" || error == "invalid_params"
        } else {
            expectedError = error == "invalid_params"
        }
        return isError == true
            && state == "C"
            && expectedError
            && writeAttempted == false
    }

    var verified: Bool { status == .passed }

    /// An input the harness did not provide, but which the operation says it
    /// needs. This is deliberately an exact operation-and-refusal match: a
    /// different refusal from one of these operations is a product failure,
    /// not a generic exemption.
    var liveGateUnmetOperationPrecondition: String? {
        guard isError == true else { return nil }
        switch OperationID(rawValue: operationID) {
        case .audioAnalyzeSpectrum:
            guard error == "invalid_params" else { return nil }
            guard hint == "analyze_spectrum requires non-empty string 'path'" else { return nil }
            return "requires non-empty string 'path'"
        case .audioRecommendEQ:
            guard error == "invalid_params" else { return nil }
            guard hint == "recommend_eq requires non-empty string 'path'" else { return nil }
            return "requires non-empty string 'path'"
        case .systemClearTraces:
            guard error == "invalid_params" else { return nil }
            guard hint == "clear_traces requires 'confirmed:true' because it destroys in-process diagnostic evidence"
            else { return nil }
            return "requires 'confirmed:true'"
        case .midiReadSelectedRegionEvents:
            guard state == "C",
                  error == "selected_region_event_read_unavailable",
                  reason == "selection_scope_incomplete",
                  writeAttempted == false,
                  rowSelectionWriteAttempted == false,
                  rowSelectionRestored == false else { return nil }
            return "requires a complete selected Arrange-region scope"
        default:
            return nil
        }
    }

    /// An environmental prerequisite, distinct from an operation input. As
    /// above, the exact refusal is part of the classification so a new error
    /// from the same operation stays visible as a failure.
    var liveGateUnmetEnvironmentalPrecondition: String? {
        guard isError == true else { return nil }
        // #966: the planner reads a retained inspection, and an unsaved project's inspections are
        // never retained. The dispatcher names that cause apart from unknown or expired handles.
        if OperationID(rawValue: operationID) == .projectPlanSessionRepair {
            guard error == "stale_snapshot",
                  hint == ProjectDispatcher.planSessionRepairUnboundProjectHint else { return nil }
            return "requires a project saved to a file, so its session inspection is retained"
        }
        if OperationID(rawValue: operationID) == .tracksListLibrary {
            guard error == HonestContract.FailureError.libraryPanelUnavailable.rawValue,
                  hint == AccessibilityChannel.libraryListPanelUnavailableHint else { return nil }
            return "requires an exact open Library panel with readable inventory"
        }
        switch OperationID(rawValue: operationID) {
        case .mixerGetOutputVerified
            where liveFixturePrecondition == .mixerOutputTarget
                && state == "C" && writeAttempted == false && error == "invalid_params"
                && hint == "get_output_verified requires a current physical Mixer target_ref; no track/index selectors or write inputs are accepted":
            return liveFixturePrecondition?.reason
        case .mixerGetInputBusVerified
            where liveFixturePrecondition == .mixerInputBusTarget
                && state == "C" && writeAttempted == false && error == "invalid_params"
                && hint == "get_input_bus_verified requires a current physical Mixer target_ref; no track/index selectors or write inputs are accepted":
            return liveFixturePrecondition?.reason
        case .mixerGetSendDestinationVerified
            where liveFixturePrecondition == .mixerOccupiedSend
                && state == "C" && writeAttempted == false && error == "invalid_params"
                && hint == "get_send_destination_verified requires a current physical Mixer target_ref; no track/index selectors or write inputs are accepted":
            return liveFixturePrecondition?.reason
        case .mixerGetSendBypassVerified
            where liveFixturePrecondition == .mixerOccupiedSend
                && state == "C" && writeAttempted == false && error == "invalid_params"
                && hint == "An exact physical Mixer target_ref and occupied source-census ordinal are required":
            return liveFixturePrecondition?.reason
        case .pluginsGetHostParameterManifest
            where liveFixturePrecondition == .pluginHostManifestTarget
                && state == "C" && writeAttempted == false && error == "invalid_params"
                && hint == "get_host_parameter_manifest requires an occupied insert target_ref and non-empty expected_build_fingerprint; it accepts no write inputs":
            return liveFixturePrecondition?.reason
        case .pluginsGetParamVerified
            where liveFixturePrecondition == .pluginReadableParameter
                && state == "C" && writeAttempted == false && error == "invalid_params"
                && hint == "get_param_verified requires an occupied insert target_ref; scalar reads also require a named param. No value, mode or confirmation is accepted":
            return liveFixturePrecondition?.reason
        case .pluginsGetChannelEQStateVerified
            where liveFixturePrecondition == .pluginChannelEQ
                && state == "C" && writeAttempted == false && error == "invalid_params"
                && hint == "get_channel_eq_state_verified requires an occupied insert target_ref; scalar reads also require a named param. No value, mode or confirmation is accepted":
            return liveFixturePrecondition?.reason
        case .pluginsPlanParameterChanges
            where liveFixturePrecondition == .pluginPlannableParameter
                && state == "C" && writeAttempted == false && error == "invalid_params"
                && hint == "plan_parameter_changes requires an occupied insert target_ref; scalar reads also require a named param. No value, mode or confirmation is accepted":
            return liveFixturePrecondition?.reason
        case .tracksScanPluginPresets
            where error == HonestContract.FailureError.pluginWindowUnavailable.rawValue
                && hint == AccessibilityChannel.pluginWindowUnavailableHint:
            return "requires an open plugin window with a Setting dropdown"
        default:
            return nil
        }
    }

    /// The outcome used by the live qualification gate. A response-only oracle is reported as
    /// protocol smoke rather than promoted or mislabeled as a product failure. Other non-passing
    /// read-only observations fail unless the operation names an exact missing operation or
    /// environmental prerequisite; neither prerequisite kind is counted as a pass.
    var liveGateDisposition: QualificationLiveGateDisposition {
        if status == .failed { return .failed }
        switch liveGateScope {
        case .inScope:
            if status == .passed { return .passed }
            // A response-only oracle deliberately withholds independent semantic credit. Its
            // shape/domain validation still ran, so this is neither a pass nor a product failure;
            // keep it visible as the status it actually earned. Refusals, mismatches and missing
            // responses do not reach `.protocolSmoke` and continue through the failure paths.
            if status == .protocolSmoke { return .protocolSmoke }
            if liveGateUnmetOperationPrecondition != nil {
                return .notExercisableWithoutPreconditions
            }
            if liveGateUnmetEnvironmentalPrecondition != nil {
                return .environmentalPrecondition
            }
            return .failed
        case .outOfScope:
            return .outOfScope
        }
    }

    /// A diagnostic reason for a failed live-gate disposition, derived only
    /// from the captured request, readback, and response observations.
    var liveGateFailureReason: String? {
        guard liveGateDisposition == .failed else { return nil }
        if let failureReason { return failureReason }
        if responseData == nil {
            return "operation request produced no response"
        }
        if readbackArtifactData == nil {
            return "independent readback produced no response"
        }
        switch mutability {
        case .mutating:
            guard !expectedZeroWriteRefusalObserved else {
                return "mutating operation produced a failed observation after its zero-write refusal"
            }
            return "operation request missing expected typed zero-write refusal "
                + "(is_error=\(Self.observed(isError)), state=\(Self.observed(state)), "
                + "error=\(Self.observed(error)), write_attempted=\(Self.observed(writeAttempted)))"
        case .readOnly:
            if isError != false {
                return "operation request returned a refusal: "
                    + Self.unavailableDetail(error: error, hint: hint)
            }
            if let reason = readbackFreshness.refusalReason {
                return "independent readback was not admissible: \(reason)"
            }
            if let deferred = QualificationSemanticReadbackValidator.independentReadbackDeferral(
                for: operationID,
                readbackSource: readbackSource
            ) {
                return deferral?.detail ?? deferred.detail
            }
            switch semanticReadbackValidated {
            case .some(false):
                return "semantic readback mismatch: response did not match its independent readback"
            case .none:
                return "in-scope read has no operation-specific semantic validator"
            case .some(true):
                return "in-scope read did not reach a passing qualification"
            }
        }
    }

    var verificationKind: QualificationVerificationKind {
        switch status {
        // A MUTATING pass and a READ pass are opposite evidence and must not share a kind. A read
        // passes because its response agreed with an independent readback, so its probe SUCCEEDED.
        // A mutating operation passes because a write-and-restore cycle was recorded and its probe
        // was REFUSED fail-closed -- `expectedZeroWriteRefusalObserved`, which requires
        // `isError == true`. Filing both as `semanticReadback` sent every mutating pass into a
        // shape rule that requires `operationIsError == false`, so the verifier rejected the whole
        // class while the runner kept reporting it passed. Nothing noticed: no test had ever put a
        // mutation-restore record through verification.
        // `mutationRestore != nil`, not `mutability == .mutating`. A verified write cycle is a
        // case that RESTS ON a recorded cycle; being a mutating operation is not the same claim.
        // The first version branched on mutability and turned every mutating pass into a cycle
        // case, including ones that never recorded one -- which the verifier then rejected for
        // lacking the record they never had.
        case .passed: mutationRestore != nil ? .verifiedWriteCycle : .semanticReadback
        case .protocolSmoke: .protocolSmoke
        default: .typedDeferral
        }
    }

    var deferral: QualificationDeferral? {
        if status == .notQualified,
           isError == false,
           let reason = readbackFreshness.refusalReason {
            return QualificationDeferral(
                code: .semanticMismatch,
                detail: reason
            )
        }
        switch status {
        case .notQualified where mutability == .mutating:
            // A record EXISTS and the operation still did not qualify: the cycle verified but its
            // independent readback was not admissible. Saying "requires an operation-specific
            // recipe" here would be false — one ran, and succeeded. Measured 2026-09-14: this is
            // what `mixer.set_volume` / `mixer.set_pan` hit, because `logic://mixer` reports its
            // provenance under `data_source` while the freshness gate reads `source` (which
            // `logic://tracks` does emit), so the envelope reads as not-live.
            if mutationRestore != nil, let reason = readbackFreshness.refusalReason {
                return QualificationDeferral(
                    code: .semanticMismatch,
                    detail: "a Phase-B write-and-restore cycle VERIFIED, but its independent "
                        + "readback was not admissible: \(reason)"
                )
            }
            if let refusal = mutationRestoreRefusal {
                return QualificationDeferral(
                    code: .liveMutationNotRun,
                    detail: "a Phase-B write-and-restore recipe RAN and refused: \(refusal)"
                )
            }
            return QualificationDeferral(
                code: .liveMutationNotRun,
                detail: "deferred to ADR-001-c: live mutation requires an operation-specific fixture and independent readback"
            )
        case .notQualified where isError == false && semanticReadbackValidated == false:
            if let deferred = QualificationSemanticReadbackValidator.independentReadbackDeferral(
                for: operationID,
                readbackSource: readbackSource
            ) {
                return QualificationDeferral(
                    code: .semanticMismatch,
                    detail: "response/readback protocol consistency check failed; \(deferred.detail)"
                )
            }
            return QualificationDeferral(
                code: .semanticMismatch,
                detail: "read-only response did not match its operation-specific independent readback"
            )
        case .notQualified where error == HonestContract.FailureError.commandNotExposed.rawValue:
            return QualificationDeferral(
                code: .notExposedInProductionContract,
                detail: "the production MCP contract does not expose this operation; no probe "
                    + "parameter can qualify it while its feature flag is off"
            )
        case .notQualified:
            return QualificationDeferral(
                code: .operationUnavailable,
                // This used to assert one cause for every shortfall: that the probe sends `[:]`
                // and the operation refused for want of a parameter. That is true for some and
                // false for others, and the attestation had no way to tell them apart.
                //
                // Measured 2026-08-24: `tracks.list_library` takes NO parameters and its refusal
                // names the unavailable Library panel rather than a missing request parameter;
                // `tracks.scan_plugin_presets` refuses with a typed missing-plugin-window receipt.
                // Both name their precondition exactly. The old text sent whoever read the
                // attestation to check probe parameters that do not exist for those operations,
                // while the operation had already said what it needed.
                //
                // So the detail now carries what the operation said. The generic sentence remains
                // only for a refusal that named nothing, which is the one case where a category
                // guess is all there is.
                detail: Self.unavailableDetail(error: error, hint: hint)
            )
        case .protocolSmoke:
            if let deferred = QualificationSemanticReadbackValidator.independentReadbackDeferral(
                for: operationID,
                readbackSource: readbackSource
            ) {
                return deferred
            }
            return QualificationDeferral(
                code: .semanticValidatorUnavailable,
                detail: "protocol transport succeeded without an operation-specific semantic validator"
            )
        default:
            return nil
        }
    }

    /// The refusal in the operation's own words when it gave any, and a stated absence otherwise.
    ///
    /// Kept deliberately literal: an attestation is read by someone deciding whether a shortfall is
    /// their environment or the product, and a paraphrase is where that distinction goes missing.
    static func unavailableDetail(error: String?, hint: String?) -> String {
        let code = error?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (code?.isEmpty == false ? code : nil, reason?.isEmpty == false ? reason : nil) {
        case let (.some(code), .some(reason)):
            return "read-only operation refused with `\(code)`: \(reason)"
        case let (.some(code), .none):
            return "read-only operation refused with `\(code)` and named no precondition"
        case let (.none, .some(reason)):
            return "read-only operation did not return a successful typed response: \(reason)"
        case (.none, .none):
            return "read-only operation did not return a successful typed response and named "
                + "neither an error code nor a precondition"
        }
    }

    private var semanticReadbackValidated: Bool? {
        guard mutability == .readOnly,
              let responseData,
              let readbackData else {
            return nil
        }
        return QualificationSemanticReadbackValidator.validate(
            operationID: operationID,
            responseData: responseData,
            readbackData: readbackData,
            readbackSource: readbackSource
        )
    }

    private var readbackFreshness: QualificationReadbackFreshness.Verdict {
        guard let readbackData else { return .cacheAgeUnknown }
        return QualificationReadbackFreshness.verdict(
            for: readbackData,
            uri: readbackSource,
            verification: verification,
            deadline: deadline
        )
    }

    private static func encoded<Value: Encodable>(_ value: Value) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(value)
    }

    private static func observed(_ value: String?) -> String {
        value ?? "not observed"
    }

    private static func observed(_ value: Bool?) -> String {
        value.map(String.init) ?? "not observed"
    }
}

enum QualificationLiveGateScope: String, Sendable {
    case inScope = "in_scope"
    case outOfScope = "out_of_scope"
}

enum QualificationLiveGateDisposition: String, Sendable {
    case passed
    case protocolSmoke = "protocol_smoke"
    case outOfScope = "out_of_scope"
    case notExercisableWithoutPreconditions = "not_exercisable_without_preconditions"
    case environmentalPrecondition = "environmental_precondition"
    case failed
}

/// The human-readable accounting for the real-process live qualification test.
///
/// It deliberately does not alter `QualificationStatus`, which is also used by
/// the release-attestation and waiver machinery. The direct live gate needs a
/// direct interpretation: product failures and semantic mismatches fail, a successful
/// response-only check remains explicitly `protocol_smoke`, and mutating success paths are
/// excluded unless they carry their separate write-and-restore evidence.
struct QualificationLiveGateSummary: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        let operationID: String
        let failureReason: String
    }

    struct Prerequisite: Equatable, Sendable {
        let operationID: String
        let reason: String
    }

    let total: Int
    let inScopePassed: Int
    let protocolSmoke: Int
    let outOfScope: Int
    let mutatingOperationCount: Int
    let notExercisableWithoutPreconditions: [Prerequisite]
    let environmentalPreconditions: [Prerequisite]
    let failures: [Failure]

    init(operationResults: [QualificationOperationResult]) {
        total = operationResults.count
        mutatingOperationCount = operationResults.filter {
            $0.liveGateScope == .outOfScope
        }.count
        inScopePassed = operationResults.filter {
            $0.liveGateDisposition == .passed
        }.count
        protocolSmoke = operationResults.filter {
            $0.liveGateDisposition == .protocolSmoke
        }.count
        outOfScope = operationResults.filter {
            $0.liveGateDisposition == .outOfScope
        }.count
        notExercisableWithoutPreconditions = operationResults
            .filter { $0.liveGateDisposition == .notExercisableWithoutPreconditions }
            .sorted { $0.operationID < $1.operationID }
            .map { operation in
                guard let reason = operation.liveGateUnmetOperationPrecondition else {
                    preconditionFailure("An unmet operation precondition must retain its reason")
                }
                return Prerequisite(operationID: operation.operationID, reason: reason)
            }
        environmentalPreconditions = operationResults
            .filter { $0.liveGateDisposition == .environmentalPrecondition }
            .sorted { $0.operationID < $1.operationID }
            .map { operation in
                guard let reason = operation.liveGateUnmetEnvironmentalPrecondition else {
                    preconditionFailure("An unmet environmental precondition must retain its reason")
                }
                return Prerequisite(operationID: operation.operationID, reason: reason)
            }
        failures = operationResults
            .filter { $0.liveGateDisposition == .failed }
            .sorted { $0.operationID < $1.operationID }
            .map { operation in
                guard let failureReason = operation.liveGateFailureReason else {
                    preconditionFailure("A failed live-gate operation must retain an observed reason")
                }
                return Failure(
                    operationID: operation.operationID,
                    failureReason: failureReason
                )
            }
    }

    var failed: Int { failures.count }

    var accounted: Int {
        inScopePassed
            + protocolSmoke
            + outOfScope
            + notExercisableWithoutPreconditions.count
            + environmentalPreconditions.count
            + failed
    }

    var classificationLine: String {
        "qualification live gate: in_scope_passed=\(inScopePassed), "
            + "protocol_smoke=\(protocolSmoke), "
            + "out_of_scope=\(outOfScope), "
            + "not_exercisable_without_preconditions=\(notExercisableWithoutPreconditions.count), "
            + "environmental_preconditions=\(environmentalPreconditions.count), "
            + "failed=\(failed) of \(total)"
    }

    var mutatingOperationExclusionLine: String {
        "qualification live gate coverage: mutating operations are not exercised; "
            + "\(mutatingOperationCount) are out of scope for semantic qualification and receive "
            + "only zero-write refusal probes"
    }

    var failureLine: String? {
        guard !failures.isEmpty else { return nil }
        return "failed operations: " + failures.map {
            "\($0.operationID) (failureReason=\($0.failureReason))"
        }.joined(separator: ", ")
    }

    var unmetOperationPreconditionsLine: String? {
        guard !notExercisableWithoutPreconditions.isEmpty else { return nil }
        return "not-exercisable without operation preconditions: "
            + notExercisableWithoutPreconditions.map {
                "\($0.operationID) (reason=\($0.reason))"
            }.joined(separator: ", ")
    }

    var environmentalPreconditionsLine: String? {
        guard !environmentalPreconditions.isEmpty else { return nil }
        return "unmet environmental preconditions: " + environmentalPreconditions.map {
            "\($0.operationID) (reason=\($0.reason))"
        }.joined(separator: ", ")
    }
}

enum QualificationSemanticReadbackValidator {
    static let coreMIDIPortReadbackSource = "host://coremidi/ports"
    static let libraryPanelReadbackSource = "host://accessibility/library-panel"

    static func independentReadbackDeferral(
        for operationID: String,
        readbackSource: String? = nil
    ) -> QualificationDeferral? {
        guard let id = OperationID(rawValue: operationID) else { return nil }
        if id == .midiListPorts, readbackSource == coreMIDIPortReadbackSource {
            return nil
        }
        if id == .tracksListLibrary, readbackSource == libraryPanelReadbackSource {
            return nil
        }
        return SemanticOracleTable.byOperationID[id]?.independentReadbackDeferral
    }

    static func canUseIndependentReadback(for operationID: OperationID) -> Bool {
        operationID == .midiListPorts || operationID == .tracksListLibrary
            || SemanticOracleTable.byOperationID[operationID]?.independentReadbackDeferral == nil
    }

    static func validate(
        operationID: String,
        responseData: Data,
        readbackData: Data,
        readbackSource: String? = nil
    ) -> Bool? {
        switch OperationID(rawValue: operationID) {
        case .systemHealth:
            // Bespoke: full typed-payload equality against the independent read.
            return healthMatches(responseData, readbackData)
        case .some(let id):
            // Preserve raw response/protocol checks, but do not promote a declared
            // non-independent agreement to semantic readback. Malformed/divergent
            // protocol evidence still fails rather than silently becoming smoke.
            guard let oracle = SemanticOracleTable.byOperationID[id] else { return nil }
            let verdict = oracle.evaluate(responseData: responseData, readbackData: readbackData)
            switch verdict {
            case .some(true) where independentReadbackDeferral(
                for: operationID,
                readbackSource: readbackSource
            ) != nil:
                return nil
            default:
                return verdict
            }
        case .none:
            return nil
        }
    }

    private static func healthMatches(_ responseData: Data, _ readbackData: Data) -> Bool {
        guard let response = try? JSONDecoder().decode(HealthResult.self, from: responseData),
              let readback = try? JSONDecoder().decode(HealthResult.self, from: readbackData) else {
            return false
        }
        return response == readback
    }
}

struct QualificationNegativeResult: Equatable, Sendable {
    let toolIsError: Bool
    let state: String
    let error: String
    let writeAttempted: Bool
    let healthBefore: Data
    let healthAfter: Data
    let catalogBefore: Data
    let catalogAfter: Data

    var healthReadStable: Bool { healthBefore == healthAfter }
    var catalogReadStable: Bool { catalogBefore == catalogAfter }

    var isFailClosedAndStable: Bool {
        // Health warms during cache polling and MCU registration; zero-write plus a stable catalog is dispositive.
        toolIsError
            && state == "C"
            && error == "invalid_params"
            && !writeAttempted
            && catalogReadStable
    }
}

struct QualificationDriveResult: Equatable, Sendable {
    let handshake: QualificationHandshake?
    let health: QualificationHealth?
    let catalog: OperationCatalogSnapshot?
    let expectedOperationCount: Int
    let traceList: QualificationTraceList?
    let traceDetail: QualificationTraceDetail?
    let negative: QualificationNegativeResult?
    let observedLocale: String
    let operationResults: [String: QualificationOperationResult]
    let wireFrames: [QualificationWireFrame]
    let mutationRestoreRecords: [QualificationMutationRestoreRecord]
    let failureReason: String?

    init(
        handshake: QualificationHandshake?,
        health: QualificationHealth?,
        catalog: OperationCatalogSnapshot?,
        expectedOperationCount: Int,
        traceList: QualificationTraceList?,
        traceDetail: QualificationTraceDetail? = nil,
        negative: QualificationNegativeResult?,
        observedLocale: String,
        operationResults: [String: QualificationOperationResult] = [:],
        wireFrames: [QualificationWireFrame] = [],
        mutationRestoreRecords: [QualificationMutationRestoreRecord] = [],
        failureReason: String?
    ) {
        self.handshake = handshake
        self.health = health
        self.catalog = catalog
        self.expectedOperationCount = expectedOperationCount
        self.traceList = traceList
        self.traceDetail = traceDetail
        self.negative = negative
        self.observedLocale = observedLocale
        self.operationResults = operationResults
        self.wireFrames = wireFrames
        self.mutationRestoreRecords = mutationRestoreRecords
        self.failureReason = failureReason
    }

    var handshakeOK: Bool { handshake?.isValid == true }
    var healthOK: Bool { health?.isValid == true && health?.identifiesLiveLogic == true }
    var catalogCountMatch: Bool {
        guard let catalog else { return false }
        return catalog.operationCount == expectedOperationCount
            && catalog.operations.count == catalog.operationCount
    }
    var traceOK: Bool {
        guard let traceDetail,
              traceDetail.operationID == OperationID.systemSagaExecute.rawValue,
              traceDetail.phases.first == TracePhase.requestReceived.rawValue,
              traceDetail.phases.last == TracePhase.resultEmitted.rawValue,
              let summary = traceList?.traces.first(where: {
                  $0.traceID == traceDetail.traceID
                      && $0.operationID == traceDetail.operationID
              }) else {
            return false
        }
        return summary.phaseCount > 0 && summary.phaseCount == traceDetail.phases.count
    }
    var negativeFailclosed: Bool { negative?.isFailClosedAndStable == true }
    var allChecksPass: Bool {
        handshakeOK && healthOK && catalogCountMatch && traceOK && negativeFailclosed
    }
    var observedVariant: String {
        guard let identifier = health?.logicProVariant else { return "unknown" }
        return identifier == LogicProVariant.creatorStudio.rawValue
            ? LogicVariant.creatorStudio.rawValue
            : identifier
    }
    var logicProVersion: String { health?.logicProVersion ?? "unknown" }
    var identifiesLiveLogic: Bool { health?.identifiesLiveLogic == true }
    var availabilityObservation: QualificationAvailabilityObservation? {
        health?.availabilityObservation
    }
}

enum QualificationTransportError: Error, Equatable, CustomStringConvertible, Sendable {
    case requestTimeout(phase: String)
    case nonZeroExit(status: Int32, stderr: String)
    case malformedFrame(String)
    case closedPipe(phase: String)
    case launchFailed(String)
    case protocolViolation(String)
    case supportBundleOutcomeQuiesced(String)
    case supportBundleOutcomeUncertain(String)
    case shutdownTimeout
    case unimplemented

    var description: String {
        switch self {
        case .requestTimeout(let phase): "qualification_transport_timeout:\(phase)"
        case .nonZeroExit(let status, let stderr):
            "qualification_transport_nonzero_exit:\(status):\(stderr)"
        case .malformedFrame(let detail): "qualification_transport_malformed_frame:\(detail)"
        case .closedPipe(let phase): "qualification_transport_closed_pipe:\(phase)"
        case .launchFailed(let detail): "qualification_transport_launch_failed:\(detail)"
        case .protocolViolation(let detail): "qualification_transport_protocol_violation:\(detail)"
        case .supportBundleOutcomeQuiesced(let detail):
            "qualification_support_bundle_outcome_quiesced:\(detail)"
        case .supportBundleOutcomeUncertain(let detail):
            "qualification_support_bundle_outcome_uncertain:\(detail)"
        case .shutdownTimeout: "qualification_transport_shutdown_timeout"
        case .unimplemented: "qualification_transport_unimplemented"
        }
    }

    var requiresDriveAbort: Bool {
        switch self {
        case .supportBundleOutcomeQuiesced, .supportBundleOutcomeUncertain: true
        default: false
        }
    }
}
