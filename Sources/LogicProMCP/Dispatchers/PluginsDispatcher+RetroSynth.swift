import ApplicationServices
import Foundation
import MCP

@MainActor
private enum RetroSynthSession {
    struct Binding {
        let reference: String
        let project: String
        let track: String
        let slot: AXUIElement
        let hash: String
    }
    static var current: Binding?
}

extension PluginsDispatcher {
    @MainActor
    static func retroSynth(command: String, params: [String: Value], cache: StateCache,
                           targetRegistry: TargetRegistry?, gate: VerifiedOpGate,
                           liveTrackNames: (@Sendable () -> [Int: String]?)?, traceID: TraceID?) async -> CallTool.Result {
        let operation = "plugin.\(command)"
        func refuse(_ error: HonestContract.FailureError, _ hint: String, extras: [String: Any] = [:]) -> CallTool.Result {
            var details = extras
            details["operation"] = operation
            details["verified"] = false
            details["write_attempted"] = false
            return toolTextResult(.error(HonestContract.encodeStateC(error: error, hint: hint, extras: details)))
        }
        var allowed: Set<String> = ["project_ref", "target_ref"]
        if command == "get_retro_synth_state" { allowed.formUnion(["options_for", "open_editor", "close_editor"]) }
        if command == "initialize_retro_synth" { allowed.insert("confirmed") }
        if command == "set_retro_synth_parameter" {
            allowed.formUnion(["instrument_ref", "expected_snapshot", "param", "unit", "value"])
        }
        guard params.keys.allSatisfy(allowed.contains),
              let project = params["project_ref"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty,
              params["target_ref"]?.stringValue?.isEmpty == false else {
            return refuse(.invalidParams, "Pass fresh project_ref and track target_ref values, and only this command's documented parameters.")
        }
        let options: String?
        if let requested = params["options_for"] {
            guard let id = requested.stringValue, RetroSynthProfile.parameter(id) != nil else {
                return refuse(.invalidParams, "options_for must name a supported Retro Synth parameter.")
            }
            options = id
        } else { options = nil }
        let openEditor: Bool
        if let requested = params["open_editor"] {
            guard case .bool(let value) = requested else {
                return refuse(.invalidParams, "open_editor must be a JSON Boolean. true opens and leaves the Controls window visible for repeated edits.")
            }
            openEditor = value
        } else { openEditor = false }
        let closeEditor: Bool
        if let requested = params["close_editor"] {
            guard case .bool(let value) = requested else {
                return refuse(.invalidParams, "close_editor must be a JSON Boolean. true reads the current state, then closes its Controls window before export.")
            }
            closeEditor = value
        } else { closeEditor = false }
        guard !(openEditor && closeEditor) else {
            return refuse(.invalidParams, "Choose either open_editor:true to prepare an editing session or close_editor:true to finish it.")
        }
        if command == "initialize_retro_synth" {
            guard case .bool(true) = params["confirmed"] else {
                return refuse(.invalidParams, "Initialize Setting replaces the instrument's current setting. Pass confirmed:true.")
            }
        }
        var parameter: RetroSynthProfile.Parameter?
        var choice: RetroSynthProfile.Choice?
        if command == "set_retro_synth_parameter" {
            guard params["instrument_ref"]?.stringValue?.isEmpty == false,
                  params["expected_snapshot"]?.stringValue?.isEmpty == false,
                  let id = params["param"]?.stringValue, let found = RetroSynthProfile.parameter(id),
                  let unit = params["unit"]?.stringValue, let value = params["value"],
                  let input = retroSynthInput(value) else {
                return refuse(.invalidParams, "Pass param, unit and a typed native value.")
            }
            guard let resolved = found.resolve(value: input, unit: unit) else {
                return refuse(.invalidParams, "Choose a supported native value. get_retro_synth_state accepts options_for to list values; no value is silently rounded.",
                              extras: ["nearest_supported_values": RetroSynthReport.nearest(found, input: input, unit: unit)])
            }
            parameter = found
            choice = resolved
        }
        guard gate.tryAcquire() else { return refuse(.verifiedOpInProgress, "Another verified editor operation is in progress.") }
        defer { gate.release() }
        let resolved: TargetRefResolver.Resolved
        switch await resolveRetroSynthTarget(params, registry: targetRegistry, cache: cache, operation: operation) {
        case .failure(let failure):
            let text = failure.content.compactMap { item -> String? in
                if case .text(let text, _, _) = item { return text }
                return nil
            }.first
            guard let text, var payload = decodedJSONObject(text), payload["state"] as? String == "C" else {
                return refuse(.readbackUnavailable, "The project and instrument references could not be resolved.")
            }
            payload["verified"] = false
            payload["write_attempted"] = false
            payload["operation"] = operation
            return toolTextResult(ResourceHandlers.encodeJSONObject(payload), isError: true)
        case .success(let value): resolved = value
        }
        guard let reference = resolved.reference, let binding = resolved.binding, let physical = binding.physicalTrack,
              let slot = RetroSynthSlot.acquire(physical: physical, index: resolved.index, name: binding.descriptor.trackName),
              let targetRegistry else {
            RetroSynthSession.current = nil
            return refuse(.readbackUnavailable, "Select one uniquely named Retro Synth track with its Inspector visible in the saved foreground project.")
        }
        if let liveTrackNames {
            guard let names = liveTrackNames(), names.filter({ $0.value == slot.name }).count == 1 else {
                RetroSynthSession.current = nil
                return refuse(.readbackUnavailable, "The track name is ambiguous or the live track inventory is unavailable.")
            }
        }
        let expected: RetroSynthSession.Binding?
        if command == "set_retro_synth_parameter" {
            guard let current = RetroSynthSession.current,
                  params["instrument_ref"]?.stringValue == current.reference,
                  current.project == project, current.track == reference.rawValue,
                  CFEqual(current.slot, slot.group) else {
                RetroSynthSession.current = nil
                return refuse(.staleTargetReference, "Read fresh Retro Synth state before editing this instrument.")
            }
            guard params["expected_snapshot"]?.stringValue == current.hash else {
                RetroSynthSession.current = nil
                return refuse(.staleSnapshot, "The expected_snapshot differs from the issued instrument snapshot.")
            }
            expected = current
        } else {
            expected = nil
            RetroSynthSession.current = nil
        }
        var source: RetroSynthNative?
        var attempted = false
        var cleanupResult: Bool? = nil
        var recorded = false
        func didWrite() async {
            attempted = true
            if !recorded {
                recorded = true
                await recordClaimedWriteBoundary(traceID)
            }
        }
        do {
            let native = try await RetroSynthNative.acquire(slot: slot, openEditor: openEditor)
            source = native
            try await native.prepareControls()
            let result: RetroSynthSnapshot
            if command == "initialize_retro_synth" {
                try await native.initialize(didWrite: didWrite)
                result = try await native.stableSnapshot()
                guard result.isFactoryInitialized else { throw RetroSynthSnapshot.Failure.unavailable("factory_initialization_unverified") }
            } else {
                let before = try await native.stableSnapshot()
                if let expected {
                    guard try before.fingerprint == expected.hash, let parameter, let choice else {
                        RetroSynthSession.current = nil
                        let cleaned = await native.cleanup()
                        return refuse(.staleSnapshot, "The instrument changed after the issued snapshot.", extras: ["ui_restored": cleaned])
                    }
                    try await native.set(parameter: parameter, choice: choice, firstEffectPermitted: {
                        guard try native.snapshot().fingerprint == expected.hash else {
                            throw RetroSynthSnapshot.Failure.unavailable("snapshot_changed_before_write")
                        }
                    }, didWrite: didWrite)
                    result = try await native.stableSnapshot()
                    let observed = try result.observation(parameter)
                    guard observed.position == choice.position, observed.text == choice.text,
                          observed.boolean == choice.boolean, observed.sync == choice.sync,
                          observed.number == choice.number else { throw RetroSynthSnapshot.Failure.unavailable("requested_value_unverified") }
                    var changed: Set<String> = [parameter.label]
                    if parameter.id == "lfo_sync" || parameter.id == "lfo_rate" { changed.formUnion(["LFO Sync:", "LFO Rate:"]) }
                    guard result.preservesPeers(of: before, changing: changed) else {
                        throw RetroSynthSnapshot.Failure.unavailable("untargeted_parameter_changed")
                    }
                } else { result = before }
            }
            guard !Task.isCancelled, await targetRegistry.resolve(reference) != nil,
                  await targetRegistry.resolveCurrentProject(.init(rawValue: project)) != nil,
                  native.holdsTarget() else { throw RetroSynthSnapshot.Failure.unavailable("final_target_changed") }
            let hash = try result.fingerprint
            let parameters = try RetroSynthReport.parameters(result, optionsFor: options)
            let retainedNewEditor = native.openedEditor
            let cleaned: Bool
            if retainedNewEditor { cleaned = native.retainPreparedEditor() }
            else { cleaned = await native.cleanup(closeExisting: closeEditor); cleanupResult = closeEditor ? false : cleaned }
            guard cleaned, slot.isCurrent(), !Task.isCancelled else {
                throw RetroSynthSnapshot.Failure.unavailable("editor_restoration_unverified")
            }
            source = nil
            cleanupResult = !retainedNewEditor && !closeEditor
            let instrument = "rsy_" + UUID().uuidString.lowercased()
            RetroSynthSession.current = .init(reference: instrument, project: project, track: reference.rawValue, slot: slot.group, hash: hash)
            return toolTextResult(ResourceHandlers.encodeJSONObject([
                "operation": operation, "state": "A", "success": true, "verified": true,
                "write_attempted": attempted, "project_ref": project, "target_ref": reference.rawValue,
                "instrument_ref": instrument, "snapshot_hash": hash, "profile": RetroSynthProfile.id,
                "instrument": "Retro Synth", "mode": "Analog", "preset": result.preset,
                "enabled": result.enabled, "enabled_source": "ax_bound_instrument_slot_bypass",
                "parameter_count": RetroSynthProfile.parameters.count,
                "native_row_count": result.rows.count, "ui_restored": !retainedNewEditor && !closeEditor,
                "editor_retained": !closeEditor, "editor_opened": retainedNewEditor,
                "editor_closed": closeEditor, "ui_policy_satisfied": true,
                "parameters": parameters,
            ]))
        } catch {
            RetroSynthSession.current = nil
            let cleaned: Bool
            if let cleanupResult { cleaned = cleanupResult }
            else if let acquisition = error as? RetroSynthNative.AcquisitionFailure { cleaned = acquisition.uiRestored }
            else { cleaned = await source?.cleanup() ?? true }
            Log.debug("Retro Synth operation unverified: \(error)", subsystem: "plugins")
            if !attempted {
                if let failure = error as? RetroSynthSnapshot.Failure,
                   case .unavailable("controls_editor_required") = failure {
                    return refuse(.readbackUnavailable, "Keep the unlinked Retro Synth window open in Controls view while editing. To open and retain one, call get_retro_synth_state with open_editor:true. An existing graphical Editor must be switched to Controls manually.",
                                  extras: ["ui_restored": cleaned, "reason": "controls_editor_required"])
                }
                return refuse(.readbackUnavailable, "The bound instrument or its Controls view could not be verified. Read fresh state before another request.",
                              extras: ["ui_restored": cleaned])
            }
            return toolTextResult(ResourceHandlers.encodeJSONObject([
                "operation": operation, "state": "B", "success": false, "verified": false,
                "write_attempted": true, "safe_to_retry": false, "ui_restored": cleaned,
                "reason": "instrument_change_unverified",
                "hint": "Inspect the instrument and read fresh state. Do not automatically repeat the edit.",
            ]))
        }
    }

    nonisolated private static func resolveRetroSynthTarget(_ params: [String: Value], registry: TargetRegistry?,
                                                           cache: StateCache, operation: String) async -> TargetRefResolver.Outcome {
        await TargetRefResolver.resolveMutationIndex(params, targetRegistry: registry, cache: cache,
            operation: operation, invalidIndexResult: toolInvalidParamsResult("A track target_ref is required."))
    }

    private static func retroSynthInput(_ value: Value) -> RetroSynthProfile.Input? {
        switch value {
        case .int(let number): return .number(Double(number))
        case .double(let number) where number.isFinite: return .number(number)
        case .string(let text): return .text(text)
        case .bool(let boolean): return .boolean(boolean)
        default: return nil
        }
    }
}
