import Foundation

enum QualificationMutationRestorePolicy: Codable, Equatable, Sendable {
    enum Motion: String, Codable, Equatable, Sendable {
        case stopped
        case paused
        case moving
    }

    case trackNumeric(field: String)
    case trackBoolean(field: String)
    case trackName
    case trackSelection
    case transportMotion(expected: Motion)
    case transportToggle(field: String)
    case tempo
    case playheadStep(direction: Int)
    case playheadPosition
    case markerNames
    case ownedFileArtifact
    case trackCreate
    case trackDelete

    var isValid: Bool {
        switch self {
        case .trackNumeric(let field), .trackBoolean(let field), .transportToggle(let field):
            return !field.isEmpty
        case .playheadStep(let direction):
            return direction == -1 || direction == 1
        case .trackName, .trackSelection, .transportMotion, .tempo, .playheadPosition,
             .markerNames, .ownedFileArtifact, .trackCreate, .trackDelete:
            return true
        }
    }
}

struct QualificationMutationRestoreRecord: Codable, Equatable, Sendable {
    let operationID: String
    let preState: String
    let mutation: String
    let readback: String
    let restore: String
    let restoreReadback: String
    /// Actual precondition write and independent observation, absent for legacy/unstaged cycles.
    var stagingMutation: String? = nil
    var stagingReadback: String? = nil

