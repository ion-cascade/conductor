import Foundation
import MCP

extension ProjectDispatcher {
    @MainActor
    static func score(command: String, params: [String: Value], traceID: TraceID? = nil) async -> CallTool.Result {
        let operation = "project.\(command)"
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> CallTool.Result {
            toolTextResult(.error(HonestContract.encodeStateC(error: error, hint: hint,
                extras: ["operation": operation, "verified": false, "write_attempted": false])))
        }

        func success(_ source: ProjectScore.Readback, score: ProjectMusicXML? = nil, output: URL? = nil) -> CallTool.Result {
            let encoder = JSONEncoder()
            let sourceData = try? encoder.encode(source)
            let native = sourceData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            var result: [String: Any] = [
                "operation": operation, "state": "A", "success": true, "verified": true,
                "write_attempted": output != nil,
                "native_score": native ?? NSNull(),
            ]
            if let score, let bytes = try? encoder.encode(score), let value = try? JSONSerialization.jsonObject(with: bytes) {
                result["musicxml_score"] = value
                result["output_path"] = output?.path
            }
            return toolTextResult(ResourceHandlers.encodeJSONObject(result))
        }

        let hint = "In a saved Logic 13 project with one track and one MIDI region, select the region and open Score in stopped transport."
        if command == "read_score" {
            guard params.isEmpty else { return refuse(.invalidParams, "read_score takes no parameters.") }
            guard let source = ProjectScore.read() else { return refuse(.readbackUnavailable, hint) }
            return success(source.readback)
        }

        guard params.count == 4, let path = params["project_path"]?.stringValue, path.hasPrefix("/"),
              let track = params["track_name"]?.stringValue, !track.isEmpty,
              let requested = params["output_path"]?.stringValue,
              params["confirmed"]?.boolValue == true
        else { return refuse(.invalidParams, "Pass project_path, track_name, an absolute .musicxml output_path, and confirmed:true.") }
        let output: URL
        do {
            output = try ProjectScoreExport.destination(requested)
        } catch ProjectScoreExport.Failure.collision {
            return refuse(.invalidParams, "The output already exists. Choose a new filename.")
        } catch {
            return refuse(.invalidParams, "Choose a .musicxml file in an existing writable folder.")
        }

        guard let source = ProjectScore.read(), AppleScriptChannel.projectPathsMatch(path, source.readback.project_path),
              source.readback.track_name == track
        else { return refuse(.readbackUnavailable, hint) }

        var attempted = false
        do {
            let exported = try await ProjectScoreExport(source: source, runtime: .production).run(to: output) {
                attempted = true
                await recordClaimedWriteBoundary(traceID)
            }
            return success(source.readback, score: exported, output: output)
        } catch {
            Log.debug("Score MusicXML export unavailable: \(error)", subsystem: "project")
            if !attempted {
                return refuse(.unsupportedState, "The bound Score as MusicXML command was unavailable.")
            }
            return toolTextResult(ResourceHandlers.encodeJSONObject([
                "operation": operation, "state": "B", "success": false, "verified": false, "write_attempted": true,
                "reason": "The MusicXML export could not be verified. Check the requested file and Logic’s open windows.",
            ]))
        }
    }
}
