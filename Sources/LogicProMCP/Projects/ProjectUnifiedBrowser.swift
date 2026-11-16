import ApplicationServices
import Foundation

/// Bound to one stopped Logic 13 Arrange document and the Instruments view of its Browser.
struct ProjectUnifiedBrowser {
    struct Result {
        let name: String
        let label: AXUIElement
    }

    let projectPath: String
    let window: AXUIElement
    let panel: AXUIElement
    let search: AXUIElement
    let input: AXUIElement
    let replace: AXUIElement
    let replacementEnabled: Bool
    let selectionEmpty: Bool
    let results: [Result]
    let query: String?
    let selectedIndex: Int
    let selectedHeader: AXUIElement
    let names: [String]
    let regions: [String]
    let patchName: String?
    let instrumentSlotObserved: Bool

    static func read(runtime: AXLogicProElements.Runtime = .production) -> Self? {
        _ = runtime.onScreenWindowList()
        let ax = runtime.ax
        guard let pid = runtime.logicProPID(), runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true,
              case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              let url = URL(string: document), url.isFileURL, url.pathExtension.lowercased() == "logicx",
              let browser = only(children(window, ax: ax), kAXGroupRole, "Browser", ax: ax),
              let inspector = only(children(window, ax: ax), kAXGroupRole, "Inspector", ax: ax),
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              (1...16).contains(headers.count),
              let content = AXLogicProElements.logic13TrackContent(in: window, runtime: runtime),
              let items = AXLogicProElements.logic13RegionItems(in: content, runtime: ax) else { return nil }

        let names = headers.compactMap { try? AXValueExtractors.extractTrackNameResult(from: $0, runtime: ax).get() }
        let selections = headers.map { AXHelpers.getAttribute($0, kAXSelectedAttribute, runtime: ax) as NSNumber? }
        let selected = selections.indices.filter { selections[$0]?.boolValue == true }
        let inspectorItems = bounded(inspector, depth: 7, ax: ax)
        let instrumentsInInspector = inspectorItems.filter {
            AXHelpers.getRole($0, runtime: ax) == kAXButtonRole &&
                AXHelpers.getHelp($0, runtime: ax)?.hasPrefix("Instrument slot.") == true
        }
        guard names.count == headers.count, selections.allSatisfy({ $0 != nil }),
              selected.count == 1, let index = selected.first, Set(names).count == names.count else { return nil }
        var regions = [String]()
        for item in items where (AXHelpers.getAttribute(item, kAXRoleDescriptionAttribute, runtime: ax) as String?) == "Region" {
            guard let name = AXHelpers.getDescription(item, runtime: ax),
                  let help = AXHelpers.getHelp(item, runtime: ax),
                  let owner = AXLogicProElements.logic13RegionTrackIndex(item, in: content, headers: headers, runtime: ax)
            else { return nil }
            regions.append("\(owner)\u{1f}\(name)\u{1f}\(help)")
        }

        let controls = bounded(browser, depth: 7, ax: ax)
        guard let replacement = only(controls, kAXCheckBoxRole, "Replace on selection", ax: ax),
              let enabled = AXValueExtractors.extractButtonState(replacement, runtime: ax),
              let instruments = only(controls, kAXCheckBoxRole, "Instruments", ax: ax),
              AXValueExtractors.extractButtonState(instruments, runtime: ax) == true,
              let search = only(controls, kAXButtonRole, "Search", ax: ax) else { return nil }
        let fields = controls.filter {
            AXHelpers.getRole($0, runtime: ax) == kAXTextFieldRole
                && (AXHelpers.getAttribute($0, kAXRoleDescriptionAttribute, runtime: ax) as String?) == "search text field"
        }
        let tables = controls.filter {
            AXHelpers.getRole($0, runtime: ax) == kAXTableRole
                && AXHelpers.getHelp($0, runtime: ax)?.hasPrefix("Results list (list view).") == true
        }
        guard fields.count == 1, tables.count == 1,
              let rows: [AXUIElement] = AXHelpers.getAttribute(tables[0], kAXVisibleRowsAttribute, runtime: ax),
              rows.count <= 64 else { return nil }
        let result = rows.compactMap { row -> Result? in
            let entries = bounded(row, depth: 3, ax: ax)
            guard only(entries, kAXButtonRole, "Instrument Patch, Play preview", ax: ax) != nil else { return nil }
            let labels = entries.filter { AXHelpers.getRole($0, runtime: ax) == kAXStaticTextRole }
            guard labels.count == 1, let name: String = AXHelpers.getAttribute(labels[0], kAXValueAttribute, runtime: ax),
                  !name.isEmpty else { return nil }
            return Result(name: name, label: labels[0])
        }
        let filters = controls.filter {
            AXHelpers.getRole($0, runtime: ax) == kAXButtonRole
                && AXHelpers.getHelp($0, runtime: ax) == "Removes this filter"
        }
        let selection: [AXUIElement]? = AXHelpers.getAttribute(tables[0], kAXSelectedRowsAttribute, runtime: ax)
        let indicators = inspectorItems.compactMap { item -> String? in
            guard AXHelpers.getRole(item, runtime: ax) == kAXButtonRole,
                  AXHelpers.getHelp(item, runtime: ax)?.hasPrefix("Browser Focus triangle.") == true,
                  let description = AXHelpers.getDescription(item, runtime: ax),
                  description == "library indicator, " + names[index] else { return nil }
            return names[index]
        }
        return Self(projectPath: url.path, window: window, panel: browser, search: search, input: fields[0], replace: replacement,
                    replacementEnabled: enabled, selectionEmpty: selection?.isEmpty == true, results: result,
                    query: filters.count == 1 ? AXHelpers.getDescription(filters[0], runtime: ax) : nil,
                    selectedIndex: index, selectedHeader: headers[index], names: names, regions: regions,
                    patchName: indicators.count == 1 ? indicators[0] : nil,
                    instrumentSlotObserved: instrumentsInInspector.count == 1)
    }

