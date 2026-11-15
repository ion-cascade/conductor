@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#369 late-bound stem plan and export-panel drive")
struct Issue369StemExportTests {
    @Test("a materializing panel can recover from transient AX failures without another menu pick")
    func transientPanelReadFailureIsObservedWithinTheOriginalBudget() async {
        let surface = StemPanelSurfaceFake()
        surface.unavailablePanelReadsBeforePresent = 2
        let result = await driveStemPanel(surface)
        #expect(result == .completed)
        #expect(surface.events.filter { $0 == "leaf_axpick" }.count == 1)
        #expect(surface.events.filter { $0.hasPrefix("export_press") }.count == 1)
    }
    // A fake whose leaf answers disabled until its menus are open. macOS validates
    // menu items on open, so a drive that reads before opening sees every export item
    // unavailable — measured live, the same items read false closed and true open.
    // proves the causal ordering rather than merely observing a success.
    @Test("opens parent menus before reading stem leaf enablement")
    func menuOpenPrecedesEnablementRead() async throws {
        let surface = StemPanelSurfaceFake()
        let outcome = await driveStemPanel(surface)

        let completed = outcome == .completed
        #expect(completed)
        let readIndex = try #require(surface.events.firstIndex(of: "leaf_enabled_read"))
        let fileIndex = try #require(surface.events.firstIndex(of: "file_open"))
        let exportIndex = try #require(surface.events.firstIndex(of: "export_open"))
        let openingPrecedesRead = [fileIndex, exportIndex].allSatisfy {
            $0 < readIndex
        }
        #expect(openingPrecedesRead)
    }

