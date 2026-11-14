import Foundation

struct ProjectIsolatedStemExportResult: Sendable {
    let outcome: ProjectStemExportPanelDriver.Outcome
    let directory: String?
    let files: [String]
}

enum ProjectIsolatedStemExport {
    static func live(root: String, expectedCount: Int) async -> ProjectIsolatedStemExportResult {
        let witness: ProjectStemExportFileWitness
        do {
            witness = try ProjectStemExportFileWitness(root: root, expectedCount: expectedCount)
        } catch {
            return .init(outcome: .refused("stem_isolated_destination_unavailable: \(error)"), directory: nil, files: [])
        }
        let outcome = await ProjectStemExportPanelDriver.drive(
            destination: witness.directory,
            surface: AXSurface(),
            progressPollAttempts: 80,
            sleep: { try? await Task.sleep(nanoseconds: $0) },
            pollIntervalNanos: 250_000_000,
            artifactCompletion: { witness.observe() }
        )
        guard outcome == .completed else {
            return .init(outcome: outcome, directory: witness.directory, files: [])
        }
        // A visible progress round trip is useful UI evidence, but still needs
        // complete files. This also handles the last container-header flush.
        for _ in 0..<20 {
            if witness.observe() {
                return .init(outcome: .completed, directory: witness.directory, files: witness.files)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return .init(
            outcome: .uncertain("stem_isolated_files_not_complete_after_export", exportEffectObserved: true),
            directory: witness.directory,
            files: []
        )
    }
}
