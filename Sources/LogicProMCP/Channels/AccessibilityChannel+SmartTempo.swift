import ApplicationServices
import Foundation

extension AccessibilityChannel {
    func readRegionSmartTempo(reference: String, runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        let operation = "project.get_region_smart_tempo"
        let ax = runtime.ax
        var receipt: [String: Any] = ["operation": operation, "target_ref": reference, "write_attempted": false]
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: error, hint: hint, extras: receipt))
        }
        guard let snapshot = regionScan, ContinuousClock.now < snapshot.expires,
              let held = snapshot.targets[reference] else {
            return refuse(.staleTargetReference, "Scan the project for a current region reference.")
        }
        guard held.info.kind == "audio" else {
            return refuse(.unsupportedState, "Select one ordinary audio region.")
        }
        func selected(_ scope: ArrangeRegionScope) -> Bool {
            guard let items = AXLogicProElements.logic13RegionItems(in: scope.content, runtime: ax),
                  items.filter({ CFEqual($0, held.item) }).count == 1, scope.selectionIsOriginal(),
                  scope.originalSelection.allSatisfy({ CFEqual($0, held.item) }) else { return false }
            return items.allSatisfy {
                AXValueExtractors.extractSelectedState($0, runtime: ax) == CFEqual($0, held.item)
            }
        }
        func hasTarget(_ scope: ArrangeRegionScope) -> Bool {
            guard scope.document == snapshot.document, CFEqual(scope.window, snapshot.window),
                  scope.holdsHeaders(),
                  scope.headers.indices.contains(held.info.trackIndex),
                  CFEqual(scope.headers[held.info.trackIndex], held.header),
                  AXTrackBinding.presentation(of: held.header, runtime: ax) == held.headerPresentation,
                  let rows = Self.regionEditCensus(scope: scope) else { return false }
            return rows.filter {
                Self.isOrdinaryRegion($0.info) && Self.sameRegionObservation(held, item: $0.item, info: $0.info)
            }.count == 1
        }
        guard let scope = ArrangeRegionScope(runtime: runtime), hasTarget(scope) else {
            return refuse(.staleTargetReference, "Re-scan the stopped project with the referenced region visible.")
        }
        guard selected(scope), let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
              runtime.observeHost(pid)?.logicVersion?.hasPrefix("13.") == true else {
            return refuse(.unsupportedState, "Select only the referenced region in desktop Logic Pro 13.")
        }
        func windows() -> [AXUIElement]? {
            let array: [AXUIElement]? = AXHelpers.getAttribute(scope.app, kAXWindowsAttribute, runtime: ax)
            return array?.filter { AXHelpers.getRole($0, runtime: ax) != kAXHelpTagRole }
        }
        guard let initial = windows(), initial.count == 1, CFEqual(initial[0], scope.window),
              let title = AXHelpers.getTitle(scope.window, runtime: ax), title.hasSuffix(" - Tracks"),
              let command = AXLogicProElements.menuItem(path: ["Window", "Open Smart Tempo Editor"], runtime: runtime),
              (AXHelpers.getAttribute(command, kAXEnabledAttribute, runtime: ax) as Bool?) == true,
              !Task.isCancelled, scope.holdsArrange(), selected(scope) else {
            return refuse(.readbackUnavailable, "Close other Logic windows and expose Window > Open Smart Tempo Editor.")
        }
        let editorTitle = String(title.dropLast(" - Tracks".count)) + " - Beats"
        _ = AXHelpers.performAction(command, kAXPressAction, runtime: ax)
        func owns(_ editor: AXUIElement) -> Bool {
            guard let visible = windows(), visible.count == 2, visible.contains(where: { CFEqual($0, scope.window) }),
                  visible.contains(where: { CFEqual($0, editor) }),
                  AXHelpers.getTitle(editor, runtime: ax) == editorTitle,
                  AXHelpers.getRole(editor, runtime: ax) == kAXWindowRole,
                  (AXHelpers.getAttribute(editor, kAXSubroleAttribute, runtime: ax) as String?) == kAXStandardWindowSubrole,
                  let focused: AXUIElement = AXHelpers.getAttribute(scope.app, kAXFocusedWindowAttribute, runtime: ax),
                  CFEqual(focused, editor), runtime.focusedApplicationPID() == pid,
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(scope.window, runtime: runtime),
                  document == snapshot.document else { return false }
            return true
        }
        var ownedEditor: AXUIElement?
        for _ in 0..<15 {
            if let visible = windows(), let editor = visible.first(where: { !CFEqual($0, scope.window) }),
               owns(editor) {
                ownedEditor = editor
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let editor = ownedEditor else {
            return refuse(.windowIdentityUnresolved, "Logic did not expose the owned Smart Tempo analysis window.")
        }

        let first = Self.smartTempoObservation(editor, runtime: ax)
        let second = Self.smartTempoObservation(editor, runtime: ax)
        guard owns(editor), let close: AXUIElement = AXHelpers.getAttribute(editor, kAXCloseButtonAttribute, runtime: ax),
              AXHelpers.performAction(close, kAXPressAction, runtime: ax) else {
            receipt["editor_close_observed"] = false
            return refuse(.windowIdentityUnresolved, "The Smart Tempo window could not be closed under verified ownership.")
        }
        var restored = false
        for _ in 0..<10 {
            if let after = ArrangeRegionScope(runtime: runtime, afterOwnedEdit: true), hasTarget(after), selected(after),
               let visible = windows(), visible.count == 1, CFEqual(visible[0], scope.window) {
                restored = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        receipt["editor_close_observed"] = restored
        guard restored else {
            return refuse(.windowIdentityUnresolved, "The original region selection could not be confirmed after closing Smart Tempo.")
        }
        guard !Task.isCancelled, let first, second == first else {
            return refuse(.readbackUnavailable, "Analyze the region in Logic and expose its first downbeat in the Smart Tempo Editor.")
        }
        receipt["region"] = held.info.name
        receipt["tempo_bpm"] = first.tempo
        receipt["first_downbeat_source_sample"] = first.firstDownbeat
        receipt["verify_source"] = "logic13_smart_tempo_editor"
        return .success(HonestContract.encodeStateA(extras: receipt))
    }

    struct SmartTempoObservation: Equatable {
        let tempo: Double
        let firstDownbeat: Int
    }

    static func smartTempoObservation(_ editor: AXUIElement, runtime: AXHelpers.Runtime) -> SmartTempoObservation? {
        func direct(_ owner: AXUIElement, description: String) -> AXUIElement? {
            guard case .success(let children) = AXHelpers.childrenResult(owner, runtime: runtime) else { return nil }
            let groups = children.filter {
                AXHelpers.getRole($0, runtime: runtime) == kAXGroupRole &&
                    AXHelpers.getDescription($0, runtime: runtime) == description
            }
            return groups.count == 1 ? groups.first : nil
        }
        guard let pane = direct(editor, description: "Smart Tempo"),
              let content = direct(pane, description: "Smart Tempo contents") else { return nil }
        let fields = AXHelpers.findAllDescendants(of: content, role: kAXTextFieldRole, maxDepth: 3, runtime: runtime).filter {
            (AXHelpers.getAttribute($0, kAXHelpAttribute, runtime: runtime) as String?)?.hasPrefix("Shows the tempo of the audio file.") == true
        }
        let displays = AXHelpers.findAllDescendants(of: content, role: kAXGroupRole, maxDepth: 3, runtime: runtime).filter {
            AXHelpers.getDescription($0, runtime: runtime) == "Smart Tempo editor"
        }
        guard fields.count == 1, displays.count == 1,
              let raw: String = AXHelpers.getAttribute(fields[0], kAXValueAttribute, runtime: runtime),
              let tempo = Double(raw.trimmingCharacters(in: .whitespaces)), tempo.isFinite, tempo > 0,
              let grid = direct(displays[0], description: "Editor"),
              let downbeat = direct(grid, description: "Downbeat, Bar 1"),
              case .success(let controls) = AXHelpers.childrenResult(downbeat, runtime: runtime) else { return nil }
        let markers = controls.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXValueIndicatorRole &&
                AXHelpers.getDescription($0, runtime: runtime) == "Move Marker"
        }
        guard markers.count == 1,
              let sample: Int = AXHelpers.getAttribute(markers[0], kAXValueAttribute, runtime: runtime),
              sample >= 0,
              (AXHelpers.getAttribute(markers[0], kAXValueDescriptionAttribute, runtime: runtime) as String?) == "\(sample) samples" else {
            return nil
        }
        return .init(tempo: tempo, firstDownbeat: sample)
    }
}
