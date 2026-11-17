import ApplicationServices
import Foundation

/// A single MIDI-region score in the focused, stopped Logic 13 document.
struct ProjectScore {
    struct Note: Encodable, Equatable {
        let position: String
        let pitch: String
    }

    struct Readback: Encodable, Equatable {
        let project_path: String
        let track_name: String
        let region_name: String
        let time_signature: String
        let notes: [Note]
        let rest_count: Int
    }

    let readback: Readback
    let pid: pid_t
    let app: AXUIElement
    let window: AXUIElement
    let document: String
    let header: AXUIElement
    let region: AXUIElement
    let surface: AXUIElement

    func holdsSameScore(as other: Self) -> Bool {
        pid == other.pid && document == other.document && readback == other.readback
            && CFEqual(window, other.window) && CFEqual(header, other.header)
            && CFEqual(region, other.region) && CFEqual(surface, other.surface)
    }

    static func read(runtime: AXLogicProElements.Runtime = .production) -> Self? {
        _ = runtime.onScreenWindowList()
        let ax = runtime.ax
        guard let pid = runtime.logicProPID(), runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true,
              let app = AXLogicProElements.appRoot(runtime: runtime),
              case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              let url = URL(string: document), url.isFileURL, url.pathExtension.lowercased() == "logicx",
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              headers.count == 1, let header = headers.first,
              let track = try? AXValueExtractors.extractTrackNameResult(from: header, runtime: ax).get(),
              let arrange = AXLogicProElements.logic13TrackContent(in: window, runtime: runtime),
              let candidates = AXLogicProElements.logic13RegionItems(in: arrange, runtime: ax)
        else { return nil }
        let regions = candidates.filter {
            (AXHelpers.getAttribute($0, kAXRoleDescriptionAttribute, runtime: ax) as String?) == "Region"
        }
        guard regions.count == 1, let region = regions.first,
              AXLogicProElements.logic13RegionTrackIndex(region, in: arrange, headers: headers, runtime: ax) == 0,
              let selected: NSNumber = AXHelpers.getAttribute(region, kAXSelectedAttribute, runtime: ax),
              selected.boolValue, let regionName = AXHelpers.getDescription(region, runtime: ax),
              AXHelpers.getHelp(region, runtime: ax)?.contains("MIDI region.") == true,
              let surface = onlyGroup(AXHelpers.getChildren(window, runtime: ax), named: "Score", ax: ax),
              let view = bounded(surface, depth: 5, ax: ax),
              let score = onlyGroup(view, named: "Score contents", ax: ax),
              let objects = bounded(score, depth: 4, ax: ax),
              let windowControls = bounded(window, depth: 3, ax: ax),
              let display = onlyGroup(windowControls, named: "Transport Display", ax: ax)
        else { return nil }

        // Logic publishes the LCD separately from the transport button toolbar.
        let meters = AXHelpers.getChildren(display, runtime: ax).filter {
            AXHelpers.getRole($0, runtime: ax) == kAXPopUpButtonRole
                && AXHelpers.getDescription($0, runtime: ax) == "Time Signature"
        }
        guard meters.count == 1, let meter: String = AXHelpers.getAttribute(meters[0], kAXValueAttribute, runtime: ax),
              meter.range(of: "^[0-9]{1,2}/[0-9]{1,2}$", options: .regularExpression) != nil else { return nil }

        let staff = objects.filter {
            AXHelpers.getRole($0, runtime: ax) == kAXGroupRole
                && AXHelpers.getDescription($0, runtime: ax)?.hasPrefix("Linear Staff ") == true
        }
        guard staff.count == 1, let entries = bounded(staff[0], depth: 2, ax: ax) else { return nil }
        var notes = [Note]()
        var rests = 0
        for entry in entries where AXHelpers.getRole(entry, runtime: ax) == kAXButtonRole {
            guard let caption = AXHelpers.getDescription(entry, runtime: ax) else { continue }
            if caption == "rest" {
                rests += 1
            } else if caption.hasPrefix("Note at ") {
                guard let comma = caption.lastIndex(of: ",") else { return nil }
                let position = String(caption.dropFirst(8).prefix(upTo: comma)).trimmingCharacters(in: .whitespaces)
                let pitch = String(caption[caption.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                guard !position.isEmpty, position.utf8.count <= 128,
                      pitch.range(of: "^[A-G][#b♯♭]?-?[0-9]{1,2}$", options: .regularExpression) != nil else { return nil }
                notes.append(.init(position: position, pitch: pitch))
            }
        }
        guard !notes.isEmpty, notes.count + rests <= 256,
              ControlBarDisplayMode.foregroundStoppedProject(window: window, runtime: runtime, ignoringHelpTags: true)
        else { return nil }
        return .init(readback: .init(project_path: url.path, track_name: track, region_name: regionName,
                                    time_signature: meter, notes: notes, rest_count: rests),
                     pid: pid, app: app, window: window, document: document,
                     header: header, region: region, surface: surface)
    }

    private static func onlyGroup(_ items: [AXUIElement], named name: String, ax: AXHelpers.Runtime) -> AXUIElement? {
        let groups = items.filter {
            AXHelpers.getRole($0, runtime: ax) == kAXGroupRole && AXHelpers.getDescription($0, runtime: ax) == name
        }
        return groups.count == 1 ? groups.first : nil
    }

    private static func bounded(_ root: AXUIElement, depth: Int, ax: AXHelpers.Runtime) -> [AXUIElement]? {
        var level = [root]
        var result = [root]
        for _ in 0..<depth {
            level = level.flatMap { AXHelpers.getChildren($0, runtime: ax) }
            guard level.count + result.count <= 512 else { return nil }
            result.append(contentsOf: level)
        }
        return result
    }
}
