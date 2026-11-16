import ApplicationServices
import Foundation
import MCP

extension ProjectDispatcher {
    static func patternStep(command: String, params: [String: Value], traceID: TraceID? = nil) async -> CallTool.Result {
        let operation = "project.\(command)"
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> CallTool.Result {
            toolTextResult(.error(HonestContract.encodeStateC(error: error, hint: hint,
                extras: ["operation": operation, "verified": false, "write_attempted": false])))
        }
        func response(_ step: ProjectPatternStep?, state: String, attempted: Bool) -> CallTool.Result {
            var result: [String: Any] = ["operation": operation, "state": state, "verified": state == "A",
                                         "success": state == "A", "write_attempted": attempted]
            if let step {
                result["address"] = step.address.json
                result["enabled"] = step.enabled
                result["velocity"] = step.velocity
                result["chance_percent"] = step.chance
                result["repeat_count"] = step.repeatCount
                result["tied"] = step.tied
                result["visible_grid"] = step.visibleRows.map(\.json)
            }
            if state == "B" { result["reason"] = "Check the selected step in Logic before trying another edit." }
            return toolTextResult(ResourceHandlers.encodeJSONObject(result))
        }
        if command == "get_pattern_step" && !params.isEmpty {
            return refuse(.invalidParams, "get_pattern_step takes no parameters.")
        }
        let request: (ProjectPatternStep.Address, Bool, Bool)?
        if command == "set_pattern_step_enabled" {
            guard case .object(let address) = params["address"], address.count == 6,
                  let path = address["project_path"]?.stringValue, path.hasPrefix("/"),
                  let name = address["region_name"]?.stringValue,
                  let location = address["region_location"]?.stringValue,
                  let track = address["track"]?.stringValue,
                  let row = address["row"]?.stringValue,
                  let number = address["step"]?.intValue, (1...16).contains(number),
                  let expected = params["expected_enabled"]?.boolValue,
                  let desired = params["enabled"]?.boolValue else {
                return refuse(.invalidParams, "Pass the address from get_pattern_step and Boolean expected_enabled and enabled values.")
            }
            request = (.init(projectPath: path, regionName: name, regionLocation: location,
                             track: track, row: row, step: number), expected, desired)
        } else {
            request = nil
        }
        guard let first = ProjectPatternStep.read() else {
            return refuse(.readbackUnavailable, "Open one 16-step Pattern region in Step Sequencer, show its Step inspector and select exactly one step. Stop playback, preview, recording and Mono Mode.")
        }
        guard let (address, expected, desired) = request else { return response(first, state: "A", attempted: false) }
        guard address == first.address, expected == first.enabled else {
            return refuse(.staleSnapshot, "Read the selected step again and pass its current address and enabled state.")
        }
        if desired == first.enabled { return response(first, state: "A", attempted: false) }
        guard let before = ProjectPatternStep.read(), before.holdsSameSelection(as: first),
              before.enabled == first.enabled, before.holdsSameParameters(as: first),
              before.visibleRows == first.visibleRows,
              await recordWriteBoundary(traceID, deadlineStage: "pattern_step_enabled") else {
            return refuse(.staleSnapshot, "The selected pattern step changed before the edit.")
        }
        _ = AXHelpers.performAction(before.toggle, kAXPressAction)
        for _ in 0..<5 {
            do { try await Task.sleep(for: .milliseconds(90)) } catch { break }
            guard let after = ProjectPatternStep.read(), after.holdsSameSelection(as: before) else { break }
            if after.enabled == desired, after.holdsSameParameters(as: before), after.visibleRows == before.visibleRows {
                return response(after, state: "A", attempted: true)
            }
        }
        return response(nil, state: "B", attempted: true)
    }
}
