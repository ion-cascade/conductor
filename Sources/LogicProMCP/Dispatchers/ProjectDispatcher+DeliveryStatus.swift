import Foundation
import MCP

extension ProjectDispatcher {
    private struct DeliverySettings: Codable, Equatable {
        let stems: ProjectAlignedStemSettings
        let mix: ProjectPCMBounceSettings?
    }

    static func deliveryStatus(params: [String: Value]) -> CallTool.Result {
        let operation = "project.export_status"
        func refusal(_ error: HonestContract.FailureError, _ hint: String) -> CallTool.Result {
            toolTextResult(.error(HonestContract.encodeStateC(error: error, hint: hint,
                extras: ["operation": operation, "write_attempted": false])))
        }
        guard case .string(let rawID) = params["delivery_id"], let id = UUID(uuidString: rawID),
              case .string(let root) = params["output_root"],
              (try? ProjectSelectiveStemRequest.existingRoot(from: params)) == root else {
            return refusal(.invalidParams, "Pass the delivery UUID and its canonical output root.")
        }
        let expected: DeliverySettings?
        if let value = params["expected_settings"] {
            guard case .object = value, let data = try? JSONEncoder().encode(value),
                  let decoded = try? JSONDecoder().decode(DeliverySettings.self, from: data) else {
                return refusal(.invalidParams, "Pass the settings object returned by export_status.")
            }
            expected = decoded
        } else {
            expected = nil
        }
        let directory = ProjectSelectiveStemRequest.directory(root: root, id: id)
        do {
            let report = try ProjectSelectiveStemReceipt.inspect(directory: directory, deliveryID: id) { journal in
                let identity = journal.identity
                let actual = DeliverySettings(stems: identity.settings, mix: identity.mix)
                let digest = try? ProjectSelectiveStemReceipt.savedProjectDigest(path: identity.projectPath)
                let projectState = digest.map { $0 == identity.projectSHA256 ? "verified" : "changed" } ?? "unverifiable"
                let settingsState = expected.map { $0 == actual ? "match" : "changed" } ?? "not_compared"
                var hasPending = false
                var invalidFile = false
                let outputs: [[String: Any]] = identity.expectedTracks.map { index in
                    let entry = journal.files.first { $0.trackIndex == index }
                    let state = entry.map {
                        ProjectSelectiveStemReceipt.fileState($0, directory: directory, identity: identity)
                    } ?? .pending
                    hasPending = hasPending || state == .pending
                    invalidFile = invalidFile || (state != .verified && state != .pending)
                    var row = entry.map { deliveryFileJSON($0, directory: directory) } ?? [
                        "kind": index == nil ? "mix" : "stem",
                    ]
                    if let index {
                        row["track_index"] = index
                        row["track_name"] = identity.subjects.first { $0.index == index }?.name
                    }
                    row["status"] = state.rawValue
                    return row
                }
                let blocked = projectState != "verified" || settingsState == "changed" || invalidFile
                return [
                    "schema": "logic_pro_mcp_delivery_status.v1", "operation": operation,
                    "state": "A", "success": true, "verified": !blocked && !hasPending,
                    "write_attempted": false, "delivery_id": id.uuidString,
                    "directory": directory.path, "project_path": identity.projectPath,
                    "project_status": projectState, "settings_status": settingsState,
                    "settings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(actual)),
                    "status": blocked ? "blocked" : hasPending ? "partial" : "complete",
                    "resume_available": !blocked && hasPending, "outputs": outputs,
                ] as [String: Any]
            }
            return toolTextResult(ResourceHandlers.encodeJSONObject(report))
        } catch ProjectSelectiveStemReceipt.Failure.missingOrBusy {
            return refusal(.readbackUnavailable, "The delivery directory is unavailable or a writer is active. Check the output root and delivery ID and try again.")
        } catch {
            return refusal(.staleSnapshot, "The delivery receipt is unreadable or invalid.")
        }
    }
}
