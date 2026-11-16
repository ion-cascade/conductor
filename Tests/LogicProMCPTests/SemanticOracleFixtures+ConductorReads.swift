import Foundation
@testable import LogicProMCP

extension SemanticOracleFixtures {
    static let expectedReadDeferralIDs: Set<OperationID> = [
        .midiListPorts, .tracksListLibrary, .midiReadSelectedRegionEvents, .midiGetRegionNotes,
        .mixerGetOutputVerified, .mixerGetSendDestinationVerified, .mixerGetInputBusVerified,
        .mixerGetSendBypassVerified, .pluginsPlanParameterChanges, .pluginsGetHostParameterManifest,
        .pluginsGetParamVerified, .pluginsGetChannelEQStateVerified, .pluginsGetGainAutomation,
        .pluginsGetPresetVerified, .pluginsGetSidechainVerified, .projectGetPatternStep, .projectScanRegions,
        .tracksGetPanAutomation, .tracksGetVolumeAutomation, .projectGetRegionSmartTempo, .projectGetRegionGain, .projectGetRegionFade,
    ]

    static let conductorReads: [OperationID: SemanticOracleFixture] = [
        .pluginsGetPresetVerified: .init(
            response: #"{"operation":"logic_plugins.get_preset_verified","state":"A","success":true,"verified":true,"write_attempted":false,"plugin":"Compressor","before":"Piano","observed_preset":"Piano","changed":false,"verify_source":"ax_compressor_setting"}"#,
            readback: #"{"independent_readback":false}"#
        ),
        .pluginsGetSidechainVerified: .init(
            response: #"{"operation":"logic_plugins.get_sidechain_verified","state":"A","success":true,"verified":true,"write_attempted":false,"source":"Internal","before":"Internal","choices":["Internal"],"changed":false,"editor_restored":true,"verify_source":"ax_compressor_popup_and_checked_menu"}"#,
            readback: #"{"independent_readback":false}"#
        ),
        .pluginsGetGainAutomation: .init(
            response: #"{"operation":"plugin.get_gain_automation","state":"A","success":true,"verified":true,"write_attempted":false,"lane":"gain","unit":"logic_plugin_automation_value","verify_source":"ax_automation_event_list","track":0,"insert":3,"points":[{"position":"1.1.1.1","value":91}]}"#,
            readback: #"{"independent_readback":false}"#
        ),
        .midiGetRegionNotes: .init(
            response: #"{"operation":"midi.get_region_notes","state":"A","success":true,"verified":true,"write_attempted":false,"target_ref":"reg_fixture","region":"MIDI fixture","verify_source":"logic13_ax_event_list","event_count":2,"notes":[{"channel":1,"pitch":60,"velocity":94,"position":"1.1.1.1","length":"0.0.3.0"}]}"#,
            readback: #"{"independent_readback":false}"#
        ),
        .projectGetPatternStep: .init(
            response: #"{"operation":"project.get_pattern_step","state":"A","success":true,"verified":true,"write_attempted":false,"address":{"project_path":"/tmp/Pattern.logicx","region_name":"Pattern","region_location":"1.1.1.1","track":"Drums","row":"Kick","step":2},"enabled":true,"velocity":64,"visible_grid":[{"row":"Kick","steps":[1,2]}]}"#,
            readback: #"{"independent_readback":false}"#
        ),
        .projectGetRegionSmartTempo: .init(
            response: #"{"operation":"project.get_region_smart_tempo","state":"A","success":true,"verified":true,"write_attempted":false,"target_ref":"reg_fixture","region":"Pulse","tempo_bpm":120.0,"first_downbeat_source_sample":8820,"verify_source":"logic13_smart_tempo_editor","editor_close_observed":true}"#,
            readback: #"{"independent_readback":false}"#
        ),
        .projectGetRegionGain: .init(
            response: #"{"operation":"project.get_region_gain","state":"A","success":true,"verified":true,"write_attempted":false,"target_ref":"reg_fixture","observed_gain_db":-6.0,"verify_source":"ax_region_inspector"}"#,
            readback: #"{"independent_readback":false}"#
        ),
        .projectGetRegionFade: .init(
            response: #"{"operation":"project.get_region_fade","state":"A","success":true,"verified":true,"write_attempted":false,"target_ref":"reg_fixture","edge":"out","observed_time_ms":500,"verify_source":"ax_region_inspector"}"#,
            readback: #"{"independent_readback":false}"#
        ),
        .projectScanRegions: .init(
            response: #"{"scope":"sampled_arrange_viewports","complete":false,"restoration":"restored","sampled_pages":[{"horizontal":0,"vertical":0}],"reasons":["sampled_viewports"],"regions":[]}"#,
            readback: #"{"independent_readback":false}"#
        ),
        .tracksGetPanAutomation: automationRead(lane: "pan", unit: "logic_pan_value"),
        .tracksGetVolumeAutomation: automationRead(lane: "volume", unit: "logic_fader_value"),
        .projectExportStatus: .init(
            response: #"{"schema":"logic_pro_mcp_delivery_status.v1","operation":"project.export_status","state":"A","success":true,"verified":true,"write_attempted":false,"delivery_id":"57074428-E625-438B-BC7D-E7FE8766E313","directory":"/tmp/delivery","project_path":"/tmp/Qualification.logicx","project_status":"verified","settings_status":"not_compared","status":"complete","resume_available":false,"settings":{"stems":{"includeAudioTail":false}},"outputs":[{"kind":"stem","track_index":0,"track_name":"Tone","path":"/tmp/delivery/Tone.wav","sha256":"synthetic-digest","sample_rate":48000,"frame_count":480,"status":"verified"}]}"#,
            readback: #"{"evidence_kind":"owned_export_status_fixture.v1","delivery_id":"57074428-E625-438B-BC7D-E7FE8766E313","directory":"/tmp/delivery","project_path":"/tmp/Qualification.logicx","settings":{"stems":{"includeAudioTail":false}},"outputs":[{"kind":"stem","track_index":0,"track_name":"Tone","path":"/tmp/delivery/Tone.wav","sha256":"synthetic-digest","sample_rate":48000,"frame_count":480,"status":"verified"}]}"#
        ),
    ]

    private static func automationRead(lane: String, unit: String) -> SemanticOracleFixture {
        .init(response: """
            {"operation":"track.get_\(lane)_automation","state":"A","success":true,"verified":true,"write_attempted":false,"lane":"\(lane)","unit":"\(unit)","position_format":"bar.beat.division.tick","verify_source":"ax_automation_event_list","track":0,"points":[{"position":"1.1.1.1","value":64}],"selected_positions":[]}
            """, readback: #"{"independent_readback":false}"#)
    }
}
