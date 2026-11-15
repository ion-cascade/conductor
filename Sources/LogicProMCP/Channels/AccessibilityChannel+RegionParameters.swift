@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum AudioRegionParameter: String {
    case gain
    case fadeIn = "in"
    case fadeOut = "out"

    var label: String {
        switch self {
        case .gain: "Gain"
        case .fadeIn: "Fade-In Time"
        case .fadeOut: "Fade-Out Time"
        }
    }

    var section: String { self == .gain ? "General" : "Fades" }
    var receiptKey: String { self == .gain ? "gain_db" : "time_ms" }

    func accepts(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        if self == .gain {
            let tenths = value * 10
            return (-24...12).contains(value) && abs(tenths - tenths.rounded()) < 1e-9
        }
        return (0...1000).contains(value) && value.rounded() == value
    }

    func entryText(_ value: Double) -> String {
        String(format: self == .gain ? "%.1f" : "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    func observed(description: String, value: String) -> Double? {
        let text: String
        if self == .gain {
            guard description.hasPrefix("Gain, "), description.hasSuffix(" dB") else { return nil }
            text = String(description.dropFirst(6).dropLast(3))
        } else {
            guard description == label else { return nil }
            if value.hasSuffix(" milliseconds") {
                text = String(value.dropLast(" milliseconds".count))
            } else if value == "1 millisecond" {
                text = "1"
            } else {
                return nil
            }
        }
        guard let number = Double(text), number.isFinite else { return nil }
        return number
    }
}

extension AccessibilityChannel {
    private struct RegionInspectorField {
        let element: AXUIElement
        let group: AXUIElement
        let value: Double
        let otherFade: Double?
    }

    func arrangeRegionParameter(_ parameter: AudioRegionParameter, parameters: [String: String], write: Bool,
                                runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        let suffix = parameter == .gain ? "region_gain" : "region_fade"
        let operation = "project.\(write ? "set" : "get")_\(suffix)"
        let reference = parameters["target_ref"] ?? ""
        let ax = runtime.ax
        var fields: [String: Any] = [
            "operation": operation, "target_ref": reference, "write_attempted": false,
        ]
        if parameter != .gain { fields["edge"] = parameter.rawValue }

        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: error, hint: hint, extras: fields))
        }

        guard let snapshot = regionScan, ContinuousClock.now < snapshot.expires,
              let held = snapshot.targets[reference] else {
            return refuse(.staleTargetReference, "Scan the project and use a current region reference.")
        }
        guard held.info.kind == "audio" else {
            return refuse(.unsupportedState, "Select one ordinary audio region in Arrange.")
        }
        func matchesTarget(_ row: EditRegionRow) -> Bool {
            Self.isOrdinaryRegion(row.info) && Self.sameRegionObservation(held, item: row.item, info: row.info)
        }
        guard let scope = ArrangeRegionScope(runtime: runtime), scope.document == snapshot.document,
              CFEqual(scope.window, snapshot.window), scope.holdsHeaders(),
              scope.headers.indices.contains(held.info.trackIndex),
              CFEqual(scope.headers[held.info.trackIndex], held.header),
              AXTrackBinding.presentation(of: held.header, runtime: ax) == held.headerPresentation,
              let before = Self.regionEditCensus(scope: scope),
              before.filter(matchesTarget).count == 1 else {
            return refuse(.staleTargetReference, "Re-scan with the target visible in the foreground, stopped project.")
        }
        func ownsSelection(_ current: ArrangeRegionScope) -> Bool {
            // Logic 13 reports an empty AXSelectedChildren on the content group even
            // when an item is selected. Check the native selection on each layout item.
            guard current.selectionIsOriginal(),
                  current.originalSelection.allSatisfy({ CFEqual($0, held.item) }),
                  let items = AXLogicProElements.logic13RegionItems(in: current.content, runtime: ax),
                  items.filter({ CFEqual($0, held.item) }).count == 1 else { return false }
            return items.allSatisfy {
                AXValueExtractors.extractSelectedState($0, runtime: ax) == CFEqual($0, held.item)
            }
        }
        guard ownsSelection(scope) else {
            return refuse(.unsupportedState, "Select only the referenced audio region.")
        }
        guard let initial = Self.regionInspectorField(parameter, name: held.info.name, scope: scope),
              scope.holdsArrange(), ownsSelection(scope) else {
            return refuse(.readbackUnavailable, "Show Region Inspector > \(parameter.section) for the selected audio region.")
        }
        let observedKey = "observed_\(parameter.receiptKey)"
        fields[observedKey] = initial.value
        fields["verify_source"] = "ax_region_inspector"
        guard write else { return .success(HonestContract.encodeStateA(extras: fields)) }

        guard let expected = parameters["expected_\(parameter.receiptKey)"].flatMap(Double.init), expected.isFinite,
              let desired = parameters[parameter.receiptKey].flatMap(Double.init), parameter.accepts(desired) else {
            return refuse(.invalidParams, "Use a finite expected value and a supported new value.")
        }
        guard expected == initial.value else {
            return refuse(.staleTargetReference, "Read the current Region Inspector value and review the write.")
        }
        if desired == initial.value {
            fields["unchanged"] = true
            return .success(HonestContract.encodeStateA(extras: fields))
        }

        let selectAllKey = CGKeyCode(kVK_ANSI_A)
        guard CGPreflightPostEventAccess(), let input = CGEventChannel.readCurrentInputSource(),
              input.isASCIICapable, let layout = input.id,
              CGEventChannel.readLayoutLetter(layoutID: layout, keyCode: selectAllKey) == "a" else {
            return refuse(.unsupportedState, "Enable keyboard event access and use an ASCII keyboard layout with A at the standard key position.")
        }
        guard let pid = runtime.logicProPID(), let frame = scope.frame(initial.element), frame.width >= 48,
              let hitTest = ax.elementAtPosition else {
            return refuse(.readbackUnavailable, "The selected region's Inspector control is unavailable.")
        }
        let point = CGPoint(x: frame.maxX - 22, y: frame.midY)
        guard case .success(.some(let hit)) = hitTest(AXUIElementCreateSystemWide(), point), CFEqual(hit, initial.element),
              scope.holdsArrange(), ownsSelection(scope),
              scope.page()?.matches(scope.originalPage) == true,
              let ready = Self.regionInspectorField(parameter, name: held.info.name, scope: scope),
              CFEqual(ready.element, initial.element), ready.value == expected,
              ready.otherFade == initial.otherFade,
              OperationTraceContext.claimDeadlineEffect("region_inspector_value") else {
            return refuse(.readbackUnavailable, "Keep the selected region and its Inspector control visible before writing.")
        }

        regionScan = nil
        fields["write_attempted"] = true
        fields["requested_\(parameter.receiptKey)"] = desired
        fields[observedKey] = NSNull()
        fields["reference_reread_required"] = true

        func ownedEditor() -> Bool {
            guard !Task.isCancelled, scope.holdsArrange(), ownsSelection(scope),
                  scope.page()?.matches(scope.originalPage) == true,
                  let editor: AXUIElement = AXHelpers.getAttribute(scope.app, kAXFocusedUIElementAttribute, runtime: ax),
                  AXHelpers.getRole(editor, runtime: ax) == kAXButtonRole,
                  AXHelpers.getDescription(editor, runtime: ax) == parameter.label,
                  let group: AXUIElement = AXHelpers.getAttribute(editor, kAXParentAttribute, runtime: ax),
                  CFEqual(group, initial.group), scope.frame(editor) == frame else { return false }
            if parameter == .gain {
                return CFEqual(editor, initial.element)
                    && AXHelpers.getActionNames(editor, runtime: ax).contains(where: { $0.hasPrefix("Name:confirm\n") })
            }
            return AXHelpers.getIdentifier(editor, runtime: ax) == "MAInspectorInlineEditField"
                && ax.attributeIsSettable(editor, kAXValueAttribute) == true
        }

        if AXMouseHelper.doubleClick(at: point) {
            try? await Task.sleep(for: .milliseconds(220))
            let posted = Self.typeRegionInspectorValue(parameter.entryText(desired), pid: pid) {
                ownedEditor() && CGEventChannel.readCurrentInputSource()?.id == layout
            }
            if !posted, ownedEditor() {
                _ = Self.postRegionKey(CGKeyCode(kVK_Escape), pid: pid)
            }
        }

        var observed: RegionInspectorField?
        var peersVerified = false
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { break }
            guard let current = ArrangeRegionScope(runtime: runtime),
                  current.document == scope.document, CFEqual(current.window, scope.window),
                  current.page()?.matches(scope.originalPage) == true,
                  ArrangeRegionScope.same(current.headers, scope.headers),
                  ownsSelection(current),
                  let after = Self.regionEditCensus(scope: current),
                  after.filter(matchesTarget).count == 1,
                  let readback = Self.regionInspectorField(parameter, name: held.info.name, scope: current),
                  current.holdsArrange(), ownsSelection(current) else { continue }
            observed = readback
            peersVerified = Self.sameRegionPeers(before, after, ignoring: held.item)
            if observed?.value == desired, observed?.otherFade == initial.otherFade, peersVerified { break }
        }

        fields[observedKey] = observed.map { $0.value as Any } ?? NSNull()
        fields["neighboring_regions_verified"] = peersVerified
        guard observed?.value == desired, observed?.otherFade == initial.otherFade, peersVerified else {
            fields["effect_unknown"] = true
            fields["safe_to_retry"] = false
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: fields))
        }
        return .success(HonestContract.encodeStateA(extras: fields))
    }

    private static func regionInspectorField(_ parameter: AudioRegionParameter, name: String,
                                             scope: ArrangeRegionScope) -> RegionInspectorField? {
        let ax = scope.runtime.ax
        func description(_ node: AXUIElement) -> String { AXHelpers.getDescription(node, runtime: ax) ?? "" }
        func value(_ node: AXUIElement) -> String {
            AXHelpers.getAttribute(node, kAXValueAttribute, runtime: ax) ?? ""
        }
        func hasRole(_ node: AXUIElement, _ role: String) -> Bool { AXHelpers.getRole(node, runtime: ax) == role }
        func children(_ node: AXUIElement) -> [AXUIElement] {
            (try? AXHelpers.childrenResult(node, runtime: ax).get()) ?? []
        }
        func only(_ nodes: [AXUIElement], matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
            let matches = nodes.filter(predicate)
            return matches.count == 1 ? matches[0] : nil
        }

        guard let inspector = only(children(scope.window), matching: { hasRole($0, kAXGroupRole) && description($0) == "Inspector" }),
              let list = only(children(inspector), matching: { hasRole($0, kAXListRole) }),
              let group = only(children(list).flatMap(children), matching: { candidate in
                  let rows = children(candidate)
                  return hasRole(candidate, kAXGroupRole) && rows.count >= 3
                      && hasRole(rows[0], kAXStaticTextRole) && value(rows[0]) == "Region:"
                      && hasRole(rows[1], kAXStaticTextRole) && value(rows[1]).utf8.elementsEqual(name.utf8)
                      && hasRole(rows[2], kAXButtonRole) && description(rows[2]) == "Region" && value(rows[2]) == "Expanded"
              }) else { return nil }
        let rows = children(group)
        guard let loop = only(rows, matching: { hasRole($0, kAXCheckBoxRole) && description($0) == "Loop" }),
              (AXHelpers.getAttribute(loop, kAXValueAttribute, runtime: ax) as NSNumber?)?.intValue == 0,
              only(rows, matching: {
                  hasRole($0, kAXButtonRole) && description($0) == parameter.section && value($0) == "Expanded"
              }) != nil else { return nil }

        func field(_ parameter: AudioRegionParameter) -> (AXUIElement, Double)? {
            guard let element = only(rows, matching: {
                hasRole($0, kAXButtonRole) && parameter.observed(description: description($0), value: value($0)) != nil
            }), let observed = parameter.observed(description: description(element), value: value(element)) else { return nil }
            return (element, observed)
        }
        guard let (element, observed) = field(parameter) else { return nil }
        if parameter == .gain {
            return RegionInspectorField(element: element, group: group, value: observed, otherFade: nil)
        }

        let buttonLabels = rows.filter { hasRole($0, kAXButtonRole) }.map(description)
        guard buttonLabels.filter({ $0.hasPrefix("Fade-In Style, ") }) == ["Fade-In Style, Fade-In"],
              buttonLabels.filter({ $0.hasPrefix("Fade-Out Style, ") }) == ["Fade-Out Style, Fade-Out"],
              buttonLabels.filter({ $0.hasPrefix("Curve, ") }) == ["Curve, 0 ", "Curve, 0 "],
              let (_, other) = field(parameter == .fadeIn ? .fadeOut : .fadeIn) else { return nil }
        return RegionInspectorField(element: element, group: group, value: observed, otherFade: other)
    }

    private static func typeRegionInspectorValue(_ text: String, pid: pid_t, ownsEditor: () -> Bool) -> Bool {
        guard ownsEditor(), postRegionKey(CGKeyCode(kVK_ANSI_A), pid: pid, flags: .maskCommand) else { return false }
        let pause = AXMouseHelper.Runtime.production.sleepMicros
        pause(100_000)
        for character in text.utf16 {
            guard ownsEditor(), postRegionKey(0, pid: pid, character: character) else { return false }
            pause(55_000)
        }
        return ownsEditor() && postRegionKey(CGKeyCode(kVK_Return), pid: pid)
    }

    private static func postRegionKey(_ code: CGKeyCode, pid: pid_t, flags: CGEventFlags = [],
                                      character: UniChar? = nil) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = flags
            if var character {
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            }
            event.postToPid(pid)
        }
        return true
    }
}
