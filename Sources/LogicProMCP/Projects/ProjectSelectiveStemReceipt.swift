import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Per-delivery journal. Only files covered by an atomically committed record are reusable.
final class ProjectSelectiveStemReceipt {
    struct Identity: Codable, Equatable {
        let projectPath: String
        let projectSHA256: String
        let subjects: [ProjectExportStemSubject]
        let settings: ProjectAlignedStemSettings
        var mix: ProjectPCMBounceSettings? = nil

        var expectedTracks: [Int?] {
            subjects.map { Optional($0.index) } + (mix == nil ? [] : [nil])
        }
    }

    struct File: Codable, Equatable {
        let trackIndex: Int?
        let relativePath: String
        let sha256: String
        let sampleRate: Int
        let frames: Int64
    }

    struct Journal: Codable {
        let version: Int
        let deliveryID: UUID
        let identity: Identity
        var files: [File]
    }

    enum Failure: Error, Equatable {
        case alreadyExists
        case missingOrBusy
        case changedDelivery
        case invalidOrChangedFile
        case savedProjectUnreadable
    }

    enum FileState: String {
        case verified, pending, missing, changed, unverifiable
    }

    let directory: URL
    let startedWith: Set<Int?>
    private let descriptor: Int32
    private let manifest: URL
    private(set) var journal: Journal

    init(directory: URL, deliveryID: UUID, identity: Identity, resume: Bool) throws {
        self.directory = directory
        let manifest = directory.appendingPathComponent("receipt.json")
        self.manifest = manifest
        if !resume {
            guard directory.path.withCString({ mkdir($0, 0o700) }) == 0 else { throw Failure.alreadyExists }
        }
        let fd = try Self.lock(directory, mode: LOCK_EX)
        var transferred = false
        defer { if !transferred { close(fd) } }
        let journal: Journal
        if resume {
            journal = try Self.readJournal(manifest, id: deliveryID)
            guard journal.identity == identity else { throw Failure.changedDelivery }
            guard journal.files.allSatisfy({
                Self.fileState($0, directory: directory, identity: identity) == .verified
            }) else { throw Failure.invalidOrChangedFile }
        } else {
            journal = .init(version: identity.mix == nil ? 1 : 2, deliveryID: deliveryID, identity: identity, files: [])
            guard Self.holdsDirectory(directory, fd: fd) else { throw Failure.missingOrBusy }
            try Self.write(journal, to: manifest)
        }
        guard Self.holdsDirectory(directory, fd: fd) else { throw Failure.missingOrBusy }
        self.startedWith = Set(journal.files.map(\.trackIndex))
        self.descriptor = fd
        self.journal = journal
        transferred = true
    }

    deinit { close(descriptor) }

    static func inspect<T>(directory: URL, deliveryID: UUID, _ inspect: (Journal) throws -> T) throws -> T {
        let fd = try lock(directory, mode: LOCK_SH)
        defer { close(fd) }
        let journal = try readJournal(directory.appendingPathComponent("receipt.json"), id: deliveryID)
        let result = try inspect(journal)
        guard !Task.isCancelled, holdsDirectory(directory, fd: fd) else { throw Failure.missingOrBusy }
        return result
    }

    private static func lock(_ directory: URL, mode: Int32) throws -> Int32 {
        let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard fd >= 0 else { throw Failure.missingOrBusy }
        guard directory.resolvingSymlinksInPath().path == directory.path, holdsDirectory(directory, fd: fd),
              flock(fd, mode | LOCK_NB) == 0 else {
            close(fd)
            throw Failure.missingOrBusy
        }
        return fd
    }

    private static func readJournal(_ manifest: URL, id: UUID) throws -> Journal {
        let entry = try openFile(manifest)
        defer { try? entry.close() }
        let data = try entry.read(upToCount: 128 * 1024) ?? Data()
        guard data.count < 128 * 1024, let journal = try? JSONDecoder().decode(Journal.self, from: data),
              journal.version == (journal.identity.mix == nil ? 1 : 2), journal.deliveryID == id,
              (1...16).contains(journal.identity.subjects.count),
              journal.identity.subjects.allSatisfy({ $0.index >= 0 }),
              Set(journal.identity.expectedTracks).count == journal.identity.expectedTracks.count,
              Set(journal.files.map(\.trackIndex)).isSubset(of: Set(journal.identity.expectedTracks)),
              Set(journal.files.map(\.trackIndex)).count == journal.files.count,
              Set(journal.files.map(\.relativePath)).count == journal.files.count
        else { throw Failure.changedDelivery }
        if let mix = journal.identity.mix {
            guard mix.range == journal.identity.settings.range, mix.range != nil,
                  mix.format == .wav, mix.bitDepth == 24, !mix.includeAudioTail,
                  !journal.identity.settings.includeAudioTail else { throw Failure.changedDelivery }
        }
        if let first = journal.files.first,
           !journal.files.allSatisfy({
               $0.sampleRate == first.sampleRate &&
                   (journal.identity.settings.includeAudioTail || $0.frames == first.frames)
           }) { throw Failure.changedDelivery }
        return journal
    }

