@preconcurrency import ApplicationServices
import Foundation

/// Logic 13's English PCM Bounce dialog followed by the owned AppKit Save panel.
@MainActor
struct ProjectLogic13Bounce {
    private enum Failure: Error {
        case unavailable(String)
    }

    private let runtime: AXLogicProElements.Runtime
    private let app: AXUIElement
    private let window: AXUIElement
    private let document: String
    private let pid: pid_t
    private let title: String

    static func isSupported(runtime: AXLogicProElements.Runtime = .production) -> Bool {
        guard let pid = runtime.logicProPID() else { return false }
        return runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true
    }

    static func run(
        path: String, projectPath: String, settings: ProjectPCMBounceSettings,
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ProjectExportBounceHelperResult {
        guard let pid = runtime.logicProPID(), isSupported(runtime: runtime),
              let app = AXLogicProElements.appRoot(runtime: runtime),
              case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              let url = URL(string: document), url.isFileURL,
              AppleScriptChannel.projectPathsMatch(projectPath, url.path)
        else { return .failure("pcm_bounce_project_unavailable") }
        let driver = Self(runtime: runtime, app: app, window: window, document: document, pid: pid,
                          title: "Bounce “" + url.deletingPathExtension().lastPathComponent + "”")
        return await driver.render(to: URL(fileURLWithPath: path), settings: settings)
    }

    private func render(
        to destination: URL, settings: ProjectPCMBounceSettings
    ) async -> ProjectExportBounceHelperResult {
        var owned: AXUIElement?
        var saveStage = "settings"
        var fired = false
        do {
            guard !Task.isCancelled, holdsProject(), focused(window), AXIsProcessTrusted(), CGPreflightPostEventAccess(),
                  MIDITrackExportPanel.Keyboard.goToFolderKeyIsMapped(using: .production),
                  AXLogicProElements.dialogPresenceReason(runtime: runtime) == .noBlockingWindow,
                  let transport = try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime, checking: {}),
                  !transport.isPlaying, !transport.isRecording,
                  !FileManager.default.fileExists(atPath: destination.path),
                  let original = windows(), original.filter({ CFEqual($0, window) }).count == 1
            else { throw Failure.unavailable("project_focus_permissions_or_destination") }
            guard let item = AXLogicProElements.menuItem(path: ["File", "Bounce", "Project or Section…"], runtime: runtime),
                  enabled(item), holdsProject(), focused(window)
            else { throw Failure.unavailable("bounce_menu") }
            _ = AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax)

            let dialog = try await wait("bounce_settings") {
                try newDialog(excluding: original, identifier: nil)
            }
            owned = dialog
            try await configure(dialog, settings: settings)
            let okay = try button("OK", in: dialog)
            guard holdsProject(), focused(dialog), enabled(okay) else {
                throw Failure.unavailable("settings_commit_scope")
            }
            _ = AXHelpers.performAction(okay, kAXPressAction, runtime: runtime.ax)
            let panel = try await wait("bounce_save_panel") {
                if windows()?.contains(dialog) == true { return nil }
                return try newDialog(excluding: original, identifier: "save-panel")
            }
            owned = panel
            let writer = MIDITrackExportPanel(window: window, document: document, runtime: runtime, permittingAction: {
                holdsProject()
            })
            try await writer.saveOpenedPanel(panel, to: destination, stage: &saveStage) {
                guard self.holdsProject(), self.focused(panel), self.text(panel, kAXTitleAttribute) == self.title,
                      OperationTraceContext.claimDeadlineEffect("pcm_bounce_save") else {
                    throw Failure.unavailable("bounce_commit_scope")
                }
                fired = true
            }
            owned = nil
            guard let output = await completedFile(destination, settings: settings) else {
                throw Failure.unavailable("bounce_file_missing_incomplete_or_wrong_settings")
            }
            return .success(output)
        } catch {
            if let owned { cancelIfOwned(owned) }
            let detail: String
            switch error {
            case Failure.unavailable(let reason): detail = reason
            case MIDITrackExportPanel.Failure.unavailable(let reason): detail = "\(saveStage):\(reason)"
            default: detail = "\(saveStage):\(error)"
            }
            return .failure("pcm_bounce_\(detail)", bounceFired: fired)
        }
    }

    private func configure(_ dialog: AXUIElement, settings: ProjectPCMBounceSettings) async throws {
        let pending: [(String, String)] = [
            ("File Type:", settings.format.label), ("Bit Depth:", "\(settings.bitDepth)-bit"),
            ("Sample Rate:", settings.sampleRateLabel), ("Format:", "Interleaved"), ("Dithering:", "None"), ("Normalize:", "Off"),
        ]
        let toggleStates = [
            "Include Audio Tail": settings.includeAudioTail,
            "Bounce 2nd Cycle Pass": false, "Surround Bounce": false, "Add to Project": false,
            "Add to Apple Music Library": false,
        ]
        let outputs = ["Uncompressed": true, "MP3": false, "M4A": false, "Burn to CD / DVD": false]
        for name in ["Uncompressed", "MP3", "M4A", "Burn to CD / DVD"] {
            try await setCheckbox(dialog, label: name, desired: outputs[name] ?? false, outputRow: true)
        }
        for (caption, value) in pending {
            let popup = try labeledPopup(caption, dialog: dialog)
            if text(popup, kAXValueAttribute) == value { continue }
            guard holdsProject(), focused(dialog), enabled(popup),
                  children(popup).allSatisfy({ role($0) != kAXMenuRole }) else {
                throw Failure.unavailable("settings_popup_scope:\(caption)")
            }
            _ = AXHelpers.performAction(popup, kAXPressAction, runtime: runtime.ax)
            let menu = try await wait("settings_popup:\(caption)") {
                let current = try labeledPopup(caption, dialog: dialog)
                guard CFEqual(current, popup) else {
                    throw Failure.unavailable("settings_control_replaced:\(caption)")
                }
                return try unique(children(current).filter { role($0) == kAXMenuRole }, "settings_popup", optional: true)
            }
            do {
                let choice = try required(children(menu).filter {
                    role($0) == kAXMenuItemRole && text($0, kAXTitleAttribute) == value
                }, "settings_choice:\(caption)")
                guard holdsProject(), windows()?.contains(dialog) == true,
                      children(popup).filter({ CFEqual($0, menu) }).count == 1, enabled(choice) else {
                    throw Failure.unavailable("settings_choice_scope:\(caption)")
                }
                _ = AXHelpers.performAction(choice, kAXPressAction, runtime: runtime.ax)
                // Choosing the container rebuilds the PCM options. The value
                // can update before the old popup and its event tracking retire.
                try await Task.sleep(for: .milliseconds(400))
                _ = try await wait("settings_readback:\(caption)") {
                    let current = try labeledPopup(caption, dialog: dialog)
                    let noPopup = runtime.onScreenWindowList().map { LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0 }
                    return text(current, kAXValueAttribute) == value && focused(dialog) && noPopup == true ? current : nil
                }
            } catch {
                if holdsProject(), windows()?.contains(dialog) == true, children(popup).contains(menu) {
                    _ = AXHelpers.performAction(menu, kAXCancelAction, runtime: runtime.ax)
                }
                throw error
            }
        }
        for (label, desired) in toggleStates.sorted(by: { $0.key < $1.key }) {
            try await setCheckbox(dialog, label: label, desired: desired, outputRow: false)
        }
        for (caption, value) in pending {
            let popup = try labeledPopup(caption, dialog: dialog)
            guard text(popup, kAXValueAttribute) == value else { throw Failure.unavailable("settings_changed:\(caption)") }
        }
        for (label, value) in toggleStates.merging(outputs, uniquingKeysWith: { $1 }) {
            let control = try checkbox(dialog, label: label, outputRow: outputs[label] != nil)
            guard checkboxValue(control) == value else { throw Failure.unavailable("settings_changed:\(label)") }
        }
    }

    private func setCheckbox(_ dialog: AXUIElement, label: String, desired: Bool, outputRow: Bool) async throws {
        let control = try checkbox(dialog, label: label, outputRow: outputRow)
        guard let before = checkboxValue(control) else { throw Failure.unavailable("checkbox_unreadable:\(label)") }
        guard before != desired else { return }
        guard holdsProject(), focused(dialog), enabled(control) else { throw Failure.unavailable("checkbox_scope:\(label)") }
        _ = AXHelpers.performAction(control, kAXPressAction, runtime: runtime.ax)
        _ = try await wait("checkbox_readback:\(label)") {
            let current = try checkbox(dialog, label: label, outputRow: outputRow)
            return checkboxValue(current) == desired && focused(dialog) ? current : nil
        }
    }

    private func checkbox(_ dialog: AXUIElement, label: String, outputRow: Bool) throws -> AXUIElement {
        try required(descendants(dialog, depth: outputRow ? 5 : 2).filter {
            role($0) == kAXCheckBoxRole
                && text($0, outputRow ? kAXDescriptionAttribute : kAXTitleAttribute) == label
                && (!outputRow || text($0, kAXIdentifierAttribute) == "enable")
        }, "checkbox:\(label)")
    }

    private func labeledPopup(_ caption: String, dialog: AXUIElement) throws -> AXUIElement {
        let parents = [dialog] + children(dialog).filter { role($0) == kAXGroupRole }
        let matching = parents.flatMap { parent -> [AXUIElement] in
            let nodes = children(parent)
            let labels = nodes.filter { role($0) == kAXStaticTextRole && text($0, kAXValueAttribute) == caption }
            guard labels.count == 1, let label = labels.first,
                  let origin = AXHelpers.getPosition(label, runtime: runtime.ax),
                  let size = AXHelpers.getSize(label, runtime: runtime.ax) else { return [] }
            return nodes.filter {
                guard role($0) == kAXPopUpButtonRole,
                      let p = AXHelpers.getPosition($0, runtime: runtime.ax),
                      let s = AXHelpers.getSize($0, runtime: runtime.ax) else { return false }
                return p.x >= origin.x + size.width - 2 && abs(p.y + s.height / 2 - origin.y - size.height / 2) <= 6
            }
        }
        return try required(matching, "settings_control:\(caption)")
    }

    private func completedFile(_ url: URL, settings: ProjectPCMBounceSettings) async -> String? {
        // AIFF may be written with either spelling by Logic. The planner checks
        // both spellings for collisions before opening the project.
        let candidates = settings.format == .aiff
            ? [url, url.deletingPathExtension().appendingPathExtension(url.pathExtension == "aif" ? "aiff" : "aif")]
            : [url]
        var previous: (URL, Int, Date)?
        for _ in 0..<120 {
            guard !Task.isCancelled else { return nil }
            let observed = candidates.compactMap { path -> (URL, Int, Date)? in
                guard let value = try? path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                      value.isRegularFile == true, value.isSymbolicLink == false,
                      let size = value.fileSize, size > 44, let date = value.contentModificationDate else { return nil }
                return (path, size, date)
            }
            guard observed.count < 2 else { return nil }
            if let file = observed.first, let previous, file == previous,
               ProjectExportContainerCompletion.isComplete(at: file.0.path, size: Int64(file.1)),
               settings.matchesFile(file.0.path) { return file.0.path }
            previous = observed.first
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return nil }
        }
        return nil
    }

    private func newDialog(excluding prior: [AXUIElement], identifier: String?) throws -> AXUIElement? {
        guard let visible = windows() else { throw Failure.unavailable("windows_unreadable") }
        let added = visible.filter { role($0) == kAXWindowRole && !prior.contains($0) }
        guard let candidate = try unique(added, "dialog_population", optional: true) else { return nil }
        guard text(candidate, kAXTitleAttribute) == title, text(candidate, kAXSubroleAttribute) == "AXDialog",
              identifier.map({ text(candidate, kAXIdentifierAttribute) == $0 }) ?? true else {
            throw Failure.unavailable("unexpected_dialog")
        }
        return focused(candidate) ? candidate : nil
    }

    private func cancelIfOwned(_ dialog: AXUIElement) {
        guard holdsProject(), focused(dialog), windows()?.contains(dialog) == true,
              !descendants(dialog, depth: 2).contains(where: { role($0) == kAXSheetRole }),
              let cancel = try? button("Cancel", in: dialog, depth: 2), enabled(cancel) else { return }
        _ = AXHelpers.performAction(cancel, kAXPressAction, runtime: runtime.ax)
    }

    private func wait(_ stage: String, _ observe: () throws -> AXUIElement?) async throws -> AXUIElement {
        for _ in 0..<80 {
            try Task.checkCancellation()
            guard holdsProject() else { throw Failure.unavailable("project_custody_lost:\(stage)") }
            if let value = try observe() { return value }
            try await Task.sleep(for: .milliseconds(90))
        }
        throw Failure.unavailable("transition_not_observed:\(stage)")
    }

    private func holdsProject() -> Bool {
        guard runtime.focusedApplicationPID() == pid, windows()?.contains(window) == true,
              case .success(.some(let current)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime)
        else { return false }
        return current == document
    }

    private func windows() -> [AXUIElement]? {
        AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax)
    }

    private func focused(_ element: AXUIElement) -> Bool {
        guard let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: runtime.ax)
        else { return false }
        return CFEqual(focused, element)
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        AXHelpers.getChildren(element, runtime: runtime.ax)
    }

    private func descendants(_ root: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        let direct = children(root)
        return direct + direct.flatMap { descendants($0, depth: depth - 1) }
    }

    private func unique(_ elements: [AXUIElement], _ error: String, optional: Bool) throws -> AXUIElement? {
        guard elements.count == 1 || (optional && elements.isEmpty) else { throw Failure.unavailable(error) }
        return elements.first
    }

    private func required(_ elements: [AXUIElement], _ error: String) throws -> AXUIElement {
        guard let only = try unique(elements, error, optional: false) else { throw Failure.unavailable(error) }
        return only
    }

    private func button(_ title: String, in root: AXUIElement, depth: Int = 1) throws -> AXUIElement {
        try required(descendants(root, depth: depth).filter {
            role($0) == kAXButtonRole && text($0, kAXTitleAttribute) == title
        }, "button:\(title)")
    }

    private func role(_ element: AXUIElement) -> String? { AXHelpers.getRole(element, runtime: runtime.ax) }
    private func text(_ element: AXUIElement, _ key: String) -> String? {
        AXHelpers.getAttribute(element, key, runtime: runtime.ax)
    }
    private func checkboxValue(_ element: AXUIElement) -> Bool? {
        guard let value: Int = AXHelpers.getAttribute(element, kAXValueAttribute, runtime: runtime.ax),
              (0...1).contains(value) else { return nil }
        return value == 1
    }
    private func enabled(_ element: AXUIElement) -> Bool {
        (AXHelpers.getAttribute(element, kAXEnabledAttribute, runtime: runtime.ax) as Bool?) == true
    }
}
