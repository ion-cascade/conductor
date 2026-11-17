import Foundation
import Testing
@testable import LogicProMCP

private func repositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func readRepoFile(_ relativePath: String) throws -> String {
    try String(
        contentsOf: repositoryRootURL().appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

struct ChangelogReleaseHeading {
    let version: String
    let date: String
}

func latestChangelogReleaseHeading() throws -> ChangelogReleaseHeading? {
    let changelog = try readRepoFile("CHANGELOG.md")
    let regex = try NSRegularExpression(
        pattern: #"^## \[([0-9]+\.[0-9]+\.[0-9]+)\] — ([0-9]{4}-[0-9]{2}-[0-9]{2})$"#
    )

    for line in changelog.components(separatedBy: .newlines) {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { continue }
        let versionRange = Range(match.range(at: 1), in: line)!
        let dateRange = Range(match.range(at: 2), in: line)!
        return ChangelogReleaseHeading(
            version: String(line[versionRange]),
            date: String(line[dateRange])
        )
    }
    return nil
}

@Test func conductorManifestPinsItsOwnSourceRelease() throws {
    let manifest = try #require(try sharedParseJSON(readRepoFile("manifest.json")) as? [String: Any])
    let version = ServerConfig.serverVersion
    let repository = "https://github.com/ion-cascade/conductor"
    let installation = try #require(manifest["installation"] as? [String: [String: Any]])
    let macOS = try #require(installation["macos"])
    #expect(manifest["name"] as? String == "ion-cascade-conductor")
    #expect(manifest["version"] as? String == version)
    #expect(manifest["repository"] as? String == repository)
    #expect(macOS["distribution"] as? String == "source")
    #expect(macOS["release_url"] as? String == "\(repository)/releases/tag/v\(version)")
    #expect(macOS["command"] as? String == ".build/release/LogicProMCP")
    #expect(macOS["download_url"] == nil)
}

@Test func versionReleaseTimestamp_matches_latest_changelog_release_date() throws {
    let latestRelease = try #require(
        try latestChangelogReleaseHeading(),
        "CHANGELOG.md must contain a release heading like '## [3.11.0] — 2026-07-10'"
    )
    #expect(latestRelease.version == ServerConfig.serverVersion)

    let timestamps = ResourceProvider.resources.compactMap { $0.annotations?.lastModified }
    #expect(
        timestamps.count == ResourceProvider.resources.count,
        "every public resource annotation must expose lastModified"
    )
    let uniqueTimestamps = Set(timestamps)
    #expect(uniqueTimestamps.count == 1, "resource annotations must use one release timestamp: \(uniqueTimestamps)")
    let timestamp = try #require(uniqueTimestamps.first)
    #expect(
        timestamp == "\(latestRelease.date)T00:00:00Z",
        "resource lastModified must match the latest CHANGELOG release date"
    )
}

@Test func testConductorManifestMatchesServerCatalog() throws {
    let manifest = try sharedParseJSON(readRepoFile("manifest.json")) as! [String: Any]

    // The manifest tools array describes the Conductor source release and must equal the
    // server catalog exactly so it can never silently drift (e.g. omit logic_audio).
    let tools = Set(try #require(manifest["tools"] as? [String]))
    #expect(tools == Set(ServerCatalog.tools.map(\.name)))
    #expect(tools.count == 10)

    let resources = Set(try #require(manifest["resources"] as? [String]))
    #expect(resources == [
        "logic://system/health",
        "logic://transport/state",
        "logic://tempo/map",
        "logic://tracks",
        "logic://mixer",
        "logic://markers",
        "logic://project/info",
        "logic://project/audit",
        "logic://project/cleanup-plan",
        "logic://midi/ports",
        "logic://mcu/state",
        "logic://library/inventory",
        "logic://stock-plugins",
        "logic://stock-plugins/census",
        "logic://stock-plugins/capabilities",
        "logic://stock-instruments",
        "logic://session-players",
        "logic://workflow-skills",
        "logic://workflow-skills/schema",
    ])
    #expect(resources == Set(ResourceProvider.resources.map(\.uri)))

    let templates = Set(try #require(manifest["resource_templates"] as? [String]))
    #expect(templates == [
        "logic://system/operations",
        "logic://tracks/{index}",
        "logic://tracks/{index}/regions",
        "logic://mixer/{strip}",
        "logic://stock-plugins/{id}",
        "logic://stock-plugins/search?query={query}",
        "logic://stock-instruments/{id}",
        "logic://stock-instruments/search?query={query}",
        "logic://session-players/{id}",
        "logic://workflow-plans/session?prompt={prompt}",

        "logic://workflow-skills/{id}",
        "logic://workflow-skills/search?query={query}",
    ])
    #expect(templates == Set(ResourceProvider.templates.map(\.uriTemplate)))

    let description = try #require(manifest["description"] as? String)
    #expect(description.contains("10 tools + 19 resources + 12 templates"))
}

