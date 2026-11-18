import ApplicationServices
import Foundation

/// AppKit can report its Open/Save service as the focused application while
/// exposing the actual focused control through the host's AX hierarchy.
/// Resolve only the measured Go to Folder chain, retaining the service PID on
/// every incomplete or contradictory observation so callers still refuse it.
enum FocusedApplicationOwnership {
    static let panelServiceBundle = "com.apple.appkit.xpc.openAndSavePanelService"

    struct Runtime: @unchecked Sendable {
        let ax: AXHelpers.Runtime
        let focusedApplication: () -> AXUIElement?
        let elementPID: (AXUIElement) -> pid_t?
        let bundleID: (pid_t) -> String?

        static let production = Runtime(ax: .production, focusedApplication: {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                kAXFocusedApplicationAttribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }, elementPID: { element in
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
            return pid
        }, bundleID: ProcessUtils.bundleIDForPID)
    }

    static func pid(runtime: Runtime = .production) -> pid_t? {
        guard let application = runtime.focusedApplication(),
              let rawPID = runtime.elementPID(application), rawPID > 0 else { return nil }
        guard runtime.bundleID(rawPID) == panelServiceBundle else { return rawPID }
        let ax = runtime.ax
        guard let field: AXUIElement = AXHelpers.getAttribute(application, kAXFocusedUIElementAttribute, runtime: ax),
              AXHelpers.getRole(field, runtime: ax) == kAXTextFieldRole,
              AXHelpers.getIdentifier(field, runtime: ax) == "PathTextField",
              let hostPID = runtime.elementPID(field), hostPID > 0, hostPID != rawPID,
              let hostBundle = runtime.bundleID(hostPID), hostBundle != panelServiceBundle else { return rawPID }
        let host = ax.axApp(hostPID)
        var current = field
        var visited: [AXUIElement] = []
        var sawFolderSheet = false
        var sawSavePanel = false
        for _ in 0..<12 {
            guard !visited.contains(where: { CFEqual($0, current) }),
                  let role = AXHelpers.getRole(current, runtime: ax),
                  runtime.elementPID(current) == hostPID else { return rawPID }
            visited.append(current)
            if role == kAXSheetRole {
                guard !sawFolderSheet, !sawSavePanel,
                      AXHelpers.getIdentifier(current, runtime: ax) == "GoToWindow" else { return rawPID }
                sawFolderSheet = true
            }
            if role == kAXWindowRole {
                guard sawFolderSheet, !sawSavePanel,
                      AXHelpers.getIdentifier(current, runtime: ax) == "save-panel" else { return rawPID }
                sawSavePanel = true
            }
            if role == kAXApplicationRole {
                guard sawFolderSheet, sawSavePanel, CFEqual(current, host),
                      (AXHelpers.getAttribute(host, kAXFrontmostAttribute, runtime: ax) as Bool?) == true,
                      let hostFocus: AXUIElement = AXHelpers.getAttribute(host, kAXFocusedUIElementAttribute, runtime: ax),
                      let serviceFocus: AXUIElement = AXHelpers.getAttribute(application, kAXFocusedUIElementAttribute, runtime: ax),
                      CFEqual(hostFocus, field), CFEqual(serviceFocus, field),
                      let freshApplication = runtime.focusedApplication(),
                      CFEqual(freshApplication, application) || CFEqual(freshApplication, host) else { return rawPID }
                Log.debug("Hosted Go to Folder focus bound to host PID \(hostPID) from service PID \(rawPID)", subsystem: "process")
                return hostPID
            }
            guard let parent: AXUIElement = AXHelpers.getAttribute(current, kAXParentAttribute, runtime: ax) else { return rawPID }
            current = parent
        }
        return rawPID
    }
}
