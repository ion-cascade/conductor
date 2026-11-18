extension SemanticOracleTable {
    static let conductorReceiptOnlyReadIDs: Set<OperationID> = [
        .pluginsGetRetroSynthState, .pluginsGetPresetVerified, .pluginsGetSidechainVerified, .projectGetPatternStep,
        .projectScanRegions, .projectGetRegionSmartTempo, .projectGetRegionGain, .projectGetRegionFade, .tracksGetPanAutomation, .tracksGetVolumeAutomation,
        .midiGetRegionNotes, .pluginsGetGainAutomation,
        .projectCapturePatternGrid, .projectGetChordTrack, .projectGetSessionPlayer, .projectSearchBrowserPatches,
    ]

    static let pluginsGetRetroSynthState = receiptOnlyRead(
        .pluginsGetRetroSynthState, operation: "plugin.get_retro_synth_state",
        constraints: [
            .valueEquals(key: "profile", expected: .string("logic13.retro_synth.analog.controls.v1")),
            .valueEquals(key: "parameter_count", expected: .number(22)),
            .valueEquals(key: "native_row_count", expected: .number(83)),
            .typedField(key: "instrument_ref", type: .string),
            .typedField(key: "snapshot_hash", type: .string),
            .booleanFlipped(keyA: "ui_restored", keyB: "editor_opened"),
            .valueEquals(key: "editor_retained", expected: .bool(true)),
            .valueEquals(key: "ui_policy_satisfied", expected: .bool(true)),
            .nonEmptyArray(key: "parameters"),
            .arrayElements(key: "parameters", constraints: [
                .typedField(key: "param", type: .string),
                .typedField(key: "unit", type: .string),
                .typedField(key: "native_display", type: .string),
            ]),
        ],
        reason: "The generic sweep has no independently bound Retro Synth instrument witness. The release fixture must verify native Controls rows, persistence and controlled renders."
    )

    static let pluginsGetPresetVerified = receiptOnlyRead(
        .pluginsGetPresetVerified, operation: "logic_plugins.get_preset_verified",
        constraints: [
            .valueEquals(key: "verify_source", expected: .string("ax_compressor_setting")),
            .typedField(key: "plugin", type: .string),
            .typedField(key: "observed_preset", type: .string),
            .fieldsEqual(keyA: "observed_preset", keyB: "before"),
            .valueEquals(key: "changed", expected: .bool(false)),
        ],
        reason: "The qualification harness has no independent observation of the selected preset on the referenced insert."
    )

    static let pluginsGetSidechainVerified = receiptOnlyRead(
        .pluginsGetSidechainVerified, operation: "logic_plugins.get_sidechain_verified",
        constraints: [
            .valueEquals(key: "verify_source", expected: .string("ax_compressor_popup_and_checked_menu")),
            .typedField(key: "source", type: .string),
            .fieldsEqual(keyA: "source", keyB: "before"),
            .nonEmptyArray(key: "choices"),
            .valueEquals(key: "changed", expected: .bool(false)),
            .valueEquals(key: "editor_restored", expected: .bool(true)),
        ],
        reason: "The returned popup and menu observations share the operation's editor acquisition. The qualification harness has no independent readback of the referenced insert's source."
    )

    static let pluginsGetGainAutomation = receiptOnlyRead(
        .pluginsGetGainAutomation, operation: "plugin.get_gain_automation",
        constraints: [
            .valueEquals(key: "verify_source", expected: .string("ax_automation_event_list")),
            .valueEquals(key: "lane", expected: .string("gain")),
            .arrayElements(key: "points", constraints: [
                .typedField(key: "position", type: .string),
                .numericRange(key: "value", min: 0, max: 127),
            ]),
        ],
        reason: "An independent Automation Event List capture is required for the referenced Gain insert."
    )

    static let midiGetRegionNotes = receiptOnlyRead(
        .midiGetRegionNotes, operation: "midi.get_region_notes",
        constraints: [
            .valueEquals(key: "verify_source", expected: .string("logic13_ax_event_list")),
            .typedField(key: "target_ref", type: .string),
            .typedField(key: "region", type: .string),
            .integerMinimum(key: "event_count", min: 0),
            .numericRange(key: "event_count", min: 0, max: 24),
            .arrayElements(key: "notes", constraints: [
                .integerMinimum(key: "channel", min: 1),
                .numericRange(key: "channel", min: 1, max: 16),
                .integerMinimum(key: "pitch", min: 0),
                .numericRange(key: "pitch", min: 0, max: 127),
                .integerMinimum(key: "velocity", min: 1),
                .numericRange(key: "velocity", min: 1, max: 127),
                .typedField(key: "position", type: .string),
                .typedField(key: "length", type: .string),
            ]),
        ],
        reason: "This generic run has no independently bound MIDI region and note inventory. The native release fixture verifies the Event List read against independently exported MIDI."
    )

    static let projectGetPatternStep = receiptOnlyRead(
        .projectGetPatternStep, operation: "project.get_pattern_step",
        constraints: [
            .typedField(key: "address.project_path", type: .string),
            .typedField(key: "address.region_name", type: .string),
            .typedField(key: "address.region_location", type: .string),
            .typedField(key: "address.track", type: .string),
            .typedField(key: "address.row", type: .string),
            .integerMinimum(key: "address.step", min: 1),
            .numericRange(key: "address.step", min: 1, max: 16),
            .typedField(key: "enabled", type: .bool),
            .integerMinimum(key: "velocity", min: 0),
            .numericRange(key: "velocity", min: 0, max: 127),
            .nonEmptyArray(key: "visible_grid"),
            .arrayElements(key: "visible_grid", constraints: [
                .typedField(key: "row", type: .string),
                .nonEmptyArray(key: "steps"),
            ]),
        ],
        reason: "Project info cannot independently identify the selected pattern cell or verify its enabled state and velocity."
    )

    static let projectCapturePatternGrid = receiptOnlyRead(
        .projectCapturePatternGrid, operation: "project.capture_pattern_grid",
        constraints: [
            .typedField(key: "address.project_path", type: .string),
            .typedField(key: "address.track", type: .string),
            .typedField(key: "address.region_name", type: .string),
            .typedField(key: "address.region_location", type: .string),
            .typedField(key: "grid_snapshot", type: .string),
            .nonEmptyArray(key: "cells"),
            .arrayElements(key: "cells", constraints: [
                .typedField(key: "row", type: .string),
                .integerMinimum(key: "step", min: 1),
                .numericRange(key: "step", min: 1, max: 16),
                .typedField(key: "enabled", type: .bool),
                .integerMinimum(key: "velocity", min: 1),
                .numericRange(key: "velocity", min: 1, max: 127),
            ]),
        ],
        reason: "The generic harness has no independent native drum-grid observation or selection-restoration witness."
    )

    static let projectReadScore = receiptOnlyRead(
        .projectReadScore, operation: "project.read_score",
        constraints: [
            .typedField(key: "native_score.project_path", type: .string),
            .typedField(key: "native_score.track_name", type: .string),
            .typedField(key: "native_score.region_name", type: .string),
            .typedField(key: "native_score.time_signature", type: .string),
            .integerMinimum(key: "native_score.rest_count", min: 0),
            .nonEmptyArray(key: "native_score.notes"),
            .arrayElements(key: "native_score.notes", constraints: [
                .typedField(key: "position", type: .string),
                .typedField(key: "pitch", type: .string),
            ]),
        ],
        reason: "The generic harness has no independent Score Editor observation."
    )

    static let projectReadLiveLoops = receiptOnlyRead(
        .projectReadLiveLoops, operation: "project.read_live_loops",
        constraints: [
            .typedField(key: "project_path", type: .string),
            .typedField(key: "quantize_start", type: .string),
            .typedField(key: "transport_playing", type: .bool),
            .typedField(key: "grid_snapshot", type: .string),
            .nonEmptyArray(key: "rows"),
            .arrayElements(key: "rows", constraints: [
                .typedField(key: "track", type: .string),
                .typedField(key: "activity", type: .string),
            ]),
            .nonEmptyArray(key: "cells"),
            .arrayElements(key: "cells", constraints: [
                .typedField(key: "cell_ref", type: .string),
                .typedField(key: "scene", type: .string),
                .typedField(key: "track", type: .string),
            ]),
        ],
        reason: "The generic harness has no independent Live Loops grid and activity observation."
    )

    static let projectGetChordTrack = receiptOnlyRead(
        .projectGetChordTrack, operation: "project.get_chord_track",
        constraints: [
            .typedField(key: "project_path", type: .string),
            .arrayElements(key: "events", constraints: [
                .typedField(key: "chord", type: .string),
                .integerMinimum(key: "start_bar", min: 1),
                .integerMinimum(key: "end_bar", min: 2),
                .integerMinimum(key: "duration_bars", min: 1),
            ]),
        ],
        reason: "The generic harness cannot independently inspect the Chord Track progression or musical boundaries."
    )

    static let projectGetSessionPlayer = receiptOnlyRead(
        .projectGetSessionPlayer, operation: "project.get_session_player",
        constraints: [
            .typedField(key: "address.project_path", type: .string),
            .typedField(key: "address.region_name", type: .string),
            .typedField(key: "address.region_location", type: .string),
            .typedField(key: "address.track", type: .string),
            .valueEquals(key: "player", expected: .string("Keyboard Player")),
            .enumMember(key: "chord_source", allowed: ["global", "region"]),
            .numericRange(key: "complexity", min: 0, max: 100),
            .numericRange(key: "intensity", min: 0, max: 100),
            .nonEmptyArray(key: "complexity_range"),
        ],
        reason: "The generic harness has no separate native observation of this selected region and its Pitch Source."
    )

    static let projectSearchBrowserPatches = receiptOnlyRead(
        .projectSearchBrowserPatches, operation: "project.search_browser_patches",
        constraints: [
            .typedField(key: "project_path", type: .string),
            .typedField(key: "track_name", type: .string),
            .integerMinimum(key: "track_index", min: 0),
            .typedField(key: "query", type: .string),
            .typedField(key: "visible_patches", type: .array),
        ],
        reason: "An independent observation of the active search filter and visible native Browser results is required."
    )

    static let projectGetRegionSmartTempo = receiptOnlyRead(
        .projectGetRegionSmartTempo, operation: "project.get_region_smart_tempo",
        constraints: [
            .typedField(key: "target_ref", type: .string),
            .typedField(key: "region", type: .string),
            .typedField(key: "tempo_bpm", type: .number),
            .integerMinimum(key: "first_downbeat_source_sample", min: 0),
            .valueEquals(key: "verify_source", expected: .string("logic13_smart_tempo_editor")),
            .valueEquals(key: "editor_close_observed", expected: .bool(true)),
        ],
        reason: "The automated harness has no separate native Smart Tempo Editor observation for this region."
    )

    static let projectGetRegionGain = receiptOnlyRead(
        .projectGetRegionGain, operation: "project.get_region_gain",
        constraints: [
            .typedField(key: "target_ref", type: .string),
            .typedField(key: "observed_gain_db", type: .number),
            .valueEquals(key: "verify_source", expected: .string("ax_region_inspector")),
        ],
        reason: "The qualification harness has no separate observation of the held audio region's Inspector gain."
    )

    static let projectGetRegionFade = receiptOnlyRead(
        .projectGetRegionFade, operation: "project.get_region_fade",
        constraints: [
            .typedField(key: "target_ref", type: .string),
            .typedField(key: "edge", type: .string),
            .typedField(key: "observed_time_ms", type: .number),
            .valueEquals(key: "verify_source", expected: .string("ax_region_inspector")),
        ],
        reason: "The qualification harness has no separate observation of the held audio region's Inspector fade."
    )

    static let projectScanRegions = OperationOracle(
        .projectScanRegions,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "scope", expected: .string("sampled_arrange_viewports")),
            .valueEquals(key: "complete", expected: .bool(false)),
            .valueEquals(key: "restoration", expected: .string("restored")),
            .typedField(key: "regions", type: .array),
            .nonEmptyArray(key: "sampled_pages"),
            .arrayElements(key: "sampled_pages", constraints: [
                .numericRange(key: "horizontal", min: 0, max: 1),
                .numericRange(key: "vertical", min: 0, max: 1),
            ]),
            .nonEmptyArray(key: "reasons"),
        ],
        independentReadbackDeferral: .init(code: .semanticValidatorUnavailable,
            detail: "The qualification harness has no independent inventory for the sampled viewports or witness of viewport restoration.")
    )

    static let tracksGetPanAutomation = trackAutomationRead(.tracksGetPanAutomation, lane: "pan", unit: "logic_pan_value")
    static let tracksGetVolumeAutomation = trackAutomationRead(.tracksGetVolumeAutomation, lane: "volume", unit: "logic_fader_value")

    static let projectExportStatus = OperationOracle(
        .projectExportStatus,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "schema", expected: .string("logic_pro_mcp_delivery_status.v1")),
            .valueEquals(key: "operation", expected: .string("project.export_status")),
            .valueEquals(key: "state", expected: .string("A")),
            .valueEquals(key: "success", expected: .bool(true)),
            .valueEquals(key: "verified", expected: .bool(true)),
            .valueEquals(key: "write_attempted", expected: .bool(false)),
            .valueEquals(key: "status", expected: .string("complete")),
            .valueEquals(key: "project_status", expected: .string("verified")),
            .valueEquals(key: "settings_status", expected: .string("not_compared")),
            .valueEquals(key: "resume_available", expected: .bool(false)),
            .typedField(key: "delivery_id", type: .string),
            .typedField(key: "directory", type: .string),
            .typedField(key: "project_path", type: .string),
            .typedField(key: "settings", type: .object),
            .nonEmptyArray(key: "outputs"),
            .crossCheck(responseKey: "delivery_id", readbackKey: "delivery_id"),
            .crossCheck(responseKey: "directory", readbackKey: "directory"),
            .crossCheck(responseKey: "project_path", readbackKey: "project_path"),
            .crossCheck(responseKey: "settings", readbackKey: "settings"),
            .crossCheck(responseKey: "outputs", readbackKey: "outputs"),
        ]
    )

    private static func receiptOnlyRead(
        _ id: OperationID, operation: String, constraints: [OracleConstraint], reason: String
    ) -> OperationOracle {
        OperationOracle(id, strength: .shapeAndDomain, constraints: [
            .valueEquals(key: "operation", expected: .string(operation)),
            .valueEquals(key: "state", expected: .string("A")),
            .valueEquals(key: "success", expected: .bool(true)),
            .valueEquals(key: "verified", expected: .bool(true)),
            .valueEquals(key: "write_attempted", expected: .bool(false)),
        ] + constraints, independentReadbackDeferral: .init(code: .semanticValidatorUnavailable, detail: reason))
    }

    private static func trackAutomationRead(_ id: OperationID, lane: String, unit: String) -> OperationOracle {
        receiptOnlyRead(id, operation: "track.get_\(lane)_automation", constraints: [
            .valueEquals(key: "lane", expected: .string(lane)),
            .valueEquals(key: "unit", expected: .string(unit)),
            .valueEquals(key: "position_format", expected: .string("bar.beat.division.tick")),
            .valueEquals(key: "verify_source", expected: .string("ax_automation_event_list")),
            .integerMinimum(key: "track", min: 0),
            .arrayElements(key: "points", constraints: [
                .typedField(key: "position", type: .string),
                .integerMinimum(key: "value", min: 0),
                .numericRange(key: "value", min: 0, max: 127),
            ]),
            .typedField(key: "selected_positions", type: .array),
        ], reason: "The qualification harness has no separate observation of the owned \(lane) event list. Track resource values do not describe automation points and their positions.")
    }
}