@Test func testReadmeAndAPIDocsMatchPublicSurfaceAndRouting() throws {
    let readme = try readRepoFile("README.md")
    let latestReleaseURL = "https://github.com/ion-cascade/conductor/releases/latest"
    #expect(readme.contains("href=\"\(latestReleaseURL)\">Download latest release</a>"))
    #expect(readme.contains("`SHA256SUMS`"))
    #expect(readme.contains("`./Scripts/install.sh`"))
    #expect(readme.contains("swift build -c release"))

    let api = try readRepoFile("docs/API.md")
    // #983: the page's opening sentence carried a release summary nothing read, and it named
    // v3.15.0 two releases later. The history now lives in CHANGELOG alone; the counts stay, and
    // are pinned here as the README's are.
    #expect(api.contains("exposes 10 tools, 19 static resources, and 12 resource templates"))
    #expect(api.contains("| `toggle_cycle` | — | text | Accessibility → MIDIKeyCommands → CGEvent → MCU |"))
    #expect(api.contains("| `toggle_autopunch` | — | State A/B/C contract envelope | Accessibility |"))
    #expect(api.contains("| `set_tempo` | `{ tempo: number }` (5–999, matches Logic's actual accepted range) | text | Accessibility |"))
    #expect(api.contains("`set_automation`"))
    // #1077: the MCU write now reads Logic's modal set after the press, and the page says what the
    // reply reports about it; the old one-line "no readback echo" contract went with that change.
    #expect(api.contains("`modal_after_press` is what the last read found: `clear`, `open`"))
    #expect(api.contains("State B `modal_left_open` whatever the mode read"))
    #expect(api.contains("only the exact `marker_list_not_open` outcome carries the terminal `logic_navigate capture_markers` alternative"))
}

@Test func conductorSourceDistributionContainsRuntimeHelpers() throws {
    let requiredFiles = [
        "Package.swift", "Package.resolved", "NOTICE.md", "LICENSE", "manifest.json",
        "tools/logic_bridge_server.py", "tools/logic_bridge_relay.py",
        "Scripts/logic_bounce.py", "Scripts/logic_bounce_ui.py",
        "Scripts/logic_ui_jxa.py", "Scripts/logic_input_source.py", "Scripts/logic_variants.py",
    ]
    let root = repositoryRootURL()
    for path in requiredFiles {
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
            "The source distribution must contain \(path).")
    }
}

// MARK: - R12 / AC1 / AC14 doc-lint
// The verified-apply-back contract must stay stated in the shipped docs so it
// cannot silently drift (the CI enforcement guardian flagged as missing).

@Test func testScripterSetParamDocumentedAsLegacyStateB() throws {
    // AC1 / R12: Scripter set_plugin_param is legacy unverified State B and must
    // NOT be presented as the verified apply-back solution.
    let api = try readRepoFile("docs/API.md")
    #expect(
        api.contains("legacy unverified State B"),
        "API.md must mark Scripter set_plugin_param as legacy unverified State B (R12/AC1)"
    )
    #expect(
        api.contains("logic_plugins.set_param_verified"),
        "API.md must point to logic_plugins.set_param_verified as the verified path (R12/AC1)"
    )
}

@Test func testInsertPluginDeprecationDocumented() throws {
    // AC14 / R12: logic_mixer.insert_plugin deprecated in favour of insert_verified.
    let changelog = try readRepoFile("CHANGELOG.md")
    #expect(
        changelog.lowercased().contains("insert_plugin` deprecated")
            || changelog.lowercased().contains("insert_plugin deprecated"),
        "CHANGELOG must note logic_mixer.insert_plugin deprecation (R12/AC14)"
    )
    #expect(
        changelog.contains("insert_verified"),
        "CHANGELOG must name logic_plugins.insert_verified as the go-forward path (R12/AC14)"
    )
}

@Test func testVerifiedApplyBackContractDocumented() throws {
    // R12: the verified apply-back contract must stay in the minimal public API docs.
    let guide = try readRepoFile("docs/API.md")
    #expect(
        guide.contains("duplicate_applyback"),
        "verified-apply-back guide must document the duplicate_applyback gate (R12)"
    )
    #expect(
        guide.contains("get_inventory"),
        "verified-apply-back guide must document get_inventory targeting (R12)"
    )
}
