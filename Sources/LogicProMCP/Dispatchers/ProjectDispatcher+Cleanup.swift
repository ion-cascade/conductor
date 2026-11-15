import Foundation
import MCP

extension ProjectDispatcher {
    // MARK: - cleanup_apply (#28) — guarded execution of a cleanup-plan step

    /// Guarded execution of exactly ONE cleanup-plan step (#28). The read-only
    /// `audit` + `cleanup_plan` surfaces (shipped in #95) propose steps but never
    /// mutate; this command turns a single supported, mutating step into a real
    /// Logic mutation while inheriting every Honest Contract guarantee of the
    /// underlying tool path.
    ///
    /// Contract:
    ///   1. Re-derive the audit + cleanup plan deterministically from the cache
    ///      (the caller cannot smuggle a stale plan — the step is matched against
    ///      a freshly-built plan).
    ///   2. Find the step by `step_id`.
    ///   3. Fail CLOSED (State C, isError) when any of:
    ///        - `confirmed` is not literally `true`
    ///        - the step id is unknown
    ///        - `supported_by_current_tools == false`
    ///        - `mutates_project == false` (nothing to execute)
    ///        - the audit shows stale/occluded inventory or a track readback gap
    ///   4. For a supported mutating step, dispatch through the EXISTING tool
    ///      path (currently only `track.rename`) so it inherits AX readback +
    ///      HC State A/B/C. The dispatcher does NOT re-implement the readback.
    ///   5. NEVER delete. Deletion steps are `supported_by_current_tools:false`
    ///      by construction (see `ProjectSessionAudit.cleanupPlanSteps`), so the
    ///      unsupported gate already refuses them; a redundant explicit refusal
    ///      guards against any future plan that mislabels a delete as supported.
    static func handleCleanupApply(
        command: String = "cleanup_apply",
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        auditFileReader: LogicProjectFileReader.Runtime = .production,
        traceID: TraceID? = nil
    ) async -> CallTool.Result {
        let stepID = stringParam(params, "step_id", "stepId")
        guard !stepID.isEmpty else {
            audit(command, phase: .rejected, reason: "missing step_id")
            return toolInvalidParamsResult(
                "cleanup_apply requires 'step_id' (an id from logic_project cleanup_plan)"
            )
        }

        // Gate 1 — explicit confirmation. A missing or non-literal-boolean
        // `confirmed` must NOT be coerced; this is a mutating op, so an
        // ambiguous confirmation fails closed rather than executing.
        switch strictBoolParam(params, "confirmed") {
        case .invalid(let hint):
            audit(command, phase: .rejected, reason: "invalid confirmed")
            return toolInvalidParamsResult("cleanup_apply \(hint)")
        case .missing:
            audit(command, phase: .rejected, reason: stepID)
            return cleanupApplyStateC(
                .invalidParams,
                stepID: stepID,
                hint: "cleanup_apply terminated before any mutation because write authorization was absent."
            )
        case .value(let confirmed):
            guard confirmed else {
                audit(command, phase: .rejected, reason: stepID)
                return cleanupApplyStateC(
                    .invalidParams,
                    stepID: stepID,
                    hint: "cleanup_apply terminated without mutation because write authorization was denied."
                )
            }
        }

        // Gate 2 — re-derive the plan deterministically and locate the step.
        // The caller cannot pass a step body in; only its id. This guarantees
        // execution is gated on the CURRENT audit, not a snapshot the caller
        // may have cached before the project changed underneath them.
        let auditReport = await ProjectSessionAudit.buildAudit(
            cache: cache,
            fileReader: auditFileReader
        )
        guard let step = auditReport.cleanupPlan.first(where: { $0.id == stepID }) else {
            audit(command, phase: .rejected, reason: "unknown step")
            return cleanupApplyStateC(
                .elementNotFound,
                stepID: stepID,
                hint: "cleanup_apply terminated because step '\(stepID)' is not present in the current audit."
            )
        }

        // Gate 3 — the audit itself must be safe to act on. Stale, occluded, or
        // gap-bearing inventory means the plan's targets may not correspond to
        // the live session, so any rename could hit the wrong track.
        if let blockingHint = cleanupApplyInventoryBlocker(auditReport) {
            audit(command, phase: .rejected, reason: "stale inventory")
            return cleanupApplyStateC(
                .staleSnapshot,
                stepID: stepID,
                hint: blockingHint,
                extras: [
                    "write_attempted": false,
                    "automatic_read_attempts_exhausted": true,
                    "terminal": true,
                    "terminal_scope": "mcp_request_only",
                    "human_intervention_required": false,
                    "human_intervention_requests": 0,
                    "human_dependent_transitions": 0,
                ]
            )
        }

        // Gate 4 — non-mutating / unsupported steps are refused. A
        // non-mutating step has nothing to execute; an unsupported step
        // (e.g. delete, marker planning gaps) is not safely executable via
        // the current tool surface.
        guard step.mutatesProject else {
            audit(command, phase: .rejected, reason: "non-mutating step")
            return cleanupApplyStateC(
                .invalidParams,
                stepID: stepID,
                hint: "cleanup_apply: step '\(stepID)' does not mutate the project (\(step.proposedOperation)); there is nothing to execute."
            )
        }
        guard step.supportedByCurrentTools else {
            audit(command, phase: .rejected, reason: "unsupported step")
            return cleanupApplyStateC(
                .notImplemented,
                stepID: stepID,
                hint: "cleanup_apply: step '\(stepID)' is not supported by the current tool surface (supported_by_current_tools=false). Resolve its stop condition (\(step.stopCondition)) and re-derive the plan."
            )
        }

        // Gate 5 — deletion is NEVER executed. By construction no plan step
        // proposes a supported delete, but this explicit refusal makes the
        // invariant impossible to regress: even a future mislabelled delete
        // step fails closed here.
        if cleanupApplyIsDeletion(step) {
            audit(command, phase: .rejected, reason: "deletion refused")
            return cleanupApplyStateC(
                .notImplemented,
                stepID: stepID,
                hint: "cleanup_apply refuses deletion: step '\(stepID)' (tool=\(step.tool ?? "nil") command=\(step.command ?? "nil")) is a destructive delete and is never executed by cleanup_apply."
            )
        }

        // Dispatch — currently only the rename family is executable. Every
        // supported mutating step in the plan is `tool:"logic_tracks"`; the
        // rename command renames duplicate/unnamed tracks. solo/arm toggle
        // steps are deferred (see deferred[] / docs): they need an explicit
        // per-track enabled vector that the read-only plan does not yet carry.
        switch (step.tool, step.command) {
        case ("logic_tracks", "rename"):
            return await applyRenameStep(
                step,
                params: params,
                router: router,
                cache: cache,
                traceID: traceID
            )
        default:
            audit(command, phase: .rejected, reason: "no executable path")
            return cleanupApplyStateC(
                .notImplemented,
                stepID: stepID,
                hint: "cleanup_apply: step '\(stepID)' (tool=\(step.tool ?? "nil") command=\(step.command ?? "nil")) has no executable cleanup path yet. Currently only rename_* steps are executable; perform other steps through their named tool directly."
            )
        }
    }

