import Foundation
import Darwin

extension QualificationTransport {
    // MARK: - Verifier-owned support-bundle artifact

    private struct OwnedSupportBundleFile: Equatable {
        let name: String
        let sha256: String
    }

    private struct OwnedSupportBundleReadback {
        let raw: String
        let identity: SecureFD.Identity
    }

    /// #373 Phase B for `system.export_support_bundle`. The verifier chooses an absent UUID leaf
    /// in the product's diagnostics root, drives the real operation, reads every published file
    /// no-follow, checks its digest, and descriptor-deletes only that owned leaf.
    func supportBundleArtifactRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        let leaf = "qualification-\(UUID().uuidString.lowercased())"
        let target = supportBundleRoot()
            .appendingPathComponent(leaf, isDirectory: true)
            .standardizedFileURL
        let pre = try Self.ownedSupportBundleAbsenceObservation(at: target)
        // Arm cleanup before the request. A timeout or malformed/lost response says nothing about
        // whether the operation created its UUID directory, and every target at this path is ours
        // because the exact leaf was observed absent immediately above.
        var cleanupIdentity: SecureFD.Identity?
        do {
            let mutation: (text: String, isError: Bool)
            do {
                mutation = try invoke(
                    session, id: id, tool: spec.tool.rawValue, command: spec.command,
                    params: ["dir": leaf], phase: "phase_b.mutation",
                    timeout: spec.deadline.seconds + 5)
            } catch {
                throw supportBundleFailureAfterQuiescing(
                    session, at: target, expectedIdentity: cleanupIdentity,
                    cause: String(describing: error))
            }
            // Acquire identity before trusting the response manifest, so malformed or incomplete
            // success replies cannot strand verifier-owned diagnostics.
            cleanupIdentity = try? Self.ownedSupportBundleIdentity(at: target)
            let response = mutation.text.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            if mutation.isError, response?["error"] as? String == "operation_timeout" {
                throw supportBundleFailureAfterQuiescing(
                    session, at: target, expectedIdentity: cleanupIdentity,
                    cause: "phase_b.mutation: operation_timeout")
            }
            guard !mutation.isError,
                  let response,
                  response["state"] as? String == "A",
                  response["bundle_path"] as? String == target.path else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.mutation: system.export_support_bundle did not publish the owned path")
            }

