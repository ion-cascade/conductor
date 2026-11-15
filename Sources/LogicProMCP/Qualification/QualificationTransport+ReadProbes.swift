import Foundation
import CoreMIDI

extension QualificationTransport {
    /// Inputs shared by the non-mutating operation probes.
    ///
    /// `system.clear_traces` receives `confirmed:true`: its destructive scope is the in-process
    /// trace store, the runner reads the trace evidence it needs before entering the operation
    /// loop, and the operation itself writes the durable receipt its oracle verifies. Sending
    /// `false` only exercised the confirmation refusal and permanently misclassified correct
    /// validation as a live-gate failure.
    /// One spelling of the key, shared by the seed and the probe. Two literals would be two
    /// places to keep in step, and the failure mode is silent: `saga_status` would look up a
    /// record nothing wrote and report exactly what it reported before the seed existed.
    static let sagaProbeIdempotencyKey = "qualification-read-probe"
    static let qualificationAudioProbePath = "/System/Library/Sounds/Ping.aiff"
    static let mixerReadProbeOperationIDs: Set<OperationID> = [
        .mixerGetOutputVerified,
        .mixerGetInputBusVerified,
        .mixerGetSendDestinationVerified,
        .mixerGetSendBypassVerified,
    ]
    static let consentFirstMutationProbeOperationIDs: Set<OperationID> = [
        .systemSetupArmKey,
        .systemSetupControlSurface,
        .systemSetupMIDIKeyCommands,
    ]
    enum SessionInspectionSeedPurpose: Sendable {
        case planner
        case mixerRead

        var maximumAttempts: Int {
            switch self {
            case .planner: 2
            case .mixerRead: 1
            }
        }
    }
    static let mixerInspectionSeedDomains = ["strips"]

    static func sessionInspectionSeedRequestParams(
        for purpose: SessionInspectionSeedPurpose
    ) -> [String: Any] {
        switch purpose {
        case .planner:
            return [:]
        case .mixerRead:
            return [
                "scope": "whole_project",
                "domains": mixerInspectionSeedDomains,
                "allow_ui_navigation": false,
            ]
        }
    }
    static let pluginReadProbeOperationIDs: Set<OperationID> = [
        .pluginsGetHostParameterManifest,
        .pluginsGetPresetVerified,
        .pluginsGetSidechainVerified,
        .pluginsGetParamVerified,
        .pluginsGetChannelEQStateVerified,
        .pluginsPlanParameterChanges,
    ]
    static func selectedAutomationTarget(from data: Data, deadline: DeadlineClass) -> String? {
        guard QualificationReadbackFreshness.verdict(for: data, uri: "logic://tracks",
            verification: .readbackRequired, deadline: deadline).isAdmissible,
            let envelope = JSONInspector.parse(data) as? [String: Any],
            let tracks = envelope["data"] as? [[String: Any]] else { return nil }
        let selection = tracks.filter { track in
            guard let selected = track["isSelected"], JSONInspector.isBoolean(selected) else { return false }
            return selected as? Bool == true
        }
        guard selection.count == 1, let reference = selection[0]["track_ref"] as? String,
              reference.hasPrefix("trk_"), reference.count > 4,
              tracks.filter({ $0["track_ref"] as? String == reference }).count == 1 else { return nil }
        return reference
    }

    static let qualificationHostBuildFingerprint = "logic-pro-mcp-qualification-unverified"

