import Foundation

extension QualificationTransport {
    func initialize(_ session: QualificationSubprocessSession) throws -> QualificationHandshake {
        let result: InitializeResult = try session.request(
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": "2025-11-25",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "adr001b-qualification", "version": "1.0"],
            ],
            phase: "handshake",
            timeout: handshakeTimeout
        )
        try session.notify(method: "notifications/initialized")
        return QualificationHandshake(
            protocolVersion: result.protocolVersion,
            serverName: result.serverInfo.name,
            serverVersion: result.serverInfo.version
        )
    }

    func health(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (value: QualificationHealth, stableData: Data) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": ["command": "health", "params": [:] as [String: Any]],
            ],
            phase: phase
        )
        guard result.isError != true else {
            throw QualificationTransportError.protocolViolation("\(phase): tool returned isError")
        }
        let text = try result.text(phase: phase)
        let wire: HealthResult = try Self.decodeInner(text, phase: phase)
        return (
            QualificationHealth(
                logicProRunning: wire.logicProRunning,
                logicProVersion: wire.logicProVersion,
                logicProBundleID: wire.logicProBundleID,
                logicProVariant: wire.logicProVariant,
                logicProUILocale: wire.logicProUILocale,
                processMetadataResolved: wire.processMetadataResolved,
                variants: wire.variants.compactMap { variant in
                    let mapped: LogicVariant
                    switch variant.variant {
                    case LogicProVariant.desktop.rawValue:
                        mapped = .desktop
                    case LogicProVariant.creatorStudio.rawValue:
                        mapped = .creatorStudio
                    default:
                        return nil
                    }
                    return QualificationVariantAvailability(
                        variant: mapped,
                        bundleID: variant.bundleID,
                        installed: variant.installed,
                        running: variant.running
                    )
                }
            ),
            try Self.stableHealthData(text, phase: phase)
        )
    }

    func catalog(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (value: OperationCatalogSnapshot, stableData: Data) {
        let result: ResourceReadResult = try session.request(
            id: id,
            method: "resources/read",
            params: ["uri": "logic://system/operations"],
            phase: phase
        )
        guard let content = result.contents.first,
              content.uri == "logic://system/operations",
              let text = content.text else {
            throw QualificationTransportError.protocolViolation("\(phase): missing operations content")
        }
        return (
            try Self.decodeInner(text, phase: phase),
            try Self.stableCatalogData(text, phase: phase)
        )
    }

    func traces(
        _ session: QualificationSubprocessSession,
        id: Int
    ) throws -> QualificationTraceList {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": [
                    "command": "list_recent_traces",
                    "params": ["limit": 10],
                ],
            ],
            phase: "trace_roundtrip"
        )
        guard result.isError != true else {
            throw QualificationTransportError.protocolViolation(
                "trace_roundtrip: \(try result.text(phase: "trace_roundtrip"))"
            )
        }
        let wire: TraceListResult = try Self.decodeInner(
            result.text(phase: "trace_roundtrip"),
            phase: "trace_roundtrip"
        )
        guard wire.traceDisabled != true else {
            throw QualificationTransportError.protocolViolation("trace_roundtrip: trace_disabled")
        }
        return QualificationTraceList(traces: wire.traces.map {
            QualificationTraceEntry(
                traceID: $0.traceID,
                operationID: $0.operationID,
                phaseCount: $0.phaseCount,
                readbackState: $0.readbackState
            )
        })
    }

    func trace(
        _ session: QualificationSubprocessSession,
        id: Int,
        traceID: String
    ) throws -> QualificationTraceDetail {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": [
                    "command": "get_trace",
                    "params": ["trace_id": traceID],
                ],
            ],
            phase: "trace_get"
        )
        guard result.isError != true else {
            throw QualificationTransportError.protocolViolation("trace_get: tool returned isError")
        }
        let wire: TraceDetailResult = try Self.decodeInner(
            result.text(phase: "trace_get"),
            phase: "trace_get"
        )
        return QualificationTraceDetail(
            traceID: wire.traceID,
            operationID: wire.operationID,
            phases: wire.events.map(\.phase)
        )
    }

    static func operationRequestTimeout(for spec: OperationSpec) -> TimeInterval {
        spec.deadline.seconds + 5
    }

    static func readProbeRefreshTimeout() throws -> TimeInterval {
        guard let spec = OperationRegistry.spec(
            tool: "logic_system", command: "refresh_cache"),
              spec.id == .systemRefreshCache else {
            throw QualificationTransportError.protocolViolation(
                "read_probe_refresh: operation spec unavailable")
        }
        return operationRequestTimeout(for: spec)
    }

    func operation(
        _ session: QualificationSubprocessSession,
        id: Int,
        spec: OperationSpec,
        traceID: String,
        sessionSnapshotID: String? = nil,
        preparedReadParams: [OperationID: [String: Any]] = [:],
        timeout: TimeInterval? = nil
    ) throws -> (text: String, isError: Bool) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": spec.tool.rawValue,
                "arguments": [
                    "command": spec.command,
                    "params": Self.probeParams(
                        for: spec, traceID: traceID, sessionSnapshotID: sessionSnapshotID,
                        preparedReadParams: preparedReadParams),
                ],
            ],
            phase: "operation_probe.\(spec.id.rawValue)",
            timeout: timeout ?? Self.operationRequestTimeout(for: spec)
        )
        return (
            try result.text(phase: "operation_probe.\(spec.id.rawValue)"),
            result.isError == true
        )
    }

    func pluginInventory(
        _ session: QualificationSubprocessSession,
        id: Int,
        track: Int,
        phase: String
    ) throws -> Data {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_plugins",
                "arguments": [
                    "command": "get_inventory",
                    "params": ["track": track],
                ],
            ],
            phase: phase
        )
        return Data(try result.text(phase: phase).utf8)
    }

    /// #373 Phase B: the two history operations, and which way each one moves the stack.
    static let historyRestoreDirection: [OperationID: HistoryDirection] = [
        .editUndo: .undo,
        .editRedo: .redo,
    ]

    /// #373 Phase B: the marker operations that need a marker to exist before they can run, and
    /// the staged shape each one takes. See `markerStagedRestoreCycle`.
    static let markerStagedRestoreMode: [OperationID: MarkerStagedMode] = [
        .navigateRenameMarker: .rename,
        .navigateDeleteMarker: .delete,
    ]

    /// #373 Phase B: the mutating operations that move the playhead to a bar and are read back
    /// out of `logic://transport/state`.
    ///
    /// `navigate.goto_bar` and `transport.goto_position` are two dispatchers over one observable.
    /// Membership here is the claim that the operation takes a `bar` number and that the transport
    /// resource reports where the playhead ended up — not that the two commands are interchangeable
    /// for callers, which they are not: `goto_position` also accepts a `position` string and a
    /// SMPTE form that this cycle does not exercise.
    static let playheadRestoreOperations: Set<OperationID> = [
        .navigateGotoBar,
        .transportGotoPosition,
    ]

    static let playheadStepDirections: [OperationID: Int] = [
        .transportRewind: -1, .transportFastForward: 1,
    ]

    /// #373 Phase B: the mutating operations whose recipe is a reversible boolean toggle, and the
    /// `logic://tracks` field that independently reports each one.
    ///
    /// A table rather than a switch because the addition it invites is a ROW — an operation, plus
    /// the field a reader can check it against. An operation with no honest independent field does
    /// not belong here and must not be given one that merely correlates.
    /// #373 Phase B: the toggles whose actuator refuses unless the TARGET TRACK is the only
    /// selected one, so the recipe has to arrange that before it writes.
    ///
    /// `tracks.arm` posts a key chord, and Logic's record-arm acts on the selection — so the rung
    /// re-checks `selectionIsExclusive(index:)` immediately before every post and refuses
    /// otherwise. Measured 2026-09-14: driven on its own after a `select`, `tracks.arm` answers
    /// State A verified on the same track the sweep failed on; inside the sweep nothing had
    /// selected it, the rung refused, and the answer that reached the recipe was the next channel's.
    /// `mute` and `solo` write an AX value and need no selection, which is why they are not here —
    /// staging one for them would move a selection the cycle has no reason to touch.
    static let requiresExclusiveSelection: Set<OperationID> = [.tracksArm]

    static let booleanToggleReadbackField: [OperationID: String] = [
        .tracksMute: "isMuted",
        .tracksSolo: "isSoloed",
        .tracksArm: "isArmed",
    ]

    /// Did the operation's own envelope say the write DID NOT happen?
    ///
    /// The recipes used to refuse on `isError`, which is too strict by exactly the case Phase B
    /// exists for. Measured 2026-09-14: `navigate.goto_bar` answers **State B**, `success: true`,
    /// `verified: false`, `reason: readback_unavailable` — "the write landed but I could not
    /// confirm it" — and the playhead moved from bar 20 to bar 17. Refusing that means Phase B can
    /// never qualify the operations that most need it, because supplying the independent
    /// confirmation the operation could not get is the recipe's whole job.
    ///
    /// State C is different and still refuses: it is the contract's "the write itself didn't
    /// succeed". So the question asked here is narrow — did the operation say it failed — and the
    /// readback guards decide everything else.
    static func mutationSaysItFailed(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // An unparseable answer is not a claim that the write landed.
            return true
        }
        if let state = object["state"] as? String { return state == "C" }
        if let success = object["success"] as? Bool { return !success }
        return true
    }

    /// Return a bounded wait only for the server's exact zero-write contention envelope after a
    /// deadline-abandoned holder. Healthy holders, unsafe replies, malformed values, and generic
    /// retry hints remain fail-closed and consume no qualification wait.
    static func cleanupGateReclaimDelay(
        _ reply: (text: String, isError: Bool)
    ) -> TimeInterval? {
        guard reply.isError,
              let data = reply.text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["state"] as? String == "C",
              exactJSONBoolean(object["success"], equals: false),
              object["error"] as? String == "mutating_operation_in_progress",
              exactJSONBoolean(object["safe_to_retry"], equals: true),
              exactJSONBoolean(object["write_attempted"], equals: false),
              object["mutation_gate"] as? String == "reclaimable_after_grace",
              let delayNumber = object["gate_reclaim_after_sec"] as? NSNumber,
              CFGetTypeID(delayNumber) != CFBooleanGetTypeID() else { return nil }
        let delay = delayNumber.doubleValue
        guard
              delay.isFinite, delay >= 0,
              delay <= LogicProServer.mutationGateReclaimGraceSeconds else { return nil }
        return delay
    }

    private static func exactJSONBoolean(_ value: Any?, equals expected: Bool) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue == expected
    }

    /// One tool call with CALLER-SUPPLIED params.
    ///
    /// `operation(…)` above always sends `probeParams`, which for a mutating operation is the
    /// deliberate no-write probe. A Phase-B recipe has to send a real request, so it needs this.
    /// Kept separate rather than adding a parameter to `operation` so the no-write probe stays the
    /// only thing the sweep itself can send.
    /// `timeout` nil uses the transport's generic 10 s request bound, which is right for a resource
    /// read and WRONG for the operation a Phase-B cycle is exercising: the registry already says
    /// how long each operation may take, and a harness that gives up inside that window reports a
    /// timeout of its own making. Measured 2026-09-14 — with `tracks.arm`'s write path finally
    /// working, its cycle failed as `qualification_transport_timeout:phase_b.mutation` while the
    /// operation was still inside its own `.short` deadline, having done nothing wrong.
    func invoke(
        _ session: QualificationSubprocessSession,
        id: Int,
        tool: String,
        command: String,
        params: [String: Any],
        phase: String,
        timeout: TimeInterval? = nil
    ) throws -> (text: String, isError: Bool) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: ["name": tool, "arguments": ["command": command, "params": params]],
            phase: phase,
            timeout: timeout
        )
        return (try result.text(phase: phase), result.isError == true)
    }
}

