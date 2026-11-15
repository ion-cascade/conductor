import ApplicationServices
import Foundation

enum Logic13AutomationLane: String {
    case volume
    case pan

    var label: String { self == .volume ? "Volume" : "Pan" }
    var unit: String { self == .volume ? "logic_fader_value" : "logic_pan_value" }

    func allows(_ value: Int) -> Bool { (0...127).contains(value) }
}

extension AccessibilityChannel {
    static func defaultTrackAutomation(
        params: [String: String],
        lane: Logic13AutomationLane, edit: Bool,
        runtime logic: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let operation = edit ? "track.set_\(lane.rawValue)_automation_point" : "track.get_\(lane.rawValue)_automation"
        func unavailable(_ stage: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "Open the Track Automation Event List for the referenced track and expose its \(lane.label) events.",
                extras: ["operation": operation, "readback_stage": stage, "write_attempted": false]))
        }
        guard let binding = AXTrackBinding.current,
              let index = binding.currentIndex(),
              let app = AXLogicProElements.appRoot(runtime: logic),
              let pid = logic.logicProPID(), logic.focusedApplicationPID() == pid,
              case .success(.some(let trackName)) = AXValueExtractors.extractTrackNameResult(
                from: binding.header, runtime: logic.ax),
              let arrangeTitle = AXHelpers.getTitle(binding.window, runtime: logic.ax),
              arrangeTitle.hasSuffix(" - Tracks"),
              let editor: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
              !CFEqual(editor, binding.window) else { return unavailable("track_editor_scope") }
        let read = Logic13AutomationEventList(app: app, editor: editor, arrange: binding.window,
            title: String(arrangeTitle.dropLast(" - Tracks".count)),
            trackName: trackName, runtime: logic.ax)
        func current() -> Bool {
            guard !Task.isCancelled, binding.currentIndex() == index,
                  case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(
                    in: binding.window, runtime: logic),
                  headers.indices.contains(index), CFEqual(headers[index], binding.header) else { return false }
            var nameMatches = 0
            for (offset, header) in headers.enumerated() {
                guard case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(
                    from: header, runtime: logic.ax),
                    AXValueExtractors.extractSelectedState(header, runtime: logic.ax) == (offset == index) else { return false }
                if name == trackName { nameMatches += 1 }
            }
            return nameMatches == 1 && logic.focusedApplicationPID() == pid && read.ownsEditor()
        }
        func ready() -> Bool {
            current() && (lane != .pan || automationLaneIsReady(.pan, header: binding.header, runtime: logic.ax))
        }
        guard ready() else { return unavailable("editor_ownership") }
        var stage = "event_table"
        guard let points = read.points(onRefusal: { stage = $0 }) else { return unavailable(stage) }
        guard ready() else { return unavailable("editor_ownership_after_read") }
        if edit {
            return await changeTrackAutomationPoint(params: params, points: points, lane: lane,
                editor: read, current: ready, logic: logic, operation: operation)
        }
        let lanePoints = points.filter { $0.lane == lane }
        return .success(HonestContract.encodeStateA(extras: [
            "operation": operation,
            "lane": lane.rawValue,
            "unit": lane.unit,
            "position_format": "bar.beat.division.tick",
            "track": index,
            "points": lanePoints.map(\.evidence),
            "selected_positions": lanePoints.filter(\.selected).map(\.position),
            "verify_source": "ax_automation_event_list",
            "write_attempted": false,
        ]))
    }

    static func createTrackAutomation(
        params: [String: String], lane: Logic13AutomationLane, logic: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let operation = lane == .pan ? "track.create_pan_automation_point" : "track.create_volume_automation_at_region_borders"
        let ax = logic.ax
        func refuse(_ stage: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: .readbackUnavailable,
                hint: lane == .pan
                    ? "Select the track in Arrange, show its empty absolute Pan lane in Read mode and set the playhead to the requested position with the full Beats display visible."
                    : "In Arrange, show and enable the Volume lane in Read mode and select exactly one region on the referenced track. The lane must be empty.",
                extras: ["operation": operation, "readback_stage": stage, "write_attempted": false]))
        }
        func uncertain(_ stage: String, cleanup: Bool) -> ChannelResult {
            .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: [
                "operation": operation, "readback_stage": stage, "write_attempted": true,
                "editor_close_observed": cleanup, "safe_to_retry": false, "effect_unknown": true,
            ]))
        }
        let startKey = lane == .pan ? "initial_position" : "start"
        let endKey = lane == .pan ? "position" : "end"
        guard let start = params[startKey], let end = params[endKey],
              let startFields = ProjectBounceRange.position(start), let endFields = ProjectBounceRange.position(end),
              startFields.lexicographicallyPrecedes(endFields) || (lane == .pan && start == end) else {
            return .error(HonestContract.encodeStateC(error: .invalidParams,
                hint: "Supply ordered musical positions in bar.beat.division.tick format.",
                extras: ["operation": operation, "write_attempted": false]))
        }
        guard ProcessInfo.processInfo.environment["LOGIC_MCP_LOGIC13_TRACKS"] == "1",
              let binding = AXTrackBinding.current, let index = binding.currentIndex(),
              let pid = logic.logicProPID(), let app = AXLogicProElements.appRoot(runtime: logic),
              let windowTitle = AXHelpers.getTitle(binding.window, runtime: ax), windowTitle.hasSuffix(" - Tracks"),
              case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(from: binding.header, runtime: ax)
        else { return refuse("track_scope") }

        func nativeWindows() -> [AXUIElement]? {
            let observed: [AXUIElement]? = AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: ax)
            return observed?.filter { AXHelpers.getRole($0, runtime: ax) != kAXHelpTagRole as String }
        }
        func ownsArrange() -> Bool {
            guard !Task.isCancelled, logic.focusedApplicationPID() == pid,
                  binding.currentIndex() == index,
                  let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: ax),
                  CFEqual(focused, binding.window), let windows = nativeWindows(),
                  windows.count == 1, CFEqual(windows[0], binding.window),
                  let transport = try? AXLogicProElements.observedTransportActivity(in: binding.window, runtime: logic, checking: {}),
                  !transport.isPlaying, !transport.isRecording else { return false }
            return true
        }
        func automationTarget() -> AXUIElement? {
            guard case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: binding.window, runtime: logic),
                  headers.indices.contains(index), CFEqual(headers[index], binding.header) else { return nil }
            var matches = 0
            for (offset, header) in headers.enumerated() {
                guard case .success(.some(let candidate)) = AXValueExtractors.extractTrackNameResult(from: header, runtime: ax),
                      AXValueExtractors.extractSelectedState(header, runtime: ax) == (offset == index) else { return nil }
                if candidate == name { matches += 1 }
            }
            guard matches == 1, automationLaneIsReady(lane, header: binding.header, runtime: ax) else { return nil }
            if lane == .pan {
                guard let controlBar = AXLogicProElements.logic13ControlBarContainer(in: binding.window, runtime: ax),
                      TransportDispatcher.completeObservedMusicalPosition(
                        AXValueExtractors.extractTransportState(from: controlBar, runtime: ax)
                      )?.value == end else { return nil }
                return binding.header
            }
            guard let content = AXLogicProElements.logic13TrackContent(in: binding.window, runtime: logic),
                  let items = AXLogicProElements.logic13RegionItems(in: content, runtime: ax) else { return nil }
            var selected: [AXUIElement] = []
            for item in items {
                guard let isSelected: Bool = AXHelpers.getAttribute(item, kAXSelectedAttribute as String, runtime: ax) else { return nil }
                if isSelected { selected.append(item) }
            }
            guard selected.count == 1, let region = selected.first,
                  AXLogicProElements.logic13RegionTrackIndex(region, in: content, headers: headers, runtime: ax) == index,
                  let help = AXHelpers.getHelp(region, runtime: ax),
                  let bounds = ArrangeRegionBounds.read(from: help), bounds.start == start, bounds.end == end else { return nil }
            return region
        }
        func openEditor() async -> Logic13AutomationEventList? {
            guard ownsArrange(), CGPreflightPostEventAccess(),
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: 14, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 14, keyDown: false),
                  OperationTraceContext.claimDeadlineEffect("track_volume_automation_editor") else { return nil }
            down.flags = [.maskControl, .maskCommand]
            up.flags = down.flags
            down.postToPid(pid)
            up.postToPid(pid)
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(65))
                guard !Task.isCancelled, binding.currentIndex() == index,
                      logic.focusedApplicationPID() == pid, let windows = nativeWindows(), windows.count <= 2 else { return nil }
                if let editor = windows.first(where: { !CFEqual($0, binding.window) }) {
                    let list = Logic13AutomationEventList(app: app, editor: editor, arrange: binding.window,
                        title: String(windowTitle.dropLast(" - Tracks".count)), trackName: name, runtime: ax)
                    if list.ownsEditor() { return list }
                }
            }
            return nil
        }
        func closeEditor(_ list: Logic13AutomationEventList) async -> Bool {
            guard list.ownsEditor(), logic.focusedApplicationPID() == pid,
                  binding.currentIndex() == index,
                  let button: AXUIElement = AXHelpers.getAttribute(list.editor, kAXCloseButtonAttribute as String, runtime: ax)
            else { return false }
            _ = AXHelpers.performAction(button, kAXPressAction, runtime: ax)
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(50))
                if ownsArrange() { return true }
            }
            return false
        }

        guard ownsArrange() else { return refuse("arrange_scope") }
        guard let target = automationTarget() else { return refuse("native_lane_or_position") }
        guard let beforeEditor = await openEditor() else { return refuse("event_editor") }
        let before = beforeEditor.points()
        let beforeClosed = await closeEditor(beforeEditor)
        guard beforeClosed, let before, !before.contains(where: { $0.lane == lane }) else {
            return refuse("empty_lane_required")
        }

        // The visible-parameter command seeds the first Pan point and Logic's initial anchor.
        let command = ["Mix", "Create Track Automation", lane == .volume
            ? "Create 2 Automation Points at Region Borders" : "Create 1 Automation Point for Visible Parameter"]
        guard let item = AXLogicProElements.menuItem(path: command, runtime: logic),
              (AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: ax) as Bool?) == true,
              let current = automationTarget(), CFEqual(current, target), ownsArrange(),
              OperationTraceContext.claimDeadlineEffect("track_volume_automation_create") else { return refuse("region_or_command_changed") }
        _ = AXHelpers.performAction(item, kAXPressAction, runtime: ax)
        try? await Task.sleep(for: .milliseconds(250))
        guard let afterEditor = await openEditor() else { return uncertain("editor_after_create", cleanup: false) }
        let after = afterEditor.points()
        let closed = await closeEditor(afterEditor)
        let peers = after?.filter { $0.lane != lane }
        guard let after = after?.filter({ $0.lane == lane }), let peers, sameAutomationValues(before, peers),
              let first = after.first, after.allSatisfy({ $0.value == first.value }), closed else {
            return uncertain("points_after_create", cleanup: closed)
        }
        let matchesBorders = lane == .pan
            ? after.map(\.position) == (start == end ? [end] : [start, end])
            : after.count == 4 && after[1].position == start && after[3].position == end
        guard matchesBorders else { return uncertain("positions_after_create", cleanup: closed) }
        return .success(HonestContract.encodeStateA(extras: [
            "operation": operation, "lane": lane.rawValue, "unit": lane.unit,
            "position_format": "bar.beat.division.tick", "write_attempted": true,
            "points": after.map(\.evidence),
            "verify_source": "ax_automation_event_list", "editor_close_observed": true,
        ]))
    }

    private static func sameAutomationValues(
        _ left: [Logic13AutomationEventList.Point], _ right: [Logic13AutomationEventList.Point]
    ) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy {
            $0.lane == $1.lane && $0.position == $1.position && $0.value == $1.value
        }
    }

    private static func automationLaneIsReady(
        _ lane: Logic13AutomationLane, header: AXUIElement, runtime: AXHelpers.Runtime
    ) -> Bool {
        guard case .success(let controls) = AXHelpers.childrenResult(header, runtime: runtime) else { return false }
        func value<T>(_ label: String, role: String) -> T? {
            let matches = controls.filter {
                AXHelpers.getRole($0, runtime: runtime) == role
                    && AXHelpers.getDescription($0, runtime: runtime) == label
            }
            guard matches.count == 1 else { return nil }
            return AXHelpers.getAttribute(matches[0], kAXValueAttribute as String, runtime: runtime)
        }
        guard (value("Automation Parameter", role: kAXPopUpButtonRole) as String?) == lane.label,
              (value("Automation Mode", role: kAXPopUpButtonRole) as String?) == "Read" else { return false }
        let enableControls = controls.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXCheckBoxRole
                && AXHelpers.getDescription($0, runtime: runtime) == "Enable Automation"
        }
        if lane == .pan {
            // The native header has a Track/Region button. An empty absolute Pan
            // lane can lack a separate Enable Automation checkbox.
            guard controls.filter({
                AXHelpers.getRole($0, runtime: runtime) == kAXButtonRole
                    && AXHelpers.getDescription($0, runtime: runtime) == "Track"
            }).count == 1 else { return false }
            if enableControls.isEmpty { return true }
        }
        guard enableControls.count == 1 else { return false }
        return (AXHelpers.getAttribute(enableControls[0], kAXValueAttribute, runtime: runtime) as Int?) == 1
    }

    private static func changeTrackAutomationPoint(
        params: [String: String], points: [Logic13AutomationEventList.Point], lane: Logic13AutomationLane,
        editor: Logic13AutomationEventList, current: () -> Bool,
        logic: AXLogicProElements.Runtime, operation: String
    ) async -> ChannelResult {
        func refusal(_ error: HonestContract.FailureError, _ hint: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: error, hint: hint,
                extras: ["operation": operation, "write_attempted": false]))
        }
        guard let position = params["position"],
              let expected = params["expected_current"].flatMap(Int.init),
              let requested = params["value"].flatMap(Int.init),
              lane.allows(expected), lane.allows(requested) else {
            return refusal(.invalidParams, "Supply an observed musical position, expected value and requested \(lane.label) value.")
        }
        let matchingIndices = points.indices.filter { points[$0].lane == lane && points[$0].position == position }
        guard matchingIndices.count == 1, let index = matchingIndices.first, points[index].value == expected else {
            return refusal(.staleSnapshot, "The position and expected value do not identify one current \(lane.label) event.")
        }
        func affectedIndices(_ rows: [Logic13AutomationEventList.Point]) -> [Int] {
            rows[index].selected ? rows.indices.filter { rows[$0].selected } : [index]
        }
        let affected = affectedIndices(points)
        var authorizedPositions = Set([position])
        if let linkedPosition = params["linked_position"] {
            guard authorizedPositions.insert(linkedPosition).inserted else {
                return refusal(.invalidParams, "The linked position must differ from the primary position.")
            }
        }
        guard affected.count == authorizedPositions.count,
              Set(affected.map { points[$0].position }) == authorizedPositions,
              affected.allSatisfy({ points[$0].lane == lane && points[$0].value == expected }) else {
            return refusal(.staleSnapshot, "The selected \(lane.label) points and their values do not match the requested edit. Read the lane again.")
        }
        guard (requested - expected).isMultiple(of: 10) else {
            return refusal(.invalidParams, "This editor supports changes in steps of 10 native \(lane.label) units.")
        }
        func stopped() -> Bool {
            guard let transport = try? AXLogicProElements.observedTransportActivity(
                in: editor.arrange, runtime: logic, checking: {}) else { return false }
            return !transport.isPlaying && !transport.isRecording
        }
        func result(_ value: Int, attempted: Bool) -> [String: Any] {
            ["operation": operation, "lane": lane.rawValue, "position": position, "unit": lane.unit,
             "before": expected, "observed": value, "requested": requested,
             "affected_positions": affected.map { points[$0].position },
             "changed": value != expected, "write_attempted": attempted]
        }
        func uncertain(_ value: Int, stage: String, actual: Int? = nil, actionAccepted: Bool? = nil) -> ChannelResult {
            var evidence = result(value, attempted: true)
            evidence.removeValue(forKey: "observed")
            evidence["last_verified_value"] = value
            evidence["safe_to_retry"] = false
            evidence["effect_unknown"] = true
            evidence["readback_stage"] = stage
            evidence["native_action_accepted"] = actionAccepted
            evidence["actual_value"] = actual
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
        }
        guard stopped(), current() else {
            return refusal(.readbackUnavailable, "Stop playback and keep the referenced Track Automation Event List focused.")
        }
        let step = requested > expected ? 10 : -10
        let action = step > 0 ? kAXIncrementAction : kAXDecrementAction
        var observed = expected
        var displayed = points[index].displayed
        var attempted = false
        func matches(_ fresh: [Logic13AutomationEventList.Point], value: Int) -> Bool {
            guard points.count == fresh.count else { return false }
            return zip(points, fresh).enumerated().allSatisfy { pair in
                let (original, live) = pair.element
                return original.lane == live.lane && original.position == live.position
                    && (lane == .pan || original.selected == live.selected)
                    && (affected.contains(pair.offset) ? value : original.value) == live.value
            }
        }
        while observed != requested {
            guard stopped(), current(), let fresh = editor.points(), matches(fresh, value: observed),
                  affectedIndices(fresh) == affected, editor.ownsEditor(),
                  OperationTraceContext.claimDeadlineEffect("track_volume_automation_edit") else {
                return attempted ? uncertain(observed, stage: "before_next_step")
                    : refusal(.staleSnapshot, "The native \(lane.label) event changed before the edit.")
            }
            attempted = true
            let applied = AXHelpers.performAction(fresh[index].slider, action, runtime: logic.ax)
            let wanted = observed + step
            var lastActual: Int?
            var readbackStage = "event_value_after_step"
            for _ in 0..<5 {
                do { try await Task.sleep(for: .milliseconds(70)) }
                catch { return uncertain(observed, stage: "cancelled_after_step", actionAccepted: applied) }
                guard current() else {
                    return uncertain(observed, stage: "ownership_after_step", actionAccepted: applied)
                }
                guard let after = editor.points(onRefusal: { readbackStage = $0 }) else { continue }
                if after.indices.contains(index), after[index].position == position {
                    lastActual = after[index].value
                }
                if matches(after, value: wanted), editor.ownsEditor() {
                    observed = wanted
                    displayed = after[index].displayed
                    break
                }
                if !matches(after, value: observed) { break }
            }
            guard observed == wanted else {
                return uncertain(observed, stage: readbackStage, actual: lastActual, actionAccepted: applied)
            }
        }
        var evidence = result(observed, attempted: attempted)
        evidence["displayed_value"] = displayed
        evidence["verify_source"] = "ax_automation_event_list"
        return .success(HonestContract.encodeStateA(extras: evidence))
    }
}

