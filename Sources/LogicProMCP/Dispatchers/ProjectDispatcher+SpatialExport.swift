import Foundation
import MCP

extension ProjectDispatcher {
    @MainActor
    static func spatialExport(params: [String: Value], traceID: TraceID?) async -> CallTool.Result {
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> CallTool.Result {
            toolTextResult(.error(HonestContract.encodeStateC(error: error, hint: hint,
                extras: ["operation": "project.export_adm_bwf", "verified": false, "write_attempted": false])))
        }
        guard params.count == 6, params["confirmed"]?.boolValue == true,
              let project = params["project_path"]?.stringValue, project.hasPrefix("/"),
              let requested = params["output_path"]?.stringValue,
              let bedName = params["bed_name"]?.stringValue, !bedName.isEmpty,
              let objectName = params["object_name"]?.stringValue, !objectName.isEmpty,
              bedName != objectName,
              case .int(let expectedFrames) = params["expected_frames"], expectedFrames > 0
        else {
            return refuse(.invalidParams, "Pass project_path, a new .wav output_path, bed_name, object_name, positive expected_frames at 48 kHz, and confirmed:true.")
        }
        let output: URL
        do { output = try ProjectSpatialDestination.destination(requested) }
        catch { return refuse(.invalidParams, "Choose a new .wav filename in an existing writable directory.") }
        guard let source = ProjectSpatialExport.acquire(projectPath: project) else {
            return refuse(.readbackUnavailable, "Focus the saved Logic 13 project with stopped transport and its other windows closed.")
        }
        let settings: ProjectSpatialExport.Settings
        do { settings = try await source.settings() }
        catch {
            Log.debug("Spatial settings unavailable: \(error)", subsystem: "project")
            return refuse(.readbackUnavailable, "The bound Audio project settings could not be read and closed.")
        }
        guard settings.spatialAudio == "Dolby Atmos", settings.surround == "7.1.2", settings.sampleRate == "48 kHz" else {
            return refuse(.unsupportedState, "The qualified ADM profile requires Dolby Atmos, a 7.1.2 bed, and 48 kHz.")
        }
        let fm = FileManager.default
        let directory = output.deletingLastPathComponent().appendingPathComponent(".conductor-adm-" + UUID().uuidString)
        var attempted = false
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let stage = directory.appendingPathComponent("Master.wav")
            try await source.exportADM(to: stage, settings: settings) {
                attempted = true
                await recordClaimedWriteBoundary(traceID)
            }
            let artifact = try ProjectADMArtifact.read(stage)
            guard source.holdsProject(), artifact.frames == expectedFrames, artifact.channels == 11,
                  artifact.objects.count == 2,
                  let bed = artifact.objects.first(where: { $0.name == bedName }),
                  let object = artifact.objects.first(where: { $0.name == objectName }),
                  bed.channels.count == 10, object.channels.count == 1,
                  bed.packReferences.allSatisfy({ $0.hasPrefix("AP_0001") }),
                  object.packReferences.allSatisfy({ $0.hasPrefix("AP_0003") })
            else { throw ProjectSpatialExport.Failure.unavailable("adm_profile_readback_mismatch") }
            // Publishing a link preserves an existing file even if it appeared during export.
            try fm.linkItem(at: stage, to: output)
            try? fm.removeItem(at: directory)
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(artifact))
            let native = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
            return toolTextResult(ResourceHandlers.encodeJSONObject([
                "operation": "project.export_adm_bwf", "state": "A", "success": true, "verified": true,
                "write_attempted": true, "output_path": output.path, "native_settings": native, "artifact": encoded,
            ]))
        } catch {
            Log.debug("ADM export unverified: \(error)", subsystem: "project")
            if !attempted {
                try? fm.removeItem(at: directory)
                return refuse(.unsupportedState, "The owned native ADM export could not be started.")
            }
            return toolTextResult(ResourceHandlers.encodeJSONObject([
                "operation": "project.export_adm_bwf", "state": "B", "success": false, "verified": false,
                "write_attempted": true, "staging_directory": directory.path,
                "reason": "The exported ADM profile could not be verified. Inspect the retained staging directory and Logic windows.",
            ]))
        }
    }
}

enum ProjectSpatialDestination {
    static func destination(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              path.rangeOfCharacter(from: .controlCharacters) == nil else { throw ProjectADMArtifact.Failure.invalid }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard candidate.pathExtension.lowercased() == "wav" else { throw ProjectADMArtifact.Failure.invalid }
        let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isWritableFile(atPath: parent.path) else { throw ProjectADMArtifact.Failure.invalid }
        let output = parent.appendingPathComponent(candidate.lastPathComponent)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: output.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: output.path)) == nil else { throw ProjectADMArtifact.Failure.invalid }
            return output
        }
        throw ProjectADMArtifact.Failure.invalid
    }
}