    private static func holdsDirectory(_ directory: URL, fd: Int32) -> Bool {
        var held = stat()
        var visible = stat()
        return fstat(fd, &held) == 0 && lstat(directory.path, &visible) == 0
            && held.st_dev == visible.st_dev && held.st_ino == visible.st_ino
            && visible.st_uid == getuid() && visible.st_mode & S_IFMT == S_IFDIR
            && visible.st_mode & 0o777 == 0o700
    }

    func holdsDirectory() -> Bool { Self.holdsDirectory(directory, fd: descriptor) }

    func newMixDestination() throws -> URL {
        guard holdsDirectory() else { throw Failure.missingOrBusy }
        let attempt = directory.appendingPathComponent("Conductor Export \(UUID().uuidString)", isDirectory: true)
        guard attempt.path.withCString({ mkdir($0, 0o700) }) == 0 else { throw Failure.alreadyExists }
        return attempt.appendingPathComponent("Stereo Mix.wav")
    }

    func record(_ url: URL, track: Int?, sampleRate: Int, frames: Int64) throws {
        let prefix = directory.path + "/"
        guard holdsDirectory(), url.path.hasPrefix(prefix), journal.identity.expectedTracks.contains(track),
              journal.files.allSatisfy({ $0.trackIndex != track }) else {
            throw Failure.invalidOrChangedFile
        }
        let relative = String(url.path.dropFirst(prefix.count))
        guard Self.validFileLocation(relative, in: directory) == url else { throw Failure.invalidOrChangedFile }
        let file = try File(trackIndex: track, relativePath: relative, sha256: Self.digest(url),
                            sampleRate: sampleRate, frames: frames)
        guard holdsDirectory() else { throw Failure.invalidOrChangedFile }
        var next = journal
        next.files.append(file)
        try Self.write(next, to: manifest)
        journal = next
    }

    static func fileState(_ file: File, directory: URL, identity: Identity) -> FileState {
        guard let url = validFileLocation(file.relativePath, in: directory) else { return .unverifiable }
        var details = stat()
        guard lstat(url.path, &details) == 0 else { return errno == ENOENT ? .missing : .unverifiable }
        guard let hash = try? digest(url) else { return .unverifiable }
        guard hash == file.sha256 else { return .changed }
        guard file.sampleRate > 0, file.frames > 0,
              identity.mix.map({ $0.sampleRate == file.sampleRate }) ?? true else { return .unverifiable }
        let formatVerified: Bool
        if file.trackIndex != nil {
            formatVerified = ProjectPCMBounceSettings.isStemWAVE24(url.path, sampleRate: file.sampleRate)
        } else {
            formatVerified = identity.mix?.matchesFile(url.path) == true
        }
        guard formatVerified, let wav = try? AVAudioFile(forReading: url), wav.length == file.frames else {
            return .unverifiable
        }
        return .verified
    }

    private static func write(_ journal: Journal, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: url, options: .atomic)
    }

    private static func validFileLocation(_ relative: String, in directory: URL) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].hasPrefix("Conductor Export "),
              UUID(uuidString: String(parts[0].dropFirst("Conductor Export ".count))) != nil,
              !parts[1].hasPrefix("."), parts[1].lowercased().hasSuffix(".wav") else { return nil }
        let result = directory.appendingPathComponent(String(parts[0]), isDirectory: true)
            .appendingPathComponent(String(parts[1]), isDirectory: false)
        return result.resolvingSymlinksInPath().path == result.path ? result : nil
    }

    private static func openFile(_ url: URL) throws -> FileHandle {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else {
            if fd >= 0 { close(fd) }
            throw Failure.invalidOrChangedFile
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func digest(_ url: URL) throws -> String {
        let file = try openFile(url)
        defer { try? file.close() }
        var initial = stat()
        guard fstat(file.fileDescriptor, &initial) == 0 else { throw Failure.invalidOrChangedFile }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            guard !Task.isCancelled else { throw CancellationError() }
            hash.update(data: bytes)
        }
        var final = stat()
        guard lstat(url.path, &final) == 0,
              initial.st_dev == final.st_dev, initial.st_ino == final.st_ino, initial.st_size == final.st_size,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec else { throw Failure.invalidOrChangedFile }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hash the saved edit data and bundled source media while ignoring Logic's UI-only files.
    static func savedProjectDigest(path: String) throws -> String {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard root.resolvingSymlinksInPath().path == root.path,
              let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { throw Failure.savedProjectUnreadable }
        var entries: [(String, URL)] = []
        var hasProjectData = false
        let prefix = root.path + "/"
        for case let file as URL in files {
            let relative = String(file.path.dropFirst(prefix.count))
            guard relative.hasPrefix("Alternatives/") || relative.hasPrefix("Media/") ||
                relative == "Resources/ProjectInformation.plist" else { continue }
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw Failure.savedProjectUnreadable }
            let isData = relative.hasPrefix("Alternatives/") && file.lastPathComponent == "ProjectData"
            guard properties.isRegularFile == true, isData || relative.hasPrefix("Media/") ||
                relative == "Resources/ProjectInformation.plist" else { continue }
            hasProjectData = hasProjectData || isData
            entries.append((relative, file))
        }
        guard hasProjectData else { throw Failure.savedProjectUnreadable }
        var digest = SHA256()
        for (relative, file) in entries.sorted(by: { $0.0 < $1.0 }) {
            digest.update(data: Data("\(relative.utf8.count):\(relative)\(try Self.digest(file))\n".utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
