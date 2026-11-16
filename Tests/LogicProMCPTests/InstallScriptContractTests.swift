import Foundation
import Testing
@testable import LogicProMCP

@Test func testDiscordLinkStaysOutOfReadmeButRemainsInSupportDocs() throws {
    let discord = "https://discord.gg/4M3s79DBzz"
    let readme = try scriptContents("README.md")

    #expect(!readme.contains(discord), "README.md should not carry the Discord community link")

    for path in ["docs/SETUP.md", "docs/TROUBLESHOOTING.md", "CONTRIBUTING.md"] {
        #expect(try scriptContents(path).contains(discord), "\(path) must link the official Discord (\(discord))")
    }
}

@Test func testCoverageGateFailsClosed() throws {
    let gate = try scriptContents("Scripts/ci-coverage-gate.sh")
    #expect(gate.contains("set -euo pipefail"))
    #expect(gate.contains("LPM_COVERAGE_MIN_REGION:-70"))
    #expect(gate.contains("LPM_COVERAGE_MIN_LINE:-78"))
    #expect(gate.contains("LPM_COVERAGE_TARGET:-90"))
    #expect(!gate.contains("set " + "+e"))
}

/// The marker rename's Edit button must be resolved by DESCRIPTION.
///
/// This is a source contract rather than a behavioural one because the script is built inside
/// `renameSelectedMarker`, which takes a live `AXUIElement` and offers no seam to capture it. The
/// generator itself is tested in `Issue519MenuLocaleGeneratorTests`; what this pins is that the
/// call site uses the right generator.
///
/// It exists because the wrong one was used and nothing noticed: `candidateResolution(
/// elementKeyword: "button", ...)` emits a BY-NAME reference, which is correct for a dialog's
/// Cancel and wrong for a Logic toolbar button whose AXTitle is empty. Measured on a running Logic
/// 12.3 on 2026-09-18 through System Events: 412 of 439 buttons report `name` as `missing value`,
/// none of the 27 that have a name carries an Edit-family label, and asked of one container both
/// ways for the same button, by-name is false where by-description is true. The rename would have
/// returned MARKER_EDIT_BUTTON_NOT_FOUND in every locale, including the two that worked before.
@Test func testMarkerRenameResolvesItsEditButtonByDescription() throws {
    let source = try scriptContents("Sources/LogicProMCP/Channels/AccessibilityChannel+MarkerNaming.swift")

    #expect(source.contains("AppleScriptMenuResolution.buttonWithDescription("))
    #expect(!source.contains("elementKeyword: \"button\""),
            "a by-name reference cannot find a button whose label is its AXDescription")
    // The group beside it has always been resolved this way; the two must not drift apart again.
    #expect(source.contains("AppleScriptMenuResolution.groupWithDescription("))
}

@Test func testLiveE2EHarnessRoutesCoverageProfilesToWritableTempDir() throws {
    let python = try scriptContents("Scripts/live-e2e-test.py")
    let shell = try scriptContents("Scripts/live-e2e-test.sh")

    #expect(python.contains("def coverage_environment():"))
    #expect(python.contains("LOGIC_PRO_MCP_PROFILE_DIR"))
    #expect(python.contains("LLVM_PROFILE_FILE"))
    #expect(python.contains("%m-%p.profraw"))
    #expect(python.contains("env=coverage_environment()"))
    #expect(python.contains("export LLVM_PROFILE_FILE="))

    #expect(shell.contains("LOGIC_PRO_MCP_PROFILE_DIR"))
    #expect(shell.contains("LLVM_PROFILE_FILE"))
    #expect(shell.contains("%m-%p.profraw"))
    #expect(shell.contains("export LLVM_PROFILE_FILE"))
}

@Test func testStrictLiveE2EBridgeUsesRawStdIOCaptureInsteadOfPaneMirroring() throws {
    let shell = try scriptContents("Scripts/live-e2e-test.sh")

    #expect(shell.contains("tee -a ${CAPTURE_FILE_COMMAND}"))
    #expect(!shell.contains("capture-pane -t \"$SESSION\""))
    #expect(!shell.contains("tmux send-keys -t \"$SESSION\" -l"))
    #expect(!shell.contains("CAPTURE_PID"))
    #expect(!shell.contains("SENDER_PID"))
}

@Test func testScriptsFolderNoLongerShipsOneOffSpikeHarnesses() {
    let root = installScriptContractRepositoryRootURL()
    let legacyPaths = [
        "Scripts/analysis-to-logic.py",
        "Scripts/issue7_live_verify.sh",
        "Scripts/probes/library-ax-probe.swift",
        "Scripts/probes/plugin-detective.swift",
        "Scripts/probes/plugin-menu-ax-probe.swift",
        "Scripts/probes/setting-popup-probe.swift",
    ]

    for relativePath in legacyPaths {
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path),
            "\(relativePath) was a one-off local/spike harness and must not ship in Scripts/"
        )
    }
}

