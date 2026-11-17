import AppKit
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
              let app = AXLogicProElements.appRoot(runtime: runtime)
        else { return unavailable("logic_13_host") }
        guard foreground(pid, runtime: runtime) else { return unavailable("logic_focus") }
        guard case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              let url = URL(string: document), url.isFileURL, url.pathExtension.lowercased() == "logicx"
        else { return unavailable("saved_document") }
        guard let windowNodes = bounded(window, depth: 3, ax: ax),
              let play = toolbarSwitch("controlBar/playButton", nodes: windowNodes, runtime: ax),
              let record = toolbarSwitch("controlBar/recordButton", nodes: windowNodes, runtime: ax)
        else { return unavailable("native_transport_switches") }
        guard stoppedDocument(window, app: app, pid: pid, play: play, record: record, runtime: runtime)
        else { return unavailable("stopped_document_custody") }
        guard case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              headers.count == 1, let header = headers.first,
              let track = try? AXValueExtractors.extractTrackNameResult(from: header, runtime: ax).get(),
              let arrange = AXLogicProElements.logic13TrackContent(in: window, runtime: runtime),
              let candidates = AXLogicProElements.logic13RegionItems(in: arrange, runtime: ax)
        else { return unavailable("single_track_and_arrange_inventory") }
        let regions = candidates.filter {
            (AXHelpers.getAttribute($0, kAXRoleDescriptionAttribute, runtime: ax) as String?) == "Region"
        }
        guard regions.count == 1, let region = regions.first,
              AXLogicProElements.logic13RegionTrackIndex(region, in: arrange, headers: headers, runtime: ax) == 0,
              let selected: NSNumber = AXHelpers.getAttribute(region, kAXSelectedAttribute, runtime: ax),
              selected.boolValue, let regionName = AXHelpers.getDescription(region, runtime: ax),
              AXHelpers.getHelp(region, runtime: ax)?.contains("MIDI region.") == true
        else { return unavailable("selected_midi_region") }
        guard let surface = onlyGroup(AXHelpers.getChildren(window, runtime: ax), named: "Score", ax: ax),
              let view = bounded(surface, depth: 5, ax: ax),
              let score = onlyGroup(view, named: "Score contents", ax: ax),
              let objects = bounded(score, depth: 4, ax: ax)
        else { return unavailable("score_surface") }
        guard let display = onlyGroup(windowNodes, named: "Transport Display", ax: ax)
        else { return unavailable("transport_display") }

        // Logic publishes the LCD separately from the transport button toolbar.
        let meters = AXHelpers.getChildren(display, runtime: ax).filter {
            AXHelpers.getRole($0, runtime: ax) == kAXPopUpButtonRole
                && AXHelpers.getDescription($0, runtime: ax) == "Time Signature"
        }
        guard meters.count == 1, let meter: String = AXHelpers.getAttribute(meters[0], kAXValueAttribute, runtime: ax),
              meter.range(of: "^[0-9]{1,2}/[0-9]{1,2}$", options: .regularExpression) != nil else { return unavailable("score_meter") }

        let staff = objects.filter {
            AXHelpers.getRole($0, runtime: ax) == kAXGroupRole
                && AXHelpers.getDescription($0, runtime: ax)?.hasPrefix("Linear Staff ") == true
        }
        guard staff.count == 1, let entries = bounded(staff[0], depth: 2, ax: ax) else { return unavailable("single_score_staff") }
        var notes = [Note]()
        var rests = 0
        for entry in entries where AXHelpers.getRole(entry, runtime: ax) == kAXButtonRole {
            guard let caption = AXHelpers.getDescription(entry, runtime: ax) else { continue }
            if caption == "rest" {
                rests += 1
            } else if caption.hasPrefix("Note at ") {
                guard let comma = caption.lastIndex(of: ",") else { return unavailable("score_note_label") }
                let position = String(caption.dropFirst(8).prefix(upTo: comma)).trimmingCharacters(in: .whitespaces)
                let pitch = String(caption[caption.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                guard !position.isEmpty, position.utf8.count <= 128,
                      pitch.range(of: "^[A-G][#b♯♭]?-?[0-9]{1,2}$", options: .regularExpression) != nil else { return unavailable("score_note_pitch") }
                notes.append(.init(position: position, pitch: pitch))
            }
        }
        guard !notes.isEmpty, notes.count + rests <= 256,
              stoppedDocument(window, app: app, pid: pid, play: play, record: record, runtime: runtime)
        else { return unavailable("score_notes_or_custody") }
        return .init(readback: .init(project_path: url.path, track_name: track, region_name: regionName,
                                    time_signature: meter, notes: notes, rest_count: rests),
                     pid: pid, app: app, window: window, document: document,
                     header: header, region: region, surface: surface)
    }

    private static func unavailable(_ stage: String) -> Self? {
        Log.debug("Score observation unavailable at \(stage)", subsystem: "project")
        return nil
    }

    static func foreground(_ pid: pid_t, runtime: AXLogicProElements.Runtime) -> Bool {
        let ownership = ProcessUtils.keyboardOwnershipObservation(
            windowList: runtime.onScreenWindowList,
            focusedPID: runtime.focusedApplicationPID,
            bundleIDForPID: ProcessUtils.bundleIDForPID
        )
        return ownership.isReady && ownership.keyboardOwnerPID == pid
            && NSRunningApplication(processIdentifier: pid)?.isActive == true
    }

    private static func toolbarSwitch(_ id: String, nodes: [AXUIElement], runtime: AXHelpers.Runtime) -> AXUIElement? {
        let matches = nodes.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXCheckBoxRole && AXHelpers.getIdentifier($0, runtime: runtime) == id
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func stoppedDocument(
        _ window: AXUIElement, app: AXUIElement, pid: pid_t, play: AXUIElement, record: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        let ax = runtime.ax
        guard !Task.isCancelled, runtime.logicProPID() == pid, foreground(pid, runtime: runtime),
              let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: ax),
              let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: ax),
              case .success(let children) = AXHelpers.childrenResult(window, runtime: ax),
              let playing: NSNumber = AXHelpers.getAttribute(play, kAXValueAttribute, runtime: ax),
              let recording: NSNumber = AXHelpers.getAttribute(record, kAXValueAttribute, runtime: ax)
        else { return false }
        let documents = windows.filter { AXHelpers.getRole($0, runtime: ax) != kAXHelpTagRole }
        return documents.count == 1 && CFEqual(documents[0], window) && CFEqual(focus, window)
            && !children.contains { AXHelpers.getRole($0, runtime: ax) == kAXSheetRole }
            && playing.intValue == 0 && recording.intValue == 0
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