            guard let rows = response["files"] as? [[String: Any]], !rows.isEmpty else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: support-bundle response has no file manifest")
            }
            var expected: [OwnedSupportBundleFile] = []
            var names = Set<String>()
            for row in rows {
                guard let name = row["name"] as? String,
                      (try? SecureFD.validateComponent(name)) != nil,
                      names.insert(name).inserted,
                      let digest = row["sha256"] as? String,
                      digest.count == 64,
                      digest.utf8.allSatisfy({
                          (48...57).contains($0) || (97...102).contains($0)
                      }) else {
                    throw QualificationTransportError.protocolViolation(
                        "phase_b.readback: malformed support-bundle manifest")
                }
                expected.append(.init(name: name, sha256: digest))
            }
            guard names == Set(SupportBundleBuilder.fileNames) else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: support-bundle manifest is not the exact product file set")
            }

            let after = try Self.verifiedOwnedSupportBundleReadback(
                at: target, expected: expected, expectedIdentity: cleanupIdentity)
            cleanupIdentity = after.identity
            let restore = try supportBundleRemover(target, after.identity)
            cleanupIdentity = nil
            let restored = try Self.ownedSupportBundleAbsenceObservation(at: target)
            return (
                QualificationMutationRestoreRecord(
                    operationID: spec.id.rawValue,
                    preState: pre,
                    mutation: mutation.text,
                    readback: after.raw,
                    restore: restore,
                    restoreReadback: restored
                ),
                id + 1
            )
        } catch let error as QualificationTransportError where error.requiresDriveAbort {
            throw error
        } catch {
            let cleanup = cleanupOwnedSupportBundleAfterFailure(
                at: target, expectedIdentity: cleanupIdentity)
            throw QualificationTransportError.protocolViolation(
                "\(error) | owned support-bundle cleanup \(cleanup)")
        }
    }

    /// A timeout or missing transport reply does not mean the server-side write stopped. End the
    /// exact candidate process first, then reacquire and remove only the UUID leaf this verifier
    /// observed absent before dispatch. No bounded absence poll can prove that an orphaned task
    /// will not publish after the poll ends.
    private func supportBundleFailureAfterQuiescing(
        _ session: QualificationSubprocessSession,
        at target: URL,
        expectedIdentity: SecureFD.Identity?,
        cause: String
    ) -> QualificationTransportError {
        do {
            let outcome = try supportBundleQuiescer(session)
            let cleanup = cleanupOwnedSupportBundleAfterFailure(
                at: target, expectedIdentity: expectedIdentity)
            return .supportBundleOutcomeQuiesced(
                "\(cause) | candidate_process_quiesced(status=\(outcome.status),forced=\(outcome.forced))"
                    + " | owned support-bundle cleanup \(cleanup)")
        } catch {
            return .supportBundleOutcomeUncertain(
                "\(cause) | candidate_process_quiescence_failed(\(error))"
                    + " | owned support-bundle cleanup cleanup_withheld(candidate_not_quiesced)"
                    + "; residual=present_or_unverified")
        }
    }

    private func cleanupOwnedSupportBundleAfterFailure(
        at target: URL,
        expectedIdentity: SecureFD.Identity?
    ) -> String {
        let identity: SecureFD.Identity
        if let expectedIdentity {
            identity = expectedIdentity
        } else {
            do {
                identity = try Self.ownedSupportBundleIdentity(at: target)
            } catch {
                if (try? Self.ownedSupportBundleAbsenceObservation(at: target)) != nil {
                    return "absent_verified"
                }
                return "failed: identity_unavailable(\(error)); residual=present_or_unverified"
            }
        }
        do {
            _ = try supportBundleRemover(target, identity)
            _ = try Self.ownedSupportBundleAbsenceObservation(at: target)
            return "removed_and_absence_verified"
        } catch {
            let residual = (try? Self.ownedSupportBundleAbsenceObservation(at: target)) != nil
                ? "absent"
                : "present_or_unverified"
            return "failed: \(error); residual=\(residual)"
        }
    }

    private static func ownedSupportBundleEnvelope(
        path: String,
        exists: Bool,
        files: [OwnedSupportBundleFile] = []
    ) throws -> String {
        let object: [String: Any] = [
            "source": "host_filesystem",
            "readable": true,
            "ax_occluded": false,
            "verified_empty": false,
            "cache_age_sec": 0,
            "data": [
                "path": path,
                "exists": exists,
                "manifest_verified": exists,
                "files": files.sorted { $0.name < $1.name }.map {
                    ["name": $0.name, "sha256": $0.sha256]
                },
            ] as [String: Any],
        ]
        return String(decoding: try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func ownedSupportBundleAbsenceObservation(at target: URL) throws -> String {
        var state = stat()
        let status = target.path.withCString { lstat($0, &state) }
        let observedErrno = errno
        guard status == -1, observedErrno == ENOENT else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.pre_state: verifier-owned support-bundle target already exists")
        }
        return try ownedSupportBundleEnvelope(path: target.path, exists: false)
    }

    private static func ownedSupportBundleIdentity(at target: URL) throws -> SecureFD.Identity {
        let opened = try SecureFD.openTrustedBase(for: target)
        defer { close(opened.baseFD) }
        let bundle = try SecureFD.walkVerified(baseFD: opened.baseFD, opened.relative)
        defer { close(bundle.fd) }
        guard let identity = bundle.ids.last else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: support-bundle identity unavailable")
        }
        return identity
    }

    private static func verifiedOwnedSupportBundleReadback(
        at target: URL,
        expected: [OwnedSupportBundleFile],
        expectedIdentity: SecureFD.Identity?
    ) throws -> OwnedSupportBundleReadback {
        let opened = try SecureFD.openTrustedBase(for: target)
        defer { close(opened.baseFD) }
        guard let leaf = opened.relative.last else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: owned support-bundle path has no leaf")
        }
        let parent = try SecureFD.walkVerified(
            baseFD: opened.baseFD, Array(opened.relative.dropLast()))
        defer { close(parent.fd) }
        let bundle = try SecureFD.walkVerified(
            baseFD: opened.baseFD, opened.relative)
        defer { close(bundle.fd) }
        guard let identity = bundle.ids.last else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: support-bundle identity unavailable")
        }
        if let expectedIdentity, !SecureFD.sameIdentity(identity, expectedIdentity) {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: owned support-bundle identity changed before verification")
        }

        let actualNames = try ownedRegularFileNames(in: bundle.fd)
        let expectedNames = Set(expected.map(\.name))
        guard actualNames == expectedNames,
              expectedNames == Set(SupportBundleBuilder.fileNames) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: support-bundle contents differ from the manifest")
        }
        for file in expected {
            let fd = try SecureFD.openRead(parentFD: bundle.fd, name: file.name)
            let data: Data
            do {
                data = try readOwnedRegularFile(fd, name: file.name)
            } catch {
                close(fd)
                throw error
            }
            close(fd)
            guard SupportBundleBuilder.sha256(data) == file.sha256 else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: support-bundle digest mismatch for \(file.name)")
            }
        }

        var named = stat()
        guard leaf.withCString({
            fstatat(parent.fd, $0, &named, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        named.st_dev == identity.dev, named.st_ino == identity.ino else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: owned support-bundle identity changed during verification")
        }
        return OwnedSupportBundleReadback(
            raw: try ownedSupportBundleEnvelope(
                path: target.path, exists: true, files: expected),
            identity: identity
        )
    }

    private static func ownedRegularFileNames(in directoryFD: Int32) throws -> Set<String> {
        let duplicate = fcntl(directoryFD, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: support-bundle directory cannot be enumerated")
        }
        defer { closedir(directory) }
        var names = Set<String>()
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            try SecureFD.validateComponent(name)
            var state = stat()
            guard name.withCString({
                fstatat(directoryFD, $0, &state, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            (state.st_mode & S_IFMT) == S_IFREG,
            state.st_nlink == 1,
            names.insert(name).inserted else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: support-bundle contains a non-exclusive regular file")
            }
            errno = 0
        }
        guard errno == 0 else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: support-bundle enumeration failed")
        }
        return names
    }

    private static func readOwnedRegularFile(
        _ fd: Int32,
        name: String,
        limit: Int = 16 * 1024 * 1024
    ) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if count == 0 { return output }
            if count < 0 {
                if errno == EINTR { continue }
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: support-bundle file read failed for \(name)")
            }
            guard output.count <= limit - count else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: support-bundle file exceeds the verifier limit")
            }
            output.append(buffer, count: count)
        }
    }

    static func removeOwnedSupportBundle(
        at target: URL,
        expectedIdentity: SecureFD.Identity
    ) throws -> String {
        let opened = try SecureFD.openTrustedBase(for: target)
        defer { close(opened.baseFD) }
        guard let leaf = opened.relative.last else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: owned support-bundle path has no leaf")
        }
        let parent = try SecureFD.walkVerified(
            baseFD: opened.baseFD, Array(opened.relative.dropLast()))
        defer { close(parent.fd) }
        var before = stat()
        guard leaf.withCString({
            fstatat(parent.fd, $0, &before, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        before.st_dev == expectedIdentity.dev,
        before.st_ino == expectedIdentity.ino else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: owned support-bundle identity changed; cleanup withheld")
        }
        try SecureFD.teardownTree(parentFD: parent.fd, name: leaf)
        var after = stat()
        let status = leaf.withCString({
            fstatat(parent.fd, $0, &after, AT_SYMLINK_NOFOLLOW)
        })
        let observedErrno = errno
        guard status == -1, observedErrno == ENOENT else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: owned support-bundle still exists")
        }
        let receipt: [String: Any] = [
            "state": "A",
            "verified": true,
            "write_attempted": true,
            "operation": "host_filesystem.remove_owned_support_bundle",
            "path": target.path,
        ]
        return String(decoding: try JSONSerialization.data(
            withJSONObject: receipt, options: [.sortedKeys]), as: UTF8.self)
    }
}
