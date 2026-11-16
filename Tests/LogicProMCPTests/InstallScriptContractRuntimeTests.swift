import Foundation
import Testing

@Test(.timeLimit(.minutes(1)), arguments: ["stdout", "stderr"])
func testRunProcessDrainsLargeOutputWhileChildIsRunning(channel: String) throws {
    let redirection = channel == "stderr" ? " >&2" : ""
    let result = try runProcess(
        executable: "/bin/bash",
        arguments: ["-c", "yes 0123456789 | head -n 20000\(redirection)"],
        currentDirectoryURL: installScriptContractRepositoryRootURL()
    )

    #expect(result.exitCode == 0)
    let output = channel == "stderr" ? result.stderr : result.stdout
    #expect(output.utf8.count == 220_000, "the helper must preserve the child's complete output")
}

@Test func testUninstallScriptMissingCommonTerminatesWithoutHumanContinuation() throws {
    let standaloneDir = try makeInstallScriptTempDir("logicpromcp-uninstall-standalone-\(UUID().uuidString)")
    let standaloneScript = standaloneDir.appendingPathComponent("uninstall.sh")
    try writeExecutable(standaloneScript, contents: try scriptContents("Scripts/uninstall.sh"))

    let result = try runProcess(
        executable: "/bin/bash",
        arguments: [standaloneScript.path],
        currentDirectoryURL: standaloneDir
    )

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("install-common.sh not found next to uninstall.sh"))
    #expect(result.combinedOutput.contains("terminal=true"))
    #expect(result.combinedOutput.contains("human_intervention_required=false"))
    #expect(result.combinedOutput.contains("human_intervention_requests=0"))
    #expect(result.combinedOutput.contains("human_dependent_transitions=0"))
    #expect(!result.combinedOutput.contains("run uninstall.sh"))
    #expect(!result.combinedOutput.localizedCaseInsensitiveContains("manually"))
    #expect(!result.combinedOutput.localizedCaseInsensitiveContains("restart"))
}

@Test func testUninstallScriptRejectsUnsafeEnvOverridesBeforeRemoval() throws {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-reject-\(UUID().uuidString)")
    let fakeBin = sandbox.appendingPathComponent("fake-bin", isDirectory: true)
    let rmLog = sandbox.appendingPathComponent("rm.log")
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try writeExecutable(
        fakeBin.appendingPathComponent("rm"),
        contents: """
        #!/bin/bash
        set -euo pipefail
        echo "$*" >> "$RM_LOG"
        exit 0
        """
    )

    let result = try runShellScript(
        "Scripts/uninstall.sh",
        environment: [
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": sandbox.appendingPathComponent("home").path,
            "LOGIC_PRO_MCP_SHARE_DIR": "/tmp/evil",
            "LOGIC_PRO_MCP_APPROVAL_STORE": "/tmp/evil.json",
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "RM_LOG": rmLog.path,
        ]
    )

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("LOGIC_PRO_MCP_APPROVAL_STORE override is not supported"))
    #expect(!FileManager.default.fileExists(atPath: rmLog.path))
}

@Test func testUninstallScriptRejectsTraversedProtectedInstallDirBeforeRemoval() throws {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-traversal-\(UUID().uuidString)")
    let fakeBin = sandbox.appendingPathComponent("fake-bin", isDirectory: true)
    let rmLog = sandbox.appendingPathComponent("rm.log")
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try writeExecutable(
        fakeBin.appendingPathComponent("rm"),
        contents: """
        #!/bin/bash
        set -euo pipefail
        echo "$*" >> "$RM_LOG"
        exit 0
        """
    )

    let result = try runShellScript(
        "Scripts/uninstall.sh",
        environment: [
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": sandbox.appendingPathComponent("home").path,
            "LOGIC_PRO_MCP_INSTALL_DIR": "/tmp/logicpromcp-missing/../../usr/bin",
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "RM_LOG": rmLog.path,
        ]
    )

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("install_dir must not target a protected system path: /usr/bin"))
    #expect(!FileManager.default.fileExists(atPath: rmLog.path))
}

