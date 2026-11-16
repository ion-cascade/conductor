import ApplicationServices
import Foundation

/// Logic 13's Arrange Chord Track groups may contain multiple chord events.
/// Each bar-aligned event is corroborated by the group summary and its native chord item.
struct ProjectChordTrack {
    struct Event: Equatable {
        let startBar: Int
        let endBar: Int
        let chord: String

        var json: [String: Any] {
            ["start_bar": startBar, "end_bar": endBar, "duration_bars": endBar - startBar, "chord": chord]
        }

        var basicQuality: String? {
            let parts = chord.split(separator: " ")
            guard parts.count == 2, ["c", "d", "e", "f", "g", "a", "b"].contains(parts[0]),
                  ["major", "minor"].contains(parts[1]) else { return nil }
            return String(parts[1])
        }
    }

    let window: AXUIElement
    let lane: AXUIElement
    let projectPath: String
    let events: [Event]
    let items: [AXUIElement?]

    func holdsSameTrack(as other: Self) -> Bool {
        projectPath == other.projectPath && CFEqual(window, other.window) && CFEqual(lane, other.lane)
    }

    func canEdit(eventAt index: Int) -> Bool {
        items.indices.contains(index) && items[index] != nil
    }

    func ownsStoppedDocument(runtime: AXLogicProElements.Runtime = .production) -> Bool {
        guard ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime)
        else { return false }
        return URL(string: document)?.path == projectPath
    }

    func popover(runtime: AXLogicProElements.Runtime = .production) -> AXUIElement? {
        let nodes = Self.descendants(window, depth: 9, ax: runtime.ax)
            .filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXPopoverRole }
        return nodes.count == 1 ? nodes.first : nil
    }

    func chordText(in popover: AXUIElement, runtime: AXLogicProElements.Runtime = .production) -> String? {
        let ax = runtime.ax
        guard let field = Self.unique(Self.descendants(popover, depth: 6, ax: ax),
                                      role: kAXTextFieldRole, description: "Chord", ax: ax) else { return nil }
        return AXHelpers.getAttribute(field, kAXValueAttribute, runtime: ax)
    }

    func qualityControl(_ quality: String, in popover: AXUIElement,
                        runtime: AXLogicProElements.Runtime = .production) -> AXUIElement? {
        let ax = runtime.ax
        let controls = Self.descendants(popover, depth: 6, ax: ax)
        let matches = controls.filter {
            AXHelpers.getRole($0, runtime: ax) == kAXCheckBoxRole
                && AXHelpers.getDescription($0, runtime: ax)?.trimmingCharacters(in: .whitespaces) == quality.capitalized
        }
        return matches.count == 1 ? matches.first : nil
    }

    func open(eventAt index: Int, runtime: AXLogicProElements.Runtime = .production) -> Bool {
        guard popover(runtime: runtime) == nil, items.indices.contains(index), let item = items[index],
              let point = verifiedPoint(for: item, allowsGroupHit: true, runtime: runtime)
        else { return false }
        return AXMouseHelper.doubleClick(at: point)
    }

    func choose(_ button: AXUIElement, runtime: AXLogicProElements.Runtime = .production) -> Bool {
        guard let point = verifiedPoint(for: button, allowsGroupHit: false, runtime: runtime) else { return false }
        return AXMouseHelper.click(at: point)
    }

    private func verifiedPoint(for element: AXUIElement, allowsGroupHit: Bool,
                               runtime: AXLogicProElements.Runtime) -> CGPoint? {
        let ax = runtime.ax
        guard CGPreflightPostEventAccess(),
              ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              URL(string: document)?.path == projectPath,
              let value: AXValue = AXHelpers.getAttribute(element, "AXFrame", runtime: ax) else { return nil }
        var frame = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &frame), frame.width > 4, frame.height > 4 else { return nil }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        var observed: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &observed)
                == .success, let observed else { return nil }
        if CFEqual(observed, element) { return point }
        guard allowsGroupHit else { return nil }
        var ancestor = observed
        for _ in 0..<3 {
            guard let parent: AXUIElement = AXHelpers.getAttribute(ancestor, kAXParentAttribute, runtime: ax) else { break }
            if CFEqual(parent, element) { return point }
            ancestor = parent
        }
        // Logic's hit test can return the group instead of the item rendered inside it.
        guard let container: AXUIElement = AXHelpers.getAttribute(element, kAXParentAttribute, runtime: ax),
              AXHelpers.getDescription(container, runtime: ax) == "chord container",
              let group: AXUIElement = AXHelpers.getAttribute(container, kAXParentAttribute, runtime: ax),
              CFEqual(observed, group) || CFEqual(observed, container) else { return nil }
        let frames = items.compactMap { item -> CGRect? in
            guard let item, let value: AXValue = AXHelpers.getAttribute(item, "AXFrame", runtime: ax) else { return nil }
            var rectangle = CGRect.zero
            guard AXValueGetValue(value, .cgRect, &rectangle) else { return nil }
            return rectangle
        }
        if frames.count == items.count, frames.filter({ $0.contains(point) }).count == 1 { return point }
        return nil
    }

    static func read(runtime: AXLogicProElements.Runtime = .production) -> Self? {
        _ = runtime.onScreenWindowList()
        let ax = runtime.ax
        guard let pid = runtime.logicProPID(), runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true,
              case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              let url = URL(string: document), url.isFileURL, url.pathExtension.lowercased() == "logicx",
              let tracks = unique(children(window, ax: ax), role: kAXGroupRole, description: "Tracks", ax: ax),
              let lane = unique(descendants(tracks, depth: 7, ax: ax), role: kAXLayoutAreaRole,
                                description: "chord track", ax: ax),
              case .success(let groups) = AXHelpers.childrenResult(lane, runtime: ax), groups.count <= 16 else { return nil }
        var evidence: [(Event, AXUIElement?)] = []
        for group in groups {
            guard let entries = groupEvents(group, ax: ax), evidence.count + entries.count <= 32 else { return nil }
            evidence += entries
        }
        let pairs = evidence.sorted(by: { $0.0.startBar < $1.0.startBar })
        let observed = pairs.map(\.0)
        guard Set(observed.map(\.startBar)).count == observed.count,
              zip(observed, observed.dropFirst()).allSatisfy({ $0.0.endBar <= $0.1.startBar }),
              AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime) == .success(document) else { return nil }
        return Self(window: window, lane: lane, projectPath: url.path, events: observed, items: pairs.map(\.1))
    }

    private static func groupEvents(_ group: AXUIElement, ax: AXHelpers.Runtime) -> [(Event, AXUIElement?)]? {
        guard AXHelpers.getRole(group, runtime: ax) == kAXLayoutItemRole,
              let container = unique(children(group, ax: ax), role: kAXLayoutAreaRole,
                                     description: "chord container", ax: ax),
              case .success(let chords) = AXHelpers.childrenResult(container, runtime: ax),
              chords.count <= 32, let help = AXHelpers.getHelp(group, runtime: ax) else { return nil }
        let pattern = #"^Chord group starts at ([1-9][0-9]*) bars?\s+and ends at ([1-9][0-9]*) bars?\s*,\s*(.+?)\. Chord\."#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: help, range: NSRange(help.startIndex..., in: help)),
              let startRange = Range(match.range(at: 1), in: help),
              let endRange = Range(match.range(at: 2), in: help),
              let summary = Range(match.range(at: 3), in: help),
              let start = Int(help[startRange]), let end = Int(help[endRange]), end > start else { return nil }

        let descriptionPattern = #"^(.+?)\s+([1-9][0-9]*) bars?\s*$"#
        guard let positions = try? NSRegularExpression(pattern: descriptionPattern) else { return nil }
        let summaries = help[summary].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...32).contains(summaries.count) else { return nil }
        var visible: [String: AXUIElement] = [:]
        for chord in chords {
            guard AXHelpers.getRole(chord, runtime: ax) == kAXLayoutItemRole,
                  let description = AXHelpers.getDescription(chord, runtime: ax) else { return nil }
            let label = description.trimmingCharacters(in: .whitespaces)
            guard visible.updateValue(chord, forKey: label) == nil, summaries.contains(label) else { return nil }
        }
        var members: [(name: String, start: Int, item: AXUIElement?)] = []
        for label in summaries {
            guard let itemMatch = positions.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                  let chordName = Range(itemMatch.range(at: 1), in: label),
                  let position = Range(itemMatch.range(at: 2), in: label),
                  let bar = Int(label[position]) else { return nil }
            let editable = summaries.count == 1 ? (visible[label] ?? group) : nil
            members.append((String(label[chordName]), bar, editable))
        }
        guard members.first?.start == start, let last = members.last, last.start < end,
              zip(members, members.dropFirst()).allSatisfy({ $0.0.start < $0.1.start }) else { return nil }
        return members.indices.map { index in
            let member = members[index]
            let next = index + 1 < members.count ? members[index + 1].start : end
            return (Event(startBar: member.start, endBar: next, chord: member.name), member.item)
        }
    }

    private static func children(_ node: AXUIElement, ax: AXHelpers.Runtime) -> [AXUIElement] {
        guard case .success(let children) = AXHelpers.childrenResult(node, runtime: ax) else { return [] }
        return children
    }

    private static func descendants(_ node: AXUIElement, depth: Int, ax: AXHelpers.Runtime) -> [AXUIElement] {
        guard depth > 0 else { return [node] }
        if AXHelpers.getRole(node, runtime: ax) == kAXLayoutAreaRole,
           AXHelpers.getDescription(node, runtime: ax) != "Tracks time ruler" { return [node] }
        let childNodes = children(node, ax: ax)
        guard childNodes.count <= 40 else { return [node] }
        return [node] + childNodes.flatMap { descendants($0, depth: depth - 1, ax: ax) }
    }

    private static func unique(_ nodes: [AXUIElement], role: String, description: String,
                               ax: AXHelpers.Runtime) -> AXUIElement? {
        let matches = nodes.filter {
            AXHelpers.getRole($0, runtime: ax) == role && AXHelpers.getDescription($0, runtime: ax) == description
        }
        return matches.count == 1 ? matches.first : nil
    }
}
