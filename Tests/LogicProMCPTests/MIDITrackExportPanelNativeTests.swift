@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private let midiPanelRecoveryFixture = ProcessInfo.processInfo.environment["CONDUCTOR_MIDI_PANEL_RECOVERY_FIXTURE"]

@Test("native MIDI Save panel recovers from a stalled directory transition",
      .enabled(if: midiPanelRecoveryFixture != nil,
               "Set CONDUCTOR_MIDI_PANEL_RECOVERY_FIXTURE to the open disposable probe project."))
@MainActor
func midiExportPanelNativeTimeoutRecovery() async throws {
    let fixture = try #require(midiPanelRecoveryFixture)
    let expected = URL(fileURLWithPath: fixture).standardizedFileURL
    try #require(expected.lastPathComponent == "Conductor 1122 MIDI Recovery Fixture.logicx")
    let runtime = AXLogicProElements.Runtime.production
    _ = ProcessUtils.activateLogicPro()

    let window = try #require(AXLogicProElements.mainWindow(runtime: runtime))
    let observedDocument = try AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime).get()
    let document = try #require(observedDocument)
    try #require(URL(string: document)?.standardizedFileURL == expected)
    try #require(AXLogicProElements.dialogPresenceReason(runtime: runtime) == .noBlockingWindow)
    let temporary = try ExportTemporaryFiles.temporaryExportFile()
    defer { ExportTemporaryFiles.cleanupTemporaryExportFile(temporary) }

    var returns = 0
    var escapes = 0
    let keyboard = MIDITrackExportPanel.Keyboard { key, flags in
        if key == 36 {
            returns += 1
            return true // Keep the real Go to Folder sheet open through the timeout.
        }
        if key == 53 { escapes += 1 }
        return MIDITrackExportPanel.Keyboard.production.post(key, flags)
    }
    // The shipped panel driver binds the project and separately verifies the
    // keyboard owner for every key. The native test supplies the single caller.
    let panel = MIDITrackExportPanel(window: window, document: document, keyboard: keyboard) {
        !Task.isCancelled
    }
    do {
        try await panel.exportAll(to: temporary.fileURL)
        Issue.record("The deliberately stalled native export reported success.")
    } catch {
        #expect(error as? MIDITrackExportPanel.Failure
            == .recovered("directory_navigation:panel_transition_not_observed:directory_navigation"))
    }

    #expect(returns == 1 && escapes == 1)
    #expect(!FileManager.default.fileExists(atPath: temporary.fileURL.path))
    #expect(AXLogicProElements.dialogPresenceReason(runtime: runtime) == .noBlockingWindow)
    let current = try #require(AXLogicProElements.mainWindow(runtime: runtime))
    #expect(CFEqual(current, window))
}
