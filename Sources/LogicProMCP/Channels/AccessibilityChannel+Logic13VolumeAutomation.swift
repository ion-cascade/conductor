import ApplicationServices
import Foundation

extension AccessibilityChannel {
    static func defaultTrackVolumeAutomation(
        params: [String: String],
        edit: Bool,
        runtime logic: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let operation = edit ? "track.set_volume_automation_point" : "track.get_volume_automation"
        func unavailable() -> ChannelResult {
            .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "Open the Track Automation Event List for the referenced track and expose its Volume events.",
                extras: ["operation": operation, "write_attempted": false]))
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
              !CFEqual(editor, binding.window) else { return unavailable() }
        let read = Logic13VolumeEventList(app: app, editor: editor, arrange: binding.window,
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
        guard let points = read.points(), current() else { return unavailable() }
        if edit {
            return await changeTrackVolumePoint(params: params, points: points,
                editor: read, current: current, logic: logic, operation: operation)
        }
        return .success(HonestContract.encodeStateA(extras: [
            "operation": operation,
            "lane": "volume",
            "unit": "logic_fader_value",
            "position_format": "bar.beat.division.tick",
            "track": index,
            "points": points.map { point -> [String: Any] in
                ["position": point.position, "value": point.value]
            },
            "verify_source": "ax_automation_event_list",
            "write_attempted": false,
        ]))
    }

    private static func changeTrackVolumePoint(
        params: [String: String], points: [Logic13VolumeEventList.Point],
        editor: Logic13VolumeEventList, current: () -> Bool,
        logic: AXLogicProElements.Runtime, operation: String
    ) async -> ChannelResult {
        func refusal(_ error: HonestContract.FailureError, _ hint: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: error, hint: hint,
                extras: ["operation": operation, "write_attempted": false]))
        }
        guard let position = params["position"],
              let expected = params["expected_current"].flatMap(Int.init),
              let requested = params["value"].flatMap(Int.init),
              (0...127).contains(expected), (0...127).contains(requested) else {
            return refusal(.invalidParams, "Supply an observed musical position, expected value and requested Logic fader value.")
        }
        let matches = points.indices.filter { points[$0].position == position }
        guard matches.count == 1, let index = matches.first, points[index].value == expected else {
            return refusal(.staleSnapshot, "The position and expected value do not identify one current Volume event.")
        }
        guard (requested - expected).isMultiple(of: 10) else {
            return refusal(.invalidParams, "This editor supports changes in steps of 10 Logic fader units.")
        }
        func stopped() -> Bool {
            guard let transport = try? AXLogicProElements.observedTransportActivity(
                in: editor.arrange, runtime: logic, checking: {}) else { return false }
            return !transport.isPlaying && !transport.isRecording
        }
        func result(_ value: Int, attempted: Bool) -> [String: Any] {
            ["operation": operation, "lane": "volume", "position": position, "unit": "logic_fader_value",
             "before": expected, "observed": value, "requested": requested,
             "changed": value != expected, "write_attempted": attempted]
        }
        func uncertain(_ value: Int) -> ChannelResult {
            var evidence = result(value, attempted: true)
            evidence.removeValue(forKey: "observed")
            evidence["last_verified_value"] = value
            evidence["safe_to_retry"] = false
            evidence["effect_unknown"] = true
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
        }
        guard stopped(), current() else {
            return refusal(.readbackUnavailable, "Stop playback and keep the referenced Track Automation Event List focused.")
        }
        let control = points[index].slider
        let step = requested > expected ? 10 : -10
        let action = step > 0 ? kAXIncrementAction : kAXDecrementAction
        var observed = expected
        var attempted = false
        func matches(_ value: Int) -> Bool {
            guard let fresh = editor.points(), points.count == fresh.count else { return false }
            return zip(points, fresh).enumerated().allSatisfy { pair in
                let (original, live) = pair.element
                return original.position == live.position
                    && (pair.offset == index ? value : original.value) == live.value
                    && CFEqual(original.slider, live.slider)
            }
        }
        while observed != requested {
            guard matches(observed), stopped(), current(),
                  OperationTraceContext.claimDeadlineEffect("track_volume_automation_edit") else {
                return attempted ? uncertain(observed)
                    : refusal(.staleSnapshot, "The native Volume event changed before the edit.")
            }
            attempted = true
            _ = AXHelpers.performAction(control, action, runtime: logic.ax)
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return uncertain(observed) }
            let wanted = observed + step
            guard matches(wanted), current() else { return uncertain(observed) }
            observed = wanted
        }
        var evidence = result(observed, attempted: attempted)
        evidence["verify_source"] = "ax_automation_event_list"
        return .success(HonestContract.encodeStateA(extras: evidence))
    }
}

private struct Logic13VolumeEventList {
    struct Point {
        let position: String
        let value: Int
        let slider: AXUIElement
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

    func points() -> [Point]? {
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
              case .success(let tableChildren) = AXHelpers.childrenResult(table, runtime: runtime) else { return nil }

        let columns = tableChildren.filter { AXHelpers.getRole($0, runtime: runtime) == kAXColumnRole as String }
        guard columns.map({ AXHelpers.getDescription($0, runtime: runtime) ?? "" })
                == ["Lock", "Muted", "Position", "Status", "Ch", "Num", "Val", "Length"] else { return nil }
        let rows = tableChildren.filter { AXHelpers.getRole($0, runtime: runtime) == kAXRowRole as String }
        guard rows.count == count else { return nil }
        var points: [Point] = []
        for row in rows {
            guard !Task.isCancelled,
                  case .success(let cells) = AXHelpers.childrenResult(row, runtime: runtime),
                  cells.count == columns.count,
                  unique("Fader", role: kAXCellRole as String, in: AXHelpers.getChildren(cells[3], runtime: runtime)) != nil,
                  unique("Volume", role: kAXCellRole as String, in: AXHelpers.getChildren(cells[7], runtime: runtime)) != nil,
                  let positionGroup = hitInCell(cells[2], column: 2, role: kAXGroupRole as String),
                  let position = AXHelpers.getDescription(positionGroup, runtime: runtime).flatMap(Self.position),
                  let slider = hitInCell(cells[6], column: 6, role: kAXSliderRole as String),
                  let value: Int = AXHelpers.getAttribute(slider, kAXValueAttribute as String, runtime: runtime),
                  (0...127).contains(value) else { return nil }
            points.append(Point(position: position, value: value, slider: slider))
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
              case .success(.some(let element)) = hit(app, CGPoint(
                x: origin.x + size.width / 2, y: origin.y + size.height / 2)),
              AXHelpers.getRole(element, runtime: runtime) == role,
              let parent: AXUIElement = AXHelpers.getAttribute(element, kAXParentAttribute as String, runtime: runtime),
              CFEqual(parent, cell) else { return nil }
        return element
    }

    private static func position(_ description: String) -> String? {
        let fields = description.split(whereSeparator: \.isWhitespace)
        let components = fields.compactMap { Int($0) }
        guard fields.count == 4, components.count == 4,
              components.dropFirst().allSatisfy({ $0 > 0 }) else { return nil }
        return components.map(String.init).joined(separator: ".")
    }
}
