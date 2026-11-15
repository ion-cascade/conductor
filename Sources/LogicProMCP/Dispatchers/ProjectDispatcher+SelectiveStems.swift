import Foundation
import MCP

extension ProjectDispatcher {
    static func selectiveStemDelivery(
        command: String, params: [String: Value], registry: TargetRegistry?
    ) async -> CallTool.Result {
        let operation = "project.\(command)"
        func refusal(_ error: HonestContract.FailureError, _ hint: String) -> CallTool.Result {
            toolTextResult(.error(HonestContract.encodeStateC(error: error, hint: hint,
                extras: ["operation": operation, "write_attempted": false])))
        }
        let request: ProjectSelectiveStemRequest
        do {
            request = try ProjectSelectiveStemRequest(params)
        } catch {
            return refusal(.invalidParams, String(describing: error))
        }
        if command != "export_plan", params["confirmed"]?.boolValue != true {
            return refusal(.invalidParams, "Set confirmed to true to write the selective stem delivery.")
        }
        guard let registry else {
            return refusal(.staleTargetReference, "Open the saved project and inspect its tracks to get current references.")
        }
        var bindings: [AXTrackBinding.Binding] = []
        var subjects: [ProjectExportStemSubject] = []
        for reference in request.references {
            guard let binding = await registry.resolve(reference), binding.kind == .track,
                  let physical = binding.physicalTrack, physical.exposure == nil,
                  let path = physical.projectPath,
                  AppleScriptChannel.projectPathsMatch(request.projectPath, path) else {
                return refusal(.staleTargetReference, "Open the saved project and reacquire each selected track reference.")
            }
            let subject = ProjectExportStemSubject(index: binding.descriptor.trackIndex, name: binding.descriptor.trackName)
            guard ProjectAlignedStemSettings.namesQualify([subject]) else {
                return refusal(.invalidParams, "Each chosen track needs a portable name made of letters, digits, spaces, underscores or hyphens.")
            }
            bindings.append(physical)
            subjects.append(subject)
        }
        guard Set(subjects.map(\.index)).count == subjects.count,
              let scope = ProjectSelectiveStemScope(bindings: bindings, subjects: subjects) else {
            return refusal(.readbackUnavailable, "Stop transport and expose the chosen tracks with one track selected in the foreground saved project.")
        }
        let range = request.settings.range
        guard scope.selected(scope.originalIndex, range: range) else {
            return refusal(.readbackUnavailable, "For an exact range, turn Cycle on, expose both locators in Logic's Custom display and set them to the requested boundaries.")
        }
        func envelope(_ state: String, files: [[String: Any]], status: String, reason: String? = nil,
                      restored: Bool? = nil, attempted: Bool = false) -> CallTool.Result {
            var result: [String: Any] = [
                "schema": "logic_pro_mcp_selective_stems.v1", "operation": operation,
                "delivery_id": request.deliveryID.uuidString, "output_root": request.outputRoot,
                "directory": request.directory.path, "project_path": request.projectPath,
                "state": state, "status": status, "success": state == "A", "verified": state == "A" && status == "complete",
                "write_attempted": attempted,
                "resume_available": status == "partial",
                "tracks": subjects.map { ["track_index": $0.index, "name": $0.name] as [String: Any] },
                "files": files,
                "include_audio_tail": request.settings.includeAudioTail,
                "include_volume_pan_automation": request.settings.includeVolumePanAutomation,
            ]
            if let range { result["range"] = ["start": range.start, "end": range.end] }
            result["selection_restored"] = restored
            result["reason"] = reason
            return toolTextResult(ResourceHandlers.encodeJSONObject(result), isError: state == "C")
        }
        if command == "export_plan" {
            return envelope("A", files: [], status: "planned")
        }

        let identity: ProjectSelectiveStemReceipt.Identity
        do {
            let digest = try ProjectSelectiveStemReceipt.savedProjectDigest(path: request.projectPath)
            identity = .init(projectPath: request.projectPath, projectSHA256: digest,
                             subjects: subjects, settings: request.settings)
        } catch {
            return refusal(.readbackUnavailable, "The saved project data or bundled media could not be verified.")
        }
        guard scope.selected(scope.originalIndex, range: range),
              OperationTraceContext.claimDeadlineEffect("selective_stem_receipt") else {
            return refusal(.readbackUnavailable, "The project, selection or range changed before delivery.")
        }
        let receipt: ProjectSelectiveStemReceipt
        do {
            receipt = try .init(directory: request.directory, deliveryID: request.deliveryID,
                                identity: identity, resume: command == "export_resume")
        } catch ProjectSelectiveStemReceipt.Failure.invalidOrChangedFile {
            return refusal(.staleSnapshot, "A file in the resume receipt is missing, changed or no longer owned by this delivery.")
        } catch ProjectSelectiveStemReceipt.Failure.changedDelivery {
            return refusal(.staleSnapshot, "Resume requires the same saved project, ordered tracks, range and options as the receipt.")
        } catch {
            return refusal(.readbackUnavailable, "The delivery directory already exists, is busy or has no readable receipt. Check the delivery ID and use export_resume for an existing run.")
        }
        var selectedIndex = scope.originalIndex
        var reason: String?
        var attempted = false
        for subject in subjects where !receipt.startedWith.contains(subject.index) {
            if Task.isCancelled { reason = "delivery_interrupted"; break }
            guard receipt.holdsDirectory() else {
                reason = "delivery_directory_changed"; break
            }
            guard await scope.select(subject.index, replacing: selectedIndex) else {
                reason = "track_selection_unverified"; break
            }
            selectedIndex = subject.index
            guard scope.selected(subject.index, range: range),
                  OperationTraceContext.claimDeadlineEffect("selective_stem_export") else {
                reason = "track_or_range_changed"; break
            }
            attempted = true
            let index = subject.index
            let surface = AXSurface(runtime: scope.runtime, selectedTrack: { scope.selected(index, range: range) })
            let rendered = await ProjectIsolatedStemExport.live(root: receipt.directory.path, expectedCount: 1,
                aligned: (request.settings, [subject], request.projectPath), surface: surface)
            guard rendered.outcome == .completed, rendered.files.count == 1, let path = rendered.files.first else {
                switch rendered.outcome {
                case .refused(let detail), .uncertain(let detail, _): reason = detail
                case .completed: reason = "single_native_file_unverified"
                }
                break
            }
            let audio = AudioAnalyzer.analyzeFile(path: path,
                policy: .init(minimumDurationSeconds: 0.05, allowsSilentOutput: true, outputRoot: receipt.directory.path))
            guard audio.verification.status == .pass, audio.frameCount > 0,
                  ProjectPCMBounceSettings.isStemWAVE24(path, sampleRate: audio.sampleRate),
                  receipt.journal.files.allSatisfy({ file in
                      file.sampleRate == audio.sampleRate &&
                        (request.settings.includeAudioTail || file.frames == audio.frameCount)
                  }),
                  scope.selected(subject.index, range: range),
                  (try? ProjectSelectiveStemReceipt.savedProjectDigest(path: request.projectPath)) == identity.projectSHA256
            else { reason = "stem_alignment_or_project_unverified"; break }
            do {
                try receipt.record(URL(fileURLWithPath: path), track: index, sampleRate: audio.sampleRate,
                                   frames: audio.frameCount)
            } catch {
                reason = "stem_receipt_commit_failed"
                break
            }
        }

        let restored = await scope.select(scope.originalIndex, replacing: selectedIndex)
        let files = receipt.journal.files.map { file -> [String: Any] in
            ["track_index": file.trackIndex, "path": receipt.directory.appendingPathComponent(file.relativePath).path,
             "sha256": file.sha256, "sample_rate": file.sampleRate, "frame_count": file.frames,
             "reused": receipt.startedWith.contains(file.trackIndex)]
        }
        let complete = reason == nil && files.count == subjects.count && restored
        return envelope(complete ? "A" : "B", files: files, status: complete ? "complete" : "partial",
                        reason: reason ?? (restored ? nil : "selection_restoration_unverified"),
                        restored: restored, attempted: attempted)
    }
}
