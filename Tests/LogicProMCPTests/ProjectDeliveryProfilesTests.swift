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

@Test func explicitBounceRangeIsValidatedAndChangesThePlanIdentity() throws {
    let project = try makeExportPlannerProject()
    let output = try makeExportPlannerDirectory()
    defer {
        try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: output)
    }
    let settings: [String: Value] = ["format": .string("wav"), "sample_rate": .int(48_000), "bit_depth": .int(16)]
    let requested = ProjectBounceRange(start: "34.2.1.1", end: "36.1.1.1")
    let args: [String: Value] = [
        "projects": .array([.string(project.path)]), "output_root": .string(output.path),
        "artifacts": .array([.string("bounce")]), "bounce_settings": .object(settings),
    ]
    let defaultPlan = try ProjectExportPlanner.plan(params: args)
    var explicit = args
    var withRange = settings
    withRange["range"] = .object(["start": .string(requested.start), "end": .string(requested.end)])
    explicit["bounce_settings"] = .object(withRange)
    let explicitPlan = try ProjectExportPlanner.plan(params: explicit)
    #expect(defaultPlan.projects.first?.expectedArtifacts.first?.bounceSettings?.range == nil)
    #expect(explicitPlan.projects.first?.expectedArtifacts.first?.bounceSettings?.range == requested)
    #expect(explicitPlan.runID != defaultPlan.runID)

    let invalid: [[String: Value]] = [
        ["start": .string(requested.end), "end": .string(requested.start)],
        ["start": .string(requested.start), "end": .string(requested.start)],
        ["start": .string("034.2.1.1"), "end": .string(requested.end)],
        ["start": .string("34.2.1"), "end": .string(requested.end)],
        ["start": .string(requested.start)],
    ]
    for badRange in invalid {
        #expect(throws: ExportPlanError.self) {
            try ProjectBounceRange.parse(.object(badRange))
        }
    }
}