    /// Execute a rename cleanup step through the existing `track.rename` path so
    /// it inherits AX readback + HC State A/B/C. The step's `targetIdentifier`
    /// is `tracks:<i0,i1,...>`; the caller supplies one new name per target via
    /// `names` (a string array or legacy CSV) or, for a single target, `new_name`. Mismatched counts fail
    /// closed before any write so a partial rename can't corrupt the session.
    private static func applyRenameStep(
        _ step: ProjectSessionAudit.CleanupPlanStep,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        traceID: TraceID?
    ) async -> CallTool.Result {
        let targets = cleanupApplyTargetIndices(step.targetIdentifier)
        guard !targets.isEmpty else {
            return cleanupApplyStateC(
                .invalidParams,
                stepID: step.id,
                hint: "cleanup_apply: rename step '\(step.id)' has no parseable target track indices in '\(step.targetIdentifier)'."
            )
        }

        guard let names = cleanupApplyRenameNames(params) else {
            return cleanupApplyStateC(
                .invalidParams,
                stepID: step.id,
                hint: "cleanup_apply: 'names' must be a string array or legacy CSV string; every array entry must be a string.",
                extras: ["write_attempted": false]
            )
        }
        guard names.count == targets.count else {
            return cleanupApplyStateC(
                .invalidParams,
                stepID: step.id,
                hint: "cleanup_apply: rename step '\(step.id)' targets \(targets.count) track(s) \(targets); supply exactly that many names via 'names' (CSV) — or 'new_name' for a single target. Got \(names.count)."
            )
        }
        // Reject blank names up-front: track.rename refuses an empty name, but
        // catching it here keeps a multi-target rename all-or-nothing instead of
        // failing partway after some tracks were already renamed.
        if let blankIdx = names.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return cleanupApplyStateC(
                .invalidParams,
                stepID: step.id,
                hint: "cleanup_apply: rename name #\(blankIdx + 1) for step '\(step.id)' is blank; every target needs a non-empty name."
            )
        }

