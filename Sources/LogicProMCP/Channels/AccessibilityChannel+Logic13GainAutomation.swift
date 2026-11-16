import ApplicationServices
import Foundation

extension AccessibilityChannel {
    static func defaultGainAutomation(
        params: [String: String], edit: Bool, logic: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let operation = edit ? "plugin.set_gain_automation_point" : "plugin.get_gain_automation"
        let pluginID = "logic.stock.effect.gain"
        // The Event List identifies this instance's parameter by a native
        // channel/controller pair. Only the measured fourth insert qualifies.
        let insert = 3
        let ax = logic.ax
        func refuse(_ stage: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: .readbackUnavailable,
                hint: "Show the selected track's fourth-insert Gain automation in Read mode, leave Mixer visible and focus its Track Automation Event List.",
                extras: ["operation": operation, "readback_stage": stage, "write_attempted": false]))
        }
        guard params["expected_plugin_identity"] == pluginID,
              params["insert"].flatMap(Int.init) == insert,
              let track = params["track"].flatMap(Int.init),
              let expectedPath = params["project_expected_path"],
              let pid = logic.logicProPID(), logic.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true,
              let app = AXLogicProElements.appRoot(runtime: logic),
              case .found(let arrange) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: logic),
              let mixer = AXLogicProElements.mixerAreaLookup(in: arrange, runtime: logic).mixer,
              let binding = AXPluginTrackBinding.resolve(track: track, mixer: mixer, runtime: logic),
              CFEqual(binding.window, arrange), binding.trackName == params["expected_track_name"],
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(arrange, runtime: logic),
              let url = URL(string: document), url.isFileURL, AppleScriptChannel.projectPathsMatch(expectedPath, url.path),
              let title = AXHelpers.getTitle(arrange, runtime: ax), title.hasSuffix(" - Tracks"),
              let editor: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: ax),
              !CFEqual(editor, arrange) else { return refuse("gain_automation_scope") }
        let list = Logic13AutomationEventList(app: app, editor: editor, arrange: arrange,
            title: String(title.dropLast(" - Tracks".count)), trackName: binding.trackName,
            runtime: ax, includesStockGain: true)

        func gainSlot() -> AXUIElement? {
            guard let slots = AXLogicProElements.audioPluginInsertSlots(in: binding.strip, runtime: ax),
                  slots.allSatisfy({ $0.readStatus == .occupiedReadable || $0.readStatus == .empty }),
                  let only = slots.first(where: { $0.index == insert }), only.occupied,
                  only.name.flatMap(VerifiedPluginCatalog.pluginID(forObservedName:)) == pluginID,
                  slots.filter({ $0.name.flatMap(VerifiedPluginCatalog.pluginID(forObservedName:)) == pluginID }).count == 1
            else { return nil }
            return only.element
        }
        guard let slot = gainSlot() else { return refuse("gain_insert_identity") }
        func current() -> Bool {
            guard !Task.isCancelled, logic.onScreenWindowList() != nil, logic.focusedApplicationPID() == pid,
                  list.ownsEditor(), AXPluginTrackBinding.isStable(binding, runtime: logic),
                  let currentSlot = gainSlot(), CFEqual(currentSlot, slot),
                  case .success(.some(let path)) = AXLogicProElements.projectPickerDocumentRead(arrange, runtime: logic),
                  path == document,
                  case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: arrange, runtime: logic),
                  headers.indices.contains(track), CFEqual(headers[track], binding.header),
                  headers.enumerated().allSatisfy({
                      AXValueExtractors.extractSelectedState($0.element, runtime: ax) == ($0.offset == track)
                  }), automationLaneIsReady(.gain, header: binding.header, runtime: ax) else { return false }
            return true
        }
        var stage = "gain_event_table"
        guard current(), let points = list.points(onRefusal: { stage = $0 }), current() else { return refuse(stage) }
        if edit {
            return await changeTrackAutomationPoint(params: params, points: points, lane: .gain,
                editor: list, current: current, logic: logic, operation: operation)
        }
        return .success(HonestContract.encodeStateA(extras: [
            "operation": operation, "lane": "gain", "unit": Logic13AutomationLane.gain.unit,
            "track": track, "insert": insert, "points": points.filter { $0.lane == .gain }.map(\.evidence),
            "verify_source": "ax_automation_event_list", "write_attempted": false,
        ]))
    }
}
