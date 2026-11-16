@preconcurrency import ApplicationServices
import Foundation

/// A single, small English Logic 13 Event List. The visible row count, unfiltered
/// pane and materialized eight-column rows must all agree for an edit.
struct Logic13MIDINoteEventList {
    struct Expression: Equatable {
        let position: Logic13MIDINoteCoordinate
        let channel: Int
        let value: Int

        var evidence: [String: Any] {
            ["position": position.description, "channel": channel, "controller": 11, "value": value]
        }
    }

    struct Row {
        let element: AXUIElement
        let fields: [AXUIElement?]
        let signature: [[String]]
        let note: Logic13MIDINoteValue?
        let expression: Expression?
        let locked: Bool
    }

    let pane: AXUIElement
    let table: AXUIElement
    let regionName: String
    let ax: AXHelpers.Runtime

    private static let columns = ["Lock", "Muted", "Position", "Status", "Ch", "Num", "Val", "Length"]
    private static let filters = ["Notes", "Progr. Change", "Pitch Bend", "Controller",
                                  "Aftertouch", "Poly Aftertouch", "Syst. Exclusive"]
    private static let scale: Int64 = 33_554_432

    static func find(in window: AXUIElement, regionName: String, ax: AXHelpers.Runtime) -> Self? {
        let candidates = AXHelpers.findAllDescendants(of: window, role: kAXTableRole, maxDepth: 18, runtime: ax)
            .filter { table in
                let native: [AXUIElement]? = AXHelpers.getAttribute(table, kAXColumnsAttribute, runtime: ax)
                return native?.compactMap { AXHelpers.getAttribute($0, kAXIdentifierAttribute, runtime: ax) as String? } == columns
            }
        guard candidates.count == 1, let table = candidates.first else { return nil }
        var element = table
        for _ in 0..<8 {
            guard let parent: AXUIElement = AXHelpers.getAttribute(element, kAXParentAttribute, runtime: ax),
                  !CFEqual(parent, window), !CFEqual(parent, element) else { return nil }
            element = parent
            let menuButtons = AXHelpers.findAllDescendants(of: parent, role: kAXMenuButtonRole, maxDepth: 8, runtime: ax)
                .filter { AXHelpers.getDescription($0, runtime: ax) == "View" }
            if menuButtons.count == 1 {
                return Self(pane: parent, table: table, regionName: regionName, ax: ax)
            }
        }
        return nil
    }

    func rows() -> [Row]? {
        let labels = elements(kAXStaticTextRole)
        func observedText(_ help: AXLocalePolicy.LabelSet) -> String? {
            let matches = labels.filter { help.matches(AXHelpers.getHelp($0, runtime: ax)) }
            guard matches.count == 1, let match = matches.first else { return nil }
            return attribute(match, kAXValueAttribute)
        }
        let checkboxes = elements(kAXCheckBoxRole)
        guard CFEqual(table, tableInPane() ?? pane),
              observedText(AXLocalePolicy.eventListRegionPathHelp) == regionName,
              Self.filters.allSatisfy({ checked($0, among: checkboxes) == true }),
              checked("Additional Info", among: checkboxes) == false,
              let countText = observedText(AXLocalePolicy.eventListItemCountHelp),
              let nativeCount = Self.eventCount(countText), nativeCount <= 24,
              let columns: [AXUIElement] = attribute(table, kAXColumnsAttribute),
              columns.compactMap({ attribute($0, kAXIdentifierAttribute) as String? }) == Self.columns,
              let nativeRows: [AXUIElement] = attribute(table, kAXRowsAttribute),
              nativeRows.count == nativeCount else { return nil }
        let converted = nativeRows.compactMap(readRow)
        return converted.count == nativeCount ? converted : nil
    }

    func selectionPermits(_ target: AXUIElement) -> Bool {
        guard let selected: [AXUIElement] = attribute(table, kAXSelectedRowsAttribute) else { return false }
        return selected.allSatisfy { CFEqual($0, target) }
    }

