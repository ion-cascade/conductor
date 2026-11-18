import ApplicationServices
import Foundation

/// A saved, stopped Logic 13 document owns every settings and export panel.
@MainActor
struct ProjectSpatialExport {
    enum Failure: Error { case unavailable(String) }

    let runtime: AXLogicProElements.Runtime
    let pid: pid_t
    let app: AXUIElement
    let window: AXUIElement
    let document: String
    let projectPath: String

    struct Settings: Codable, Equatable {
        let surround: String
        let spatialAudio: String
        let sampleRate: String
    }

    static func acquire(projectPath: String, runtime: AXLogicProElements.Runtime = .production) -> Self? {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(),
              let pid = runtime.logicProPID(), runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true,
              let app = AXLogicProElements.appRoot(runtime: runtime),
              case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              let url = URL(string: document), url.isFileURL,
              AppleScriptChannel.projectPathsMatch(projectPath, url.path),
              AXLogicProElements.dialogPresenceReason(runtime: runtime) == .noBlockingWindow else { return nil }
        let source = Self(runtime: runtime, pid: pid, app: app, window: window, document: document, projectPath: projectPath)
        guard source.holdsProject(), source.focused(window), source.stopped() else { return nil }
        return source
    }

    func holdsProject() -> Bool {
        runtime.logicProPID() == pid && ProjectScore.foreground(pid, runtime: runtime)
            && windows()?.contains(where: { CFEqual($0, window) }) == true
            && (try? AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime).get()) == document
    }

    func settings() async throws -> Settings {
        guard holdsProject(), focused(window), stopped(),
              let file = menu(["File"]), let projectSettings = menu(["File", "Project Settings"])
        else { throw Failure.unavailable("project_settings_menu") }
        var owned: AXUIElement?
        do {
            guard AXHelpers.performAction(file, kAXPressAction, runtime: runtime.ax),
                  AXHelpers.performAction(projectSettings, kAXPressAction, runtime: runtime.ax),
                  let audio = menu(["File", "Project Settings", "Audio…"]),
                  AXHelpers.performAction(audio, kAXPressAction, runtime: runtime.ax)
            else { throw Failure.unavailable("project_settings_audio") }
            let panel = try await wait {
                guard let windows = windows(), windows.count <= 2 else { throw Failure.unavailable("settings_window_population") }
                return windows.first { !CFEqual($0, window) && AXHelpers.getTitle($0, runtime: runtime.ax) == title + " - Project Settings" && focused($0) }
            }
            owned = panel
            guard focused(panel) else { throw Failure.unavailable("settings_focus") }
            let controls = try descendants(panel)
            func value(_ prefix: String) throws -> String {
                let matches = controls.filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXPopUpButtonRole
                    && (AXHelpers.getAttribute($0, kAXHelpAttribute, runtime: runtime.ax) as String?)?.hasPrefix(prefix) == true }
                guard matches.count == 1,
                      let value: String = AXHelpers.getAttribute(matches[0], kAXValueAttribute, runtime: runtime.ax)
                else { throw Failure.unavailable("settings_readback") }
                return value
            }
            let result = try Settings(surround: value("Surround Format pop-up menu."),
                                      spatialAudio: value("Spatial Audio pop-up menu."),
                                      sampleRate: value("Sample Rate pop-up menu."))
            try closeSettings(panel)
            owned = nil
            _ = try await wait { focused(window) ? window : nil }
            guard holdsProject(), stopped() else { throw Failure.unavailable("settings_project_changed") }
            return result
        } catch {
            if let owned { try? closeSettings(owned) }
            throw error
        }
    }

    func exportADM(to output: URL, settings expected: Settings,
                   didWrite: @MainActor () async -> Void) async throws {
        let keyboard = MIDITrackExportPanel.Keyboard.withFocus { _, observedPID in observedPID == pid && holdsProject() }
        let writer = MIDITrackExportPanel(window: window, document: document, runtime: runtime,
                                         keyboard: keyboard, permittingAction: { holdsProject() })
        guard holdsProject(), focused(window), stopped(),
              try await settings() == expected,
              let file = menu(["File"]), let export = menu(["File", "Export"])
        else { throw Failure.unavailable("adm_project_changed") }
        var panel: AXUIElement?
        do {
            guard AXHelpers.performAction(file, kAXPressAction, runtime: runtime.ax),
                  AXHelpers.performAction(export, kAXPressAction, runtime: runtime.ax),
                  let command = menu(["File", "Export", "Project as Spatial Audio…"]),
                  enabled(command), holdsProject(), focused(window),
                  OperationTraceContext.claimDeadlineEffect("spatial_export_panel", rejectTaskCancellationWithoutContext: true)
            else { throw Failure.unavailable("adm_menu_unavailable") }
            _ = AXHelpers.performAction(command, kAXPressAction, runtime: runtime.ax)
            await didWrite()
            let acquired = try await wait {
                guard let windows = windows(), windows.count <= 2 else { throw Failure.unavailable("export_window_population") }
                return windows.first {
                    AXHelpers.getIdentifier($0, runtime: runtime.ax) == "save-panel"
                        && AXHelpers.getTitle($0, runtime: runtime.ax) == "Export Spatial Audio File as…"
                        && focused($0)
                }
            }
            panel = acquired
            let controls = try descendants(acquired)
            let format = controls.filter { AXHelpers.getDescription($0, runtime: runtime.ax) == "Export Format" }
            let project = controls.filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXRadioButtonRole
                && AXHelpers.getDescription($0, runtime: runtime.ax) == "Project" }
            guard format.count == 1,
                  (AXHelpers.getAttribute(format[0], kAXValueAttribute, runtime: runtime.ax) as String?) == "Dolby Atmos ADM BWF",
                  project.count == 1, holdsProject(), focused(acquired),
                  AXHelpers.performAction(project[0], kAXPressAction, runtime: runtime.ax),
                  (AXHelpers.getAttribute(project[0], kAXValueAttribute, runtime: runtime.ax) as NSNumber?)?.intValue == 1
            else { throw Failure.unavailable("adm_format_or_project_range") }
            var stage = "adm_save"
            try await writer.saveOpenedPanel(acquired, to: output, stage: &stage) {
                guard holdsProject(), focused(acquired),
                      (AXHelpers.getAttribute(format[0], kAXValueAttribute, runtime: runtime.ax) as String?) == "Dolby Atmos ADM BWF",
                      (AXHelpers.getAttribute(project[0], kAXValueAttribute, runtime: runtime.ax) as NSNumber?)?.intValue == 1
                else { throw Failure.unavailable("adm_save_scope") }
            }
            panel = nil
            var previous: (UInt64, Date)?
            for _ in 0..<240 {
                try Task.checkCancellation()
                guard holdsProject() else { throw Failure.unavailable("adm_project_changed") }
                if let metadata = try? FileManager.default.attributesOfItem(atPath: output.path),
                   metadata[.type] as? FileAttributeType == .typeRegular,
                   let size = metadata[.size] as? NSNumber, let modified = metadata[.modificationDate] as? Date {
                    let current = (size.uint64Value, modified)
                    if let previous, current == previous, (try? ProjectADMArtifact.read(output)) != nil { return }
                    previous = current
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw Failure.unavailable("adm_artifact_incomplete")
        } catch {
            if let panel { _ = await writer.recoverOwnedPanel(panel, app: app, originalWindows: [window]) }
            throw error
        }
    }

    private var title: String { URL(fileURLWithPath: projectPath).deletingPathExtension().lastPathComponent }

    private func stopped() -> Bool {
        guard let activity = try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime, checking: {}) else { return false }
        return !activity.isPlaying && !activity.isRecording
    }

    private func closeSettings(_ panel: AXUIElement) throws {
        let buttons = AXHelpers.getChildren(panel, runtime: runtime.ax).filter {
            (AXHelpers.getAttribute($0, kAXSubroleAttribute, runtime: runtime.ax) as String?) == kAXCloseButtonSubrole
        }
        guard holdsProject(), focused(panel), buttons.count == 1,
              AXHelpers.performAction(buttons[0], kAXPressAction, runtime: runtime.ax) else {
            throw Failure.unavailable("settings_close_custody")
        }
    }

    private func menu(_ path: [String]) -> AXUIElement? {
        guard var root: AXUIElement = AXHelpers.getAttribute(app, kAXMenuBarAttribute, runtime: runtime.ax) else { return nil }
        for segment in path {
            guard case .success(let children) = AXHelpers.childrenResult(root, runtime: runtime.ax) else { return nil }
            let entries = children.flatMap { child in
                AXHelpers.getRole(child, runtime: runtime.ax) == kAXMenuRole
                    ? AXHelpers.getChildren(child, runtime: runtime.ax) : [child]
            }
            let matches = entries.filter { AXHelpers.getTitle($0, runtime: runtime.ax) == segment }
            guard matches.count == 1, let next = matches.first else { return nil }
            root = next
        }
        return root
    }

    private func windows() -> [AXUIElement]? {
        let windows: [AXUIElement]? = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax)
        return windows?.filter { AXHelpers.getRole($0, runtime: runtime.ax) != kAXHelpTagRole }
    }

    private func enabled(_ element: AXUIElement) -> Bool {
        (AXHelpers.getAttribute(element, kAXEnabledAttribute, runtime: runtime.ax) as NSNumber?)?.boolValue == true
    }

    private func focused(_ element: AXUIElement) -> Bool {
        guard let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: runtime.ax) else { return false }
        return CFEqual(focused, element)
    }

    private func descendants(_ root: AXUIElement) throws -> [AXUIElement] {
        var nodes = [(root, 0)]
        var cursor = 0
        while cursor < nodes.count {
            let (node, depth) = nodes[cursor]
            cursor += 1
            guard nodes.count <= 600 else { throw Failure.unavailable("panel_census_limit") }
            if depth == 4 { continue }
            switch AXHelpers.childrenResult(node, runtime: runtime.ax) {
            case .success(let children):
                for child in children where !nodes.contains(where: { CFEqual($0.0, child) }) {
                    nodes.append((child, depth + 1))
                }
            case .failure(let error) where error.isDefinitiveAbsence: break
            case .failure: throw Failure.unavailable("incomplete_panel_census")
            }
        }
        return nodes.map(\.0)
    }

    private func wait(_ read: () throws -> AXUIElement?) async throws -> AXUIElement {
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard holdsProject() else { throw Failure.unavailable("lost_project") }
            if let element = try read() { return element }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.unavailable("native_panel_timeout")
    }
}
