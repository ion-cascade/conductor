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
    }

    struct File: Codable, Equatable {
        let trackIndex: Int
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

    let directory: URL
    let startedWith: Set<Int>
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
        let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        var transferred = false
        defer { if fd >= 0 && !transferred { close(fd) } }
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
              directory.resolvingSymlinksInPath().path == directory.path,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.missingOrBusy }
        let journal: Journal
        if resume {
            let entry = try Self.openFile(manifest)
            defer { try? entry.close() }
            let data = try entry.read(upToCount: 128 * 1024) ?? Data()
            guard data.count < 128 * 1024, let existing = try? JSONDecoder().decode(Journal.self, from: data),
                  existing.version == 1, existing.deliveryID == deliveryID, existing.identity == identity,
                  Set(existing.files.map(\.trackIndex)).isSubset(of: Set(identity.subjects.map(\.index))),
                  Set(existing.files.map(\.trackIndex)).count == existing.files.count,
                  Set(existing.files.map(\.relativePath)).count == existing.files.count else { throw Failure.changedDelivery }
            journal = existing
        } else {
            journal = .init(version: 1, deliveryID: deliveryID, identity: identity, files: [])
            try Self.write(journal, to: manifest)
        }
        for file in journal.files {
            guard let url = Self.validFileLocation(file.relativePath, in: directory),
                  file.sampleRate > 0, file.frames > 0,
                  try Self.digest(url) == file.sha256,
                  ProjectPCMBounceSettings.isStemWAVE24(url.path, sampleRate: file.sampleRate) else {
                throw Failure.invalidOrChangedFile
            }
        }
        self.startedWith = Set(journal.files.map(\.trackIndex))
        self.descriptor = fd
        self.journal = journal
        transferred = true
    }

    deinit { close(descriptor) }

    func holdsDirectory() -> Bool {
        var held = stat()
        var visible = stat()
        return fstat(descriptor, &held) == 0 && lstat(directory.path, &visible) == 0
            && held.st_dev == visible.st_dev && held.st_ino == visible.st_ino
            && visible.st_uid == getuid() && visible.st_mode & S_IFMT == S_IFDIR
            && visible.st_mode & 0o777 == 0o700
    }

    func record(_ url: URL, track: Int, sampleRate: Int, frames: Int64) throws {
        let prefix = directory.path + "/"
        guard holdsDirectory(), url.path.hasPrefix(prefix), journal.files.allSatisfy({ $0.trackIndex != track }) else {
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