    @Test("a late export panel is polled through to destination selection")
    func lateExportPanelReachesDestinationStage() async throws {
        let surface = StemPanelSurfaceFake()
        surface.absentPanelReadsBeforePresent = 2

        let outcome = await driveStemPanel(surface)

        let destinationIndex = try #require(
            surface.events.firstIndex(of: "destination_browser_select")
        )
        let eventsBeforeDestination = surface.events[..<destinationIndex]
        let panelReadsBeforeDestination = eventsBeforeDestination.filter { $0 == "panel_read" }
        let panelWasPolled = panelReadsBeforeDestination.count == 3
        #expect(panelWasPolled)
        let sleepsBeforeDestination = eventsBeforeDestination.filter { $0 == "poll_sleep" }
        let pollIntervalsWereUsed = sleepsBeforeDestination.count == 2
        #expect(pollIntervalsWereUsed)
        let completed = outcome == .completed
        #expect(completed)
        let didNotRefuseOnTheInitialRead = outcome != .refused(
            "stem_export_panel_not_observed_after_axpick"
        )
        #expect(didNotRefuseOnTheInitialRead)
    }

    @Test("a panel that never appears refuses after the bounded wait")
    func missingExportPanelRefusesWithinBoundedWait() async {
        let surface = StemPanelSurfaceFake()
        surface.panelAppears = false

        let outcome = await driveStemPanel(surface)

        let refusedAfterBoundedWait = outcome == .refused(
            "stem_export_panel_not_observed_after_bounded_wait_elapsed"
        )
        #expect(refusedAfterBoundedWait)
        let panelReadCount = surface.events.filter { $0 == "panel_read" }.count
        let expectedPanelReads = Int(
            ProjectStemExportPanelDriver.exportPanelObservationDeadlineNanos / 250_000_000
        ) + 2 // initial read, one read after every poll, then close readback
        let observationStayedBounded = panelReadCount == expectedPanelReads
        #expect(observationStayedBounded)
    }

    @Test("panel observation budget includes synchronous AX census time")
    func panelDeadlineCountsReadTime() async {
        let surface = StemPanelSurfaceFake()
        surface.panelAppears = false
        let clock = StemPanelTestClock()
        surface.onPanelRead = {
            // One slow AX census already exceeds the advertised ten-second
            // bound. Sleep-only accounting would still perform forty polls.
            clock.now += ProjectStemExportPanelDriver.exportPanelObservationDeadlineNanos + 1
        }
        let outcome = await ProjectStemExportPanelDriver.drive(
            destination: "/private/tmp/Stem Exports",
            surface: surface,
            progressPollAttempts: 1,
            sleep: { duration in
                surface.events.append("poll_sleep")
                clock.now += duration
            },
            pollIntervalNanos: 250_000_000,
            monotonicNowNanos: { clock.now }
        )

        let refusedAtElapsedBound = outcome == .refused(
            "stem_export_panel_not_observed_after_bounded_wait_elapsed"
        )
        #expect(refusedAtElapsedBound)
        let noSleepOccurred = !surface.events.contains("poll_sleep")
        #expect(noSleepOccurred)
    }

    @Test("an unavailable panel readback refuses without becoming absence")
    func unavailableExportPanelReadbackRefusesDistinctly() async {
        let surface = StemPanelSurfaceFake()
        surface.panelPresence = .unavailable

        let outcome = await driveStemPanel(surface)

        let readbackUnavailable = outcome == .refused(
            "readback_unavailable: stem_export_panel_close_not_observed"
        )
        #expect(readbackUnavailable)
        let neverBecameBoundedAbsence = outcome != .refused(
            "stem_export_panel_not_observed_after_bounded_wait_elapsed"
        )
        #expect(neverBecameBoundedAbsence)
        let panelReadCount = surface.events.filter { $0 == "panel_read" }.count
        // Observation may recover while the panel materializes, but the
        // original deadline stays finite and no action is replayed.
        #expect(panelReadCount >= 2 && panelReadCount <= 42)
        #expect(surface.events.filter { $0 == "leaf_axpick" }.count == 1)
        #expect(!surface.events.contains { $0.hasPrefix("export_press") })
    }

    @Test("stem Export submenu resolves its measured Korean title")
    func koreanExportMenuTitleResolves() {
        let resolves = ProjectStemExportPanelDriver.exportMenuTitleMatches("내보내기")
        #expect(resolves)
    }

    @Test("stem Export submenu still resolves its measured English title")
    func englishExportMenuTitleResolves() {
        let resolves = ProjectStemExportPanelDriver.exportMenuTitleMatches("Export")
        #expect(resolves)
    }

    @Test("parent-menu action status is not treated as evidence that the menu opened")
    func menuActionStatusDoesNotDecideAvailability() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let menuBar = builder.element(2)
        let file = builder.element(3)
        let fileMenu = builder.element(4)
        let export = builder.element(5)
        let exportMenu = builder.element(6)
        let stem = builder.element(7)
        let unrelated = builder.element(8)
        builder.setAttribute(app, "AXMenuBar", menuBar)
        builder.setRole(file, kAXMenuBarItemRole as String)
        builder.setAttribute(file, kAXTitleAttribute as String, "File")
        builder.setRole(fileMenu, kAXMenuRole as String)
        builder.setRole(export, kAXMenuItemRole as String)
        builder.setAttribute(export, kAXTitleAttribute as String, "Export")
        builder.setRole(exportMenu, kAXMenuRole as String)
        for leaf in [stem, unrelated] {
            builder.setRole(leaf, kAXMenuItemRole as String)
            builder.setAttribute(leaf, kAXTitleAttribute as String, "All Tracks as Audio Files…")
            builder.setAttribute(leaf, kAXEnabledAttribute as String, true)
        }
        builder.setChildren(menuBar, [file])
        builder.setChildren(file, [fileMenu])
        builder.setChildren(fileMenu, [export])
        builder.setChildren(export, [exportMenu])
        builder.setChildren(exportMenu, [stem])
        builder.setChildren(app, [unrelated])
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { _, _ in false }
        )
        let surface = AXSurface(runtime: runtime)

        let fileCandidateWasFound = surface.openFileMenu()
        #expect(fileCandidateWasFound)
        let exportCandidateWasFound = surface.openExportMenu() == .available
        #expect(exportCandidateWasFound)
        #expect(surface.resolveStemLeaf() == .available)
        let actionSurface = AXSurface(runtime: builder.makeLogicRuntime(appElement: app))
        actionSurface.pickStemLeaf()
        #expect(builder.actionCalls.last?.elementID == builder.elementID(stem))
        #expect(builder.actionCalls.last?.action == ProjectStemExportPanelDriver.stemLeafPickAction)

        // A same-named item outside the File menu must not substitute for an absent leaf.
        builder.setChildren(exportMenu, [])
        #expect(surface.resolveStemLeaf() == .unavailable(ProjectStemExportPanelDriver.stemLeafLabelNotMeasuredReason))
        let actionsBefore = builder.actionCalls.count
        actionSurface.pickStemLeaf()
        #expect(builder.actionCalls.count == actionsBefore)

        builder.setChildren(exportMenu, [stem, unrelated])
        #expect(surface.resolveStemLeaf() == .unavailable("stem_export_menu_leaf_unavailable_after_open"))
        actionSurface.pickStemLeaf()
        #expect(builder.actionCalls.count == actionsBefore)

    }

    @Test("English stem-export controls are identified and their effects are observed")
    func englishStemExportPanelIsRecognised() {
        let fixture = StemExportPanelAXFixture(
            popupValue: "One File per Track",
            exportButtonTitle: "Export",
            cancelButtonTitle: "Cancel"
        )
        let surface = AXSurface(runtime: fixture.runtime)

        let recognised = surface.exportPanelPresence() == .present
        #expect(recognised)
        let oneFilePerTrackIsActive = surface.oneFilePerTrackIsActive()
        #expect(oneFilePerTrackIsActive)
        surface.pressExport()
        let exportEffectWasObserved = surface.progressWindowPresence() == .present
        #expect(exportEffectWasObserved)
        #expect(fixture.state.exportActionAttempts == 1)

        let cancelFixture = StemExportPanelAXFixture(
            popupValue: "One File per Track",
            exportButtonTitle: "Export",
            cancelButtonTitle: "Cancel"
        )
        let cancelSurface = AXSurface(runtime: cancelFixture.runtime)
        cancelSurface.closeExportPanel()
        let cancelEffectWasObserved = cancelSurface.exportPanelPresence() == .absent
        #expect(cancelEffectWasObserved)
        #expect(cancelFixture.state.cancelActionAttempts == 1)
    }

    @Test("Korean stem-export controls are identified and their effects are observed")
    func koreanStemExportPanelIsRecognised() {
        let fixture = StemExportPanelAXFixture(
            popupValue: "트랙당 하나의 파일",
            exportButtonTitle: "내보내기",
            cancelButtonTitle: "취소"
        )
        let surface = AXSurface(runtime: fixture.runtime)

        let recognised = surface.exportPanelPresence() == .present
        #expect(recognised)
        let oneFilePerTrackIsActive = surface.oneFilePerTrackIsActive()
        #expect(oneFilePerTrackIsActive)
        surface.pressExport()
        let exportEffectWasObserved = surface.progressWindowPresence() == .present
        #expect(exportEffectWasObserved)

        let cancelFixture = StemExportPanelAXFixture(
            popupValue: "트랙당 하나의 파일",
            exportButtonTitle: "내보내기",
            cancelButtonTitle: "취소"
        )
        let cancelSurface = AXSurface(runtime: cancelFixture.runtime)
        cancelSurface.closeExportPanel()
        let cancelEffectWasObserved = cancelSurface.exportPanelPresence() == .absent
        #expect(cancelEffectWasObserved)
    }

    @Test("destination browser writes AXSelectedChildren for a URL-backed one-level entry")
    func destinationBrowserSelectsURLTextFieldThroughOwningList() {
        let destination = "/Users/fixture/Exports"
        let fixture = DestinationBrowserAXFixture(
            initialEntries: [destination],
            childrenByPath: [destination: ["\(destination)/Rendered"]]
        )
        let result = fixture.makeSurface().selectDestinationBrowserElement(at: destination)

        let selected = result == .selected
        #expect(selected)
        let wroteOwningList = fixture.state.selectedChildrenWrites.count == 1
        #expect(wroteOwningList)
        let selectedEntryGroup = fixture.state.selectedChildrenWrites.first?.selectedGroupID != nil
        #expect(selectedEntryGroup)
        let neverPressedEntry = fixture.state.actions.isEmpty
        #expect(neverPressedEntry)
    }

    @Test("destination browser descends URL-backed components one at a time")
    func destinationBrowserDescendsMultipleComponents() {
        let first = "/Users/fixture/Exports"
        let destination = "\(first)/Mixes"
        let fixture = DestinationBrowserAXFixture(
            initialEntries: [first],
            childrenByPath: [
                first: [destination],
                destination: ["\(destination)/Rendered"],
            ]
        )
        let result = fixture.makeSurface().selectDestinationBrowserElement(at: destination)

        let selected = result == .selected
        #expect(selected)
        let wroteEachComponent = fixture.state.selectedChildrenWrites.count == 2
        #expect(wroteEachComponent)
    }

    @Test("destination browser refuses with the component that is never listed")
    func destinationBrowserNamesUnresolvedComponent() {
        let fixture = DestinationBrowserAXFixture(
            initialEntries: ["/Users/fixture/Exports"],
            childrenByPath: [:]
        )
        let result = fixture.makeSurface().selectDestinationBrowserElement(at: "/Users/fixture/Missing")

        guard case let .refused(reason) = result else {
            Issue.record("an unlisted destination component was accepted")
            return
        }
        let namesMissingComponent = reason.contains("Missing")
        #expect(namesMissingComponent)
    }

    @Test("destination browser refuses an echoed selection without navigation for a non-empty destination")
    func destinationBrowserRequiresObservedNavigationEffect() {
        let destination = "/Users/fixture/Exports"
        let fixture = DestinationBrowserAXFixture(
            initialEntries: [destination],
            childrenByPath: [destination: ["\(destination)/Rendered"]],
            navigationOccurs: false
        )
        let result = fixture.makeSurface().selectDestinationBrowserElement(at: destination)

        guard case let .refused(reason) = result else {
            Issue.record("an echoed selection without navigation was accepted")
            return
        }
        let writeWasAttempted = fixture.state.selectedChildrenWrites.count == 1
        #expect(writeWasAttempted)
        let refusalRequiresNavigation = reason.contains("not_confirmed:Exports")
        #expect(refusalRequiresNavigation)
    }

    @Test("destination browser keeps a rejected write distinct from an echoed selection")
    func destinationBrowserCanModelRejectedWrite() {
        let destination = "/Users/fixture/Exports"
        let fixture = DestinationBrowserAXFixture(
            initialEntries: [destination],
            childrenByPath: [destination: ["\(destination)/Rendered"]],
            acceptsWrite: false,
            navigationOccurs: true
        )
        let result = fixture.makeSurface().selectDestinationBrowserElement(at: destination)

        guard case let .refused(reason) = result else {
            Issue.record("a rejected AX selection write was accepted")
            return
        }
        let attemptedOneWrite = fixture.state.selectedChildrenWrites.count == 1
        #expect(attemptedOneWrite)
        let didNotEchoRejectedWrite = fixture.state.selectionEchoCount == 0
        #expect(didNotEchoRejectedWrite)
        let refusedWithoutReadback = reason.contains("not_confirmed:Exports")
        #expect(refusedWithoutReadback)
    }

    @Test("a sidebar volume-name match is refused unless the browser lists that exact volume root")
    func volumeSidebarRequiresRootPathListing() throws {
        let root = URL(fileURLWithPath: "/")
        let values = try root.resourceValues(forKeys: [.volumeNameKey])
        let volumeName = try #require(values.volumeName)
        let fixture = DestinationBrowserAXFixture(
            initialEntries: [],
            childrenByPath: [:],
            volumeName: volumeName,
            // This materializes a browser entry, but its parent is not the
            // requested root. A Favorites row with this display name must not
            // be accepted as a volume hop.
            volumeRootEntriesAfterSelection: ["/Volumes/not-the-requested-root/entry"]
        )
        let result = fixture.makeSurface().selectDestinationBrowserElement(at: "/")

        let expected = ProjectStemExportPanelDriver.DestinationSelection.refused(
            "stem_destination_volume_path_not_confirmed:\(volumeName):/"
        )
        let refusedWrongRootListing = result == expected
        #expect(refusedWrongRootListing)
    }

    @Test("a visible home row can establish a destination when the startup volume is absent")
    func homeSidebarRequiresActualHomeListing() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let destination = home.appendingPathComponent("Stem Exports").path
        let fixture = DestinationBrowserAXFixture(initialEntries: ["/tmp/unrelated"],
            childrenByPath: [destination: []], volumeName: home.lastPathComponent,
            volumeRootEntriesAfterSelection: [destination])
        #expect(fixture.makeSurface().selectDestinationBrowserElement(at: destination) == .selected)
    }

    @Test("a matching home label cannot authorize a browser rooted elsewhere")
    func homeSidebarRefusesWrongRootListing() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let fixture = DestinationBrowserAXFixture(initialEntries: [], childrenByPath: [:],
            volumeName: home.lastPathComponent,
            volumeRootEntriesAfterSelection: ["/Volumes/not-home/Stem Exports"])
        let result = fixture.makeSurface().selectDestinationBrowserElement(at: home.appendingPathComponent("Stem Exports").path)
        #expect(result != .selected)
        #expect(fixture.state.selectedChildrenWrites.isEmpty)
    }

    @Test("the destination popup is identified by carrying a title, not by traversal order")
    func destinationPopupIsIdentifiedStructurally() {
        // Five untitled decoys come first; taking the first popup would read
        // "AIFF" as the destination.
        let fixture = DestinationPopupAXFixture(
            titledPopups: [(title: "위치:", value: "logic-pro-mcp-stem-test")],
            untitledValues: ["AIFF", "16비트", "트랙당 하나의 파일", "과부하 보호만", "파일 끝점의 무음 구간 다듬기"]
        )
        let value = AXSurface(runtime: fixture.runtime).destinationPopupValue()
        let readsTheTitledPopup = value == "logic-pro-mcp-stem-test"
        #expect(readsTheTitledPopup)
    }

    @Test("an ambiguous or missing destination popup refuses instead of picking one")
    func destinationPopupRefusesWhenNotUnique() {
        let none = AXSurface(runtime: DestinationPopupAXFixture(
            titledPopups: [],
            untitledValues: ["AIFF", "16비트"]
        ).runtime).destinationPopupValue()
        let refusesWhenAbsent = none == nil
        #expect(refusesWhenAbsent)

        let two = AXSurface(runtime: DestinationPopupAXFixture(
            titledPopups: [(title: "위치:", value: "A"), (title: "Where:", value: "B")],
            untitledValues: []
        ).runtime).destinationPopupValue()
        let refusesWhenAmbiguous = two == nil
        #expect(refusesWhenAmbiguous)
    }

    @Test("the export progress dialog is recognised through its NO-BREAK SPACE title")
    func progressWindowTitleUsesNoBreakSpace() {
        // The exact live title, written as scalars so the NBSP cannot be lost to
        // an editor or a copy-paste that silently normalises it.
        let liveTitle = "Logic\u{00A0}Pro"
        let looksIdenticalButIsNotEqual = liveTitle != "Logic Pro"
        #expect(looksIdenticalButIsNotEqual)

        let observed = AXSurface(runtime: ProgressWindowAXFixture(windowTitle: liveTitle).runtime)
            .progressWindowPresence() == .present
        #expect(observed)

        let ordinarySpace = AXSurface(runtime: ProgressWindowAXFixture(windowTitle: "Logic Pro").runtime)
            .progressWindowPresence() == .present
        #expect(ordinarySpace)
    }

    @Test("a window that is not the progress dialog is not mistaken for it")
    func progressWindowRejectsOtherTitles() {
        // The separator may localise, but it must still BE a separator: a title
        // with the space removed is a different product string, not this dialog.
        let noSeparator = AXSurface(runtime: ProgressWindowAXFixture(windowTitle: "LogicPro").runtime)
            .progressWindowPresence()
        let rejectsRemovedSeparator = noSeparator == .absent
        #expect(rejectsRemovedSeparator)

        let project = AXSurface(runtime: ProgressWindowAXFixture(windowTitle: "lpm-606-warm - 트랙").runtime)
            .progressWindowPresence()
        let rejectsProjectWindow = project == .absent
        #expect(rejectsProjectWindow)

        let none = AXSurface(runtime: ProgressWindowAXFixture(windowTitle: nil).runtime)
            .progressWindowPresence()
        let rejectsNoWindows = none == .absent
        #expect(rejectsNoWindows)
    }

    @Test("a failed progress-window read cannot be promoted to progress disappearance")
    func failedProgressWindowReadNeverCompletesExport() async {
        let unreadableProgress = AXSurface(runtime: ProgressWindowAXFixture(
            windowTitle: "Logic Pro",
            failWindowsRead: true
        ).runtime).progressWindowPresence()
        let fixturePreservesFailure = unreadableProgress == .unavailable
        #expect(fixturePreservesFailure)

        let surface = StemPanelSurfaceFake()
        surface.progressObservations = [.present, .unavailable]
        let outcome = await driveStemPanel(surface, attempts: 2)

        let readbackUnavailable = outcome == .uncertain(
            "readback_unavailable: stem_export_effect_or_progress_not_observed_after_press",
            exportEffectObserved: true
        )
        #expect(readbackUnavailable)
        let didNotClaimCompletion = outcome != .completed
        #expect(didNotClaimCompletion)
    }

    @Test("an untitled auxiliary window does not hide the later progress window")
    func untitledWindowBeforeProgressWindowIsSkipped() {
        let presence = AXSurface(runtime: ProgressWindowAXFixture(
            windowTitle: "Logic Pro",
            untitledWindowBeforeProgress: true
        ).runtime).progressWindowPresence()

        let laterProgressWindowWasObserved = presence == .present
        #expect(laterProgressWindowWasObserved)
    }

    @Test("destination browser refuses duplicate URL entries rather than using traversal order")
    func destinationBrowserRefusesDuplicateURL() {
        let destination = "/Users/fixture/Exports"
        let fixture = DestinationBrowserAXFixture(
            initialEntries: [destination, destination],
            childrenByPath: [destination: ["\(destination)/Rendered"]]
        )
        let result = fixture.makeSurface().selectDestinationBrowserElement(at: destination)

        guard case let .refused(reason) = result else {
            Issue.record("a duplicate URL entry was accepted using traversal order")
            return
        }
        let duplicateWasNamed = reason.contains("ambiguous:Exports")
        #expect(duplicateWasNamed)
        let wroteNothing = fixture.state.selectedChildrenWrites.isEmpty
        #expect(wroteNothing)
    }

    @Test("a Cancel-known and Export-unknown stem panel is partially measured and can close")
    func cancelKnownPartialPanelCanClose() async {
        let fixture = StemExportPanelAXFixture(
            popupValue: "One File per Track",
            exportButtonTitle: nil,
            cancelButtonTitle: "Cancel"
        )
        let surface = AXSurface(runtime: fixture.runtime)

        let presence = surface.exportPanelPresence()
        let partiallyMeasured = presence == .partiallyMeasured(
            recognized: "Cancel",
            notMeasured: "Export"
        )
        #expect(partiallyMeasured)
        surface.closeExportPanel()
        let closeWasObserved = surface.exportPanelPresence() == .absent
        #expect(closeWasObserved)

        let driverSurface = StemPanelSurfaceFake()
        driverSurface.panelPresence = presence
        let outcome = await driveStemPanel(driverSurface)
        let refusalNamesRecognizedAndMissingLabels = outcome == .refused(
            "stem_export_panel_partially_measured: recognized=Cancel; not_measured=Export"
        )
        #expect(refusalNamesRecognizedAndMissingLabels)
    }

    @Test("a popup-bearing Cancel decoy is neither recognised nor cancelled")
    func popupBearingCancelDecoyIsNotTouched() async {
        let fixture = StemExportPanelAXFixture(
            popupValue: "General Settings",
            exportButtonTitle: "Apply",
            cancelButtonTitle: "Cancel",
            usesStemPopupStructure: false
        )
        let axSurface = AXSurface(runtime: fixture.runtime)
        let driverSurface = StemPanelSurfaceFake()
        driverSurface.panelPresenceReader = { axSurface.exportPanelPresence() }
        driverSurface.panelCloseAction = { axSurface.closeExportPanel() }

        let outcome = await driveStemPanel(driverSurface)
        let decoyWasNotRecognised = outcome == .refused(
            "stem_export_panel_not_observed_after_bounded_wait_elapsed"
        )
        #expect(decoyWasNotRecognised)
        let decoyCancelWasNotPressed = fixture.state.cancelActionAttempts == 0
        #expect(decoyCancelWasNotPressed)
    }

    @Test("a non-active per-track popup is recognised then refused at its state guard")
    func inactivePerTrackPopupUsesDedicatedStateRefusal() async {
        let fixture = StemExportPanelAXFixture(
            popupValue: "One File",
            exportButtonTitle: "Export",
            cancelButtonTitle: "Cancel"
        )
        let axSurface = AXSurface(runtime: fixture.runtime)
        let productionPresence = axSurface.exportPanelPresence()

        let panelWasRecognised = productionPresence == .present
        #expect(panelWasRecognised)
        let perTrackStateWasInactive = !axSurface.oneFilePerTrackIsActive()
        #expect(perTrackStateWasInactive)

        let driverSurface = StemPanelSurfaceFake()
        driverSurface.panelPresenceReader = { axSurface.exportPanelPresence() }
        driverSurface.perTrackActive = false
        let outcome = await driveStemPanel(driverSurface)

        let refusedAtPerTrackGuard = outcome == .refused("stem_one_file_per_track_not_active")
        #expect(refusedAtPerTrackGuard)
    }

    @Test("a descendant with no readable role makes the stem-panel census unavailable")
    func unreadableDescendantRoleDoesNotDisappearFromCensus() {
        let fixture = StemExportPanelAXFixture(
            popupValue: "One File per Track",
            exportButtonTitle: "Export",
            cancelButtonTitle: "Cancel",
            unreadablePerTrackPopupRole: true
        )
        let surface = AXSurface(runtime: fixture.runtime)

        let censusWasUnavailable = surface.exportPanelPresence() == .unavailable
        #expect(censusWasUnavailable)
        surface.closeExportPanel()
        let unreadableRoleDidNotAuthorizeCancel = fixture.state.cancelActionAttempts == 0
        #expect(unreadableRoleDidNotAuthorizeCancel)
    }

    @Test("an unmeasured stem-export panel states that it was left open")
    func unmeasuredStemExportPanelRefuses() async {
        // Deliberately synthetic button labels: neither is claimed as a Logic
        // translation, while the per-track popup remains the structural signal.
        let fixture = StemExportPanelAXFixture(
            popupValue: "Unmeasured per-track value",
            exportButtonTitle: "未測定の書き出し",
            cancelButtonTitle: "未測定の取り消し",
            popupTitle: "Location:"
        )
        let panelPresence = AXSurface(runtime: fixture.runtime).exportPanelPresence()
        let namesMissingMeasurement = panelPresence == .unmeasured(
            ProjectStemExportPanelDriver.panelLabelNotMeasuredReason
        )
        #expect(namesMissingMeasurement)

        let surface = StemPanelSurfaceFake()
        surface.panelPresence = panelPresence
        surface.dismissLabelMeasured = false
        let outcome = await driveStemPanel(surface)
        let refusedWithOpenPanelDisclosure = outcome == .refused(
            "stem_export_panel_left_open_unmeasured: "
                + ProjectStemExportPanelDriver.panelLabelNotMeasuredReason
        )
        #expect(refusedWithOpenPanelDisclosure)
    }

    @Test("an Export-known and Cancel-unknown stem panel states that it was left open")
    func exportKnownPartialPanelStatesOpenModal() async {
        let fixture = StemExportPanelAXFixture(
            popupValue: "One File per Track",
            exportButtonTitle: "Export",
            cancelButtonTitle: "Unmeasured Cancel"
        )
        let presence = AXSurface(runtime: fixture.runtime).exportPanelPresence()
        let partiallyMeasured = presence == .partiallyMeasured(
            recognized: "Export",
            notMeasured: "Cancel"
        )
        #expect(partiallyMeasured)

        let surface = StemPanelSurfaceFake()
        surface.panelPresence = presence
        surface.dismissLabelMeasured = false
        let outcome = await driveStemPanel(surface)
        let namesTheLeftOpenPanel = outcome == .refused(
            "stem_export_panel_left_open_after_close_attempt: recognized=Export; not_measured=Cancel"
        )
        #expect(namesTheLeftOpenPanel)
    }

    @Test("an unreadable open panel's descendants cannot be accepted as absent after close")
    func unreadablePanelChildrenRefuseCloseAcceptance() {
        let fixture = StemExportPanelAXFixture(
            popupValue: "One File per Track",
            exportButtonTitle: "Export",
            cancelButtonTitle: "Cancel",
            failPanelChildrenRead: true
        )
        let surface = AXSurface(runtime: fixture.runtime)

        surface.closeExportPanel()
        let presenceIsUnavailable = surface.exportPanelPresence() == .unavailable
        #expect(presenceIsUnavailable)
        let noCancelWasGuessed = fixture.state.cancelActionAttempts == 0
        #expect(noCancelWasGuessed)
    }

    @Test("an unrelated two-button dialog without the per-track popup is not a stem panel")
    func twoButtonDialogWithoutStemPopupIsIgnored() {
        let fixture = StemExportPanelAXFixture(
            popupValue: "One File per Track",
            exportButtonTitle: "Export",
            cancelButtonTitle: "Cancel",
            includesPopup: false
        )
        let surface = AXSurface(runtime: fixture.runtime)

        let panelIsNotAccepted = surface.exportPanelPresence() == .absent
        #expect(panelIsNotAccepted)
        surface.closeExportPanel()
        let unrelatedCancelWasNotPressed = fixture.state.cancelActionAttempts == 0
        #expect(unrelatedCancelWasNotPressed)
    }

    @Test("Korean all-tracks audio-file leaf resolves")
    func koreanAllTracksStemLeafResolves() {
        let resolves = ProjectStemExportPanelDriver.stemLeafTitleMatches("모든 트랙을 오디오 파일로…")
        #expect(resolves)
    }

    @Test("Korean selection-rewritten single-track audio-file leaf is rejected")
    func koreanSingleTrackStemLeafIsRejected() {
        let resolves = ProjectStemExportPanelDriver.stemLeafTitleMatches("1개의 트랙을 오디오 파일로…")
        #expect(!resolves)
    }

    @Test("Korean selection-range audio-file leaf is rejected")
    func koreanSelectionRangeStemLeafIsRejected() {
        let resolves = ProjectStemExportPanelDriver.stemLeafTitleMatches("선택 범위를 오디오 파일로…")
        #expect(!resolves)
    }

    @Test("unmeasured stem-export labels refuse instead of falling back to a guess")
    func unmeasuredLocaleStemMenuRefuses() async {
        // A synthetic Japanese-script AX title, deliberately NOT offered as a
        // Logic translation or a policy variant: this leaf has no Japanese
        // measurement, so it must remain an unrecognized title.
        let unmatchedTitle = "未測定ロケールのオーディオ書き出し"
        let titleMatches = ProjectStemExportPanelDriver.stemLeafTitleMatches(unmatchedTitle)
        #expect(!titleMatches)

        let surface = StemPanelSurfaceFake()
        surface.stemLeafAvailability = .unavailable(
            ProjectStemExportPanelDriver.stemLeafLabelNotMeasuredReason
        )
        let outcome = await driveStemPanel(surface)
        let refusalNamesMeasurement = outcome == .refused(
            ProjectStemExportPanelDriver.stemLeafLabelNotMeasuredReason
        )
        #expect(refusalNamesMeasurement)
        let leafWasNotPicked = !surface.events.contains("leaf_axpick")
        #expect(leafWasNotPicked)
    }

    // Typing a destination path DISMISSES the panel — reproduced twice live with
    // nothing written — so the folder is chosen as a browser element and the
    // destination popup re-read. No observed popup change means no Export press, State C with
    // write_attempted false, even though the browser action reported success.
    @Test("unchanged destination popup refuses before export")
    func unchangedDestinationRefusesWithoutWrite() async {
        let surface = StemPanelSurfaceFake()
        surface.destinationAfter = surface.destinationBefore
        let outcome = await driveStemPanel(surface)

        let refused = outcome == .refused("stem_destination_not_confirmed_after_browser_selection")
        #expect(refused)
        let exportWasNotPressed = !surface.events.contains { $0.hasPrefix("export_press") }
        #expect(exportWasNotPressed)
        let panelClosed = surface.panelPresence == .absent
        #expect(panelClosed)
    }

    @Test("uses AXPick for the export-menu leaf")
    func leafUsesAXPick() async {
        let surface = StemPanelSurfaceFake()
        _ = await driveStemPanel(surface)

        let picked = surface.events.contains("leaf_axpick")
        #expect(picked)
        let usesAXPick = ProjectStemExportPanelDriver.stemLeafPickAction == "AXPick"
        #expect(usesAXPick)
    }

    @Test("confirmed browser destination precedes Export")
    func confirmedBrowserDestinationPrecedesExport() async throws {
        let surface = StemPanelSurfaceFake()
        _ = await driveStemPanel(surface)

        let selected = try #require(surface.events.firstIndex(of: "destination_browser_select"))
        let export = try #require(surface.events.firstIndex(where: { $0.hasPrefix("export_press") }))
        let selectionPrecedesExport = selected < export
        #expect(selectionPrecedesExport)
    }

    @Test("missing One File per Track refuses before Export")
    func missingOneFilePerTrackRefuses() async {
        let surface = StemPanelSurfaceFake()
        surface.perTrackActive = false
        let outcome = await driveStemPanel(surface)

        let refused = outcome == .refused("stem_one_file_per_track_not_active")
        #expect(refused)
        let noExport = !surface.events.contains { $0.hasPrefix("export_press") }
        #expect(noExport)
    }

    @Test("stuck progress window is State B, never successful completion")
    func stuckProgressIsUncertain() async {
        let surface = StemPanelSurfaceFake()
        surface.progressObservations = [.present, .present, .present]
        let outcome = await driveStemPanel(surface, attempts: 3)

        let uncertain = outcome == .uncertain(
            "stem_progress_window_did_not_disappear_within_budget",
            exportEffectObserved: true
        )
        #expect(uncertain)
    }

    @Test("unseen progress window is State B, not click-return success")
    func unseenProgressIsUncertain() async {
        let surface = StemPanelSurfaceFake()
        surface.progressObservations = [.absent, .absent, .absent]
        let outcome = await driveStemPanel(surface, attempts: 3)

        let uncertain = outcome == .uncertain(
            "stem_export_press_effect_not_observed",
            exportEffectObserved: false
        )
        #expect(uncertain)
    }

    @Test("a closed panel and a private completed-file witness cover an unseen progress window")
    func fastExportRequiresFileWitnessAndClosedPanel() async {
        let surface = StemPanelSurfaceFake()
        surface.panelDisappearsAfterExportPress = true
        surface.progressObservations = [.absent, .absent]
        let result = await driveStemPanel(surface, artifactCompletion: { true })
        #expect(result == .completed)
    }

    @Test("files alone cannot complete an export while the panel remains open")
    func fileWitnessCannotSubstituteForPanelClosure() async {
        let surface = StemPanelSurfaceFake()
        surface.exportEffectOccurs = false
        let result = await driveStemPanel(surface, artifactCompletion: { true })
        #expect(result != .completed)
    }

    @Test("a failed Export action status with observed progress is treated as an observed export effect")
    func failedExportActionStatusWithObservedEffectCompletes() async {
        let surface = StemPanelSurfaceFake()
        surface.exportActionStatus = false
        surface.exportEffectOccurs = true
        let outcome = await driveStemPanel(surface)

        let completedFromObservation = outcome == .completed
        #expect(completedFromObservation)
        let fakeReportedFailure = surface.events.contains("export_press_status_false")
        #expect(fakeReportedFailure)
    }

    @Test("a successful Export action status with observed progress completes")
    func successfulExportActionStatusWithObservedEffectCompletes() async {
        let surface = StemPanelSurfaceFake()
        surface.exportActionStatus = true
        surface.exportEffectOccurs = true
        let outcome = await driveStemPanel(surface)

        let completedFromObservation = outcome == .completed
        #expect(completedFromObservation)
        let fakeReportedSuccess = surface.events.contains("export_press_status_true")
        #expect(fakeReportedSuccess)
    }

    @Test("a successful Export action status without an observed effect does not claim a bounce")
    func successfulExportActionStatusWithoutEffectIsNotFired() async {
        let surface = StemPanelSurfaceFake()
        surface.exportActionStatus = true
        surface.exportEffectOccurs = false
        let outcome = await driveStemPanel(surface)

        let noEffectWasObserved = outcome == .uncertain(
            "stem_export_press_effect_not_observed",
            exportEffectObserved: false
        )
        #expect(noEffectWasObserved)
    }

    @Test("a failed Export action status without an observed effect does not claim a bounce")
    func failedExportActionStatusWithoutEffectIsNotFired() async {
        let surface = StemPanelSurfaceFake()
        surface.exportActionStatus = false
        surface.exportEffectOccurs = false
        let outcome = await driveStemPanel(surface)

        let noEffectWasObserved = outcome == .uncertain(
            "stem_export_press_effect_not_observed",
            exportEffectObserved: false
        )
        #expect(noEffectWasObserved)
    }

    @Test("a disappearing panel without progress is not an observed export effect")
    func escapeShapedPanelDisappearanceDoesNotFireBounce() async {
        let surface = StemPanelSurfaceFake()
        surface.exportEffectOccurs = false
        surface.panelDisappearsAfterExportPress = true
        surface.progressObservations = [.absent, .absent]

        let outcome = await driveStemPanel(surface, attempts: 2)

        let didNotTreatPanelDisappearanceAsEffect = outcome == .uncertain(
            "stem_export_press_effect_not_observed",
            exportEffectObserved: false
        )
        #expect(didNotTreatPanelDisappearanceAsEffect)
    }

    @Test("a post-press unobserved effect preserves write_attempted without bounce_fired")
    func unobservedEffectMapsToActuatorReceiptWithoutBounce() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Unobserved Stem Press")
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in
            .uncertain(
                "readback_unavailable: stem_export_effect_or_progress_not_observed_after_press",
                exportEffectObserved: false
            )
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifact = try #require(run.projects.first?.artifacts.first)
        let didNotClaimBounce = !artifact.bounceFired
        #expect(didNotClaimBounce)
        let actuatorWasReached = artifact.writeAttempted
        #expect(actuatorWasReached)
    }

    @Test("panel refusal becomes State C with write_attempted false")
    func panelRefusalMapsToStateC() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Stem Panel Refusal")
        let router = await makeExportRouter()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in .refused("stem_destination_not_confirmed_after_browser_selection") }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifact = try #require(run.projects.first?.artifacts.first)
        let stateC = artifact.state == "C"
        #expect(stateC)
        let writeWasNotAttempted = !artifact.writeAttempted
        #expect(writeWasNotAttempted)
        #expect(artifact.error == "stem_destination_not_confirmed_after_browser_selection")
    }

    @Test("every panel refusal attempts to close the panel")
    func refusalClosesPanel() async {
        let surface = StemPanelSurfaceFake()
        surface.fileMenuOpens = false
        let outcome = await driveStemPanel(surface)

        let refused = outcome == .refused("stem_export_file_menu_unavailable")
        #expect(refused)
        let closed = surface.panelPresence == .absent
        #expect(closed)
    }

    @Test("a Cancel press that leaves the panel present refuses instead of claiming closure")
    func closeReadbackMustObserveAbsence() async {
        let surface = StemPanelSurfaceFake()
        surface.fileMenuOpens = false
        surface.closeChangesPanelPresence = false

        let outcome = await driveStemPanel(surface)

        let refused = outcome == .refused("stem_export_panel_remained_open_after_close_attempt")
        #expect(refused)
        let panelStillPresent = surface.panelPresence == .present
        #expect(panelStillPresent)
    }

    @Test("unavailable close readback refuses rather than assuming the panel closed")
    func closeReadbackUnavailableRefuses() async {
        let surface = StemPanelSurfaceFake()
        surface.fileMenuOpens = false
        surface.closeChangesPanelPresence = false
        surface.panelPresence = .unavailable

        let outcome = await driveStemPanel(surface)

        let refused = outcome == .refused("readback_unavailable: stem_export_panel_close_not_observed")
        #expect(refused)
    }

    @Test("silent late-bound stem is State B after analyzer verification")
    func silentStemFailsVerification() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Stem Silence")
        let output = outputRoot.appendingPathComponent("opaque-silent.wav")
        let router = await makeExportRouter()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in
            _ = try? writeSilentWav(at: output)
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        let oneResultPerSubject = artifacts.count == 2
        #expect(oneResultPerSubject)
        let unverified = artifacts.allSatisfy { $0.state == "B" && !$0.verified }
        #expect(unverified)
        let observation = try #require(artifacts.first?.observedStemOutputs?.first)
        let silenceWasObserved = (observation.reason ?? "").contains("near_silent_output")
        #expect(silenceWasObserved)
        let countMismatch = try #require(artifacts.first?.reason).contains("observed=1 expected=2")
        #expect(countMismatch)
        let notCompleted = run.status != "completed"
        #expect(notCompleted)
    }

    @Test("an empty scanned subject list is refused before a stem plan is published")
    func emptyStemSubjectsAreRefused() throws {
        let project = try makeExportPlannerProject(named: "Empty Stem Subjects")
        let outputRoot = try makeExportPlannerDirectory()
        var failure: String?

        do {
            _ = try ProjectExportPlanner.plan(
                params: [
                    "project": .string(project.path),
                    "output_root": .string(outputRoot.path),
                    "artifact": .string("stem"),
                ],
                stemSubjects: .scanned(projectPath: project.path, subjects: [])
            )
        } catch {
            failure = String(describing: error)
        }

        let refusal = try #require(failure)
        let emptySubjectReason = refusal.contains("stem_subject_list_empty")
        #expect(emptySubjectReason)
    }

    @Test("an existing directory absent from the export browser is refused before writing")
    func browserUnreachableStemDestinationRefusesAtExecution() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Browser Unreachable")
        let subjects = scannedStemSubjects(for: project)
        let plan = try ProjectExportPlanner.plan(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ],
            stemSubjects: subjects
        )
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in .refused("stem_destination_browser_selection_failed") }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: subjects
        )

        #expect(plan.status == "planned")
        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let allRefusedBeforeWrite = artifacts.allSatisfy {
            $0.state == "C" && !$0.writeAttempted && $0.error == "stem_destination_browser_selection_failed"
        }
        #expect(allRefusedBeforeWrite)
    }

    @Test("the immediately-pre-export collision snapshot is authoritative")
    func stemCollisionAppearingAfterPreflightPreventsPanelDrive() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Concurrent Collision")
        let collision = outputRoot.appendingPathComponent("writer-race.wav")
        let panelReached = BoolFlag()
        let router = await makeExportRouter(openSideEffect: {
            try? Data("other writer".utf8).write(to: collision)
        })
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in
            panelReached.set()
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        #expect(!panelReached.isSet)
        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let authoritativeRefusal = artifacts.allSatisfy {
            $0.state == "C" && ($0.error ?? "").contains("authoritative immediately-pre-export")
        }
        #expect(authoritativeRefusal)
    }

    @Test("a post-snapshot destination entry remains an unattributed State B observation")
    func postSnapshotEntryIsNotClaimedAsProduced() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Concurrent Observation")
        let concurrentEntry = outputRoot.appendingPathComponent("concurrent.wav")
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in
            _ = try? writeToneWav(at: concurrentEntry)
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        #expect(run.status == "uncertain")
        let artifact = try #require(run.projects.first?.artifacts.first)
        #expect(artifact.state == "B")
        let concurrencyCaveat = try #require(artifact.reason).contains("may have been created concurrently")
        #expect(concurrencyCaveat)
        let observation = try #require(artifact.observedStemOutputs?.first)
        #expect(observation.path == concurrentEntry.path)
    }

    @Test("stem plan publishes late-bound destination and live subjects")
    func stemPlanIsLateBound() throws {
        let project = try makeExportPlannerProject(named: "Stem Plan")
        let outputRoot = try makeExportPlannerDirectory()
        let plan = try ProjectExportPlanner.plan(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ],
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)
        let lateBound = artifact.filenamesLateBound == true
        #expect(lateBound)
        #expect(artifact.destination == outputRoot.path)
        let subjects = try #require(artifact.subjects)
        #expect(subjects.map(\.index) == [0, 1])
        #expect(subjects.map(\.name) == ["Studio Grand", "Bass / DI"])
        let noFilenamePromise = !artifact.path.hasSuffix(".wav")
        #expect(noFilenamePromise)
    }

    @Test("fail_if_exists refuses a stem destination containing audio")
    func failIfExistsRefusesExistingDestinationAudio() throws {
        let project = try makeExportPlannerProject(named: "Stem Collision")
        let outputRoot = try makeExportPlannerDirectory()
        try Data("old audio".utf8).write(to: outputRoot.appendingPathComponent("old.aif"))
        let plan = try ProjectExportPlanner.plan(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ],
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)
        let degraded = plan.status == "degraded"
        #expect(degraded)
        let blocked = artifact.verification.issues.contains("stem_destination_contains_audio")
        #expect(blocked)
        let reason = try #require(artifact.planningReason)
        let reasonExplainsWhy = reason.contains("filenames are late-bound")
        #expect(reasonExplainsWhy)
    }

    @Test("stem collision rule is top-level suffix-qualified entries, not parsed audio")
    func stemCollisionRuleIsExplicitAndShared() throws {
        let project = try makeExportPlannerProject(named: "Stem Entry Rule")
        let outputRoot = try makeExportPlannerDirectory()
        try Data("plain text with wav suffix".utf8).write(to: outputRoot.appendingPathComponent("blocks.wav"))
        try Data("not eligible".utf8).write(to: outputRoot.appendingPathComponent("ignored.flac"))
        let nested = outputRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested should be ignored".utf8).write(to: nested.appendingPathComponent("nested.aif"))

        let plan = try ProjectExportPlanner.plan(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ],
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)
        let exactlyOneEligibleEntry = artifact.verification.existingAudioFileCount == 1
        #expect(exactlyOneEligibleEntry)
        let blocked = artifact.verification.issues.contains("stem_destination_contains_audio")
        #expect(blocked)
        let rule = artifact.analysis["eligible_output_rule"]
        let publishedRule = rule == "top-level non-directory entry with suffix wav|wave|aif|aiff|aifc|m4a|mp3"
        #expect(publishedRule)
    }

    @Test("unreadable stem destination is refused instead of treated as empty")
    func unreadableStemDestinationRefuses() throws {
        let project = try makeExportPlannerProject(named: "Stem Unreadable")
        let outputRoot = try makeExportPlannerDirectory()
        let fileManager = UnreadableDirectoryFileManager(unreadablePath: outputRoot.path)

        var failure: String?
        do {
            _ = try ProjectExportPlanner.plan(
                params: [
                    "project": .string(project.path),
                    "output_root": .string(outputRoot.path),
                    "artifact": .string("stem"),
                ],
                fileManager: fileManager,
                stemSubjects: scannedStemSubjects(for: project)
            )
        } catch {
            failure = String(describing: error)
        }

        let refusal = try #require(failure)
        let refusesUnreadableDestination = refusal.contains("stem_destination_unreadable")
        #expect(refusesUnreadableDestination)
    }

    @Test("stem plans refuse unavailable subjects and batch projects rather than degrading")
    func stemPlanRefusesUnsupportedReach() throws {
        let project = try makeExportPlannerProject(named: "Stem Reach")
        let secondProject = try makeExportPlannerProject(named: "Stem Reach Second")
        let outputRoot = try makeExportPlannerDirectory()

        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ])
        }
        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(
                params: [
                    "projects": .array([.string(project.path), .string(secondProject.path)]),
                    "output_root": .string(outputRoot.path),
                    "artifact": .string("stem"),
                ],
                stemSubjects: scannedStemSubjects(for: project)
            )
        }
    }

    @Test("stem results retain observed analyzer evidence without inventing track bindings")
    func stemResultsArePerSubjectAndUnbound() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Stem Unbound")
        let first = outputRoot.appendingPathComponent("opaque-first.wav")
        let second = outputRoot.appendingPathComponent("opaque-second.wav")
        let router = await makeExportRouter()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in
            _ = try? writeToneWav(at: first)
            _ = try? writeToneWav(at: second)
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        let oneResultPerPopulatedTrack = artifacts.count == 2
        #expect(oneResultPerPopulatedTrack)
        let subjectsAreExplicit = artifacts.compactMap(\.subject).map(\.index) == [0, 1]
        #expect(subjectsAreExplicit)
        let allRemainUnbound = artifacts.allSatisfy {
            $0.state == "B" && ($0.reason ?? "").contains("file_binding_unestablished")
        }
        #expect(allRemainUnbound)
        let observations = try #require(artifacts.first?.observedStemOutputs)
        let bothOutputsObservedAfterExport = observations.map(\.path) == [first.path, second.path]
        #expect(bothOutputsObservedAfterExport)
        let observationsVerified = observations.allSatisfy(\.verified)
        #expect(observationsVerified)
        let runNeverClaimsCompleted = run.status != "completed"
        #expect(runNeverClaimsCompleted)
    }

    @Test("pre-existing stem audio produces one refusal per populated subject")
    func preexistingStemAudioRetainsSubjectCardinality() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Scoped Collision")
        try Data("old".utf8).write(to: outputRoot.appendingPathComponent("old.aif"))

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: fastOptions(identity: { project.path }),
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let scopedFailures = artifacts.allSatisfy {
            $0.state == "C" && $0.subject != nil && ($0.error ?? "").contains("overwrite_blocked")
        }
        #expect(scopedFailures)
    }

    @Test("confirmation-required stem runs retain one result per populated subject")
    func confirmationRequiredStemRetainsSubjectCardinality() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Scoped Confirmation")

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: fastOptions(identity: { project.path }),
            stemSubjects: scannedStemSubjects(for: project)
        )

        #expect(run.status == "confirmation_required")
        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let scopedConfirmation = artifacts.allSatisfy {
            $0.subject != nil && $0.error == "confirmation_required" && !$0.writeAttempted
        }
        #expect(scopedConfirmation)
    }

    @Test("a destination that becomes unreadable after planning refuses every subject")
    func stemReadabilityTransitionRetainsSubjectCardinality() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Readability Transition")
        let fileManager = ReadableThenUnreadableStemDirectoryFileManager(
            destination: outputRoot.path,
            readableEnumerations: 2
        )
        let panelReached = BoolFlag()
        var options = fastOptions(identity: { project.path })
        options.fileManager = fileManager
        options.driveStemExport = { _ in
            panelReached.set()
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        #expect(!panelReached.isSet)
        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let unreadableRefusals = artifacts.allSatisfy {
            $0.subject != nil && ($0.error ?? "").contains("overwrite_check_unavailable")
        }
        #expect(unreadableRefusals)
    }

    @Test("skip_existing refuses the stem plan instead of returning a degraded manifest")
    func skipExistingStemRefused() throws {
        let project = try makeExportPlannerProject(named: "Stem Skip")
        let outputRoot = try makeExportPlannerDirectory()
        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(
                params: [
                    "project": .string(project.path),
                    "output_root": .string(outputRoot.path),
                    "artifact": .string("stem"),
                    "collision_policy": .string("skip_existing"),
                ],
                stemSubjects: scannedStemSubjects(for: project)
            )
        }
    }

    @Test("export_resume refuses stems before opening a project")
    func stemResumeRefused() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Stem Resume")
        let router = await makeExportRouter()
        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: true,
            options: fastOptions(identity: { project.path }),
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let allAreScopedRefusals = artifacts.allSatisfy {
            $0.state == "C" && $0.subject != nil && !$0.writeAttempted
                && ($0.error ?? "").contains("filenames only after export")
        }
        #expect(allAreScopedRefusals)
    }
}
