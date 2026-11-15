extension SemanticOracleTable {
    static let conductorReceiptOnlyReadIDs: Set<OperationID> = [
        .pluginsGetPresetVerified, .pluginsGetSidechainVerified, .projectGetPatternStep,
        .projectScanRegions, .tracksGetPanAutomation, .tracksGetVolumeAutomation,
    ]

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
        ],
        reason: "Project info cannot independently identify the selected pattern cell or verify its enabled state and velocity."
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
            .nonEmptyArray(key: "reasons"),
        ],
        independentReadbackDeferral: .init(code: .semanticValidatorUnavailable,
            detail: "The qualification harness has no independent inventory for the sampled viewports or witness of viewport restoration.")
    )

    static let tracksGetPanAutomation = trackAutomationRead(.tracksGetPanAutomation, lane: "pan", unit: "logic_pan_value")
    static let tracksGetVolumeAutomation = trackAutomationRead(.tracksGetVolumeAutomation, lane: "volume", unit: "logic_fader_value")

    static let projectExportStatus = OperationOracle(
        .projectExportStatus,
        strength: .value,
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
            .typedField(key: "points", type: .array),
            .typedField(key: "selected_positions", type: .array),
        ], reason: "The qualification harness has no separate observation of the owned \(lane) event list. Track resource values do not describe automation points and their positions.")
    }
}