    /// Read-only Mixer probes must address the exact physical sources the current server issued.
    /// Names and Arrange indices cannot substitute for a `mix_` reference: Aux and output strips
    /// have no safe Arrange ordinal, and duplicate names are ordinary. The resource's typed slot
    /// observations decide which operation can be attempted; untyped display bytes never grant a
    /// send or input capability.
    /// `nil` means the inspection itself was not admissible. An empty dictionary is different:
    /// the inspection was current, request-owned and read-only, but this project did not expose a
    /// physical source suitable for the requested probe. The live gate must keep that distinction
    /// so unsafe evidence remains a failure while an honest fixture gap remains visible as an
    /// environmental precondition.
    static func validatedMixerReadProbeParams(
        from resourceData: Data
    ) -> [OperationID: [String: Any]]? {
        guard let envelope = try? JSONSerialization.jsonObject(with: resourceData) as? [String: Any]
        else { return nil }
        guard let snapshotID = envelope["snapshot_id"] as? String, !snapshotID.isEmpty,
              envelope["schema"] as? String == "logic_pro_mcp_session_population.v1",
              let readOnly = envelope["read_only"], JSONInspector.isBoolean(readOnly),
              readOnly as? Bool == true,
              envelope["scope"] as? String == "whole_project",
              envelope["requested_domains"] as? [String] == mixerInspectionSeedDomains,
              let sources = envelope["sources"] as? [String: Any],
              sources["strips"] as? String == "ax_request_read",
              let section = envelope["strips"] as? [String: Any],
              let stripCoverage = section["coverage"] as? String,
              ["complete", "partial"].contains(stripCoverage),
              let strips = section["rows"] as? [[String: Any]],
              let effects = envelope["ui_effects"] as? [String: Any],
              let navigationPerformed = effects["navigation_performed"],
              JSONInspector.isBoolean(navigationPerformed),
              navigationPerformed as? Bool == false,
              effects["restoration"] as? String == "not_applicable",
              effects["attempted"] as? [String] == [],
              effects["changed"] as? [String] == [],
              effects["reason"] == nil || effects["reason"] is NSNull else {
            return nil
        }
        var params: [OperationID: [String: Any]] = [:]
        for strip in strips {
            guard let reference = strip["mixer_strip_ref"] as? String,
                  reference.hasPrefix("mix_"), reference.count > 4 else { return nil }

            if let rawOutput = strip["output_observation"] {
                guard let observation = rawOutput as? [String: Any],
                      let state = observation["state"] as? String else { return nil }
                switch state {
                case "observed_destination":
                    guard let destination = observation["destination"] as? String else { return nil }
                    if params[.mixerGetOutputVerified] == nil,
                       OutputAssignment.observed(slotLabel: destination) != nil {
                        params[.mixerGetOutputVerified] = ["target_ref": reference]
                    }
                case "no_slot", "unreadable":
                    guard observation["destination"] == nil
                            || observation["destination"] is NSNull else { return nil }
                default:
                    return nil
                }
            }
            if let rawInput = strip["input_observation"] {
                guard let observation = rawInput as? [String: Any],
                      let state = observation["state"] as? String else { return nil }
                switch state {
                case "observed_source":
                    guard let source = observation["source"] as? String else { return nil }
                    if params[.mixerGetInputBusVerified] == nil,
                       InputAssignment.classifiedMenuTitle(source)?.busOutputAssignment != nil {
                        params[.mixerGetInputBusVerified] = ["target_ref": reference]
                    }
                case "no_slot", "unreadable":
                    guard observation["source"] == nil
                            || observation["source"] is NSNull else { return nil }
                default:
                    return nil
                }
            }
            guard let rawSlots = strip["send_slots"] else { continue }
            guard let slots = rawSlots as? [[String: Any]] else { return nil }
            for slot in slots {
                guard let ordinal = slot["ordinal"] as? Int, ordinal >= 0,
                      let state = slot["state"] as? String else { return nil }
                guard [
                    "observed_empty", "occupied_unknown_destination",
                    "occupied_known_destination", "unreadable",
                ].contains(state) else { return nil }
                guard state == "occupied_unknown_destination"
                        || state == "occupied_known_destination" else { continue }
                if params[.mixerGetSendDestinationVerified] == nil {
                    params[.mixerGetSendDestinationVerified] = [
                        "target_ref": reference, "ordinal": ordinal,
                    ]
                }
                if let bypassed = slot["bypassed"], !(bypassed is Bool) { return nil }
                if params[.mixerGetSendBypassVerified] == nil, slot["bypassed"] is Bool {
                    params[.mixerGetSendBypassVerified] = [
                        "target_ref": reference, "ordinal": ordinal,
                    ]
                }
            }
        }
        return params
    }

    static func mixerReadProbeParams(from resourceData: Data) -> [OperationID: [String: Any]] {
        validatedMixerReadProbeParams(from: resourceData) ?? [:]
    }