private struct UninstallLaunchAgentFixture {
    let home: URL
    let fakeBin: URL
    let installRoot: URL
    let launchAgent: URL
    let serviceState: URL
    let launchctlLog: URL

    var environment: [String: String] {
        [
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "LOGIC_PRO_MCP_INSTALL_DIR": installRoot.path,
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LAUNCHCTL_LOG": launchctlLog.path,
            "LAUNCH_AGENT_PATH": launchAgent.resolvingSymlinksInPath().path,
            "SERVICE_STATE": serviceState.path,
        ]
    }
}

private func makeUninstallLaunchAgentFixture(
    serviceLoaded: Bool,
    plistPresent: Bool,
    brokenPlistSymlink: Bool = false,
    bootoutExitCode: Int = 0,
    serviceAbsentExitCode: Int = 113,
    removeServiceBeforeBootoutFailure: Bool = false,
    preserveServiceAfterBootout: Bool = false,
    finalBootoutExitCode: Int = 0,
    finalServiceAbsentExitCode: Int? = nil,
    failPlistRemoval: Bool = false,
    reloadServiceAfterPlistRemoval: Bool = false,
    binaryPresent: Bool = false
) throws -> UninstallLaunchAgentFixture {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-launch-agent-\(UUID().uuidString)")
    let home = sandbox.appendingPathComponent("home", isDirectory: true)
    let fakeBin = sandbox.appendingPathComponent("fake-bin", isDirectory: true)
    let installRoot = sandbox.appendingPathComponent("install-root", isDirectory: true)
    let launchAgent = home.appendingPathComponent("Library/LaunchAgents/com.logicpro.mcp.plist")
    let serviceState = sandbox.appendingPathComponent("service-loaded")
    let launchctlLog = sandbox.appendingPathComponent("launchctl.log")

    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
    if plistPresent {
        try writeFile(launchAgent, contents: "fixture")
    } else if brokenPlistSymlink {
        try FileManager.default.createDirectory(
            at: launchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: launchAgent.path,
            withDestinationPath: sandbox.appendingPathComponent("missing-target").path
        )
    }
    if serviceLoaded {
        try writeFile(serviceState, contents: "loaded")
    }
    if binaryPresent {
        try writeFile(installRoot.appendingPathComponent("LogicProMCP"), contents: "fixture")
    }

    try writeExecutable(
        fakeBin.appendingPathComponent("launchctl"),
        contents: """
        #!/bin/bash
        set -euo pipefail
        echo "$*" >> "$LAUNCHCTL_LOG"
        [ "${2:-}" = "gui/$UID/com.logicpro.mcp" ] || exit 64
        case "${1:-}" in
            print)
                if [ -f "$SERVICE_STATE" ]; then
                    exit 0
                fi
                if [ ! -e "$LAUNCH_AGENT_PATH" ] && [ ! -L "$LAUNCH_AGENT_PATH" ] && [ "\(finalServiceAbsentExitCode ?? -1)" -ge 0 ]; then
                    exit "\(finalServiceAbsentExitCode ?? -1)"
                fi
                exit "\(serviceAbsentExitCode)"
                ;;
            bootout)
                effective_exit="\(bootoutExitCode)"
                if [ ! -e "$LAUNCH_AGENT_PATH" ] && [ ! -L "$LAUNCH_AGENT_PATH" ] && [ "\(finalBootoutExitCode)" -ne 0 ]; then
                    effective_exit="\(finalBootoutExitCode)"
                fi
                if [ "$effective_exit" -ne 0 ]; then
                    if [ "\(removeServiceBeforeBootoutFailure ? 1 : 0)" -eq 1 ]; then
                        /bin/rm -f "$SERVICE_STATE"
                    fi
                    exit "$effective_exit"
                fi
                if [ "\(preserveServiceAfterBootout ? 1 : 0)" -eq 0 ]; then
                    /bin/rm -f "$SERVICE_STATE"
                fi
                ;;
            *) exit 64 ;;
        esac
        """
    )
    try writeExecutable(
        fakeBin.appendingPathComponent("cl" + "aude"),
        contents: """
        #!/bin/bash
        exit 0
        """
    )
    if failPlistRemoval || reloadServiceAfterPlistRemoval {
        try writeExecutable(
            fakeBin.appendingPathComponent("rm"),
            contents: """
            #!/bin/bash
            set -euo pipefail
            for argument in "$@"; do
                case "$argument" in
                    */Library/LaunchAgents/com.logicpro.mcp.plist.logicpromcp-uninstall.*)
                        if [ "\(failPlistRemoval ? 1 : 0)" -eq 1 ]; then
                            exit 71
                        fi
                        ;;
                    */Library/LaunchAgents/com.logicpro.mcp.plist)
                        if [ "\(failPlistRemoval ? 1 : 0)" -eq 1 ]; then
                            exit 71
                        fi
                        if [ "\(reloadServiceAfterPlistRemoval ? 1 : 0)" -eq 1 ]; then
                            printf loaded > "$SERVICE_STATE"
                        fi
                        ;;
                esac
            done
            exec /bin/rm "$@"
            """
        )
    }
    if reloadServiceAfterPlistRemoval {
        try writeExecutable(
            fakeBin.appendingPathComponent("mv"),
            contents: """
            #!/bin/bash
            set -euo pipefail
            source_path="${1:-}"
            /bin/mv "$@"
            case "$source_path" in
                */Library/LaunchAgents/com.logicpro.mcp.plist)
                    printf loaded > "$SERVICE_STATE"
                    ;;
            esac
            """
        )
    }

    return UninstallLaunchAgentFixture(
        home: home,
        fakeBin: fakeBin,
        installRoot: installRoot,
        launchAgent: launchAgent,
        serviceState: serviceState,
        launchctlLog: launchctlLog
    )
}

