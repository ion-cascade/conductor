@preconcurrency import ApplicationServices
import AVFoundation
import Darwin
import Foundation

/// Measured Logic 13 path for a single selected audio region in a saved package.
@MainActor
struct ProjectLogic13StemSplitter {
    private static let labels = ["Vocals", "Drums", "Bass", "Guitar", "Piano", "Other"]
    private static let operation = "track.split_selected_audio"
    private enum Failure: Error { case unavailable(String) }

    private let runtime: AXLogicProElements.Runtime
    private let window: AXUIElement
    private let app: AXUIElement
    private let pid: pid_t
    private let document: String
    private let name: String
    private let bounds: ArrangeRegionBounds
    private let trackIndex: Int
    private let media: URL

    static func run(
        params: [String: String], runtime: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        guard let binding = AXTrackBinding.current, let trackIndex = binding.currentIndex(),
              let name = params["region_name"], !name.isEmpty, !name.contains("/"),
              let start = params["start"], let end = params["end"], start != end,
              let pid = runtime.logicProPID(),
              runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true,
              let app = AXLogicProElements.appRoot(runtime: runtime),
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(binding.window, runtime: runtime),
              let url = URL(string: document), url.isFileURL, url.pathExtension == "logicx"
        else { return refusal("saved_project_or_track") }
        let media = url.appendingPathComponent("Media/Audio Files", isDirectory: true)
        let package = url.standardizedFileURL.resolvingSymlinksInPath()
        guard media.resolvingSymlinksInPath().path == package.appendingPathComponent("Media/Audio Files").path else {
            return refusal("project_media_custody")
        }
        let workflow = Self(runtime: runtime, window: binding.window, app: app, pid: pid, document: document,
                            name: name, bounds: .init(start: start, end: end), trackIndex: trackIndex, media: media)
        return await workflow.split(binding: binding)
    }

    private static func refusal(_ stage: String) -> ChannelResult {
        .error(HonestContract.encodeStateC(
            error: .readbackUnavailable,
            hint: "Select one audio region on the referenced track in a saved Logic 13 project. Its name and boundaries must match the request.",
            extras: ["operation": operation, "stage": stage, "write_attempted": false]))
    }

