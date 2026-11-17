import ApplicationServices
import Foundation
import MCP

extension ProjectDispatcher {
    static func liveLoops(command: String, params: [String: Value], traceID: TraceID? = nil) async -> CallTool.Result {
        let operation = "project.\(command)"
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> CallTool.Result {
            toolTextResult(.error(HonestContract.encodeStateC(error: error, hint: hint,
                extras: ["operation": operation, "verified": false, "write_attempted": false])))
        }

        func response(
            _ grid: ProjectLiveLoops.Grid?, attempted: Bool, verified: Bool, queued: Bool = false
        ) -> CallTool.Result {
            var result: [String: Any] = [
                "operation": operation, "state": verified ? "A" : "B", "success": verified,
                "verified": verified, "write_attempted": attempted
            ]
            if let grid, let data = try? JSONEncoder().encode(grid),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result.merge(object) { current, _ in current }
                result["grid_snapshot"] = try? grid.snapshot()
            }
            if attempted { result["observed_queue"] = queued }
            if !verified { result["reason"] = "Recheck the grid before retrying. A launch or stop may have reached Logic." }
            return toolTextResult(ResourceHandlers.encodeJSONObject(result))
        }

        if command == "read_live_loops" {
            guard params.isEmpty else { return refuse(.invalidParams, "read_live_loops takes no parameters.") }
            guard let live = ProjectLiveLoops.read() else {
                return refuse(.readbackUnavailable, "Show the Live Loops grid of a focused, saved Logic 13 project with a small readable grid.")
            }
            return response(live.grid, attempted: false, verified: true)
        }

        guard params.count == 3, let reference = params["cell_ref"]?.stringValue,
              reference.hasPrefix("cell_"), reference.utf8.count == 69,
              let snapshot = params["grid_snapshot"]?.stringValue,
              snapshot.hasPrefix("loops_"), snapshot.utf8.count == 70,
              let playing = params["playing"]?.boolValue else {
            return refuse(.invalidParams, "Pass cell_ref and grid_snapshot from read_live_loops and the desired playing Boolean.")
        }
        guard let first = ProjectLiveLoops.read(), (try? first.grid.snapshot()) == snapshot,
              first.grid.selected_cell_ref == reference,
              let target = first.grid.cells.first(where: { $0.cell_ref == reference }),
              target.name != nil, let row = first.grid.rows.first(where: { $0.track == target.track })
        else { return refuse(.staleSnapshot, "Select the populated cell in Logic and recapture the grid.") }
        guard first.grid.transport_playing, first.grid.quantize_start == "1 Bar",
              target.mode == "Looping, Start/Stop", first.control != nil else {
            return refuse(.unsupportedState, "Use a visible looping Start/Stop cell with the transport running and Quantize Start set to 1 Bar.")
        }

        let alreadyPlaying = row.activity == "stop" && first.action == "stop"
        let alreadyStopped = row.inactive && first.action == "play"
        if playing ? alreadyPlaying : alreadyStopped {
            return response(first.grid, attempted: false, verified: true)
        }
        guard playing ? alreadyStopped : alreadyPlaying else {
            return refuse(.readbackUnavailable, "Wait for the current cell action to settle before capturing it again.")
        }

        guard let ready = ProjectLiveLoops.read(), ready.holdsSelection(as: first),
              ready.grid == first.grid, ready.action == first.action,
              let button = ready.control, let original = first.control, CFEqual(button, original),
              OperationTraceContext.claimDeadlineEffect("live_loops_cell_playback")
        else { return refuse(.staleSnapshot, "The selected cell or transport changed before the action.") }

        _ = AXHelpers.performAction(button, kAXPressAction)
        await recordClaimedWriteBoundary(traceID)
        let deadline = ContinuousClock.now + .seconds(9)
        let queuedState = playing ? "cancel playing" : "cancel stopping"
        var queued = false
        var last: ProjectLiveLoops.Grid?
        repeat {
            guard !Task.isCancelled,
                  let observed = ProjectLiveLoops.read(), observed.holdsSelection(as: first),
                  observed.grid.preservesPeers(of: first.grid, track: target.track),
                  let row = observed.grid.rows.first(where: { $0.track == target.track })
            else { break }
            last = observed.grid
            queued = queued || row.activity == queuedState
            let applied = playing ? row.activity == "stop" && observed.action == "stop"
                : row.inactive && observed.action == "play"
            if applied { return response(observed.grid, attempted: true, verified: true, queued: queued) }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { break }
        } while ContinuousClock.now < deadline
        return response(last, attempted: true, verified: false, queued: queued)
    }
}
