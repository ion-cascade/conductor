@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

// These tests prove the driver state machine against a semantic fake and the
// panel-label and destination-browser paths against synthetic AX trees. They
// do NOT exercise AXSurface.openFileMenu or progress discovery in a live Logic
// process; those production Accessibility interactions remain for the user's
// live acceptance. The fake is intentionally stateful so mutations to the
// driver's observations and transitions still turn these tests red.
final class StemPanelSurfaceFake: ProjectStemExportPanelDriver.Surface, @unchecked Sendable {
    var events: [String] = []
    var fileMenuOpens = true
    var exportMenuAvailability: ProjectStemExportPanelDriver.MenuAvailability = .available
    var stemLeafAvailability: ProjectStemExportPanelDriver.MenuAvailability = .available
    var panelAppears = true
    /// `exportPanelPresence()` reports absence for this many initial reads,
    /// then reports the configured presence. This models a panel materializing
    /// after AXPick instead of encoding an instantaneous fake-only contract.
    var absentPanelReadsBeforePresent = 0
    var unavailablePanelReadsBeforePresent = 0
    var browserSelectionSucceeds = true
    var destinationBefore: String? = "Old Exports"
    var destinationAfter: String? = "Stem Exports"
    var perTrackActive = true
    /// The action status and observable UI effect vary independently. The
    /// driver must never use the first as evidence for the second.
    var exportActionStatus = true
    var exportEffectOccurs = true
    /// Models the user pressing Escape (or an unrelated transient census) after
    /// the driver reaches Export but before progress was ever observed.
    var panelDisappearsAfterExportPress = false
    var progressObservations: [ProjectStemExportPanelDriver.ProgressPresence] = [.present, .absent]
    var panelPresence: ProjectStemExportPanelDriver.PanelPresence = .present
    var closeChangesPanelPresence = true
    var dismissLabelMeasured = true
    var onPanelRead: (() -> Void)?
    /// Lets a state-machine test use AXSurface's real panel classifier for its
    /// pre-close observations while the semantic fake still supplies the other
    /// protocol actions.
    var panelPresenceReader: (() -> ProjectStemExportPanelDriver.PanelPresence)?
    var panelCloseAction: (() -> Void)?

    func openFileMenu() -> Bool {
        events.append("file_open")
        return fileMenuOpens
    }

    func openExportMenu() -> ProjectStemExportPanelDriver.MenuAvailability {
        events.append("export_open")
        return events.contains("file_open")
            ? exportMenuAvailability
            : .unavailable("stem_export_export_menu_unavailable")
    }

    func resolveStemLeaf() -> ProjectStemExportPanelDriver.MenuAvailability {
        events.append("leaf_enabled_read")
        // Closed-menu enablement is deliberately false in this fake. The only
        // passing route is the one that opened both parent menus first.
        return events.starts(with: ["file_open", "export_open"])
            ? stemLeafAvailability
            : .unavailable("stem_export_menu_leaf_unavailable_after_open")
    }

    func pickStemLeaf() {
        events.append("leaf_axpick")
    }

    func exportPanelPresence() -> ProjectStemExportPanelDriver.PanelPresence {
        events.append("panel_read")
        onPanelRead?()
        if unavailablePanelReadsBeforePresent > 0 {
            unavailablePanelReadsBeforePresent -= 1
            return .unavailable
        }
        if !events.contains("panel_close"), let panelPresenceReader {
            return panelPresenceReader()
        }
        if !panelAppears { return .absent }
        if panelPresence == .present, absentPanelReadsBeforePresent > 0 {
            absentPanelReadsBeforePresent -= 1
            return .absent
        }
        return panelPresence
    }

    func destinationPopupValue() -> String? {
        let afterSelection = events.contains("destination_browser_select")
        events.append("destination_popup_read")
        return afterSelection ? destinationAfter : destinationBefore
    }

