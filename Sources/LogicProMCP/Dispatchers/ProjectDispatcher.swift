import Foundation
import MCP

struct ProjectDispatcher: OperationTraceDispatching {
    // Keeps dispatcher cases auditable against the registry so fallback cannot bypass strict validation.
    static let handledCommands: Set<String> = OperationRegistry.commands(for: .logicProject)
    /// `plan_session_repair`'s refusal when the cache holds a project with no bound file path.
    /// One spelling shared with the qualification classifier that matches it exactly.
    static let planSessionRepairUnboundProjectHint =
        "planning reads a retained inspection, and the current project has no bound file path, so none of its inspections is retained; save the project and inspect again"
    /// A stem plan may only reuse a recent, complete project/track/region
    /// snapshot. The scanner is deliberately cache-only: dry-run planning
    /// does not open a requested project merely to manufacture subjects.
    private static let stemSubjectInventoryMaximumAge: TimeInterval = 10

    struct LifecycleExecution: Sendable {
        let executionError: String?
        let timedOut: Bool
        let terminationStatus: Int32
        let stderrOutput: String
    }

    static let tool = commandTool(
        name: "logic_project",
        description: "Project lifecycle + read-only project state in Logic Pro. Commands: new, open, save, save_as, close, bounce, is_running, launch, quit, get_regions, get_region_smart_tempo, get_pattern_step, set_pattern_step_enabled, capture_pattern_grid, set_pattern_steps_enabled, get_chord_track, set_chord_quality, get_session_player, set_session_player_chord_source, search_browser_patches, load_browser_patch, scan_regions, edit_region, get_region_gain, set_region_gain, get_region_fade, set_region_fade, export_plan, export_run, export_resume, export_status, audit, cleanup_plan, inspect_session, plan_session_repair, apply_session_repair, cleanup_apply. Params: open -> { path: String }; save_as -> { path: String }; close -> { saving?: \"yes\"|\"no\" }; bounce/launch/quit -> {}; standalone bounce terminates unsupported before UI because it cannot produce an artifact unattended; use confirmed `export_run` for automated artifact production; get_regions -> {} (returns { regions: [{ name, trackIndex, startBar, endBar, kind, rawHelp, isSelected?, startPosition?, endPosition? }], complete, scope, reason, returned_count }; coverage and exact positions depend on the native region census); get_pattern_step -> {} reads one selected 16-step Pattern cell’s address and native On/Off and velocity in the visible Step inspector; set_pattern_step_enabled -> { address: Object, expected_enabled: Bool, enabled: Bool } verifies the returned address and current enabled state before writing that selected step; capture_pattern_grid -> {} reads one to three visible 16-step rows and restores the initial selection; set_pattern_steps_enabled -> { address: Object, grid_snapshot: String, changes: [{ row: String, step: Int, enabled: Bool }] } checks the captured grid and applies one to four changes with a fresh full-grid readback; get_chord_track -> {} reads visible bar-aligned chords; set_chord_quality -> { project_path, start_bar, end_bar, expected_chord, quality } changes one natural-root major or minor chord; get_session_player -> {} reads the selected Keyboard Player region, performance values and native Pitch Source; set_session_player_chord_source -> { address, expected_chord_source, chord_source } selects an available source and checks the native mark; search_browser_patches -> { project_path, track_index, track_name, query } snapshots visible Instruments results on the selected track with Replace on selection off; load_browser_patch -> { project_path, track_index, track_name, query, patch } applies a unique visible result and verifies the selected track patch and peer layout; scan_regions -> {} samples a bounded set of Arrange viewports, restores the original view, and returns short-lived references for corroborated ordinary audio and MIDI regions; edit_region -> { target_ref: String, expected_start: String, expected_end: String, mode: move|trim, start?: String, end?: String } moves to start or trims one inward boundary. Positions use bar.beat.division.tick. Re-scan after a write attempt; get_region_gain -> { target_ref: String }; set_region_gain -> { target_ref: String, expected_gain_db: Number, gain_db: Number }. Select one ordinary audio region in stopped Arrange and expand Region Inspector > General. Reads use a fresh scan reference. Writes accept -24.0 to +12.0 dB in 0.1 dB steps and require matching current gain; get_region_fade -> { target_ref: String, edge: in|out }; set_region_fade -> { target_ref: String, edge: in|out, expected_time_ms: Number, time_ms: Number }. Expand Region Inspector > Fades. Supports standard linear fades in whole milliseconds from 0 to 1000. Re-scan after a write attempt; export_plan -> { projects: [absolute .logicx], output_root: String, artifacts?: [bounce|stem|preview|variant], collision_policy?: fail_if_exists|skip_existing, bounce_settings?: { format: wav|aiff, sample_rate: 44100|48000|96000, bit_depth: 16|24, include_audio_tail?: Bool, range?: { start: String, end: String } }, stem_settings?: { include_audio_tail?: Bool, include_volume_pan_automation?: Bool } } dry-run only. Stem is narrower than the generic projects shape: it refuses unless exactly one currently scanned project has a fresh complete region inventory proving its populated tracks, and output_root is an existing directory; the Export panel must also expose that folder in its browser at execution. On Logic 13, stem_settings selects an aligned PCM WAVE export with verified track-name binding. Without stem_settings, filenames and format are late-bound. Live runs allocate a private subdirectory under output_root; the actual artifact path is returned. Verified single-track binding requires a fresh complete native track census and stable complete WAV/AIFF audio. fail_if_exists examines only top-level non-directory entries with suffix wav|wave|aif|aiff|aifc|m4a|mp3, and it refuses if enumeration fails; skip_existing is refused for stem. export_run -> { ...same as export_plan, confirmed: Bool } GUARDED execution (re-plans, opens, verifies project identity by readback, drives the stem Export panel or bounces as appropriate, checks files and verifies their track-name mapping when the aligned profile is requested, records logic_pro_mcp_export_run.v1 with HC State A/B/C; never overwrites under fail_if_exists); For selective Logic 13 stems, supply stem_settings.track_refs (1–16 current Arrange references), stem_settings.delivery_id (UUID), and optional stem_settings.range (exact musical start and end). Leave the saved project open with stopped transport and the intended tracks exposed. A ranged delivery requires the matching enabled Cycle and visible Custom display locators. export_resume -> { ...same as export_run } reuses verified files from a selective stem receipt and exports the missing tracks. Reopen the same project and pass fresh references in the original track order. Legacy all-tracks stem runs have no resume receipt; export_status -> { delivery_id, output_root, expected_settings? } checks a saved selective delivery and its files without opening Logic; audit -> read-only project/session audit JSON; cleanup_plan -> read-only serializable cleanup plan JSON; inspect_session -> { scope?: \"whole_project\"|\"selection\", domains?: [tracks|strips|associations|hierarchy|routing|color], allow_ui_navigation?: Bool, project_ref?: String, snapshot_id?: String } read-only logic_pro_mcp_session_population.v1 JSON from a request-owned fresh read of the currently exposed Arrange rail and Mixer, with optional owned Mixer reveal and nested stack exposure/restoration: every requested domain carries coverage complete|partial|unavailable|unstable plus reasons, tracks/strips rows come with witnesses, and unread data is reported as unread rather than absent. A fresh report has an opaque snapshot_id. snapshot_retention reports whether its observed project bundle path permits retention; an unbound project remains readable but retained=false (project_identity_unobserved) and its ID cannot be looked up. Bound reports are retained for 60 seconds, with at most 8 reports of at most 2 MiB each in this process-local cache. snapshot_id alone returns the original report bytes and original capture interval, not a fresh observation; expired, evicted, cross-session or changed-project handles fail stale_snapshot without regenerating. Lookup cannot combine project_ref or override scope/domains/navigation. Failed requested reads never borrow older cached rows. Missing windows yield unavailable without AX acquisition, text editing prevents unsafe AXHelp reads, and unstable live observations cannot serve as current repair baselines. Global hidden/stacked/virtualized population remains incomplete. allow_ui_navigation=true permits project/window-bound Mixer reveal through the existing View menu and temporary exposure through held stack disclosures. When associations are requested and no presentation exposure was needed, held exclusive selection and verified restoration of the original selection/focus can produce partial association pairs with current issued track and Mixer references; names and ordinals never establish a pair. These actions require retained physical-target, project/window, focus and operation ownership, with conditional reverse restoration and no global keys or activation. Acquired membership does not infer parent/depth; native restoration and complete population remain unqualified. UI effects and restoration/conflicts are reported separately; cache-only callers cannot navigate. Hidden/stacked/virtualized traversal remains incomplete; plan_session_repair -> { snapshot_id: String, policy: finite session intent object, names?: [{ target: declared handle, name: String }] } creates a read-only retained canonical draft; { plan_id: String, digest?: String } retrieves original bytes. Unknown intent is refused, unavailable exact-target and preservation adapters block tasks, and planning writes nothing. Plans expire with their baseline and are not write authority; apply_session_repair -> { plan_id: String, digest: String, confirmed: true, idempotency_key: String } with ADR-004 opt-in revalidates the exact retained canonical plan, digest, project and captured target/footprint authority before scheduling supported work through the existing Saga executor. The canonical preview describes executable tasks, unchanged goals and unsupported scope; it is not current write authority. Known-invalid complete plans refuse before writes; later lost custody or failed final verification stops dependent work and uses only actual owned inverses, reporting residuals. Already-satisfied goals require fresh independent observation and do not manufacture setter effects or inverse permission. saga_status and saga_cancel use the same idempotency key and session journal. Duplicate keys replay a retained historical outcome without a new read or write; detailed-outcome eviction does not permit reexecution, and restart does not recover old plans. Caller-supplied steps, serialized observations and approval claims never supply native authority. Native qualification and complete scenario coverage remain separately scoped; cleanup_apply -> { step_id: String, confirmed: Bool, names?: [String] (exact names aligned to the step's target track indices) | \"newA,newB\" (legacy CSV) | new_name?: String (single target) } executes ONE supported mutating cleanup-plan step (currently rename_* only) through the existing track.rename path so it inherits AX readback + Honest Contract State A/B/C. Fails closed (State C) when confirmed!=true, the step is unknown/unsupported/non-mutating, the audit shows stale/occluded inventory or a track readback gap, or rename names are missing/mismatched. Deletion steps are unsupported by construction and are always refused; others -> {}.",
        commandDescription: "Project command to execute"
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        targetRegistry: TargetRegistry? = nil,
        // Single source of truth — use ProcessUtils.isLogicProRunning everywhere
        // (NSRunningApplication-based with multi-fallback). Removed prior OR with
        // PermissionChecker.checkAutomationState() == .granted because permission
        // grant ≠ Logic actually running, and the OR caused state inconsistency
        // vs `system.health` and `transport.toggle_cycle` which use ProcessUtils only.
        isLogicProRunning: () -> Bool = { ProcessUtils.isLogicProRunning },
        executeLifecycleScript: (String) async -> LifecycleExecution = { script in
            await executeAppleScript(script)
        },
        sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        dialogPresent: @escaping @Sendable () -> Bool = { false },
        // #427 follow-up: the authoritative blocking-dialog signal the transport
        // preflight fails closed on (`preflight_blocking_dialog`). Threaded into
        // the read-only `audit` so a modal present at audit time surfaces as an
        // export-readiness blocker instead of a false green. Defaults to the same
        // live source the transport path uses; tests inject a fixture.
        blockingDialogInfo: @escaping @Sendable () -> AXLogicProElements.BlockingDialogInfo? = { AXLogicProElements.blockingDialogInfo() },
        cleanupAuditFileReader: LogicProjectFileReader.Runtime = .production,
        // #27 Phase 2 — injectable export-execution seams (identity readback,
        // audio analysis, file polling). Defaults to the live wiring; tests
        // inject fakes so the guarded state machine is unit-testable headless.
        exportOptions: ProjectExportExecutor.Options = .live(),
        acquireSessionPopulation: (@Sendable (SessionPopulationObservation.Request) async throws -> SessionPopulationObservation.Capture)? = nil,
        applySessionRepair: (@Sendable (ApprovedSessionRepair.ApplyRequest) async -> CallTool.Result)? = nil
    ) async -> CallTool.Result {
        // A cancelled fresh inspection must not resolve, issue or retain a replacement
        // capture. Historical lookup remains a lookup of the original immutable bytes.
        if command == "inspect_session", params["snapshot_id"] == nil, Task.isCancelled {
            return toolStateCResult(.cancelled,
                hint: "Session inspection was cancelled before acquisition; no report was generated.",
                extras: ["write_attempted": false, "navigation_performed": false])
        }
        if let projectFailure = await TargetRefResolver.validateProjectReference(
            params,
            targetRegistry: targetRegistry,
            operation: "project.\(command)"
        ) {
            return projectFailure
        }

        func destructiveConfirmation(for command: String) -> (confirmed: Bool, error: CallTool.Result?) {
            switch strictBoolParam(params, "confirmed") {
            case .missing:
                return (false, nil)
            case .value(let confirmed):
                return (confirmed, nil)
            case .invalid(let hint):
                audit(command, phase: .rejected, reason: "invalid confirmed")
                return (
                    false,
                    toolInvalidParamsResult("\(command) \(hint)")
                )
            }
        }

        // H-1 (2026-05-08 enterprise review): pre-fix this dispatcher logged
        // `[AUDIT] project.<command> executed` BEFORE param validation,
        // BEFORE the destructive-confirmation gate, and BEFORE the route
        // actually fired. Enterprise audit trails treated rejected calls
        // (e.g. `project.open` with empty path) as if they had run, which
        // both inflated the audit volume and hid genuine failures behind
        // identical log lines.
        //
        // The fix splits the audit signal into three distinct phases that
        // a SIEM can filter on:
        //   - `rejected` — validation refused the call before any side effect
        //   - `confirmation_required` — destructive policy returned the
        //     confirmation envelope; no route was attempted
        //   - `executed` — the underlying route was invoked (success or
        //     hard failure) and any side effect has either landed or been
        //     reported back from the channel
        //
        // Helpers below are intentionally inlined per-case rather than
        // wrapped in a single function so the log is always paired with
        // the immediately-following return — refactors that move the
        // return without moving the audit call would surface as a diff
        // anomaly during review.

        if ["export_plan", "export_run", "export_resume"].contains(command),
           ProjectSelectiveStemRequest.requested(params) {
            return await selectiveStemDelivery(command: command, params: params, registry: targetRegistry)
        }

        switch command {
        case "export_status":
            return deliveryStatus(params: params)

        case "export_plan":
            do {
                let stemSubjects = await stemSubjectInventory(params: params, router: router, cache: cache)
                let plan = try ProjectExportPlanner.plan(
                    params: params,
                    stemSubjects: stemSubjects
                )
                // PR99-C5 / C2-nit (HC): use the throwing encoder so an encode
                // failure fails closed (isError=true) via the catch below instead
                // of returning an error-shaped, non-manifest body as a success.
                return toolTextResult(try encodeJSONStrict(plan, compact: true))
            } catch {
                audit(command, phase: .rejected, reason: "invalid export plan")
                return toolInvalidParamsResult(
                    "export_plan invalid_params: \(error)",
                    extras: ["operation": "project.export_plan"]
                )
            }

        case "export_run", "export_resume":
            // #27 Phase 2 — GUARDED EXECUTION. Validate the plan inputs first so
            // a malformed request fails closed with `invalid_params` (rejected,
            // no mutation) exactly like export_plan, instead of reaching the
            // executor. The executor then re-runs the planner itself for the
            // authoritative manifest — the dispatcher's call is purely the
            // caller-input gate.
            let stemSubjects = await stemSubjectInventory(params: params, router: router, cache: cache)
            do {
                _ = try ProjectExportPlanner.plan(
                    params: params,
                    stemSubjects: stemSubjects
                )
            } catch {
                audit(command, phase: .rejected, reason: "invalid export plan")
                return toolInvalidParamsResult(
                    "\(command) invalid_params: \(error)",
                    extras: ["operation": "project.\(command)"]
                )
            }
            let traceID = await startTraceIfEnabled(command: command)
            if dialogPresent() {
                let explicitPCM = params["bounce_settings"] != nil
                let decision = explicitPCM ? await exportOptions.pcmOpenBlocker(rechecking: dialogPresent) : nil
                if !explicitPCM || exportOptions.pcmDialogDecision == nil || decision != nil || dialogPresent() {
                    audit(command, phase: .rejected, reason: "blocking dialog")
                    return await finalizeTrace(
                        blockingLogicDialogResult(operation: "project.\(command)", decision: decision),
                        traceID: traceID
                    )
                }
            }
            let confirmation = strictBoolParam(params, "confirmed")
            if case .invalid(let hint) = confirmation {
                audit(command, phase: .rejected, reason: "invalid confirmed")
                return await finalizeTrace(toolInvalidParamsResult(
                    "\(command) \(hint)",
                    extras: ["operation": "project.\(command)"]
                ), traceID: traceID)
            }
            let existingFirstWrite = exportOptions.onFirstWrite
            var tracedExportOptions = exportOptions
            if let acquireSessionPopulation {
                tracedExportOptions.verifyIsolatedSubjectBinding = { path, subjects in
                    let request = SessionPopulationObservation.Request(scope: .wholeProject, domains: [.tracks],
                        allowUINavigation: false, projectRef: nil)
                    guard let capture = try? await acquireSessionPopulation(request),
                          capture.freshPopulation?.stable == true,
                          capture.tracks.allSatisfy({ $0.physicalBinding != nil }) else { return false }
                    let report = SessionPopulationObservation.build(request: request, capture: capture)
                    guard report.project.status == .issued,
                          report.project.filePath == URL(fileURLWithPath: path).standardizedFileURL.path,
                          report.tracks.coverage == .complete,
                          Set(report.tracks.rows.map(\.name)).count == report.tracks.rows.count else { return false }
                    return !subjects.isEmpty && subjects.allSatisfy { subject in
                        report.tracks.rows.filter { $0.trackIndex == subject.index && $0.name.utf8.elementsEqual(subject.name.utf8) }.count == 1
                    }
                }
            }
            tracedExportOptions.onFirstWrite = {
                guard await existingFirstWrite() else { return false }
                return await recordWriteBoundary(
                    traceID,
                    deadlineStage: "project_export_first_write"
                )
            }
            let run: ProjectExportExecutor.RunResult
            switch confirmation {
            case .invalid:
                return await finalizeTrace(toolInvalidParamsResult(
                    "\(command) 'confirmed' must be a literal boolean true or false",
                    extras: ["operation": "project.\(command)"]
                ), traceID: traceID)
            case .missing, .value(false):
                audit(command, phase: .confirmationRequired)
                run = await ProjectExportExecutor.run(
                    params: params,
                    router: router,
                    resume: command == "export_resume",
                    options: tracedExportOptions,
                    stemSubjects: stemSubjects
                )
            case .value(true):
                audit(command, phase: .executed)
                run = await ProjectExportExecutor.run(
                    params: params,
                    router: router,
                    resume: command == "export_resume",
                    options: tracedExportOptions,
                    stemSubjects: stemSubjects
                )
            }
            // Lifecycle cache invalidation: a guarded run opens projects, so the
            // cache may now reflect the LAST opened project. Clear it on any run
            // that actually opened something, matching open/close semantics.
            if run.projects.contains(where: { $0.opened }) {
                await invalidateProjectState(cache: cache, targetRegistry: targetRegistry)
            }
            do {
                // HC truthfulness: a run that produced ZERO verified artifacts and
                // had failures (or the confirmation gate) is isError=true on the
                // wire so a client never reads a failed/blocked run as success.
                let body = try encodeJSONStrict(run, compact: true)
                let isError = run.status == "failed" || run.status == "confirmation_required"
                return await finalizeTrace(
                    toolTextResult(body, isError: isError),
                    traceID: traceID
                )
            } catch {
                return await finalizeTrace(toolTextResult(
                    "{\"success\":false,\"error\":\"\(command) encode failed: \(jsonStringEscape(error.localizedDescription))\"}",
                    isError: true
                ), traceID: traceID)
            }

        case "new":
            let traceID = await startTraceIfEnabled(command: command)
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return await finalizeTrace(
                    blockingLogicDialogResult(operation: "project.new"),
                    traceID: traceID
                )
            }
            audit(command, phase: .executed)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(operation: "project.new")
            }
            // v3.1.2 (P0-3) — clear cache on lifecycle success so the next
            // resource read / name-based routing decision sees the fresh
            // project's tracks instead of the previous project's stale list.
            // Without this, `cache.getTracks()` returned 38 tracks for over
            // a minute after `project.new` (live-witnessed); the StatePoller
            // takes up to 3s to overwrite, and resource consumers assumed
            // the data was current. clearProjectState() is idempotent and
            // mutation-free on actor state — safe to call on every success
            // even if the poller would have caught up eventually.
            await invalidateOnSuccess(command: command, result: result, cache: cache, targetRegistry: targetRegistry)
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "open":
            let path = stringParam(params, "path")
            guard !path.isEmpty else {
                audit(command, phase: .rejected, reason: "missing path")
                return toolInvalidParamsResult(
                    "open requires 'path' param",
                    extras: ["operation": "project.open"]
                )
            }
            guard AppleScriptSafety.isValidProjectPath(path, requireExisting: true) else {
                audit(command, phase: .rejected, reason: "invalid path")
                return toolInvalidParamsResult(
                    "open requires an existing absolute .logicx project path",
                    extras: ["operation": "project.open"]
                )
            }
            let traceID = await startTraceIfEnabled(command: command)
            let confirmation = destructiveConfirmation(for: command)
            if let error = confirmation.error {
                return await finalizeTrace(error, traceID: traceID)
            }
            if !confirmation.confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                audit(command, phase: .confirmationRequired)
                return await finalizeTrace(toolTextResult(response, isError: true), traceID: traceID)
            }
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return await finalizeTrace(
                    blockingLogicDialogResult(operation: "project.open"),
                    traceID: traceID
                )
            }
            audit(command, phase: .executed)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(
                    operation: "project.open",
                    params: ["path": path]
                )
            }
            // v3.1.2 (P0-3) — same cache stale-after-lifecycle bug as `new`.
            await invalidateOnSuccess(command: command, result: result, cache: cache, targetRegistry: targetRegistry)
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "save":
            let traceID = await startTraceIfEnabled(command: command)
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return await finalizeTrace(
                    blockingLogicDialogResult(operation: "project.save"),
                    traceID: traceID
                )
            }
            audit(command, phase: .executed)
            // #110: save is an export/bounce prerequisite. The read-back
            // verification lives in the AppleScript channel (the reliable
            // writer, now tried first) so it stays DI-testable like save_as;
            // the dispatcher just routes + surfaces the channel's HC verdict.
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(operation: "project.save")
            }
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "save_as":
            let path = stringParam(params, "path")
            guard !path.isEmpty else {
                audit(command, phase: .rejected, reason: "missing path")
                return toolInvalidParamsResult(
                    "save_as requires 'path' param",
                    extras: ["operation": "project.save_as"]
                )
            }
            guard AppleScriptSafety.isValidProjectPath(path, requireExisting: false) else {
                audit(command, phase: .rejected, reason: "invalid path")
                return toolInvalidParamsResult(
                    "save_as requires an absolute .logicx project path",
                    extras: ["operation": "project.save_as"]
                )
            }
            let traceID = await startTraceIfEnabled(command: command)
            let confirmation = destructiveConfirmation(for: command)
            if let error = confirmation.error {
                return await finalizeTrace(error, traceID: traceID)
            }
            if !confirmation.confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                audit(command, phase: .confirmationRequired)
                return await finalizeTrace(toolTextResult(response, isError: true), traceID: traceID)
            }
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return await finalizeTrace(
                    blockingLogicDialogResult(operation: "project.save_as"),
                    traceID: traceID
                )
            }
            audit(command, phase: .executed)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(
                    operation: "project.save_as",
                    params: ["path": path]
                )
            }
            if FeatureFlags.adr002TargetRef {
                await invalidateOnSuccess(command: command, result: result, cache: cache, targetRegistry: targetRegistry)
            }
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "close":
            let savingRaw = stringParam(params, "saving", default: "yes")
            let saving = ["yes", "no"].contains(savingRaw) ? savingRaw : "yes"
            if savingRaw != saving {
                audit(command, phase: .rejected, reason: "invalid saving value")
                return toolInvalidParamsResult(
                    "close 'saving' must be one of: yes, no; interactive save prompts are unsupported (got: \(savingRaw))",
                    extras: ["operation": "project.close"]
                )
            }
            let traceID = await startTraceIfEnabled(command: command)
            let confirmation = destructiveConfirmation(for: command)
            if let error = confirmation.error {
                return await finalizeTrace(error, traceID: traceID)
            }
            if !confirmation.confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                audit(command, phase: .confirmationRequired)
                return await finalizeTrace(toolTextResult(response, isError: true), traceID: traceID)
            }
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return await finalizeTrace(
                    blockingLogicDialogResult(operation: "project.close"),
                    traceID: traceID
                )
            }
            audit(command, phase: .executed)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(
                    operation: "project.close",
                    params: ["saving": saving]
                )
            }
            // v3.1.2 (P0-3) — closing the project leaves the cache stuffed
            // with the just-closed tracks/regions/markers. Clear so resource
            // reads honestly reflect "no project" until the next open.
            await invalidateOnSuccess(command: command, result: result, cache: cache, targetRegistry: targetRegistry)
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "bounce":
            let traceID = await startTraceIfEnabled(command: command)
            audit(command, phase: .rejected, reason: "standalone unattended bounce unavailable")
            let result = await AccessibilityChannel.openBounceDialogViaMenu()
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "is_running":
            return toolTextResult(isLogicProRunning() ? "true" : "false")

        case "get_pattern_step":
            return await patternStep(command: command, params: params)

        case "set_pattern_step_enabled":
            let traceID = await startTraceIfEnabled(command: command)
            let result = await patternStep(command: command, params: params, traceID: traceID)
            return await finalizeTrace(result, traceID: traceID)

        case "capture_pattern_grid":
            return await patternGrid(command: command, params: params)

        case "set_pattern_steps_enabled":
            let traceID = await startTraceIfEnabled(command: command)
            let result = await patternGrid(command: command, params: params, traceID: traceID)
            return await finalizeTrace(result, traceID: traceID)

        case "get_chord_track":
            return await chordTrack(command: command, params: params)

        case "set_chord_quality":
            let traceID = await startTraceIfEnabled(command: command)
            return await finalizeTrace(await chordTrack(command: command, params: params, traceID: traceID), traceID: traceID)

        case "get_session_player":
            return await sessionPlayer(command: command, params: params)

        case "set_session_player_chord_source":
            let traceID = await startTraceIfEnabled(command: command)
            return await finalizeTrace(await sessionPlayer(command: command, params: params, traceID: traceID), traceID: traceID)

        case "search_browser_patches":
            return await unifiedBrowser(command: command, params: params)

        case "load_browser_patch":
            let traceID = await startTraceIfEnabled(command: command)
            return await finalizeTrace(await unifiedBrowser(command: command, params: params, traceID: traceID), traceID: traceID)

        case "scan_regions":
            guard params.isEmpty else { return toolInvalidParamsResult("scan_regions takes no parameters") }
            return toolTextResult(await router.route(operation: "region.scan"))

        case "get_region_smart_tempo":
            guard params.count == 1, let reference = params["target_ref"]?.stringValue,
                  reference.hasPrefix("reg_") else {
                return toolInvalidParamsResult("Pass one current region target_ref.")
            }
            return toolTextResult(await router.route(operation: "region.get_smart_tempo", params: ["target_ref": reference]))

        case "get_region_gain", "set_region_gain", "get_region_fade", "set_region_fade":
            return await regionParameter(command: command, params: params, router: router)

        case "edit_region":
            let keys: Set<String> = ["target_ref", "mode", "expected_start", "expected_end", "start", "end"]
            guard Set(params.keys).isSubset(of: keys),
                  let reference = params["target_ref"]?.stringValue, reference.hasPrefix("reg_"),
                  let expectedStart = params["expected_start"]?.stringValue,
                  let expectedEnd = params["expected_end"]?.stringValue,
                  let first = ProjectBounceRange.position(expectedStart),
                  let last = ProjectBounceRange.position(expectedEnd),
                  first.lexicographicallyPrecedes(last),
                  let mode = params["mode"]?.stringValue,
                  (mode == "move" && params["start"] != nil && params["end"] == nil)
                    || (mode == "trim" && ((params["start"] != nil) != (params["end"] != nil))),
                  ["start", "end"].allSatisfy({ key in
                      params[key] == nil || params[key]?.stringValue.flatMap(ProjectBounceRange.position) != nil
                  }) else {
                return toolInvalidParamsResult("edit_region requires target_ref, expected_start and expected_end. Use move with start, or trim with exactly one new boundary.")
            }
            let observedProject = await cache.currentProjectIdentity()
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(operation: "region.edit_by_reference", params: params.compactMapValues(\.stringValue))
            }
            if let receipt = try? JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any],
               receipt["write_attempted"] as? Bool == true {
                await cache.invalidateRegions(ifCurrent: observedProject)
            }
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "get_regions":
            // Read-only arrange-area inspection. Necessary for programmatic
            // verification of record_sequence region placement — without this
            // the only feedback loop was visual screenshots.
            let observedProject = await cache.currentProjectIdentity()
            let result = await router.route(operation: "region.get_regions")
            await refreshRegionCache(
                from: result,
                cache: cache,
                ifCurrent: observedProject
            )
            return toolTextResult(result)

        case "audit":
            let report = await ProjectSessionAudit.buildAudit(
                cache: cache,
                blockingDialogButtons: blockingDialogInfo().map(\.buttonTitles)
            )
            do {
                return toolTextResult(try encodeJSONStrict(report, compact: true))
            } catch {
                // Honest Contract: a serialization failure must NOT be returned
                // as a success-shaped body. Fail loud with isError=true.
                return toolTextResult(
                    "{\"error\":\"audit encode failed: \(jsonStringEscape(error.localizedDescription))\"}",
                    isError: true
                )
            }

        case "inspect_session":
            if let supplied = params["snapshot_id"] {
                guard case .string(let id) = supplied, !id.isEmpty,
                      !["scope", "domains", "allow_ui_navigation", "project_ref"].contains(where: { params[$0] != nil }) else {
                    return toolStateCResult(.invalidParams,
                        hint: "snapshot_id must be a nonempty string and cannot be combined with scope, domains, project_ref or allow_ui_navigation; lookup returns the original report",
                        extras: ["write_attempted": false])
                }
                guard let json = await cache.retainedSessionReport(id: id) else {
                    return toolStateCResult(.staleSnapshot,
                        hint: "snapshot_id is unknown, expired, evicted, or belongs to another project or session; no replacement report was generated",
                        extras: ["write_attempted": false])
                }
                return toolTextResult(json)
            }
            // The registered handler supplies request-owned AX acquisition through the existing
            // poll-cycle arbiter. Direct cache-only callers retain their explicit compatibility
            // seam. Only explicit permission allows the registered producer's temporary Mixer
            // view; neither route claims hidden population completeness.
            let request: SessionPopulationObservation.Request
            switch inspectSessionRequest(params) {
            case .request(let parsed):
                request = parsed
            case .rejected(let failure):
                return failure
            }
            if request.allowUINavigation && acquireSessionPopulation == nil {
                return toolStateCResult(
                    .notImplemented,
                    hint: "inspect_session: allow_ui_navigation=true requires the registered request-owned producer; a cache-only inspection cannot navigate.",
                    extras: ["write_attempted": false, "navigation_performed": false]
                )
            }
            let capture: SessionPopulationObservation.Capture
            var capturedUIEffects = SessionPopulationObservation.UIEffects()
            func uiEffectExtras(_ effects: SessionPopulationObservation.UIEffects) -> [String: Any] {
                ["write_attempted": false, "navigation_performed": effects.navigationPerformed,
                 "ui_effects": ["navigation_performed": effects.navigationPerformed,
                                "restoration": effects.restoration, "changed": effects.changed, "attempted": effects.attempted,
                                "reason": effects.reason as Any? ?? NSNull()]]
            }
            func acquisitionFailure(_ error: Error) -> CallTool.Result {
                let navigationFailure = error as? SessionPopulationObservation.NavigationAcquisitionError
                let cause = navigationFailure?.cause ?? error
                let effects = navigationFailure?.effects ?? capturedUIEffects
                let failure: HonestContract.FailureError
                let hint: String
                switch cause {
                case SessionPopulationObservation.AcquisitionError.cancelled:
                    failure = .cancelled
                    hint = "Fresh population acquisition was cancelled; no replacement report was published."
                case SessionPopulationObservation.AcquisitionError.deadline:
                    failure = .operationTimeout
                    hint = "Fresh population acquisition exceeded its owned deadline; no replacement report was published."
                case SessionPopulationObservation.AcquisitionError.ownershipLost:
                    failure = .readbackUnavailable
                    hint = "Fresh population could not retain operation ownership or cache/project custody; no replacement report was published."
                case SessionPopulationObservation.AcquisitionError.pollerStopped:
                    failure = .readbackUnavailable
                    hint = "The registered population producer is stopped; no replacement report was published."
                case SessionPopulationObservation.AcquisitionError.textEditing:
                    failure = .readbackUnavailable
                    hint = "Fresh population acquisition was stopped by its keyboard-focus/observation guard; no replacement report was published."
                default:
                    failure = .readbackUnavailable
                    hint = "Fresh population acquisition could not verify its owned observation; no replacement report was published."
                }
                return toolStateCResult(failure, hint: hint, extras: uiEffectExtras(effects))
            }
            if let acquireSessionPopulation {
                do {
                    capture = try await acquireSessionPopulation(request)
                } catch {
                    return acquisitionFailure(error)
                }
            } else {
                // Explicit legacy/headless seam: the registered server handler supplies the real producer.
                capture = await SessionPopulationObservation.capture(
                    cache: cache, targetRegistry: targetRegistry,
                    fileReader: cleanupAuditFileReader, requestedProjectRef: request.projectRef
                )
            }
            capturedUIEffects = capture.freshPopulation?.uiEffects ?? .init()
            // The registry accepted `project_ref` above, but it can still name the project the
            // cache held before an external switch. Another project's report is not an answer.
            if capture.requestedProjectMatches == false {
                return TargetRefResolver.staleTargetReferenceResult(
                    request.projectRef,
                    operation: "project.inspect_session",
                    referenceKey: "project_ref",
                    hint: "project_ref does not name the project the state cache holds (it changed after the reference was issued); no report was built",
                    extras: uiEffectExtras(capturedUIEffects)
                )
            }
            var report = SessionPopulationObservation.build(request: request, capture: capture)
            let bound = StateCache.sessionReportHasBoundPath(capture.project.filePath)
            report.snapshotRetention = .init(retained: bound,
                reason: bound ? nil : "project_identity_unobserved")
            do {
                let json = try encodeJSONStrict(report, compact: true)
                if acquireSessionPopulation != nil {
                    do { try SessionPopulationObservation.requireOwnedAcquisition() }
                    catch { return acquisitionFailure(error) }
                }
                // Keep incomplete/cold reads available, but do not create a name-bound handle.
                if !bound { return toolTextResult(json) }
                guard await cache.retainSessionReport(
                    id: report.snapshotId, json: json,
                    capturedEpoch: capture.projectEpoch, capturedPath: capture.project.filePath,
                    capture: capture, request: request,
                    stoppingWhen: {
                        acquireSessionPopulation != nil &&
                            (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil
                    }
                ) else {
                    if acquireSessionPopulation != nil {
                        do { try SessionPopulationObservation.requireOwnedAcquisition() }
                        catch { return acquisitionFailure(error) }
                    }
                    return toolStateCResult(.staleSnapshot,
                        hint: "capture could not be retained (project changed, document closed, or report exceeds 2 MiB); no reusable snapshot was issued",
                        extras: uiEffectExtras(capturedUIEffects))
                }
                return toolTextResult(json)
            } catch {
                // Honest Contract: a serialization failure must NOT be returned
                // as a success-shaped body. Fail loud with isError=true.
                return toolTextResult(
                    "{\"error\":\"inspect_session encode failed: \(jsonStringEscape(error.localizedDescription))\"}",
                    isError: true
                )
            }

        case "apply_session_repair":
            guard let request = ApprovedSessionRepair.ApplyRequest.parse(params) else {
                return ApprovedSessionRepair.ApplyRequest.refusal()
            }
            guard let applySessionRepair else {
                return toolStateCResult(.unsupportedState, hint: "The retained repair execution provider is unavailable.",
                    extras: ["write_attempted": false])
            }
            return await applySessionRepair(request)

        case "plan_session_repair":
            func refused(_ hint: String, stale: Bool = false) -> CallTool.Result {
                toolStateCResult(stale ? .staleSnapshot : .invalidParams,
                    hint: hint, extras: ["write_attempted": false])
            }
            guard Set(params.keys).isSubset(of: Set(["snapshot_id", "policy", "names", "plan_id", "digest"])
                    .union(ProjectSessionAudit.PlanningOptions.parameterKeys)),
                  let encoded = try? encodeJSONStrict(Value.object(params), compact: true),
                  encoded.utf8.count <= StateCache.sessionCaptureByteLimit else {
                return refused("unknown parameter or input exceeds the 2 MiB draft limit")
            }
            if let value = params["plan_id"] {
                guard case .string(let id) = value, !id.isEmpty,
                      params["snapshot_id"] == nil, params["policy"] == nil, params["names"] == nil,
                      ProjectSessionAudit.PlanningOptions.parameterKeys.isDisjoint(with: params.keys) else {
                    return refused("plan_id lookup cannot reinterpret snapshot, policy, names or planning options")
                }
                var digest: String?
                if let raw = params["digest"] {
                    guard case .string(let supplied) = raw else { return refused("digest must be a string") }
                    digest = supplied
                }
                guard let json = await cache.retainedRepairPlan(id: id, digest: digest) else {
                    return refused("plan is unknown, expired, evicted, from another cache/project, or digest differs; no replacement was generated", stale: true)
                }
                return toolTextResult(json)
            }
            guard params["digest"] == nil,
                  case .string(let snapshot)? = params["snapshot_id"], !snapshot.isEmpty,
                  case .object(let object)? = params["policy"] else {
                return refused("planning requires snapshot_id and an approved policy object")
            }
            guard let inspection = await cache.retainedInspection(id: snapshot) else {
                // Said apart from the other causes because inspecting again cannot help: nothing
                // about an unsaved project is retained, and qualification classifies this exact
                // refusal as a missing prerequisite rather than a product failure.
                if !StateCache.sessionReportHasBoundPath(await cache.getProject().filePath) {
                    return refused(Self.planSessionRepairUnboundProjectHint, stale: true)
                }
                return refused("snapshot is unknown, expired, evicted or unbound; inspect again to obtain a new handle", stale: true)
            }
            let policy: ProjectSessionAudit.IntentPolicy
            switch ProjectSessionAudit.parseIntentPolicy(object) {
            case .accepted(let accepted): policy = accepted
            case .rejected(let reasons):
                return refused("invalid repair policy: " + reasons.map(\.sortKey).joined(separator: "; "))
            }
            guard let names = ProjectSessionAudit.parseApprovedNames(params["names"], policy: policy) else {
                return refused("names must be at most 32 unique declared target/name objects with valid scalar names; no partial plan was created")
            }
            guard let options = ProjectSessionAudit.PlanningOptions.parse(params) else {
                return refused("on_ambiguity must be terminate or report_only (legacy ask is a terminal alias), and allow_create_aux, allow_stack_membership_change and allow_replace_send must be booleans; no plan was created")
            }
            do {
                let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(
                    policy: policy, policyValue: .object(object), names: names,
                    capture: inspection.capture, request: inspection.request,
                    snapshotCurrent: await cache.inspectionIsCurrent(inspection.capture),
                    options: options)
                guard await cache.retainRepairPlan(plan, snapshotID: snapshot) else {
                    return refused("plan source expired or storage limit exceeded; no reusable plan was issued", stale: true)
                }
                return toolTextResult(plan.json)
            } catch {
                return refused("plan serialization failed; no plan was retained")
            }

        case "cleanup_plan":
            let report = await ProjectSessionAudit.buildCleanupPlan(cache: cache)
            do {
                return toolTextResult(try encodeJSONStrict(report, compact: true))
            } catch {
                return toolTextResult(
                    "{\"error\":\"cleanup_plan encode failed: \(jsonStringEscape(error.localizedDescription))\"}",
                    isError: true
                )
            }

        case "cleanup_apply":
            let traceID = await startTraceIfEnabled(command: command)
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return await finalizeTrace(
                    blockingLogicDialogResult(operation: "project.cleanup_apply"),
                    traceID: traceID
                )
            }
            let result = await handleCleanupApply(
                params: params,
                router: router,
                cache: cache,
                auditFileReader: cleanupAuditFileReader,
                traceID: traceID
            )
            return await finalizeTrace(result, traceID: traceID)

        case "launch":
            let traceID = await startTraceIfEnabled(command: command)
            if isLogicProRunning() {
                audit(command, phase: .rejected, reason: "already running")
                return await finalizeTrace(
                    toolTextResult("Logic Pro is already running"),
                    traceID: traceID
                )
            }
            audit(command, phase: .executed)
            let result = await runLifecycleScript(
                script: LogicProTarget.appleScriptTarget().activateByBundleID,
                successMessage: "Logic Pro launched",
                expectedRunning: true,
                actionLabel: "launch",
                execute: executeLifecycleScript,
                isLogicProRunning: isLogicProRunning,
                sleep: sleep,
                traceID: traceID
            )
            return await finalizeTrace(result, traceID: traceID)

        case "quit":
            let traceID = await startTraceIfEnabled(command: command)
            let confirmation = destructiveConfirmation(for: command)
            if let error = confirmation.error {
                return await finalizeTrace(error, traceID: traceID)
            }
            if !confirmation.confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                audit(command, phase: .confirmationRequired)
                return await finalizeTrace(toolTextResult(response, isError: true), traceID: traceID)
            }
            if !isLogicProRunning() {
                audit(command, phase: .rejected, reason: "not running")
                return await finalizeTrace(
                    toolTextResult("Logic Pro is not running"),
                    traceID: traceID
                )
            }
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return await finalizeTrace(
                    blockingLogicDialogResult(operation: "project.quit"),
                    traceID: traceID
                )
            }
            audit(command, phase: .executed)
            let result = await runLifecycleScript(
                script: LogicProTarget.appleScriptTarget().quitByBundleID,
                successMessage: "Logic Pro quit",
                expectedRunning: false,
                actionLabel: "quit",
                execute: executeLifecycleScript,
                isLogicProRunning: isLogicProRunning,
                sleep: sleep,
                traceID: traceID
            )
            return await finalizeTrace(result, traceID: traceID)

        default:
            return Self.unhandledCommandResult(command, label: "project")
        }
    }

    enum InspectSessionParse {
        case request(SessionPopulationObservation.Request)
        case rejected(CallTool.Result)
    }

    /// #965: `inspect_session` parameters. A missing key takes the Request
    /// default; a wrong type, an unknown member, or an empty `domains` list is
    /// State C `invalid_params` with nothing captured. `project_ref` has already
    /// been validated against the registry at the top of `handle`; the capture
    /// then compares it with the project the cache actually holds.
    static func inspectSessionRequest(_ params: [String: Value]) -> InspectSessionParse {
        typealias Observation = SessionPopulationObservation
        func reject(_ hint: String) -> InspectSessionParse {
            .rejected(toolInvalidParamsResult(hint, extras: ["write_attempted": false]))
        }

        var scope: Observation.Scope = .wholeProject
        if let raw = params["scope"] {
            let allowed = Observation.Scope.allCases.map(\.rawValue).joined(separator: "|")
            guard let text = raw.stringValue else {
                return reject("'scope' must be a string: \(allowed)")
            }
            guard let parsed = Observation.Scope(rawValue: text) else {
                return reject("'scope' must be one of \(allowed); got '\(text)'")
            }
            scope = parsed
        }

        var domains = Observation.Request.defaultDomains
        if let raw = params["domains"] {
            let allowed = Observation.Domain.allCases.map(\.rawValue).joined(separator: "|")
            guard let array = raw.arrayValue else {
                return reject("'domains' must be an array of \(allowed)")
            }
            var parsed: [Observation.Domain] = []
            for element in array {
                guard let text = element.stringValue else {
                    return reject("'domains' must contain only strings: \(allowed)")
                }
                guard let domain = Observation.Domain(rawValue: text) else {
                    return reject("'domains' member '\(text)' is not one of \(allowed)")
                }
                if !parsed.contains(domain) { parsed.append(domain) }
            }
            guard !parsed.isEmpty else {
                return reject("'domains' must name at least one of \(allowed)")
            }
            domains = parsed
        }

        var allowUINavigation = false
        switch strictBoolParam(params, "allow_ui_navigation") {
        case .missing:
            break
        case .value(let value):
            allowUINavigation = value
        case .invalid(let hint):
            return reject(hint)
        }

        return .request(Observation.Request(
            scope: scope,
            domains: domains,
            allowUINavigation: allowUINavigation,
            projectRef: params["project_ref"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    /// v3.1.2 (P0-3) — invalidate cache on successful project lifecycle
    /// transition. Defensive: only fires when the underlying channel reports
    /// success, so a failed AppleScript leaves the cache untouched (preserves
    /// whatever truth the poller had).
    ///
    /// ADR-003: WHICH commands dirty the cache comes from the registry's
    /// `dirtySections` (currently `new` / `open` / `save_as` / `close` declare
    /// the full section set) — a call site cannot invalidate unless the
    /// registry entry declares impact, so no dispatcher-local list can drift.
    private static func invalidateOnSuccess(
        command: String,
        result: ChannelResult,
        cache: StateCache,
        targetRegistry: TargetRegistry?
    ) async {
        guard result.isSuccess,
              let spec = OperationRegistry.spec(
                  tool: ToolID.logicProject.rawValue,
                  command: command
              ),
              !spec.dirtySections.isEmpty else { return }
        await invalidateProjectState(cache: cache, targetRegistry: targetRegistry)
    }

    private static func invalidateProjectState(
        cache: StateCache,
        targetRegistry: TargetRegistry?
    ) async {
        await cache.clearProjectState()
        // ADR-006 coupling fix: the versioned-cache envelope publishes
        // `project_epoch` as ITS cross-project discriminator, so the epoch
        // must advance on lifecycle transitions whenever EITHER consumer is
        // active. Gating on adr002 alone froze the envelope's epoch at 0
        // when only adr006 was enabled (a constant discriminator across
        // project switches). With both flags off the bump has no observable
        // surface, so the either-flag condition is behavior-preserving for
        // the default configuration.
        if FeatureFlags.adr002TargetRef || FeatureFlags.adr006VersionedCache {
            await targetRegistry?.bumpProjectEpoch()
        }
    }

    private static func refreshRegionCache(
        from result: ChannelResult,
        cache: StateCache,
        ifCurrent observedProject: StateCache.ProjectIdentity?
    ) async {
        guard result.isSuccess,
              let payload = try? RegionInfo.decodeInventoryPayload(result.message) else {
            return
        }
        _ = await cache.updateRegions(
            payload.regions.map { $0.asRegionState() },
            complete: payload.isComplete,
            ifCurrent: observedProject
        )
    }

    /// Capture the exact identity-backed, populated-track scan that a stem dry
    /// run publishes. Placeholder/project-file rows are intentionally rejected:
    /// a count is not the index-and-name subject list the plan promises. A
    /// track is a stem subject only when a fresh, complete region inventory
    /// proves that the track contains at least one region.
    private static func stemSubjectInventory(
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> ProjectExportStemSubjectInventory? {
        guard let kinds = try? ProjectExportPlanner.artifactKinds(from: params),
              kinds.contains("stem") else {
            return nil
        }
        guard let projects = try? ProjectExportPlanner.projectPaths(from: params),
              projects.count == 1 else {
            return .unavailable(
                reason: "stem export plans one currently scanned project at a time; a batch has no per-project live subject scan"
            )
        }

        if ProcessInfo.processInfo.environment["LOGIC_MCP_LOGIC13_TRACKS"] == "1" {
            let observedProject = await cache.currentProjectIdentity()
            let expectedPath = URL(fileURLWithPath: projects[0]).standardizedFileURL.path
            let runtime = AXLogicProElements.Runtime.production
            guard observedProject?.path == expectedPath, !Task.isCancelled,
                  case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                  case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  let url = URL(string: document), url.isFileURL, url.standardizedFileURL.path == expectedPath else {
                return .unavailable(reason: "the currently observed project does not match the requested project")
            }
            let result = await router.route(operation: "region.get_regions")
            guard result.isSuccess, !Task.isCancelled,
                  case .found(let afterWindow) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                  CFEqual(window, afterWindow),
                  AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime) == .success(document),
                  let payload = try? RegionInfo.decodeInventoryPayload(result.message),
                  payload.isComplete,
                  await cache.updateRegions(payload.regions.map { $0.asRegionState() },
                    complete: true, ifCurrent: observedProject) else {
                return .unavailable(reason: "the requested project's complete region inventory could not be renewed")
            }
        }

        let snapshot = await cache.auditSnapshot()
        let now = Date()
        guard !snapshot.axOccluded else {
            return .unavailable(reason: "the live track scan is occluded by a Logic panel or dialog")
        }
        guard snapshot.projectFetchedAt > .distantPast,
              now.timeIntervalSince(snapshot.projectFetchedAt) <= stemSubjectInventoryMaximumAge else {
            return .unavailable(reason: "the observed project identity is stale or has not been read within \(Int(stemSubjectInventoryMaximumAge)) seconds")
        }
        guard snapshot.tracksFetchedAt > .distantPast,
              now.timeIntervalSince(snapshot.tracksFetchedAt) <= stemSubjectInventoryMaximumAge else {
            return .unavailable(reason: "the live track scan is stale or has not completed within \(Int(stemSubjectInventoryMaximumAge)) seconds")
        }
        guard snapshot.regionsFetchedAt > .distantPast,
              now.timeIntervalSince(snapshot.regionsFetchedAt) <= stemSubjectInventoryMaximumAge,
              snapshot.regionsComplete else {
            return .unavailable(reason: "a fresh complete region inventory is required to prove which tracks are populated")
        }
        let project = snapshot.project
        guard let observedPath = project.filePath, !observedPath.isEmpty else {
            return .unavailable(reason: "the live scan has no observed project identity")
        }
        let expectedPath = URL(fileURLWithPath: projects[0]).standardizedFileURL.path
        let scannedPath = URL(fileURLWithPath: observedPath).standardizedFileURL.path
        guard expectedPath == scannedPath else {
            return .unavailable(
                reason: "the live scan belongs to \(scannedPath), not planned project \(expectedPath)"
            )
        }

        guard snapshot.tracksProjectIdentity?.epoch == snapshot.projectEpoch,
              snapshot.tracksProjectIdentity?.path == scannedPath else {
            return .unavailable(
                reason: "the live track scan is not coherently associated with the observed project identity"
            )
        }
        guard snapshot.regionsProjectIdentity?.epoch == snapshot.projectEpoch,
              snapshot.regionsProjectIdentity?.path == scannedPath else {
            return .unavailable(
                reason: "the complete region inventory is not coherently associated with the observed project identity"
            )
        }

        let tracks = snapshot.tracks
        guard tracks.allSatisfy({ $0.liveIdentityBacked && $0.placeholder != true }) else {
            return .unavailable(
                reason: "the live track scan contains placeholder or identity-unbacked rows"
            )
        }
        let populatedTrackIDs = Set(snapshot.regions.map(\.trackIndex))
        let knownTrackIDs = Set(tracks.map(\.id))
        guard populatedTrackIDs.isSubset(of: knownTrackIDs) else {
            return .unavailable(reason: "the complete region inventory refers to a track absent from the live track scan")
        }
        return .scanned(
            projectPath: scannedPath,
            subjects: tracks
                .filter { populatedTrackIDs.contains($0.id) }
                .map { ProjectExportStemSubject(index: $0.id, name: $0.name) }
        )
    }

    /// H-1 (2026-05-08 enterprise review): audit phases for L1+ project
    /// commands. Splits the prior single `executed` line into three signals
    /// a SIEM can filter on.
    ///
    /// **Contract — v3.4.1:** `executed` is emitted
    /// **immediately before** `router.route(...)` fires, not after. This
    /// records *invocation intent* rather than *outcome*. The reasons:
    ///   - Outcome lives in the channel response (success / hard error).
    ///   - A post-route audit line would be lost if the AppleScript hung
    ///     or the actor died, exactly when audit visibility matters most.
    ///   - SIEM consumers that want the outcome can correlate the
    ///     `executed` line with the channel response by timestamp +
    ///     command name; the contract gives them both signals.
    /// Concretely: an L1 command that passes validation but fails at the
    /// channel level (Logic not running, AppleScript denied) will still
    /// show `[AUDIT] project.<command> executed` followed by an error
    /// envelope on the wire. That is the intended behaviour.
    enum AuditPhase: String, Sendable {
        /// Validation refused the call before any side effect.
        case rejected
        /// Destructive policy returned the confirmation envelope; no route
        /// was attempted, the caller is expected to retry with `confirmed:true`.
        case confirmationRequired = "confirmation_required"
        /// The underlying route was invoked. Success or hard failure is then
        /// captured in the channel response, not the audit line.
        case executed
    }

    /// Emit an audit line for L1+ commands. No-op for L0 (`is_running`,
    /// `get_regions`, etc.) so read-only ops don't pollute the audit log.
    static func audit(_ command: String, phase: AuditPhase, reason: String? = nil) {
        guard DestructivePolicy.needsAuditLog(for: command) else { return }
        if let reason {
            Log.info("[AUDIT] project.\(command) \(phase.rawValue) — \(reason)", subsystem: "project")
        } else {
            Log.info("[AUDIT] project.\(command) \(phase.rawValue)", subsystem: "project")
        }
    }

    private static func runLifecycleScript(
        script: String,
        successMessage: String,
        expectedRunning: Bool,
        actionLabel: String,
        execute: (String) async -> LifecycleExecution,
        isLogicProRunning: () -> Bool,
        sleep: (UInt64) async -> Void,
        traceID: TraceID?
    ) async -> CallTool.Result {
        // #389: no router involved — the AppleScript launch/quit IS the external
        // effect, and it is about to run unconditionally, so the immediate emit
        // is an honest observation of the genuine first write.
        guard await recordWriteBoundary(
            traceID,
            deadlineStage: "project_\(actionLabel)"
        ) else {
            return toolStateCResult(
                .cancelled,
                hint: "The request deadline won before the Logic Pro \(actionLabel) effect began.",
                extras: [
                    "operation": "project.\(actionLabel)",
                    "write_attempted": false,
                ]
            )
        }
        let execution = await execute(script)
        if let executionError = execution.executionError {
            return toolTextResult("Failed to \(actionLabel) Logic Pro: \(executionError)", isError: true)
        }
        let launchTimedOut = expectedRunning && execution.timedOut
        if execution.timedOut && !launchTimedOut {
            return toolTextResult(
                "Failed to \(actionLabel) Logic Pro: timed out after \(Int(ServerConfig.appleScriptTimeout))s",
                isError: true
            )
        }
        if !launchTimedOut && execution.terminationStatus != 0 {
            let message = execution.stderrOutput.isEmpty
                ? "osascript exited with status \(execution.terminationStatus)"
                : execution.stderrOutput
            return toolTextResult("Failed to \(actionLabel) Logic Pro: \(message)", isError: true)
        }

        let statePolls = Int(max(1, ServerConfig.appleScriptTimeout * 10))
        for _ in 0..<statePolls {
            if isLogicProRunning() == expectedRunning {
                return toolTextResult(launchTimedOut
                    ? "Logic Pro is running after launch; AppleScript activation timed out after \(Int(ServerConfig.appleScriptTimeout))s"
                    : successMessage)
            }
            await sleep(100_000_000)
        }

        return toolTextResult(
            launchTimedOut
                ? "Failed to \(actionLabel) Logic Pro: timed out after \(Int(ServerConfig.appleScriptTimeout))s"
                : "Lifecycle command completed but Logic Pro did not reach expected running state",
            isError: true
        )
    }

    static func executeAppleScript(
        _ script: String,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/osascript")
    ) async -> LifecycleExecution {
        let result = BoundedProcessRunner.run(
            executable: executableURL.path,
            arguments: ["-e", script],
            timeout: ServerConfig.appleScriptTimeout,
            outputLimitBytes: 32 * 1024
        )

        switch result {
        case let .spawnFailed(message):
            return LifecycleExecution(
                executionError: message,
                timedOut: false,
                terminationStatus: -1,
                stderrOutput: ""
            )
        case .timedOut:
            return LifecycleExecution(
                executionError: nil,
                timedOut: true,
                terminationStatus: -1,
                stderrOutput: ""
            )
        case let .completed(output):
            return LifecycleExecution(
                executionError: nil,
                timedOut: false,
                terminationStatus: output.exitCode,
                stderrOutput: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
