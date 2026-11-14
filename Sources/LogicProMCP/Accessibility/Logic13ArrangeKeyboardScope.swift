import ApplicationServices
import Foundation

/// Logic can select an Arrange track while leaving Command-C and Command-V
/// routed to the Instruments browser. Hold the project and verify AX keyboard focus.
struct Logic13ArrangeKeyboardScope: @unchecked Sendable {
    private let binding: AXTrackBinding.Binding
    private let app: AXUIElement
    private let pid: pid_t
    private let library: AXUIElement

    private var runtime: AXLogicProElements.Runtime { binding.runtime }

    init?(binding: AXTrackBinding.Binding) {
        let runtime = binding.runtime
        guard let pid = runtime.logicProPID(),
              let app = AXLogicProElements.appRoot(runtime: runtime),
              let library = Self.libraryControl(in: binding.window, runtime: runtime.ax) else { return nil }
        self.binding = binding
        self.pid = pid
        self.app = app
        self.library = library
    }

    private static func libraryControl(in window: AXUIElement, runtime: AXHelpers.Runtime) -> AXUIElement? {
        guard let toolbar = AXLogicProElements.directLogic13Toolbar(in: window, runtime: runtime) else { return nil }
        return AXLogicProElements.directToolbarControl(AXLocalePolicy.libraryPanelLabel, in: toolbar, runtime: runtime)
    }

    private func windowChildren() -> [AXUIElement]? {
        guard !Task.isCancelled, runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid,
              binding.currentWindowAndDocumentMatch(),
              let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: runtime.ax),
              windows.count == 1, CFEqual(windows[0], binding.window),
              case .success(let children) = AXHelpers.childrenResult(binding.window, runtime: runtime.ax) else { return nil }
        return children
    }

    private func groups(_ name: String, in children: [AXUIElement]) -> [AXUIElement] {
        children.filter {
            AXHelpers.getRole($0, runtime: runtime.ax) == kAXGroupRole as String
                && AXHelpers.getDescription($0, runtime: runtime.ax) == name
        }
    }

    var libraryIsOpen: Bool? {
        guard let children = windowChildren(),
              let current = Self.libraryControl(in: binding.window, runtime: runtime.ax), CFEqual(current, library),
              let open = AXValueExtractors.extractButtonState(library, runtime: runtime.ax),
              groups("Browser", in: children).count == (open ? 1 : 0) else { return nil }
        return open
    }

    func requestLibrary(open: Bool) -> Bool {
        guard libraryIsOpen == !open,
              OperationTraceContext.claimDeadlineEffect(open ? "relocation_restore_library" : "relocation_close_library")
        else { return false }
        // Readback is authoritative even if AXPress returns an error after delivery.
        _ = AXHelpers.performAction(library, kAXPressAction, runtime: runtime.ax)
        return true
    }

    func waitForLibrary(open: Bool, settle: () async -> Void) async -> Bool {
        for _ in 0..<8 {
            guard !Task.isCancelled else { return false }
            if libraryIsOpen == open { return true }
            await settle()
        }
        return libraryIsOpen == open
    }

    func hasArrangeFocus() -> Bool {
        guard let children = windowChildren(),
              let focused: AXUIElement = AXHelpers.getAttribute(
                app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) else { return false }
        let tracks = groups("Tracks", in: children)
        guard tracks.count == 1 else { return false }
        var element = focused
        for _ in 0..<12 {
            if CFEqual(element, tracks[0]) { return true }
            guard let role = AXHelpers.getRole(element, runtime: runtime.ax),
                  ![kAXTextFieldRole as String, kAXTextAreaRole as String, kAXWindowRole as String].contains(role),
                  let parent: AXUIElement = AXHelpers.getAttribute(
                    element, kAXParentAttribute as String, runtime: runtime.ax),
                  !CFEqual(element, parent) else { return false }
            element = parent
        }
        return false
    }
}
