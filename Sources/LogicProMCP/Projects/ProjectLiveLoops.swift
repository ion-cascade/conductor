import ApplicationServices
import CryptoKit
import Foundation

/// A finite Live Loops grid held against one focused Logic 13 document.
struct ProjectLiveLoops {
    struct Row: Codable, Equatable {
        let track: String
        let activity: String

        var inactive: Bool { activity == "activate track" || activity == "deactivate track" }
    }

    struct Cell: Codable, Equatable {
        let cell_ref: String
        let scene: String
        let track: String
        let name: String?
        let mode: String?
    }

    struct Grid: Codable, Equatable {
        let project_path: String
        let quantize_start: String
        let transport_playing: Bool
        let rows: [Row]
        let cells: [Cell]
        let selected_cell_ref: String?

        func snapshot() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return "loops_" + SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
        }

        func preservesPeers(of baseline: Self, track: String) -> Bool {
            project_path == baseline.project_path && quantize_start == baseline.quantize_start
                && transport_playing == baseline.transport_playing && cells == baseline.cells
                && selected_cell_ref == baseline.selected_cell_ref
                && rows.filter { $0.track != track } == baseline.rows.filter { $0.track != track }
        }
    }

    let grid: Grid
    let pid: pid_t
    let window: AXUIElement
    let area: AXUIElement
    let selected: AXUIElement?
    let control: AXUIElement?
    let action: String?

    func holdsSelection(as other: Self) -> Bool {
        guard pid == other.pid, CFEqual(window, other.window), CFEqual(area, other.area),
              let selected, let previous = other.selected else { return false }
        return CFEqual(selected, previous)
    }

    static func read(runtime: AXLogicProElements.Runtime = .production) -> Self? {
        _ = runtime.onScreenWindowList()
        let ax = runtime.ax
        guard !Task.isCancelled, let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
              runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true,
              let app = AXLogicProElements.appRoot(runtime: runtime),
              let window: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: ax),
              heldWindow(window, app: app, pid: pid, runtime: runtime),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              let url = URL(string: document), url.isFileURL, url.pathExtension.lowercased() == "logicx",
              let transport = try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime, checking: {}),
              !transport.isRecording,
              let tracks = only(children(window, ax), role: kAXGroupRole, description: "Tracks", ax: ax),
              let census = bounded(tracks, depth: 5, ax: ax),
              let scroll = only(census, role: kAXScrollAreaRole, description: "Live Loops", ax: ax),
              let viewport = frame(scroll, ax),
              let area = only(children(scroll, ax), role: kAXLayoutAreaRole, description: "Live Loops Grid", ax: ax),
              let scenes = only(children(scroll, ax), role: kAXLayoutAreaRole, description: "Live Loops Scene Trigger", ax: ax),
              let divider = only(children(scroll, ax), role: kAXLayoutAreaRole, description: "Live Loops Divider", ax: ax),
              let legend = only(census, role: "AXUnknown", description: "Live Loops Legend", ax: ax),
              let quantize = unique(children(legend, ax).filter {
                  AXHelpers.getRole($0, runtime: ax) == kAXPopUpButtonRole
                      && AXHelpers.getHelp($0, runtime: ax)?.hasPrefix("Quantize Start Menu,") == true
              }),
              let quantizeStart: String = AXHelpers.getAttribute(quantize, kAXValueAttribute, runtime: ax),
              !quantizeStart.isEmpty,
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              (1...8).contains(headers.count)
        else { return nil }

        let rowItems = children(divider, ax)
        let sceneItems = children(scenes, ax)
        guard rowItems.count == headers.count, (1...16).contains(sceneItems.count) else { return nil }
        let rows = zip(headers, rowItems).enumerated().compactMap { offset, pair -> Row? in
            let (header, row) = pair
            let ordinal = offset + 1
            guard let name = try? AXValueExtractors.extractTrackNameResult(from: header, runtime: ax).get(),
                  !name.isEmpty, name.utf8.count <= 256,
                  AXHelpers.getDescription(header, runtime: ax) == "Track \(ordinal) “\(name)”",
                  AXHelpers.getDescription(row, runtime: ax) == "track \(ordinal)",
                  aligned(frame(header, ax), frame(row, ax), coordinate: \.midY),
                  let state: String = AXHelpers.getAttribute(row, kAXValueDescriptionAttribute, runtime: ax),
                  ["activate track", "deactivate track", "cancel playing", "stop", "cancel stopping"].contains(state)
            else { return nil }
            return Row(track: name, activity: state)
        }
        guard rows.count == headers.count, Set(rows.map(\.track)).count == rows.count else { return nil }

        var sceneLabels = [String]()
        for item in sceneItems {
            guard let label = AXHelpers.getDescription(item, runtime: ax),
                  let number = ordinal(label, prefix: "scene "),
                  AXHelpers.getTitle(item, runtime: ax) == "Scene Trigger, \(number)",
                  !sceneLabels.contains(label) else { return nil }
            sceneLabels.append(label)
        }
        var addresses = Set<String>()
        var cells = [Cell]()
        var selected: AXUIElement?
        var selectedRef: String?
        var control: AXUIElement?
        var action: String?
        let nodes = children(area, ax)
        guard nodes.count == rows.count * sceneItems.count else { return nil }
        for node in nodes {
            guard AXHelpers.getRole(node, runtime: ax) == kAXLayoutItemRole,
                  let address = AXHelpers.getDescription(node, runtime: ax),
                  addresses.insert(address).inserted,
                  let split = address.range(of: " track "),
                  let scene = sceneLabels.firstIndex(of: String(address[..<split.lowerBound])),
                  let track = ordinal(String(address[split.upperBound...]), prefix: ""),
                  rows.indices.contains(track - 1), let bounds = frame(node, ax),
                  aligned(bounds, frame(sceneItems[scene], ax), coordinate: \.midX),
                  aligned(bounds, frame(headers[track - 1], ax), coordinate: \.midY),
                  let isSelected: NSNumber = AXHelpers.getAttribute(node, kAXSelectedAttribute, runtime: ax) else { return nil }
            let trackName = rows[track - 1].track
            let title = AXHelpers.getTitle(node, runtime: ax).flatMap { $0.isEmpty ? nil : $0 }
            let mode: String? = AXHelpers.getAttribute(node, kAXValueDescriptionAttribute, runtime: ax)
            let stableMode = mode?.replacingOccurrences(of: "^selected, ", with: "", options: .regularExpression)
            guard (title?.utf8.count ?? 0) <= 256, (stableMode?.utf8.count ?? 0) <= 256 else { return nil }
            let cellReference = "cell_" + SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
            cells.append(.init(cell_ref: cellReference, scene: sceneLabels[scene], track: trackName,
                               name: title, mode: stableMode))
            if isSelected.boolValue {
                guard selected == nil else { return nil }
                selected = node
                selectedRef = cellReference
                if viewport.contains(bounds) && title != nil {
                    control = only(children(node, ax), role: kAXButtonRole, description: "primary button", ax: ax)
                    action = control.flatMap { AXHelpers.getAttribute($0, kAXValueAttribute, runtime: ax) as String? }
                }
            }
        }
        guard heldWindow(window, app: app, pid: pid, runtime: runtime) else { return nil }
        let grid = Grid(project_path: url.path, quantize_start: quantizeStart,
                        transport_playing: transport.isPlaying, rows: rows,
                        cells: cells.sorted { $0.cell_ref < $1.cell_ref }, selected_cell_ref: selectedRef)
        return .init(grid: grid, pid: pid, window: window, area: area,
                     selected: selected, control: control, action: action)
    }

    private static func heldWindow(
        _ window: AXUIElement, app: AXUIElement, pid: pid_t, runtime: AXLogicProElements.Runtime
    ) -> Bool {
        let ax = runtime.ax
        guard !Task.isCancelled, runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid,
              let wins: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: ax),
              let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: ax),
              case .success(let entries) = AXHelpers.childrenResult(window, runtime: ax) else { return false }
        let relevant = wins.filter { AXHelpers.getRole($0, runtime: ax) != kAXHelpTagRole }
        return relevant.count == 1 && CFEqual(relevant[0], window) && CFEqual(focus, window)
            && !entries.contains { AXHelpers.getRole($0, runtime: ax) == kAXSheetRole }
    }

    private static func ordinal(_ text: String, prefix: String) -> Int? {
        guard text.hasPrefix(prefix), let value = Int(text.dropFirst(prefix.count)),
              (1...128).contains(value), text == prefix + String(value) else { return nil }
        return value
    }

    private static func children(_ item: AXUIElement, _ ax: AXHelpers.Runtime) -> [AXUIElement] {
        guard case .success(let entries) = AXHelpers.childrenResult(item, runtime: ax) else { return [] }
        return entries
    }

    private static func bounded(_ root: AXUIElement, depth: Int, ax: AXHelpers.Runtime) -> [AXUIElement]? {
        var layer = [root]
        var all = [root]
        for _ in 0..<depth {
            layer = layer.flatMap { children($0, ax) }
            guard all.count + layer.count <= 1024 else { return nil }
            all.append(contentsOf: layer)
        }
        return all
    }

    private static func only(
        _ nodes: [AXUIElement], role: String, description: String, ax: AXHelpers.Runtime
    ) -> AXUIElement? {
        unique(nodes.filter {
            AXHelpers.getRole($0, runtime: ax) == role && AXHelpers.getDescription($0, runtime: ax) == description
        })
    }

    private static func unique<T>(_ entries: [T]) -> T? { entries.count == 1 ? entries.first : nil }

    private static func frame(_ element: AXUIElement, _ ax: AXHelpers.Runtime) -> CGRect? {
        guard let origin = AXHelpers.getPosition(element, runtime: ax),
              let size = AXHelpers.getSize(element, runtime: ax), size.width > 0, size.height > 0,
              [origin.x, origin.y, size.width, size.height].allSatisfy(\.isFinite) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func aligned(_ a: CGRect?, _ b: CGRect?, coordinate: KeyPath<CGRect, CGFloat>) -> Bool {
        guard let a, let b else { return false }
        return abs(a[keyPath: coordinate] - b[keyPath: coordinate]) <= 2
    }
}