    func selectDestinationBrowserElement(
        at path: String
    ) -> ProjectStemExportPanelDriver.DestinationSelection {
        events.append("destination_browser_select")
        return browserSelectionSucceeds && path.hasSuffix("Stem Exports")
            ? .selected
            : .refused("stem_destination_component_not_listed:Stem Exports")
    }

    func oneFilePerTrackIsActive() -> Bool {
        events.append("per_track_read")
        return perTrackActive
    }

    func pressExport() {
        events.append("export_press_status_\(exportActionStatus)")
        if panelDisappearsAfterExportPress {
            panelPresence = .absent
        }
        if !exportEffectOccurs {
            progressObservations = Array(repeating: .absent, count: max(1, progressObservations.count))
        }
    }

    func progressWindowPresence() -> ProjectStemExportPanelDriver.ProgressPresence {
        events.append("progress_read")
        guard !progressObservations.isEmpty else { return .absent }
        return progressObservations.removeFirst()
    }

    func closeExportPanel() {
        events.append("panel_close")
        panelCloseAction?()
        if closeChangesPanelPresence,
           dismissLabelMeasured,
           panelPresence != .unavailable {
            panelPresence = .absent
        }
    }
}

final class StemPanelTestClock: @unchecked Sendable {
    var now: UInt64 = 0
}

func driveStemPanel(
    _ surface: StemPanelSurfaceFake,
    attempts: Int = 3,
    pollIntervalNanos: UInt64 = 250_000_000,
    artifactCompletion: @escaping @Sendable () -> Bool = { false }
) async -> ProjectStemExportPanelDriver.Outcome {
    let clock = StemPanelTestClock()
    return await ProjectStemExportPanelDriver.drive(
        destination: "/private/tmp/Stem Exports",
        surface: surface,
        progressPollAttempts: attempts,
        sleep: { duration in
            surface.events.append("poll_sleep")
            clock.now += duration
        },
        pollIntervalNanos: pollIntervalNanos,
        artifactCompletion: artifactCompletion,
        monotonicNowNanos: { clock.now }
    )
}

private final class StemExportPanelAXFixtureState: @unchecked Sendable {
    let builder: FakeAXRuntimeBuilder
    let app: AXUIElement
    let panel: AXUIElement
    let export: AXUIElement?
    let cancel: AXUIElement?
    let actionEffectsOccur: Bool
    private(set) var exportActionAttempts = 0
    private(set) var cancelActionAttempts = 0

    init(
        builder: FakeAXRuntimeBuilder,
        app: AXUIElement,
        panel: AXUIElement,
        export: AXUIElement?,
        cancel: AXUIElement?,
        actionEffectsOccur: Bool
    ) {
        self.builder = builder
        self.app = app
        self.panel = panel
        self.export = export
        self.cancel = cancel
        self.actionEffectsOccur = actionEffectsOccur
    }

    func performAction(_ element: AXUIElement, _ action: String, status: Bool) -> Bool {
        guard action == (kAXPressAction as String) else { return status }
        if let export, CFEqual(element, export) {
            exportActionAttempts += 1
            if actionEffectsOccur {
                let progress = builder.element(99)
                builder.setRole(progress, kAXWindowRole as String)
                builder.setAttribute(progress, kAXTitleAttribute as String, "Logic\u{00A0}Pro")
                builder.setAttribute(app, kAXWindowsAttribute as String, [progress])
            }
        }
        if let cancel, CFEqual(element, cancel) {
            cancelActionAttempts += 1
            if actionEffectsOccur {
                builder.setAttribute(app, kAXWindowsAttribute as String, [])
            }
        }
        return status
    }
}

struct StemExportPanelAXFixture {
    let runtime: AXLogicProElements.Runtime
    let state: StemExportPanelAXFixtureState