    /// Build live plug-in read probes only from complete inventory responses that issued current
    /// `ins_` references. The catalog narrows those physical insert observations to readers the
    /// shipped dispatcher can actually execute; an occupied name alone grants no parameter
    /// capability. Plan probes use the planner's stricter raw-unit predicate and never authorize
    /// application.
    static func validatedPluginReadProbeParams(
        from inventoryResponses: [Data]
    ) -> [OperationID: [String: Any]]? {
        struct Candidate {
            let reference: String
            let pluginID: String
            let entry: StockPluginCatalogEntry
            let order: Int
        }

        var candidates: [Candidate] = []
        for data in inventoryResponses {
            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope["state"] as? String == "A",
                  envelope["complete"] as? Bool == true,
                  let plugins = envelope["plugins"] as? [[String: Any]] else { return nil }
            for plugin in plugins {
                guard let readStatus = plugin["read_status"] as? String,
                      let occupied = plugin["occupied"] as? Bool else { return nil }
                switch readStatus {
                case "empty":
                    guard !occupied, plugin["plugin_id"] is NSNull else { return nil }
                    continue
                case "ok":
                    guard occupied else { return nil }
                case "unreadable", "unclassified":
                    // A producer cannot call an inventory complete while retaining an unreadable
                    // or unclassified row.
                    return nil
                default:
                    return nil
                }
                guard let reference = plugin["plugin_insert_ref"] as? String,
                      reference.hasPrefix("ins_"), reference.count > 4,
                      plugin.keys.contains("plugin_id") else { return nil }
                if plugin["plugin_id"] is NSNull {
                    // A readable third-party/non-catalog insert is a valid observation, but it
                    // cannot authorize one of the catalog-backed qualification probes.
                    continue
                }
                guard let pluginID = plugin["plugin_id"] as? String,
                      !pluginID.isEmpty else { return nil }
                guard let entry = VerifiedPluginCatalog.productionEntryLookup(pluginID) else {
                    // The producer represents a readable non-catalog insert with JSON null.
                    // A non-null unknown id is contradictory discovery, not an empty fixture.
                    return nil
                }
                candidates.append(Candidate(
                    reference: reference,
                    pluginID: pluginID,
                    entry: entry,
                    order: candidates.count
                ))
            }
        }

        var params: [OperationID: [String: Any]] = [:]
        if let candidate = candidates.first {
            params[.pluginsGetHostParameterManifest] = [
                "target_ref": candidate.reference,
                "expected_build_fingerprint": Self.qualificationHostBuildFingerprint,
            ]
        }

        if let compressor = candidates.first(where: { $0.pluginID == "logic.stock.effect.compressor" }) {
            params[.pluginsGetPresetVerified] = ["target_ref": compressor.reference]
            params[.pluginsGetSidechainVerified] = ["target_ref": compressor.reference]
        }

        // Gain's scalar is the least invasive measured reader in the qualification fixture. Keep
        // deterministic inventory order for every other catalog-backed plug-in.
        let scalarCandidates = candidates.sorted { lhs, rhs in
            let lhsPriority = lhs.pluginID == "logic.stock.effect.gain" ? 0 : 1
            let rhsPriority = rhs.pluginID == "logic.stock.effect.gain" ? 0 : 1
            return lhsPriority == rhsPriority ? lhs.order < rhs.order : lhsPriority < rhsPriority
        }
        if let selected = scalarCandidates.lazy.compactMap({ candidate -> (Candidate, StockPluginParameterMetadata)? in
            guard let parameter = candidate.entry.parameters.first(where: Self.pluginParameterIsReadable)
            else { return nil }
            return (candidate, parameter)
        }).first {
            params[.pluginsGetParamVerified] = [
                "target_ref": selected.0.reference,
                "param": selected.1.id,
            ]
        }

        if let channelEQ = candidates.first(where: {
            $0.pluginID == "logic.stock.effect.channel_eq"
        }) {
            params[.pluginsGetChannelEQStateVerified] = ["target_ref": channelEQ.reference]
        }

        if let selected = candidates.lazy.compactMap({ candidate
            -> (Candidate, StockPluginParameterMetadata, Any)? in
            guard let parameter = candidate.entry.parameters.first(where: Self.pluginParameterIsPlanReadable),
                  let value = Self.qualificationPlanValue(for: parameter) else { return nil }
            return (candidate, parameter, value)
        }).first, let unit = selected.1.unit {
            params[.pluginsPlanParameterChanges] = [
                "target_ref": selected.0.reference,
                "changes": [[
                    "param": selected.1.id,
                    "value": selected.2,
                    "unit": unit,
                ] as [String: Any]],
            ]
        }
        return params
    }

    static func pluginReadProbeParams(from inventoryResponses: [Data]) -> [OperationID: [String: Any]] {
        validatedPluginReadProbeParams(from: inventoryResponses) ?? [:]
    }

