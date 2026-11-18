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
        func refused(_ reason: String) -> pid_t {
            Log.debug("Hosted Go to Folder focus unresolved: \(reason); service PID \(rawPID)", subsystem: "process")
            return rawPID
        }
        let ax = runtime.ax
        guard let field: AXUIElement = AXHelpers.getAttribute(application, kAXFocusedUIElementAttribute, runtime: ax) else {
            return refused("focused_control_unreadable")
        }
        let fieldRole = AXHelpers.getRole(field, runtime: ax)
        let fieldIdentifier = AXHelpers.getIdentifier(field, runtime: ax)
        guard fieldRole == kAXTextFieldRole, fieldIdentifier == "PathTextField" else {
            return refused("field role=\(fieldRole ?? "unread") identifier=\(fieldIdentifier ?? "unread")")
        }
        var current = field
        var visited: [AXUIElement] = []
        var sawFolderSheet = false
        var sawSavePanel = false
        for _ in 0..<12 {
            guard !visited.contains(where: { CFEqual($0, current) }),
                  let role = AXHelpers.getRole(current, runtime: ax) else { return refused("ancestor_identity_\(visited.count)") }
            visited.append(current)
            Log.debug("Hosted focus ancestor depth \(visited.count): role=\(role) pid=\(runtime.elementPID(current) ?? 0)", subsystem: "process")
            if role == kAXSheetRole {
                guard !sawFolderSheet, !sawSavePanel,
                      AXHelpers.getIdentifier(current, runtime: ax) == "GoToWindow" else { return refused("folder_sheet") }
                sawFolderSheet = true
            }
            if role == kAXWindowRole {
                guard sawFolderSheet, !sawSavePanel,
                      AXHelpers.getIdentifier(current, runtime: ax) == "save-panel" else { return refused("save_panel") }
                sawSavePanel = true
            }
            if role == kAXApplicationRole {
                // A hosted field can itself carry the service PID. The actual
                // application ancestor identifies its host; every node must
                // remain inside that exact host/service pair.
                let observedHostPID = runtime.elementPID(current)
                guard let hostPID = observedHostPID, hostPID > 0, hostPID != rawPID,
                      let hostBundle = runtime.bundleID(hostPID), hostBundle != panelServiceBundle else {
                    return refused("application_ancestor_pid_\(observedHostPID ?? 0)")
                }
                let host = ax.axApp(hostPID)
                guard visited.allSatisfy({ node in
                    guard let pid = runtime.elementPID(node) else { return false }
                    return pid == rawPID || pid == hostPID
                }) else { return refused("third_process_in_ancestor_chain") }
                guard sawFolderSheet, sawSavePanel, CFEqual(current, host),
                      (AXHelpers.getAttribute(host, kAXFrontmostAttribute, runtime: ax) as Bool?) == true,
                      let hostFocus: AXUIElement = AXHelpers.getAttribute(host, kAXFocusedUIElementAttribute, runtime: ax),
                      let serviceFocus: AXUIElement = AXHelpers.getAttribute(application, kAXFocusedUIElementAttribute, runtime: ax),
                      CFEqual(hostFocus, field), CFEqual(serviceFocus, field),
                      let freshApplication = runtime.focusedApplication(),
                      CFEqual(freshApplication, application) || CFEqual(freshApplication, host) else { return refused("host_or_focus_bookend") }
                Log.debug("Hosted Go to Folder focus bound to host PID \(hostPID) from service PID \(rawPID)", subsystem: "process")
                return hostPID
            }
            guard let parent: AXUIElement = AXHelpers.getAttribute(current, kAXParentAttribute, runtime: ax) else { return refused("ancestor_parent_\(visited.count)") }
            current = parent
        }
        return refused("ancestor_depth")
    }
}