    init(
        popupValue: String,
        exportButtonTitle: String?,
        cancelButtonTitle: String?,
        isDialog: Bool = true,
        includesPopup: Bool = true,
        popupTitle: String? = nil,
        actionStatus: Bool = true,
        actionEffectsOccur: Bool = true,
        failPanelChildrenRead: Bool = false,
        usesStemPopupStructure: Bool = true,
        unreadablePerTrackPopupRole: Bool = false
    ) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let panel = builder.element(2)
        let popup = builder.element(3)
        let perTrackPopup = builder.element(4)

        builder.setRole(panel, kAXWindowRole as String)
        if isDialog {
            builder.setAttribute(panel, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        }

        var panelChildren: [AXUIElement] = []
        if includesPopup {
            if usesStemPopupStructure {
                // Logic's panel has one titled destination popup plus five
                // untitled option popups. The fixture mirrors that complete
                // structural witness instead of letting a lone generic popup
                // stand in for the per-track control.
                builder.setRole(popup, kAXPopUpButtonRole as String)
                builder.setAttribute(popup, kAXValueAttribute as String, "Stem Exports")
                builder.setAttribute(popup, kAXTitleAttribute as String, popupTitle ?? "Location:")
                panelChildren.append(popup)

                builder.setRole(perTrackPopup, kAXPopUpButtonRole as String)
                builder.setAttribute(perTrackPopup, kAXValueAttribute as String, popupValue)
                panelChildren.append(perTrackPopup)

                for (offset, value) in ["AIFF", "16-bit", "Normalize", "Include Audio Tail"].enumerated() {
                    let option = builder.element(10 + offset)
                    builder.setRole(option, kAXPopUpButtonRole as String)
                    builder.setAttribute(option, kAXValueAttribute as String, value)
                    panelChildren.append(option)
                }
            } else {
                builder.setRole(popup, kAXPopUpButtonRole as String)
                builder.setAttribute(popup, kAXValueAttribute as String, popupValue)
                if let popupTitle {
                    builder.setAttribute(popup, kAXTitleAttribute as String, popupTitle)
                }
                panelChildren.append(popup)
            }
        }

        var export: AXUIElement?
        if let exportButtonTitle {
            let button = builder.element(20)
            builder.setButton(
                button,
                title: exportButtonTitle,
                x: 100,
                y: 100,
                width: 70,
                height: 24
            )
            panelChildren.append(button)
            export = button
        }
        var cancel: AXUIElement?
        if let cancelButtonTitle {
            let button = builder.element(21)
            builder.setButton(
                button,
                title: cancelButtonTitle,
                x: 180,
                y: 100,
                width: 70,
                height: 24
            )
            panelChildren.append(button)
            cancel = button
        }

        builder.setChildren(panel, panelChildren)
        builder.setAttribute(app, kAXWindowsAttribute as String, [panel])

        let state = StemExportPanelAXFixtureState(
            builder: builder,
            app: app,
            panel: panel,
            export: export,
            cancel: cancel,
            actionEffectsOccur: actionEffectsOccur
        )
        self.state = state
        runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                if unreadablePerTrackPopupRole,
                   CFEqual(element, perTrackPopup),
                   attribute == (kAXRoleAttribute as String) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.noValue.rawValue))
                }
                return nil
            },
            childrenResultHandler: { element in
                if failPanelChildrenRead, CFEqual(element, panel) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                state.performAction(element, action, status: actionStatus)
            }
        )
    }
}

/// The live export panel carries SIX popup buttons and only the destination one
/// exposes an AXTitle. This fixture reproduces that shape so the production code
/// cannot fall back to taking the first popup in traversal order — the untitled
/// decoys are deliberately emitted BEFORE the titled one.
struct DestinationPopupAXFixture {
    let runtime: AXLogicProElements.Runtime

    init(titledPopups: [(title: String, value: String)], untitledValues: [String]) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let panel = builder.element(2)
        builder.setRole(panel, kAXWindowRole as String)
        builder.setAttribute(panel, kAXSubroleAttribute as String, kAXDialogSubrole as String)

