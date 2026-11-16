import ApplicationServices
import Foundation

/// The Keyboard Player evidence comes from both the selected Arrange region and
/// its live editor. A generic Session Player track label alone is insufficient.
struct ProjectSessionPlayer {
    let window: AXUIElement
    let region: AXUIElement
    let editor: AXUIElement
    let chordsButton: AXUIElement
    let address: [String: String]
    let complexity: Int
    let intensity: Int
    let range: ClosedRange<Int>
    let chordSource: ChordSource

    static func read(runtime: AXLogicProElements.Runtime = .production) -> Self? {
        _ = runtime.onScreenWindowList()
        let ax = runtime.ax
        guard let pid = runtime.logicProPID(), runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true,
              case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              let url = URL(string: document), url.isFileURL, url.pathExtension.lowercased() == "logicx",
              let content = AXLogicProElements.logic13TrackContent(in: window, runtime: runtime),
              let region = AXLogicProElements.logic13SelectedRegion(in: content, runtime: ax),
              let name = AXHelpers.getDescription(region, runtime: ax), !name.isEmpty,
              let help = AXHelpers.getHelp(region, runtime: ax),
              help.contains(", Session Player region."),
              let position = help.range(of: #"^Region starts at [1-9][0-9]* bars?\s+and ends at [1-9][0-9]* bars?(?=\s*,)"#,
                                        options: .regularExpression),
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              let index = AXLogicProElements.logic13RegionTrackIndex(region, in: content, headers: headers, runtime: ax),
              let track = AXHelpers.getDescription(headers[index], runtime: ax),
              let inspector = only(children(window, ax: ax), role: kAXGroupRole, description: "Inspector", ax: ax),
              let source = pitchSource(in: inspector, ax: ax),
              let editor = only(children(window, ax: ax), role: kAXGroupRole, description: "Session Player", ax: ax)
        else { return nil }

        let location = String(help[position])
        guard let regionLane: AXUIElement = AXHelpers.getAttribute(region, kAXParentAttribute, runtime: ax),
              case .success(let peers) = AXHelpers.childrenResult(regionLane, runtime: ax),
              peers.filter({
                  AXHelpers.getRole($0, runtime: ax) == kAXLayoutItemRole
                      && AXHelpers.getDescription($0, runtime: ax) == name
              }).count == 1 else { return nil }
        let controls = descendants(editor, depth: 5, ax: ax)
        guard let player = only(controls, role: kAXButtonRole, description: "Session Player", ax: ax),
              (AXHelpers.getAttribute(player, kAXValueAttribute, runtime: ax) as String?) == "Keyboard Player",
              let chords = only(controls, role: kAXMenuButtonRole, description: "Chords", ax: ax),
              let slider = only(controls, role: kAXSliderRole, description: "Complexity", ax: ax),
              let intensitySlider = only(controls, role: kAXSliderRole, description: "Intensity", ax: ax),
              let minimum = integer(slider, key: kAXMinValueAttribute, ax: ax),
              let maximum = integer(slider, key: kAXMaxValueAttribute, ax: ax),
              minimum >= 0, minimum <= maximum, maximum <= 100,
              let complexity = integer(slider, key: kAXValueAttribute, ax: ax),
              (minimum...maximum).contains(complexity),
              let intensity = integer(intensitySlider, key: kAXValueAttribute, ax: ax),
              (0...100).contains(intensity),
              AXLogicProElements.logic13SelectedRegion(in: content, runtime: ax).map({ CFEqual($0, region) }) == true,
              AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime) == .success(document)
        else { return nil }
        return Self(window: window, region: region, editor: editor, chordsButton: chords,
                    address: ["project_path": url.path, "region_name": name, "region_location": location, "track": track],
                    complexity: complexity, intensity: intensity, range: minimum...maximum, chordSource: source)
    }

    func holdsSameSelection(as other: Self) -> Bool {
        holdsSameAddress(as: other) && CFEqual(region, other.region)
            && CFEqual(editor, other.editor) && CFEqual(chordsButton, other.chordsButton)
    }

    func holdsSameAddress(as other: Self) -> Bool {
        address == other.address && CFEqual(window, other.window)
    }

    enum ChordSource: String, CaseIterable {
        case global
        case region

        var title: String {
            switch self {
            case .global: "Follow Global Chord Track"
            case .region: "Follow Region Chords"
            }
        }
    }

    struct ChordMenu {
        let menu: AXUIElement
        let selected: ChordSource
        let controls: [ChordSource: AXUIElement]
        let enabled: Set<ChordSource>
    }

    func openChordMenu() -> Bool {
        guard CGPreflightPostEventAccess(), let current = Self.read(), current.holdsSameSelection(as: self),
              !current.hasExposedChordMenu,
              let extent: AXValue = AXHelpers.getAttribute(current.chordsButton, "AXFrame") else { return false }
        var frame = CGRect.zero
        guard AXValueGetValue(extent, .cgRect, &frame), frame.width > 1, frame.height > 1 else { return false }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
                == .success, let hit, CFEqual(hit, current.chordsButton) else { return false }
        return AXMouseHelper.click(at: point)
    }

    func chordMenu(runtime: AXLogicProElements.Runtime = .production) -> ChordMenu? {
        let ax = runtime.ax
        guard let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              URL(string: document)?.path == address["project_path"],
              let menu = ownedChordMenuNode(ax: ax) else { return nil }
        let options = Self.children(menu, ax: ax)
        var controls: [ChordSource: AXUIElement] = [:]
        var checked: [ChordSource] = []
        var enabled: Set<ChordSource> = []
        for source in ChordSource.allCases {
            let match = options.filter {
                AXHelpers.getRole($0, runtime: ax) == kAXMenuItemRole
                    && AXHelpers.getTitle($0, runtime: ax) == source.title
            }
            guard match.count == 1, let item = match.first,
                  let available: NSNumber = AXHelpers.getAttribute(item, kAXEnabledAttribute, runtime: ax) else {
                return nil
            }
            controls[source] = item
            let mark: String? = AXHelpers.getAttribute(item, "AXMenuItemMarkChar", runtime: ax)
            if mark == "✓" || mark == "✔" { checked.append(source) }
            if available.boolValue { enabled.insert(source) }
        }
        guard checked.count == 1, let selected = checked.first else { return nil }
        return .init(menu: menu, selected: selected, controls: controls, enabled: enabled)
    }

    var hasExposedChordMenu: Bool { ownedChordMenuNode(ax: .production) != nil }

    func dismissChordMenu(_ observed: ChordMenu? = nil, runtime: AXLogicProElements.Runtime = .production) -> Bool {
        guard let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              URL(string: document)?.path == address["project_path"],
              let active = ownedChordMenuNode(ax: runtime.ax),
              observed.map({ CFEqual($0.menu, active) }) ?? true else { return false }
        AXMouseHelper.pressEscape()
        return true
    }

    private func ownedChordMenuNode(ax: AXHelpers.Runtime) -> AXUIElement? {
        let controls = Self.children(chordsButton, ax: ax)
        let candidates = controls + controls.flatMap { Self.children($0, ax: ax) }
        let menus = candidates.filter { AXHelpers.getRole($0, runtime: ax) == kAXMenuRole }
        return menus.count == 1 ? menus.first : nil
    }

    private static func integer(_ node: AXUIElement, key: String, ax: AXHelpers.Runtime) -> Int? {
        guard let number: NSNumber = AXHelpers.getAttribute(node, key, runtime: ax),
              number.doubleValue.isFinite else { return nil }
        return Int(exactly: number.doubleValue)
    }

    private static func pitchSource(in inspector: AXUIElement, ax: AXHelpers.Runtime) -> ChordSource? {
        let matches = descendants(inspector, depth: 5, ax: ax).filter {
            AXHelpers.getRole($0, runtime: ax) == kAXButtonRole &&
                AXHelpers.getDescription($0, runtime: ax)?.hasPrefix("Pitch Source, ") == true
        }
        guard matches.count == 1, let control = matches.first,
              let value: String = AXHelpers.getAttribute(control, kAXValueAttribute, runtime: ax),
              AXHelpers.getDescription(control, runtime: ax) == "Pitch Source, " + value else { return nil }
        switch value {
        case "Chord Track, Chord Track": return .global
        case "Region Chords, Region Chords": return .region
        default: return nil
        }
    }

    private static func children(_ node: AXUIElement, ax: AXHelpers.Runtime) -> [AXUIElement] {
        guard case .success(let result) = AXHelpers.childrenResult(node, runtime: ax) else { return [] }
        return result
    }

    private static func descendants(_ node: AXUIElement, depth: Int, ax: AXHelpers.Runtime) -> [AXUIElement] {
        guard depth > 0, let role = AXHelpers.getRole(node, runtime: ax),
              [kAXGroupRole, kAXSplitGroupRole, kAXScrollAreaRole, kAXListRole].contains(role) else { return [node] }
        let nodes = children(node, ax: ax)
        guard nodes.count < 40 else { return [node] }
        return [node] + nodes.flatMap { descendants($0, depth: depth - 1, ax: ax) }
    }

    private static func only(_ nodes: [AXUIElement], role: String, description: String,
                             ax: AXHelpers.Runtime) -> AXUIElement? {
        let matches = nodes.filter {
            AXHelpers.getRole($0, runtime: ax) == role && AXHelpers.getDescription($0, runtime: ax) == description
        }
        return matches.count == 1 ? matches.first : nil
    }
}