@Test func testUninstallScriptBootsOutExactLoadedLaunchAgentWithoutPlist() throws {
    let fixture = try makeUninstallLaunchAgentFixture(serviceLoaded: true, plistPresent: false)

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Removed launch agent service"))
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    #expect(!FileManager.default.fileExists(atPath: fixture.serviceState.path))
    let calls = try String(contentsOf: fixture.launchctlLog, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(calls.count == 4)
    #expect(calls[0].hasPrefix("print gui/"))
    #expect(calls[1].hasPrefix("bootout gui/"))
    #expect(calls[2].hasPrefix("print gui/"))
    #expect(calls.allSatisfy { $0.hasSuffix("/com.logicpro.mcp") })
}

@Test func testUninstallScriptRemovesFixedPlistWhenLaunchAgentIsNotLoaded() throws {
    let fixture = try makeUninstallLaunchAgentFixture(serviceLoaded: false, plistPresent: true)

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Removed launch agent plist"))
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    #expect(!FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    let calls = try String(contentsOf: fixture.launchctlLog, encoding: .utf8)
        .split(separator: "\n")
    #expect(calls.count == 2)
    #expect(calls[0].hasPrefix("print gui/"))
}

@Test func testUninstallScriptSkipsAbsentLaunchAgentWithoutBootout() throws {
    let fixture = try makeUninstallLaunchAgentFixture(serviceLoaded: false, plistPresent: false)

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Launch agent service not loaded"))
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    let calls = try String(contentsOf: fixture.launchctlLog, encoding: .utf8)
        .split(separator: "\n")
    #expect(calls.count == 2)
    #expect(calls[0].hasPrefix("print gui/"))
}

@Test func testUninstallScriptPreservesBinaryAndPlistWhenLaunchAgentBootoutFails() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        bootoutExitCode: 72,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service could not be stopped"))
    #expect(FileManager.default.fileExists(atPath: fixture.serviceState.path))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testUninstallScriptRejectsLaunchAgentThatRemainsLoadedAfterBootout() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        preserveServiceAfterBootout: true,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service remains loaded"))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
    let calls = try String(contentsOf: fixture.launchctlLog, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(calls.filter { $0.hasPrefix("print gui/") }.count == 6)
}

@Test func testUninstallScriptTerminatesWhenFixedPlistRemovalFails() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: false,
        plistPresent: true,
        failPlistRemoval: true,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent plist could not be removed"))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testUninstallScriptPreservesArtifactsWhenLaunchAgentProbeIsIndeterminate() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: false,
        plistPresent: true,
        serviceAbsentExitCode: 73,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service state could not be established"))
    #expect(result.combinedOutput.contains("terminal=true"))
    #expect(result.combinedOutput.contains("human_intervention_required=false"))
    #expect(result.combinedOutput.contains("human_intervention_requests=0"))
    #expect(result.combinedOutput.contains("human_dependent_transitions=0"))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testUninstallScriptPreservesArtifactsWhenBootoutReadbackIsIndeterminate() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        serviceAbsentExitCode: 73,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service removal could not be verified"))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testUninstallScriptDoesNotConfuseLaunchctlExit75WithLoadedState() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        serviceAbsentExitCode: 75,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service removal could not be verified"))
    #expect(!result.combinedOutput.contains("launch agent service remains loaded"))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testUninstallScriptRemovesOnlyTheBrokenFixedPlistSymlink() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: false,
        plistPresent: false,
        brokenPlistSymlink: true
    )
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.launchAgent.path)) != nil)

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Removed launch agent plist"))
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.launchAgent.path)) == nil)
}