        var next = 3
        var children: [AXUIElement] = []
        for value in untitledValues {
            let popup = builder.element(next); next += 1
            builder.setRole(popup, kAXPopUpButtonRole as String)
            builder.setAttribute(popup, kAXValueAttribute as String, value)
            children.append(popup)
        }
        for entry in titledPopups {
            let popup = builder.element(next); next += 1
            builder.setRole(popup, kAXPopUpButtonRole as String)
            builder.setAttribute(popup, kAXTitleAttribute as String, entry.title)
            builder.setAttribute(popup, kAXValueAttribute as String, entry.value)
            children.append(popup)
        }
        // The panel must still be recognisable, so give it its measured buttons.
        let export = builder.element(next); next += 1
        builder.setButton(export, title: "내보내기", x: 100, y: 100, width: 70, height: 24)
        children.append(export)
        let cancel = builder.element(next); next += 1
        builder.setButton(cancel, title: "취소", x: 180, y: 100, width: 70, height: 24)
        children.append(cancel)

        builder.setChildren(panel, children)
        builder.setAttribute(app, kAXWindowsAttribute as String, [panel])
        runtime = builder.makeLogicRuntime(appElement: app)
    }
}

/// A Logic app whose only window is the export progress dialog, titled exactly as
/// the live Korean UI titles it. Measured 2026-09-02, its scalars are
/// `U+004C U+006F U+0067 U+0069 U+0063 U+00A0 U+0050 U+0072 U+006F` — the
/// separator is a NO-BREAK SPACE, so the title prints as "Logic Pro" but is not
/// equal to it.
struct ProgressWindowAXFixture {
    let runtime: AXLogicProElements.Runtime

    init(
        windowTitle: String?,
        failWindowsRead: Bool = false,
        untitledWindowBeforeProgress: Bool = false
    ) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        var windows: [AXUIElement] = []
        var nextElementID = 2
        let untitledWindow: AXUIElement?
        if untitledWindowBeforeProgress {
            let window = builder.element(nextElementID)
            nextElementID += 1
            builder.setRole(window, kAXWindowRole as String)
            windows.append(window)
            untitledWindow = window
        } else {
            untitledWindow = nil
        }
        if let windowTitle {
            let window = builder.element(nextElementID)
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXTitleAttribute as String, windowTitle)
            windows.append(window)
        }
        builder.setAttribute(app, kAXWindowsAttribute as String, windows)
        runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                if let untitledWindow,
                   CFEqual(element, untitledWindow),
                   attribute == (kAXTitleAttribute as String) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.noValue.rawValue))
                }
                if failWindowsRead,
                   CFEqual(element, app),
                   attribute == (kAXWindowsAttribute as String) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
    }
}

/// Finder-column AX fixture for the measured destination route. Each URL entry
/// is `AXList -> AXGroup -> AXTextField(AXURL)`; selecting its group can
/// materialize the next column, exactly the readback the production code needs.
private final class DestinationBrowserFixtureState: @unchecked Sendable {
    let builder: FakeAXRuntimeBuilder
    let panel: AXUIElement
    private var nextElementID = 100
    private var panelChildren: [AXUIElement]
    private var pathByGroupID: [Int: String] = [:]
    private var listIDs: Set<Int> = []
    private let childrenByPath: [String: [String]]
    private let acceptsWrite: Bool
    private let navigationOccurs: Bool
    private let outlineID: Int?
    private let volumeRootEntriesAfterSelection: [String]?
    private var navigationNowNanos: UInt64 = 0
    private(set) var selectedChildrenWrites: [(listID: Int, selectedGroupID: Int)] = []
    private(set) var selectionEchoCount = 0
    private(set) var actions: [(elementID: Int, action: String)] = []

