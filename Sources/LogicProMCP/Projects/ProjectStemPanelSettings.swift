@preconcurrency import ApplicationServices
import Foundation

enum ProjectStemPanelSettings {
    static func apply(
        _ settings: ProjectAlignedStemSettings, subjects: [ProjectExportStemSubject],
        panel: AXUIElement, runtime: AXLogicProElements.Runtime, ownsPanel: () -> Bool
    ) async -> Bool {
        let ax = runtime.ax
        func children(_ element: AXUIElement) -> [AXUIElement] { AXHelpers.getChildren(element, runtime: ax) }
        func role(_ element: AXUIElement) -> String? { AXHelpers.getRole(element, runtime: ax) }
        func text(_ element: AXUIElement, _ attribute: String) -> String? {
            AXHelpers.getAttribute(element, attribute, runtime: ax)
        }
        func enabled(_ element: AXUIElement) -> Bool {
            (AXHelpers.getAttribute(element, kAXEnabledAttribute, runtime: ax) as Bool?) == true
        }
        func unique(_ elements: [AXUIElement]) -> AXUIElement? { elements.count == 1 ? elements.first : nil }
        func optionContainers() -> [AXUIElement] {
            [panel] + children(panel).filter { role($0) == kAXSplitGroupRole || role($0) == kAXGroupRole }
        }
        func popup(_ caption: String) -> AXUIElement? {
            unique(optionContainers().flatMap { element -> [AXUIElement] in
                let nodes = children(element)
                guard let label = unique(nodes.filter { role($0) == kAXStaticTextRole && text($0, kAXValueAttribute) == caption }),
                      let origin = AXHelpers.getPosition(label, runtime: ax), let size = AXHelpers.getSize(label, runtime: ax)
                else { return [] }
                return nodes.filter {
                    guard role($0) == kAXPopUpButtonRole, let p = AXHelpers.getPosition($0, runtime: ax),
                          let s = AXHelpers.getSize($0, runtime: ax) else { return false }
                    return p.x >= origin.x + size.width - 2
                        && abs(p.y + s.height / 2 - origin.y - size.height / 2) <= 6
                }
            })
        }
        func checkbox(_ label: String) -> AXUIElement? {
            unique(optionContainers().flatMap(children).filter {
                role($0) == kAXCheckBoxRole && text($0, kAXTitleAttribute) == label
            })
        }
        func checked(_ label: String) -> Bool? {
            guard let item = checkbox(label), let state: Int = AXHelpers.getAttribute(item, kAXValueAttribute, runtime: ax),
                  (0...1).contains(state) else { return nil }
            return state == 1
        }
        func trackNamePattern() -> Bool {
            let groups = optionContainers().flatMap(children).filter { role($0) == kAXGroupRole }
            guard let pattern = unique(groups.filter { group in
                children(group).contains { role($0) == kAXStaticTextRole && text($0, kAXValueAttribute) == "Filename Example:" }
            }) else { return false }
            let controls = children(pattern)
            guard let tokens = unique(controls.filter {
                role($0) == kAXTextFieldRole && children($0).contains { text($0, kAXSubroleAttribute) == "AXTextAttachment" }
            }) else { return false }
            let attachments = children(tokens).filter { text($0, kAXSubroleAttribute) == "AXTextAttachment" }
            let values = attachments.compactMap { text($0, kAXValueAttribute) }
            guard values == ["Track Name"] || values == ["Track Name", "Custom"] else { return false }
            guard text(tokens, kAXValueAttribute) == String(repeating: "\u{FFFC}", count: values.count) else { return false }
            if values.contains("Custom") {
                guard let custom = unique(controls.filter { role($0) == kAXTextFieldRole && !CFEqual($0, tokens) }),
                      text(custom, kAXValueAttribute) == "" else { return false }
            }
            let known = Set(subjects.map { "\($0.name).wav" })
            return controls.filter { role($0) == kAXStaticTextRole && known.contains(text($0, kAXValueAttribute) ?? "") }.count == 1
        }

        let popupLabels = [
            ("Range:", "Extend File Length to Project End"), ("File Type:", "WAVE"),
            ("Bit Depth:", "24-bit"), ("Normalize:", "Off"),
            ("Multi-Output Software Instruments:", "One File per Track"),
        ]
        let toggleStates = [
            ("Include Audio Tail", settings.includeAudioTail),
            ("Include Volume/Pan Automation", settings.includeVolumePanAutomation),
            ("Bypass Effect Plug-ins", false), ("Add resulting files to Project Browser", false),
        ]
        guard ProjectAlignedStemSettings.namesQualify(subjects), ownsPanel() else { return false }

        for (caption, desired) in popupLabels {
            guard let control = popup(caption), ownsPanel() else { return false }
            if text(control, kAXValueAttribute) == desired { continue }
            guard enabled(control), !children(control).contains(where: { role($0) == kAXMenuRole }) else { return false }
            _ = AXHelpers.performAction(control, kAXPressAction, runtime: ax)
            var menu: AXUIElement?
            for _ in 0..<12 {
                do { try await Task.sleep(for: .milliseconds(85)) } catch { return false }
                guard ownsPanel() else { return false }
                if let present = unique(children(control).filter({ role($0) == kAXMenuRole })) {
                    menu = present
                    break
                }
            }
            guard let menu else { return false }
            let item = unique(children(menu).filter { role($0) == kAXMenuItemRole && text($0, kAXTitleAttribute) == desired })
            guard let item, enabled(item), ownsPanel(), children(control).contains(menu) else {
                if ownsPanel(), children(control).contains(menu) {
                    _ = AXHelpers.performAction(menu, kAXCancelAction, runtime: ax)
                }
                return false
            }
            _ = AXHelpers.performAction(item, kAXPressAction, runtime: ax)
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return false }
            guard let next = popup(caption), text(next, kAXValueAttribute) == desired else { return false }
        }
        for (label, desired) in toggleStates {
            guard ownsPanel(), let item = checkbox(label), let preceding = checked(label) else { return false }
            if preceding == desired { continue }
            guard enabled(item) else { return false }
            _ = AXHelpers.performAction(item, kAXPressAction, runtime: ax)
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return false }
            guard checked(label) == desired else { return false }
        }
        return ownsPanel() && trackNamePattern() && toggleStates.allSatisfy { checked($0.0) == $0.1 }
            && popupLabels.allSatisfy { caption, desired in popup(caption).flatMap { text($0, kAXValueAttribute) } == desired }
    }
}
