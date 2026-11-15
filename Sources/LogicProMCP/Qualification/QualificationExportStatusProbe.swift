import CryptoKit
import Darwin
import Foundation

/// One synthetic delivery supplied by the verifier. The response never chooses the files
/// used for readback. Those paths, expected bytes, and bindings are retained before the RPC.
final class QualificationExportStatusProbe {
    static let source = "host://filesystem/owned-export-status-fixture"
    static let evidenceKind = "owned_export_status_fixture.v1"

    private let root: URL
    private let rootFD: Int32
    private let deliveryID = UUID()
    private let settings = ProjectAlignedStemSettings(
        includeAudioTail: false, includeVolumePanAutomation: false,
        range: .init(start: "1.1.1.1", end: "2.1.1.1")
    )
    private let sampleRate = 48_000
    private let frameCount = 480
    private let track = ProjectExportStemSubject(index: 0, name: "Qualification Tone")
    private let attempt = "Conductor Export \(UUID().uuidString)"
    private let projectFolder = "Qualification.logicx"
    private let projectBytes = Data("Conductor qualification project-data fixture\n".utf8)
    private let wavName = "Qualification Tone.wav"
    private let journalBytes: Data
    private let wavBytes: Data

    private struct Settings: Encodable {
        let stems: ProjectAlignedStemSettings
    }

    init() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Conductor Qualification \(UUID().uuidString)", isDirectory: true)
        root = folder
        guard mkdir(folder.path, 0o700) == 0 else {
            throw QualificationTransportError.protocolViolation("could not create export status fixture")
        }
        var fd: Int32?
        do {
            let opened = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else {
                throw QualificationTransportError.protocolViolation("could not hold export status fixture")
            }
            fd = opened
            rootFD = opened
            wavBytes = Self.wave(sampleRate: sampleRate, frames: frameCount)
            let project = folder.appendingPathComponent(projectFolder)
            let projectRelative = "Alternatives/000/ProjectData"
            let projectFile = project.appendingPathComponent(projectRelative)
            try FileManager.default.createDirectory(at: projectFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try projectBytes.write(to: projectFile)

            let directory = ProjectSelectiveStemRequest.directory(root: folder.path, id: deliveryID)
            let attemptDirectory = directory.appendingPathComponent(attempt)
            for url in [directory, attemptDirectory] {
                guard mkdir(url.path, 0o700) == 0 else {
                    throw QualificationTransportError.protocolViolation("could not create export status delivery directory")
                }
            }
            try wavBytes.write(to: attemptDirectory.appendingPathComponent(wavName))

            // The saved-project digest for this fixture covers only its one known entry.
            let projectDigest = Self.sha256(Data(
                "\(projectRelative.utf8.count):\(projectRelative)\(Self.sha256(projectBytes))\n".utf8))
            let identity = ProjectSelectiveStemReceipt.Identity(
                projectPath: project.path, projectSHA256: projectDigest, subjects: [track], settings: settings)
            let journal = ProjectSelectiveStemReceipt.Journal(version: 1, deliveryID: deliveryID,
                identity: identity, files: [.init(trackIndex: track.index, relativePath: "\(attempt)/\(wavName)",
                    sha256: Self.sha256(wavBytes), sampleRate: sampleRate, frames: Int64(frameCount))])
            journalBytes = try JSONEncoder().encode(journal)
            try journalBytes.write(to: directory.appendingPathComponent("receipt.json"))
        } catch {
            if let fd { close(fd) }
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    deinit {
        defer { close(rootFD) }
        if stillOwnsRoot { try? FileManager.default.removeItem(at: root) }
    }

    var params: [String: Any] {
        ["output_root": root.path, "delivery_id": deliveryID.uuidString]
    }

    func readback() throws -> Data {
        let directory = ProjectSelectiveStemRequest.directory(root: root.path, id: deliveryID)
        let delivery = directory.lastPathComponent
        try check([projectFolder, "Alternatives", "000"], "ProjectData", against: projectBytes)
        try check([delivery], "receipt.json", against: journalBytes)
        try check([delivery, attempt], wavName, against: wavBytes)
        guard stillOwnsRoot else {
            throw QualificationTransportError.protocolViolation("export status fixture directory changed")
        }

        let settingsJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings(stems: settings)))
        return try JSONSerialization.data(withJSONObject: [
            "evidence_kind": Self.evidenceKind,
            "delivery_id": deliveryID.uuidString,
            "directory": directory.path,
            "project_path": root.appendingPathComponent(projectFolder).path,
            "settings": settingsJSON,
            "outputs": [[
                "kind": "stem", "track_index": track.index, "track_name": track.name,
                "path": directory.appendingPathComponent(attempt).appendingPathComponent(wavName).path,
                "sha256": Self.sha256(wavBytes), "sample_rate": sampleRate, "frame_count": frameCount,
                "status": "verified",
            ]],
        ], options: [.sortedKeys])
    }

    static func accepts(source: String?, data: Data) -> Bool {
        guard source == Self.source, let evidence = JSONInspector.parse(data) as? [String: Any] else {
            return false
        }
        return evidence["evidence_kind"] as? String == evidenceKind
    }

    private var stillOwnsRoot: Bool {
        var held = stat()
        var current = stat()
        return fstat(rootFD, &held) == 0 && lstat(root.path, &current) == 0
            && held.st_dev == current.st_dev && held.st_ino == current.st_ino
            && (current.st_mode & S_IFMT) == S_IFDIR
    }

    private func check(_ directories: [String], _ name: String, against expected: Data) throws {
        let parent = try SecureFD.walkVerified(baseFD: rootFD, directories).fd
        defer { close(parent) }
        let fd = try SecureFD.openRead(parentFD: parent, name: name)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        guard try file.read(upToCount: expected.count + 1) == expected else {
            throw QualificationTransportError.protocolViolation("export status fixture changed: \(name)")
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func wave(sampleRate: Int, frames: Int) -> Data {
        var bytes = Data()
        func text(_ text: String) { bytes.append(contentsOf: text.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        let pcmBytes = frames * 3
        text("RIFF")
        word(UInt32(36 + pcmBytes))
        text("WAVEfmt ")
        word(UInt32(16))
        word(UInt16(1))
        word(UInt16(1))
        word(UInt32(sampleRate))
        word(UInt32(sampleRate * 3))
        word(UInt16(3))
        word(UInt16(24))
        text("data")
        word(UInt32(pcmBytes))
        for sample in 0..<frames {
            bytes.append(contentsOf: [0, 0, UInt8(sample % 64)])
        }
        return bytes
    }
}