private struct InitializeResult: Decodable {
    struct ServerInfo: Decodable {
        let name: String
        let version: String
    }

    let protocolVersion: String
    let serverInfo: ServerInfo
}

struct ToolCallResult: Decodable {
    struct Content: Decodable {
        let type: String
        let text: String?
    }

    let content: [Content]
    let isError: Bool?

    func text(phase: String) throws -> String {
        guard let content = content.first(where: { $0.type == "text" }),
              let text = content.text else {
            throw QualificationTransportError.protocolViolation("\(phase): missing text content")
        }
        return text
    }
}

struct ResourceReadResult: Decodable {
    struct Content: Decodable {
        let uri: String
        let text: String?
    }

    let contents: [Content]
}

struct HealthResult: Decodable, Equatable {
    struct VariantAvailability: Decodable, Equatable {
        let variant: String
        let bundleID: String
        let installed: Bool
        let running: Bool

        enum CodingKeys: String, CodingKey {
            case variant
            case bundleID = "bundle_id"
            case installed
            case running
        }
    }

    let logicProRunning: Bool
    let logicProVersion: String
    let logicProBundleID: String
    let logicProVariant: String
    let logicProUILocale: String
    let processMetadataResolved: Bool
    let variants: [VariantAvailability]

    enum CodingKeys: String, CodingKey {
        case logicProRunning = "logic_pro_running"
        case logicProVersion = "logic_pro_version"
        case logicProBundleID = "logic_pro_bundle_id"
        case logicProVariant = "logic_pro_variant"
        case logicProUILocale = "logic_pro_ui_locale"
        case processMetadataResolved = "process_metadata_resolved"
        case variants = "logic_pro_variants"
    }
}

