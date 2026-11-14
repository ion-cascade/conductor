import Foundation
import MCP
import Testing
@testable import LogicProMCP

private final class WitnessClock: @unchecked Sendable { var instant: UInt64 = 0 }

@Suite("Conductor isolated export completion")
struct ConductorExportFileWitnessTests {
    @Test(arguments: [false, true], [false, true])
    func isolatedSingleSubjectRequiresVerifiedAudioAndPopulation(valid: Bool, populationVerified: Bool) async throws {
        let root = try makeExecTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeLogicxProject(in: root, named: "Single instrument")
        let output = root.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var options = fastOptions(identity: { project.path })
        options.verifyIsolatedSubjectBinding = { _, _ in populationVerified }
        options.driveIsolatedStemExport = { destination, count in
            #expect(count == 1)
            let witness = try! ProjectStemExportFileWitness(root: destination, expectedCount: count)
            let file = URL(fileURLWithPath: witness.directory).appendingPathComponent("Logic assigned.wav")
            if valid { try! writeToneWav(at: file) }
            else { try! Data("not audio".utf8).write(to: file) }
            return .init(outcome: .completed, directory: witness.directory, files: [file.path])
        }
        let run = await ProjectExportExecutor.run(
            params: ["project": .string(project.path), "output_root": .string(output.path), "artifact": .string("stem"), "confirmed": .bool(true)],
            router: await makeExportRouter(), resume: false, options: options,
            stemSubjects: .scanned(projectPath: project.path, subjects: [.init(index: 0, name: "Piano")])
        )
        let artifact = try #require(run.projects.first?.artifacts.first)
        #expect(artifact.verified == (valid && populationVerified))
        #expect(artifact.state == (valid && populationVerified ? "A" : "B"))
        if populationVerified { #expect(artifact.path.hasSuffix("Logic assigned.wav")) }
        #expect(artifact.subject?.name == "Piano")
    }

    @Test func newNamespaceDoesNotAcceptOldRootAudio() throws {
        let root = try makeExecTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeToneWav(at: root.appendingPathComponent("old.wav"))
        let witness = try ProjectStemExportFileWitness(root: root.path, expectedCount: 1)
        #expect(!witness.observe())
        #expect(witness.files.isEmpty)
        #expect(witness.directory != root.path)
    }

    @Test func stableCompleteAudioPassesAndGrowthResetsTheClock() throws {
        let root = try makeExecTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = WitnessClock()
        let witness = try ProjectStemExportFileWitness(root: root.path, expectedCount: 1, settleNanos: 10, now: { clock.instant })
        let file = URL(fileURLWithPath: witness.directory).appendingPathComponent("actual.wav")
        try writeToneWav(at: file)
        #expect(!witness.observe())
        clock.instant = 9
        #expect(!witness.observe())
        try writeToneWav(at: file, durationSeconds: 0.4)
        clock.instant = 11
        #expect(!witness.observe())
        clock.instant = 20
        #expect(!witness.observe())
        clock.instant = 21
        #expect(witness.observe())
        #expect(witness.files == [file.path])
    }

    @Test(arguments: [false, true])
    func invalidOrSilentAudioDoesNotComplete(silent: Bool) throws {
        let root = try makeExecTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = WitnessClock()
        let witness = try ProjectStemExportFileWitness(root: root.path, expectedCount: 1, settleNanos: 1, now: { clock.instant })
        let file = URL(fileURLWithPath: witness.directory).appendingPathComponent("invalid.wav")
        if silent { try writeSilentWav(at: file) }
        else { try Data("partial header".utf8).write(to: file) }
        #expect(!witness.observe())
        clock.instant = 2
        #expect(!witness.observe())
        #expect(witness.files.isEmpty)
    }

    @Test func wrongFileCountAndSymlinksDoNotComplete() throws {
        let root = try makeExecTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = WitnessClock()
        let witness = try ProjectStemExportFileWitness(root: root.path, expectedCount: 2, settleNanos: 1, now: { clock.instant })
        let directory = URL(fileURLWithPath: witness.directory)
        let first = try writeToneWav(at: directory.appendingPathComponent("first.wav"))
        #expect(!witness.observe())
        let second = directory.appendingPathComponent("second.wav")
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)
        #expect(!witness.observe())
        clock.instant = 2
        #expect(!witness.observe())
        try FileManager.default.removeItem(at: second)
        try writeToneWav(at: second)
        #expect(!witness.observe())
        clock.instant = 4
        #expect(witness.observe())
    }

    @Test func truncatedContainerDoesNotComplete() throws {
        let root = try makeExecTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = WitnessClock()
        let witness = try ProjectStemExportFileWitness(root: root.path, expectedCount: 1, settleNanos: 1, now: { clock.instant })
        let file = try writeToneWav(at: URL(fileURLWithPath: witness.directory).appendingPathComponent("truncated.wav"))
        let handle = try FileHandle(forWritingTo: file)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size / 2)
        try handle.close()
        #expect(!witness.observe())
        clock.instant = 2
        #expect(!witness.observe())
        #expect(witness.files.isEmpty)
    }

    @Test func replacedDirectoryCannotSupplyEvidence() throws {
        let root = try makeExecTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let witness = try ProjectStemExportFileWitness(root: root.path, expectedCount: 1)
        try FileManager.default.moveItem(atPath: witness.directory, toPath: witness.directory + "-original")
        try FileManager.default.createDirectory(atPath: witness.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try writeToneWav(at: URL(fileURLWithPath: witness.directory).appendingPathComponent("other.wav"))
        #expect(!witness.observe())
    }
}
