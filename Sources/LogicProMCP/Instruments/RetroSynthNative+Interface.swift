import ApplicationServices
import Foundation

extension RetroSynthNative {
    func viewButton() throws -> AXUIElement {
        let buttons = try children(editor).filter {
            AXHelpers.getRole($0, runtime: runtime.ax) == "AXMenuButton"
                && AXHelpers.getDescription($0, runtime: runtime.ax) == "view"
        }
        guard buttons.count == 1, let button = buttons.first else { throw Failure.unavailable("view_button") }
        return button
    }

    func showView(_ name: String, cleanup: Bool = false) async throws {
        func permitted() -> Bool { cleanup ? cleanupPermitted() : holdsTarget() }
        guard permitted() else { throw Failure.unavailable("view_context") }
        let button = try viewButton()
        let title = AXHelpers.getTitle(button, runtime: runtime.ax)
        if name == "Controls", title == "Controls" { return }
        if name == "Editor", title != "Controls" { return }
        guard cleanup || OperationTraceContext.claimDeadlineEffect("retro_view_menu", rejectTaskCancellationWithoutContext: true) else {
            throw Failure.unavailable("view_authority")
        }
        _ = AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax)
        var owned: AXUIElement?
        do {
            let menu = try await waitForMenu(under: button, cleanup: cleanup, permitted: permitted)
            owned = menu
            let choices = try children(menu).filter {
                AXHelpers.getRole($0, runtime: runtime.ax) == kAXMenuItemRole
                    && AXHelpers.getTitle($0, runtime: runtime.ax) == name
            }
            guard choices.count == 1, permitted(),
                  (AXHelpers.getAttribute(choices[0], kAXEnabledAttribute, runtime: runtime.ax) as Bool?) == true else {
                throw Failure.unavailable("view_choice")
            }
            _ = AXHelpers.performAction(choices[0], kAXPressAction, runtime: runtime.ax)
            for _ in 0..<30 {
                if !cleanup { try Task.checkCancellation() }
                guard permitted() else { throw Failure.unavailable("view_changed_context") }
                let fresh = try viewButton()
                let now = AXHelpers.getTitle(fresh, runtime: runtime.ax)
                if name == "Controls", now == "Controls", (try? table()) != nil { return }
                if name == "Editor", now != "Controls", now == originalView { return }
                try await interfacePause(cleanup: cleanup, milliseconds: 60)
            }
            throw Failure.unavailable("view_readback_timeout")
        } catch {
            if let owned, cleanupPermitted() { _ = AXHelpers.performAction(owned, kAXCancelAction, runtime: runtime.ax) }
            throw error
        }
    }

    func prepareControls() async throws {
        try await showView("Controls")
        let bar = try scrollBar()
        guard let value: Double = AXHelpers.getAttribute(bar, kAXValueAttribute, runtime: runtime.ax),
              value.isFinite, (0...1).contains(value) else { throw Failure.unavailable("scroll_position") }
        originalScroll = value
    }

    func scrollBar() throws -> AXUIElement {
        let bars = try nodes(editor, depth: 3, capacity: 400).filter {
            AXHelpers.getRole($0, runtime: runtime.ax) == kAXScrollBarRole
        }
        guard bars.count == 1, let bar = bars.first else { throw Failure.unavailable("controls_scroll_bar") }
        return bar
    }

    func reveal(_ row: AXUIElement) async throws {
        let table = try table()
        let bar = try scrollBar()
        let initial: Double? = AXHelpers.getAttribute(bar, kAXValueAttribute, runtime: runtime.ax)
        for position in [initial ?? 0, 0, 0.25, 0.5, 0.75, 1] {
            guard holdsTarget() else { throw Failure.unavailable("scroll_context") }
            if let visible: [AXUIElement] = AXHelpers.getAttribute(table, kAXVisibleRowsAttribute, runtime: runtime.ax),
               visible.contains(where: { CFEqual($0, row) }) { return }
            guard OperationTraceContext.claimDeadlineEffect("retro_reveal_parameter", rejectTaskCancellationWithoutContext: true) else {
                throw Failure.unavailable("scroll_authority")
            }
            _ = AXHelpers.setAttribute(bar, kAXValueAttribute, NSNumber(value: position), runtime: runtime.ax)
            try await Task.sleep(for: .milliseconds(80))
        }
        if let visible: [AXUIElement] = AXHelpers.getAttribute(table, kAXVisibleRowsAttribute, runtime: runtime.ax),
           visible.contains(where: { CFEqual($0, row) }) { return }
        throw Failure.unavailable("parameter_not_visible")
    }

    func waitForMenu(under parent: AXUIElement, cleanup: Bool = false, permitted: () -> Bool) async throws -> AXUIElement {
        for _ in 0..<25 {
            guard permitted() else { throw Failure.unavailable("menu_context") }
            let menus = try children(parent).filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXMenuRole }
            guard menus.count <= 1 else { throw Failure.unavailable("ambiguous_menu") }
            if let menu = menus.first { return menu }
            try await interfacePause(cleanup: cleanup, milliseconds: 40)
        }
        throw Failure.unavailable("menu_unavailable")
    }

    /// Cleanup has no audio effect and uses original window/document custody.
    /// It does not depend on a cancelled operation's track-renewal authority.
    func cleanupPermitted() -> Bool {
        guard runtime.logicProPID() == pid, ProjectScore.foreground(pid, runtime: runtime),
              let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: runtime.ax),
              (CFEqual(focused, editor) || (openedEditor && CFEqual(focused, slot.physical.window))), let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax),
              windows.contains(where: { CFEqual($0, slot.physical.window) }),
              windows.contains(where: { CFEqual($0, editor) }),
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(slot.physical.window, runtime: runtime),
              document == slot.physical.document,
              AXHelpers.getTitle(editor, runtime: runtime.ax) == slot.name,
              let children = try? children(editor) else { return false }
        return children.contains {
            AXHelpers.getRole($0, runtime: runtime.ax) == kAXStaticTextRole
                && (AXHelpers.getAttribute($0, kAXValueAttribute, runtime: runtime.ax) as String?) == "Retro Synth"
        }
    }

    func cleanup() async -> Bool {
        guard cleanupPermitted() else { return false }
        if openedEditor {
            guard let buttons = try? children(editor).filter({
                AXHelpers.getRole($0, runtime: runtime.ax) == kAXButtonRole
                    && AXHelpers.getDescription($0, runtime: runtime.ax) == "close"
            }), buttons.count == 1 else { return false }
            _ = AXHelpers.performAction(buttons[0], kAXPressAction, runtime: runtime.ax)
            for _ in 0..<15 {
                let windows: [AXUIElement]? = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax)
                if windows?.contains(where: { CFEqual($0, editor) }) == false { return true }
                try? await interfacePause(cleanup: true, milliseconds: 40)
            }
            return false
        }
        do {
            if let originalScroll {
                let bar = try scrollBar()
                _ = AXHelpers.setAttribute(bar, kAXValueAttribute, NSNumber(value: originalScroll), runtime: runtime.ax)
                var restored = false
                for _ in 0..<10 {
                    if let now: Double = AXHelpers.getAttribute(bar, kAXValueAttribute, runtime: runtime.ax),
                       abs(now - originalScroll) <= 0.000_001 { restored = true; break }
                    try? await interfacePause(cleanup: true, milliseconds: 40)
                }
                guard restored else { return false }
            }
            if originalView != "Controls" { try await showView("Editor", cleanup: true) }
            return cleanupPermitted()
        } catch { return false }
    }

    private func interfacePause(cleanup: Bool, milliseconds: Int) async throws {
        if cleanup {
            await Task.detached { try? await Task.sleep(for: .milliseconds(milliseconds)) }.value
        } else {
            try await Task.sleep(for: .milliseconds(milliseconds))
        }
    }
}
