import Foundation

extension ProjectExportExecutor {
    static func overwriteBlockedArtifact(
        _ artifact: ProjectExportPlanArtifact,
        plan: ProjectExportPlan,
        options: Options
    ) -> RunArtifact? {
        guard plan.collisionPolicy == "fail_if_exists" else { return nil }
        if artifact.filenamesLateBound == true {
            let existingAudio = ProjectExportArtifactPathPolicy.supportedAudioEntries(
                in: artifact.destination ?? artifact.path,
                fileManager: options.fileManager
            )
            switch existingAudio {
            case .unreadable(let reason):
                return failedArtifact(
                    artifact,
                    error: "overwrite_check_unavailable: collision_policy=fail_if_exists requires a readable late-bound stem destination: \(reason)"
                )
            case .files(let files) where !files.isEmpty:
                return failedArtifact(
                    artifact,
                    error: "overwrite_blocked: collision_policy=fail_if_exists and the late-bound stem destination contains \(files.count) suffix-qualified top-level audio entry/entries"
                )
            case .files:
                break
            }
            return artifact.verification.wouldOverwrite
                ? failedArtifact(
                    artifact,
                    error: "overwrite_blocked: collision_policy=fail_if_exists and the late-bound stem destination already contained audio at plan time"
                )
                : nil
        }
        switch ProjectExportArtifactPathPolicy.preferredExistingVariant(
            for: artifact.path,
            fileManager: options.fileManager
        ) {
        case .found(let blockingPath):
            return failedArtifact(
                artifact,
                error: "overwrite_blocked: collision_policy=\(plan.collisionPolicy) and artifact already exists at \(blockingPath)"
            )
        case .unreadable(let reason):
            return failedArtifact(
                artifact,
                error: "overwrite_check_unavailable: collision_policy=\(plan.collisionPolicy) requires a readable destination: \(reason)"
            )
        case .absent:
            break
        }
        if artifact.verification.wouldOverwrite {
            return failedArtifact(
                artifact,
                error: "overwrite_blocked: collision_policy=\(plan.collisionPolicy) and artifact already exists"
            )
        }
        return nil
    }

    static func preflightArtifactOutcome(
        _ artifact: ProjectExportPlanArtifact,
        plan: ProjectExportPlan,
        options: Options
    ) -> RunArtifact? {
        if let overwriteBlocked = overwriteBlockedArtifact(artifact, plan: plan, options: options) {
            return overwriteBlocked
        }
        if artifact.filenamesLateBound == true {
            guard artifact.verification.issues.isEmpty else {
                return failedArtifact(
                    artifact,
                    error: artifact.planningReason ?? "late_bound_stem_blocked: \(artifact.verification.issues.joined(separator: ","))"
                )
            }
            return nil
        }
        if artifact.verification.exists {
            guard artifact.verification.issues.isEmpty else {
                return failedArtifact(
                    artifact,
                    error: "artifact_blocked: \(artifact.verification.issues.joined(separator: ","))"
                )
            }
            return skippedArtifact(artifact, options: options, outputRoot: plan.outputRoot)
        }
        guard artifact.verification.issues.isEmpty else {
            return failedArtifact(
                artifact,
                error: "artifact_blocked: \(artifact.verification.issues.joined(separator: ","))"
            )
        }
        return nil
    }

    static func produceArtifacts(
        artifact: ProjectExportPlanArtifact,
        projectPath: String,
        plan: ProjectExportPlan,
        router: ChannelRouter,
        options: Options
    ) async -> [RunArtifact] {
        if artifact.filenamesLateBound == true {
            return await produceStem(artifact: artifact, plan: plan, options: options)
        }
        return [await produce(artifact: artifact, projectPath: projectPath, plan: plan, router: router, options: options)]
    }