    func stepExpression(_ row: Row, toward target: Int, authorize: () -> Bool) -> Bool {
        guard let current = row.expression, (0...127).contains(target), abs(target - current.value) == 10,
              let control = row.fields[6],
              let raw: NSNumber = attribute(control, kAXValueAttribute),
              raw.int64Value == Int64(current.value) * Self.scale else { return false }
        let action = target < current.value ? kAXDecrementAction : kAXIncrementAction
        guard AXHelpers.getActionNames(control, runtime: ax).contains(action), authorize() else { return false }
        return AXHelpers.performAction(control, action, runtime: ax)
    }

    /// The setter takes one step for pitch and musical scrubber segments.
    /// Velocity supports one encoded increment or a native ten-unit action.
    func write(_ step: Logic13MIDINoteEditPlan.Step, row: Row, authorize: () -> Bool) -> Bool {
        var segment: Int?
        let column: Int
        switch step.field {
        case .pitch: column = 5
        case .velocity: column = 6
        case .position(let index): column = 2; segment = index
        case .length(let index): column = 7; segment = index
        }
        guard let field = row.fields[column] else { return false }
        let slider: AXUIElement
        if let segment {
            guard let segments = scrubber(field), segments.indices.contains(segment) else { return false }
            slider = segments[segment]
        } else {
            slider = field
        }
        guard role(slider) == kAXSliderRole,
              AXHelpers.isAttributeSettable(slider, kAXValueAttribute, runtime: ax) == true else { return false }

        var value = Int64(step.target)
        if column == 6 {
            guard let observed: NSNumber = attribute(slider, kAXValueAttribute),
                  observed.int64Value / Self.scale == Int64(step.current.velocity) else { return false }
            let delta = step.target - step.current.velocity
            if abs(delta) == 10 {
                let action = delta < 0 ? kAXDecrementAction : kAXIncrementAction
                guard AXHelpers.getActionNames(slider, runtime: ax).contains(action), authorize() else { return false }
                return AXHelpers.performAction(slider, action, runtime: ax)
            }
            value = observed.int64Value + Int64(delta) * Self.scale
        }
        guard authorize() else { return false }
        return AXHelpers.setAttribute(slider, kAXValueAttribute, NSNumber(value: value), runtime: ax)
    }

    private func tableInPane() -> AXUIElement? {
        let candidates = elements(kAXTableRole)
        return candidates.count == 1 ? candidates.first : nil
    }

    private func checked(_ title: String, among controls: [AXUIElement]) -> Bool? {
        let matching = controls.filter { AXHelpers.getTitle($0, runtime: ax) == title }
        guard matching.count == 1, let control = matching.first,
              let value: Int = attribute(control, kAXValueAttribute), (0...1).contains(value) else { return nil }
        return value == 1
    }

