import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Test func explicitPCMSettingsDetermineThePlannedExtensionAndRunIdentity() throws {
    let project = try makeExportPlannerProject()
    let output = try makeExportPlannerDirectory()
    defer {
        try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: output)
    }
    let args: [String: Value] = [
        "projects": .array([.string(project.path)]), "output_root": .string(output.path),
        "artifacts": .array([.string("bounce")]),
    ]
    let settings: [String: Value] = ["format": .string("aiff"), "sample_rate": .int(48_000),
                                     "bit_depth": .int(16), "include_audio_tail": .bool(true)]
    let standard = try ProjectExportPlanner.plan(params: args)
    let explicit = try ProjectExportPlanner.plan(params: args.merging(
        ["bounce_settings": .object(settings)], uniquingKeysWith: { _, incoming in incoming }))
    let artifact = try #require(explicit.projects.first?.expectedArtifacts.first)
    #expect(artifact.path.hasSuffix(".aif"))
    #expect(artifact.bounceSettings?.sampleRate == 48_000)
    #expect(artifact.bounceSettings?.bitDepth == 16)
    #expect(artifact.bounceSettings?.includeAudioTail == true)
    #expect(standard.runID != explicit.runID)
}

@Test func nativeDeliveryProfilesRejectUnsupportedOrAmbiguousInputs() throws {
    #expect(throws: ExportPlanError.self) {
        try ProjectPCMBounceSettings.parse(
            .object(["format": .string("wav"), "sample_rate": .int(48_000), "bit_depth": .int(20)]),
            artifacts: ["bounce"])
    }
    #expect(throws: ExportPlanError.self) {
        try ProjectAlignedStemSettings.parse(.object(["include_audio_tail": .string("yes")]), artifacts: ["stem"])
    }
    #expect(ProjectAlignedStemSettings.namesQualify([
        .init(index: 0, name: "Bass 1"), .init(index: 1, name: "Piano-2"),
    ]))
    #expect(!ProjectAlignedStemSettings.namesQualify([
        .init(index: 0, name: "Bass"), .init(index: 1, name: "bass"),
    ]))
}
