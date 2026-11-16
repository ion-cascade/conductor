@preconcurrency import ApplicationServices
import AVFoundation
import Darwin
import Foundation

/// Measured Logic 13 path for a single selected audio region in a saved package.
@MainActor
struct ProjectLogic13StemSplitter {
    enum Preset: String, CaseIterable {
        case allStems = "all_stems"
        case drumKitPieces = "drum_kit_pieces"

        var nativeTitle: String {
            switch self {
            case .allStems: "Separate All Stems"
            case .drumKitPieces: "Drums (Individual Kit Pieces)"
            }
        }

        var labels: [String] {
            switch self {
            case .allStems: ["Vocals", "Drums", "Bass", "Guitar", "Piano", "Other"]
            case .drumKitPieces: ["Kick", "Snare", "Hi-Hat", "Toms", "Cymbals", "Drums Other"]
            }
        }
    }

    private struct ArrangementEvidence {
        let tracks: [Int]
        let stackName: String?
    }
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
    private let preset: Preset

    static func run(
        params: [String: String], runtime: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        guard let preset = Preset(rawValue: params["preset"] ?? Preset.allStems.rawValue) else {
            return .error(HonestContract.encodeStateC(error: .invalidParams,
                hint: "Use all_stems or drum_kit_pieces.",
                extras: ["operation": operation, "write_attempted": false]))
        }
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
                            name: name, bounds: .init(start: start, end: end), trackIndex: trackIndex,
                            media: media, preset: preset)
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
            let originalTrackName = trackName(binding.header)
            let input = directory.filter {
                $0.deletingPathExtension().lastPathComponent == name && ["wav", "aif", "aiff"].contains($0.pathExtension.lowercased())
            }
            let expected = outputFiles(preset)
            // On Logic 13.0 the sheet initially reserves the broad-stem names
            // even when its remembered preset is the individual kit pieces.
            let reservations = outputFiles(.allStems)
            let occupiedNames = Set(directory.map(\.lastPathComponent))
            guard input.count == 1, let source = audioFile(input[0]),
                  (expected + reservations).allSatisfy({ !occupiedNames.contains($0.lastPathComponent) }),
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
            try await selectPreset(in: panel)
            let controls = descendants(panel, depth: 7)
            let apply = try control("Apply", role: kAXButtonRole, in: controls)
            try verifyPresetControls(controls)
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
                  Set(reserved.map(\.path)) == Set((directory + reservations).map(\.path)),
                  reservations.allSatisfy(isNativeReservation) else {
                throw Failure.unavailable("splitter_output_reservations")
            }
            guard !Task.isCancelled, OperationTraceContext.claimDeadlineEffect("stem_splitter_apply") else {
                throw Failure.unavailable("splitter_apply_deadline")
            }
            attempted = true
            _ = AXHelpers.performAction(apply, kAXPressAction, runtime: runtime.ax)
            sheet = nil

            var readbackStage = "splitter_project_readback_unavailable"
            for _ in 0..<80 {
                try await Task.sleep(for: .milliseconds(750))
                // Logic can rebuild its Arrange presentation after splitting.
                // Reacquire read-only custody from the same process and exact
                // document, then use that single window for the observations.
                guard let observedWindow = readbackWindow() else { continue }
                readbackStage = "splitter_assets_not_observed"
                guard let files = directoryFiles(),
                      Set(files.map(\.path)) == Set((directory + expected).map(\.path)) else { continue }
                readbackStage = "splitter_arrangement_not_observed"
                guard let regionEvidence = observedRegions(in: observedWindow, original: region,
                    header: binding.header, originalTrackName: originalTrackName) else { continue }
                readbackStage = "splitter_audio_extent_not_observed"
                let outputs = expected.compactMap(audioFile)
                guard outputs.count == expected.count, outputs.allSatisfy({ $0.rate == source.rate
                    && $0.channels == source.channels && $0.frames == source.frames }) else { continue }

                var receipt: [String: Any] = [
                    "operation": Self.operation, "write_attempted": true, "preset": preset.rawValue,
                    "source_region": name, "source_muted": true,
                    "start": bounds.start, "end": bounds.end, "verify_source": "ax_arrange_and_project_media",
                    "separation": "logic_pro_estimated_stems", "save_required": true,
                    "stems": zip(zip(preset.labels, expected), zip(outputs, regionEvidence.tracks)).map { pair in
                        let ((label, path), (audio, track)) = pair
                        return ["stem": label.lowercased(), "path": path.path, "track": track,
                                "sample_rate": audio.rate, "channels": audio.channels, "frames": audio.frames] as [String: Any]
                    },
                ]
                if let stackName = regionEvidence.stackName {
                    receipt["drum_stack"] = ["name": stackName, "track": trackIndex + 1,
                                             "child_tracks": regionEvidence.tracks] as [String: Any]
                }
                return .success(HonestContract.encodeStateA(extras: receipt))
            }
            throw Failure.unavailable(readbackStage)
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