    private static func produce(
        artifact: ProjectExportPlanArtifact,
        projectPath: String,
        plan: ProjectExportPlan,
        router: ChannelRouter,
        options: Options
    ) async -> RunArtifact {
        if let overwriteBlocked = overwriteBlockedArtifact(artifact, plan: plan, options: options) {
            return overwriteBlocked
        }
        if !artifact.verification.issues.isEmpty {
            return failedArtifact(
                artifact,
                error: "artifact_blocked: \(artifact.verification.issues.joined(separator: ","))"
            )
        }

        let producedPath: String
        if options.bounceToPath != nil || options.driveNativeBounce != nil || artifact.bounceSettings != nil {
            guard OperationTraceContext.claimDeadlineEffect("project_export_bounce") else {
                return failedArtifact(
                    artifact,
                    error: "deadline_won_before_bounce",
                    bounceFired: false
                )
            }
            let nativeResult: BounceHelperResult?
            if artifact.kind == "bounce", let native = options.driveNativeBounce {
                nativeResult = await native(artifact.path, projectPath, artifact.bounceSettings)
            } else {
                nativeResult = nil
            }
            let bounceResult: BounceHelperResult
            if let nativeResult {
                bounceResult = nativeResult
            } else if artifact.bounceSettings != nil {
                bounceResult = .failure("explicit_pcm_bounce_requires_logic_13")
            } else if let legacy = options.bounceToPath {
                bounceResult = await legacy(artifact.path)
            } else {
                bounceResult = .failure("bounce_route_unavailable")
            }
            guard let produced = bounceResult.artifactPath else {
                let uncertain = nativeResult != nil && bounceResult.bounceFired
                let prefix = nativeResult == nil ? "bounce_helper_failed" : "bounce_failed"
                let detail = "\(prefix): \(bounceResult.error ?? "no verified artifact produced for \(artifact.path)")"
                return RunArtifact(
                    kind: artifact.kind,
                    path: artifact.path,
                    state: uncertain ? "B" : "C",
                    verified: false,
                    bounceFired: bounceResult.bounceFired,
                    writeAttempted: bounceResult.bounceFired,
                    error: uncertain ? nil : detail,
                    reason: uncertain ? detail : nil,
                    evidence: nil
                )
            }
            guard ProjectExportArtifactPathPolicy.helperProducedPathMatchesPlannedStem(
                producedPath: produced,
                plannedPath: artifact.path
            ) else {
                return failedArtifact(
                    artifact,
                    error: "bounce_helper_unexpected_artifact_path: expected stem \(ProjectExportArtifactPathPolicy.standardizedStemPath(artifact.path)) but helper returned \(produced)",
                    bounceFired: true
                )
            }
            producedPath = produced
        } else {
            let bounceResult = await router.route(operation: "project.bounce")
            guard bounceResult.isSuccess else {
                return RunArtifact(
                    kind: artifact.kind,
                    path: artifact.path,
                    state: "C",
                    verified: false,
                    bounceFired: false,
                    writeAttempted: false,
                    error: "bounce_failed: \(bounceResult.message)",
                    reason: nil,
                    evidence: nil
                )
            }
            let appeared = await waitForArtifact(path: artifact.path, options: options)
            guard appeared else {
                return RunArtifact(
                    kind: artifact.kind,
                    path: artifact.path,
                    state: "B",
                    verified: false,
                    bounceFired: true,
                    writeAttempted: true,
                    error: nil,
                    reason: "artifact_not_observed_within_poll_window",
                    evidence: nil
                )
            }
            producedPath = artifact.path
        }

        let analysis = options.analyze(producedPath, analysisPolicy(plan: plan, options: options))
        if analysis.verification.reasons.contains("unsafe_path") {
            return failedArtifact(
                artifact,
                error: "artifact_path_unsafe: \(analysis.verification.detail ?? analysis.verification.reasons.joined(separator: ","))",
                bounceFired: true
            )
        }
        if let settings = artifact.bounceSettings, !settings.matchesFile(producedPath) {
            return failedArtifact(artifact, error: "rendered_pcm_settings_mismatch", bounceFired: true)
        }
        let evidence = ArtifactEvidence(from: analysis, source: "audio_analyzer")
        if analysis.verification.status == .pass {
            return RunArtifact(
                kind: artifact.kind,
                path: producedPath,
                state: "A",
                verified: true,
                bounceFired: true,
                writeAttempted: true,
                error: nil,
                reason: nil,
                evidence: evidence
            )
        }
        return RunArtifact(
            kind: artifact.kind,
            path: producedPath,
            state: "B",
            verified: false,
            bounceFired: true,
            writeAttempted: true,
            error: nil,
            reason: "artifact_unverified: \(analysis.verification.reasons.joined(separator: ","))",
            evidence: evidence
        )
    }

