import ApplicationServices
import Foundation
import MCP

extension ProjectDispatcher {
    static func unifiedBrowser(command: String, params: [String: Value], traceID: TraceID? = nil) async -> CallTool.Result {
        let operation = "project.\(command)"
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> CallTool.Result {
            toolTextResult(.error(HonestContract.encodeStateC(error: error, hint: hint,
                extras: ["operation": operation, "verified": false, "write_attempted": false])))
        }
        func reply(_ browser: ProjectUnifiedBrowser?, attempted: Bool) -> CallTool.Result {
            var result: [String: Any] = ["operation": operation, "state": browser == nil ? "B" : "A",
                                         "verified": browser != nil, "success": browser != nil, "write_attempted": attempted]
            if let browser {
                result["project_path"] = browser.projectPath
                result["track_index"] = browser.selectedIndex
                result["track_name"] = browser.names[browser.selectedIndex]
                result["visible_patches"] = browser.results.map(\.name)
                result["query"] = browser.query
                result["observed_patch"] = browser.patchName
            } else {
                result["reason"] = "Inspect the Browser and target track before retrying."
            }
            return toolTextResult(ResourceHandlers.encodeJSONObject(result))
        }

        guard let path = params["project_path"]?.stringValue, path.hasPrefix("/"),
              let trackName = params["track_name"]?.stringValue, !trackName.isEmpty,
              let query = params["query"]?.stringValue, (1...80).contains(query.count),
              query == query.trimmingCharacters(in: .whitespacesAndNewlines),
              query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return refuse(.invalidParams, "Pass the current project, the exact selected track name and a short search query.")
        }
        let loading = command == "load_browser_patch"
        let requested = params["patch"]?.stringValue
        guard loading ? (params.count == 4 && requested?.isEmpty == false) : params.count == 3 else {
            return refuse(.invalidParams, "To load a result, pass the exact patch name from search_browser_patches.")
        }
        guard let before = ProjectUnifiedBrowser.read(), before.instrumentSlotObserved, !before.replacementEnabled else {
            return refuse(.readbackUnavailable, "Show Browser Instruments and the Inspector in stopped Arrange. Turn off Replace on selection.")
        }
        guard before.projectPath == path, before.names[before.selectedIndex] == trackName else {
            return refuse(.staleSnapshot, "The selected instrument track or project changed.")
        }

        if !loading {
            if before.query == nil {
                _ = AXHelpers.setAttribute(before.input, kAXValueAttribute, query as NSString)
                guard let held = ProjectUnifiedBrowser.read(), held.holdsSameTarget(as: before),
                      !held.replacementEnabled,
                      (AXHelpers.getAttribute(held.input, kAXValueAttribute) as String?) == query else {
                    return refuse(.readbackUnavailable, "Could not verify the Browser search field before submitting.")
                }
                _ = AXHelpers.performAction(held.search, kAXPressAction)
            } else if before.query != query {
                return refuse(.staleSnapshot, "Clear the previous Browser filter before submitting another search.")
            }
            var previous: [String]?
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(330))
                guard let observed = ProjectUnifiedBrowser.read(), observed.holdsSameTarget(as: before),
                      !observed.replacementEnabled else { break }
                guard observed.query == query else { continue }
                let names = observed.results.map(\.name)
                if names == previous { return reply(observed, attempted: false) }
                previous = names
            }
            return refuse(.readbackUnavailable, "Logic did not expose a stable result list for that query.")
        }

        guard let requested, before.query == query, before.selectionEmpty, !before.names.contains(requested),
              before.results.filter({ $0.name == requested }).count == 1 else {
            return refuse(.staleSnapshot, "Search again, leave results unselected and pass one unique visible instrument patch.")
        }
        guard let current = ProjectUnifiedBrowser.read(), current.holdsSameTarget(as: before),
              current.query == query, current.selectionEmpty, !current.replacementEnabled, current.instrumentSlotObserved,
              current.results.map(\.name) == before.results.map(\.name),
              await recordWriteBoundary(traceID, deadlineStage: "browser_patch_load") else {
            return refuse(.staleSnapshot, "The Browser or selected target changed before writing.")
        }
        _ = AXHelpers.performAction(current.replace, kAXPressAction)
        try? await Task.sleep(for: .milliseconds(220))
        var loaded: ProjectUnifiedBrowser?
        if let ready = ProjectUnifiedBrowser.read(), ready.holdsSameTarget(as: current),
           ready.query == query, ready.replacementEnabled, ready.selectionEmpty {
            let candidates = ready.results.filter { $0.name == requested }
            if candidates.count == 1, ready.clickResult(candidates[0].label) {
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(160))
                    if let after = ProjectUnifiedBrowser.read(), after.loaded(requested, replacing: before) {
                        loaded = after
                        break
                    }
                }
            }
        }
        if let active = ProjectUnifiedBrowser.read(), active.projectPath == current.projectPath,
           CFEqual(active.window, current.window), CFEqual(active.panel, current.panel), active.replacementEnabled {
            _ = AXHelpers.performAction(active.replace, kAXPressAction)
        }
        guard loaded != nil, let final = ProjectUnifiedBrowser.read(), !final.replacementEnabled,
              final.loaded(requested, replacing: before) else { return reply(nil, attempted: true) }
        return reply(final, attempted: true)
    }
}