    private func observedRegions(
        in observedWindow: AXUIElement, original retainedRegion: AXUIElement,
        header retainedHeader: AXUIElement, originalTrackName: String?
    ) -> ArrangementEvidence? {
        guard case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: observedWindow, runtime: runtime),
              headers.indices.contains(trackIndex),
              let content = AXLogicProElements.logic13TrackContent(in: observedWindow, runtime: runtime),
              let items = AXLogicProElements.logic13RegionItems(in: content, runtime: runtime.ax) else { return nil }
        let originals = items.filter { regionName($0) == name + ", muted" && audioBounds($0) == bounds }
        guard originals.count == 1, let original = originals.first,
              AXLogicProElements.logic13RegionTrackIndex(original, in: content, headers: headers, runtime: runtime.ax) == trackIndex
        else { return nil }
        if !CFEqual(original, retainedRegion), !CFEqual(headers[trackIndex], retainedHeader) {
            // Rebuilt AX objects need another positive witness for the same lane.
            let names = headers.compactMap(trackName)
            guard let originalTrackName, names.count == headers.count, names[trackIndex] == originalTrackName,
                  names.filter({ $0 == originalTrackName }).count == 1 else { return nil }
        }
        var tracks: [Int] = []
        for label in preset.labels {
            let matches = items.filter { regionName($0) == "\(name) (\(label))" && audioBounds($0) == bounds }
            guard matches.count == 1, let region = matches.first,
                  let index = AXLogicProElements.logic13RegionTrackIndex(region, in: content, headers: headers, runtime: runtime.ax),
                  index > trackIndex, !tracks.contains(index) else { return nil }
            tracks.append(index)
        }
        if preset == .allStems { return ArrangementEvidence(tracks: tracks, stackName: nil) }
        let stackIndex = trackIndex + 1
        let stackName = name + " (Drums)"
        guard headers.indices.contains(stackIndex), trackName(headers[stackIndex]) == stackName,
              headers.filter({ trackName($0) == stackName }).count == 1,
              tracks == Array((stackIndex + 1)...(stackIndex + preset.labels.count)) else { return nil }
        let stack = AXValueExtractors.extractTrackStackState(from: headers[stackIndex], runtime: runtime.ax)
        guard stack.isStackHeader == true, stack.collapsed == false,
              zip(tracks, preset.labels).allSatisfy({ index, label in
                  trackName(headers[index]) == "\(name) (\(label))"
                      && AXValueExtractors.extractTrackStackState(from: headers[index], runtime: runtime.ax).isStackHeader == false
              }) else { return nil }
        return ArrangementEvidence(tracks: tracks, stackName: stackName)
    }

    private func outputFiles(_ mode: Preset) -> [URL] {
        mode.labels.map { media.appendingPathComponent("\(name)_\($0).aif") }
    }

    private func selectPreset(in panel: AXUIElement) async throws {
        func popups() -> [AXUIElement] {
            descendants(panel, depth: 7).filter { role($0) == kAXPopUpButtonRole }
        }
        func ownsSheet() -> Bool {
            holdsProject() && sheets() == [panel] && isSplitterSheet(panel)
        }
        // The sheet can be visible before the SwiftUI popup accepts input.
        try await Task.sleep(for: .milliseconds(500))
        let popup = try only(popups(), "splitter_preset_control")
        if text(popup, kAXValueAttribute) == preset.nativeTitle { return }
        guard ownsSheet(), enabled(popup), popupFrames()?.isEmpty == true else {
            throw Failure.unavailable("splitter_preset_ownership")
        }
        _ = AXHelpers.performAction(popup, kAXPressAction, runtime: runtime.ax)
        do {
            var menu: AXUIElement?
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                guard ownsSheet() else { throw Failure.unavailable("splitter_preset_sheet_changed") }
                if let ready = presetMenu(for: popup) {
                    menu = ready
                    break
                }
            }
            if menu == nil, ownsSheet(), popups() == [popup], popupFrames()?.isEmpty == true,
               children(popup).allSatisfy({ role($0) != kAXMenuRole }), pressPresetPopupAtNativePoint(popup) {
                menu = try await wait("splitter_preset_menu", attempts: 18) {
                    guard ownsSheet() else { throw Failure.unavailable("splitter_preset_sheet_changed") }
                    return presetMenu(for: popup)
                }
            }
            guard let menu else { throw Failure.unavailable("splitter_preset_menu") }
            let choice = try only(children(menu).filter {
                role($0) == kAXMenuItemRole && title($0) == preset.nativeTitle
            }, "splitter_preset_option")
            guard ownsSheet(), presetMenu(for: popup).map({ CFEqual($0, menu) }) == true,
                  enabled(choice), !Task.isCancelled else {
                throw Failure.unavailable("splitter_preset_option_ownership")
            }
            _ = AXHelpers.performAction(choice, kAXPressAction, runtime: runtime.ax)
            _ = try await wait("splitter_preset_readback", attempts: 20) {
                guard ownsSheet() else { throw Failure.unavailable("splitter_preset_sheet_changed") }
                return popups().first(where: { text($0, kAXValueAttribute) == preset.nativeTitle })
            }
        } catch {
            if ownsSheet(), let menu = presetMenu(for: popup) {
                _ = AXHelpers.performAction(menu, kAXCancelAction, runtime: runtime.ax)
            }
            throw error
        }
    }

    private func presetMenu(for popup: AXUIElement) -> AXUIElement? {
        let attached = children(popup).filter { role($0) == kAXMenuRole }
        guard attached.count <= 1 else { return nil }
        if let menu = attached.first, isPresetMenu(menu) { return menu }
        guard let frames = popupFrames(), frames.count == 1, let frame = frames.first,
              let position = AXHelpers.getPosition(popup, runtime: runtime.ax),
              let size = AXHelpers.getSize(popup, runtime: runtime.ax),
              frame.intersects(CGRect(origin: position, size: size).insetBy(dx: -4, dy: -4)),
              let hitTest = runtime.ax.elementAtPosition,
              case .success(.some(let hit)) = hitTest(app, CGPoint(x: frame.midX, y: frame.midY)),
              role(hit) == kAXMenuItemRole,
              let menu: AXUIElement = AXHelpers.getAttribute(hit, kAXParentAttribute, runtime: runtime.ax),
              children(menu).contains(hit), isPresetMenu(menu) else { return nil }
        return menu
    }

    private func isPresetMenu(_ menu: AXUIElement) -> Bool {
        let options = children(menu).filter { role($0) == kAXMenuItemRole }
        return role(menu) == kAXMenuRole && Preset.allCases.allSatisfy { mode in
            options.filter { title($0) == mode.nativeTitle }.count == 1
        }
    }

    private func pressPresetPopupAtNativePoint(_ popup: AXUIElement) -> Bool {
        guard !Task.isCancelled, enabled(popup), CGPreflightPostEventAccess(),
              let position = AXHelpers.getPosition(popup, runtime: runtime.ax),
              let size = AXHelpers.getSize(popup, runtime: runtime.ax), size.width > 4, size.height > 4,
              let hitTest = runtime.ax.elementAtPosition else { return false }
        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        guard case .success(.some(let hit)) = hitTest(app, center), CFEqual(hit, popup),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)
        else { return false }
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    private func verifyPresetControls(_ controls: [AXUIElement]) throws {
        let popup = try only(controls.filter { role($0) == kAXPopUpButtonRole }, "splitter_preset_control")
        let kit = try only(controls.filter {
            role($0) == kAXCheckBoxRole && text($0, kAXIdentifierAttribute) == "isDrumsSubstemsVisibleToggle"
        }, "kit_pieces_switch")
        let submix = try control("Submix", role: kAXCheckBoxRole, in: controls)
        guard text(popup, kAXValueAttribute) == preset.nativeTitle,
              value(kit) == (preset == .drumKitPieces ? 1 : 0), value(submix) == 0 else {
            throw Failure.unavailable("splitter_preset_state")
        }
        for label in preset.labels {
            let checkbox = try control(label, role: kAXCheckBoxRole, in: controls)
            guard value(checkbox) == 1 else { throw Failure.unavailable("stem_selection:\(label)") }
        }
        if preset == .drumKitPieces {
            for label in Preset.allStems.labels where label != "Drums" {
                let checkbox = try control(label, role: kAXCheckBoxRole, in: controls)
                guard value(checkbox) == 0 else { throw Failure.unavailable("unexpected_stem_selection:\(label)") }
            }
        }
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
    private func readbackWindow() -> AXUIElement? {
        guard runtime.onScreenWindowList() != nil, runtime.logicProPID() == pid,
              let currentApp = AXLogicProElements.appRoot(runtime: runtime),
              let windows: [AXUIElement] = AXHelpers.getAttribute(currentApp, kAXWindowsAttribute, runtime: runtime.ax)
        else { return nil }
        let matches = windows.filter { candidate in
            guard role(candidate) == kAXWindowRole,
                  text(candidate, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                  case .success(.some(let current)) = AXLogicProElements.projectPickerDocumentRead(candidate, runtime: runtime)
            else { return false }
            return current == document
        }
        guard matches.count == 1, let match = matches.first,
              !children(match).contains(where: { role($0) == kAXSheetRole && isSplitterSheet($0) }) else { return nil }
        return match
    }

    private func trackName(_ header: AXUIElement) -> String? {
        try? AXValueExtractors.extractTrackNameResult(from: header, runtime: runtime.ax).get()
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