    private static func eventCount(_ text: String) -> Int? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, ["Event", "Events"].contains(parts[1]) else { return nil }
        return Int(parts[0])
    }

    private func readRow(_ row: AXUIElement) -> Row? {
        guard role(row) == kAXRowRole, case .success(let cells) = AXHelpers.childrenResult(row, runtime: ax),
              cells.count == Self.columns.count else { return nil }
        var fields: [AXUIElement?] = []
        var signature: [[String]] = []
        for (index, cell) in cells.enumerated() {
            guard role(cell) == kAXCellRole else { return nil }
            let field: AXUIElement?
            switch AXHelpers.childrenResult(cell, runtime: ax) {
            case .success(let children):
                guard children.count <= 1, index < 2 || children.count == 1 else { return nil }
                field = children.first
            case .failure(let failure):
                // Logic 13 returns AXError.failure for the two empty status
                // flag cells. A data cell must still answer with its child.
                guard index < 2, failure.raw == AXError.failure.rawValue,
                      attribute(cell, kAXValueAttribute) as NSObject? == nil else { return nil }
                field = nil
            }
            fields.append(field)
            signature.append(field.map(fingerprint) ?? [])
        }
        guard let status = fields[3].flatMap({ AXHelpers.getDescription($0, runtime: ax) }),
              !status.isEmpty, let start = fields[2], let position = coordinate(start, length: false) else { return nil }
        let note: Logic13MIDINoteValue?
        if status == "Note" {
            guard let channel = fields[4].flatMap(sliderInt), (1...16).contains(channel),
                  let pitch = fields[5].flatMap(sliderInt), (0...127).contains(pitch),
                  let velocity = fields[6].flatMap({ attribute($0, kAXValueDescriptionAttribute) as String? }).flatMap(Int.init),
                  (1...127).contains(velocity), let duration = fields[7],
                  let length = coordinate(duration, length: true) else { return nil }
            note = Logic13MIDINoteValue(channel: channel, pitch: pitch, velocity: velocity,
                                        position: position, length: length)
        } else {
            guard ["Program", "Control", "Controller"].contains(status) else { return nil }
            note = nil
        }
        let expression: Expression?
        if status == "Control", fields[5].flatMap(sliderInt) == 11,
           let label = fields[7], role(label) == kAXPopUpButtonRole,
           (attribute(label, kAXValueAttribute) as String?) == "11 = Expression",
           let channel = fields[4].flatMap(sliderInt), (1...16).contains(channel),
           let valueControl = fields[6], role(valueControl) == kAXSliderRole,
           let raw: NSNumber = attribute(valueControl, kAXValueAttribute),
           let display: String = attribute(valueControl, kAXValueDescriptionAttribute),
           let value = Int(display), (0...127).contains(value), raw.int64Value == Int64(value) * Self.scale {
            expression = Expression(position: position, channel: channel, value: value)
        } else {
            expression = nil
        }
        return Row(element: row, fields: fields, signature: signature, note: note,
                   expression: expression, locked: fields[0] != nil)
    }

    private func coordinate(_ element: AXUIElement, length: Bool) -> Logic13MIDINoteCoordinate? {
        guard let segments = scrubber(element),
              let caption = AXHelpers.getDescription(element, runtime: ax),
              let value = Logic13MIDINoteCoordinate(caption, length: length),
              segments.compactMap(sliderInt) == value.components else { return nil }
        return value
    }

    private func scrubber(_ element: AXUIElement) -> [AXUIElement]? {
        guard role(element) == kAXGroupRole,
              case .success(let parts) = AXHelpers.childrenResult(element, runtime: ax), parts.count == 4,
              parts.enumerated().allSatisfy({ index, part in
                  role(part) == kAXSliderRole && AXHelpers.getDescription(part, runtime: ax) == "Segment \(index)"
              }) else { return nil }
        return parts
    }

    private func sliderInt(_ element: AXUIElement) -> Int? {
        guard role(element) == kAXSliderRole else { return nil }
        return attribute(element, kAXValueAttribute)
    }

    private func fingerprint(_ element: AXUIElement) -> [String] {
        let value: String
        if let number: NSNumber = attribute(element, kAXValueAttribute) { value = number.stringValue }
        else { value = attribute(element, kAXValueAttribute) ?? "" }
        return [role(element) ?? "", AXHelpers.getDescription(element, runtime: ax) ?? "",
                attribute(element, kAXValueDescriptionAttribute) ?? "", value]
    }

    private func elements(_ role: String) -> [AXUIElement] {
        AXHelpers.findAllDescendants(of: pane, role: role, maxDepth: 12, runtime: ax)
    }

    private func role(_ element: AXUIElement) -> String? {
        AXHelpers.getRole(element, runtime: ax)
    }

    private func attribute<T>(_ element: AXUIElement, _ key: String) -> T? {
        AXHelpers.getAttribute(element, key, runtime: ax)
    }
}
