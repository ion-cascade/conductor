import ApplicationServices
import Foundation

/// Reuses one Controls window on the selected instrument slot. Only an explicit
/// preparation read may open a window, which remains visible after success.
/// Parameter elements are reacquired from the current table; only the physical
/// track and instrument-slot carrier survive between requests.
@MainActor
final class RetroSynthNative {
    typealias Failure = RetroSynthSnapshot.Failure
    struct AcquisitionFailure: Error {
        let reason: String
        let uiRestored: Bool
    }
    let slot: RetroSynthSlot
    let runtime: AXLogicProElements.Runtime
    let pid: pid_t
    let app: AXUIElement
    let editor: AXUIElement
    let openedEditor: Bool
    let originalView: String
    var originalScroll: Double?

    private init(slot: RetroSynthSlot, pid: pid_t, app: AXUIElement,
                 editor: AXUIElement, opened: Bool, originalView: String) {
        self.slot = slot
        runtime = slot.physical.runtime
        self.pid = pid
        self.app = app
        self.editor = editor
        openedEditor = opened
        self.originalView = originalView
    }

    static func acquire(slot: RetroSynthSlot, openEditor: Bool = false) async throws -> RetroSynthNative {
        let runtime = slot.physical.runtime
        guard AXIsProcessTrusted(), let pid = runtime.logicProPID(),
              let host = runtime.observeHost(pid), host.logicVersion == RetroSynthProfile.logicVersion,
              host.logicBuild == RetroSynthProfile.logicBuild,
              ProjectScore.foreground(pid, runtime: runtime), slot.isCurrent(),
              let app = AXLogicProElements.appRoot(runtime: runtime),
              let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax),
              let activity = try? AXLogicProElements.observedTransportActivity(in: slot.physical.window, runtime: runtime, checking: {}),
              !activity.isPlaying, !activity.isRecording else { throw Failure.unavailable("instrument_context") }
        let visible = windows.filter { AXHelpers.getRole($0, runtime: runtime.ax) != kAXHelpTagRole }
        guard visible.filter({ CFEqual($0, slot.physical.window) }).count == 1 else { throw Failure.unavailable("project_window") }
        func candidate(_ window: AXUIElement) -> Bool {
            guard AXHelpers.getTitle(window, runtime: runtime.ax) == slot.name,
                  case .success(let children) = AXHelpers.childrenResult(window, runtime: runtime.ax) else { return false }
            return children.filter {
                AXHelpers.getRole($0, runtime: runtime.ax) == kAXStaticTextRole
                    && (AXHelpers.getAttribute($0, kAXValueAttribute, runtime: runtime.ax) as String?) == "Retro Synth"
            }.count == 1
        }
        var found = visible.filter(candidate)
        let opened = found.isEmpty
        guard visible.count == (opened ? 1 : 2), found.count <= 1 else { throw Failure.unavailable("other_editor_or_dialog") }
        // Recreating Controls cells on every request showed bounded, repeatable
        // host memory growth. Never do that implicitly, including for writes.
        guard !opened || openEditor else { throw Failure.unavailable("controls_editor_required") }
        var pressedOpen = false
        do {
            if opened {
                guard slot.isCurrent(), ProjectScore.foreground(pid, runtime: runtime),
                      OperationTraceContext.claimDeadlineEffect("retro_open_editor", rejectTaskCancellationWithoutContext: true) else {
                    throw Failure.unavailable("open_editor_authority")
                }
                _ = AXHelpers.performAction(slot.openButton, kAXPressAction, runtime: runtime.ax)
                pressedOpen = true
                for _ in 0..<30 {
                    try Task.checkCancellation()
                    guard slot.isCurrent(), ProjectScore.foreground(pid, runtime: runtime),
                          let current: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax) else {
                        throw Failure.unavailable("editor_acquisition_changed")
                    }
                    found = current.filter(candidate)
                    if found.count == 1 { break }
                    try await Task.sleep(for: .milliseconds(80))
                }
            }
            guard found.count == 1, let editor = found.first,
                  case .success(let children) = AXHelpers.childrenResult(editor, runtime: runtime.ax) else {
                throw Failure.unavailable("editor_unavailable")
            }
            let views = children.filter {
                AXHelpers.getRole($0, runtime: runtime.ax) == "AXMenuButton"
                    && AXHelpers.getDescription($0, runtime: runtime.ax) == "view"
            }
            guard views.count == 1, let view = AXHelpers.getTitle(views[0], runtime: runtime.ax), !view.isEmpty else {
                throw Failure.unavailable("editor_view_unknown")
            }
            guard opened || view == "Controls" else { throw Failure.unavailable("controls_editor_required") }
            let source = RetroSynthNative(slot: slot, pid: pid, app: app, editor: editor, opened: opened, originalView: view)
            if let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: runtime.ax),
               !CFEqual(focused, editor), slot.isCurrent(), ProjectScore.foreground(pid, runtime: runtime),
               OperationTraceContext.claimDeadlineEffect("retro_focus_editor", rejectTaskCancellationWithoutContext: true) {
                _ = AXHelpers.performAction(editor, kAXRaiseAction, runtime: runtime.ax)
                try await Task.sleep(for: .milliseconds(100))
            }
            guard source.holdsTarget() else { throw Failure.unavailable("editor_not_focused") }
            let population = try source.nodes(editor, depth: 6, capacity: 2000)
            guard !population.contains(where: { AXHelpers.getRole($0, runtime: runtime.ax) == kAXMenuRole }) else {
                throw Failure.unavailable("preexisting_editor_menu")
            }
            return source
        } catch {
            // Once Open has been pressed, acquisition can be cancelled before
            // the editor is returned. Retire only the uniquely identified editor
            // created by this acquisition, under the original document guard.
            if pressedOpen {
                var restored = false
                if let current: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax) {
                    let owned = current.filter(candidate)
                    if owned.count == 1, let editor = owned.first {
                        let cleanup = RetroSynthNative(slot: slot, pid: pid, app: app,
                            editor: editor, opened: true, originalView: "")
                        restored = await cleanup.cleanup()
                    }
                }
                throw AcquisitionFailure(reason: String(describing: error), uiRestored: restored)
            }
            throw error
        }
    }

    func holdsTarget() -> Bool {
        guard !Task.isCancelled, runtime.logicProPID() == pid,
              ProjectScore.foreground(pid, runtime: runtime), slot.isCurrent(),
              let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: runtime.ax),
              CFEqual(focused, editor),
              let activity = try? AXLogicProElements.observedTransportActivity(in: slot.physical.window, runtime: runtime, checking: {}),
              !activity.isPlaying, !activity.isRecording,
              let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax) else { return false }
        let visible = windows.filter { AXHelpers.getRole($0, runtime: runtime.ax) != kAXHelpTagRole }
        guard case .success(let controls) = AXHelpers.childrenResult(editor, runtime: runtime.ax) else { return false }
        guard case .success(let projectChildren) = AXHelpers.childrenResult(slot.physical.window, runtime: runtime.ax),
              (controls + projectChildren).allSatisfy({
                  guard let role = AXHelpers.getRole($0, runtime: runtime.ax) else { return false }
                  return role != kAXSheetRole
              }) else { return false }
        let links = controls.filter {
            AXHelpers.getRole($0, runtime: runtime.ax) == kAXCheckBoxRole
                && AXHelpers.getDescription($0, runtime: runtime.ax) == "link"
        }
        let owners = controls.filter {
            AXHelpers.getRole($0, runtime: runtime.ax) == kAXStaticTextRole
                && (AXHelpers.getAttribute($0, kAXValueAttribute, runtime: runtime.ax) as String?) == slot.name
        }
        guard links.count == 1, owners.count == 1,
              case .success(.some(false)) = AXValueExtractors.extractButtonStateResult(links[0], runtime: runtime.ax) else { return false }
        return visible.count == 2 && visible.contains { CFEqual($0, editor) }
            && visible.contains { CFEqual($0, slot.physical.window) }
    }

    func children(_ node: AXUIElement) throws -> [AXUIElement] {
        switch AXHelpers.childrenResult(node, runtime: runtime.ax) {
        case .success(let values): return values
        case .failure(let error) where error.isDefinitiveAbsence: return []
        case .failure: throw Failure.unavailable("native_children_unreadable")
        }
    }

    func nodes(_ root: AXUIElement, depth: Int = 6, capacity: Int = 100) throws -> [AXUIElement] {
        try RetroSynthSlot.descendants(root, runtime: runtime.ax, maximumDepth: depth, capacity: capacity)
    }

    func table() throws -> AXUIElement {
        guard holdsTarget() else { throw Failure.unavailable("target_lost") }
        let matches = try nodes(editor, depth: 3, capacity: 400).filter {
            AXHelpers.getRole($0, runtime: runtime.ax) == kAXTableRole
        }
        guard matches.count == 1, let table = matches.first else { throw Failure.unavailable("controls_table") }
        return table
    }

    func rows() throws -> [AXUIElement] {
        let table = try table()
        guard let rows: [AXUIElement] = AXHelpers.getAttribute(table, kAXRowsAttribute, runtime: runtime.ax), rows.count == 83 else {
            throw Failure.unavailable("controls_row_population")
        }
        return rows
    }

    func row(_ label: String) throws -> AXUIElement {
        let current = try rows()
        guard let index = RetroSynthFactoryBaseline.labels.firstIndex(of: label), current.indices.contains(index),
              try rowLabel(current[index]) == label else { throw Failure.unavailable("row_address_changed") }
        return current[index]
    }

    func rowLabel(_ row: AXUIElement) throws -> String? {
        let texts = try nodes(row).filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXStaticTextRole }
        guard texts.count <= 1 else { throw Failure.unavailable("ambiguous_row_label") }
        guard let text = texts.first else { return nil }
        return try string(text, kAXValueAttribute, required: true)
    }

    func controls(_ row: AXUIElement) throws -> [AXUIElement] {
        try nodes(row).filter {
            [kAXSliderRole, kAXValueIndicatorRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole]
                .contains(AXHelpers.getRole($0, runtime: runtime.ax) ?? "")
        }
    }

    func string(_ node: AXUIElement, _ key: String, required: Bool = false) throws -> String? {
        switch AXHelpers.getAttributeResult(node, key, runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError> {
        case .success(let value):
            guard !required || value != nil else { throw Failure.unavailable("required_text_absent") }
            return value
        case .failure(let error) where error.isDefinitiveAbsence && !required: return nil
        case .failure: throw Failure.unavailable("text_unreadable")
        }
    }

    func controlState(_ control: AXUIElement) throws -> RetroSynthSnapshot.Control {
        guard let role = AXHelpers.getRole(control, runtime: runtime.ax) else { throw Failure.unavailable("control_role") }
        let value: RetroSynthSnapshot.Scalar
        if role == kAXCheckBoxRole || role == kAXRadioButtonRole {
            guard case .success(.some(let boolean)) = AXValueExtractors.extractButtonStateResult(control, runtime: runtime.ax) else {
                throw Failure.unavailable("boolean_unreadable")
            }
            value = .boolean(boolean)
        } else if role == kAXPopUpButtonRole {
            guard let text = try string(control, kAXValueAttribute, required: true), !text.isEmpty else { throw Failure.unavailable("popup_unreadable") }
            value = .text(text)
        } else {
            switch AXHelpers.getAttributeResult(control, kAXValueAttribute, runtime: runtime.ax) as Result<NSNumber?, AXHelpers.AXStatusError> {
            case .success(.some(let number)) where CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite:
                value = .number(number.doubleValue)
            default: throw Failure.unavailable("number_unreadable")
            }
        }
        return .init(role: role, value: value, display: try string(control, kAXValueDescriptionAttribute) ?? "")
    }

    func snapshot() throws -> RetroSynthSnapshot {
        guard holdsTarget() else { throw Failure.unavailable("target_lost") }
        let direct = try children(editor)
        let settings = direct.filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXPopUpButtonRole }
        guard settings.count == 1,
              let preset = try string(settings[0], kAXValueAttribute, required: true) else {
            throw Failure.unavailable("instrument_header")
        }
        let enabled = try RetroSynthPowerState.observe(boundInstrumentGroup: slot.group,
            editorChildren: direct, runtime: runtime.ax)
        var values: [RetroSynthSnapshot.Row] = []
        for row in try rows() {
            let label = try rowLabel(row)
            let native = try controls(row)
            if label == "Filter State:" { try validateFilterRadios(native) }
            values.append(try .init(label: label, controls: native.map(controlState)))
        }
        guard holdsTarget() else { throw Failure.unavailable("snapshot_context_changed") }
        let result = RetroSynthSnapshot(preset: preset, rows: values, enabled: enabled)
        try result.validateLayout()
        for parameter in RetroSynthProfile.parameters { _ = try result.observation(parameter) }
        return result
    }

    /// Two matching complete censuses bound the issued before-state. This is
    /// stable readback, not an atomic host transaction.
    func stableSnapshot() async throws -> RetroSynthSnapshot {
        let before = try snapshot()
        try await pause()
        let after = try snapshot()
        guard try before.fingerprint == after.fingerprint else {
            throw Failure.unavailable("instrument_changed_during_read")
        }
        return after
    }

    func validateFilterRadios(_ controls: [AXUIElement]) throws {
        guard controls.count == 2,
              controls.allSatisfy({ AXHelpers.getRole($0, runtime: runtime.ax) == kAXRadioButtonRole }),
              try controls.map({ try string($0, kAXTitleAttribute, required: true) }) == ["Bypass", "Active"] else {
            throw Failure.unavailable("filter_state_address")
        }
    }

    func scalar(_ label: String) throws -> (control: AXUIElement, position: Int, display: String) {
        let row = try row(label)
        let native = try controls(row)
        let state = try RetroSynthSnapshot.Row(label: label, controls: native.map(controlState))
        let sample = try RetroSynthSnapshot(preset: "", rows: [state]).scalar(label)
        let displayed = try native.filter { !(try string($0, kAXValueDescriptionAttribute) ?? "").isEmpty }
        guard displayed.count == 1, let control = displayed.first else { throw Failure.unavailable("scalar_address") }
        return (control, sample.position, sample.display)
    }

    func pause() async throws { try await Task.sleep(for: .milliseconds(40)) }
}
