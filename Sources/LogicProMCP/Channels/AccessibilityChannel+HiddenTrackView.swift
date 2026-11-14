import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// Explicit view state only: never changes a track's Hide flag. The first
    /// Toggle Hide View invocation materializes its previously absent control.
    static func setHiddenTrackViewVisibility(
        _ desired: Bool, runtime: AXLogicProElements.Runtime,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) async -> ChannelResult {
        let operation = "view.set_hidden_tracks_visibility"
        let ax = runtime.ax
        var attempted = false
        var before: Bool?
        func result(_ observed: Bool?, reason: String? = nil) -> ChannelResult {
            var fields: [String: Any] = ["operation": operation, "requested_visible": desired,
                "write_attempted": attempted, "visibility_source": "bound_tracks_legend"]
            if let before { fields["before_visible"] = before }
            if let observed { fields["after_visible"] = observed }
            if observed == desired { return .success(HonestContract.encodeStateA(extras: fields)) }
            if let reason { fields["reason_detail"] = reason }
            if attempted { return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: fields)) }
            return .error(HonestContract.encodeStateC(error: .readbackUnavailable,
                hint: reason ?? "Hidden-track view could not be observed; no view action was sent.", extras: fields))
        }
        guard let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
              let app = AXLogicProElements.appRoot(runtime: runtime),
              case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime)
        else { return result(nil, reason: "A stopped, foreground project is required.") }
        func stopped() -> Bool {
            if ProcessInfo.processInfo.environment["LOGIC_MCP_LOGIC13_TRACKS"] == "1" {
                guard let bar = AXLogicProElements.logic13ControlBarContainer(in: window, runtime: ax),
                      let play = AXLogicProElements.directToolbarControl(AXLocalePolicy.transportPlayControl,
                          in: bar, runtime: ax),
                      let record = AXLogicProElements.directToolbarControl(AXLocalePolicy.transportRecordControl,
                          in: bar, runtime: ax) else { return false }
                return AXValueExtractors.extractButtonState(play, runtime: ax) == false
                    && AXValueExtractors.extractButtonState(record, runtime: ax) == false
            }
            guard let activity = try? AXLogicProElements.observedTransportActivity(
                in: window, runtime: runtime, checking: { try Task.checkCancellation() }) else { return false }
            return !activity.isPlaying && !activity.isRecording
        }
        guard stopped() else { return result(nil, reason: "The transport is active or unreadable.") }
        func current(_ allowCancelled: Bool = false) -> Bool {
            guard (!Task.isCancelled || allowCancelled), runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid,
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: ax) as Bool? == true,
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: ax),
                  let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: ax),
                  CFEqual(main, window), CFEqual(focused, window),
                  let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: ax),
                  windows.count == 1, CFEqual(windows[0], window),
                  AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime) == .success(document) else { return false }
            return true
        }
        func observation() -> AXLogicProElements.HiddenTrackViewObservation {
            guard current(), case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
                  !headers.isEmpty else { return .unavailable }
            return AXLogicProElements.hiddenTrackViewObservation(headers: headers, in: window, runtime: runtime)
        }
        switch observation() {
        case .observed(let state):
            before = state.shown
            if state.shown == desired { return result(state.shown) }
        case .absent:
            guard desired else { return result(nil, reason: "No hidden-track view control is exposed.") }
        case .unavailable:
            return result(nil)
        }
        guard current(), let bar: AXUIElement = AXHelpers.getAttribute(app, kAXMenuBarAttribute as String, runtime: ax),
              case .success(let top) = AXHelpers.childrenResult(bar, runtime: ax) else { return result(nil) }
        let tracks = top.filter { AXHelpers.getRole($0, runtime: ax) == kAXMenuBarItemRole as String
            && AXLocalePolicy.trackMenuBar.matches(AXHelpers.getTitle($0, runtime: ax)) }
        guard tracks.count == 1, current(), stopped(), OperationTraceContext.claimDeadlineEffect(operation) else { return result(nil) }
        _ = AXHelpers.performAction(tracks[0], kAXPressAction, runtime: ax)
        guard case .success(let children) = AXHelpers.childrenResult(tracks[0], runtime: ax),
              children.count == 1, AXHelpers.getRole(children[0], runtime: ax) == kAXMenuRole as String else { return result(nil) }
        let menu = children[0]
        defer {
            if current(true), AXHelpers.getActionNames(menu, runtime: ax).contains(kAXCancelAction as String) {
                _ = AXHelpers.performAction(menu, kAXCancelAction, runtime: ax)
            }
        }
        func leaf() -> AXUIElement? {
            guard current(), case .success(let menus) = AXHelpers.childrenResult(tracks[0], runtime: ax),
                  menus.count == 1, CFEqual(menus[0], menu),
                  case .success(let items) = AXHelpers.childrenResult(menu, runtime: ax) else { return nil }
            let matches = items.filter { AXHelpers.getRole($0, runtime: ax) == kAXMenuItemRole as String
                && AXLocalePolicy.toggleHideViewMenuItem.matches(AXHelpers.getTitle($0, runtime: ax)) }
            guard matches.count == 1, AXHelpers.getAttribute(matches[0], kAXEnabledAttribute as String, runtime: ax) as Bool? == true,
                  AXHelpers.getActionNames(matches[0], runtime: ax).contains(kAXPressAction as String) else { return nil }
            return matches[0]
        }
        guard let target = leaf(), let repeated = leaf(), CFEqual(target, repeated), current(),
              OperationTraceContext.claimDeadlineEffect(operation) else { return result(nil, reason: "Track menu custody changed before the view action.") }
        attempted = true
        _ = AXHelpers.performAction(target, kAXPressAction, runtime: ax)
        var after: Bool?
        for _ in 0..<12 {
            await sleep(50_000_000)
            guard current() else { return result(nil, reason: "Project custody changed after the view action.") }
            if case .observed(let state) = observation() {
                after = state.shown
                if after == desired { return result(after) }
            }
        }
        return result(after, reason: "The requested hidden-track view was not observed after one action.")
    }
}
