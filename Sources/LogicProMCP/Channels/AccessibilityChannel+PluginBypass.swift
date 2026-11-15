@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    static func setPluginBypassVerified(
        params: [String: String], runtime: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let operation = "logic_plugins.set_bypass_verified"
        let ax = runtime.ax
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: error, hint: hint,
                extras: ["operation": operation, "write_attempted": false]))
        }
        _ = runtime.onScreenWindowList()
        guard let track = params["track"].flatMap(Int.init), let insert = params["insert"].flatMap(Int.init),
              let id = params["expected_plugin_identity"], VerifiedPluginCatalog.canonicalPluginID(from: id) != nil,
              params["expected_slot_read_status"] == "ok",
              let path = params["project_expected_path"], let name = params["expected_track_name"],
              let requested = params["bypassed"].flatMap(Bool.init),
              let expected = params["expected_current"].flatMap(Bool.init),
              let pid = runtime.logicProPID(), runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true
        else { return refuse(.invalidParams, "Use a current stock insert reference and Boolean bypass values on Logic Pro 13.") }

        guard case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              let url = URL(string: document), url.isFileURL, AppleScriptChannel.projectPathsMatch(path, url.path),
              let mixer = mixerWithoutRevealForInventory(runtime: runtime, revealRequested: false)?.mixer,
              let binding = AXPluginTrackBinding.resolve(track: track, mixer: mixer, runtime: runtime),
              CFEqual(window, binding.window), binding.trackName == name,
              let before = AXLogicProElements.audioPluginInsertSlots(in: binding.strip, runtime: ax),
              before.indices.contains(insert),
              before.allSatisfy({ $0.readStatus == .empty || ($0.readStatus == .occupiedReadable && $0.isBypassed != nil) }),
              let original = before[insert].isBypassed else {
            return refuse(.readbackUnavailable, "Stop playback and show the Mixer for the referenced stock insert.")
        }
        if let failure = pluginInsertReferenceGuard(params: params, slot: before[insert], operation: operation) {
            return failure
        }
        guard original == expected else {
            return refuse(.staleSnapshot, "The insert’s bypass state changed. Read its inventory again.")
        }

        func snapshot() -> [AXLogicProElements.PluginInsertSlot]? {
            _ = runtime.onScreenWindowList()
            guard ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true),
                  AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime) == .success(document),
                  AXPluginTrackBinding.isStable(binding, runtime: runtime),
                  let current = AXLogicProElements.audioPluginInsertSlots(in: binding.strip, runtime: ax),
                  current.count == before.count,
                  zip(before, current).allSatisfy({ old, now in
                      old.index == now.index && old.name == now.name && old.readStatus == now.readStatus
                          && CFEqual(old.element, now.element)
                          && (old.index == insert || old.isBypassed == now.isBypassed)
                  }) else { return nil }
            return current
        }
        guard let live = snapshot(), live[insert].isBypassed == original else {
            return refuse(.staleTargetReference, "The referenced slot or its Mixer changed. Read the inventory again.")
        }

        func verified(attempted: Bool) -> ChannelResult {
            .success(HonestContract.encodeStateA(extras: [
                "operation": operation, "insert": insert, "before": original, "bypassed": requested,
                "changed": attempted, "write_attempted": attempted, "neighboring_inserts_verified": true,
                "verify_source": "ax_mixer_insert_bypass",
            ]))
        }
        if requested == original { return verified(attempted: false) }
        guard case .success(let children) = AXHelpers.childrenResult(live[insert].element, runtime: ax) else {
            return refuse(.readbackUnavailable, "The insert’s bypass control could not be read.")
        }
        let controls = children.filter {
            AXHelpers.getRole($0, runtime: ax) == kAXCheckBoxRole
                && AXHelpers.getDescription($0, runtime: ax) == "bypass"
        }
        // Logic 13 reports AXEnabled false on the Mixer slot's bypass checkbox
        // even when its supported AXPress changes the value and the slot reads it back.
        guard controls.count == 1, let control = controls.first,
              let owner: AXUIElement = AXHelpers.getAttribute(control, kAXParentAttribute, runtime: ax),
              CFEqual(owner, live[insert].element),
              case .success(let actions)? = ax.actionNamesResult?(control),
              actions.contains(kAXPressAction),
              AXValueExtractors.extractButtonState(control, runtime: ax) == original,
              snapshot()?[insert].isBypassed == original,
              OperationTraceContext.claimDeadlineEffect("bound_plugin_bypass") else {
            return refuse(.readbackUnavailable, "The insert’s bypass control could not be held for this edit.")
        }

        _ = AXHelpers.performAction(control, kAXPressAction, runtime: ax)
        for _ in 0..<10 {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            if snapshot()?[insert].isBypassed == requested { return verified(attempted: true) }
        }
        return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: [
            "operation": operation, "insert": insert, "requested_bypass": requested,
            "write_attempted": true, "safe_to_retry": false, "effect_unknown": true,
        ]))
    }
}
