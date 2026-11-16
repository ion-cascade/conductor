import ApplicationServices
import Foundation
import MCP

extension ProjectDispatcher {
    private struct PatternChange {
        let target: ProjectPatternStep.CellAddress
        let enabled: Bool
    }

    static func patternGrid(command: String, params: [String: Value], traceID: TraceID? = nil) async -> CallTool.Result {
        let operation = "project.\(command)"
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> CallTool.Result {
            toolTextResult(.error(HonestContract.encodeStateC(error: error, hint: hint,
                extras: ["operation": operation, "verified": false, "write_attempted": false])))
        }
        func response(_ grid: ProjectPatternGrid?, attempted: Bool, verified: Bool) -> CallTool.Result {
            var result: [String: Any] = ["operation": operation, "state": verified ? "A" : "B",
                                         "verified": verified, "success": verified, "write_attempted": attempted]
            if let grid, let data = try? grid.data(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result.merge(object) { current, _ in current }
                result["grid_snapshot"] = try? grid.snapshot()
            }
            if !verified { result["reason"] = "Recheck the complete pattern before retrying; an edit may have landed." }
            return toolTextResult(ResourceHandlers.encodeJSONObject(result))
        }

        let writing = command == "set_pattern_steps_enabled"
        var request: (ProjectPatternGrid.Identity, String, [PatternChange])?
        if writing {
            guard params.count == 3, case .object(let address) = params["address"],
                  let identity = ProjectPatternGrid.Identity(json: address.compactMapValues(\.stringValue)),
                  let snapshot = params["grid_snapshot"]?.stringValue, snapshot.hasPrefix("grid_"), snapshot.count == 69,
                  case .array(let changes) = params["changes"], (1...4).contains(changes.count) else {
                return refuse(.invalidParams, "Pass the address and grid_snapshot from capture_pattern_grid and one to four changes.")
            }
            let edits = changes.compactMap { value -> PatternChange? in
                guard case .object(let edit) = value, edit.count == 3, let row = edit["row"]?.stringValue,
                      let step = edit["step"]?.intValue, (1...16).contains(step),
                      let enabled = edit["enabled"]?.boolValue else { return nil }
                return PatternChange(target: .init(row: row, step: step), enabled: enabled)
            }
            guard edits.count == changes.count, Set(edits.map(\.target)).count == edits.count else {
                return refuse(.invalidParams, "Each change needs a different row and step and a Boolean enabled value.")
            }
            request = (identity, snapshot, edits)
        } else if !params.isEmpty {
            return refuse(.invalidParams, "capture_pattern_grid takes no parameters.")
        }

        guard let initial = ProjectPatternStep.read(), initial.completeGrid != nil else {
            return refuse(.readbackUnavailable, "Open a stopped Pattern region with one to three visible 16-step rows and select one cell in the Step inspector.")
        }
        if let (identity, _, _) = request, ProjectPatternGrid.Identity(initial) != identity {
            return refuse(.staleSnapshot, "The open pattern does not match the captured address.")
        }
        guard let before = await ProjectPatternGrid.capture(from: initial) else {
            return refuse(.readbackUnavailable, "The visible pattern or its selection could not be verified.")
        }
        guard let (_, snapshot, edits) = request else {
            return response(before, attempted: false, verified: true)
        }
        guard (try? before.snapshot()) == snapshot else {
            return refuse(.staleSnapshot, "Capture the pattern again before editing.")
        }
        let byAddress = Dictionary(uniqueKeysWithValues: before.cells.map { ($0.address, $0) })
        guard edits.allSatisfy({ byAddress[$0.target] != nil }) else {
            return refuse(.staleSnapshot, "An addressed cell is absent from the captured pattern.")
        }

        let changed = edits.filter { byAddress[$0.target]?.enabled != $0.enabled }
        if changed.isEmpty { return response(before, attempted: false, verified: true) }

        var current = initial
        var attempted = false
        var completed = true
        for edit in changed {
            guard let selected = await ProjectPatternGrid.select(edit.target, from: current) else {
                completed = false
                break
            }
            current = selected
            guard ProjectPatternGrid.Entry(selected) == byAddress[edit.target],
                  await recordWriteBoundary(traceID, deadlineStage: "pattern_grid_enabled") else {
                completed = false
                break
            }
            attempted = true
            _ = AXHelpers.performAction(selected.toggle, kAXPressAction)
            try? await Task.sleep(for: .milliseconds(100))
            guard let next = ProjectPatternStep.read(), next.holdsSameSelection(as: current),
                  next.enabled == edit.enabled, next.holdsSameParameters(as: current) else {
                completed = false
                break
            }
            current = next
        }
        guard let restored = await ProjectPatternGrid.select(initial.cellAddress, from: current) else {
            return attempted ? response(nil, attempted: true, verified: false)
                : refuse(.staleSnapshot, "The selected pattern changed before writing.")
        }
        guard attempted else { return refuse(.staleSnapshot, "The selected pattern changed before writing.") }

        let after = await ProjectPatternGrid.capture(from: restored)
        let changes = Dictionary(uniqueKeysWithValues: changed.map { ($0.target, $0.enabled) })
        let expected = before.cells.map { cell in changes[cell.address].map(cell.replacingEnabled) ?? cell }
        return response(after, attempted: true,
                        verified: completed && after?.identity == before.identity && after?.cells == expected)
    }
}