    /// Produce a stem batch exactly once, then record the eligible files in
    /// the destination's before/after delta. The file list is observed only
    /// after the progress window disappears; it is never fabricated from track
    /// names or mistaken for a filename-to-subject binding.
    private static func produceStem(
        artifact: ProjectExportPlanArtifact,
        plan: ProjectExportPlan,
        options: Options
    ) async -> [RunArtifact] {
        var destination = artifact.destination ?? artifact.path
        guard let subjects = artifact.subjects, !subjects.isEmpty else {
            return [failedArtifact(
                artifact,
                error: "stem_subject_list_unavailable_at_execution: refusing export without populated-track subjects"
            )]
        }
        guard artifact.verification.issues.isEmpty else {
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "C",
                bounceFired: false,
                writeAttempted: false,
                error: artifact.planningReason ?? "late_bound_stem_blocked: \(artifact.verification.issues.joined(separator: ","))",
                reason: nil,
                observations: nil
            )
        }
        guard options.driveStemExport != nil || options.driveIsolatedStemExport != nil else {
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "C",
                bounceFired: false,
                writeAttempted: false,
                error: "stem_export_panel_unavailable: refusing to use project.bounce for a stem artifact",
                reason: nil,
                observations: nil
            )
        }
        // The plan's collision read can become stale before the panel opens.
        // This later, immediately-pre-export snapshot is authoritative: if it
        // is no longer empty under fail_if_exists, do not drive the panel.
        let before: [String]
        switch ProjectExportArtifactPathPolicy.supportedAudioEntries(
            in: destination,
            fileManager: options.fileManager
        ) {
        case .files(let files) where plan.collisionPolicy == "fail_if_exists" && !files.isEmpty:
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "C",
                bounceFired: false,
                writeAttempted: false,
                error: "overwrite_blocked: collision_policy=fail_if_exists and the authoritative immediately-pre-export stem snapshot contains \(files.count) suffix-qualified top-level audio entry/entries",
                reason: nil,
                observations: nil
            )
        case .files(let files):
            before = files
        case .unreadable(let reason):
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "C",
                bounceFired: false,
                writeAttempted: false,
                error: "stem_output_snapshot_unavailable_before_export: \(reason)",
                reason: nil,
                observations: nil
            )
        }

        let subjectBindingVerified: Bool
        if let projectPath = plan.projects.first?.projectPath, let verify = options.verifyIsolatedSubjectBinding {
            subjectBindingVerified = await verify(projectPath, subjects)
        } else { subjectBindingVerified = false }
        if artifact.stemSettings != nil,
           !(subjectBindingVerified && ProjectAlignedStemSettings.namesQualify(subjects)
                && options.driveAlignedStemExport != nil) {
            return stemSubjectArtifacts(artifact: artifact, destination: destination, subjects: subjects,
                state: "C", bounceFired: false, writeAttempted: false,
                error: "aligned_stem_subjects_or_host_unavailable", reason: nil, observations: nil)
        }
        guard OperationTraceContext.claimDeadlineEffect("project_export_stem") else {
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "C",
                bounceFired: false,
                writeAttempted: false,
                error: "deadline_won_before_stem_export",
                reason: nil,
                observations: nil
            )
        }
        let outcome: ProjectStemExportPanelDriver.Outcome
        var isolatedFiles: [String] = []
        if let settings = artifact.stemSettings, let drive = options.driveAlignedStemExport,
           let projectPath = plan.projects.first?.projectPath {
            let receipt = await drive(destination, settings, subjects, projectPath)
            outcome = receipt.outcome
            if let actualDirectory = receipt.directory { destination = actualDirectory }
            isolatedFiles = receipt.files
        } else if let drive = options.driveIsolatedStemExport {
            let receipt = await drive(destination, subjects.count)
            outcome = receipt.outcome
            if let actualDirectory = receipt.directory { destination = actualDirectory }
            isolatedFiles = receipt.files
        } else if let drive = options.driveStemExport {
            outcome = await drive(destination)
        } else {
            // The availability gate above makes this unreachable.
            return [failedArtifact(artifact, error: "stem_export_panel_unavailable")]
        }
        switch outcome {
        case .refused(let error):
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "C",
                bounceFired: false,
                writeAttempted: false,
                error: error,
                reason: nil,
                observations: nil
            )
        case let .uncertain(reason, exportEffectObserved):
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "B",
                // A status-success AXPress is not evidence that the export
                // fired. `bounceFired` is true only when the driver observed
                // the progress dialog after the press. `writeAttempted` records
                // the distinct fact that the driver had reached the Export
                // actuator before this post-press observation phase.
                bounceFired: exportEffectObserved,
                writeAttempted: true,
                error: nil,
                reason: reason,
                observations: nil
            )
        case .completed:
            break
        }

        if artifact.stemSettings != nil {
            let observations = isolatedFiles.map {
                stemOutputObservation(path: $0, plan: plan, options: options, allowsSilentOutput: true)
            }
            var byTrack: [String: ProjectExportObservedStemOutput] = [:]
            for output in observations {
                let key = URL(fileURLWithPath: output.path).lastPathComponent
                guard output.verified, byTrack.updateValue(output, forKey: key) == nil else {
                    return stemSubjectArtifacts(artifact: artifact, destination: destination, subjects: subjects,
                        state: "B", bounceFired: true, writeAttempted: true, error: nil,
                        reason: "aligned_stem_output_not_verified", observations: observations)
                }
            }
            let paired = subjects.compactMap { byTrack[$0.name + ".wav"] }
            let rate = observations.first?.evidence.sampleRate
            let frames = observations.first?.evidence.frameCount
            guard paired.count == subjects.count, paired.count == observations.count, let rate, let frames,
                  paired.allSatisfy({
                      $0.evidence.sampleRate == rate && $0.evidence.frameCount == frames
                          && ProjectPCMBounceSettings.isStemWAVE24($0.path, sampleRate: rate)
                  }) else {
                return stemSubjectArtifacts(artifact: artifact, destination: destination, subjects: subjects,
                    state: "B", bounceFired: true, writeAttempted: true, error: nil,
                    reason: "aligned_stem_name_binding_or_common_length_unverified", observations: observations)
            }
            return zip(subjects, paired).map { subject, output in
                RunArtifact(kind: artifact.kind, path: output.path, state: "A", verified: true,
                            bounceFired: true, writeAttempted: true, error: nil, reason: nil,
                            evidence: output.evidence, subject: subject, observedStemOutputs: [output])
            }
        }

        // A sole planned populated subject and a sole complete file in a
        // newly allocated, independently panel-confirmed namespace provide a
        // binding without guessing filenames. General multi-subject mapping
        // still remains explicitly unverified below.
        if subjectBindingVerified, subjects.count == 1, isolatedFiles.count == 1 {
            let observed = stemOutputObservation(path: isolatedFiles[0], plan: plan, options: options)
            return [RunArtifact(
                kind: artifact.kind,
                path: observed.path,
                state: observed.verified ? "A" : "B",
                verified: observed.verified,
                bounceFired: true,
                writeAttempted: true,
                error: nil,
                reason: observed.reason,
                evidence: observed.evidence,
                subject: subjects[0],
                observedStemOutputs: [observed]
            )]
        }

        let after: [String]
        switch ProjectExportArtifactPathPolicy.supportedAudioEntries(
            in: destination,
            fileManager: options.fileManager
        ) {
        case .files(let files):
            after = files
        case .unreadable(let reason):
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "B",
                bounceFired: true,
                writeAttempted: true,
                error: nil,
                reason: "stem_output_snapshot_unavailable_after_export: \(reason)",
                observations: nil
            )
        }

        let beforeSet = Set(before)
        let appeared = after.filter { !beforeSet.contains($0) }
        let observations = appeared.map {
            stemOutputObservation(path: $0, plan: plan, options: options)
        }
        let reason: String
        if appeared.isEmpty {
            reason = "stem_audio_files_not_observed_after_progress_completion: observed=0 expected=\(subjects.count)"
        } else if appeared.count != subjects.count {
            reason = "stem_subject_count_mismatch: observed=\(appeared.count) expected=\(subjects.count); file-to-subject binding and output attribution were not established, so post-snapshot entries may have been created concurrently"
        } else {
            reason = "stem_subject_file_binding_unestablished: observed=\(appeared.count) expected=\(subjects.count); filenames are late-bound, no name-matching rule is used, and post-snapshot entries may have been created concurrently"
        }
        // One result per populated track is preserved, but none is promoted to
        // State A: the observed output list has no evidence that a particular
        // file belongs to a particular subject. The observations carry the
        // real per-file analyzer results without inventing that association.
        return stemSubjectArtifacts(
            artifact: artifact,
            destination: destination,
            subjects: subjects,
            state: "B",
            bounceFired: true,
            writeAttempted: true,
            error: nil,
            reason: reason,
            observations: observations
        )
    }

    private static func stemOutputObservation(
        path: String,
        plan: ProjectExportPlan,
        options: Options,
        allowsSilentOutput: Bool = false
    ) -> ProjectExportObservedStemOutput {
        var policy = analysisPolicy(plan: plan, options: options)
        policy.allowsSilentOutput = allowsSilentOutput
        let analysis = options.analyze(path, policy)
        let evidence = ArtifactEvidence(from: analysis, source: "audio_analyzer")
        if analysis.verification.reasons.contains("unsafe_path") {
            return ProjectExportObservedStemOutput(
                path: path,
                verified: false,
                reason: "artifact_path_unsafe: \(analysis.verification.detail ?? analysis.verification.reasons.joined(separator: ","))",
                evidence: evidence
            )
        }
        if analysis.verification.status == .pass {
            return ProjectExportObservedStemOutput(
                path: path,
                verified: true,
                reason: nil,
                evidence: evidence
            )
        }
        return ProjectExportObservedStemOutput(
            path: path,
            verified: false,
            reason: "artifact_unverified: \(analysis.verification.reasons.joined(separator: ","))",
            evidence: evidence
        )
    }

    static func stemSubjectArtifacts(
        artifact: ProjectExportPlanArtifact,
        destination: String,
        subjects: [ProjectExportStemSubject],
        state: String,
        bounceFired: Bool,
        writeAttempted: Bool,
        error: String?,
        reason: String?,
        observations: [ProjectExportObservedStemOutput]?
    ) -> [RunArtifact] {
        subjects.map { subject in
            RunArtifact(
                kind: artifact.kind,
                path: destination,
                state: state,
                verified: false,
                bounceFired: bounceFired,
                writeAttempted: writeAttempted,
                error: error,
                reason: reason,
                evidence: nil,
                subject: subject,
                observedStemOutputs: observations
            )
        }
    }

    /// A late-bound stem has one result per requested subject even when it
    /// refuses before the panel opens.  An unscoped preflight result would
    /// otherwise change result cardinality merely because it ran early.
    static func subjectScopedArtifacts(
        _ result: RunArtifact,
        for artifact: ProjectExportPlanArtifact
    ) -> [RunArtifact] {
        guard artifact.filenamesLateBound == true,
              let subjects = artifact.subjects,
              !subjects.isEmpty else {
            return [result]
        }
        return subjects.map { subject in
            RunArtifact(
                kind: result.kind,
                path: result.path,
                state: result.state,
                verified: result.verified,
                bounceFired: result.bounceFired,
                writeAttempted: result.writeAttempted,
                error: result.error,
                reason: result.reason,
                evidence: result.evidence,
                subject: subject,
                observedStemOutputs: result.observedStemOutputs
            )
        }
    }

    static func analysisPolicy(plan: ProjectExportPlan, options: Options) -> AudioAnalyzer.AnalysisPolicy {
        var policy = AudioAnalyzer.AnalysisPolicy.default
        policy.outputRoot = plan.outputRoot
        policy.minimumDurationSeconds = options.minimumDurationSeconds
        policy.minimumFileSizeBytes = 1
        return policy
    }

    static func waitForArtifact(path: String, options: Options) async -> Bool {
        var attempt = 0
        while attempt < max(1, options.pollAttempts) {
            var isDir: ObjCBool = false
            if options.fileManager.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                return true
            }
            attempt += 1
            if attempt < options.pollAttempts {
                await options.sleep(options.pollIntervalNanos)
            }
        }
        var isDir: ObjCBool = false
        return options.fileManager.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    static func skippedArtifact(
        _ artifact: ProjectExportPlanArtifact,
        options: Options,
        outputRoot: String
    ) -> RunArtifact {
        guard artifact.verification.exists,
              artifact.verification.issues.isEmpty else {
            return RunArtifact(
                kind: artifact.kind,
                path: artifact.path,
                state: "C",
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: "skip_precondition_failed",
                reason: nil,
                evidence: nil
            )
        }
        let existingPath: String
        switch ProjectExportArtifactPathPolicy.preferredExistingVariant(
            for: artifact.path,
            fileManager: options.fileManager
        ) {
        case .found(let path):
            existingPath = path
        case .absent:
            return RunArtifact(
                kind: artifact.kind,
                path: artifact.path,
                state: "C",
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: "skip_precondition_failed",
                reason: nil,
                evidence: nil
            )
        case .unreadable(let reason):
            return RunArtifact(
                kind: artifact.kind,
                path: artifact.path,
                state: "C",
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: "skip_precondition_unavailable: \(reason)",
                reason: nil,
                evidence: nil
            )
        }
        var policy = AudioAnalyzer.AnalysisPolicy.default
        policy.outputRoot = outputRoot
        policy.minimumDurationSeconds = options.minimumDurationSeconds
        policy.minimumFileSizeBytes = 1
        let analysis = options.analyze(existingPath, policy)
        if analysis.verification.reasons.contains("unsafe_path") {
            return RunArtifact(
                kind: artifact.kind,
                path: existingPath,
                state: "C",
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: "existing_artifact_path_unsafe: \(analysis.verification.detail ?? analysis.verification.reasons.joined(separator: ","))",
                reason: nil,
                evidence: nil
            )
        }
        let evidence = ArtifactEvidence(from: analysis, source: "skip_reverify")
        if artifact.bounceSettings != nil {
            return RunArtifact(kind: artifact.kind, path: existingPath, state: "B", verified: false,
                               bounceFired: false, writeAttempted: false, error: nil,
                               reason: "existing_bounce_settings_provenance_unavailable", evidence: evidence)
        }
        guard analysis.verification.status == .pass else {
            return RunArtifact(
                kind: artifact.kind,
                path: existingPath,
                state: "B",
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: nil,
                reason: "existing_artifact_unverified: \(analysis.verification.reasons.joined(separator: ","))",
                evidence: evidence
            )
        }
        return RunArtifact(
            kind: artifact.kind,
            path: existingPath,
            state: "A",
            verified: true,
            bounceFired: false,
            writeAttempted: false,
            error: nil,
            reason: "skipped_already_verified",
            evidence: evidence
        )
    }

    static func failedArtifact(
        _ artifact: ProjectExportPlanArtifact,
        error: String,
        bounceFired: Bool = false
    ) -> RunArtifact {
        RunArtifact(
            kind: artifact.kind,
            path: artifact.path,
            state: "C",
            verified: false,
            bounceFired: bounceFired,
            writeAttempted: bounceFired,
            error: error,
            reason: nil,
            evidence: nil
        )
    }
}