    /// Prepare plug-in probes from their own two authorities only. Session inspection is a Mixer
    /// source and must not suppress a valid plug-in inventory when that unrelated read refuses.
    static func preparePluginReadProbeParams(
        tracksRead: () throws -> Data,
        inventoryRead: (Int) throws -> Data
    ) throws -> [OperationID: [String: Any]] {
        let tracksData = try tracksRead()
        guard let trackIndices = validatedPluginInventoryTrackIndices(from: tracksData) else {
            throw QualificationTransportError.protocolViolation(
                "plugin_read_probe_tracks: response was not a complete live referenced Arrange inventory"
            )
        }
        let inventories = try trackIndices.map(inventoryRead)
        guard let params = validatedPluginReadProbeParams(from: inventories) else {
            throw QualificationTransportError.protocolViolation(
                "plugin_read_probe_inventory: response was malformed, incomplete, or not current"
            )
        }
        return params
    }

    /// Warm the candidate's read cache once before any requested Mixer or plug-in probe. A failed
    /// refresh is shared evidence for every dependent read and must not be replaced by a later
    /// operation refusal. Plug-in discovery remains owned by tracks plus plug-in inventories.
    static func prepareRequestedReadProbeParams(
        requestedMixerReads: Set<OperationID>,
        requestedPluginReads: Set<OperationID>,
        refresh: (TimeInterval) throws -> (text: String, isError: Bool),
        pluginPreparation: () throws -> [OperationID: [String: Any]]
    ) -> (params: [OperationID: [String: Any]], failures: [OperationID: String]) {
        let requestedReads = requestedMixerReads.union(requestedPluginReads)
        guard !requestedReads.isEmpty else { return ([:], [:]) }

        do {
            let result = try refresh(try readProbeRefreshTimeout())
            guard !result.isError else {
                throw QualificationTransportError.protocolViolation(
                    "read_probe_refresh: tool returned isError")
            }
        } catch {
            let failure = observedFailureReason(
                from: error, during: "read-probe cache refresh")
            return (
                [:],
                Dictionary(uniqueKeysWithValues: requestedReads.map { ($0, failure) })
            )
        }

        guard !requestedPluginReads.isEmpty else { return ([:], [:]) }
        do {
            return (try pluginPreparation(), [:])
        } catch {
            let failure = observedFailureReason(
                from: error, during: "plug-in read-probe preparation")
            return (
                [:],
                Dictionary(uniqueKeysWithValues: requestedPluginReads.map { ($0, failure) })
            )
        }
    }

    /// Mixer read operations can spend longer navigating than the resource freshness window.
    /// Refresh immediately before their independent resource read, while leaving every freshness
    /// and semantic validator unchanged. A refused refresh cannot be followed by a read whose old
    /// cache bytes would be mistaken for evidence from this operation.
    static func independentResourceReadback(
        source: String,
        nextRequestID: inout Int,
        refresh: (Int, TimeInterval) throws -> (text: String, isError: Bool),
        read: (Int) throws -> Data
    ) throws -> Data {
        if source == "logic://mixer" {
            let timeout = try readProbeRefreshTimeout()
            let refreshID = nextRequestID
            nextRequestID += 1
            let result = try refresh(refreshID, timeout)
            guard !result.isError else {
                throw QualificationTransportError.protocolViolation(
                    "independent_readback_refresh: tool returned isError")
            }
        }
        let readID = nextRequestID
        nextRequestID += 1
        return try read(readID)
    }

    /// Inventory accepts Arrange track ids, not Mixer strip ordinals. Only a current native track
    /// read grants that scan range; project-file placeholders and duplicate ids cannot safely
    /// address the live surface.
    static func validatedPluginInventoryTrackIndices(from tracksData: Data) -> [Int]? {
        guard let envelope = try? JSONSerialization.jsonObject(with: tracksData) as? [String: Any],
              envelope["source"] as? String == "ax_live",
              envelope["readable"] as? Bool == true,
              let tracks = envelope["data"] as? [[String: Any]] else { return nil }
        var ids: [Int] = []
        for track in tracks {
            guard let id = track["id"] as? Int, id >= 0,
                  let reference = track["track_ref"] as? String,
                  reference.hasPrefix("trk_"), reference.count > 4 else { return nil }
            ids.append(id)
        }
        guard Set(ids).count == ids.count else { return nil }
        return ids.sorted()
    }

    static func pluginInventoryTrackIndices(from tracksData: Data) -> [Int] {
        validatedPluginInventoryTrackIndices(from: tracksData) ?? []
    }

    private static func pluginParameterIsReadable(_ parameter: StockPluginParameterMetadata) -> Bool {
        if parameter.readbackMethod == "ax_slider_axvalue" {
            return parameter.axDescription != nil
        }
        if parameter.readbackMethod == "ax_controls_view_checkbox_value" {
            return parameter.controlsViewControlRole == "AXCheckBox"
                && parameter.controlsViewRowLabel != nil
        }
        return ControlsViewParameterReader.kind(for: parameter) != nil
    }