        // Validate the whole input before the first child rename. Otherwise a
        // known-invalid later name could leave earlier tracks already changed.
        for (position, name) in names.enumerated() {
            if let failure = TrackDispatcher.renameNameFailure(name) {
                return cleanupApplyStateC(
                    .invalidParams,
                    stepID: step.id,
                    hint: "cleanup_apply: rename name #\(position + 1) is invalid; no rename was attempted.",
                    extras: [
                        "write_attempted": false,
                        "underlying": cleanupApplyResultText(failure),
                    ]
                )
            }
        }

        var renamed: [[String: Any]] = []
        var anyRenameWriteAttempted = false
        var allRenameWriteAttemptsKnown = true
        // #389: cleanup_apply reaches the router only through nested
        // TrackDispatcher.handle calls, each of which arms and commits its OWN
        // child boundary — the parent trace would otherwise show none. Keep the
        // explicit parent emit here; propagating a child's committed boundary up
        // to its parent trace (so this becomes observation, not intent, like the
        // routed ops) is future work.
        guard await recordWriteBoundary(
            traceID,
            deadlineStage: "cleanup_apply_first_write"
        ) else {
            return cleanupApplyStateC(
                .cancelled,
                stepID: step.id,
                hint: "cleanup_apply deadline won before the first rename began.",
                extras: ["write_attempted": false]
            )
        }
        for (target, newName) in zip(targets, names) {
            let result = await TrackDispatcher.handle(
                command: "rename",
                params: ["index": .int(target), "name": .string(newName)],
                router: router,
                cache: cache
            )
            let body = cleanupApplyResultText(result)
            let proof = cleanupApplyResultJSONObject(body)
            let childWriteAttempted: Bool?
            if let explicit = proof?["write_attempted"] as? Bool {
                childWriteAttempted = explicit
            } else if proof?["state"] as? String == "B" {
                // Honest Contract State B means the child write landed but its
                // readback could not establish a verified outcome.
                childWriteAttempted = true
            } else if proof?["state"] as? String == "A", proof?["via"] as? String == "no-op" {
                childWriteAttempted = false
            } else {
                childWriteAttempted = nil
            }
            if childWriteAttempted == true {
                anyRenameWriteAttempted = true
            }
            if childWriteAttempted == nil { allRenameWriteAttemptsKnown = false }
            renamed.append([
                "track_index": target,
                "new_name": newName,
                "result": body,
            ])
            // TrackDispatcher.rename already maps State B/C to isError. If any
            // target failed (or came back unverified), stop and surface the
            // underlying HC envelope as State C — do NOT report State A for a
            // batch where a later track could not be confirmed.
            if result.isError == true {
                var failureExtras: [String: Any] = [
                    "tool": "logic_tracks",
                    "command": "rename",
                    "failed_track_index": target,
                    "applied": renamed,
                    "underlying": body,
                    "terminal": true,
                    "terminal_scope": "mcp_request_only",
                    "human_intervention_required": false,
                    "human_intervention_requests": 0,
                    "human_dependent_transitions": 0,
                ]
                if anyRenameWriteAttempted {
                    failureExtras["write_attempted"] = true
                } else if allRenameWriteAttemptsKnown {
                    failureExtras["write_attempted"] = anyRenameWriteAttempted
                } else {
                    failureExtras["write_attempted_known"] = false
                }
                return cleanupApplyStateC(
                    .readbackMismatch,
                    stepID: step.id,
                    hint: "cleanup_apply: rename step '\(step.id)' terminated at track \(target) because "
                        + "the track.rename path did not confirm a verified rename (State B/C).",
                    extras: failureExtras
                )
            }
        }

