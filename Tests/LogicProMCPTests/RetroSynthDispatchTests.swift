import Foundation
import MCP
import Testing
@testable import LogicProMCP

@MainActor
struct RetroSynthDispatchTests {
    private func request(_ command: String, _ extra: [String: Value], gate: VerifiedOpGate) async throws -> [String: Any] {
        let params: [String: Value] = ["project_ref": "prj_fixture", "target_ref": "trk_fixture"]
        let result = await PluginsDispatcher.retroSynth(command: command,
            params: params.merging(extra, uniquingKeysWith: { _, new in new }), cache: StateCache(),
            targetRegistry: nil, gate: gate, liveTrackNames: nil, traceID: nil)
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    @Test(arguments: [Value.bool(true), .string("0.5"), .double(0.505), .double(.infinity)])
    func invalidNumericValuesAreRejectedBeforeAnyNativeAcquisition(_ value: Value) async throws {
        let gate = VerifiedOpGate()
        #expect(gate.tryAcquire())
        defer { gate.release() }
        let body = try await request("set_retro_synth_parameter", [
            "instrument_ref": "rsy_fixture", "expected_snapshot": "snapshot", "param": "oscillator_mix",
            "unit": "normalized", "value": value,
        ], gate: gate)
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "invalid_params")
        #expect(body["write_attempted"] as? Bool == false)
    }

    @Test func factoryResetRequiresExplicitConsentBeforeAcquisition() async throws {
        let body = try await request("initialize_retro_synth", ["confirmed": .bool(false)], gate: VerifiedOpGate())
        #expect(body["state"] as? String == "C")
        #expect(body["write_attempted"] as? Bool == false)
    }

    @Test func concurrentReadCannotAcquireTheSharedEditor() async throws {
        let gate = VerifiedOpGate()
        #expect(gate.tryAcquire())
        defer { gate.release() }
        let body = try await request("get_retro_synth_state", [:], gate: gate)
        #expect(body["error"] as? String == "verified_op_in_progress")
        #expect(body["write_attempted"] as? Bool == false)
    }

    @Test func unresolvedProjectRetainsAnExplicitUnverifiedZeroWriteRefusal() async throws {
        let body = try await request("initialize_retro_synth", ["confirmed": .bool(true)], gate: VerifiedOpGate())
        #expect(body["state"] as? String == "C")
        #expect(body["verified"] as? Bool == false)
        #expect(body["write_attempted"] as? Bool == false)
        #expect(body["operation"] as? String == "plugin.initialize_retro_synth")
    }

    @Test func bareIndexCannotReplaceTheRequiredPhysicalReference() async throws {
        let result = await PluginsDispatcher.retroSynth(command: "get_retro_synth_state",
            params: ["project_ref": "prj_fixture", "index": .int(0)], cache: StateCache(),
            targetRegistry: nil, gate: VerifiedOpGate(), liveTrackNames: nil, traceID: nil)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "invalid_params")
        #expect(body["write_attempted"] as? Bool == false)
    }
}