private struct Logic13AutomationEventList {
    struct Point {
        let lane: Logic13AutomationLane
        let position: String
        let value: Int
        let displayed: String?
        let selected: Bool
        let slider: AXUIElement

        var evidence: [String: Any] {
            var fields: [String: Any] = ["position": position, "value": value]
            fields["displayed_value"] = displayed
            return fields
        }
    }

    let app: AXUIElement
    let editor: AXUIElement
    let arrange: AXUIElement
    let title: String
    let trackName: String
    let runtime: AXHelpers.Runtime

    func ownsEditor() -> Bool {
        let path = "Track Automation Root Folder:" + trackName
        return AXHelpers.getTitle(editor, runtime: runtime) == title + " - " + path + " - Event List"
            && AXHelpers.getRole(editor, runtime: runtime) == kAXWindowRole as String
            && exactWindowPair()
    }

    private func exactWindowPair() -> Bool {
        guard !Task.isCancelled,
              let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime),
              CFEqual(focused, editor),
              let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: runtime) else { return false }
        let documents = windows.filter { AXHelpers.getRole($0, runtime: runtime) != kAXHelpTagRole as String }
        return documents.count == 2 && documents.contains(where: { CFEqual($0, arrange) })
            && documents.contains(where: { CFEqual($0, editor) })
    }

    func points(onRefusal: (String) -> Void = { _ in }) -> [Point]? {
        guard ownsEditor(),
              case .success(let windowChildren) = AXHelpers.childrenResult(editor, runtime: runtime),
              let event = unique("Event", role: kAXGroupRole as String, in: windowChildren),
              case .success(let eventChildren) = AXHelpers.childrenResult(event, runtime: runtime),
              let path = unique("Region Path", role: kAXStaticTextRole as String, in: eventChildren),
              (AXHelpers.getAttribute(path, kAXValueAttribute as String, runtime: runtime) as String?)
                == "Track Automation Root Folder:" + trackName,
              let countLabel = unique("Number of Items", role: kAXStaticTextRole as String, in: eventChildren),
              let countText: String = AXHelpers.getAttribute(countLabel, kAXValueAttribute as String, runtime: runtime),
              let count = eventCount(countText),
              let contents = unique("Event", role: kAXGroupRole as String, in: eventChildren),
              case .success(let contentChildren) = AXHelpers.childrenResult(contents, runtime: runtime),
              let scroll = uniqueRole(kAXScrollAreaRole as String, in: contentChildren),
              case .success(let scrollChildren) = AXHelpers.childrenResult(scroll, runtime: runtime),
              let table = uniqueRole(kAXTableRole as String, in: scrollChildren),
              case .success(let tableChildren) = AXHelpers.childrenResult(table, runtime: runtime) else {
            onRefusal("event_table")
            return nil
        }

        let columns = tableChildren.filter { AXHelpers.getRole($0, runtime: runtime) == kAXColumnRole as String }
        guard columns.map({ column -> String in
            AXHelpers.getAttribute(column, kAXIdentifierAttribute as String, runtime: runtime) ?? ""
        })
                == ["Lock", "Muted", "Position", "Status", "Ch", "Num", "Val", "Length"] else {
            onRefusal("event_columns")
            return nil
        }
        let rows = tableChildren.filter { AXHelpers.getRole($0, runtime: runtime) == kAXRowRole as String }
        guard rows.count == count else { onRefusal("event_row_count"); return nil }
        var points: [Point] = []
        for row in rows {
            guard !Task.isCancelled,
                  case .success(let cells) = AXHelpers.childrenResult(row, runtime: runtime),
                  cells.count == columns.count,
                  unique("Fader", role: kAXCellRole as String, in: AXHelpers.getChildren(cells[3], runtime: runtime)) != nil
            else { onRefusal("event_identity"); return nil }
            let eventLabels = AXHelpers.getChildren(cells[7], runtime: runtime)
            let lanes: [Logic13AutomationLane] = [.volume, .pan]
            let matches = lanes.filter { unique($0.label, role: kAXCellRole as String, in: eventLabels) != nil }
            guard matches.count == 1, let lane = matches.first else { onRefusal("event_lane"); return nil }
            guard let positionGroup = hitInCell(cells[2], column: 2, role: kAXGroupRole as String),
                  let position = AXHelpers.getDescription(positionGroup, runtime: runtime).flatMap(Self.position)
            else { onRefusal("event_position"); return nil }
            guard let slider = hitInCell(cells[6], column: 6, role: kAXSliderRole as String),
                  let value: Int = AXHelpers.getAttribute(slider, kAXValueAttribute as String, runtime: runtime),
                  let selected: Bool = AXHelpers.getAttribute(row, kAXSelectedAttribute as String, runtime: runtime),
                  lane.allows(value) else { onRefusal("event_value"); return nil }
            var displayed: String?
            if lane == .pan {
                guard let controller = hitInCell(cells[5], column: 5, role: kAXSliderRole),
                      (AXHelpers.getAttribute(controller, kAXValueAttribute, runtime: runtime) as Int?) == 10,
                      let text = AXValueExtractors.extractValueDescription(slider, runtime: runtime),
                      !text.isEmpty else { onRefusal("pan_event_value"); return nil }
                displayed = text
            }
            points.append(Point(lane: lane, position: position, value: value, displayed: displayed,
                                selected: selected, slider: slider))
        }
        return points
    }

    private func eventCount(_ text: String) -> Int? {
        let pieces = text.split(separator: " ")
        guard pieces.count == 2, ["Event", "Events"].contains(pieces[1]),
              let count = Int(pieces[0]), (0...64).contains(count) else { return nil }
        return count
    }

    private func unique(_ description: String, role: String, in elements: [AXUIElement]) -> AXUIElement? {
        let matches = elements.filter {
            AXHelpers.getRole($0, runtime: runtime) == role
                && AXHelpers.getDescription($0, runtime: runtime) == description
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func uniqueRole(_ role: String, in elements: [AXUIElement]) -> AXUIElement? {
        let matches = elements.filter { AXHelpers.getRole($0, runtime: runtime) == role }
        return matches.count == 1 ? matches.first : nil
    }

    private func hitInCell(_ cell: AXUIElement, column: Int, role: String) -> AXUIElement? {
        guard AXHelpers.getRole(cell, runtime: runtime) == kAXCellRole as String,
              let rawColumn: AXValue = AXHelpers.getAttribute(cell, "AXColumnIndexRange", runtime: runtime),
              let origin = AXHelpers.getPosition(cell, runtime: runtime),
              let size = AXHelpers.getSize(cell, runtime: runtime),
              origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, let hit = runtime.elementAtPosition else { return nil }
        var observed = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rawColumn, .cfRange, &observed),
              observed.location == column, observed.length == 1,
              case .success(.some(let element)) = hit(AXUIElementCreateSystemWide(), CGPoint(
                x: origin.x + size.width / 2, y: origin.y + size.height / 2)),
              AXHelpers.getRole(element, runtime: runtime) == role,
              let parent: AXUIElement = AXHelpers.getAttribute(element, kAXParentAttribute as String, runtime: runtime),
              CFEqual(parent, cell) else { return nil }
        return element
    }

    private static func position(_ description: String) -> String? {
        var label = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.hasSuffix(".") { label.removeLast() }
        let fields = label.split(whereSeparator: \.isWhitespace)
        let components = fields.compactMap { Int($0) }
        guard fields.count == 4, components.count == 4,
              components.dropFirst().allSatisfy({ $0 > 0 }) else { return nil }
        return components.map(String.init).joined(separator: ".")
    }
}