private struct TraceListResult: Decodable {
    struct Trace: Decodable {
        let traceID: String
        let operationID: String
        let phaseCount: Int
        let readbackState: String?

        enum CodingKeys: String, CodingKey {
            case traceID = "trace_id"
            case operationID = "operation_id"
            case phaseCount = "phase_count"
            case readbackState = "readback_state"
        }
    }

    let traces: [Trace]
    let traceDisabled: Bool?

    enum CodingKeys: String, CodingKey {
        case traces
        case traceDisabled = "trace_disabled"
    }
}

private struct TraceDetailResult: Decodable {
    struct Event: Decodable {
        let phase: String
    }

    let traceID: String
    let operationID: String
    let events: [Event]

    enum CodingKeys: String, CodingKey {
        case traceID = "trace_id"
        case operationID = "operation_id"
        case events
    }
}

struct OperationProbeResult: Decodable {
    let state: String?
    let error: String?
    let hint: String?
    let reason: String?
    let writeAttempted: Bool?
    let rowSelectionWriteAttempted: Bool?
    let rowSelectionRestored: Bool?
    let traceID: String?

    enum CodingKeys: String, CodingKey {
        case state
        case error
        case hint
        case reason
        case writeAttempted = "write_attempted"
        case rowSelectionWriteAttempted = "row_selection_write_attempted"
        case rowSelectionRestored = "row_selection_restored"
        case traceID = "trace_id"
    }
}

struct NegativeResult: Decodable {
    let state: String
    let error: String
    let writeAttempted: Bool

    enum CodingKeys: String, CodingKey {
        case state
        case error
        case writeAttempted = "write_attempted"
    }
}
