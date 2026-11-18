import ApplicationServices
import Foundation

extension AXLogicProElements {
    /// Logic 13 accepts AXSelectedChildren/AXPress without changing the selection.
    /// Its own Search and Select Track palette supplies a numbered, named result.
    /// This opt-in adapter confirms that exact result before one Return, then reads
    /// exclusive selection from the retained rail. No coordinates or blind retries.
    static func selectTrackUsingSearch(
        at index: Int, header: AXUIElement, runtime: Runtime,
        keys: AXMouseHelper.Runtime = .production,
        permittingWrite: () -> Bool, willWrite: (() -> Void)? = nil
    ) -> Bool {
        let ax = runtime.ax
        func selectionWindows(in app: AXUIElement) -> [AXUIElement]? {
            let windows: [AXUIElement]? = AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: ax)
            // Logic lists transient tooltips in AXWindows. Ignore only entries
            // that explicitly read as help tags; an unknown role stays in view.
            return windows?.filter { AXHelpers.getRole($0, runtime: ax) != kAXHelpTagRole as String }
        }
        guard let pid = runtime.logicProPID(), selectionKeyboardOwnerIsCurrent(pid, runtime: runtime),
              let app = appRoot(runtime: runtime),
              AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: ax) as Bool? == true,
              case .found(let window) = arrangeWindowRead(runtime: runtime),
              case .success(let document?) = projectPickerDocumentRead(window, runtime: runtime),
              let rail: AXUIElement = AXHelpers.getAttribute(header, kAXParentAttribute as String, runtime: ax),
              case .success(let rows) = AXHelpers.childrenResult(rail, runtime: ax),
              rows.indices.contains(index), CFEqual(rows[index], header),
              case .success(let name?) = AXValueExtractors.extractTrackNameResult(from: header, runtime: ax),
              let description = AXHelpers.getDescription(header, runtime: ax),
              description.hasPrefix("Track \(index + 1) "),
              let windows = selectionWindows(in: app),
              windows.count == 1, CFEqual(windows[0], window) else { return false }
        func current() -> Bool {
            guard !Task.isCancelled, permittingWrite(),
                  selectionKeyboardOwnerIsCurrent(pid, runtime: runtime),
                  projectPickerDocumentRead(window, runtime: runtime) == .success(document),
                  case .success(let now) = AXHelpers.childrenResult(rail, runtime: ax),
                  now.count == rows.count, zip(now, rows).allSatisfy({ CFEqual($0, $1) }),
                  case .success(let currentName?) = AXValueExtractors.extractTrackNameResult(from: header, runtime: ax)
            else { return false }
            return currentName == name
        }
        if rows.enumerated().allSatisfy({ AXValueExtractors.extractSelectedState($0.element, runtime: ax) == ($0.offset == index) }) {
            return current()
        }
        guard let bar: AXUIElement = AXHelpers.getAttribute(app, kAXMenuBarAttribute as String, runtime: ax),
              case .success(let top) = AXHelpers.childrenResult(bar, runtime: ax) else { return false }
        let tracks = top.filter { AXHelpers.getTitle($0, runtime: ax) == "Track" }
        guard tracks.count == 1, case .success(let menus) = AXHelpers.childrenResult(tracks[0], runtime: ax),
              menus.count == 1, case .success(let items) = AXHelpers.childrenResult(menus[0], runtime: ax) else { return false }
        let search = items.filter { AXHelpers.getTitle($0, runtime: ax) == "Search and Select Track…" }
        guard search.count == 1, current() else { return false }
        willWrite?()
        _ = AXHelpers.performAction(search[0], kAXPressAction, runtime: ax)
        keys.sleepMicros(150_000)
        guard let after = selectionWindows(in: app) else { return false }
        let added = after.filter { w in !windows.contains { CFEqual($0, w) } }
        guard added.count == 1 else { return false }
        let popup = added[0]
        guard let nodes = searchPaletteNodes(popup, runtime: ax),
              nodes.filter({ AXHelpers.getRole($0, runtime: ax) == kAXImageRole as String && AXHelpers.getDescription($0, runtime: ax) == "Search" }).count == 1 else { return false }
        let fields = nodes.filter { AXHelpers.getRole($0, runtime: ax) == kAXTextFieldRole as String }
        guard fields.count == 1, let field = fields.first else { return false }
        var confirmed = false
        defer {
            if !confirmed {
                // An empty search can leave its field focused with no Close button.
                // Dismiss only this operation's palette while it still has keyboard focus.
                func stillOwnsPalette() -> Bool {
                    guard runtime.logicProPID() == pid, selectionKeyboardOwnerIsCurrent(pid, runtime: runtime),
                          AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: ax) as Bool? == true,
                          projectPickerDocumentRead(window, runtime: runtime) == .success(document),
                          let remaining = selectionWindows(in: app),
                          remaining.count == 2,
                          remaining.contains(where: { CFEqual($0, window) }),
                          remaining.contains(where: { CFEqual($0, popup) }),
                          let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: ax)
                    else { return false }
                    return CFEqual(focused, field)
                }
                if stillOwnsPalette() {
                    let close = nodes.filter {
                        AXHelpers.getRole($0, runtime: ax) == kAXButtonRole as String
                            && AXHelpers.getDescription($0, runtime: ax) == "Close"
                    }
                    if close.count == 1 { _ = AXHelpers.performAction(close[0], kAXPressAction, runtime: ax) }
                    if stillOwnsPalette() { _ = keys.postKeyEvent(53) }
                }
            }
        }
        guard current() else { return false }
        willWrite?()
        guard AXHelpers.setAttribute(field, kAXValueAttribute, String(index + 1) as CFString, runtime: ax) else { return false }
        keys.sleepMicros(150_000)
        guard let resultNodes = searchPaletteNodes(popup, runtime: ax) else { return false }
        let labels = resultNodes.filter { AXHelpers.getRole($0, runtime: ax) == kAXStaticTextRole as String }
            .compactMap { AXHelpers.getAttribute($0, kAXValueAttribute as String, runtime: ax) as String? }
        guard searchTrackResultMatches(labels, number: index + 1, name: name), current(),
              let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: ax),
              CFEqual(focused, field) else { return false }
        willWrite?()
        guard keys.postKeyEvent(36) else { return false }
        for _ in 0..<6 {
            keys.sleepMicros(50_000)
            if rows.enumerated().allSatisfy({ AXValueExtractors.extractSelectedState($0.element, runtime: ax) == ($0.offset == index) }) {
                guard current(), let remaining = selectionWindows(in: app),
                      !remaining.contains(where: { CFEqual($0, popup) }) else { return false }
                confirmed = true
                return true
            }
        }
        return false
    }

    /// Use the same live WindowServer ownership observation as other verified
    /// project writes. System-wide AX focus can remain unreadable after export;
    /// that is not evidence of another owner. A readable mismatch, missing
    /// window list, foreign owner or different Logic PID still refuses. Fake
    /// runtimes without this observation retain the explicit AX focus gate.
    static func selectionKeyboardOwnerIsCurrent(_ pid: pid_t, runtime: Runtime) -> Bool {
        if let observe = runtime.observeFrontmost {
            let ownership = observe()
            return ownership.isReady && ownership.keyboardOwnerPID == pid
        }
        return runtime.focusedApplicationPID() == pid
    }

    static func searchTrackResultMatches(_ labels: [String], number: Int, name: String) -> Bool {
        labels == ["\(number)\t\(name)"]
    }

    private static func searchPaletteNodes(_ root: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement]? {
        var pending: [(AXUIElement, Int)] = [(root, 0)], result: [AXUIElement] = []
        let leaves: Set<String> = [kAXStaticTextRole as String, kAXTextFieldRole as String, kAXImageRole as String, kAXButtonRole as String, kAXColumnRole as String]
        while !pending.isEmpty {
            let (node, depth) = pending.removeFirst()
            guard result.count < 128, depth <= 8, let role = AXHelpers.getRole(node, runtime: runtime) else { return nil }
            result.append(node)
            if leaves.contains(role) { continue }
            guard case .success(let children) = AXHelpers.childrenResult(node, runtime: runtime) else { return nil }
            pending.append(contentsOf: children.map { ($0, depth+1) })
        }
        return result
    }
}