@Test func testUninstallScriptAcceptsObservedAbsenceAfterBootoutReturnsNonzero() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        bootoutExitCode: 72,
        removeServiceBeforeBootoutFailure: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Removed launch agent service"))
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    #expect(!FileManager.default.fileExists(atPath: fixture.serviceState.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.launchAgent.path))
}

@Test func testUninstallScriptStopsServiceThatReloadsBeforeFinalReadback() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        reloadServiceAfterPlistRemoval: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    #expect(!FileManager.default.fileExists(atPath: fixture.serviceState.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    let calls = try String(contentsOf: fixture.launchctlLog, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(calls.filter { $0.hasPrefix("bootout gui/") }.count == 2)
}

@Test func testKeyCommandUninstallerPreservesBindingsAndBackupsWithoutHumanContinuation() throws {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-keycmds-\(UUID().uuidString)")
    let keyCommandDir = sandbox.appendingPathComponent("Key Commands", isDirectory: true)
    let backupDir = keyCommandDir.appendingPathComponent("backups/backup_20261031_120000", isDirectory: true)
    let currentBindings = keyCommandDir.appendingPathComponent("User.logikcs")
    let backedUpBindings = backupDir.appendingPathComponent("User.logikcs")
    let stagedReference = keyCommandDir.appendingPathComponent("LogicProMCP-KeyCommands.plist")
    try writeFile(currentBindings, contents: "current-bindings")
    try writeFile(backedUpBindings, contents: "older-backup")
    try writeFile(stagedReference, contents: "reference-only")

    let result = try runShellScript(
        "Scripts/uninstall-keycmds.sh",
        environment: [
            "LOGIC_PRO_MCP_KEYCMD_DIR": keyCommandDir.path,
            "LOGIC_PRO_MCP_KEYCMD_AUTO_RESTORE": "1",
        ]
    )

    #expect(result.exitCode == 0)
    #expect(!FileManager.default.fileExists(atPath: stagedReference.path))
    #expect(try String(contentsOf: currentBindings, encoding: .utf8) == "current-bindings")
    #expect(try String(contentsOf: backedUpBindings, encoding: .utf8) == "older-backup")
    #expect(result.combinedOutput.contains("terminal=true"))
    #expect(result.combinedOutput.contains("human_intervention_required=false"))
    #expect(result.combinedOutput.contains("human_intervention_requests=0"))
    #expect(result.combinedOutput.contains("human_dependent_transitions=0"))
    #expect(!result.combinedOutput.localizedCaseInsensitiveContains("re-run"))
    #expect(!result.combinedOutput.localizedCaseInsensitiveContains("manually"))
    #expect(!result.combinedOutput.localizedCaseInsensitiveContains("restart Logic"))
}