    private func split(binding: AXTrackBinding.Binding) async -> ChannelResult {
        var menu: AXUIElement?
        var sheet: AXUIElement?
        var attempted = false
        do {
            guard holdsProject(), focusedWindow(), popupFrames()?.isEmpty == true, sheets().isEmpty,
                  AXLogicProElements.dialogPresenceReason(runtime: runtime) == .noBlockingWindow,
                  let transport = try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime, checking: {}),
                  !transport.isPlaying, !transport.isRecording,
                  let region = selectedSource(binding), let directory = directoryFiles()
            else { throw Failure.unavailable("selected_audio_region") }
            let input = directory.filter {
                $0.deletingPathExtension().lastPathComponent == name && ["wav", "aif", "aiff"].contains($0.pathExtension.lowercased())
            }
            let expected = Self.labels.map { media.appendingPathComponent("\(name)_\($0).aif") }
            guard input.count == 1, let source = audioFile(input[0]),
                  expected.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }),
                  AXHelpers.getActionNames(region, runtime: runtime.ax).contains(kAXShowMenuAction)
            else { throw Failure.unavailable("source_or_output_files") }

            _ = AXHelpers.performAction(region, kAXShowMenuAction, runtime: runtime.ax)
            let opened = try await wait("region_context_menu", attempts: 30) { contextMenu() }
            menu = opened
            let processing = try only(children(opened).filter { role($0) == kAXMenuItemRole && title($0) == "Processing" },
                                      "processing_category")
            let submenu = try only(children(processing).filter { role($0) == kAXMenuRole }, "processing_submenu")
            let action = try only(children(submenu).filter { role($0) == kAXMenuItemRole && title($0) == "Stem Splitter…" },
                                  "stem_splitter_action")
            guard enabled(action), selectedSource(binding).map({ CFEqual($0, region) }) == true,
                  contextMenu().map({ CFEqual($0, opened) }) == true else {
                throw Failure.unavailable("context_menu_ownership")
            }
            _ = AXHelpers.performAction(action, "AXPick", runtime: runtime.ax)
            let panel = try await wait("splitter_sheet", attempts: 35) {
                let observed = sheets()
                guard observed.count <= 1 else { throw Failure.unavailable("multiple_sheets") }
                guard let candidate = observed.first, isSplitterSheet(candidate) else { return nil }
                return candidate
            }
            menu = nil
            sheet = panel
            let controls = descendants(panel, depth: 7)
            let apply = try control("Apply", role: kAXButtonRole, in: controls)
            let kit = try only(controls.filter {
                text($0, kAXIdentifierAttribute) == "isDrumsSubstemsVisibleToggle"
            }, "kit_pieces_switch")
            let submix = try control("Submix", role: kAXCheckBoxRole, in: controls)
            guard controls.filter({ role($0) == kAXPopUpButtonRole && text($0, kAXValueAttribute) == "Separate All Stems" }).count == 1,
                  value(kit) == 0, value(submix) == 0 else { throw Failure.unavailable("separate_all_stems_preset") }
            for label in Self.labels {
                let checkbox = try control(label, role: kAXCheckBoxRole, in: controls)
                guard value(checkbox) == 1 else { throw Failure.unavailable("stem_selection:\(label)") }
            }
            guard holdsProject(), sheets().count == 1, sheets().contains(panel), isSplitterSheet(panel) else {
                throw Failure.unavailable("splitter_sheet_ownership")
            }
            guard enabled(apply) else { throw Failure.unavailable("splitter_apply_disabled") }
            // The modal sheet owns the original Arrange window. Its focus
            // suppresses ordinary track-reference resolution while it is open.
            // Recheck the retained region itself under the same document.
            guard (AXHelpers.getAttribute(region, kAXSelectedAttribute, runtime: runtime.ax) as Bool?) == true,
                  regionName(region) == name, audioBounds(region) == bounds else {
                throw Failure.unavailable("splitter_selected_source_changed")
            }
            // Logic reserves the six names with 512-byte placeholder files
            // as soon as the sheet opens. Before the menu action, those names
            // were all absent. Check that the sheet created only this set.
            guard let reserved = directoryFiles(),
                  Set(reserved.map(\.path)) == Set((directory + expected).map(\.path)),
                  expected.allSatisfy(isNativeReservation) else {
                throw Failure.unavailable("splitter_output_reservations")
            }
            guard !Task.isCancelled, OperationTraceContext.claimDeadlineEffect("stem_splitter_apply") else {
                throw Failure.unavailable("splitter_apply_deadline")
            }
            attempted = true
            _ = AXHelpers.performAction(apply, kAXPressAction, runtime: runtime.ax)
            sheet = nil

            for _ in 0..<95 {
                try await Task.sleep(for: .milliseconds(350))
                guard holdsProject() else { throw Failure.unavailable("project_changed_after_split") }
                guard sheets().isEmpty, let files = directoryFiles(),
                      Set(files.map(\.path)) == Set((directory + expected).map(\.path)),
                      let regionEvidence = observedRegions(binding: binding) else { continue }
                let outputs = expected.compactMap(audioFile)
                guard outputs.count == expected.count, outputs.allSatisfy({ $0.rate == source.rate
                    && $0.channels == source.channels && $0.frames == source.frames }) else { continue }

                return .success(HonestContract.encodeStateA(extras: [
                    "operation": Self.operation, "write_attempted": true,
                    "source_region": name, "source_muted": true,
                    "start": bounds.start, "end": bounds.end, "verify_source": "ax_arrange_and_project_media",
                    "separation": "logic_pro_estimated_stems", "save_required": true,
                    "stems": zip(zip(Self.labels, expected), zip(outputs, regionEvidence)).map { pair in
                        let ((label, path), (audio, track)) = pair
                        return ["stem": label.lowercased(), "path": path.path, "track": track,
                                "sample_rate": audio.rate, "channels": audio.channels, "frames": audio.frames] as [String: Any]
                    },
                ]))
            }
            throw Failure.unavailable("splitter_outputs_not_verified")
        } catch {
            let stage: String
            if case Failure.unavailable(let detail) = error { stage = detail } else { stage = "cancelled_or_interrupted" }
            if !attempted {
                if let menu, contextMenu().map({ CFEqual($0, menu) }) == true {
                    _ = AXHelpers.performAction(menu, kAXCancelAction, runtime: runtime.ax)
                }
                if let sheet, holdsProject(), sheets().contains(sheet), isSplitterSheet(sheet),
                   let cancel = try? control("Cancel", role: kAXButtonRole, in: descendants(sheet, depth: 5)) {
                    _ = AXHelpers.performAction(cancel, kAXPressAction, runtime: runtime.ax)
                }
                return Self.refusal(stage)
            }
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: [
                "operation": Self.operation, "stage": stage, "write_attempted": true,
                "effect_unknown": true, "safe_to_retry": false,
            ]))
        }
    }

    private func selectedSource(_ binding: AXTrackBinding.Binding) -> AXUIElement? {
        guard binding.currentIndex() == trackIndex,
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              headers.indices.contains(trackIndex), CFEqual(headers[trackIndex], binding.header),
              let content = AXLogicProElements.logic13TrackContent(in: window, runtime: runtime),
              let items = AXLogicProElements.logic13RegionItems(in: content, runtime: runtime.ax) else { return nil }
        var selected: [AXUIElement] = []
        for item in items {
            guard let isSelected: Bool = AXHelpers.getAttribute(item, kAXSelectedAttribute, runtime: runtime.ax) else { return nil }
            if isSelected { selected.append(item) }
        }
        guard selected.count == 1, let region = selected.first, regionName(region) == name,
              audioBounds(region) == bounds,
              AXLogicProElements.logic13RegionTrackIndex(region, in: content, headers: headers, runtime: runtime.ax) == trackIndex
        else { return nil }
        return region
    }

    private func observedRegions(binding: AXTrackBinding.Binding) -> [Int]? {
        guard case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              headers.indices.contains(trackIndex), CFEqual(headers[trackIndex], binding.header),
              let content = AXLogicProElements.logic13TrackContent(in: window, runtime: runtime),
              let items = AXLogicProElements.logic13RegionItems(in: content, runtime: runtime.ax) else { return nil }
        let originals = items.filter { regionName($0) == name + ", muted" && audioBounds($0) == bounds }
        guard originals.count == 1, let original = originals.first,
              AXLogicProElements.logic13RegionTrackIndex(original, in: content, headers: headers, runtime: runtime.ax) == trackIndex
        else { return nil }
        var tracks: [Int] = []
        for label in Self.labels {
            let matches = items.filter { regionName($0) == "\(name) (\(label))" && audioBounds($0) == bounds }
            guard matches.count == 1, let region = matches.first,
                  let index = AXLogicProElements.logic13RegionTrackIndex(region, in: content, headers: headers, runtime: runtime.ax),
                  index > trackIndex, !tracks.contains(index) else { return nil }
            tracks.append(index)
        }
        return tracks
    }

    private func audioBounds(_ item: AXUIElement) -> ArrangeRegionBounds? {
        guard let help = AXHelpers.getHelp(item, runtime: runtime.ax), help.contains("Audio region.") else { return nil }
        return ArrangeRegionBounds.read(from: help)
    }

    private func directoryFiles() -> [URL]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: media,
            includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]), urls.count <= 512
        else { return nil }
        return urls
    }

    private func isNativeReservation(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) } == 0
            && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
            && info.st_uid == getuid() && info.st_size == 512
    }

    private func audioFile(_ url: URL) -> (rate: Double, channels: UInt32, frames: Int64)? {
        guard url.deletingLastPathComponent().path == media.path,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink == false,
              let file = try? AVAudioFile(forReading: url), file.length > 0
        else { return nil }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { return nil }
        file.framePosition = file.length - 1
        guard (try? file.read(into: buffer, frameCount: 1)) != nil, buffer.frameLength == 1 else { return nil }
        return (format.sampleRate, format.channelCount, file.length)
    }

    private func wait(
        _ stage: String, attempts: Int, observe: () throws -> AXUIElement?
    ) async throws -> AXUIElement {
        for _ in 0..<attempts {
            try Task.checkCancellation()
            guard holdsProject() else { throw Failure.unavailable("project_custody_lost:\(stage)") }
            if let found = try observe() { return found }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.unavailable(stage)
    }

    private func contextMenu() -> AXUIElement? {
        guard holdsProject(), let frames = popupFrames(), frames.count == 1, let frame = frames.first,
              let hitTest = runtime.ax.elementAtPosition,
              case .success(.some(let hit)) = hitTest(app, CGPoint(x: frame.midX, y: frame.midY)),
              let menu: AXUIElement = AXHelpers.getAttribute(hit, kAXParentAttribute, runtime: runtime.ax),
              role(hit) == kAXMenuItemRole, role(menu) == kAXMenuRole,
              let p = AXHelpers.getPosition(menu, runtime: runtime.ax), let s = AXHelpers.getSize(menu, runtime: runtime.ax),
              frame.contains(CGRect(origin: p, size: s)), children(menu).contains(hit),
              children(menu).filter({ title($0) == "Processing" }).count == 1 else { return nil }
        return menu
    }

    private func popupFrames() -> [CGRect]? {
        runtime.onScreenWindowList().map { windows in
            LogicOnScreenWindows.logicOwned(windows, logicPID: pid)
                .filter { $0.layer == LogicOnScreenWindows.popupMenuLevel }
                .compactMap(\.bounds)
        }
    }

    private func isSplitterSheet(_ sheet: AXUIElement) -> Bool {
        descendants(sheet, depth: 4).filter {
            role($0) == kAXStaticTextRole && text($0, kAXValueAttribute) == "Stem Splitter"
        }.count == 1
    }
    private func focusedWindow() -> Bool {
        guard let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: runtime.ax) else { return false }
        return CFEqual(focused, window) || sheets().contains(focused)
    }
    private func holdsProject() -> Bool {
        guard runtime.focusedApplicationPID() == pid,
              let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax),
              windows.contains(window),
              case .success(.some(let current)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime)
        else { return false }
        return current == document
    }
    private func sheets() -> [AXUIElement] { children(window).filter { role($0) == kAXSheetRole } }
    private func children(_ element: AXUIElement) -> [AXUIElement] { AXHelpers.getChildren(element, runtime: runtime.ax) }
    private func descendants(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        let nodes = children(element)
        return nodes + nodes.flatMap { descendants($0, depth: depth - 1) }
    }
    private func only(_ elements: [AXUIElement], _ stage: String) throws -> AXUIElement {
        guard elements.count == 1, let element = elements.first else { throw Failure.unavailable(stage) }
        return element
    }
    private func control(_ label: String, role expectedRole: String, in nodes: [AXUIElement]) throws -> AXUIElement {
        try only(nodes.filter { role($0) == expectedRole && text($0, kAXDescriptionAttribute) == label }, label)
    }
    private func role(_ element: AXUIElement) -> String? { AXHelpers.getRole(element, runtime: runtime.ax) }
    private func title(_ element: AXUIElement) -> String? { text(element, kAXTitleAttribute) }
    private func regionName(_ element: AXUIElement) -> String? { text(element, kAXDescriptionAttribute) }
    private func text(_ element: AXUIElement, _ key: String) -> String? { AXHelpers.getAttribute(element, key, runtime: runtime.ax) }
    private func value(_ element: AXUIElement) -> Int? { AXHelpers.getAttribute(element, kAXValueAttribute, runtime: runtime.ax) }
    private func enabled(_ element: AXUIElement) -> Bool { (AXHelpers.getAttribute(element, kAXEnabledAttribute, runtime: runtime.ax) as Bool?) == true }
}
