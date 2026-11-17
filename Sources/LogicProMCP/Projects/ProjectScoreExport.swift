import ApplicationServices
import Foundation

@MainActor
struct ProjectScoreExport {
    enum Failure: Error {
        case invalidDestination
        case collision
        case nativeUnavailable
        case artifactUnverified
    }

    let source: ProjectScore
    let runtime: AXLogicProElements.Runtime

    static func destination(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              path.rangeOfCharacter(from: .controlCharacters) == nil else { throw Failure.invalidDestination }
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        guard requested.pathExtension.lowercased() == "musicxml", !requested.deletingPathExtension().lastPathComponent.isEmpty
        else { throw Failure.invalidDestination }
        let parent = requested.deletingLastPathComponent().resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isWritableFile(atPath: parent.path) else { throw Failure.invalidDestination }
        let output = parent.appendingPathComponent(requested.lastPathComponent)
        guard try vacant(output) else { throw Failure.collision }
        return output
    }

    private static func vacant(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return false
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil
        } catch {
            throw Failure.invalidDestination
        }
    }

    func run(to output: URL, didWrite: @MainActor () async -> Void) async throws -> ProjectMusicXML {
        let fm = FileManager.default
        let privateDirectory = output.deletingLastPathComponent().appendingPathComponent(".conductor-score-\(UUID().uuidString)")
        try fm.createDirectory(at: privateDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: privateDirectory) }
        let stage = privateDirectory.appendingPathComponent("Score.musicxml")
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(),
              MIDITrackExportPanel.Keyboard.goToFolderKeyIsMapped(using: .production),
              holdsProject(), focused(source.window),
              let refreshed = ProjectScore.read(runtime: runtime), refreshed.holdsSameScore(as: source),
              let file = menu(["File"]), let export = menu(["File", "Export"])
        else { throw Failure.nativeUnavailable }

        var ownedPanel: AXUIElement?
        let keyboard = MIDITrackExportPanel.Keyboard.withFocus { _, pid in
            pid == source.pid && holdsProject()
        }
        let writer = MIDITrackExportPanel(window: source.window, document: source.document, runtime: runtime,
                                         keyboard: keyboard, permittingAction: { holdsProject() })
        do {
            try Task.checkCancellation()
            guard try Self.vacant(output), holdsProject(), focused(source.window),
                  AXHelpers.performAction(file, kAXPressAction, runtime: runtime.ax) else { throw Failure.nativeUnavailable }
            defer {
                if holdsProject() && focused(source.window) {
                    _ = AXHelpers.performAction(export, kAXCancelAction, runtime: runtime.ax)
                    _ = AXHelpers.performAction(file, kAXCancelAction, runtime: runtime.ax)
                }
            }
            guard holdsProject(), focused(source.window),
                  AXHelpers.performAction(export, kAXPressAction, runtime: runtime.ax),
                  let scoreMenu = menu(["File", "Export", "Score as MusicXML…"]),
                  (AXHelpers.getAttribute(scoreMenu, kAXEnabledAttribute, runtime: runtime.ax) as NSNumber?)?.boolValue == true,
                  holdsProject(), focused(source.window),
                  OperationTraceContext.claimDeadlineEffect("score_musicxml_export", rejectTaskCancellationWithoutContext: true)
            else { throw Failure.nativeUnavailable }

            _ = AXHelpers.performAction(scoreMenu, kAXPickAction, runtime: runtime.ax)
            await didWrite()
            ownedPanel = try await acquirePanel()
            guard let panel = ownedPanel else { throw Failure.nativeUnavailable }
            var saveStage = "score_save_panel"
            try await writer.saveOpenedPanel(panel, to: stage, stage: &saveStage) {
                guard try Self.vacant(output) else { throw Failure.collision }
            }
        } catch {
            if let ownedPanel {
                _ = await writer.recoverOwnedPanel(ownedPanel, app: source.app, originalWindows: [source.window])
            }
            throw error
        }

        guard let final = ProjectScore.read(runtime: runtime), final.holdsSameScore(as: source),
              let entries = try? fm.contentsOfDirectory(at: privateDirectory, includingPropertiesForKeys: nil),
              entries.count == 1, let file = entries.first,
              ["xml", "musicxml"].contains(file.pathExtension.lowercased()),
              let metadata = try? fm.attributesOfItem(atPath: file.path),
              metadata[.type] as? FileAttributeType == .typeRegular,
              let size = metadata[.size] as? NSNumber, (1...ProjectMusicXML.maximumBytes).contains(size.intValue),
              let bytes = try? Data(contentsOf: file), let score = ProjectMusicXML.parse(bytes),
              try Self.vacant(output)
        else { throw Failure.artifactUnverified }
        do {
            // The staged file and final destination share a volume. link fails
            // atomically if another file or symlink occupies the destination.
            try fm.linkItem(at: file, to: output)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw Failure.collision
        }
        guard try Data(contentsOf: output) == bytes else { throw Failure.artifactUnverified }
        return score
    }

    private func menu(_ path: [String]) -> AXUIElement? {
        guard var root: AXUIElement = AXHelpers.getAttribute(source.app, kAXMenuBarAttribute, runtime: runtime.ax) else { return nil }
        for segment in path {
            guard case .success(let children) = AXHelpers.childrenResult(root, runtime: runtime.ax) else { return nil }
            let entries = children.flatMap { child -> [AXUIElement] in
                AXHelpers.getRole(child, runtime: runtime.ax) == kAXMenuRole
                    ? AXHelpers.getChildren(child, runtime: runtime.ax) : [child]
            }
            let matches = entries.filter { AXHelpers.getTitle($0, runtime: runtime.ax) == segment }
            guard matches.count == 1, let next = matches.first else { return nil }
            root = next
        }
        return root
    }

    private func holdsProject() -> Bool {
        runtime.logicProPID() == source.pid && ProjectScore.foreground(source.pid, runtime: runtime)
            && windows()?.contains(where: { CFEqual($0, source.window) }) == true
            && (try? AXLogicProElements.projectPickerDocumentRead(source.window, runtime: runtime).get()) == source.document
    }

    private func windows() -> [AXUIElement]? {
        let all: [AXUIElement]? = AXHelpers.getAttribute(source.app, kAXWindowsAttribute, runtime: runtime.ax)
        return all?.filter { AXHelpers.getRole($0, runtime: runtime.ax) != kAXHelpTagRole }
    }

    private func focused(_ element: AXUIElement) -> Bool {
        guard let focus: AXUIElement = AXHelpers.getAttribute(source.app, kAXFocusedWindowAttribute, runtime: runtime.ax)
        else { return false }
        return CFEqual(element, focus)
    }

    private func acquirePanel() async throws -> AXUIElement? {
        for _ in 0..<60 {
            try Task.checkCancellation()
            guard holdsProject(), let windows = windows(), windows.count <= 2 else { throw Failure.nativeUnavailable }
            if let panel = windows.first(where: { !CFEqual($0, source.window) }) {
                guard AXHelpers.getRole(panel, runtime: runtime.ax) == kAXWindowRole,
                      AXHelpers.getIdentifier(panel, runtime: runtime.ax) == "save-panel",
                      AXHelpers.getTitle(panel, runtime: runtime.ax) == "Save MusicXML File as:"
                else { throw Failure.nativeUnavailable }
                if focused(panel) { return panel }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}