    private static func pluginParameterIsPlanReadable(_ parameter: StockPluginParameterMetadata) -> Bool {
        let directSlider = parameter.readbackMethod == "ax_slider_axvalue"
            && parameter.axDescription != nil
        let controlsViewSlider = parameter.readbackMethod == "ax_controls_view_slider_display"
            && parameter.controlsViewControlRole == "AXSlider"
            && parameter.controlsViewRowLabel != nil
        let checkbox = parameter.readbackMethod == "ax_controls_view_checkbox_value"
            && parameter.controlsViewControlRole == "AXCheckBox"
            && parameter.controlsViewRowLabel != nil
        return (directSlider || controlsViewSlider || checkbox)
            && parameter.unit != nil
            && (parameter.readbackUnit ?? parameter.unit) == parameter.unit
    }

    private static func qualificationPlanValue(for parameter: StockPluginParameterMetadata) -> Any? {
        if parameter.unit == "boolean" { return false }
        guard let range = parameter.valueRange,
              range.min.isFinite, range.max.isFinite, range.min <= range.max else { return nil }
        let value = range.defaultValue ?? (range.min + (range.max - range.min) / 2)
        return value.isFinite && value >= range.min && value <= range.max ? value : nil
    }

    static func probeParams(
        for spec: OperationSpec,
        traceID: String,
        sessionSnapshotID: String? = nil,
        preparedReadParams: [OperationID: [String: Any]] = [:]
    ) -> [String: Any] {
        if spec.mutability == .mutating {
            return ["__adr001b_no_write_probe": true]
        }
        if let prepared = preparedReadParams[spec.id] {
            return prepared
        }
        switch spec.id {
        case .systemListRecentTraces:
            return ["limit": 10]
        case .systemGetTrace:
            return ["trace_id": traceID]
        case .systemClearTraces:
            return ["confirmed": true]
        case .systemHelp:
            return ["category": "system"]
        case .systemSagaPreflight:
            return ["idempotency_key": Self.sagaProbeIdempotencyKey, "steps": []]
        case .systemSagaStatus:
            return ["idempotency_key": Self.sagaProbeIdempotencyKey]

        // #373 Phase A established the semantic oracle surface. These probes provide documented,
        // deterministic inputs without weakening any operation's validation.
        case .tracksResolvePath:
            // A LIBRARY path classifier, not a filesystem one. Its oracle accepts either contract:
            // a hit must name `matchedPath` and classify the node, a miss must say why. This path
            // is a deterministic MISS, chosen on purpose -- a hit depends on what patches the
            // machine happens to have installed, and a gate whose result varies by host is not a
            // gate. The limitation is real and stated: the HIT branch stays unexercised here, and
            // covering it needs a fixture library rather than a different string.
            return ["path": "__qualification_probe__/definitely-absent"]
        case .audioAnalyzeFile:
            // The oracle requires `verification.status ∈ {pass, warn}` -- a `fail` arrives with
            // isError and is classified before the oracle runs, so accepting it could only launder
            // a failed analysis into a semantic pass. That means a REAL, analysable file.
            //
            // A macOS system sound rather than a committed fixture, and the trade is deliberate:
            // a repo fixture is repo-controlled but the binary has no way to locate it at run time,
            // which would need a new option threaded through the transport. This file is externally
            // owned, which is the weaker guarantee -- but if it ever disappears, `analyze_file`
            // returns its typed refusal and the case defers exactly as it does today. The downside
            // is the current state, so this cannot regress anything.
            //
            // Measured: 1.502 s, 48 kHz, `verification.status == "pass"`.
            return ["path": Self.qualificationAudioProbePath]
        case .audioAnalyzeSpectrum:
            // The spectral commands share the same documented non-empty audio path precondition
            // as `analyze_file`. Reusing the measured system sound exercises the real analysis
            // path; omitting it merely tests that the dispatcher refuses missing input.
            return ["path": Self.qualificationAudioProbePath]
        case .audioCompareSpectra:
            // Same-file comparison exercises the shipped reader without editing either input.
            // This supplies missing inputs; the shape-only oracle gains no numerical authority.
            return ["before_path": Self.qualificationAudioProbePath,
                    "after_path": Self.qualificationAudioProbePath]
        case .audioRecommendEQ:
            // Ping's measured level confidence is 0.538. Its default 0.6 recommendation threshold
            // correctly returns the safe `level_below_minimum` branch, but this probe needs to
            // exercise the recommendation branch and its semantic constraints. 0.5 is still a
            // caller-supplied, finite documented value, not a change to the operation's policy.
            return ["path": Self.qualificationAudioProbePath, "minimum_level": 0.5]
        case .projectExportPlan:
            // A DRY RUN whose oracle allows `status ∈ {planned, degraded}`. An absent project is
            // honestly `degraded` and still returns a complete, schema-valid manifest, so the probe
            // needs no fixture project and no path that varies by host. `output_root` is required
            // too -- omitting it refuses with `output_root must be an absolute local path`, which
            // is why supplying only `project` still failed.
            return [
                "project": "/__qualification_probe__/absent.logicx",
                "output_root": "/tmp",
            ]
        case .projectPlanSessionRepair:
            // #966. The planner reads a RETAINED inspection, so `{}` could only ever be refused.
            // `sessionSnapshotID` is the handle this subprocess's own `inspect_session` returned
            // just before, and the empty approved policy asks for no change: the read-only draft
            // path runs end to end. With no handle the probe sends none and the refusal stays
            // the failure it is.
            guard let sessionSnapshotID else { return [:] }
            return [
                "snapshot_id": sessionSnapshotID,
                "policy": [
                    "schema": ProjectSessionAudit.intentPolicySchema,
                    "targets": [] as [Any], "roles": [] as [Any], "outputs": [] as [Any],
                ] as [String: Any],
            ]
        case .pluginsGetInventory:
            // Track 0 exists whenever a project does: `project.new` reports
            // `mandatory_track_created`. On a projectless Logic this still returns a typed refusal
            // rather than the bare `invalid_params` an absent parameter produced.
            return ["track": 0]

        default:
            return [:]
        }
    }