    init(
        builder: FakeAXRuntimeBuilder,
        panel: AXUIElement,
        initialEntries: [String],
        childrenByPath: [String: [String]],
        acceptsWrite: Bool,
        navigationOccurs: Bool,
        outline: AXUIElement?,
        volumeRootEntriesAfterSelection: [String]?
    ) {
        self.builder = builder
        self.panel = panel
        self.panelChildren = AXHelpers.getChildren(panel, runtime: builder.makeAXRuntime())
        self.childrenByPath = childrenByPath
        self.acceptsWrite = acceptsWrite
        self.navigationOccurs = navigationOccurs
        self.outlineID = outline.map(builder.elementID)
        self.volumeRootEntriesAfterSelection = volumeRootEntriesAfterSelection
        appendColumn(entries: initialEntries)
    }

    func handleWrite(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        if attribute == (kAXSelectedRowsAttribute as String),
           outlineID == builder.elementID(element) {
            builder.setAttribute(element, attribute, value)
            if let volumeRootEntriesAfterSelection {
                appendColumn(entries: volumeRootEntriesAfterSelection)
            }
            return true
        }
        guard attribute == (kAXSelectedChildrenAttribute as String),
              listIDs.contains(builder.elementID(element)),
              let selected = value as? [AXUIElement],
              let group = selected.first,
              let path = pathByGroupID[builder.elementID(group)] else {
            builder.setAttribute(element, attribute, value)
            return true
        }
        selectedChildrenWrites.append((builder.elementID(element), builder.elementID(group)))
        guard acceptsWrite else { return false }
        // A successful settable AX attribute write always echoes in a real AX
        // server. Navigation is a distinct physical effect and is deliberately
        // controlled separately, so all three states are expressible: rejected,
        // echoed-without-navigation, and echoed-with-navigation.
        builder.setAttribute(element, attribute, value)
        selectionEchoCount += 1
        if navigationOccurs, let children = childrenByPath[path] {
            appendColumn(entries: children)
        }
        return true
    }

    func directoryListing(at path: String) -> AXSurface.DirectoryListing {
        guard let entries = childrenByPath[path] else { return .empty }
        return entries.isEmpty ? .empty : .hasEntries
    }

    func navigationNow() -> UInt64 { navigationNowNanos }

    func advanceNavigationClock(by duration: UInt64) {
        navigationNowNanos += duration
    }

    func recordAction(_ element: AXUIElement, _ action: String) -> Bool {
        actions.append((builder.elementID(element), action))
        return false
    }

    private func appendColumn(entries: [String]) {
        let list = builder.element(nextElementID)
        nextElementID += 1
        builder.setRole(list, kAXListRole as String)
        listIDs.insert(builder.elementID(list))
        var groups: [AXUIElement] = []
        for path in entries {
            let group = builder.element(nextElementID)
            nextElementID += 1
            let field = builder.element(nextElementID)
            nextElementID += 1
            builder.setRole(group, kAXGroupRole as String)
            builder.setRole(field, kAXTextFieldRole as String)
            // AXURL is a CFURL, never a CFString. Measured on the live export
            // panel 2026-09-02: 4 of 4 URL-bearing entries read back as NSURL and
            // 0 as String. Supplying a String here is what let a production read
            // typed `String?` — which returns nil for every real entry — pass a
            // green suite while the destination stage could not work on any
            // machine. The fixture must hand back the type the API hands back.
            builder.setAttribute(field, kAXURLAttribute as String, URL(fileURLWithPath: path) as NSURL)
            builder.setAttribute(field, kAXFilenameAttribute as String, URL(fileURLWithPath: path).lastPathComponent)
            builder.setChildren(group, [field])
            groups.append(group)
            pathByGroupID[builder.elementID(group)] = path
        }
        builder.setChildren(list, groups)
        panelChildren.append(list)
        builder.setChildren(panel, panelChildren)
    }
}

struct DestinationBrowserAXFixture {
    let runtime: AXLogicProElements.Runtime
    let state: DestinationBrowserFixtureState

