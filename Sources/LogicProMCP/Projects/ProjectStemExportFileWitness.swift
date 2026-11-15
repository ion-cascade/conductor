import Darwin
import Foundation

/// A run-owned namespace prevents old files and unrelated output-root entries
/// from being used as evidence. The panel must independently confirm this exact
/// destination. This class is polled serially by one export operation.
final class ProjectStemExportFileWitness: @unchecked Sendable {
    let directory: String
    private let expectedCount: Int
    private let allowsSilentOutput: Bool
    private let directoryInode: UInt64
    private let directoryDevice: Int32
    private var previous: [String] = []
    private var stableSince: UInt64?
    private let now: @Sendable () -> UInt64
    private let settleNanos: UInt64
    private(set) var files: [String] = []

    init(
        root: String,
        expectedCount: Int,
        allowsSilentOutput: Bool = false,
        settleNanos: UInt64 = 1_000_000_000,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) throws {
        guard expectedCount > 0 else { throw WitnessError.invalidSubjectCount }
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        guard rootURL.resolvingSymlinksInPath().path == rootURL.path else {
            throw WitnessError.unsafeDirectory
        }
        let destination = rootURL.appendingPathComponent("Conductor Export \(UUID().uuidString)").path
        guard destination.withCString({ Darwin.mkdir($0, 0o700) }) == 0 else {
            throw WitnessError.cannotCreateDirectory
        }
        var info = stat()
        guard destination.withCString({ lstat($0, &info) }) == 0,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw WitnessError.unsafeDirectory
        }
        directory = destination
        directoryInode = info.st_ino
        directoryDevice = info.st_dev
        self.expectedCount = expectedCount
        self.allowsSilentOutput = allowsSilentOutput
        self.now = now
        self.settleNanos = settleNanos
    }

    enum WitnessError: Error {
        case invalidSubjectCount, cannotCreateDirectory, unsafeDirectory
    }

    /// Requiring a closed panel and an observed absence of progress is owned
    /// by the caller. Here require a stable, fully decodable set. Aligned project-length stems may contain silence.
    func observe() -> Bool {
        files = []
        var directoryInfo = stat()
        guard directory.withCString({ lstat($0, &directoryInfo) }) == 0,
              directoryInfo.st_ino == directoryInode,
              directoryInfo.st_dev == directoryDevice,
              directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_mode & 0o777 == 0o700,
              case let .files(paths) = ProjectExportArtifactPathPolicy.supportedAudioEntries(
                in: directory, fileManager: .default
              ), paths.count == expectedCount else { return reset() }
        var signatures: [String] = []
        for path in paths {
            var info = stat()
            guard path.withCString({ lstat($0, &info) }) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_size > 0,
                  ProjectExportContainerCompletion.isComplete(at: path, size: info.st_size) else { return reset() }
            signatures.append("\(path):\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)")
        }
        let instant = now()
        guard signatures == previous, let since = stableSince,
              instant >= since, instant - since >= settleNanos else {
            if signatures != previous { previous = signatures; stableSince = instant }
            return false
        }
        for path in paths {
            let result = AudioAnalyzer.analyzeFile(
                path: path,
                policy: .init(minimumDurationSeconds: 0.05, allowsSilentOutput: allowsSilentOutput, outputRoot: directory)
            )
            guard result.verification.status == .pass else { return reset() }
        }
        // Re-stat after decoding: a file changing during analysis cannot pass.
        for (index, path) in paths.enumerated() {
            var info = stat()
            guard path.withCString({ lstat($0, &info) }) == 0,
                  signatures[index] == "\(path):\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)" else { return reset() }
        }
        files = paths
        return true
    }

    private func reset() -> Bool {
        previous = []; stableSince = nil
        return false
    }
}