    static func coreMIDIPortReadback() throws -> Data {
        struct Listing: Encodable {
            let sources: [String]
            let destinations: [String]
        }

        func endpointName(_ endpoint: MIDIEndpointRef, kind: String, index: Int) throws -> String {
            guard endpoint != 0 else {
                throw QualificationTransportError.protocolViolation(
                    "host_coremidi_readback: missing \(kind) endpoint at index \(index)"
                )
            }
            for property in [kMIDIPropertyDisplayName, kMIDIPropertyName] {
                var value: Unmanaged<CFString>?
                if MIDIObjectGetStringProperty(endpoint, property, &value) == noErr,
                   let name = value?.takeRetainedValue() as String? {
                    return name
                }
            }
            throw QualificationTransportError.protocolViolation(
                "host_coremidi_readback: unnamed \(kind) endpoint at index \(index)"
            )
        }

        func endpointNames(
            count: Int,
            kind: String,
            getter: (Int) -> MIDIEndpointRef
        ) throws -> [String] {
            try (0..<count).map { index in
                try endpointName(getter(index), kind: kind, index: index)
            }
        }

        let listing = Listing(
            sources: try endpointNames(
                count: MIDIGetNumberOfSources(), kind: "source", getter: MIDIGetSource
            ),
            destinations: try endpointNames(
                count: MIDIGetNumberOfDestinations(), kind: "destination",
                getter: MIDIGetDestination
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(listing)
    }

    static func readbackSource(for spec: OperationSpec) -> String {
        // These existing recipes mutate and restore the exact track scalar. Their final
        // independent read must use that same surface, not require a separately visible Mixer.
        if valueRestoreReadbackField[spec.id] != nil { return "logic://tracks" }
        switch spec.tool {
        case .logicTransport:
            return "logic://transport/state"
        case .logicMixer, .logicPlugins:
            return "logic://mixer"
        case .logicNavigate:
            return "logic://markers"
        case .logicEdit:
            return "logic://tracks"
        case .logicProject:
            switch spec.id {
            case .projectGetRegions:
                return "logic://tracks"
            case .projectAudit:
                return "logic://project/audit"
            case .projectCleanupPlan, .projectCleanupApply:
                return "logic://project/cleanup-plan"
            default:
                return "logic://project/info"
            }
        case .logicMidi:
            if spec.id == .midiListPorts {
                return QualificationSemanticReadbackValidator.coreMIDIPortReadbackSource
            }
            return "logic://midi/ports"
        case .logicTracks:
            switch spec.id {
            case .tracksListLibrary:
                return QualificationSemanticReadbackValidator.libraryPanelReadbackSource
            case .tracksScanLibrary, .tracksResolvePath, .tracksScanPluginPresets:
                return "logic://library/inventory"
            default:
                return "logic://tracks"
            }
        case .logicAudio:
            return "logic://system/health"
        case .logicSystem:
            switch spec.id {
            case .systemListRecentTraces, .systemGetTrace, .systemClearTraces, .systemHelp:
                return "logic://system/operations"
            default:
                return "logic://system/health"
            }
        }
    }

    static func observedFailureReason(
        from error: Error,
        during observation: String
    ) -> String {
        if let transportError = error as? QualificationTransportError,
           case .requestTimeout = transportError {
            return "\(observation) timeout: \(error)"
        }
        return "\(observation) failed: \(error)"
    }

    func resourceReadback(
        _ session: QualificationSubprocessSession,
        id: Int,
        uri: String,
        phase: String
    ) throws -> Data {
        let result: ResourceReadResult = try session.request(
            id: id,
            method: "resources/read",
            params: ["uri": uri],
            phase: phase
        )
        guard let content = result.contents.first,
              content.uri == uri,
              let text = content.text else {
            throw QualificationTransportError.protocolViolation("\(phase): missing readback content")
        }
        return Data(text.utf8)
    }

    func negative(
        _ session: QualificationSubprocessSession,
        id: Int
    ) throws -> (toolIsError: Bool, body: NegativeResult, text: String) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_tracks",
                "arguments": [
                    "command": "rename",
                    "params": ["track_index": 1],
                ],
            ],
            phase: "negative_failclosed"
        )
        let text = try result.text(phase: "negative_failclosed")
        let body: NegativeResult = try Self.decodeInner(
            text,
            phase: "negative_failclosed"
        )
        return (result.isError == true, body, text)
    }

    /// Seed a saga journal record under the key `probeParams` hands `system.saga_status`.
    ///
    /// Deliberately tolerant: the qualification must not fail because a SETUP step did not take.
    /// If this does not land, `saga_status` reports `element_not_found` and defers exactly as it
    /// did before -- the downside is the previous behaviour, so the seed cannot make things worse.
    @discardableResult
    func sagaSeed(
        _ session: QualificationSubprocessSession,
        id: Int
    ) throws -> Bool {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": [
                    "command": "saga_execute",
                    "params": [
                        "idempotency_key": Self.sagaProbeIdempotencyKey,
                        "steps": [] as [Any],
                    ],
                ],
            ],
            phase: "saga_seed"
        )
        return result.isError == true
    }

    func traceSeed(
        _ session: QualificationSubprocessSession,
        id: Int
    ) throws -> (toolIsError: Bool, body: OperationProbeResult, text: String) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": [
                    "command": "saga_execute",
                    "params": [:] as [String: Any],
                ],
            ],
            phase: "trace_seed"
        )
        let text = try result.text(phase: "trace_seed")
        let body: OperationProbeResult = try Self.decodeInner(text, phase: "trace_seed")
        guard result.isError == true,
              body.state == "C",
              body.error == "invalid_params",
              body.writeAttempted == false else {
            throw QualificationTransportError.protocolViolation(
                "trace_seed: expected typed zero-write refusal"
            )
        }
        return (true, body, text)
    }

    /// #966: the handle the planner probe plans over, taken from request-owned `inspect_session`
    /// in the same subprocess. Only the handle is read; whether it was retained is the planner's
    /// to answer, and its refusal for an unsaved project is classified where refusals are.
    func sessionInspectionSeed(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        purpose: SessionInspectionSeedPurpose
    ) throws -> String {
        try sessionInspectionSeedPayload(session, startingAt: id, purpose: purpose).snapshotID
    }

    func sessionInspectionSeedPayload(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        purpose: SessionInspectionSeedPurpose
    ) throws -> SessionInspectionSeedPayload {
        guard let inspect = OperationRegistry.specs.first(where: { $0.id == .projectInspectSession }) else {
            throw QualificationTransportError.protocolViolation("session_inspection_seed: no inspect_session operation")
        }
        let requestParams = Self.sessionInspectionSeedRequestParams(for: purpose)
        return try Self.sessionInspectionSeedPayload(startingAt: id, purpose: purpose) { requestID, phase in
            let result: ToolCallResult = try session.request(
                id: requestID,
                method: "tools/call",
                params: [
                    "name": inspect.tool.rawValue,
                    "arguments": [
                        "command": inspect.command,
                        "params": requestParams,
                    ],
                ],
                phase: phase,
                timeout: Self.operationRequestTimeout(for: inspect)
            )
            return (result.isError, try result.text(phase: phase))
        }
    }

    /// Startup feedback can invalidate a genuine fresh read's strict cache boundary.
    /// Keep that refusal and perform at most one entirely new read; never accept its
    /// old rows, refresh the boundary around them, navigate, or retry a write/timeout.
    static func sessionInspectionSeed(
        startingAt id: Int,
        purpose: SessionInspectionSeedPurpose,
        request: (Int, String) throws -> (isError: Bool?, text: String)
    ) throws -> String {
        try sessionInspectionSeedPayload(startingAt: id, purpose: purpose, request: request).snapshotID
    }

    static func sessionInspectionSeedPayload(
        startingAt id: Int,
        purpose: SessionInspectionSeedPurpose,
        request: (Int, String) throws -> (isError: Bool?, text: String)
    ) throws -> SessionInspectionSeedPayload {
        for attempt in 0..<purpose.maximumAttempts {
            let phase = attempt == 0 ? "session_inspection_seed" : "session_inspection_seed_retry"
            let result = try request(id + attempt, phase)
            if result.isError == true {
                if attempt == 0,
                   let refusal = try? JSONDecoder().decode(SessionSeedReadRefusal.self, from: Data(result.text.utf8)),
                   refusal.permitsFreshReadRetry { continue }
                throw QualificationTransportError.protocolViolation("\(phase): tool returned isError")
            }
            let seed: SessionInspectionSeed = try decodeInner(result.text, phase: phase)
            guard !seed.snapshotID.isEmpty else {
                throw QualificationTransportError.protocolViolation("\(phase): empty snapshot_id")
            }
            return SessionInspectionSeedPayload(
                snapshotID: seed.snapshotID,
                responseData: Data(result.text.utf8)
            )
        }
        throw QualificationTransportError.protocolViolation("session_inspection_seed: no successful fresh read")
    }

    private struct SessionSeedReadRefusal: Decodable {
        struct Effects: Decodable {
            let attempted: [String]
            let changed: [String]
            let navigationPerformed: Bool
            let restoration: String
            let reason: String?
            enum CodingKeys: String, CodingKey {
                case attempted, changed, restoration, reason
                case navigationPerformed = "navigation_performed"
            }
        }
        let state: String
        let success: Bool
        let error: String
        let writeAttempted: Bool
        let navigationPerformed: Bool
        let effects: Effects
        let snapshotID: String?
        enum CodingKeys: String, CodingKey {
            case state, success, error
            case writeAttempted = "write_attempted"
            case navigationPerformed = "navigation_performed"
            case effects = "ui_effects"
            case snapshotID = "snapshot_id"
        }
        var permitsFreshReadRetry: Bool {
            state == "C" && !success && error == "readback_unavailable"
                && !writeAttempted && !navigationPerformed && snapshotID == nil
                && effects.attempted.isEmpty && effects.changed.isEmpty
                && !effects.navigationPerformed && effects.restoration == "not_applicable"
                && effects.reason == nil
        }
    }

    private struct SessionInspectionSeed: Decodable {
        let snapshotID: String
        enum CodingKeys: String, CodingKey { case snapshotID = "snapshot_id" }
    }

    struct SessionInspectionSeedPayload: Sendable {
        let snapshotID: String
        let responseData: Data
    }

    static func decodeInner<Value: Decodable>(
        _ text: String,
        phase: String
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        } catch {
            throw QualificationTransportError.protocolViolation("\(phase): invalid typed JSON")
        }
    }

    static func stableHealthData(_ text: String, phase: String) throws -> Data {
        guard var object = try jsonObject(text, phase: phase) as? [String: Any] else {
            throw QualificationTransportError.protocolViolation("\(phase): health is not an object")
        }
        object.removeValue(forKey: "process")
        if var cache = object["cache"] as? [String: Any] {
            cache.removeValue(forKey: "transport_age_sec")
            object["cache"] = cache
        }
        if var mcu = object["mcu"] as? [String: Any] {
            mcu.removeValue(forKey: "last_feedback_at")
            mcu.removeValue(forKey: "feedback_stale")
            object["mcu"] = mcu
        }
        if let channels = object["channels"] as? [[String: Any]] {
            object["channels"] = channels.map { channel in
                var stable = channel
                stable.removeValue(forKey: "latency_ms")
                return stable
            }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func stableCatalogData(_ text: String, phase: String) throws -> Data {
        guard var object = try jsonObject(text, phase: phase) as? [String: Any] else {
            throw QualificationTransportError.protocolViolation("\(phase): catalog is not an object")
        }
        object.removeValue(forKey: "generated_at")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func jsonObject(_ text: String, phase: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: Data(text.utf8))
        } catch {
            throw QualificationTransportError.protocolViolation("\(phase): invalid JSON")
        }
    }
}