    init(
        initialEntries: [String],
        childrenByPath: [String: [String]],
        acceptsWrite: Bool = true,
        navigationOccurs: Bool = true,
        volumeName: String? = nil,
        volumeRootEntriesAfterSelection: [String]? = nil
    ) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let panel = builder.element(2)
        let popup = builder.element(3)
        let export = builder.element(4)
        let cancel = builder.element(5)
        let perTrack = builder.element(9)
        builder.setRole(panel, kAXWindowRole as String)
        builder.setAttribute(panel, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setRole(popup, kAXPopUpButtonRole as String)
        builder.setAttribute(popup, kAXTitleAttribute as String, "Location:")
        builder.setAttribute(popup, kAXValueAttribute as String, "Other Destination")
        builder.setRole(perTrack, kAXPopUpButtonRole as String)
        builder.setAttribute(perTrack, kAXValueAttribute as String, "One File per Track")
        builder.setButton(export, title: "Export", x: 100, y: 100, width: 70, height: 24)
        builder.setButton(cancel, title: "Cancel", x: 180, y: 100, width: 70, height: 24)
        var panelChildren = [popup, perTrack]
        for (offset, value) in ["AIFF", "16-bit", "Normalize", "Include Audio Tail"].enumerated() {
            let option = builder.element(20 + offset)
            builder.setRole(option, kAXPopUpButtonRole as String)
            builder.setAttribute(option, kAXValueAttribute as String, value)
            panelChildren.append(option)
        }
        panelChildren += [export, cancel]
        let outline: AXUIElement?
        if let volumeName {
            let outlineElement = builder.element(6)
            let row = builder.element(7)
            let text = builder.element(8)
            builder.setRole(outlineElement, kAXOutlineRole as String)
            builder.setRole(row, kAXRowRole as String)
            builder.setRole(text, kAXStaticTextRole as String)
            builder.setAttribute(text, kAXValueAttribute as String, volumeName)
            builder.setChildren(row, [text])
            builder.setChildren(outlineElement, [row])
            panelChildren.append(outlineElement)
            outline = outlineElement
        } else {
            outline = nil
        }
        builder.setChildren(panel, panelChildren)
        builder.setAttribute(app, kAXWindowsAttribute as String, [panel])

        let state = DestinationBrowserFixtureState(
            builder: builder,
            panel: panel,
            initialEntries: initialEntries,
            childrenByPath: childrenByPath,
            acceptsWrite: acceptsWrite,
            navigationOccurs: navigationOccurs,
            outline: outline,
            volumeRootEntriesAfterSelection: volumeRootEntriesAfterSelection
        )
        self.state = state
        runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: { element, attribute, value in
                state.handleWrite(element, attribute, value)
            },
            performActionHandler: { element, action in
                state.recordAction(element, action)
            }
        )
    }

    func makeSurface() -> AXSurface {
        AXSurface(
            runtime: runtime,
            directoryListing: { [state] path in state.directoryListing(at: path) },
            navigationNowNanos: { [state] in state.navigationNow() },
            navigationSleep: { [state] duration in state.advanceNavigationClock(by: duration) }
        )
    }
}

func scannedStemSubjects(for project: URL) -> ProjectExportStemSubjectInventory {
    .scanned(
        projectPath: project.path,
        subjects: [
            ProjectExportStemSubject(index: 0, name: "Studio Grand"),
            ProjectExportStemSubject(index: 1, name: "Bass / DI"),
        ]
    )
}

final class ReadableThenUnreadableStemDirectoryFileManager: FileManager {
    private let destination: String
    private let readableEnumerations: Int
    private var enumerationCount = 0

    init(destination: String, readableEnumerations: Int) {
        self.destination = destination
        self.readableEnumerations = readableEnumerations
        super.init()
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        guard path == destination else {
            return try super.contentsOfDirectory(atPath: path)
        }
        enumerationCount += 1
        guard enumerationCount <= readableEnumerations else {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.contentsOfDirectory(atPath: path)
    }
}
