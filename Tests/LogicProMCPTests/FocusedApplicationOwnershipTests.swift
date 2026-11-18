@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

struct FocusedApplicationOwnershipTests {
    @Test(arguments: ["bound", "service_owned_nodes", "mixed_service_nodes", "other_host", "wrong_sheet", "wrong_panel", "cross_pid", "retired_parent",
                      "host_not_frontmost", "different_host_focus", "changed_service_focus", "changed_application",
                      "unknown_role", "cycle", "deep_chain", "wrong_field", "unknown_service", "missing_host_bundle", "canonical_host_field", "different_candidate_field"])
    func hostedFolderFocusRequiresTheActualHostChain(fault: String) throws {
        let b = FakeAXRuntimeBuilder()
        let service = b.element(1_961_100), host = b.element(1_961_101), field = b.element(1_961_102)
        let sheet = b.element(1_961_103), panel = b.element(1_961_104), other = b.element(1_961_105)
        let hostPID: pid_t = fault == "other_host" ? 900 : 672
        let servicePID: pid_t = 28_159
        b.setRole(service, kAXApplicationRole as String); b.setRole(host, kAXApplicationRole as String)
        b.setRole(field, kAXTextFieldRole as String); b.setRole(sheet, kAXSheetRole as String)
        b.setRole(panel, fault == "unknown_role" ? "" : kAXWindowRole as String)
        b.setAttribute(field, kAXIdentifierAttribute as String, fault == "wrong_field" ? "other" : "PathTextField")
        b.setAttribute(sheet, kAXIdentifierAttribute as String, fault == "wrong_sheet" ? "different" : "GoToWindow")
        b.setAttribute(panel, kAXIdentifierAttribute as String, fault == "wrong_panel" ? "different" : "save-panel")
        b.setAttribute(field, kAXParentAttribute as String, sheet)
        b.setAttribute(sheet, kAXParentAttribute as String, fault == "cycle" ? field : panel)
        if fault == "deep_chain" {
            var child = field
            for offset in 0..<13 {
                let group = b.element(1_961_120 + offset)
                b.setRole(group, kAXGroupRole as String)
                b.setAttribute(child, kAXParentAttribute as String, group)
                child = group
            }
            b.setAttribute(child, kAXParentAttribute as String, sheet)
        }
        if fault != "retired_parent" { b.setAttribute(panel, kAXParentAttribute as String, host) }
        b.setAttribute(service, kAXFocusedUIElementAttribute as String, field)
        b.setAttribute(host, kAXFocusedUIElementAttribute as String, ["different_host_focus", "different_candidate_field"].contains(fault) ? other : field)
        b.setAttribute(host, kAXFrontmostAttribute as String, fault != "host_not_frontmost")
        let ax = b.makeLogicRuntime(appElement: host, attributeValueHandler: { element, attribute in
            if fault == "changed_service_focus", CFEqual(element, service), attribute == kAXFocusedUIElementAttribute as String {
                let reads = (b.attributeValue(service, "focus_reads") as? Int ?? 0) + 1
                b.setAttribute(service, "focus_reads", reads)
                return reads == 1 ? field : other
            }
            return nil
        }, setAttributeHandler: nil, performActionHandler: nil).ax
        var applicationReads = 0
        let runtime = FocusedApplicationOwnership.Runtime(ax: ax, focusedApplication: {
            applicationReads += 1
            return fault == "changed_application" && applicationReads > 1 ? other : service
        }, elementPID: { element in
            if CFEqual(element, service) { return servicePID }
            if fault == "service_owned_nodes", !CFEqual(element, host) { return servicePID }
            if fault == "mixed_service_nodes", CFEqual(element, field) || CFEqual(element, sheet) { return servicePID }
            if fault == "cross_pid", CFEqual(element, sheet) { return 901 }
            return hostPID
        }, bundleID: { pid in
            if pid == servicePID { return fault == "unknown_service" ? "example.other-service" : FocusedApplicationOwnership.panelServiceBundle }
            if fault == "missing_host_bundle" { return nil }
            return pid == 900 ? "com.apple.finder" : "com.apple.logic10"
        }, candidateHostPID: { ["canonical_host_field", "different_candidate_field"].contains(fault) ? hostPID : nil })
        let observed = FocusedApplicationOwnership.pid(runtime: runtime)
        #expect(observed == (["bound", "service_owned_nodes", "mixed_service_nodes", "other_host", "canonical_host_field"].contains(fault) ? hostPID : servicePID))
        let ownership = ProcessUtils.keyboardOwnershipObservation(
            windows: [[kCGWindowOwnerPID as String: 672, kCGWindowLayer as String: 8]],
            focusedApplicationPID: observed,
            bundleIDForPID: { $0 == 672 ? "com.apple.logic10" : "com.apple.finder" })
        #expect(ownership.isReady == (["bound", "service_owned_nodes", "mixed_service_nodes", "canonical_host_field"].contains(fault)))
        #expect(b.actionCalls.isEmpty && b.setCalls.isEmpty)
    }

    @Test func anOrdinaryFocusedApplicationNeedsNoPanelException() {
        let b = FakeAXRuntimeBuilder(), app = b.element(1_961_110)
        let runtime = FocusedApplicationOwnership.Runtime(ax: b.makeAXRuntime(),
            focusedApplication: { app }, elementPID: { _ in 900 }, bundleID: { _ in "com.apple.finder" })
        #expect(FocusedApplicationOwnership.pid(runtime: runtime) == 900)
        #expect(b.actionCalls.isEmpty && b.setCalls.isEmpty)
    }
}
