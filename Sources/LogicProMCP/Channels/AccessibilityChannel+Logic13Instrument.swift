import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// Logic 13 presents installed patches in an Instruments table. Keep the
    /// selection and materialization checks tied to one retained project and row.
    static func setLogic13Instrument(
        index: Int, path: String, preset: String, runtime: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let ax = runtime.ax
        var attempted = false
        func failure(_ hint: String) -> ChannelResult {
            let fields: [String: Any] = ["operation": "track.set_instrument", "requested_path": path,
                "target_track_index": index, "write_attempted": attempted, "safe_to_retry": false, "hint": hint]
            if attempted { return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: fields)) }
            return .error(HonestContract.encodeStateC(error: .readbackUnavailable, hint: hint, extras: fields))
        }
        guard let pid = runtime.logicProPID(), let app = AXLogicProElements.appRoot(runtime: runtime),
              case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
              case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              headers.indices.contains(index) else { return failure("The target Arrange track could not be held.") }
        func current() -> Bool {
            guard !Task.isCancelled, runtime.focusedApplicationPID() == pid,
                  case .success(let observed?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  observed.utf8.elementsEqual(document.utf8),
                  let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: ax),
                  windows.count == 1, CFEqual(windows[0], window),
                  case .read(let rows) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
                  rows.count == headers.count, zip(rows, headers).allSatisfy({ CFEqual($0, $1) }) else { return false }
            return rows.enumerated().allSatisfy {
                AXValueExtractors.extractSelectedState($0.element, runtime: ax) == ($0.offset == index)
            }
        }
        guard current(), let toolbar = AXLogicProElements.directLogic13Toolbar(in: window, runtime: ax),
              let play = AXLogicProElements.directToolbarControl(AXLocalePolicy.transportPlayControl, in: toolbar, runtime: ax),
              let record = AXLogicProElements.directToolbarControl(AXLocalePolicy.transportRecordControl, in: toolbar, runtime: ax),
              let library = AXLogicProElements.directToolbarControl(AXLocalePolicy.libraryPanelLabel, in: toolbar, runtime: ax),
              let open = AXValueExtractors.extractButtonState(library, runtime: ax) else {
            return failure("The selected track, stopped transport, or Library control could not be verified.")
        }
        func stopped() -> Bool {
            AXValueExtractors.extractButtonState(play, runtime: ax) == false
                && AXValueExtractors.extractButtonState(record, runtime: ax) == false
        }
        guard stopped() else { return failure("The transport is active or unreadable.") }
        if !open {
            guard current(), stopped(), OperationTraceContext.claimDeadlineEffect("logic13_open_instrument_browser") else {
                return failure("Project scope changed before the Library could open.")
            }
            attempted = true
            _ = AXHelpers.performAction(library, kAXPressAction, runtime: ax)
        }
        func browserTable() -> AXUIElement? {
            guard current(), case .success(let children) = AXHelpers.childrenResult(window, runtime: ax) else { return nil }
            let browsers = children.filter { AXHelpers.getRole($0, runtime: ax) == kAXGroupRole as String
                && AXHelpers.getDescription($0, runtime: ax) == "Browser" }
            guard browsers.count == 1,
                  let nodes = logic13InstrumentNodes(browsers[0], depth: 8, terminalRoles: [kAXTableRole as String], runtime: ax)
            else { return nil }
            func checked(_ label: String) -> Bool {
                let controls = nodes.filter { AXHelpers.getRole($0, runtime: ax) == kAXCheckBoxRole as String
                    && AXHelpers.getDescription($0, runtime: ax) == label }
                return controls.count == 1 && AXValueExtractors.extractButtonState(controls[0], runtime: ax) == true
            }
            guard checked("Instruments"), checked("Link to selection"), checked("Replace on selection") else { return nil }
            let tables = nodes.filter { AXHelpers.getRole($0, runtime: ax) == kAXTableRole as String }
            return tables.count == 1 ? tables[0] : nil
        }
        var table: AXUIElement?
        for _ in 0..<12 {
            if let found = browserTable() { table = found; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // AXChildren contains thousands of virtual patch rows in Logic 13. Only visible rows
        // expose their usable labels and controls. The exact stock patch must be on this page.
        func visibleRows(in table: AXUIElement) -> [AXUIElement]? {
            guard case .success(.some(let rows)) = AXHelpers.getAttributeResult(
                table, "AXVisibleRows", runtime: ax) as Result<[AXUIElement]?, AXHelpers.AXStatusError>,
                !rows.isEmpty, rows.count <= 256 else { return nil }
            return rows
        }
        guard let table, let rows = visibleRows(in: table) else {
            return failure("The visible Instruments rows could not be verified.")
        }
        var matches: [AXUIElement] = []
        for row in rows {
            guard AXHelpers.getRole(row, runtime: ax) == kAXRowRole as String,
                  let nodes = logic13InstrumentNodes(row, depth: 3, terminalRoles: [], runtime: ax) else {
                return failure("A visible Instruments row could not be read.")
            }
            let exactTitle = nodes.contains {
                AXHelpers.getRole($0, runtime: ax) == kAXStaticTextRole as String
                    && (AXHelpers.getValue($0, runtime: ax) as? String)?.utf8.elementsEqual(preset.utf8) == true
            }
            let instrumentPatch = nodes.contains {
                AXHelpers.getDescription($0, runtime: ax) == "Instrument Patch, Play preview"
            }
            if exactTitle && instrumentPatch { matches.append(row) }
        }
        guard matches.count == 1, let row = matches.first, let repeated = browserTable(), CFEqual(table, repeated),
              let latestRows = visibleRows(in: table), latestRows.count == rows.count,
              zip(latestRows, rows).allSatisfy({ CFEqual($0, $1) }),
              AXHelpers.isAttributeSettable(table, kAXSelectedRowsAttribute as String, runtime: ax) == true,
              current(), stopped(), OperationTraceContext.claimDeadlineEffect("logic13_select_instrument_patch") else {
            return failure("The requested instrument patch was unavailable or ambiguous in the observed table.")
        }
        attempted = true
        _ = AXHelpers.setAttribute(table, kAXSelectedRowsAttribute, [row] as CFArray, runtime: ax)
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard current() else { return failure("Project or track selection changed during patch loading.") }
            guard AXValueExtractors.extractSelectedState(row, runtime: ax) == true,
                  let name = AXLogicProElements.trackName(at: index, runtime: runtime),
                  logic13StudioGrandInspector(named: name, in: window, runtime: ax) else { continue }
            if current(), stopped() {
                return .success(HonestContract.encodeStateA(extras: [
                    "operation": "track.set_instrument", "requested_path": path, "observed_patch_name": preset,
                    "target_track_index": index, "target_track_name": name, "write_attempted": true,
                    "verify_source": "selected_browser_row_and_bound_inspector_settings"
                ]))
            }
        }
        return failure("The patch selection was sent but its Inspector settings could not be verified.")
    }

    static func logic13StudioGrandInspector(
        named name: String, in window: AXUIElement, runtime: AXHelpers.Runtime
    ) -> Bool {
        guard case .success(let children) = AXHelpers.childrenResult(window, runtime: runtime) else { return false }
        let inspectors = children.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXGroupRole as String
                && AXHelpers.getDescription($0, runtime: runtime) == "Inspector"
        }
        guard inspectors.count == 1,
              let nodes = logic13InstrumentNodes(inspectors[0], depth: 5,
                terminalRoles: [kAXLayoutItemRole as String], runtime: runtime) else { return false }
        let leftStrips = nodes.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXLayoutItemRole as String
                && AXLocalePolicy.inspectorChannelStripHelpPrefix.hasPrefixAny(
                    AXHelpers.getHelp($0, runtime: runtime) ?? "")
        }
        guard leftStrips.count == 1,
              AXHelpers.getDescription(leftStrips[0], runtime: runtime)?.utf8.elementsEqual(name.utf8) == true,
              case .success(let slots) = AXHelpers.childrenResult(leftStrips[0], runtime: runtime) else { return false }
        let settings = slots.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXButtonRole as String
                && AXHelpers.getDescription($0, runtime: runtime) == "Studio Grand"
                && (AXHelpers.getHelp($0, runtime: runtime) ?? "").hasPrefix("Setting button.")
        }
        let midiEffects = slots.filter {
            AXHelpers.getDescription($0, runtime: runtime) == "MIDI plug-in"
                && (AXHelpers.getHelp($0, runtime: runtime) ?? "").hasPrefix("MIDI Effect slot")
        }
        let piano = slots.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXGroupRole as String
                && AXHelpers.getDescription($0, runtime: runtime) == "Piano"
        }
        guard settings.count == 1, midiEffects.count == 1, piano.count == 1,
              case .success(let controls) = AXHelpers.childrenResult(piano[0], runtime: runtime) else { return false }
        return controls.filter {
            AXHelpers.getRole($0, runtime: runtime) == kAXButtonRole as String
                && AXHelpers.getDescription($0, runtime: runtime) == "open"
        }.count == 1
    }

    private static func logic13InstrumentNodes(
        _ root: AXUIElement, depth: Int, terminalRoles: Set<String>, runtime: AXHelpers.Runtime
    ) -> [AXUIElement]? {
        var pending = [(root, 0)]
        var result: [AXUIElement] = []
        while let (node, level) = pending.popLast() {
            guard !Task.isCancelled, result.count < 128, let role = AXHelpers.getRole(node, runtime: runtime),
                  !result.contains(where: { CFEqual($0, node) }) else { return nil }
            result.append(node)
            let description = AXHelpers.getDescription(node, runtime: runtime)
            if level == depth || terminalRoles.contains(role) || description == "User Content"
                || [kAXStaticTextRole as String, kAXButtonRole as String, kAXCheckBoxRole as String,
                    kAXTextFieldRole as String].contains(role) { continue }
            switch AXHelpers.childrenResult(node, runtime: runtime) {
            case .success(let children): pending.append(contentsOf: children.reversed().map { ($0, level + 1) })
            case .failure(let error) where error.isDefinitiveAbsence: break
            case .failure: return nil
            }
        }
        return result
    }
}