    func holdsSameTarget(as other: Self) -> Bool {
        projectPath == other.projectPath && CFEqual(window, other.window) && CFEqual(panel, other.panel)
            && selectedIndex == other.selectedIndex && CFEqual(selectedHeader, other.selectedHeader)
            && names == other.names && regions == other.regions
    }

    func loaded(_ name: String, replacing before: Self) -> Bool {
        projectPath == before.projectPath && CFEqual(window, before.window) && CFEqual(panel, before.panel)
            && selectedIndex == before.selectedIndex && names.count == before.names.count
            && names[selectedIndex] == name && patchName == name && regions == before.regions
            && names.indices.filter({ $0 != selectedIndex }).allSatisfy({ names[$0] == before.names[$0] })
    }

    func clickResult(_ label: AXUIElement) -> Bool {
        guard CGPreflightPostEventAccess(),
              let extent: AXValue = AXHelpers.getAttribute(label, "AXFrame") else { return false }
        var frame = CGRect.zero
        guard AXValueGetValue(extent, .cgRect, &frame), frame.width > 1, frame.height > 1 else { return false }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, CFEqual(hit, label),
              let observed = Self.read(), observed.holdsSameTarget(as: self), observed.replacementEnabled,
              observed.results.contains(where: { CFEqual($0.label, label) }) else { return false }
        return AXMouseHelper.click(at: point)
    }

    private static func children(_ item: AXUIElement, ax: AXHelpers.Runtime) -> [AXUIElement] {
        guard case .success(let nodes) = AXHelpers.childrenResult(item, runtime: ax) else { return [] }
        return nodes
    }

    private static func bounded(_ item: AXUIElement, depth: Int, ax: AXHelpers.Runtime) -> [AXUIElement] {
        guard depth > 0, AXHelpers.getRole(item, runtime: ax) != kAXTableRole else { return [item] }
        let nodes = children(item, ax: ax)
        guard nodes.count <= 64 else { return [item] }
        return [item] + nodes.flatMap { bounded($0, depth: depth - 1, ax: ax) }
    }

    private static func only(_ items: [AXUIElement], _ role: String, _ name: String,
                             ax: AXHelpers.Runtime) -> AXUIElement? {
        let found = items.filter { AXHelpers.getRole($0, runtime: ax) == role && AXHelpers.getDescription($0, runtime: ax) == name }
        return found.count == 1 ? found.first : nil
    }
}
