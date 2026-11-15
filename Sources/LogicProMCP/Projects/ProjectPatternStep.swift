@preconcurrency import ApplicationServices
import Foundation

/// One visible Logic 13 Step inspector selection. Grid cells expose their
/// addresses and selection; the inspector supplies the actual step values.
struct ProjectPatternStep {
    let window: AXUIElement
    let editor: AXUIElement
    let region: AXUIElement
    let cell: AXUIElement
    let toggle: AXUIElement
    let address: Address
    let enabled: Bool
    let velocity: Int
    let visibleRows: [GridRow]

    struct Address: Equatable {
        let projectPath: String
        let regionName: String
        let regionLocation: String
        let track: String
        let row: String
        let step: Int

        var json: [String: Any] {
            ["project_path": projectPath, "region_name": regionName, "region_location": regionLocation,
             "track": track, "row": row, "step": step]
        }
    }

    struct GridRow: Equatable {
        let name: String
        let steps: [Int]

        var json: [String: Any] { ["row": name, "steps": steps] }
    }

    private struct GridCell {
        let element: AXUIElement
        let number: Int
        let selected: Bool
        let frame: CGRect
    }

    func holdsSameSelection(as other: Self) -> Bool {
        address == other.address && CFEqual(window, other.window) && CFEqual(editor, other.editor)
            && CFEqual(region, other.region) && CFEqual(cell, other.cell)
    }

