import ApplicationServices
import Foundation

extension AccessibilityChannel {
    static func defaultReadTrackVolumeAutomation(
        runtime logic: AXLogicProElements.Runtime
    ) -> ChannelResult {
        let operation = "track.get_volume_automation"
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
        guard let points = read.points(), binding.currentIndex() == index,
              logic.focusedApplicationPID() == pid, read.ownsEditor() else { return unavailable() }
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
}

private struct Logic13VolumeEventList {
    struct Point {
        let position: String
        let value: Int
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
            points.append(Point(position: position, value: value))
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
