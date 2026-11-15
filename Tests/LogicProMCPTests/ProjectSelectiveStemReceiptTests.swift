import AVFoundation
import Foundation
import Testing
@testable import LogicProMCP

@Suite("Selective stem delivery receipts")
struct ProjectSelectiveStemReceiptTests {
    @Test func resumePreservesCompletedStemAndRejectsChangedFileOrSettings() throws {
        let root = try makeExecTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let delivery = root.appendingPathComponent("Conductor Stems \(id.uuidString)")
        let subjects: [ProjectExportStemSubject] = [.init(index: 0, name: "Twin"), .init(index: 2, name: "Twin")]
        let settings = ProjectAlignedStemSettings(includeAudioTail: false, includeVolumePanAutomation: false,
                                                     range: .init(start: "1.1.1.1", end: "3.1.1.1"))
        let identity = ProjectSelectiveStemReceipt.Identity(projectPath: "/project.logicx",
            projectSHA256: "saved-project", subjects: subjects, settings: settings)
        let file: URL
        do {
            let receipt = try ProjectSelectiveStemReceipt(directory: delivery, deliveryID: id, identity: identity, resume: false)
            let attempt = try ProjectStemExportFileWitness(root: delivery.path, expectedCount: 1)
            file = URL(fileURLWithPath: attempt.directory).appendingPathComponent("Twin.wav")
            try writeStem(file)
            try receipt.record(file, track: 0, sampleRate: 48_000, frames: 4800)
            #expect(receipt.journal.files.count == 1)
            #expect(throws: ProjectSelectiveStemReceipt.Failure.self) {
                try ProjectSelectiveStemReceipt(directory: delivery, deliveryID: id, identity: identity, resume: true)
            }
        }
        let original = try Data(contentsOf: file)
        do {
            let receipt = try ProjectSelectiveStemReceipt(directory: delivery, deliveryID: id, identity: identity, resume: true)
            #expect(receipt.startedWith == [0])
            #expect(receipt.journal.files.map(\.trackIndex) == [0])
            #expect(try Data(contentsOf: file) == original)
        }
        let movedRange = ProjectSelectiveStemReceipt.Identity(projectPath: identity.projectPath,
            projectSHA256: identity.projectSHA256, subjects: subjects,
            settings: .init(includeAudioTail: false, includeVolumePanAutomation: false,
                            range: .init(start: "1.1.1.1", end: "4.1.1.1")))
        #expect(throws: ProjectSelectiveStemReceipt.Failure.self) {
            try ProjectSelectiveStemReceipt(directory: delivery, deliveryID: id, identity: movedRange, resume: true)
        }

        var edited = original
        edited[edited.index(before: edited.endIndex)] ^= 0x01
        try edited.write(to: file)
        #expect(throws: ProjectSelectiveStemReceipt.Failure.self) {
            try ProjectSelectiveStemReceipt(directory: delivery, deliveryID: id, identity: identity, resume: true)
        }
        #expect(try Data(contentsOf: file) == edited)
    }

    @Test func inspectMixDeliveryChecksFilesWithoutChangingTheJournal() throws {
        let root = try makeExecTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let delivery = ProjectSelectiveStemRequest.directory(root: root.path, id: id)
        let range = ProjectBounceRange(start: "1.1.1.1", end: "3.1.1.1")
        let identity = ProjectSelectiveStemReceipt.Identity(projectPath: "/project.logicx",
            projectSHA256: "saved-project", subjects: [.init(index: 0, name: "Twin")],
            settings: .init(includeAudioTail: false, includeVolumePanAutomation: true, range: range),
            mix: .init(format: .wav, sampleRate: 48_000, bitDepth: 24, includeAudioTail: false, range: range))
        let mix: URL
        do {
            let receipt = try ProjectSelectiveStemReceipt(directory: delivery, deliveryID: id, identity: identity, resume: false)
            mix = try receipt.newMixDestination()
            try writeStem(mix, channels: 2)
            try receipt.record(mix, track: nil, sampleRate: 48_000, frames: 4800)
            #expect(throws: ProjectSelectiveStemReceipt.Failure.self) {
                try ProjectSelectiveStemReceipt.inspect(directory: delivery, deliveryID: id) { _ in true }
            }
        }
        let path = delivery.appendingPathComponent("receipt.json")
        let original = try Data(contentsOf: path)
        let modified = try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        func status() throws -> ProjectSelectiveStemReceipt.FileState {
            try ProjectSelectiveStemReceipt.inspect(directory: delivery, deliveryID: id) { journal in
                #expect(journal.version == 2)
                #expect(journal.identity.expectedTracks == [0, nil])
                let entry = try #require(journal.files.first)
                #expect(entry.trackIndex == nil)
                return ProjectSelectiveStemReceipt.fileState(entry, directory: delivery, identity: journal.identity)
            }
        }
        #expect(try status() == .verified)
        var wav = try Data(contentsOf: mix)
        wav[wav.index(before: wav.endIndex)] ^= 1
        try wav.write(to: mix)
        #expect(try status() == .changed)
        try FileManager.default.removeItem(at: mix)
        #expect(try status() == .missing)
        #expect(try Data(contentsOf: path) == original)
        #expect(try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    }

    private func writeStem(_ url: URL, channels: AVAudioChannelCount = 1) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
        ])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        try file.write(from: buffer)
    }
}