@Test func testKeyCommandUninstallerReportsRemovalFailureAsTerminal() throws {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-keycmds-failure-\(UUID().uuidString)")
    let keyCommandDir = sandbox.appendingPathComponent("Key Commands", isDirectory: true)
    let fakeBin = sandbox.appendingPathComponent("fake-bin", isDirectory: true)
    let stagedReference = keyCommandDir.appendingPathComponent("LogicProMCP-KeyCommands.plist")
    try writeFile(stagedReference, contents: "reference-only")
    try writeExecutable(
        fakeBin.appendingPathComponent("rm"),
        contents: """
        #!/bin/bash
        exit 71
        """
    )

    let result = try runShellScript(
        "Scripts/uninstall-keycmds.sh",
        environment: [
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "LOGIC_PRO_MCP_KEYCMD_DIR": keyCommandDir.path,
        ]
    )

    #expect(result.exitCode != 0)
    #expect(FileManager.default.fileExists(atPath: stagedReference.path))
    #expect(result.combinedOutput.contains("terminal=true"))
    #expect(result.combinedOutput.contains("human_intervention_required=false"))
    #expect(result.combinedOutput.contains("human_intervention_requests=0"))
    #expect(result.combinedOutput.contains("human_dependent_transitions=0"))
    #expect(result.combinedOutput.contains("reference removal failed"))
}

@Test func testKeyCommandUninstallerAcceptsObservedAbsenceAfterRmReturnsNonzero() throws {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-keycmds-ambiguous-rm-\(UUID().uuidString)")
    let keyCommandDir = sandbox.appendingPathComponent("Key Commands", isDirectory: true)
    let fakeBin = sandbox.appendingPathComponent("fake-bin", isDirectory: true)
    let stagedReference = keyCommandDir.appendingPathComponent("LogicProMCP-KeyCommands.plist")
    try writeFile(stagedReference, contents: "reference-only")
    try writeExecutable(
        fakeBin.appendingPathComponent("rm"),
        contents: """
        #!/bin/bash
        /bin/rm "$@"
        exit 71
        """
    )

    let result = try runShellScript(
        "Scripts/uninstall-keycmds.sh",
        environment: [
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "LOGIC_PRO_MCP_KEYCMD_DIR": keyCommandDir.path,
        ]
    )

    #expect(result.exitCode == 0)
    #expect(!FileManager.default.fileExists(atPath: stagedReference.path))
    #expect(result.combinedOutput.contains("terminal=true"))
    #expect(result.combinedOutput.contains("human_intervention_requests=0"))
    #expect(result.combinedOutput.contains("human_dependent_transitions=0"))
}

@Test func testUninstallScriptRestoresPlistWhenReloadedServiceCannotStop() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        finalBootoutExitCode: 72,
        reloadServiceAfterPlistRemoval: true,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service could not be stopped"))
    #expect(FileManager.default.fileExists(atPath: fixture.serviceState.path))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testUninstallScriptRestoresPlistWhenFinalReadbackIsIndeterminate() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        finalServiceAbsentExitCode: 75,
        reloadServiceAfterPlistRemoval: true,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service removal could not be verified"))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}


@Test(arguments: [0, 17])
func managedInstallerForwardsItsSourceOptionsAndExitStatus(expectedStatus: Int) throws {
    let scratch = try makeInstallScriptTempDir()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("Source Archive", isDirectory: true).resolvingSymlinksInPath()
    let script = source.appendingPathComponent("Scripts/install.sh")
    let entrypoint = source.appendingPathComponent("tools/conductor_install.py")
    try writeExecutable(script, contents: try scriptContents("Scripts/install.sh"))
    try writeFile(entrypoint, contents: """
    import json, sys
    print(json.dumps(sys.argv[1:]))
    sys.exit(\(expectedStatus))
    """)
    let prefix = scratch.appendingPathComponent("Managed Install").path
    let result = try runProcess(executable: "/bin/bash", arguments: [script.path, "--prefix", prefix],
                                currentDirectoryURL: scratch)

    #expect(result.exitCode == Int32(expectedStatus))
    let forwarded = try JSONDecoder().decode([String].self, from: Data(result.stdout.utf8))
    let filesystemPath = try #require(realpath(source.path, nil))
    defer { free(filesystemPath) }
    #expect(forwarded == ["install", "--source", String(cString: filesystemPath), "--prefix", prefix])
}