        // Every target reached verified State A from the underlying rename path.
        return toolTextResult(
            HonestContract.encodeStateA(extras: [
                "op": "project.cleanup_apply",
                "step_id": step.id,
                "tool": "logic_tracks",
                "command": "rename",
                "target_track_indices": targets,
                "applied": renamed,
                "verify_source": "track.rename ax_readback",
            ])
        )
    }

    // MARK: - cleanup_apply helpers

    /// Returns a blocking hint when the audit's inventory is unsafe to act on
    /// (no document, AX occluded, stale track inventory, or a file-vs-AX track
    /// readback gap), else nil. Keeps the stale/occluded/gap gate in one place.
    private static func cleanupApplyInventoryBlocker(_ report: ProjectSessionAudit.AuditReport) -> String? {
        if !report.evidence.hasDocument {
            return "cleanup_apply terminated before mutation: the current automatic audit did not "
                + "confirm an open Logic document."
        }
        if report.evidence.axOccluded {
            return "cleanup_apply terminated before mutation: the bounded automatic audit found "
                + "occluded Accessibility readback, so the plan's targets cannot be trusted."
        }
        let tracksFreshness = report.evidence.tracks.freshness
        if !tracksFreshness.available || tracksFreshness.stale {
            return "cleanup_apply terminated before mutation: the bounded automatic track inventory "
                + "read was unavailable or stale (available=\(tracksFreshness.available), "
                + "stale=\(tracksFreshness.stale))."
        }
        if report.findings.contains(where: { $0.id == "track_readback_gap" }) {
            return "cleanup_apply terminated before mutation: the automatic audit found a "
                + "track_readback_gap, so plan target indices cannot be bound to the live arrange."
        }
        return nil
    }

    /// True when the step is a destructive delete, regardless of how it is
    /// labelled. Belt-and-braces against a future plan that mislabels a delete.
    /// Internal (not private) so the deletion-refusal invariant can be asserted
    /// directly in tests against a synthetic mislabelled delete step.
    static func cleanupApplyIsDeletion(_ step: ProjectSessionAudit.CleanupPlanStep) -> Bool {
        let command = (step.command ?? "").lowercased()
        if command.contains("delete") || command.contains("remove") { return true }
        return step.proposedOperation.lowercased().contains("delete ")
    }

    /// Parse `tracks:0,1,2` (the plan's `target_identifier` form) into sorted,
    /// de-duplicated non-negative indices. Returns [] for any unparseable shape
    /// so the caller fails closed instead of guessing a target.
    static func cleanupApplyTargetIndices(_ identifier: String) -> [Int] {
        let parts = identifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "tracks" else { return [] }
        let csv = parts[1]
        var indices: [Int] = []
        for token in csv.split(separator: ",") {
            guard let value = Int(token.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                return []
            }
            indices.append(value)
        }
        return Array(Set(indices)).sorted()
    }

    /// Resolve the new names for a rename step. `names` (array or CSV) takes precedence;
    /// `new_name` is a single-target convenience. Returns the parsed list as-is
    /// (count is validated against the target count by the caller). A malformed
    /// array rejects the whole input rather than dropping an entry.
    private static func cleanupApplyRenameNames(_ params: [String: Value]) -> [String]? {
        if let raw = params["names"] {
            if let array = raw.arrayValue {
                var names: [String] = []
                for value in array {
                    guard let name = value.stringValue else { return nil }
                    names.append(name)
                }
                return names
            }
            guard let csv = raw.stringValue else { return nil }
            if !csv.isEmpty {
                return csv.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        let single = stringParam(params, "new_name", "name")
        if !single.isEmpty {
            return [single]
        }
        return []
    }

    /// Extract the text body from a CallTool.Result so cleanup_apply can fold
    /// the underlying `track.rename` HC envelope into its own response.
    private static func cleanupApplyResultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private static func cleanupApplyResultJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Build a State C (hard-failure) Honest Contract envelope for cleanup_apply
    /// with the step id always attached for diagnosis.
    private static func cleanupApplyStateC(
        _ error: HonestContract.FailureError,
        stepID: String,
        hint: String,
        extras: [String: Any] = [:]
    ) -> CallTool.Result {
        var merged: [String: Any] = [
            "op": "project.cleanup_apply",
            "step_id": stepID,
        ]
        for (k, v) in extras { merged[k] = v }
        merged["terminal"] = true
        merged["terminal_scope"] = "mcp_request_only"
        merged["safe_to_retry"] = false
        merged["human_intervention_required"] = false
        merged["human_intervention_requests"] = 0
        merged["human_dependent_transitions"] = 0
        return toolTextResult(
            HonestContract.encodeStateC(error: error, hint: hint, extras: merged),
            isError: true
        )
    }
}