    static func read(runtime: AXLogicProElements.Runtime = .production) -> Self? {
        _ = runtime.onScreenWindowList()
        let ax = runtime.ax
        guard let pid = runtime.logicProPID(), runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true,
              case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              let url = URL(string: document), url.isFileURL, url.pathExtension.lowercased() == "logicx",
              let content = AXLogicProElements.logic13TrackContent(in: window, runtime: runtime),
              let region = selectedRegion(in: content, ax: ax),
              AXHelpers.getRole(region, runtime: ax) == kAXLayoutItemRole,
              let help = AXHelpers.getHelp(region, runtime: ax), help.contains(", Pattern region."),
              let regionName = AXHelpers.getDescription(region, runtime: ax), !regionName.isEmpty,
              let regionTrack: AXUIElement = AXHelpers.getAttribute(region, kAXParentAttribute, runtime: ax),
              let location = uniqueLocation(for: regionName, selected: region, in: regionTrack, ax: ax),
              let track = AXHelpers.getDescription(regionTrack, runtime: ax), track.hasPrefix("Track "),
              case .read(let trackHeaders) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              AXLogicProElements.logic13RegionTrackIndex(region, in: content, headers: trackHeaders, runtime: ax) != nil,
              let editor = single(children(window, ax), role: kAXGroupRole, name: "Step Sequencer", ax: ax),
              let toolbar = single(children(editor, ax), role: kAXGroupRole, roleDescription: "toolbar",
                                   name: "Step Sequencer", ax: ax)
        else { return nil }
        let controls = descendants(toolbar, depth: 3, ax: ax)
        guard ["Mono Mode", "Pattern Live Recording", "Preview", "MIDI In (Step Record)"].allSatisfy({ name in
            single(controls, role: kAXCheckBoxRole, name: name, ax: ax).flatMap {
                AXValueExtractors.extractButtonState($0, runtime: ax)
            } == false
        }), let body = single(children(editor, ax), role: kAXGroupRole, roleDescription: "group",
                              name: "Step Sequencer", ax: ax)
        else { return nil }

        let scrollAreas = descendants(body, depth: 4, ax: ax).filter { AXHelpers.getRole($0, runtime: ax) == kAXScrollAreaRole }
        let candidates = scrollAreas.map { children($0, ax) }.filter { nodes in
            nodes.contains { (AXHelpers.getDescription($0, runtime: ax) ?? "").hasPrefix("Step 1 of 16") }
        }
        guard candidates.count == 1, let grid = candidates.first, grid.count <= 1024 else { return nil }

        let headers = grid.filter { roleDescription($0, ax) == "row" }
        let cells = grid.compactMap { gridCell($0, ax: ax) }
        let selected = cells.filter(\.selected)
        guard selected.count == 1, let cell = selected.first else { return nil }

        var visibleRows: [GridRow] = []
        var selectedRows: [String] = []
        for header in headers {
            guard let label = AXHelpers.getDescription(header, runtime: ax), !label.isEmpty,
                  let rectangle = frame(header, ax) else { return nil }
            let rowCells = cells.filter { abs($0.frame.minY - rectangle.minY) < 0.5 }
            let steps = rowCells.map(\.number).sorted()
            guard Set(steps).count == steps.count else { return nil }
            let name = label.hasSuffix(", selected") ? String(label.dropLast(", selected".count)) : label
            if rowCells.contains(where: \.selected) {
                guard label.hasSuffix(", selected") else { return nil }
                selectedRows.append(name)
            }
            visibleRows.append(.init(name: name, steps: steps))
        }

        let editorControls = descendants(body, depth: 8, ax: ax, stoppingAt: scrollAreas.filter { area in
            children(area, ax).contains { CFEqual($0, cell.element) }
        })
        guard Set(visibleRows.map(\.name)).count == visibleRows.count,
              selectedRows.count == 1, let row = selectedRows.first,
              let tab = single(editorControls, role: kAXRadioButtonRole, name: "Step", ax: ax),
              AXValueExtractors.extractButtonState(tab, runtime: ax) == true,
              let toggle = single(editorControls, role: kAXCheckBoxRole, name: "On/Off", ax: ax),
              let enabled = AXValueExtractors.extractButtonState(toggle, runtime: ax)
        else { return nil }
        let velocities = editorControls.compactMap { element -> Int? in
            guard AXHelpers.getRole(element, runtime: ax) == kAXButtonRole,
                  let label = AXHelpers.getDescription(element, runtime: ax), label.hasPrefix("Velocity, "),
                  let value = Int(label.dropFirst("Velocity, ".count)), (1...127).contains(value) else { return nil }
            return value
        }
        guard velocities.count == 1, let velocity = velocities.first,
              ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true),
              AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime) == .success(document),
              selectedRegion(in: content, ax: ax).map({ CFEqual($0, region) }) == true
        else { return nil }

        let address = Address(projectPath: url.path, regionName: regionName, regionLocation: location,
                              track: track, row: row, step: cell.number)
        return .init(window: window, editor: editor, region: region, cell: cell.element, toggle: toggle,
                     address: address, enabled: enabled, velocity: velocity, visibleRows: visibleRows)
    }

    private static func uniqueLocation(for name: String, selected: AXUIElement, in lane: AXUIElement,
                                       ax: AXHelpers.Runtime) -> String? {
        guard let detail = AXHelpers.getHelp(selected, runtime: ax),
              let separator = detail.range(of: ", Pattern region."),
              case .success(let children) = AXHelpers.childrenResult(lane, runtime: ax) else { return nil }
        let location = String(detail[..<separator.lowerBound])
        let prefix = location + ", Pattern region."
        let matching = children.filter {
            AXHelpers.getDescription($0, runtime: ax) == name
                && AXHelpers.getHelp($0, runtime: ax)?.hasPrefix(prefix) == true
        }
        guard matching.count == 1, matching.first.map({ CFEqual($0, selected) }) == true else { return nil }
        return location
    }

    private static func selectedRegion(in content: AXUIElement, ax: AXHelpers.Runtime) -> AXUIElement? {
        // In the split editor, the Arrange group's selected-children array is empty
        // even while its individual pattern item reports AXSelected=true.
        guard let items = AXLogicProElements.logic13RegionItems(in: content, runtime: ax) else { return nil }
        var selection: AXUIElement?
        for item in items where roleDescription(item, ax) == "Region" {
            guard case .success(let selected?) = AXHelpers.getAttributeResult(item, kAXSelectedAttribute, runtime: ax)
                as Result<NSNumber?, AXHelpers.AXStatusError> else { return nil }
            if selected.boolValue {
                guard selection == nil else { return nil }
                selection = item
            }
        }
        return selection
    }

    private static func gridCell(_ item: AXUIElement, ax: AXHelpers.Runtime) -> GridCell? {
        guard [kAXButtonRole, kAXSliderRole].contains(AXHelpers.getRole(item, runtime: ax) ?? ""),
              let label = AXHelpers.getDescription(item, runtime: ax), label.hasPrefix("Step "),
              let rectangle = frame(item, ax) else { return nil }
        let selected = label.hasSuffix(", selected")
        let entry = selected ? String(label.dropLast(", selected".count)) : label
        let parts = entry.split(separator: " ")
        guard parts.count == 4, parts[2] == "of", parts[3] == "16",
              let number = Int(parts[1]), (1...16).contains(number) else { return nil }
        return .init(element: item, number: number, selected: selected, frame: rectangle)
    }

    private static func children(_ item: AXUIElement, _ ax: AXHelpers.Runtime) -> [AXUIElement] {
        guard case .success(let children) = AXHelpers.childrenResult(item, runtime: ax) else { return [] }
        return children
    }

    private static func descendants(_ node: AXUIElement, depth: Int, ax: AXHelpers.Runtime,
                                    stoppingAt: [AXUIElement] = []) -> [AXUIElement] {
        guard depth > 0, !stoppingAt.contains(where: { CFEqual($0, node) }) else { return [] }
        let children = children(node, ax)
        return children + children.flatMap { descendants($0, depth: depth - 1, ax: ax, stoppingAt: stoppingAt) }
    }

    private static func single(_ nodes: [AXUIElement], role: String, roleDescription: String? = nil,
                               name: String, ax: AXHelpers.Runtime) -> AXUIElement? {
        let matches = nodes.filter { node in
            AXHelpers.getRole(node, runtime: ax) == role && AXHelpers.getDescription(node, runtime: ax) == name
                && (roleDescription == nil || Self.roleDescription(node, ax) == roleDescription)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func roleDescription(_ item: AXUIElement, _ ax: AXHelpers.Runtime) -> String? {
        AXHelpers.getAttribute(item, kAXRoleDescriptionAttribute, runtime: ax)
    }

    private static func frame(_ item: AXUIElement, _ ax: AXHelpers.Runtime) -> CGRect? {
        guard let p = AXHelpers.getPosition(item, runtime: ax), let s = AXHelpers.getSize(item, runtime: ax),
              p.x.isFinite, p.y.isFinite, s.width.isFinite, s.height.isFinite, s.width > 0, s.height > 0 else { return nil }
        return CGRect(origin: p, size: s)
    }
}
