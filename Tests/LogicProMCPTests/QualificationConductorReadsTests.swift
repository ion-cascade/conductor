import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Conductor read qualification")
struct QualificationConductorReadsTests {
    @Test func exportStatusMatchesOwnedFilesAndRejectsWrongEvidence() throws {
        let fixture = try QualificationExportStatusProbe()
        let params = try fixture.params.mapValues { value in
            Value.string(try #require(value as? String))
        }
        let result = ProjectDispatcher.deliveryStatus(params: params)
        let payload = Data(sharedToolText(result).utf8)
        let witness = try fixture.readback()
        let source = QualificationExportStatusProbe.source

        #expect(result.isError != true)
        #expect(validateExport(payload, witness, source: source) == true)
        #expect(validateExport(payload, witness, source: "logic://project/info") == false)
        #expect(validateExport(payload, payload, source: source) == false)
        let spec = try #require(OperationRegistry.specs.first { $0.id == .projectExportStatus })
        let oracle = try #require(SemanticOracleTable.byOperationID[spec.id])
        let semanticPolicy = QualificationSemanticPolicy(kind: .declarative, strength: oracle.strength,
            constraints: oracle.constraints, independentlyCreditable: true)
        #expect(semanticPolicy.evaluate(operationID: spec.id.rawValue, responseData: payload,
            readbackData: witness, readbackSource: source))
        #expect(!semanticPolicy.evaluate(operationID: spec.id.rawValue, responseData: payload,
            readbackData: witness, readbackSource: "logic://project/info"))

        let otherFixture = try QualificationExportStatusProbe()
        #expect(validateExport(payload, try otherFixture.readback(), source: source) == false)

        var staleParams = params
        staleParams["delivery_id"] = .string(try #require(otherFixture.params["delivery_id"] as? String))
        let stale = ProjectDispatcher.deliveryStatus(params: staleParams)
        #expect(stale.isError == true)
        #expect(validateExport(Data(sharedToolText(stale).utf8), witness, source: source) == false)
    }

    @Test(arguments: ["audio", "receipt", "project", "missing_audio"])
    func independentWitnessWithholdsCreditAfterFixtureChanges(path: String) throws {
        let fixture = try QualificationExportStatusProbe()
        let params = try fixture.params.mapValues { Value.string(try #require($0 as? String)) }
        let witness = try fixture.readback()
        let document = try #require(JSONInspector.parse(witness) as? [String: Any])
        let directory = try #require(document["directory"] as? String)
        let project = try #require(document["project_path"] as? String)
        let output = try #require((document["outputs"] as? [[String: Any]])?.first?["path"] as? String)

        switch path {
        case "audio":
            let url = URL(fileURLWithPath: output)
            var bytes = try Data(contentsOf: url)
            bytes[bytes.index(before: bytes.endIndex)] ^= 1
            try bytes.write(to: url, options: .atomic)
        case "receipt":
            try Data("{}".utf8).write(to: URL(fileURLWithPath: directory + "/receipt.json"), options: .atomic)
        case "project":
            try Data("changed".utf8).write(to: URL(fileURLWithPath: project + "/Alternatives/000/ProjectData"),
                options: .atomic)
        case "missing_audio":
            try FileManager.default.removeItem(atPath: output)
        default:
            Issue.record("unknown fixture mutation")
        }

        #expect(throws: (any Error).self) { try fixture.readback() }
        let result = ProjectDispatcher.deliveryStatus(params: params)
        #expect(validateExport(Data(sharedToolText(result).utf8), witness,
            source: QualificationExportStatusProbe.source) == false)
    }

    @Test(arguments: [
        OperationID.pluginsGetPresetVerified, .pluginsGetSidechainVerified,
        .projectGetPatternStep, .projectScanRegions, .tracksGetPanAutomation, .tracksGetVolumeAutomation,
        .projectGetRegionGain, .projectGetRegionFade, .midiGetRegionNotes, .pluginsGetGainAutomation,
        .projectCapturePatternGrid, .projectReadLiveLoops, .projectReadScore, .projectGetChordTrack, .projectGetSessionPlayer, .projectSearchBrowserPatches,
    ])
    func receiptOnlyReadWithholdsCreditAndRejectsMalformedResponse(id: OperationID) throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == id })
        let fixture = try #require(SemanticOracleFixtures.byOperationID[id])
        func result(_ body: Data, readback: Data, refused: Bool = false) -> QualificationOperationResult {
            .init(operationID: id.rawValue, tool: spec.tool.rawValue, command: spec.command, mutability: .readOnly,
                requestID: "response", responseData: body, isError: refused, state: refused ? "C" : nil,
                error: refused ? "readback_unavailable" : nil, hint: nil, writeAttempted: false,
                readbackSource: QualificationSemanticReadbackValidator.responseOnlySource,
                readbackRequestID: "record", readbackData: readback, verification: spec.verification,
                deadline: spec.deadline, failureReason: nil)
        }
        let record = QualificationSemanticReadbackValidator.responseOnlyRecord
        let smoke = result(fixture.responseData, readback: record)
        #expect(smoke.status == .protocolSmoke)
        #expect(!smoke.verified)
        #expect(smoke.readback?.verified == false)
        #expect(smoke.deferral?.code == .semanticValidatorUnavailable)
        let echoed = result(fixture.responseData, readback: fixture.responseData)
        #expect(!echoed.verified)
        let malformed = result(Data("{}".utf8), readback: record)
        #expect(malformed.status == .notQualified)
        #expect(!malformed.verified)
        let refusal = result(Data(#"{"state":"C","write_attempted":false}"#.utf8), readback: record, refused: true)
        #expect(refusal.status == .notQualified)
    }

    private func validateExport(_ payload: Data, _ witness: Data, source: String) -> Bool? {
        QualificationSemanticReadbackValidator.validate(operationID: OperationID.projectExportStatus.rawValue,
            responseData: payload, readbackData: witness, readbackSource: source)
    }
}