    /// The name of the first reading in this record that says it did not HAPPEN, or nil when all
    /// three report a real one.
    ///
    /// Why this exists rather than leaning on `readbackFreshness`: that verdict is computed from
    /// the operation's own later readback, not from these three, and it short-circuits to
    /// `.admissible` for every verification policy that is not `.readbackRequired`.
    ///
    /// THE FIRST VERSION OF THIS COMMENT NAMED THE WRONG OPERATIONS, and a blind review caught it.
    /// It said `mixer.set_volume` and `mixer.set_pan` were `.none` and were "the only two
    /// operations this record is built for". Both halves were false. `OperationRegistry.swift`
    /// hardcodes `verification: .readbackRequired` for the whole `.logicMixer` block; the `.none`
    /// beside those rows is the **ConfirmationPolicy** — the tuple is
    /// `(OperationID, String, ConfirmationPolicy, TargetPolicy, Set<String>)`. And fourteen cycles
    /// in this file produce a `QualificationMutationRestoreRecord`, not two.
    ///
    /// The operations where freshness really is vacuous are in the TRANSPORT family —
    /// `transport.toggle_cycle` and `transport.set_tempo` are `.none` verification — and those read
    /// `logic://transport/state`, whose envelope carries neither `readable` nor `verified_empty`.
    /// It says so a different way: `unverified: true` with `source: "cache"`. So that is checked
    /// here too, or this guard would be absent from exactly the family it is the only defence for.
    ///
    /// What it checks is whether a reading OCCURRED, never whether it is fresh: staleness is a
    /// different complaint and has its own verdict.
    var readingThatDidNotHappen: String? {
        var readings = [("pre_state", preState), ("readback", readback), ("restore_readback", restoreReadback)]
        if let stagingReadback { readings.append(("staging_readback", stagingReadback)) }
        for (name, raw) in readings {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "\(name): not readable as a JSON envelope"
            }
            if object["readable"] as? Bool == false { return "\(name): readable=false" }
            if object["ax_occluded"] as? Bool == true { return "\(name): ax_occluded=true" }
            // The transport envelope's own word for "this is not a reading of the live surface".
            if object["unverified"] as? Bool == true { return "\(name): unverified=true" }
            // THE FRESHNESS GATE'S OWN QUESTION, widened by exactly one step. These were two
            // checks and they disagreed on an absent rows key -- this one refused, that one waved
            // it through -- so whether a rowless readback was admissible depended on which gate
            // asked. Both were also blind to a DICTIONARY payload, which this subsystem reads.
            //
            // `showsNoRows` rather than `isEmpty(object["data"])` because a record carries no URI:
            // its three readings come from whichever resource the recipe used, and `logic://mixer`
            // publishes `strips` where `logic://tracks` publishes `data`. Asking only about `data`
            // called every mixer reading empty.
            if QualificationReadbackFreshness.showsNoRows(object),
               object["verified_empty"] as? Bool != true {
                return "\(name): empty without verified_empty"
            }
        }
        return nil
    }

    /// Compare the observed part of the resource, not the whole envelope. Refresh metadata and
    /// unrelated rows can change between reads; each recipe below checks the field it restored.
    private func restoreMatchesPreState(using policy: QualificationMutationRestorePolicy) -> Bool {
        guard let before = Self.envelope(preState),
              let after = Self.envelope(restoreReadback) else { return false }

        // Phase C deletion stages a track and recreates it with a new reference.
        if policy == .trackCreate {
            guard let old = Self.trackRefs(before), let restored = Self.trackRefs(after) else { return false }
            return before["complete"] as? Bool == after["complete"] as? Bool
                && Set(old) == Set(restored)
        }
        if policy == .trackDelete {
            guard let old = Self.trackRefs(before), let restored = Self.trackRefs(after) else { return false }
            return before["complete"] as? Bool == after["complete"] as? Bool
                && old.count == restored.count
                && Set(old).intersection(restored).count == old.count - 1
        }
        return Self.sameRecipeValue(policy, before, after) == true
    }

    /// A successful-looking write is not proof of a mutation. Compare the recipe's observable
    /// before and after the write, with the same track identity where the recipe addresses one.
    private func mutationMovedRecipeValue(using policy: QualificationMutationRestorePolicy) -> Bool {
        guard let before = Self.envelope(preState),
              let after = Self.envelope(readback) else { return false }
        if policy == .trackCreate || policy == .trackDelete {
            guard let old = Self.trackRefs(before), let changed = Self.trackRefs(after) else { return false }
            return before["complete"] as? Bool == after["complete"] as? Bool
                && old.count != changed.count && Set(old) != Set(changed)
        }
        // transportRestoreCycle records its pre-state from BEFORE its precondition stage: when the
        // transport already sits where the operation puts it, the recipe first moves it the other
        // way and throws if that did not happen. So a genuine readback can equal the pre-state, and
        // the write's movement is shown by the readback being where the operation puts the
        // transport, which the state just before the write never is.
        if case .transportMotion(let expected) = policy {
            return QualificationTransport.recordedTransportMotion(readback)?.policyValue == expected
        }
        if case .playheadStep(let direction) = policy {
            guard let old = QualificationTransport.freshRecordedExactStepPosition(preState),
                  let observed = QualificationTransport.freshRecordedExactStepPosition(readback),
                  QualificationTransport.freshRecordedExactStepPosition(restoreReadback) == old,
                  QualificationTransport.playheadStepMutationWasAttempted(mutation),
                  QualificationTransport.verifiedPlayheadGotoReply(restore, expectedPosition: old)
            else { return false }
            let stepOrigin: String
            switch (stagingMutation, stagingReadback) {
            case (nil, nil): stepOrigin = old
            case let (write?, reading?):
                let boundary = QualificationTransport.barBoundary(from: old)
                guard QualificationTransport.verifiedPlayheadGotoReply(write, expectedPosition: boundary),
                      let position = QualificationTransport.freshRecordedExactStepPosition(reading),
                      position == boundary, position != old
                else { return false }
                stepOrigin = position
            default: return false
            }
            return QualificationTransport.stepPosition(from: stepOrigin, direction: direction) == observed
        }
        return Self.sameRecipeValue(policy, before, after) == false
    }

    /// nil means the observation is malformed or belongs to another track, not a value change.
    private static func sameRecipeValue(
        _ policy: QualificationMutationRestorePolicy,
        _ before: [String: Any],
        _ after: [String: Any]
    ) -> Bool? {
        switch policy {
        case .trackNumeric(let field):
            guard let old = Self.track(before, index: 0),
                  let observed = Self.track(after, index: 0),
                  let oldRef = old["track_ref"] as? String, !oldRef.isEmpty,
                  let observedRef = observed["track_ref"] as? String, oldRef == observedRef,
                  let oldValue = old[field] as? Double,
                  let observedValue = observed[field] as? Double else { return nil }
            return oldValue == observedValue
        case .trackBoolean(let field):
            guard let old = Self.track(before, index: 0),
                  let observed = Self.track(after, index: 0),
                  let oldRef = old["track_ref"] as? String, !oldRef.isEmpty,
                  let observedRef = observed["track_ref"] as? String, oldRef == observedRef,
                  let oldValue = old[field] as? Bool,
                  let observedValue = observed[field] as? Bool else { return nil }
            return oldValue == observedValue
        case .trackName:
            guard let old = Self.track(before, index: 0),
                  let observed = Self.track(after, index: 0),
                  let oldRef = old["track_ref"] as? String, !oldRef.isEmpty,
                  let observedRef = observed["track_ref"] as? String, oldRef == observedRef,
                  let oldValue = old["name"] as? String,
                  let observedValue = observed["name"] as? String else { return nil }
            return oldValue == observedValue
        case .trackSelection:
            guard let oldRows = before["data"] as? [[String: Any]],
                  let observedRows = after["data"] as? [[String: Any]],
                  oldRows.count > 1, observedRows.count > 1,
                  let oldFirstRef = oldRows[0]["track_ref"] as? String, !oldFirstRef.isEmpty,
                  let oldSecondRef = oldRows[1]["track_ref"] as? String, !oldSecondRef.isEmpty,
                  let observedFirstRef = observedRows[0]["track_ref"] as? String,
                  let observedSecondRef = observedRows[1]["track_ref"] as? String,
                  oldFirstRef == observedFirstRef, oldSecondRef == observedSecondRef,
                  let firstWasSelected = oldRows[0]["isSelected"] as? Bool
            else { return nil }
            let originalRef = firstWasSelected ? oldFirstRef : oldSecondRef
            guard let oldSelection = Self.selectedTrackRefs(oldRows),
                  let observedSelection = Self.selectedTrackRefs(observedRows),
                  oldSelection.contains(originalRef) else { return nil }
            return observedSelection == oldSelection
        case .transportMotion:
            guard let oldData = try? JSONSerialization.data(withJSONObject: before),
                  let observedData = try? JSONSerialization.data(withJSONObject: after),
                  let old = QualificationTransport.recordedTransportMotion(String(decoding: oldData, as: UTF8.self)),
                  let observed = QualificationTransport.recordedTransportMotion(String(decoding: observedData, as: UTF8.self)) else { return nil }
            return old == observed
        case .transportToggle(let field):
            guard let old = Self.transportState(before)?[field] as? Bool,
                  let observed = Self.transportState(after)?[field] as? Bool else { return nil }
            return old == observed
        case .tempo:
            guard let old = Self.transportState(before)?["tempo"] as? Double,
                  let observed = Self.transportState(after)?["tempo"] as? Double else { return nil }
            return old == observed
        case .playheadStep:
            guard let old = QualificationTransport.recordedExactStepPosition(before),
                  let observed = QualificationTransport.recordedExactStepPosition(after) else { return nil }
            return old == observed
        case .playheadPosition:
            guard let old = Self.bar(before), let observed = Self.bar(after) else { return nil }
            return old == observed
        case .markerNames:
            guard let old = Self.markerNames(before),
                  let observed = Self.markerNames(after) else { return nil }
            return old == observed
        case .ownedFileArtifact:
            guard let old = Self.ownedFileArtifact(before),
                  let observed = Self.ownedFileArtifact(after),
                  old.path == observed.path else { return nil }
            return old.exists == observed.exists
        case .trackCreate, .trackDelete:
            return nil
        }
    }

    var verifiedCycleShape: Bool {
        guard let operation = OperationID(rawValue: operationID),
              let policy = QualificationTransport.mutationRestorePolicy(for: operation) else {
            return false
        }
        return verifiedCycleShape(using: policy)
    }

    func verifiedCycleShape(using policy: QualificationMutationRestorePolicy) -> Bool {
        guard policy.isValid,
              readingThatDidNotHappen == nil,
              mutationMovedRecipeValue(using: policy),
              restoreMatchesPreState(using: policy) else { return false }
        if policy == .ownedFileArtifact {
            guard let readback = Self.envelope(readback),
                  let artifact = Self.ownedFileArtifact(readback) else { return false }
            return Self.ownedFileMutationResponse(mutation, expected: artifact)
                && Self.ownedFileRestoreResponse(restore, expectedPath: artifact.path)
        }
        return Self.writeResponse(mutation) && Self.writeResponse(restore)
    }

    private static func envelope(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func track(_ envelope: [String: Any], index: Int) -> [String: Any]? {
        guard let rows = envelope["data"] as? [[String: Any]], rows.indices.contains(index) else {
            return nil
        }
        return rows[index]
    }

    private static func selectedTrackRefs(_ rows: [[String: Any]]) -> [String]? {
        var selected: [String] = []
        for row in rows where (row["isSelected"] as? Bool) == true {
            guard let ref = row["track_ref"] as? String, !ref.isEmpty else { return nil }
            selected.append(ref)
        }
        return selected.sorted()
    }

    private static func transportState(_ envelope: [String: Any]) -> [String: Any]? {
        (envelope["data"] as? [String: Any])?["state"] as? [String: Any]
    }

    private static func bar(_ envelope: [String: Any]) -> Int? {
        guard let position = transportState(envelope)?["position"] as? String,
              let first = position.split(separator: ".").first else { return nil }
        return Int(first)
    }

    private static func markerNames(_ envelope: [String: Any]) -> [String]? {
        guard let rows = envelope["data"] as? [[String: Any]] else { return nil }
        let names = rows.compactMap { $0["name"] as? String }
        return names.count == rows.count ? names.sorted() : nil
    }

    /// A verifier-owned filesystem artifact is a valid observation only in one of two complete
    /// states: absent, or present with a non-empty independently checked manifest. This keeps a
    /// bare `exists:true` (or the operation's own manifest echoed back as if it were a read) from
    /// becoming Phase-B credit.
    private static func ownedFileArtifact(
        _ envelope: [String: Any]
    ) -> (path: String, exists: Bool, files: [String: String])? {
        guard envelope["source"] as? String == "host_filesystem",
              envelope["readable"] as? Bool == true,
              let data = envelope["data"] as? [String: Any],
              let path = data["path"] as? String, path.hasPrefix("/"),
              let exists = data["exists"] as? Bool,
              let verified = data["manifest_verified"] as? Bool,
              let files = data["files"] as? [[String: Any]] else { return nil }
        if !exists {
            guard !verified, files.isEmpty else { return nil }
            return (path, false, [:])
        }
        guard verified, let manifest = ownedFileManifest(files) else { return nil }
        return (path, true, manifest)
    }

    private static func ownedFileManifest(
        _ files: [[String: Any]]
    ) -> [String: String]? {
        guard !files.isEmpty else { return nil }
        var names = Set<String>()
        var manifest: [String: String] = [:]
        for file in files {
            guard let name = file["name"] as? String,
                  (try? SecureFD.validateComponent(name)) != nil,
                  names.insert(name).inserted,
                  let digest = file["sha256"] as? String,
                  digest.count == 64,
                  digest.utf8.allSatisfy({
                      (48...57).contains($0) || (97...102).contains($0)
                  }) else { return nil }
            manifest[name] = digest
        }
        guard names == Set(SupportBundleBuilder.fileNames) else { return nil }
        return manifest
    }

    private static func ownedFileMutationResponse(
        _ raw: String,
        expected: (path: String, exists: Bool, files: [String: String])
    ) -> Bool {
        guard expected.exists,
              let response = envelope(raw),
              response["state"] as? String == "A",
              response["bundle_path"] as? String == expected.path,
              let rows = response["files"] as? [[String: Any]],
              ownedFileManifest(rows) == expected.files else { return false }
        return true
    }

    private static func ownedFileRestoreResponse(_ raw: String, expectedPath: String) -> Bool {
        guard let response = envelope(raw) else { return false }
        return response["state"] as? String == "A"
            && response["verified"] as? Bool == true
            && response["write_attempted"] as? Bool == true
            && response["operation"] as? String == "host_filesystem.remove_owned_support_bundle"
            && response["path"] as? String == expectedPath
    }

    private static func trackRefs(_ envelope: [String: Any]) -> [String]? {
        guard let rows = envelope["data"] as? [[String: Any]] else { return nil }
        let refs = rows.compactMap { $0["track_ref"] as? String }
        return refs.count == rows.count ? refs : nil
    }

    private static func writeResponse(_ raw: String) -> Bool {
        guard let response = envelope(raw) else { return false }
        if let state = response["state"] as? String { return state == "A" || state == "B" }
        return response["success"] as? Bool == true
    }

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case preState = "pre_state"
        case mutation
        case readback
        case restore
        case restoreReadback = "restore_readback"
        case stagingMutation = "staging_mutation"
        case stagingReadback = "staging_readback"
    }
}