@Test func testLocalReleaseScriptUsesCLTNativeQualificationAndHostedPublication() throws {
    let script = try scriptContents("Scripts/release.sh")

    #expect(script.contains("DEVELOPER_DIR=/Library/Developer/CommandLineTools"))
    #expect(script.contains("bash Scripts/release-qualify.sh"))
    #expect(script.contains("git diff --exit-code Package.resolved"))
    #expect(script.contains("set -euo pipefail"))
    #expect(script.contains("RUN_ID=\"${2:-}\""))
    #expect(script.contains("git ls-remote --tags origin"))
    #expect(script.contains("remote tag lookup failed; absence was not established"))
    #expect(script.contains("Scripts/release-verify-candidate.py run"))
    #expect(script.contains("Native-qualified: $QUALIFIED"))
    #expect(script.contains("Candidate-run-id: $RUN_ID"))
    #expect(script.contains("Candidate-run-attempt: $RUN_ATTEMPT"))
    #expect(script.contains("Candidate-artifact-id: $ARTIFACT_ID"))
    #expect(script.contains("Candidate-artifact-digest: $ARTIFACT_DIGEST"))
    #expect(script.contains("Candidate-manifest-sha256: $MANIFEST_SHA"))
    #expect(!script.contains("gh release create"))
    #expect(!script.contains("ADHOC"))
    #expect(!script.contains("codesign"))
}

@Test func testStableReleaseScriptPreflightsTagBeforePush() throws {
    let script = try scriptContents("Scripts/release-stable.sh")

    #expect(script.contains("release.sh"))
    #expect(script.contains("[ \"$#\" != 2 ]"))
    #expect(script.contains("[[ \"$2\" =~ ^[1-9][0-9]*$ ]]"))
    #expect(script.contains("Usage: $0 vMAJOR.MINOR.PATCH CANDIDATE_RUN_ID"))
    #expect(!script.contains("gh release view"))
    let validation = try #require(script.range(of: "[ \"$#\" != 2 ]"))
    let delegate = try #require(script.range(of: "exec bash \"$(dirname \"$0\")/release.sh\" \"$@\""))
    #expect(validation.lowerBound < delegate.lowerBound)
}

@Test func testUninstallScriptReportsUnverifiedLogicResidualsWithoutManualContinuation() throws {
    let script = try scriptContents("Scripts/uninstall.sh")
    let keyCommandUninstaller = try scriptContents("Scripts/uninstall-keycmds.sh")
    let launchAgentTemplate = try scriptContents("Scripts/com.logicpro.mcp.plist.template")

    #expect(script.contains("claude mcp remove logic-pro"))
    #expect(!script.contains("Manual command:"))
    #expect(!script.contains("Remove Scripter MIDI FX"))
    #expect(!script.contains("manually"))
    #expect(script.contains("Uninstall unsuccessful: Logic-resident Scripter/MCU state is unverified."))
    #expect(script.contains("APPROVAL_STORE"))
    #expect(script.contains("LOGIC_PRO_MCP_SHARE_DIR"))
    #expect(script.contains("Removed shared assets"))
    #expect(script.contains("Removed operator approvals"))
    #expect(script.contains("APPROVAL_LOCK"))
    #expect(script.contains("gui/$UID/com.logicpro.mcp"))
    #expect(script.contains("launchctl print \"$LAUNCH_AGENT_SERVICE\""))
    #expect(script.contains("launchctl bootout \"$LAUNCH_AGENT_SERVICE\""))
    #expect(script.contains("[ -e \"$LAUNCH_AGENT\" ] || [ -L \"$LAUNCH_AGENT\" ]"))
    #expect(!script.contains("launchctl unload"))
    #expect(!script.contains("pgrep"))
    #expect(!script.contains("pkill"))
    #expect(!script.contains("killall"))
    #expect(!launchAgentTemplate.contains("launchctl load"))
    #expect(!launchAgentTemplate.contains("launchctl unload"))
    #expect(!launchAgentTemplate.contains("rm ~/Library/LaunchAgents"))
    #expect(launchAgentTemplate.contains("removal is owned by Scripts/uninstall.sh"))
    #expect(!keyCommandUninstaller.contains("read -p"))
    #expect(!keyCommandUninstaller.localizedCaseInsensitiveContains("re-run"))
    #expect(!keyCommandUninstaller.localizedCaseInsensitiveContains("manually"))
    #expect(!keyCommandUninstaller.localizedCaseInsensitiveContains("restart Logic"))
}

@Test func testKeyEventHelperSupportsReturnEnterAliasesAndPreflight() throws {
    // #186: the demo capture harness aborted on `--return` ("Unknown option").
    // The key-event input primitive must accept a flag-style --return (leading
    // dashes stripped), alias `enter` -> Return, expose a no-post `--check`
    // preflight, and fail closed naming the supported keys.
    let script = try scriptContents("Scripts/logic_key_event.swift")

    #expect(script.contains("\"return\": KeyEventSpec(keyCode: 36"))
    #expect(script.contains("\"enter\": KeyEventSpec(keyCode: 36"))
    #expect(script.contains("\"esc\": KeyEventSpec(keyCode: 53"))
    // A leading `--` is stripped so `--return` resolves to the Return key.
    #expect(script.contains("while value.hasPrefix(\"-\")"))
    // Preflight that validates a key without posting a CGEvent.
    #expect(script.contains("--check"))
    #expect(script.contains("checkMode"))
    #expect(script.contains("canonicalNameByKeyCode"))
    // Fail-closed unknown key names the supported set.
    #expect(script.contains("unknown_key:"))
    #expect(script.contains("supportedKeysLine()"))
}
